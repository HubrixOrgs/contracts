// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHub} from "../interfaces/IHub.sol";
import {IPoolManager} from "../interfaces/IPoolManager.sol";
import {IPoolHook} from "../interfaces/IPoolHook.sol";
import {SqrtPriceMath} from "../libraries/SqrtPriceMath.sol";

/// @title Singleton manager for hook pools (v4-style full-range venue).
/// @notice Pools are keyed by (token0, token1, hooks, feeSeed). Positions are
///         per-owner full-range liquidity records with v3-style fee accounting.
///         The swap fee is decided per swap by the pool's hook (dynamic or
///         oracle-guarded); pools without a hook use their static feeSeed.
contract PoolManager is IPoolManager, UUPSUpgradeable, ReentrancyGuardUpgradeable, AccessControlUpgradeable {
    using SafeERC20 for IERC20;

    uint128 internal constant MAX_LIQUIDITY = type(uint120).max;

    /// @custom:storage-location erc7201:poolmanager.storage.PoolManager
    struct PMStorage {
        IHub hub;
        mapping(bytes32 => PoolState) pools;
        mapping(bytes32 => mapping(address => PositionState)) positions;
        bytes32[] poolIds;
        mapping(address => mapping(address => bytes32[])) poolIdsByPair;
        address positionManager; // authorized to manage positions on behalf of users
    }

    // ERC-7201 slot for "poolmanager.storage.PoolManager"
    bytes32 private constant PM_STORAGE_SLOT = 0x2df2587d162bc3c21f55ec33407e2108e429bcc964b39c59ca4f0b2035b64d00;

    function _s() private pure returns (PMStorage storage $) {
        assembly {
            $.slot := PM_STORAGE_SLOT
        }
    }

    // ---------- errors ----------
    error IdenticalTokens();
    error ZeroAddress();
    error PoolExists();
    error PoolNotFound();
    error ZeroLiquidity();
    error LiquidityCapExceeded();
    error InsufficientLiquidity();
    error InsufficientOutput(uint256 got, uint256 min);
    error InvalidAmount();
    error NotAuthorized();
    error Paused();
    error ZeroPrice();

    // ---------- events ----------
    event PoolCreated(bytes32 indexed poolId, address token0, address token1, address hooks, uint24 feeSeed, uint160 sqrtPriceX96);
    event ModifyLiquidity(bytes32 indexed poolId, address indexed owner, int256 liquidityDelta, uint256 amount0, uint256 amount1);
    event Swap(bytes32 indexed poolId, address indexed sender, address indexed recipient, bool zeroForOne, uint256 amountIn, uint256 amountOut, uint160 sqrtPriceX96, uint24 feeBps);
    event Collect(bytes32 indexed poolId, address indexed owner, address indexed recipient, uint256 amount0, uint256 amount1);
    event PositionManagerUpdated(address account);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address hub_, address admin) external initializer {
        if (hub_ == address(0) || admin == address(0)) revert ZeroAddress();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _s().hub = IHub(hub_);
    }

    function setPositionManager(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _s().positionManager = account;
        emit PositionManagerUpdated(account);
    }

    function positionManager() external view returns (address) {
        return _s().positionManager;
    }

    function hub() external view returns (address) {
        return address(_s().hub);
    }

    // ---------- pool lifecycle ----------

    function computePoolId(address tokenA, address tokenB, address hooks, uint24 feeSeed)
        public
        pure
        returns (bytes32)
    {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encode(t0, t1, hooks, feeSeed));
    }

    /// @notice Creates a pool. Callable by the PositionManager or the admin.
    function createPool(address tokenA, address tokenB, address hooks, uint24 feeSeed, uint160 sqrtPriceX96)
        external
        nonReentrant
        returns (bytes32 poolId)
    {
        PMStorage storage $ = _s();
        if (msg.sender != $.positionManager && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert NotAuthorized();
        if ($.hub.paused()) revert Paused();
        if (tokenA == address(0) || tokenB == address(0)) revert ZeroAddress();
        if (tokenA == tokenB) revert IdenticalTokens();
        if (sqrtPriceX96 == 0) revert ZeroPrice();
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        poolId = keccak256(abi.encode(t0, t1, hooks, feeSeed));
        PoolState storage pool = $.pools[poolId];
        if (pool.token0 != address(0)) revert PoolExists();
        pool.token0 = t0;
        pool.token1 = t1;
        pool.hooks = hooks;
        pool.feeSeed = feeSeed;
        pool.sqrtPriceX96 = sqrtPriceX96;
        $.poolIds.push(poolId);
        $.poolIdsByPair[t0][t1].push(poolId);
        if (hooks != address(0)) {
            IPoolHook(hooks).onPoolInit(poolId, t0, t1, feeSeed, sqrtPriceX96);
        }
        // register with the hub (venue 1 = hook); skip if this singleton is already registered
        try $.hub.registerPool(address(this), t0, t1, 1) {} catch {}
        emit PoolCreated(poolId, t0, t1, hooks, feeSeed, sqrtPriceX96);
    }

    // ---------- liquidity ----------

    function modifyLiquidity(bytes32 poolId, int256 liquidityDelta, address owner)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        PMStorage storage $ = _s();
        PoolState storage pool = $.pools[poolId];
        if (pool.token0 == address(0)) revert PoolNotFound();
        if (pool.liquidity == 0 && liquidityDelta <= 0) revert ZeroLiquidity();
        PositionState storage pos = $.positions[poolId][owner];

        _updateOwed(pool, pos); // settle pending fees first

        uint160 sqrtP = pool.sqrtPriceX96;
        if (liquidityDelta > 0) {
            if ($.hub.paused()) revert Paused();
            uint128 delta = uint128(uint256(liquidityDelta));
            if (delta == 0) revert InvalidAmount();
            if (delta > MAX_LIQUIDITY - pool.liquidity) revert LiquidityCapExceeded();
            amount0 = Math.mulDiv(delta, 1 << 96, sqrtP, Math.Rounding.Ceil);
            amount1 = Math.mulDiv(delta, sqrtP, 1 << 96, Math.Rounding.Ceil);
            pos.liquidity += delta;
            pool.liquidity += delta;
            IERC20(pool.token0).safeTransferFrom(msg.sender, address(this), amount0);
            IERC20(pool.token1).safeTransferFrom(msg.sender, address(this), amount1);
        } else {
            uint128 delta = uint128(uint256(-liquidityDelta));
            if (delta == 0) revert InvalidAmount();
            if (delta > pos.liquidity) revert InsufficientLiquidity();
            amount0 = Math.mulDiv(delta, 1 << 96, sqrtP); // round down: favors pool
            amount1 = Math.mulDiv(delta, sqrtP, 1 << 96);
            pos.liquidity -= delta;
            pool.liquidity -= delta;
            (uint256 owed0, uint256 owed1) = _settleOwed(pos);
            IERC20(pool.token0).safeTransfer(owner, amount0 + owed0);
            IERC20(pool.token1).safeTransfer(owner, amount1 + owed1);
        }
        emit ModifyLiquidity(poolId, owner, liquidityDelta, amount0, amount1);
    }

    // ---------- swap ----------

    function swap(bytes32 poolId, bool zeroForOne, uint256 amountIn, uint256 amountOutMin, address recipient)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        PMStorage storage $ = _s();
        PoolState storage pool = $.pools[poolId];
        if (pool.token0 == address(0)) revert PoolNotFound();
        if ($.hub.paused()) revert Paused();
        if (amountIn == 0) revert InvalidAmount();
        if (pool.liquidity == 0) revert InsufficientLiquidity();

        uint24 feeBps;
        if (pool.hooks != address(0)) {
            feeBps = IPoolHook(pool.hooks).getSwapFeeBefore(_ctx(poolId, pool, zeroForOne, amountIn));
        } else {
            feeBps = pool.feeSeed;
        }

        uint160 sqrtP = pool.sqrtPriceX96;
        uint128 L = pool.liquidity;
        uint256 feeAmount = (amountIn * feeBps) / 10_000;
        uint256 amountInLessFee = amountIn - feeAmount;

        address tokenIn = zeroForOne ? pool.token0 : pool.token1;
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        uint160 sqrtPAfter;
        if (zeroForOne) {
            // token0 in -> price decreases -> token1 out
            sqrtPAfter = SqrtPriceMath.sqrtPriceAfterToken0In(sqrtP, L, amountInLessFee);
            amountOut = SqrtPriceMath.token1Out(L, sqrtP, sqrtPAfter);
        } else {
            sqrtPAfter = SqrtPriceMath.sqrtPriceAfterToken1In(sqrtP, L, amountInLessFee);
            amountOut = SqrtPriceMath.token0Out(L, sqrtP, sqrtPAfter);
        }
        if (amountOut < amountOutMin) revert InsufficientOutput(amountOut, amountOutMin);

        pool.sqrtPriceX96 = sqrtPAfter;
        _accountFee(pool, zeroForOne, feeAmount, L);

        address tokenOut = zeroForOne ? pool.token1 : pool.token0;
        IERC20(tokenOut).safeTransfer(recipient, amountOut);

        if (pool.hooks != address(0)) {
            IPoolHook(pool.hooks).afterSwap(poolId, sqrtPAfter, amountIn, feeBps);
        }
        emit Swap(poolId, msg.sender, recipient, zeroForOne, amountIn, amountOut, sqrtPAfter, feeBps);
    }

    /// @dev Splits `feeAmount` of the input token: protocol share transfers out,
    ///      LP share grows the global fee accumulator.
    function _accountFee(PoolState storage pool, bool zeroForOne, uint256 feeAmount, uint128 L) internal {
        if (feeAmount == 0) return;
        PMStorage storage $ = _s();
        uint256 protocolCut = (feeAmount * $.hub.protocolFeeBps()) / 10_000;
        uint256 lpCut = feeAmount - protocolCut;
        if (zeroForOne) {
            if (protocolCut > 0) IERC20(pool.token0).safeTransfer($.hub.feeRecipient(), protocolCut);
            pool.feeGrowthGlobal0X128 += Math.mulDiv(lpCut, 1 << 128, L);
        } else {
            if (protocolCut > 0) IERC20(pool.token1).safeTransfer($.hub.feeRecipient(), protocolCut);
            pool.feeGrowthGlobal1X128 += Math.mulDiv(lpCut, 1 << 128, L);
        }
    }

    // ---------- fees ----------

    function collect(bytes32 poolId, address owner, address recipient)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        PMStorage storage $ = _s();
        PoolState storage pool = $.pools[poolId];
        if (pool.token0 == address(0)) revert PoolNotFound();
        PositionState storage pos = $.positions[poolId][owner];
        _updateOwed(pool, pos);
        (amount0, amount1) = _settleOwed(pos);
        if (amount0 > 0) IERC20(pool.token0).safeTransfer(recipient, amount0);
        if (amount1 > 0) IERC20(pool.token1).safeTransfer(recipient, amount1);
        emit Collect(poolId, owner, recipient, amount0, amount1);
    }

    function _ctx(bytes32 poolId, PoolState storage pool, bool zeroForOne, uint256 amountIn)
        internal
        view
        returns (IPoolHook.SwapContext memory)
    {
        return IPoolHook.SwapContext({
            poolId: poolId,
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            sqrtPriceX96: pool.sqrtPriceX96,
            liquidity: pool.liquidity
        });
    }

    function _updateOwed(PoolState storage pool, PositionState storage pos) internal {
        if (pos.liquidity == 0) {
            pos.feeGrowthInside0LastX128 = pool.feeGrowthGlobal0X128;
            pos.feeGrowthInside1LastX128 = pool.feeGrowthGlobal1X128;
            return;
        }
        if (pool.feeGrowthGlobal0X128 != pos.feeGrowthInside0LastX128) {
            pos.tokensOwed0 +=
                Math.mulDiv(pos.liquidity, pool.feeGrowthGlobal0X128 - pos.feeGrowthInside0LastX128, 1 << 128);
        }
        if (pool.feeGrowthGlobal1X128 != pos.feeGrowthInside1LastX128) {
            pos.tokensOwed1 +=
                Math.mulDiv(pos.liquidity, pool.feeGrowthGlobal1X128 - pos.feeGrowthInside1LastX128, 1 << 128);
        }
        pos.feeGrowthInside0LastX128 = pool.feeGrowthGlobal0X128;
        pos.feeGrowthInside1LastX128 = pool.feeGrowthGlobal1X128;
    }

    function _settleOwed(PositionState storage pos) internal returns (uint256, uint256) {
        uint256 a0 = pos.tokensOwed0;
        uint256 a1 = pos.tokensOwed1;
        pos.tokensOwed0 = 0;
        pos.tokensOwed1 = 0;
        return (a0, a1);
    }

    // ---------- views ----------

    function getPool(bytes32 poolId) external view returns (PoolState memory) {
        return _s().pools[poolId];
    }

    function poolTokens(bytes32 poolId) external view returns (address, address) {
        PoolState storage pool = _s().pools[poolId];
        return (pool.token0, pool.token1);
    }

    function getPosition(bytes32 poolId, address owner) external view returns (PositionState memory) {
        return _s().positions[poolId][owner];
    }

    function poolIdsForPair(address tokenA, address tokenB) external view returns (bytes32[] memory) {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return _s().poolIdsByPair[t0][t1];
    }

    function poolCount() external view returns (uint256) {
        return _s().poolIds.length;
    }

    /// @notice Simulated exact-in quote. Reverts if the hook guard rejects the trade.
    function getAmountOut(bytes32 poolId, bool zeroForOne, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint24 feeBps)
    {
        PMStorage storage $ = _s();
        PoolState storage pool = $.pools[poolId];
        if (pool.token0 == address(0)) revert PoolNotFound();
        if (pool.liquidity == 0 || amountIn == 0) return (0, 0);
        if (pool.hooks != address(0)) {
            feeBps = IPoolHook(pool.hooks).getSwapFeeBefore(_ctx(poolId, pool, zeroForOne, amountIn));
        } else {
            feeBps = pool.feeSeed;
        }
        uint256 feeAmount = (amountIn * feeBps) / 10_000;
        uint256 inLessFee = amountIn - feeAmount;
        uint160 sqrtP = pool.sqrtPriceX96;
        if (zeroForOne) {
            uint160 sqrtAfter = SqrtPriceMath.sqrtPriceAfterToken0In(sqrtP, pool.liquidity, inLessFee);
            amountOut = SqrtPriceMath.token1Out(pool.liquidity, sqrtP, sqrtAfter);
        } else {
            uint160 sqrtAfter = SqrtPriceMath.sqrtPriceAfterToken1In(sqrtP, pool.liquidity, inLessFee);
            amountOut = SqrtPriceMath.token0Out(pool.liquidity, sqrtP, sqrtAfter);
        }
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
