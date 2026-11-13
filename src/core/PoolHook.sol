// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHub} from "../interfaces/IHub.sol";
import {IPoolHook} from "../interfaces/IPoolHook.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {FeeMath} from "../libraries/FeeMath.sol";
import {SqrtPriceMath} from "../libraries/SqrtPriceMath.sol";

/// @title Combined dynamic-fee and oracle-guard hook for singleton pools.
/// @notice Mode is selected per pool at creation:
///         - DYNAMIC: volatility accumulator drives the fee (base 5 bps, cap 2,000 bps).
///         - ORACLE_GUARDED (auto-selected when either asset is a STOCK): deviation-scaled
///           fee (base 30 bps, cap 3,000 bps), staleness revert, circuit breaker.
contract PoolHook is IPoolHook, UUPSUpgradeable, AccessControlUpgradeable {
    using FeeMath for FeeMath.VolState;

    enum Mode {
        NONE,
        DYNAMIC,
        ORACLE_GUARDED
    }

    struct FeeCfg {
        Mode mode;
        uint24 baseFeeBps;
        uint24 maxFeeBps;
    }

    /// @custom:storage-location erc7201:poolhook.storage.PoolHook
    struct HookStorage {
        IHub hub;
        address manager;
        mapping(bytes32 => FeeCfg) poolCfg;
        mapping(bytes32 => FeeMath.VolState) vol;
        uint64 decayWindow;
        uint64 oracleStaleness; // seconds
        uint32 maxDeviationBps; // circuit breaker threshold
        uint32 devFeeSpanBps; // deviation at which the fee reaches its cap
    }

    // ERC-7201 slot for "poolhook.storage.PoolHook"
    bytes32 private constant HOOK_STORAGE_SLOT = 0x6570ec48ea46f4a412adff979b6c765c6070dd5fc3121aecbc9c3b6f31f65c00;

    function _s() private pure returns (HookStorage storage $) {
        assembly {
            $.slot := HOOK_STORAGE_SLOT
        }
    }

    // ---------- errors ----------
    error ZeroAddress();
    error NotAuthorized();
    error NotPool();
    error FeeCapTooHigh();
    error OracleStale();
    error CircuitBreakerTripped(uint256 deviationBps, uint256 maxBps);
    error NoOracle();

    // ---------- events ----------
    event FeeCharged(bytes32 indexed poolId, uint24 feeBps, uint96 accumulator);
    event PoolConfigured(bytes32 indexed poolId, uint8 mode, uint24 baseFeeBps, uint24 maxFeeBps);
    event ManagerUpdated(address manager);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address hub_, address admin) external initializer {
        if (hub_ == address(0) || admin == address(0)) revert ZeroAddress();
        __UUPSUpgradeable_init();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        HookStorage storage $ = _s();
        $.hub = IHub(hub_);
        $.decayWindow = FeeMath.DEFAULT_DECAY_WINDOW; // 600 s
        $.oracleStaleness = 24 hours;
        $.maxDeviationBps = 1_000; // 10%
        $.devFeeSpanBps = 5_000; // 50% deviation saturates the fee span
    }

    function setManager(address manager_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _s().manager = manager_;
        emit ManagerUpdated(manager_);
    }

    function manager() external view returns (address) {
        return _s().manager;
    }

    function setRiskParams(uint64 decayWindow, uint64 oracleStaleness, uint32 maxDeviationBps, uint32 devFeeSpanBps)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        HookStorage storage $ = _s();
        $.decayWindow = decayWindow;
        $.oracleStaleness = oracleStaleness;
        $.maxDeviationBps = maxDeviationBps;
        $.devFeeSpanBps = devFeeSpanBps;
    }

    // ---------- pool init ----------

    function onPoolInit(bytes32 poolId, address token0, address token1, uint24, uint160 sqrtPriceX96)
        external
    {
        HookStorage storage $ = _s();
        if (msg.sender != $.manager) revert NotAuthorized();
        FeeCfg storage cfg = $.poolCfg[poolId];
        if (cfg.mode != Mode.NONE) revert NotPool(); // already configured
        bool stock = _isStock(token0) || _isStock(token1);
        if (stock) {
            cfg.mode = Mode.ORACLE_GUARDED;
            cfg.baseFeeBps = 30;
            cfg.maxFeeBps = 3_000;
        } else {
            cfg.mode = Mode.DYNAMIC;
            cfg.baseFeeBps = 5;
            cfg.maxFeeBps = 2_000;
        }
        FeeMath.VolState storage v = $.vol[poolId];
        v.lastPriceX96 = sqrtPriceX96;
        v.lastTs = uint64(block.timestamp);
        emit PoolConfigured(poolId, uint8(cfg.mode), cfg.baseFeeBps, cfg.maxFeeBps);
    }

    /// @notice OPERATOR override of per-pool fee config (clamped to the hub cap).
    function configurePool(bytes32 poolId, uint8 mode, uint24 baseFeeBps, uint24 maxFeeBps)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        HookStorage storage $ = _s();
        if ($.poolCfg[poolId].mode == Mode.NONE) revert NotPool();
        if (mode == 0 || mode > 2) revert NotPool();
        if (maxFeeBps > $.hub.maxFeeBps()) revert FeeCapTooHigh();
        if (baseFeeBps > maxFeeBps) revert FeeCapTooHigh();
        $.poolCfg[poolId] = FeeCfg(Mode(mode), baseFeeBps, maxFeeBps);
        emit PoolConfigured(poolId, mode, baseFeeBps, maxFeeBps);
    }

    // ---------- fee decisions ----------

    function getSwapFeeBefore(IPoolHook.SwapContext memory ctx) external view returns (uint24 feeBps) {
        HookStorage storage $ = _s();
        FeeCfg storage cfg = $.poolCfg[ctx.poolId];
        if (cfg.mode == Mode.NONE) revert NotPool();
        uint24 hubCap = $.hub.maxFeeBps();

        if (cfg.mode == Mode.DYNAMIC) {
            return FeeMath.dynamicFee(cfg.baseFeeBps, cfg.maxFeeBps, $.vol[ctx.poolId].accumulator, hubCap);
        }

        // ORACLE_GUARDED
        PoolManagerLike pm = PoolManagerLike(msg.sender);
        (address t0, address t1) = pm.poolTokens(ctx.poolId);
        (uint256 p0, uint64 u0) = _price(t0);
        (uint256 p1, uint64 u1) = _price(t1);
        uint64 stale = $.oracleStaleness;
        if (block.timestamp - u0 > stale || block.timestamp - u1 > stale) revert OracleStale();

        // oracle price of token1 per token0 (WAD)
        uint256 oraclePrice = (p0 * 1e18) / p1;
        uint256 poolPrice = _poolPriceWad(ctx.sqrtPriceX96);
        uint256 devBefore = _deviationBps(poolPrice, oraclePrice);

        // simulate post-trade price
        uint160 afterX96 = ctx.zeroForOne
            ? SqrtPriceMath.sqrtPriceAfterToken0In(ctx.sqrtPriceX96, ctx.liquidity, ctx.amountIn)
            : SqrtPriceMath.sqrtPriceAfterToken1In(ctx.sqrtPriceX96, ctx.liquidity, ctx.amountIn);
        uint256 devAfter = _deviationBps(_poolPriceWad(afterX96), oraclePrice);

        if (devAfter > $.maxDeviationBps) {
            revert CircuitBreakerTripped(devAfter, $.maxDeviationBps);
        }
        if (devAfter <= devBefore) {
            // trade pulls the pool toward the reference price
            return cfg.baseFeeBps > hubCap ? hubCap : cfg.baseFeeBps;
        }
        // trade pushes away: scale the fee span by deviation
        uint256 span = cfg.maxFeeBps > cfg.baseFeeBps ? cfg.maxFeeBps - cfg.baseFeeBps : 0;
        uint256 spanBps = devAfter > $.devFeeSpanBps ? $.devFeeSpanBps : devAfter;
        uint256 fee = cfg.baseFeeBps + (span * spanBps) / $.devFeeSpanBps;
        if (fee > hubCap) fee = hubCap;
        return uint24(fee);
    }

    function afterSwap(bytes32 poolId, uint160 sqrtPriceAfterX96, uint256, uint24 feeBps) external {
        HookStorage storage $ = _s();
        if (msg.sender != $.manager) revert NotAuthorized();
        FeeCfg storage cfg = $.poolCfg[poolId];
        if (cfg.mode == Mode.NONE) revert NotPool();
        FeeMath.VolState storage v = $.vol[poolId];
        v.accumulator = FeeMath.update(v, sqrtPriceAfterX96, $.decayWindow);
        v.lastPriceX96 = sqrtPriceAfterX96;
        v.lastTs = uint64(block.timestamp);
        emit FeeCharged(poolId, feeBps, v.accumulator);
    }

    // ---------- views ----------

    function poolConfig(bytes32 poolId) external view returns (Mode mode, uint24 baseFeeBps, uint24 maxFeeBps) {
        FeeCfg storage cfg = _s().poolCfg[poolId];
        return (cfg.mode, cfg.baseFeeBps, cfg.maxFeeBps);
    }

    function volInfo(bytes32 poolId) external view returns (uint96 accumulator, uint160 lastPriceX96, uint64 lastTs) {
        FeeMath.VolState storage v = _s().vol[poolId];
        return (v.accumulator, v.lastPriceX96, v.lastTs);
    }

    function riskParams()
        external
        view
        returns (uint64 decayWindow, uint64 oracleStaleness, uint32 maxDeviationBps, uint32 devFeeSpanBps)
    {
        HookStorage storage $ = _s();
        return ($.decayWindow, $.oracleStaleness, $.maxDeviationBps, $.devFeeSpanBps);
    }

    // ---------- internals ----------

    function _isStock(address token) internal view returns (bool) {
        IHub.AssetInfo memory info = _s().hub.assetInfo(token);
        return info.active && info.class == 1;
    }

    function _price(address token) internal view returns (uint256 price, uint64 updatedAt) {
        IHub.AssetInfo memory info = _s().hub.assetInfo(token);
        if (info.oracle == address(0)) revert NoOracle();
        (price, updatedAt) = IOracle(info.oracle).getTokenPrice(token);
        if (price == 0) revert NoOracle();
    }

    /// @dev pool price as token1-per-token0 in WAD from the Q64.96 sqrt price.
    function _poolPriceWad(uint160 sqrtP) internal pure returns (uint256) {
        return Math.mulDiv(sqrtP, uint256(sqrtP) * 1e18, 1 << 192);
    }

    function _deviationBps(uint256 poolPrice, uint256 oraclePrice) internal pure returns (uint256) {
        uint256 diff = poolPrice > oraclePrice ? poolPrice - oraclePrice : oraclePrice - poolPrice;
        return (diff * 10_000) / oraclePrice;
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

/// @dev Minimal manager view surface used by the hook.
interface PoolManagerLike {
    function poolTokens(bytes32 poolId) external view returns (address token0, address token1);
}
