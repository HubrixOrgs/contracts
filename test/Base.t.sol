// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Hub} from "../src/core/Hub.sol";
import {PoolManager} from "../src/core/PoolManager.sol";
import {PoolHook} from "../src/core/PoolHook.sol";
import {PositionManager} from "../src/core/PositionManager.sol";
import {BinPool} from "../src/venues/BinPool.sol";
import {BinPoolFactory} from "../src/venues/BinPoolFactory.sol";
import {RangePool} from "../src/venues/RangePool.sol";
import {RangePoolFactory} from "../src/venues/RangePoolFactory.sol";
import {SwapRouter} from "../src/periphery/SwapRouter.sol";
import {LimitOrderBook} from "../src/periphery/LimitOrderBook.sol";
import {TokenLaunchpad} from "../src/periphery/TokenLaunchpad.sol";
import {LendingVault} from "../src/periphery/LendingVault.sol";
import {CreditManager} from "../src/periphery/CreditManager.sol";
import {WETH} from "../src/mocks/WETH.sol";
import {TestToken} from "../src/mocks/TestToken.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";

/// @dev Shared local deployment of the full stack (proxied, mirroring Deploy.s.sol).
abstract contract Base is Test {
    Hub hub;
    PoolManager manager;
    PoolHook hook;
    PositionManager positions;
    BinPoolFactory binFactory;
    RangePoolFactory rangeFactory;
    SwapRouter router;
    LimitOrderBook lob;
    TokenLaunchpad launchpad;
    LendingVault vault;
    CreditManager credit;
    WETH weth;
    TestToken usdx;
    TestToken stok;
    MockOracle oracle;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice"); // LP / trader
    address bob = makeAddr("bob"); // trader / keeper
    address keeper = makeAddr("keeper");

    uint256 constant Q96 = 1 << 96;

    function setUp() public virtual {
        vm.startPrank(admin);
        weth = new WETH();
        usdx = new TestToken("Test USD Stable", "USDX");
        stok = new TestToken("Test Stock Token", "STOK");
        oracle = new MockOracle();

        hub = Hub(address(new ERC1967Proxy(address(new Hub()), abi.encodeCall(Hub.initialize, (admin, admin)))));
        manager = PoolManager(
            address(new ERC1967Proxy(address(new PoolManager()), abi.encodeCall(PoolManager.initialize, (address(hub), admin))))
        );
        hook = PoolHook(
            address(new ERC1967Proxy(address(new PoolHook()), abi.encodeCall(PoolHook.initialize, (address(hub), admin))))
        );
        hook.setManager(address(manager));
        positions = PositionManager(
            address(
                new ERC1967Proxy(
                    address(new PositionManager()),
                    abi.encodeCall(PositionManager.initialize, (address(hub), address(manager), admin))
                )
            )
        );
        manager.setPositionManager(address(positions));

        binFactory = BinPoolFactory(
            address(
                new ERC1967Proxy(
                    address(new BinPoolFactory()),
                    abi.encodeCall(BinPoolFactory.initialize, (address(hub), address(new BinPool()), admin))
                )
            )
        );
        rangeFactory = RangePoolFactory(
            address(
                new ERC1967Proxy(
                    address(new RangePoolFactory()),
                    abi.encodeCall(RangePoolFactory.initialize, (address(hub), address(new RangePool()), admin))
                )
            )
        );

        lob = LimitOrderBook(
            address(
                new ERC1967Proxy(address(new LimitOrderBook()), abi.encodeCall(LimitOrderBook.initialize, (address(hub), admin)))
            )
        );
        router = SwapRouter(
            payable(
                address(
                    new ERC1967Proxy(
                        address(new SwapRouter()),
                        abi.encodeCall(SwapRouter.initialize, (address(hub), address(manager), address(weth), admin))
                    )
                )
            )
        );
        vault = LendingVault(
            address(
                new ERC1967Proxy(
                    address(new LendingVault()), abi.encodeCall(LendingVault.initialize, (address(usdx), admin, admin))
                )
            )
        );
        credit = CreditManager(
            address(
                new ERC1967Proxy(
                    address(new CreditManager()),
                    abi.encodeCall(
                        CreditManager.initialize,
                        (address(hub), address(vault), address(positions), address(manager), admin)
                    )
                )
            )
        );
        vault.setCreditManager(address(credit));
        positions.setCreditManager(address(credit));
        launchpad = TokenLaunchpad(payable(
            address(
                new ERC1967Proxy(
                    address(new TokenLaunchpad()),
                    abi.encodeCall(
                        TokenLaunchpad.initialize,
                        (address(hub), address(manager), address(hook), address(weth), address(positions), admin)
                    )
                )
            ))
        );

        hub.grantRole(hub.OPERATOR_ROLE(), address(manager));
        hub.grantRole(hub.OPERATOR_ROLE(), address(binFactory));
        hub.grantRole(hub.OPERATOR_ROLE(), address(rangeFactory));
        hub.grantRole(hub.OPERATOR_ROLE(), address(router));
        hub.setRouter(address(router));
        router.addIntermediate(address(usdx)); // stablecoin hop (WETH added at init)

        // oracles + assets
        oracle.setPrice(address(usdx), 1e18);
        oracle.setPrice(address(weth), 3000e18);
        oracle.setPrice(address(stok), 250e18);
        hub.registerAsset(address(usdx), 0, address(oracle));
        hub.registerAsset(address(weth), 0, address(oracle));
        hub.registerAsset(address(stok), 1, address(oracle)); // STOCK

        // funds
        usdx.mint(alice, 10_000_000e18);
        usdx.mint(bob, 10_000_000e18);
        stok.mint(alice, 500_000e18);
        stok.mint(bob, 500_000e18);
        vm.deal(alice, 10_000 ether);
        vm.deal(bob, 10_000 ether);
        vm.deal(keeper, 1_000 ether);
        vm.deal(admin, 1000 ether);
        vm.startPrank(alice);
        weth.deposit{value: 5_000 ether}();
        vm.stopPrank();
        vm.startPrank(bob);
        weth.deposit{value: 5_000 ether}();
        vm.stopPrank();
        vm.startPrank(keeper);
        weth.deposit{value: 500 ether}();
        vm.stopPrank();
        vm.stopPrank();
    }

    // ---------- helpers ----------

    function _sqrtFromPriceWad(uint256 priceWad) internal pure returns (uint160) {
        // sqrt(P * 2^192) = sqrtPrice * 2^96
        uint256 p2 = (priceWad * (1 << 192)) / 1e18; // P_real * 2^192
        return uint160(_sqrt(p2));
    }

    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 r = Math_sqr(x);
        return r;
    }

    function Math_sqr(uint256 x) internal pure returns (uint256) {
        // integer sqrt via Newton's method
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }

    function _approveAll(address who, address spender) internal {
        vm.startPrank(who);
        IERC20(address(weth)).approve(spender, type(uint256).max);
        IERC20(address(usdx)).approve(spender, type(uint256).max);
        IERC20(address(stok)).approve(spender, type(uint256).max);
        vm.stopPrank();
    }
}
