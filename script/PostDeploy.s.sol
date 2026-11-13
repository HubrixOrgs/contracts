// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Hub} from "../src/core/Hub.sol";
import {PositionManager} from "../src/core/PositionManager.sol";
import {BinPoolFactory} from "../src/venues/BinPoolFactory.sol";
import {RangePoolFactory} from "../src/venues/RangePoolFactory.sol";
import {SwapRouter} from "../src/periphery/SwapRouter.sol";
import {LimitOrderBook} from "../src/periphery/LimitOrderBook.sol";
import {TokenLaunchpad} from "../src/periphery/TokenLaunchpad.sol";
import {LendingVault} from "../src/periphery/LendingVault.sol";
import {CreditManager} from "../src/periphery/CreditManager.sol";
import {TestToken} from "../src/mocks/TestToken.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";
import {IBinPool} from "../src/interfaces/IBinPool.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {IRangePool} from "../src/interfaces/IRangePool.sol";

/// @title Post-deployment seeding and end-to-end verification (chain-agnostic).
/// @notice Seeds oracles/assets/pools, then exercises every product surface:
///         router (direct + 2-hop), limit orders, launchpad graduation, credit.
contract PostDeploy is Script {
    using stdJson for string;
    using SafeERC20 for IERC20;

    uint256 constant Q96 = 1 << 96;

    address hub_;
    address pm_; // pool manager
    address hook_;
    address pos_; // position manager
    address binFac_;
    address rangeFac_;
    address router_;
    address lob_;
    address launchpad_;
    address vault_;
    address cm_;
    address weth_;
    address usdx_;
    address stok_;
    address oracle_;

    address binPool;
    address rangePool;
    bytes32 hookPoolEthUsdx;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        string memory json = vm.readFile(string.concat("deployments/", vm.toString(block.chainid), ".json"));
        hub_ = json.readAddress(".hub");
        pm_ = json.readAddress(".poolManager");
        hook_ = json.readAddress(".poolHook");
        pos_ = json.readAddress(".positionManager");
        binFac_ = json.readAddress(".binPoolFactory");
        rangeFac_ = json.readAddress(".rangePoolFactory");
        router_ = json.readAddress(".swapRouter");
        lob_ = json.readAddress(".limitOrderBook");
        launchpad_ = json.readAddress(".tokenLaunchpad");
        vault_ = json.readAddress(".lendingVault");
        cm_ = json.readAddress(".creditManager");
        weth_ = json.readAddress(".weth");
        usdx_ = json.readAddress(".usdx");
        stok_ = json.readAddress(".stok");
        oracle_ = json.readAddress(".oracle");

        vm.startBroadcast(pk);
        IWETH(weth_).deposit{value: 0.0055 ether}(); // small WETH budget for seeding
        _seedOraclesAndAssets();
        _mintTestTokens(deployer);
        _createHookPools(deployer);
        _createBinPool(deployer);
        _createRangePool(deployer);
        _routerSwaps();
        _limitOrderFlow();
        _launchFlow();
        _creditFlow(deployer);
        vm.stopBroadcast();

        console.log("Post-deploy verification complete.");
        console.log("binPool:        ", binPool);
        console.log("rangePool:      ", rangePool);
        console.log("hookPoolEthUsdx:", vm.toString(hookPoolEthUsdx));
    }

    // ---------- seeding ----------

    function _seedOraclesAndAssets() internal {
        MockOracle oracle = MockOracle(oracle_);
        oracle.setPrice(usdx_, 1e18);
        oracle.setPrice(weth_, 3000e18);
        oracle.setPrice(stok_, 250e18);

        Hub hub = Hub(hub_);
        hub.registerAsset(usdx_, 0, oracle_);
        hub.registerAsset(weth_, 0, oracle_);
        hub.registerAsset(stok_, 1, oracle_); // STOCK -> oracle-guarded hook pools
    }

    function _mintTestTokens(address to) internal {
        TestToken(usdx_).mint(to, 5_000_000e18);
        TestToken(stok_).mint(to, 200_000e18);
    }

    function _createHookPools(address deployer) internal {
        PositionManager pos = PositionManager(pos_);
        IERC20(weth_).approve(pos_, type(uint256).max);
        IERC20(usdx_).approve(pos_, type(uint256).max);
        IERC20(stok_).approve(pos_, type(uint256).max);

        // WETH/USDX dynamic-fee pool @ 1 ETH = 3000 USDX: 0.002 WETH + 6k-milli USDX
        uint256 tid = pos.mint(
            PositionManager.MintParams({
                tokenA: weth_,
                tokenB: usdx_,
                hooks: hook_,
                feeSeed: 0,
                amount0Desired: 0.0015e18,
                amount1Desired: 4.5e18,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                recipient: deployer,
                lockUntil: 0
            })
        );
        hookPoolEthUsdx = pos.positionPool(tid);

        // STOK/USDX oracle-guarded (stock) pool @ 1 STOK = 250 USDX: 400 STOK + 100k USDX
        tid = pos.mint(
            PositionManager.MintParams({
                tokenA: stok_,
                tokenB: usdx_,
                hooks: hook_,
                feeSeed: 0,
                amount0Desired: 400e18,
                amount1Desired: 100_000e18,
                amount0Min: 390e18,
                amount1Min: 99_000e18,
                deadline: block.timestamp + 1 hours,
                recipient: deployer,
                lockUntil: 0
            })
        );
        console.log("hook pools created; first position tokenId:", tid);
    }

    function _createBinPool(address deployer) internal {
        BinPoolFactory fac = BinPoolFactory(binFac_);
        bool wethIsToken0 = weth_ < usdx_;
        // (1.0025)^3207 ~= 3010 -> ladder id for a 3000 USDX per WETH market
        int32 id = wethIsToken0 ? int32(3207) : -int32(3207);
        binPool = fac.createPool(weth_, usdx_, 25, id);
        IBinPool pool = IBinPool(binPool);
        require(pool.token0() == (wethIsToken0 ? weth_ : usdx_), "ordering");

        // seed 5 bins around active: 0.5 WETH-equivalent each
        uint256 wethPerBin = 0.0004e18;
        uint256 usdxPerBin = Math.mulDiv(wethPerBin, pool.priceOfBin(pool.activeId()), Q96);

        int32[] memory ids = new int32[](5);
        uint256[] memory a0 = new uint256[](5);
        uint256[] memory a1 = new uint256[](5);
        int32 active = pool.activeId();
        // active: both sides
        ids[0] = active;
        (a0[0], a1[0]) = wethIsToken0 ? (wethPerBin, usdxPerBin) : (usdxPerBin, wethPerBin);
        // two above: token0 only
        ids[1] = active + 1;
        a0[1] = wethIsToken0 ? wethPerBin : usdxPerBin;
        ids[2] = active + 2;
        a0[2] = wethIsToken0 ? wethPerBin : usdxPerBin;
        // two below: token1 only
        ids[3] = active - 1;
        a1[3] = wethIsToken0 ? usdxPerBin : wethPerBin;
        ids[4] = active - 2;
        a1[4] = wethIsToken0 ? usdxPerBin : wethPerBin;

        IERC20(weth_).approve(binPool, type(uint256).max);
        IERC20(usdx_).approve(binPool, type(uint256).max);
        pool.addLiquidity(ids, a0, a1, deployer);
    }

    function _createRangePool(address deployer) internal {
        RangePoolFactory fac = RangePoolFactory(rangeFac_);
        // market: 1 WETH = 12 STOK; base-unit price = token1 per token0
        uint256 num = weth_ < stok_ ? 60e18 : 5e18;
        uint256 den = weth_ < stok_ ? 5e18 : 60e18;
        uint160 anchor = uint160(Math.sqrt(Math.mulDiv(num, 1 << 192, den)));
        rangePool = fac.createPool(weth_, stok_, anchor, 1200, 5, 3000, 1 hours);

        IERC20(weth_).approve(rangePool, type(uint256).max);
        IERC20(stok_).approve(rangePool, type(uint256).max);
        // seed at the band ratio: dy/dx = (sqrtP - sqrtLow)*sqrtP*sqrtUp / (2^192*(sqrtUp - sqrtP))
        uint256 d0 = 0.001e18;
        (uint160 sqrtLow, uint160 sqrtUp) = IRangePool(rangePool).band();
        uint160 sqrtP = IRangePool(rangePool).sqrtPriceX96();
        uint256 t = Math.mulDiv(uint256(sqrtP) - sqrtLow, sqrtP, uint256(sqrtUp) - sqrtP);
        uint256 ratioQ96 = Math.mulDiv(t, sqrtUp, 1 << 96);
        uint256 d1 = Math.mulDiv(d0, ratioQ96, 1 << 96);
        uint256 shares = IRangePool(rangePool).addLiquidity(d0, d1, 0, deployer);
        console.log("range pool seeded, shares:", shares);
    }

    // ---------- product flows ----------

    function _routerSwaps() internal {
        SwapRouter router = SwapRouter(payable(router_));
        IERC20(usdx_).approve(router_, type(uint256).max);
        IERC20(weth_).approve(router_, type(uint256).max);
        IERC20(stok_).approve(router_, type(uint256).max);

        // direct USDX -> WETH
        SwapRouter.Route memory r1 = router.quoteExactIn(usdx_, 1e18, weth_);
        console.log("USDX->WETH quote:", r1.amountOut, "hops:", r1.hops.length);
        uint256 out1 = router.execute(r1, 1e18, (r1.amountOut * 99) / 100, block.timestamp + 1 hours);
        console.log("USDX->WETH executed:", out1);

        // direct WETH -> USDX
        SwapRouter.Route memory r2 = router.quoteExactIn(weth_, 0.0002e18, usdx_);
        uint256 out2 = router.execute(r2, 0.0002e18, (r2.amountOut * 99) / 100, block.timestamp + 1 hours);
        console.log("WETH->USDX executed:", out2);

        // two-hop STOK -> (USDX) -> WETH: no direct STOK/WETH pool exists
        SwapRouter.Route memory r3 = router.quoteExactIn(stok_, 0.5e18, weth_);
        require(r3.hops.length == 2, "expected a two-hop route");
        uint256 out3 = router.execute(r3, 0.5e18, (r3.amountOut * 95) / 100, block.timestamp + 1 hours);
        console.log("STOK->WETH (2-hop) executed:", out3);
    }

    function _limitOrderFlow() internal {
        IBinPool pool = IBinPool(binPool);
        LimitOrderBook lob = LimitOrderBook(lob_);
        IERC20(weth_).approve(lob_, type(uint256).max);
        IERC20(usdx_).approve(lob_, type(uint256).max);

        bool wethIsToken0 = pool.token0() == weth_;
        int32 active = pool.activeId();
        // sell 0.2 WETH one bin away from market, on the correct side of the ladder
        uint256 oid;
        if (wethIsToken0) {
            oid = lob.place(binPool, active + 1, true, 0.0001e18, 10); // sell token0 above market
        } else {
            oid = lob.place(binPool, active - 1, false, 0.0001e18, 10); // sell token1 below market
        }
        console.log("limit order placed:", oid);

        // buy WETH with a big USDX order -> price crosses the order bin -> order fills
        SwapRouter router = SwapRouter(payable(router_));
        SwapRouter.Route memory r = router.quoteExactIn(usdx_, 3e18, weth_);
        uint256 got = router.execute(r, 3e18, (r.amountOut * 80) / 100, block.timestamp + 1 hours);
        console.log("big WETH buy:", got);

        console.log("order filled:", lob.filled(oid));
        if (lob.filled(oid)) {
            lob.claim(oid); // owner claims proceeds
        }
    }

    function _launchFlow() internal {
        TokenLaunchpad lp = TokenLaunchpad(payable(launchpad_));
        uint256 lid = lp.create("Test Launch One", "TLCH", 0.002e18); // low threshold for the demo
        console.log("launch created:", lid);
        lp.buy{value: 0.0015e18}(lid, 0, block.timestamp + 1 hours);
        lp.buy{value: 0.0015e18}(lid, 0, block.timestamp + 1 hours);
        console.log("raised:", lp.launch(lid).realEth);
        lp.graduate(lid);
        console.log("graduated:", lp.launch(lid).graduated);
        console.log("graduation position NFT:", lp.launch(lid).positionTokenId);
    }

    function _creditFlow(address deployer) internal {
        LendingVault vault = LendingVault(vault_);
        CreditManager cm = CreditManager(cm_);

        IERC20(usdx_).approve(vault_, type(uint256).max);
        vault.deposit(200_000e18, deployer);

        // open a fresh position and pledge it
        PositionManager pos = PositionManager(pos_);
        uint256 tid = pos.mint(
            PositionManager.MintParams({
                tokenA: weth_,
                tokenB: usdx_,
                hooks: hook_,
                feeSeed: 0,
                amount0Desired: 0.0015e18,
                amount1Desired: 4.5e18,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                recipient: deployer,
                lockUntil: 0
            })
        );
        pos.approve(cm_, tid);
        pos.safeTransferFrom(deployer, cm_, tid); // pledge via onERC721Received

        uint256 loanId = cm.loanOf(tid);
        uint256 val = cm.valuation(tid);
        console.log("loan:", loanId, "valuation (USD):", val);

        uint256 borrowAmount = (val * 30) / 100; // 30% LTV
        cm.borrow(loanId, borrowAmount);
        console.log("borrowed:", borrowAmount);

        IERC20(usdx_).approve(cm_, type(uint256).max);
        cm.repay(loanId, cm.debtOf(loanId) * 2); // capped to outstanding inside
        cm.unpledge(loanId);
        console.log("unpledged; debt:", cm.debtOf(loanId));
    }
}
