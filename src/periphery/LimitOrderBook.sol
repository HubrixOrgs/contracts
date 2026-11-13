// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBinPool} from "../interfaces/IBinPool.sol";
import {IHub} from "../interfaces/IHub.sol";

/// @title Single-bin limit orders over bin pools.
/// @notice An order parks one asset in a single non-active bin; it fills
///         passively as the active bin crosses it. Owner or keeper claims the
///         proceeds (keeper earns a fee); cancel works until filled.
contract LimitOrderBook is UUPSUpgradeable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_KEEPER_FEE_BPS = 100; // 1%

    struct Order {
        address pool;
        int32 binId;
        bool zeroForOne; // true: sell token0 into a bin above active
        uint256 amountIn;
        uint256 shares; // bin shares held for this order
        address owner;
        uint16 keeperFeeBps;
        bool active;
    }

    /// @custom:storage-location erc7201:limitorderbook.storage.LimitOrderBook
    struct LOBStorage {
        IHub hub;
        mapping(uint256 => Order) orders;
        uint256 nextId;
    }

    // ERC-7201 slot for "limitorderbook.storage.LimitOrderBook"
    bytes32 private constant LOB_STORAGE_SLOT = 0x169b74994b5190da6167dd0abdc1c4de4c0f3c0a51ede5b3504e15d85c109900;

    function _s() private pure returns (LOBStorage storage $) {
        assembly {
            $.slot := LOB_STORAGE_SLOT
        }
    }

    error ZeroAddress();
    error ZeroAmount();
    error NotBinPool();
    error WrongBinSide(int32 binId, int32 activeId);
    error InvalidKeeperFee();
    error NotOwner();
    error OrderNotFillable(uint256 orderId);
    error OrderStillOpen(uint256 orderId);
    error UnknownOrder(uint256 orderId);
    error Paused();

    event Placed(uint256 indexed orderId, address indexed pool, int32 indexed binId, bool zeroForOne, uint256 amountIn);
    event Claimed(uint256 indexed orderId, address indexed owner, address keeper, uint256 amount0, uint256 amount1, uint256 keeperFee0, uint256 keeperFee1);
    event Cancelled(uint256 indexed orderId, uint256 amount0, uint256 amount1);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address hub_, address admin) external initializer {
        if (hub_ == address(0) || admin == address(0)) revert ZeroAddress();
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _s().hub = IHub(hub_);
        _s().nextId = 1;
    }

    function hub() external view returns (address) {
        return address(_s().hub);
    }

    function order(uint256 orderId) external view returns (Order memory) {
        return _s().orders[orderId];
    }

    function orderCount() external view returns (uint256) {
        return _s().nextId - 1;
    }

    /// @notice Place a limit order. zeroForOne=true sells token0 and requires
    ///         binId ABOVE the active bin (fills as price rises); zeroForOne=false
    ///         sells token1 into a bin BELOW active (fills as price falls).
    function place(address pool, int32 binId, bool zeroForOne, uint256 amountIn, uint16 keeperFeeBps)
        external
        nonReentrant
        returns (uint256 orderId)
    {
        LOBStorage storage $ = _s();
        if ($.hub.paused()) revert Paused();
        if (pool == address(0) || amountIn == 0) revert ZeroAmount();
        if (keeperFeeBps > MAX_KEEPER_FEE_BPS) revert InvalidKeeperFee();
        IBinPool p = IBinPool(pool);
        if ($.hub.poolVenue(pool) != 2) revert NotBinPool();
        int32 active = p.activeId();
        if (zeroForOne) {
            if (binId <= active) revert WrongBinSide(binId, active); // sell token0 above market
        } else {
            if (binId >= active) revert WrongBinSide(binId, active); // sell token1 below market
        }

        // pull the sold token and deposit into the bin as the book
        address tokenIn = zeroForOne ? p.token0() : p.token1();
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(pool, amountIn);

        int32[] memory ids = new int32[](1);
        uint256[] memory a0 = new uint256[](1);
        uint256[] memory a1 = new uint256[](1);
        ids[0] = binId;
        if (zeroForOne) {
            a0[0] = amountIn;
        } else {
            a1[0] = amountIn;
        }
        uint256[] memory minted = p.addLiquidity(ids, a0, a1, address(this));

        orderId = $.nextId++;
        $.orders[orderId] = Order({
            pool: pool,
            binId: binId,
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            shares: minted[0],
            owner: msg.sender,
            keeperFeeBps: keeperFeeBps,
            active: true
        });
        emit Placed(orderId, pool, binId, zeroForOne, amountIn);
    }

    /// @notice Claim a filled (or partially filled) order. Keeper calls earn a fee.
    function claim(uint256 orderId) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        LOBStorage storage $ = _s();
        Order storage o = $.orders[orderId];
        if (!o.active) revert UnknownOrder(orderId);
        IBinPool p = IBinPool(o.pool);
        int32 active = p.activeId();
        bool isFilled = o.zeroForOne ? active >= o.binId : active <= o.binId;
        if (!isFilled) revert OrderNotFillable(orderId);
        (amount0, amount1) = _exit(o, p);

        uint256 fee0;
        uint256 fee1;
        if (msg.sender != o.owner && o.keeperFeeBps > 0) {
            fee0 = (amount0 * o.keeperFeeBps) / 10_000;
            fee1 = (amount1 * o.keeperFeeBps) / 10_000;
        }
        if (amount0 - fee0 > 0) IERC20(p.token0()).safeTransfer(o.owner, amount0 - fee0);
        if (amount1 - fee1 > 0) IERC20(p.token1()).safeTransfer(o.owner, amount1 - fee1);
        if (fee0 > 0) IERC20(p.token0()).safeTransfer(msg.sender, fee0);
        if (fee1 > 0) IERC20(p.token1()).safeTransfer(msg.sender, fee1);
        emit Claimed(orderId, o.owner, msg.sender, amount0, amount1, fee0, fee1);
    }

    /// @notice Cancel an unfilled order and refund the parked asset.
    function cancel(uint256 orderId) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        LOBStorage storage $ = _s();
        Order storage o = $.orders[orderId];
        if (!o.active) revert UnknownOrder(orderId);
        if (msg.sender != o.owner) revert NotOwner();
        IBinPool p = IBinPool(o.pool);
        int32 active = p.activeId();
        bool isFilled = o.zeroForOne ? active >= o.binId : active <= o.binId;
        if (isFilled) revert OrderStillOpen(orderId);
        (amount0, amount1) = _exit(o, p);
        if (amount0 > 0) IERC20(p.token0()).safeTransfer(o.owner, amount0);
        if (amount1 > 0) IERC20(p.token1()).safeTransfer(o.owner, amount1);
        emit Cancelled(orderId, amount0, amount1);
    }

    /// @notice True once the active bin has reached/crossed the order bin.
    function filled(uint256 orderId) public view returns (bool) {
        Order storage o = _s().orders[orderId];
        if (!o.active) return false;
        IBinPool p = IBinPool(o.pool);
        int32 active = p.activeId();
        return o.zeroForOne ? active >= o.binId : active <= o.binId;
    }

    function _exit(Order storage o, IBinPool p) internal returns (uint256 amount0, uint256 amount1) {
        int32[] memory ids = new int32[](1);
        uint256[] memory sh = new uint256[](1);
        ids[0] = o.binId;
        sh[0] = o.shares;
        (uint256[] memory a0s, uint256[] memory a1s) = p.removeLiquidity(ids, sh, address(this));
        o.active = false;
        return (a0s[0], a1s[0]);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
