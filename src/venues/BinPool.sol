// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHub} from "../interfaces/IHub.sol";
import {IBinPool} from "../interfaces/IBinPool.sol";
import {BinPriceMath} from "../libraries/BinPriceMath.sol";
import {FeeMath} from "../libraries/FeeMath.sol";

/// @title Discrete-bin liquidity pool (beacon-proxied implementation).
/// @notice Liquidity sits in price bins; bin `id` trades at the fixed price
///         (1 + step)^id in Q64.96, so fills inside a single bin have zero
///         slippage. Bins above the active id hold token0; below hold token1.
///         Swap fees stay in the bins where they were earned, so per-bin share
///         price appreciates. Fees use the shared volatility model.
contract BinPool is IBinPool, Initializable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant MAX_SWAP_STEPS = 2_048; // bin-visits per swap (partial fill beyond)

    /// @custom:storage-location erc7201:binpool.storage.BinPool
    struct BinPoolStorage {
        IHub hub;
        address factory;
        address token0;
        address token1;
        uint16 binStepBps;
        int32 activeId;
        uint24 baseFeeBps;
        uint24 maxFeeBps;
        FeeMath.VolState vol;
        mapping(int32 => BinState) bins;
        mapping(int32 => mapping(address => uint256)) shares;
    }

    // ERC-7201 slot for "binpool.storage.BinPool"
    bytes32 private constant BINPOOL_STORAGE_SLOT = 0x2c87ce034c60e70bae16080c4dc2b7024cf3269639eb8b518d986f2b0d076500;

    function _s() private pure returns (BinPoolStorage storage $) {
        assembly {
            $.slot := BINPOOL_STORAGE_SLOT
        }
    }

    error Paused();
    error ZeroAddress();
    error IdenticalTokens();
    error LengthMismatch();
    error WrongSideAsset(int32 binId);
    error EmptyDeposit();
    error InsufficientShares();
    error InsufficientOutput(uint256 got, uint256 min);
    error InvalidAmount();

    event LiquidityAdded(address indexed to, int32[] ids, uint256[] shares, uint256 totalValueIn1);
    event LiquidityRemoved(address indexed from, int32[] ids, uint256[] shares, uint256 amount0, uint256 amount1);
    event Swap(
        address indexed sender,
        address indexed recipient,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountConsumed,
        uint256 amountOut,
        int32 activeIdAfter,
        uint24 feeBps
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address hub_, address tokenA, address tokenB, uint16 binStepBps_, int32 activeId_)
        external
        initializer
    {
        if (hub_ == address(0) || tokenA == address(0) || tokenB == address(0)) revert ZeroAddress();
        if (tokenA == tokenB) revert IdenticalTokens();
        __ReentrancyGuard_init();
        BinPoolStorage storage $ = _s();
        $.hub = IHub(hub_);
        $.factory = msg.sender;
        ($.token0, $.token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        $.binStepBps = binStepBps_;
        $.activeId = activeId_;
        $.baseFeeBps = 20; // 0.20%
        $.maxFeeBps = 2_000; // 20%
    }

    // ---------- views ----------

    function token0() external view returns (address) {
        return _s().token0;
    }

    function token1() external view returns (address) {
        return _s().token1;
    }

    function binStepBps() external view returns (uint16) {
        return _s().binStepBps;
    }

    function activeId() external view returns (int32) {
        return _s().activeId;
    }

    function hub() external view returns (address) {
        return address(_s().hub);
    }

    function factory() external view returns (address) {
        return _s().factory;
    }

    function feeConfig() external view returns (uint24 baseFeeBps, uint24 maxFeeBps) {
        return (_s().baseFeeBps, _s().maxFeeBps);
    }

    function priceOfBin(int32 id) public view returns (uint160) {
        return BinPriceMath.priceOfBin(_s().binStepBps, id);
    }

    function bin(int32 id) external view returns (BinState memory) {
        return _s().bins[id];
    }

    function sharesOf(int32 id, address account) external view returns (uint256) {
        return _s().shares[id][account];
    }

    function volInfo() external view returns (uint96 accumulator, uint160 lastPriceX96, uint64 lastTs) {
        FeeMath.VolState storage v = _s().vol;
        return (v.accumulator, v.lastPriceX96, v.lastTs);
    }

    function currentFeeBps() public view returns (uint24) {
        BinPoolStorage storage $ = _s();
        return FeeMath.dynamicFee($.baseFeeBps, $.maxFeeBps, $.vol.accumulator, $.hub.maxFeeBps());
    }

    /// @notice Current pool price (token1 per token0, Q64.96) = active bin price.
    function priceX96() external view returns (uint160) {
        return priceOfBin(_s().activeId);
    }

    // ---------- LP ----------

    function addLiquidity(int32[] calldata ids, uint256[] calldata amounts0, uint256[] calldata amounts1, address to)
        external
        nonReentrant
        returns (uint256[] memory sharesMinted)
    {
        BinPoolStorage storage $ = _s();
        if ($.hub.paused()) revert Paused();
        if (ids.length != amounts0.length || ids.length != amounts1.length) revert LengthMismatch();
        if (ids.length == 0) revert InvalidAmount();
        sharesMinted = new uint256[](ids.length);
        uint256 totalValue;
        uint256 sum0;
        uint256 sum1;
        for (uint256 i = 0; i < ids.length; i++) {
            int32 id = ids[i];
            uint256 a0 = amounts0[i];
            uint256 a1 = amounts1[i];
            if (id > $.activeId && a1 != 0) revert WrongSideAsset(id); // above active: token0 only
            if (id < $.activeId && a0 != 0) revert WrongSideAsset(id); // below active: token1 only
            uint160 p = priceOfBin(id);
            uint256 value = Math.mulDiv(a0, p, Q96) + a1; // numeraire: token1
            if (value == 0) revert EmptyDeposit();
            BinState storage b = $.bins[id];
            uint256 minted;
            if (b.totalShares == 0) {
                minted = value;
            } else {
                uint256 binValue = Math.mulDiv(b.reserve0, p, Q96) + b.reserve1;
                minted = Math.mulDiv(b.totalShares, value, binValue);
            }
            b.reserve0 += a0;
            b.reserve1 += a1;
            b.totalShares += minted;
            $.shares[id][to] += minted;
            sharesMinted[i] = minted;
            totalValue += value;
            sum0 += a0;
            sum1 += a1;
        }
        if (sum0 > 0) IERC20($.token0).safeTransferFrom(msg.sender, address(this), sum0);
        if (sum1 > 0) IERC20($.token1).safeTransferFrom(msg.sender, address(this), sum1);
        emit LiquidityAdded(to, ids, sharesMinted, totalValue);
    }

    function removeLiquidity(int32[] calldata ids, uint256[] calldata shares, address to)
        external
        nonReentrant
        returns (uint256[] memory amounts0, uint256[] memory amounts1)
    {
        BinPoolStorage storage $ = _s();
        if (ids.length != shares.length || ids.length == 0) revert LengthMismatch();
        amounts0 = new uint256[](ids.length);
        amounts1 = new uint256[](ids.length);
        uint256 total0;
        uint256 total1;
        for (uint256 i = 0; i < ids.length; i++) {
            BinState storage b = $.bins[ids[i]];
            if (shares[i] == 0 || shares[i] > $.shares[ids[i]][msg.sender]) revert InsufficientShares();
            uint256 out0 = Math.mulDiv(b.reserve0, shares[i], b.totalShares);
            uint256 out1 = Math.mulDiv(b.reserve1, shares[i], b.totalShares);
            b.reserve0 -= out0;
            b.reserve1 -= out1;
            b.totalShares -= shares[i];
            $.shares[ids[i]][msg.sender] -= shares[i];
            amounts0[i] = out0;
            amounts1[i] = out1;
            total0 += out0;
            total1 += out1;
        }
        if (total0 > 0) IERC20($.token0).safeTransfer(to, total0);
        if (total1 > 0) IERC20($.token1).safeTransfer(to, total1);
        emit LiquidityRemoved(msg.sender, ids, shares, total0, total1);
    }

    // ---------- swap ----------

    function swap(bool zeroForOne, uint256 amountIn, uint256 amountOutMin, address recipient)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        BinPoolStorage storage $ = _s();
        if ($.hub.paused()) revert Paused();
        if (amountIn == 0) revert InvalidAmount();
        uint24 feeBps = currentFeeBps();
        uint256 protocolBps = $.hub.protocolFeeBps();

        address tokenIn = zeroForOne ? $.token0 : $.token1;
        address tokenOut = zeroForOne ? $.token1 : $.token0;
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        uint256 remaining = amountIn;
        int32 cursor = $.activeId;
        bool consumedAny = false;
        uint256 totalOut;
        uint256 protocolDue;

        for (uint256 step = 0; step < MAX_SWAP_STEPS && remaining > 0; step++) {
            BinState storage b = $.bins[cursor];
            uint256 reserveOut = zeroForOne ? b.reserve1 : b.reserve0;
            if (reserveOut == 0) {
                if (cursor == (zeroForOne ? -BinPriceMath.MAX_BIN_ID : BinPriceMath.MAX_BIN_ID)) break;
                cursor += zeroForOne ? int32(-1) : int32(1);
                continue;
            }
            uint160 p = priceOfBin(cursor);
            uint256 netMax = (remaining * (10_000 - feeBps)) / 10_000;
            uint256 maxOut = zeroForOne ? Math.mulDiv(netMax, p, Q96) : Math.mulDiv(netMax, Q96, p);
            uint256 out = maxOut >= reserveOut ? reserveOut : maxOut;
            uint256 netIn = zeroForOne
                ? Math.mulDiv(out, Q96, p, Math.Rounding.Ceil)
                : Math.mulDiv(out, p, Q96, Math.Rounding.Ceil);
            uint256 grossIn = Math.mulDiv(netIn, 10_000, 10_000 - feeBps, Math.Rounding.Ceil);
            if (grossIn > remaining) {
                grossIn = remaining;
                netIn = (grossIn * (10_000 - feeBps)) / 10_000;
                out = zeroForOne ? Math.mulDiv(netIn, p, Q96) : Math.mulDiv(netIn, Q96, p);
            }
            // fee split: protocol cut leaves the pool, LP cut stays in the bin
            uint256 feeAmt = grossIn - netIn;
            uint256 protocolShare = Math.mulDiv(feeAmt, protocolBps, 10_000);
            uint256 credit = grossIn - protocolShare;
            if (zeroForOne) {
                b.reserve1 -= out;
                b.reserve0 += credit;
            } else {
                b.reserve0 -= out;
                b.reserve1 += credit;
            }
            protocolDue += protocolShare;
            totalOut += out;
            remaining -= grossIn;
            consumedAny = true;
            if (out == reserveOut) {
                if (cursor == (zeroForOne ? -BinPriceMath.MAX_BIN_ID : BinPriceMath.MAX_BIN_ID)) break;
                cursor += zeroForOne ? int32(-1) : int32(1);
            } else {
                break; // price rests inside this bin
            }
        }

        amountOut = totalOut;
        if (amountOut < amountOutMin) revert InsufficientOutput(amountOut, amountOutMin);

        if (consumedAny) {
            $.activeId = cursor;
        }

        if (protocolDue > 0) IERC20(tokenIn).safeTransfer($.hub.feeRecipient(), protocolDue);
        if (remaining > 0) IERC20(tokenIn).safeTransfer(msg.sender, remaining); // refund unfilled input
        if (amountOut > 0) IERC20(tokenOut).safeTransfer(recipient, amountOut);

        // volatility update on the post-trade bin price
        uint160 priceAfter = priceOfBin($.activeId);
        FeeMath.VolState storage v = $.vol;
        v.accumulator = FeeMath.update(v, priceAfter, FeeMath.DEFAULT_DECAY_WINDOW);
        v.lastPriceX96 = priceAfter;
        v.lastTs = uint64(block.timestamp);

        emit Swap(msg.sender, recipient, zeroForOne, amountIn, amountIn - remaining, amountOut, $.activeId, feeBps);
    }

    // ---------- quote ----------

    function getAmountOut(bool zeroForOne, uint256 amountIn) external view returns (uint256 amountOut) {
        BinPoolStorage storage $ = _s();
        if (amountIn == 0) return 0;
        uint24 feeBps = currentFeeBps();
        uint256 remaining = amountIn;
        int32 cursor = $.activeId;
        for (uint256 step = 0; step < MAX_SWAP_STEPS && remaining > 0; step++) {
            BinState storage b = $.bins[cursor];
            uint256 reserveOut = zeroForOne ? b.reserve1 : b.reserve0;
            if (reserveOut == 0) {
                if (cursor == (zeroForOne ? -BinPriceMath.MAX_BIN_ID : BinPriceMath.MAX_BIN_ID)) break;
                cursor += zeroForOne ? int32(-1) : int32(1);
                continue;
            }
            uint160 p = priceOfBin(cursor);
            uint256 netMax = (remaining * (10_000 - feeBps)) / 10_000;
            uint256 maxOut = zeroForOne ? Math.mulDiv(netMax, p, Q96) : Math.mulDiv(netMax, Q96, p);
            uint256 out = maxOut >= reserveOut ? reserveOut : maxOut;
            uint256 netIn = zeroForOne
                ? Math.mulDiv(out, Q96, p, Math.Rounding.Ceil)
                : Math.mulDiv(out, p, Q96, Math.Rounding.Ceil);
            uint256 grossIn = Math.mulDiv(netIn, 10_000, 10_000 - feeBps, Math.Rounding.Ceil);
            if (grossIn > remaining) {
                grossIn = remaining;
                netIn = (grossIn * (10_000 - feeBps)) / 10_000;
                out = zeroForOne ? Math.mulDiv(netIn, p, Q96) : Math.mulDiv(netIn, Q96, p);
            }
            amountOut += out;
            remaining -= grossIn;
            if (out == reserveOut) {
                if (cursor == (zeroForOne ? -BinPriceMath.MAX_BIN_ID : BinPriceMath.MAX_BIN_ID)) break;
                cursor += zeroForOne ? int32(-1) : int32(1);
            } else {
                break;
            }
        }
    }
}
