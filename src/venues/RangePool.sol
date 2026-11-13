// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHub} from "../interfaces/IHub.sol";
import {IRangePool} from "../interfaces/IRangePool.sol";
import {FeeMath} from "../libraries/FeeMath.sol";

/// @title Single-range pool (beacon-proxied implementation).
/// @notice One dynamic band [anchor*(1-r), anchor*(1+r)] per pool (default ±12%).
///         v3-style math inside the band; swaps stop at the band edge with a
///         partial fill and refund. Shares are fungible (first mint = sqrt(x*y));
///         fees compound per share through an accumulator and are claimable any
///         time. An optional launch fee starts high and decays to the base fee
///         over the launch window, then the shared volatility model applies.
contract RangePool is IRangePool, Initializable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    uint256 internal constant Q96 = 1 << 96;

    /// @custom:storage-location erc7201:rangepool.storage.RangePool
    struct RangePoolStorage {
        IHub hub;
        address factory;
        address token0;
        address token1;
        uint160 sqrtPriceX96;
        uint160 sqrtLowerX96;
        uint160 sqrtUpperX96;
        uint128 liquidity;
        uint128 totalShares;
        mapping(address => uint256) shares;
        mapping(address => uint256) claimedFees0;
        mapping(address => uint256) claimedFees1;
        uint256 feeGrowth0X128;
        uint256 feeGrowth1X128;
        uint24 baseFeeBps;
        uint24 maxFeeBps;
        uint24 launchFeeStartBps;
        uint32 launchWindow;
        uint64 createdAt;
        FeeMath.VolState vol;
    }

    // ERC-7201 slot for "rangepool.storage.RangePool"
    bytes32 private constant RANGEPOOL_STORAGE_SLOT = 0xd8152820c5303f8ae25747626fa9d7f65506a29707e6c4c5c88cb5f2a8da9400;

    function _s() private pure returns (RangePoolStorage storage $) {
        assembly {
            $.slot := RANGEPOOL_STORAGE_SLOT
        }
    }

    error Paused();
    error ZeroAddress();
    error InvalidRange();
    error InvalidSide(); // deposit on a side that is empty at the band edge
    error InsufficientShares();
    error InsufficientSharesMinted(uint256 got, uint256 min);
    error InsufficientOutput(uint256 got, uint256 min);
    error InvalidAmount();
    error ZeroLiquidity();

    event LiquidityAdded(address indexed to, uint256 shares, uint256 amount0, uint256 amount1);
    event LiquidityRemoved(address indexed from, uint256 shares, uint256 amount0, uint256 amount1);
    event FeesClaimed(address indexed to, uint256 amount0, uint256 amount1);
    event Swap(
        address indexed sender,
        address indexed recipient,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountConsumed,
        uint256 amountOut,
        uint160 sqrtPriceX96,
        uint24 feeBps
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address hub_,
        address tokenA,
        address tokenB,
        uint160 sqrtPriceX96_,
        uint24 rangeBps,
        uint24 baseFeeBps_,
        uint24 launchFeeStartBps_,
        uint32 launchWindow_
    ) external initializer {
        if (hub_ == address(0) || tokenA == address(0) || tokenB == address(0)) revert ZeroAddress();
        if (rangeBps == 0 || rangeBps > 5_000) revert InvalidRange();
        if (sqrtPriceX96_ == 0) revert ZeroAddress();
        __ReentrancyGuard_init();
        RangePoolStorage storage $ = _s();
        $.hub = IHub(hub_);
        $.factory = msg.sender;
        ($.token0, $.token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        $.sqrtPriceX96 = sqrtPriceX96_;
        // band edges: anchor * (1 +/- range)
        uint256 anchor = sqrtPriceX96_;
        $.sqrtUpperX96 = uint160(anchor + Math.mulDiv(anchor, rangeBps, 10_000));
        $.sqrtLowerX96 = uint160(anchor - Math.mulDiv(anchor, rangeBps, 10_000));
        $.baseFeeBps = baseFeeBps_;
        $.maxFeeBps = 2_000;
        $.launchFeeStartBps = launchFeeStartBps_;
        $.launchWindow = launchWindow_;
        $.createdAt = uint64(block.timestamp);
    }

    // ---------- views ----------

    function token0() external view returns (address) {
        return _s().token0;
    }

    function token1() external view returns (address) {
        return _s().token1;
    }

    function hub() external view returns (address) {
        return address(_s().hub);
    }

    function factory() external view returns (address) {
        return _s().factory;
    }

    function sqrtPriceX96() external view returns (uint160) {
        return _s().sqrtPriceX96;
    }

    function band() external view returns (uint160 sqrtLowerX96, uint160 sqrtUpperX96) {
        return (_s().sqrtLowerX96, _s().sqrtUpperX96);
    }

    function liquidity() external view returns (uint128) {
        return _s().liquidity;
    }

    function totalShares() external view returns (uint256) {
        return _s().totalShares;
    }

    function sharesOf(address account) external view returns (uint256) {
        return _s().shares[account];
    }

    function reserve0() external view returns (uint256) {
        RangePoolStorage storage $ = _s();
        return _amount0($.liquidity, $.sqrtPriceX96, $.sqrtUpperX96);
    }

    function reserve1() external view returns (uint256) {
        RangePoolStorage storage $ = _s();
        return _amount1($.liquidity, $.sqrtPriceX96, $.sqrtLowerX96);
    }

    function feeConfig()
        external
        view
        returns (uint24 baseFeeBps, uint24 maxFeeBps, uint24 launchFeeStartBps, uint32 launchWindow, uint64 createdAt)
    {
        RangePoolStorage storage $ = _s();
        return ($.baseFeeBps, $.maxFeeBps, $.launchFeeStartBps, $.launchWindow, $.createdAt);
    }

    function launchFeeBps() external view returns (uint24) {
        RangePoolStorage storage $ = _s();
        return FeeMath.launchFee($.baseFeeBps, $.launchFeeStartBps, $.launchWindow, $.createdAt);
    }

    function currentFeeBps() public view returns (uint24) {
        RangePoolStorage storage $ = _s();
        uint24 hubCap = $.hub.maxFeeBps();
        if ($.launchFeeStartBps > 0 && block.timestamp < $.createdAt + $.launchWindow) {
            uint24 f = FeeMath.launchFee($.baseFeeBps, $.launchFeeStartBps, $.launchWindow, $.createdAt);
            return f > hubCap ? hubCap : f;
        }
        return FeeMath.dynamicFee($.baseFeeBps, $.maxFeeBps, $.vol.accumulator, hubCap);
    }

    function volInfo() external view returns (uint96 accumulator, uint160 lastPriceX96, uint64 lastTs) {
        FeeMath.VolState storage v = _s().vol;
        return (v.accumulator, v.lastPriceX96, v.lastTs);
    }

    function claimableFees(address account) external view returns (uint256 amount0, uint256 amount1) {
        RangePoolStorage storage $ = _s();
        uint256 sh = $.shares[account];
        amount0 = Math.mulDiv(sh, $.feeGrowth0X128, 1 << 128) - $.claimedFees0[account];
        amount1 = Math.mulDiv(sh, $.feeGrowth1X128, 1 << 128) - $.claimedFees1[account];
    }

    // ---------- LP ----------

    function addLiquidity(uint256 amount0Desired, uint256 amount1Desired, uint256 minShares, address to)
        external
        nonReentrant
        returns (uint256 shares)
    {
        RangePoolStorage storage $ = _s();
        if ($.hub.paused()) revert Paused();
        uint128 dL = _deltaLiquidityFor(amount0Desired, amount1Desired);
        if (dL == 0) revert InvalidAmount();
        uint256 a0 = _amount0(dL, $.sqrtPriceX96, $.sqrtUpperX96);
        uint256 a1 = _amount1(dL, $.sqrtPriceX96, $.sqrtLowerX96);
        if ($.totalShares == 0) {
            shares = Math.sqrt(a0 * a1); // 1 share = 1 L at inception
            if (shares == 0) shares = dL; // degenerate single-sided seed
        } else {
            shares = Math.mulDiv($.totalShares, dL, $.liquidity);
        }
        if (shares < minShares) revert InsufficientSharesMinted(shares, minShares);
        $.liquidity += dL;
        $.totalShares += uint128(shares);
        $.shares[to] += shares;
        if (a0 > 0) IERC20($.token0).safeTransferFrom(msg.sender, address(this), a0);
        if (a1 > 0) IERC20($.token1).safeTransferFrom(msg.sender, address(this), a1);
        emit LiquidityAdded(to, shares, a0, a1);
    }

    function removeLiquidity(uint256 shares, uint256 amount0Min, uint256 amount1Min, address to)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        RangePoolStorage storage $ = _s();
        if (shares == 0 || shares > $.shares[msg.sender]) revert InsufficientShares();
        // claim accrued fees on the full share balance BEFORE decrementing
        (uint256 f0, uint256 f1) = _claimFees(msg.sender, to);
        uint128 dL = uint128(Math.mulDiv($.liquidity, shares, $.totalShares));
        amount0 = _amount0(dL, $.sqrtPriceX96, $.sqrtUpperX96);
        amount1 = _amount1(dL, $.sqrtPriceX96, $.sqrtLowerX96);
        if (amount0 < amount0Min) revert InsufficientOutput(amount0, amount0Min);
        if (amount1 < amount1Min) revert InsufficientOutput(amount1, amount1Min);
        $.liquidity -= dL;
        $.totalShares -= uint128(shares);
        $.shares[msg.sender] -= shares;
        amount0 += f0;
        amount1 += f1;
        if (amount0 > 0) IERC20($.token0).safeTransfer(to, amount0);
        if (amount1 > 0) IERC20($.token1).safeTransfer(to, amount1);
        emit LiquidityRemoved(msg.sender, shares, amount0, amount1);
    }

    function claimFees(address to) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        RangePoolStorage storage $ = _s();
        (amount0, amount1) = _claimFees(msg.sender, to);
        if (amount0 > 0) IERC20($.token0).safeTransfer(to, amount0);
        if (amount1 > 0) IERC20($.token1).safeTransfer(to, amount1);
        emit FeesClaimed(to, amount0, amount1);
    }

    // ---------- swap ----------

    function swap(bool zeroForOne, uint256 amountIn, uint256 amountOutMin, address recipient)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        RangePoolStorage storage $ = _s();
        if ($.hub.paused()) revert Paused();
        if (amountIn == 0) revert InvalidAmount();
        if ($.liquidity == 0) revert ZeroLiquidity();

        uint24 feeBps = currentFeeBps();
        uint256 protocolBps = $.hub.protocolFeeBps();
        uint256 feeAmount = (amountIn * feeBps) / 10_000; // upper bound; recomputed on the consumed part
        uint256 netIn = amountIn - feeAmount;

        address tokenIn = zeroForOne ? $.token0 : $.token1;
        address tokenOut = zeroForOne ? $.token1 : $.token0;
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        uint160 sqrtP = $.sqrtPriceX96;
        uint128 L = $.liquidity;
        uint256 netUsed = netIn;
        uint160 sqrtAfter;

        if (zeroForOne) {
            // token0 in -> price falls toward sqrtLower; capacity in token0 to reach the edge
            uint256 capacity = Math.mulDiv(uint256(L) << 96, sqrtP - $.sqrtLowerX96, uint256(sqrtP) * $.sqrtLowerX96);
            if (netUsed > capacity) netUsed = capacity;
            if (netUsed == capacity) {
                sqrtAfter = $.sqrtLowerX96;
                amountOut = _amount1(L, sqrtP, $.sqrtLowerX96); // entire token1 side
            } else {
                sqrtAfter = _sqrtAfterToken0In(sqrtP, L, netUsed);
                amountOut = Math.mulDiv(L, sqrtP - sqrtAfter, Q96); // L * (a - a')/2^96
            }
        } else {
            // token1 in -> price rises toward sqrtUpper; capacity in token1
            uint256 capacity = Math.mulDiv(uint256($.sqrtUpperX96) - sqrtP, L, Q96);
            if (netUsed > capacity) netUsed = capacity;
            if (netUsed == capacity) {
                sqrtAfter = $.sqrtUpperX96;
                amountOut = _amount0(L, sqrtP, $.sqrtUpperX96); // entire token0 side
            } else {
                sqrtAfter = uint160(uint256(sqrtP) + Math.mulDiv(netUsed, Q96, L));
                amountOut = Math.mulDiv(uint256(L) << 96, sqrtAfter - sqrtP, uint256(sqrtP) * sqrtAfter);
            }
        }
        if (amountOut < amountOutMin) revert InsufficientOutput(amountOut, amountOutMin);

        $.sqrtPriceX96 = sqrtAfter;

        // gross input consumed = net + fee on the consumed part only (partial fills
        // at the band edge do not pay fees on the refunded remainder)
        uint256 grossUsed = Math.mulDiv(netUsed, 10_000, 10_000 - feeBps, Math.Rounding.Ceil);
        if (grossUsed > amountIn) grossUsed = amountIn;
        feeAmount = grossUsed - netUsed;

        // fee accounting: protocol cut out; LP cut per-share accumulator
        if (feeAmount > 0) {
            uint256 protocolCut = Math.mulDiv(feeAmount, protocolBps, 10_000);
            uint256 lpCut = feeAmount - protocolCut;
            if (protocolCut > 0) IERC20(tokenIn).safeTransfer($.hub.feeRecipient(), protocolCut);
            if (lpCut > 0 && $.totalShares > 0) {
                if (zeroForOne) {
                    $.feeGrowth0X128 += Math.mulDiv(lpCut, 1 << 128, $.totalShares);
                } else {
                    $.feeGrowth1X128 += Math.mulDiv(lpCut, 1 << 128, $.totalShares);
                }
            }
        }

        uint256 refund = amountIn - grossUsed;
        if (refund > 0) IERC20(tokenIn).safeTransfer(msg.sender, refund);
        if (amountOut > 0) IERC20(tokenOut).safeTransfer(recipient, amountOut);

        // volatility update
        FeeMath.VolState storage v = $.vol;
        v.accumulator = FeeMath.update(v, sqrtAfter, FeeMath.DEFAULT_DECAY_WINDOW);
        v.lastPriceX96 = sqrtAfter;
        v.lastTs = uint64(block.timestamp);

        emit Swap(msg.sender, recipient, zeroForOne, amountIn, grossUsed, amountOut, sqrtAfter, feeBps);
    }

    // ---------- quote ----------

    function getAmountOut(bool zeroForOne, uint256 amountIn) external view returns (uint256 amountOut) {
        RangePoolStorage storage $ = _s();
        if (amountIn == 0 || $.liquidity == 0) return 0;
        uint24 feeBps = currentFeeBps();
        uint256 netIn = amountIn - (amountIn * feeBps) / 10_000;
        uint160 sqrtP = $.sqrtPriceX96;
        uint128 L = $.liquidity;
        if (zeroForOne) {
            uint256 capacity = Math.mulDiv(uint256(L) << 96, sqrtP - $.sqrtLowerX96, uint256(sqrtP) * $.sqrtLowerX96);
            if (netIn > capacity) netIn = capacity;
            if (netIn == capacity) return _amount1(L, sqrtP, $.sqrtLowerX96);
            uint160 sqrtAfter = _sqrtAfterToken0In(sqrtP, L, netIn);
            return Math.mulDiv(L, sqrtP - sqrtAfter, Q96);
        } else {
            uint256 capacity = Math.mulDiv(uint256($.sqrtUpperX96) - sqrtP, L, Q96);
            if (netIn > capacity) netIn = capacity;
            if (netIn == capacity) return _amount0(L, sqrtP, $.sqrtUpperX96);
            uint160 sqrtAfter = uint160(uint256(sqrtP) + Math.mulDiv(netIn, Q96, L));
            return Math.mulDiv(uint256(L) << 96, sqrtAfter - sqrtP, uint256(sqrtP) * sqrtAfter);
        }
    }

    /// @notice Exact token1 amount paired with `amount0` for a band-ratio deposit.
    function pairedAmount1For0(uint256 amount0) external view returns (uint256) {
        RangePoolStorage storage $ = _s();
        // dy/dx = (sqrtP - sqrtLow) * sqrtP * sqrtUp / (2^192 * (sqrtUp - sqrtP))
        uint256 t = Math.mulDiv(uint256($.sqrtPriceX96) - $.sqrtLowerX96, $.sqrtPriceX96, uint256($.sqrtUpperX96) - $.sqrtPriceX96);
        uint256 ratioQ96 = Math.mulDiv(t, $.sqrtUpperX96, Q96);
        return Math.mulDiv(amount0, ratioQ96, Q96);
    }

    // ---------- internals ----------

    /// @dev x = L * 2^96 * (sqrtUp - sqrtP) / (sqrtP * sqrtUp)
    function _amount0(uint128 L, uint160 sqrtP, uint160 sqrtUp) internal pure returns (uint256) {
        if (sqrtP >= sqrtUp) return 0;
        return Math.mulDiv(uint256(L) << 96, sqrtUp - sqrtP, uint256(sqrtP) * sqrtUp);
    }

    /// @dev y = L * (sqrtP - sqrtLow) / 2^96
    function _amount1(uint128 L, uint160 sqrtP, uint160 sqrtLow) internal pure returns (uint256) {
        if (sqrtP <= sqrtLow) return 0;
        return Math.mulDiv(L, sqrtP - sqrtLow, Q96);
    }

    /// @dev sqrtP' = (L<<96)*sqrtP / ((L<<96) + net0*sqrtP), rounding up.
    function _sqrtAfterToken0In(uint160 sqrtP, uint128 L, uint256 net0) internal pure returns (uint160) {
        uint256 denom = (uint256(L) << 96) + Math.mulDiv(net0, sqrtP, 1);
        return uint160(Math.mulDiv(uint256(L) << 96, sqrtP, denom, Math.Rounding.Ceil));
    }

    /// @dev Max liquidity addable for the given desired amounts at the current price.
    function _deltaLiquidityFor(uint256 desired0, uint256 desired1) private view returns (uint128) {
        RangePoolStorage storage $ = _s();
        uint160 sqrtP = $.sqrtPriceX96;
        uint256 d0 = uint256($.sqrtUpperX96) - sqrtP; // > 0 while inside band
        uint256 d1 = uint256(sqrtP) - $.sqrtLowerX96;
        uint256 dL0;
        uint256 dL1;
        if (desired0 > 0) {
            if (d0 == 0) revert InvalidSide();
            // dL = desired0 * sqrtP * sqrtUp / ((sqrtUp - sqrtP) << 96)
            dL0 = Math.mulDiv(Math.mulDiv(desired0, sqrtP, 1), $.sqrtUpperX96, d0 << 96);
        }
        if (desired1 > 0) {
            if (d1 == 0) revert InvalidSide();
            dL1 = Math.mulDiv(desired1, Q96, d1);
        }
        uint256 dL = dL0 == 0 ? dL1 : (dL1 == 0 ? dL0 : Math.min(dL0, dL1));
        return uint128(dL);
    }

    function _claimFees(address from, address to) private returns (uint256 amount0, uint256 amount1) {
        RangePoolStorage storage $ = _s();
        uint256 sh = $.shares[from];
        amount0 = Math.mulDiv(sh, $.feeGrowth0X128, 1 << 128) - $.claimedFees0[from];
        amount1 = Math.mulDiv(sh, $.feeGrowth1X128, 1 << 128) - $.claimedFees1[from];
        $.claimedFees0[from] += amount0;
        $.claimedFees1[from] += amount1;
        // quiet unused-var warning pattern
        to;
    }
}
