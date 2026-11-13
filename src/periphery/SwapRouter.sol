// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IHub} from "../interfaces/IHub.sol";
import {IPoolManager} from "../interfaces/IPoolManager.sol";
import {IBinPool} from "../interfaces/IBinPool.sol";
import {IRangePool} from "../interfaces/IRangePool.sol";
import {IWETH} from "../interfaces/IWETH.sol";

/// @title Exact-input smart router across hook (v4-style), bin and range venues.
/// @notice `quoteExactIn` simulates every direct pool plus two-hop paths through
///         registered intermediates (eth_call-safe) and returns the best route;
///         `execute` settles the route atomically with minOut + deadline guards.
///         Execution re-simulates nothing: each venue enforces its own math and
///         the final minOut reverts the whole transaction if breached.
contract SwapRouter is UUPSUpgradeable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    enum Venue {
        Hook, // 0
        Bin, // 1
        Range // 2
    }

    struct Hop {
        Venue venue;
        address pool; // bin/range pool address; hook: PoolManager address
        bytes32 poolId; // hook pool id (bin/range: 0)
        address tokenIn;
        address tokenOut;
        uint24 feeBps; // informational: quoted fee of this leg
    }

    struct Route {
        Hop[] hops;
        uint256 amountOut;
    }

    /// @custom:storage-location erc7201:swaprouter.storage.SwapRouter
    struct RouterStorage {
        IHub hub;
        IPoolManager manager;
        IWETH weth;
        address[] intermediates;
    }

    // ERC-7201 slot for "swaprouter.storage.SwapRouter"
    bytes32 private constant ROUTER_STORAGE_SLOT = 0x4d883da31a7cb6b858b750d801f37a27c75e5dd79db5d5a19f212c4126ea5f00;

    function _s() private pure returns (RouterStorage storage $) {
        assembly {
            $.slot := ROUTER_STORAGE_SLOT
        }
    }

    error ZeroAddress();
    error BadRoute();
    error Expired(uint256 deadline);
    error InsufficientOutput(uint256 got, uint256 min);
    error ZeroAmount();
    error EthMismatch();

    event RouteExecuted(
        address indexed sender, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut, uint8 hopCount
    );
    event IntermediateAdded(address token);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address hub_, address manager_, address weth_, address admin) external initializer {
        if (hub_ == address(0) || manager_ == address(0) || weth_ == address(0) || admin == address(0)) {
            revert ZeroAddress();
        }
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        RouterStorage storage $ = _s();
        $.hub = IHub(hub_);
        $.manager = IPoolManager(manager_);
        $.weth = IWETH(weth_);
        $.intermediates.push(weth_);
    }

    function addIntermediate(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        _s().intermediates.push(token);
        emit IntermediateAdded(token);
    }

    function weth() external view returns (address) {
        return address(_s().weth);
    }

    function intermediates() external view returns (address[] memory) {
        return _s().intermediates;
    }

    // ---------- quoting ----------

    /// @notice Best exact-in route: direct pools on the pair plus two-hop paths
    ///         through every registered intermediate. eth_call-safe.
    function quoteExactIn(address tokenIn, uint256 amountIn, address tokenOut)
        external
        view
        returns (Route memory best)
    {
        RouterStorage storage $ = _s();
        if (amountIn == 0) revert ZeroAmount();

        best = _bestRoute(tokenIn, amountIn, tokenOut);
        if (tokenIn != tokenOut) {
            for (uint256 m = 0; m < $.intermediates.length; m++) {
                address mid = $.intermediates[m];
                if (mid == tokenIn || mid == tokenOut) continue;
                Route memory first = _bestRoute(tokenIn, amountIn, mid);
                if (first.amountOut == 0) continue;
                Route memory second = _bestRoute(mid, first.amountOut, tokenOut);
                if (second.amountOut == 0) continue;
                if (second.amountOut > best.amountOut) {
                    best = _joinRoutes(first, second);
                }
            }
        }
    }

    /// @dev Best single-hop route for a pair across all venues.
    function _bestRoute(address tokenIn, uint256 amountIn, address tokenOut)
        internal
        view
        returns (Route memory best)
    {
        RouterStorage storage $ = _s();

        // hook pools (singleton holds one address, many poolIds)
        bytes32[] memory hookPools = $.manager.poolIdsForPair(tokenIn, tokenOut);
        for (uint256 i = 0; i < hookPools.length; i++) {
            (address t0,) = $.manager.poolTokens(hookPools[i]);
            bool zeroForOne = t0 == tokenIn;
            try $.manager.getAmountOut(hookPools[i], zeroForOne, amountIn) returns (uint256 out, uint24 fee) {
                if (out > best.amountOut) {
                    best = _singleHopRoute(Venue.Hook, address($.manager), hookPools[i], tokenIn, tokenOut, fee, out);
                }
            } catch {}
        }

        // bin / range pools
        address[] memory pools = $.hub.pairPools(tokenIn, tokenOut);
        for (uint256 i = 0; i < pools.length; i++) {
            uint8 venue = $.hub.poolVenue(pools[i]);
            if (venue == 1) continue; // hook singleton handled above
            try this._quoteVenue(pools[i], venue, tokenIn, amountIn) returns (uint256 out, uint24 fee) {
                if (out > best.amountOut) {
                    best = _singleHopRoute(
                        venue == 2 ? Venue.Bin : Venue.Range, pools[i], bytes32(0), tokenIn, tokenOut, fee, out
                    );
                }
            } catch {}
        }
    }

    /// @dev Quote one bin/range pool (external for try/catch isolation).
    function _quoteVenue(address pool, uint8 venue, address tokenIn, uint256 amountIn)
        external
        view
        returns (uint256 out, uint24 fee)
    {
        if (venue == 2) {
            IBinPool p = IBinPool(pool);
            out = p.getAmountOut(p.token0() == tokenIn, amountIn);
            fee = p.currentFeeBps();
        } else if (venue == 3) {
            IRangePool p = IRangePool(pool);
            out = p.getAmountOut(p.token0() == tokenIn, amountIn);
            fee = p.currentFeeBps();
        }
    }

    function _singleHopRoute(
        Venue venue,
        address pool,
        bytes32 poolId,
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 out
    ) internal pure returns (Route memory r) {
        r.hops = new Hop[](1);
        r.hops[0] = Hop(venue, pool, poolId, tokenIn, tokenOut, fee);
        r.amountOut = out;
    }

    function _joinRoutes(Route memory first, Route memory second) internal pure returns (Route memory r) {
        r.hops = new Hop[](2);
        r.hops[0] = first.hops[0];
        r.hops[1] = second.hops[0];
        r.amountOut = second.amountOut;
    }

    // ---------- execution ----------

    /// @notice Execute a quoted route with exact input (ERC-20 in / ERC-20 out).
    function execute(Route calldata route, uint256 amountIn, uint256 minOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (block.timestamp > deadline) revert Expired(deadline);
        RouterStorage storage $ = _s();
        IERC20(route.hops[0].tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        amountOut = _runHops(msg.sender, route, amountIn, minOut);
        $.weth; // keep storage reference alive for symmetry
    }

    /// @notice Execute with ETH input (wraps to WETH for the first hop).
    function executeETHIn(Route calldata route, uint256 minOut, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 amountOut)
    {
        if (block.timestamp > deadline) revert Expired(deadline);
        RouterStorage storage $ = _s();
        if (route.hops.length == 0 || route.hops[0].tokenIn != address($.weth)) revert BadRoute();
        uint256 amountIn = msg.value;
        $.weth.deposit{value: amountIn}();
        amountOut = _runHops(msg.sender, route, amountIn, minOut);
    }

    /// @notice Execute with ETH output (unwraps the final WETH leg).
    function executeETHOut(Route calldata route, uint256 amountIn, uint256 minOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 amountOutEth)
    {
        if (block.timestamp > deadline) revert Expired(deadline);
        RouterStorage storage $ = _s();
        if (route.hops.length == 0 || route.hops[route.hops.length - 1].tokenOut != address($.weth)) {
            revert BadRoute();
        }
        IERC20(route.hops[0].tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 out = _runHops(msg.sender, route, amountIn, minOut);
        $.weth.withdraw(out);
        (bool ok,) = msg.sender.call{value: out}("");
        if (!ok) revert EthMismatch();
        return out;
    }

    function _runHops(address user, Route calldata route, uint256 amountIn, uint256 minOut)
        internal
        returns (uint256 amountOut)
    {
        RouterStorage storage $ = _s();
        if (route.hops.length == 0 || route.hops.length > 2) revert BadRoute();
        uint256 amount = amountIn;
        for (uint256 i = 0; i < route.hops.length; i++) {
            Hop calldata hop = route.hops[i];
            if (hop.venue == Venue.Hook) {
                (address t0,) = $.manager.poolTokens(hop.poolId);
                IERC20(hop.tokenIn).forceApprove(hop.pool, amount);
                amount = $.manager.swap(hop.poolId, t0 == hop.tokenIn, amount, 0, address(this));
            } else if (hop.venue == Venue.Bin) {
                IERC20(hop.tokenIn).forceApprove(hop.pool, amount);
                amount = IBinPool(hop.pool).swap(IBinPool(hop.pool).token0() == hop.tokenIn, amount, 0, address(this));
            } else if (hop.venue == Venue.Range) {
                IERC20(hop.tokenIn).forceApprove(hop.pool, amount);
                amount =
                    IRangePool(hop.pool).swap(IRangePool(hop.pool).token0() == hop.tokenIn, amount, 0, address(this));
            } else {
                revert BadRoute();
            }
        }
        amountOut = amount;
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
        IERC20(route.hops[route.hops.length - 1].tokenOut).safeTransfer(user, amountOut);
        emit RouteExecuted(
            user,
            route.hops[0].tokenIn,
            route.hops[route.hops.length - 1].tokenOut,
            amountIn,
            amountOut,
            uint8(route.hops.length)
        );
    }

    receive() external payable {
        if (msg.sender != address(_s().weth)) revert EthMismatch();
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
