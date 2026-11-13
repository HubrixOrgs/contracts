// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {ERC721EnumerableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHub} from "../interfaces/IHub.sol";
import {IPoolManager} from "../interfaces/IPoolManager.sol";

/// @title ERC-721 LP positions over singleton pools, with locks and vesting.
/// @notice The contract owns positions inside the PoolManager; each NFT maps to
///         one (poolId, liquidity) record. Locks block transfer and principal
///         withdrawal; vesting (cliff + linear) caps withdrawable principal;
///         fee collection is never restricted.
contract PositionManager is
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    ERC721Upgradeable,
    ERC721EnumerableUpgradeable
{
    using SafeERC20 for IERC20;

    uint64 public constant PERMANENT_LOCK = type(uint64).max;

    struct PositionInfo {
        bytes32 poolId; // 32
        uint128 liquidity; // 16
        uint64 lockUntil; // 8
        uint64 vestCliff; // 8
        uint64 vestDuration; // 8
        uint128 vestPrincipalSnapshot; // liquidity snapshot under vesting
        uint128 principalWithdrawn; // liquidity already withdrawn under vesting
    } // fits in 3 slots + 1

    /// @custom:storage-location erc7201:positionmanager.storage.PositionManager
    struct PMNStorage {
        IHub hub;
        IPoolManager manager;
        address creditManager;
        mapping(uint256 => PositionInfo) positions;
        uint256 nextId;
    }

    // ERC-7201 slot for "positionmanager.storage.PositionManager"
    bytes32 private constant PMN_STORAGE_SLOT = 0x02b1b1786f8d033fcfc3ccfc1e2c0ac35923a335a2cbe1f57c1275f984db9900;

    function _s() private pure returns (PMNStorage storage $) {
        assembly {
            $.slot := PMN_STORAGE_SLOT
        }
    }

    struct MintParams {
        address tokenA;
        address tokenB;
        address hooks;
        uint24 feeSeed;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
        address recipient;
        uint64 lockUntil; // 0 = unlocked; PERMANENT_LOCK = forever
    }

    /// @param amount0Desired token0 amount (pool order)
    /// @param amount1Desired token1 amount (pool order)
    struct AddParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct RemoveParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    // ---------- errors ----------
    error ZeroAddress();
    error Expired(uint256 deadline);
    error InsufficientAmountA(uint256 got, uint256 min);
    error InsufficientAmountB(uint256 got, uint256 min);
    error PositionLocked(uint256 tokenId, uint64 until);
    error PositionPledged(uint256 tokenId);
    error LockShortened();
    error UnknownToken(uint256 tokenId);
    error NotOwner();
    error VestingNotStarted();
    error VestingShortened();
    error ExceedsWithdrawable(uint256 requested, uint256 available);
    error ZeroAmount();
    error InvalidVesting();
    error Paused();

    // ---------- events ----------
    event Mint(uint256 indexed tokenId, bytes32 indexed poolId, uint128 liquidity, address indexed recipient, uint64 lockUntil);
    event LiquidityAdded(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event LiquidityRemoved(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event FeesCollected(uint256 indexed tokenId, address indexed recipient, uint256 amount0, uint256 amount1);
    event Burned(uint256 indexed tokenId);
    event Locked(uint256 indexed tokenId, uint64 until);
    event VestingSet(uint256 indexed tokenId, uint64 cliff, uint64 duration);
    event CreditManagerUpdated(address account);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address hub_, address manager_, address admin)
        external
        initializer
    {
        if (hub_ == address(0) || manager_ == address(0) || admin == address(0)) revert ZeroAddress();
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __ERC721_init("Liquidity Position", "LP-POS");
        __ERC721Enumerable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        PMNStorage storage $ = _s();
        $.hub = IHub(hub_);
        $.manager = IPoolManager(manager_);
        $.nextId = 1;
    }

    function setCreditManager(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _s().creditManager = account;
        emit CreditManagerUpdated(account);
    }

    function poolManager() external view returns (address) {
        return address(_s().manager);
    }

    // ---------- position lifecycle ----------

    function mint(MintParams calldata p) external nonReentrant returns (uint256 tokenId) {
        if (block.timestamp > p.deadline) revert Expired(p.deadline);
        PMNStorage storage $ = _s();
        if ($.hub.paused()) revert Paused();
        bytes32 poolId = $.manager.computePoolId(p.tokenA, p.tokenB, p.hooks, p.feeSeed);
        IPoolManager.PoolState memory pool = $.manager.getPool(poolId);
        if (pool.token0 == address(0)) {
            // create the pool at the implied price from the deposit ratio (token1 per token0)
            uint256 num = p.tokenA < p.tokenB ? p.amount1Desired : p.amount0Desired;
            uint256 den = p.tokenA < p.tokenB ? p.amount0Desired : p.amount1Desired;
            uint256 priceX96 = Math.mulDiv(num, 1 << 96, den);
            uint160 sqrtP = _sqrtFromPriceX96(priceX96);
            poolId = $.manager.createPool(p.tokenA, p.tokenB, p.hooks, p.feeSeed, sqrtP);
        }
        pool = $.manager.getPool(poolId);

        // map desired/min amounts from the caller's (tokenA, tokenB) order to sorted (token0, token1)
        bool aIs0 = pool.token0 == p.tokenA;
        uint256 desired0 = aIs0 ? p.amount0Desired : p.amount1Desired;
        uint256 desired1 = aIs0 ? p.amount1Desired : p.amount0Desired;
        uint256 min0 = aIs0 ? p.amount0Min : p.amount1Min;
        uint256 min1 = aIs0 ? p.amount1Min : p.amount0Min;

        // compute liquidity, then pull exactly the liquidity-derived amounts
        uint128 liquidity = _liquidityForAmounts(pool.sqrtPriceX96, desired0, desired1);
        uint256 exp0 = Math.mulDiv(liquidity, 1 << 96, pool.sqrtPriceX96, Math.Rounding.Ceil);
        uint256 exp1 = Math.mulDiv(liquidity, pool.sqrtPriceX96, 1 << 96, Math.Rounding.Ceil);
        IERC20(pool.token0).safeTransferFrom(msg.sender, address(this), exp0);
        IERC20(pool.token1).safeTransferFrom(msg.sender, address(this), exp1);
        _approveManager(pool.token0, exp0);
        _approveManager(pool.token1, exp1);

        (uint256 amount0, uint256 amount1) =
            $.manager.modifyLiquidity(poolId, int256(uint256(liquidity)), address(this));
        if (amount0 < min0) revert InsufficientAmountA(amount0, min0);
        if (amount1 < min1) revert InsufficientAmountB(amount1, min1);

        tokenId = $.nextId++;
        _s().positions[tokenId] = PositionInfo({
            poolId: poolId,
            liquidity: liquidity,
            lockUntil: p.lockUntil,
            vestCliff: 0,
            vestDuration: 0,
            vestPrincipalSnapshot: 0,
            principalWithdrawn: 0
        });
        _safeMint(p.recipient, tokenId);
        emit Mint(tokenId, poolId, liquidity, p.recipient, p.lockUntil);
    }

    function addLiquidity(AddParams calldata p) external nonReentrant {
        if (block.timestamp > p.deadline) revert Expired(p.deadline);
        PMNStorage storage $ = _s();
        if ($.hub.paused()) revert Paused();
        PositionInfo storage pos = $.positions[p.tokenId];
        if (pos.poolId == bytes32(0)) revert UnknownToken(p.tokenId);
        _checkOwner(p.tokenId);
        IPoolManager.PoolState memory pool = $.manager.getPool(pos.poolId);

        // AddParams amounts are in POOL order (token0, token1)
        uint128 delta = _liquidityForAmounts(pool.sqrtPriceX96, p.amount0Desired, p.amount1Desired);
        uint256 exp0 = Math.mulDiv(delta, 1 << 96, pool.sqrtPriceX96, Math.Rounding.Ceil);
        uint256 exp1 = Math.mulDiv(delta, pool.sqrtPriceX96, 1 << 96, Math.Rounding.Ceil);
        IERC20(pool.token0).safeTransferFrom(msg.sender, address(this), exp0);
        IERC20(pool.token1).safeTransferFrom(msg.sender, address(this), exp1);
        _approveManager(pool.token0, exp0);
        _approveManager(pool.token1, exp1);

        (uint256 amount0, uint256 amount1) =
            $.manager.modifyLiquidity(pos.poolId, int256(uint256(delta)), address(this));
        if (amount0 < p.amount0Min) revert InsufficientAmountA(amount0, p.amount0Min);
        if (amount1 < p.amount1Min) revert InsufficientAmountB(amount1, p.amount1Min);
        pos.liquidity += delta;
        emit LiquidityAdded(p.tokenId, delta, amount0, amount1);
    }

    function removeLiquidity(RemoveParams calldata p) external nonReentrant {
        if (block.timestamp > p.deadline) revert Expired(p.deadline);
        PMNStorage storage $ = _s();
        PositionInfo storage pos = $.positions[p.tokenId];
        if (pos.poolId == bytes32(0)) revert UnknownToken(p.tokenId);
        _checkOwner(p.tokenId);
        if (p.liquidity == 0) revert ZeroAmount();
        _checkWithdrawable(pos, p.tokenId, p.liquidity);

        // route the withdrawal through this contract (owner of the manager position)
        (uint256 amount0, uint256 amount1) =
            $.manager.modifyLiquidity(pos.poolId, -int256(uint256(p.liquidity)), address(this));
        if (amount0 < p.amount0Min) revert InsufficientAmountA(amount0, p.amount0Min);
        if (amount1 < p.amount1Min) revert InsufficientAmountB(amount1, p.amount1Min);
        pos.liquidity -= p.liquidity;
        if (pos.vestDuration > 0) {
            pos.principalWithdrawn += p.liquidity;
        }
        address owner = ownerOf(p.tokenId);
        IPoolManager.PoolState memory pool = $.manager.getPool(pos.poolId);
        IERC20(pool.token0).safeTransfer(owner, amount0);
        IERC20(pool.token1).safeTransfer(owner, amount1);
        emit LiquidityRemoved(p.tokenId, p.liquidity, amount0, amount1);
    }

    /// @notice Collect accrued fees to the NFT owner. Never blocked by locks/vesting/pledge.
    function collect(uint256 tokenId, address recipient) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        PMNStorage storage $ = _s();
        PositionInfo storage pos = $.positions[tokenId];
        if (pos.poolId == bytes32(0)) revert UnknownToken(tokenId);
        _checkOwner(tokenId);
        (amount0, amount1) = $.manager.collect(pos.poolId, address(this), recipient);
        emit FeesCollected(tokenId, recipient, amount0, amount1);
    }

    function burn(uint256 tokenId) external nonReentrant {
        PositionInfo storage pos = _s().positions[tokenId];
        if (pos.poolId == bytes32(0)) revert UnknownToken(tokenId);
        _checkOwner(tokenId);
        if (pos.liquidity > 0) revert PositionLocked(tokenId, pos.lockUntil);
        delete _s().positions[tokenId];
        _burn(tokenId);
        emit Burned(tokenId);
    }

    // ---------- locks & vesting ----------

    /// @notice Lock principal until `unlockAt` (PERMANENT_LOCK = forever). Only extends.
    function lock(uint256 tokenId, uint64 unlockAt) external {
        PositionInfo storage pos = _s().positions[tokenId];
        if (pos.poolId == bytes32(0)) revert UnknownToken(tokenId);
        _checkOwner(tokenId);
        if (unlockAt < pos.lockUntil) revert LockShortened();
        pos.lockUntil = unlockAt;
        emit Locked(tokenId, unlockAt);
    }

    /// @notice Set a cliff + linear vesting schedule on the current principal.
    ///         Withdrawable principal = snapshot * elapsedAfterCliff / duration.
    function setVesting(uint256 tokenId, uint64 cliff, uint64 duration) external {
        PMNStorage storage $ = _s();
        PositionInfo storage pos = $.positions[tokenId];
        if (pos.poolId == bytes32(0)) revert UnknownToken(tokenId);
        _checkOwner(tokenId);
        if (duration == 0) revert InvalidVesting();
        if (cliff < block.timestamp) cliff = uint64(block.timestamp);
        if (pos.vestDuration > 0 && cliff < pos.vestCliff) revert VestingShortened();
        pos.vestCliff = cliff;
        pos.vestDuration = duration;
        pos.vestPrincipalSnapshot = pos.liquidity;
        pos.principalWithdrawn = 0;
        emit VestingSet(tokenId, cliff, duration);
    }

    function vestedPrincipal(uint256 tokenId) public view returns (uint128) {
        PositionInfo storage pos = _s().positions[tokenId];
        if (pos.vestDuration == 0) return pos.liquidity;
        if (block.timestamp < pos.vestCliff) return 0;
        uint256 elapsed = block.timestamp - pos.vestCliff;
        if (elapsed >= pos.vestDuration) return pos.vestPrincipalSnapshot;
        uint256 vested =
            (uint256(pos.vestPrincipalSnapshot) * elapsed) / pos.vestDuration;
        return uint128(vested);
    }

    function withdrawablePrincipal(uint256 tokenId) public view returns (uint128) {
        PositionInfo storage pos = _s().positions[tokenId];
        if (block.timestamp < pos.lockUntil) return 0;
        uint128 vested = vestedPrincipal(tokenId);
        if (vested > pos.principalWithdrawn) {
            uint128 avail = vested - pos.principalWithdrawn;
            return avail > pos.liquidity ? pos.liquidity : avail;
        }
        return 0;
    }

    // ---------- views ----------

    function position(uint256 tokenId) external view returns (PositionInfo memory) {
        return _s().positions[tokenId];
    }

    /// @notice Pool id backing a position token (credit collateral valuation).
    function positionPool(uint256 tokenId) external view returns (bytes32) {
        return _s().positions[tokenId].poolId;
    }

    function nextTokenId() external view returns (uint256) {
        return _s().nextId;
    }

    /// @notice Underlying amounts + owed fees for a position.
    function positionAmounts(uint256 tokenId)
        external
        view
        returns (uint128 liquidity, uint256 amount0, uint256 amount1, uint256 feesOwed0, uint256 feesOwed1)
    {
        PMNStorage storage $ = _s();
        PositionInfo storage pos = $.positions[tokenId];
        liquidity = pos.liquidity;
        IPoolManager.PoolState memory pool = $.manager.getPool(pos.poolId);
        amount0 = Math.mulDiv(liquidity, 1 << 96, pool.sqrtPriceX96);
        amount1 = Math.mulDiv(liquidity, pool.sqrtPriceX96, 1 << 96);
        IPoolManager.PositionState memory mpos = $.manager.getPosition(pos.poolId, address(this));
        // owed = liquidity * (global - last) for both tokens
        if (mpos.liquidity > 0) {
            if (pool.feeGrowthGlobal0X128 > mpos.feeGrowthInside0LastX128) {
                feesOwed0 = Math.mulDiv(
                    liquidity,
                    pool.feeGrowthGlobal0X128 - mpos.feeGrowthInside0LastX128,
                    1 << 128
                ) + mpos.tokensOwed0;
            } else {
                feesOwed0 = mpos.tokensOwed0;
            }
            if (pool.feeGrowthGlobal1X128 > mpos.feeGrowthInside1LastX128) {
                feesOwed1 = Math.mulDiv(
                    liquidity,
                    pool.feeGrowthGlobal1X128 - mpos.feeGrowthInside1LastX128,
                    1 << 128
                ) + mpos.tokensOwed1;
            } else {
                feesOwed1 = mpos.tokensOwed1;
            }
        }
    }

    // ---------- internals ----------

    function _checkOwner(uint256 tokenId) internal view {
        if (ownerOf(tokenId) != msg.sender) revert NotOwner();
    }

    function _checkWithdrawable(PositionInfo storage pos, uint256 tokenId, uint128 amount) internal view {
        if (block.timestamp < pos.lockUntil) revert PositionLocked(tokenId, pos.lockUntil);
        PMNStorage storage $ = _s();
        if ($.creditManager != address(0) && ICreditManagerView($.creditManager).pledgedToken(tokenId)) {
            revert PositionPledged(tokenId);
        }
        if (pos.vestDuration > 0) {
            uint128 avail = withdrawablePrincipal(tokenId);
            if (amount > avail) revert ExceedsWithdrawable(amount, avail);
        }
    }

    function _liquidityForAmounts(uint160 sqrtP, uint256 amount0, uint256 amount1)
        internal
        pure
        returns (uint128)
    {
        // full range: L = min(sqrt(amount0 * amount1)) derived from each side
        uint256 l0 = Math.mulDiv(amount0, sqrtP, 1 << 96); // L = x * sqrtP
        uint256 l1 = Math.mulDiv(amount1, 1 << 96, sqrtP); // L = y / sqrtP
        uint256 l = l0 < l1 ? l0 : l1;
        return uint128(l);
    }

    function _sqrtFromPriceX96(uint256 priceX96) internal pure returns (uint160) {
        // sqrt(price * 2^96) = sqrtPrice * 2^48 ... -> sqrtQ96 = sqrt(priceX96 << 96)
        return uint160(Math.sqrt(Math.mulDiv(priceX96, 1 << 96, 1)));
    }

    function _approveManager(address token, uint256 amount) internal {
        IERC20(token).forceApprove(address(_s().manager), amount);
    }

    function _refund(address token, address to, uint256 amount) internal {
        if (amount > 0) IERC20(token).safeTransfer(to, amount);
    }

    // ---------- ERC-721 plumbing ----------

    function _update(address to, uint256 tokenId, address auth)
        internal
        override (ERC721Upgradeable, ERC721EnumerableUpgradeable)
        returns (address)
    {
        PMNStorage storage $ = _s();
        PositionInfo storage pos = $.positions[tokenId];
        if (pos.poolId != bytes32(0)) {
            address from = _ownerOf(tokenId);
            if (from != address(0) && to != address(0)) {
                if (block.timestamp < pos.lockUntil) revert PositionLocked(tokenId, pos.lockUntil);
                if (
                    $.creditManager != address(0) && ICreditManagerView($.creditManager).pledgedToken(tokenId)
                        && from != $.creditManager
                ) {
                    revert PositionPledged(tokenId);
                }
            }
        }
        return super._update(to, tokenId, auth);
    }

    function _increaseBalance(address account, uint128 value)
        internal
        override (ERC721Upgradeable, ERC721EnumerableUpgradeable)
    {
        super._increaseBalance(account, value);
    }

    function tokenURI(uint256) public pure override returns (string memory) {
        return "";
    }

    function supportsInterface(bytes4 id)
        public
        view
        override (AccessControlUpgradeable, ERC721Upgradeable, ERC721EnumerableUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(id);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

/// @dev Read surface the PositionManager uses from the CreditManager.
interface ICreditManagerView {
    function pledgedToken(uint256 tokenId) external view returns (bool);
}
