// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {console} from "forge-std/console.sol";

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

/// @title Full protocol deployment (chain-agnostic).
/// @notice Deploys fixtures, core, venues, periphery; wires authorizations;
///         writes the address book to deployments/<chainId>.json.
contract Deploy is Script {
    using stdJson for string;

    struct Addresses {
        address hub;
        address poolManager;
        address poolHook;
        address positionManager;
        address binPoolFactory;
        address binPoolImpl;
        address rangePoolFactory;
        address rangePoolImpl;
        address limitOrderBook;
        address swapRouter;
        address tokenLaunchpad;
        address lendingVault;
        address creditManager;
        address weth;
        address usdx;
        address stok;
        address oracle;
    }

    Addresses public a;

    function run() external returns (Addresses memory) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        vm.startBroadcast(pk);

        // ---------- fixtures ----------
        a.weth = address(new WETH());
        a.usdx = address(new TestToken("Test USD Stable", "USDX"));
        a.stok = address(new TestToken("Test Stock Token", "STOK"));
        a.oracle = address(new MockOracle());

        // ---------- core ----------
        Hub hubImpl = new Hub();
        a.hub = address(new ERC1967Proxy(address(hubImpl), abi.encodeCall(Hub.initialize, (deployer, deployer))));

        PoolManager pmImpl = new PoolManager();
        a.poolManager =
            address(new ERC1967Proxy(address(pmImpl), abi.encodeCall(PoolManager.initialize, (a.hub, deployer))));

        PoolHook hookImpl = new PoolHook();
        a.poolHook =
            address(new ERC1967Proxy(address(hookImpl), abi.encodeCall(PoolHook.initialize, (a.hub, deployer))));
        PoolHook(a.poolHook).setManager(a.poolManager);

        PositionManager posImpl = new PositionManager();
        a.positionManager = address(
            new ERC1967Proxy(
                address(posImpl), abi.encodeCall(PositionManager.initialize, (a.hub, a.poolManager, deployer))
            )
        );
        PoolManager(a.poolManager).setPositionManager(a.positionManager);

        // ---------- venues ----------
        a.binPoolImpl = address(new BinPool());
        BinPoolFactory binImpl = new BinPoolFactory();
        a.binPoolFactory = address(
            new ERC1967Proxy(
                address(binImpl),
                abi.encodeCall(BinPoolFactory.initialize, (a.hub, a.binPoolImpl, deployer))
            )
        );

        a.rangePoolImpl = address(new RangePool());
        RangePoolFactory rangeImpl = new RangePoolFactory();
        a.rangePoolFactory = address(
            new ERC1967Proxy(
                address(rangeImpl),
                abi.encodeCall(RangePoolFactory.initialize, (a.hub, a.rangePoolImpl, deployer))
            )
        );

        // ---------- periphery ----------
        LimitOrderBook lobImpl = new LimitOrderBook();
        a.limitOrderBook = address(
            new ERC1967Proxy(address(lobImpl), abi.encodeCall(LimitOrderBook.initialize, (a.hub, deployer)))
        );

        SwapRouter routerImpl = new SwapRouter();
        a.swapRouter = address(
            new ERC1967Proxy(
                address(routerImpl),
                abi.encodeCall(SwapRouter.initialize, (a.hub, a.poolManager, a.weth, deployer))
            )
        );

        LendingVault vaultImpl = new LendingVault();
        a.lendingVault = address(
            new ERC1967Proxy(
                address(vaultImpl),
                abi.encodeCall(LendingVault.initialize, (a.usdx, deployer, deployer)) // creditManager set below
            )
        );

        CreditManager cmImpl = new CreditManager();
        a.creditManager = address(
            new ERC1967Proxy(
                address(cmImpl),
                abi.encodeCall(
                    CreditManager.initialize, (a.hub, a.lendingVault, a.positionManager, a.poolManager, deployer)
                )
            )
        );
        LendingVault(a.lendingVault).setCreditManager(a.creditManager);
        PositionManager(a.positionManager).setCreditManager(a.creditManager);

        TokenLaunchpad lpImpl = new TokenLaunchpad();
        a.tokenLaunchpad = address(
            new ERC1967Proxy(
                address(lpImpl),
                abi.encodeCall(
                    TokenLaunchpad.initialize,
                    (a.hub, a.poolManager, a.poolHook, a.weth, a.positionManager, deployer)
                )
            )
        );

        // ---------- wiring ----------
        SwapRouter(payable(a.swapRouter)).addIntermediate(a.usdx); // stablecoin hop (WETH added at init)
        Hub hub = Hub(a.hub);
        hub.grantRole(hub.OPERATOR_ROLE(), a.poolManager); // pool registration
        hub.grantRole(hub.OPERATOR_ROLE(), a.binPoolFactory);
        hub.grantRole(hub.OPERATOR_ROLE(), a.rangePoolFactory);
        hub.grantRole(hub.OPERATOR_ROLE(), a.swapRouter); // future: router-registered pools
        hub.setRouter(a.swapRouter);

        vm.stopBroadcast();

        _writeAddresses();
        return a;
    }

    function _writeAddresses() internal {
        string memory obj = "addresses";
        vm.serializeAddress(obj, "hub", a.hub);
        vm.serializeAddress(obj, "poolManager", a.poolManager);
        vm.serializeAddress(obj, "poolHook", a.poolHook);
        vm.serializeAddress(obj, "positionManager", a.positionManager);
        vm.serializeAddress(obj, "binPoolFactory", a.binPoolFactory);
        vm.serializeAddress(obj, "binPoolImpl", a.binPoolImpl);
        vm.serializeAddress(obj, "rangePoolFactory", a.rangePoolFactory);
        vm.serializeAddress(obj, "rangePoolImpl", a.rangePoolImpl);
        vm.serializeAddress(obj, "limitOrderBook", a.limitOrderBook);
        string memory semi = vm.serializeAddress(obj, "swapRouter", a.swapRouter);
        vm.serializeAddress(semi, "tokenLaunchpad", a.tokenLaunchpad);
        vm.serializeAddress(semi, "lendingVault", a.lendingVault);
        vm.serializeAddress(semi, "creditManager", a.creditManager);
        vm.serializeAddress(semi, "weth", a.weth);
        vm.serializeAddress(semi, "usdx", a.usdx);
        vm.serializeAddress(semi, "stok", a.stok);
        string memory json = vm.serializeAddress(semi, "oracle", a.oracle);

        string memory file = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(json, file);
        console.log("addresses written to", file);
    }
}
