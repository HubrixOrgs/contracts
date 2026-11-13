# Hubrix Protocol — Contracts

**Every market. One hub.** A multi-venue AMM protocol built with
[Foundry](https://book.getfoundry.sh/): three pool venues behind a single
router, ERC-721 liquidity positions with locks and vesting, single-bin limit
orders, a bonding-curve token launchpad that graduates into permanently
locked liquidity, and an ERC-4626 credit system.

All contracts are written in Solidity `^0.8.26`, use UUPS upgradeable proxies
with ERC-7201 namespaced storage, and compile with the Cancun EVM schedule and
the IR optimizer enabled. The deployment scripts are fully chain-agnostic:
point them at any EVM network through environment variables.

## Protocol architecture

```
                       ┌──────────────────────────┐
                       │          Hub             │  registry · roles · pause
                       └────────────┬─────────────┘
        ┌───────────────┬───────────┼────────────────┬───────────────┐
        ▼               ▼           ▼                ▼               ▼
 ┌─────────────┐ ┌─────────────┐ ┌────────────┐ ┌───────────┐ ┌─────────────┐
 │ PoolManager │ │ Position    │ │ SwapRouter │ │ Limit     │ │ TokenLaunch │
 │ + PoolHook  │ │ Manager     │ │            │ │ OrderBook │ │ pad         │
 └──────┬──────┘ │ (ERC-721)   │ └─────┬──────┘ └─────┬─────┘ └──────┬──────┘
        │        └─────────────┘       │              │              │
        ▼                              ▼              ▼              ▼
 ┌───────────────────────────┐   venue pools    bin pools     graduation LP
 │  BinPool / RangePool      │   (hook pools)   (LOB venues)  (locked forever)
 │  beacon-proxy venues      │
 └───────────────────────────┘
        │
        ▼
 ┌───────────────────────────┐      ┌─────────────────────┐
 │ LendingVault (ERC-4626)   │◄────►│ CreditManager       │
 │                           │      │ pledge · borrow LTV │
 └───────────────────────────┘      └─────────────────────┘
```

### Components

| Category  | Contract          | Description                                                                 |
|-----------|-------------------|-----------------------------------------------------------------------------|
| Core      | `Hub`             | Global asset/pool registry, role management (admin/operator/keeper), emergency pause |
| Core      | `PoolManager`     | Singleton holding all hook-venue pool state (v4-style)                      |
| Core      | `PoolHook`        | Hook contract with dynamic-fee and oracle-guarded (stale-feed) modes        |
| Core      | `PositionManager` | ERC-721 LP positions: mint/burn/collect, extend-only locks, cliff+linear vesting |
| Venues    | `BinPool`         | Discrete bin ladder venue (LB-AMM style), beacon proxied via `BinPoolFactory` |
| Venues    | `RangePool`       | Concentrated band venue with launch-fee decay, via `RangePoolFactory`       |
| Periphery | `SwapRouter`      | Best-of routing: direct venue quote vs two-hop through intermediates        |
| Periphery | `LimitOrderBook`  | Single-bin limit orders with keeper-claimable fills                         |
| Periphery | `TokenLaunchpad`  | Bonding-curve launches; graduation migrates liquidity into a locked position |
| Periphery | `LendingVault`    | ERC-4626 vault, the credit system's USDX reserve                            |
| Periphery | `CreditManager`  | Pledge position NFTs, borrow up to 50% LTV, repay, liquidation              |
| Libraries | `FeeMath`, `SqrtPriceMath`, `BinPriceMath`, `StorageSlots` | Pure math and ERC-7201 helpers |
| Interfaces | `IHub`, `IPoolManager`, `IPoolHook`, `IBinPool`, `IRangePool`, `IOracle`, `IWETH` | Public interfaces |
| Test fixtures | `WETH`, `TestToken`, `MockOracle`, `LaunchToken` | Mocks used by tests and the deploy script's fixture section |

## Repository layout

```
hubrix-contracts/
├── src/
│   ├── core/         # Hub, PoolManager, PoolHook, PositionManager
│   ├── venues/       # BinPool(+Factory), RangePool(+Factory)
│   ├── periphery/    # SwapRouter, LimitOrderBook, TokenLaunchpad, LendingVault, CreditManager
│   ├── libraries/    # FeeMath, SqrtPriceMath, BinPriceMath, StorageSlots
│   ├── interfaces/   # public interfaces
│   └── mocks/        # WETH, TestToken, MockOracle, LaunchToken
├── test/             # 8 Foundry test suites (38 tests, all passing)
├── script/           # Deploy.s.sol, PostDeploy.s.sol
├── deployments/      # address book output directory (created by Deploy.s.sol)
├── foundry.toml
└── remappings.txt
```

## Getting started

### Requirements

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`)

### Install dependencies

```bash
forge install foundry-rs/forge-std@v1.17.0 --no-commit
forge install OpenZeppelin/openzeppelin-contracts@v5.1.0 --no-commit
forge install OpenZeppelin/openzeppelin-contracts-upgradeable@v5.1.0 --no-commit
```

### Build

```bash
forge build
```

### Test

```bash
forge test          # 38 tests across 8 suites
forge test -vvv     # with traces
forge test --fuzz-runs 1024   # deeper fuzzing (CI profile)
```

## Deployment

The deploy scripts are chain-agnostic: they target whatever RPC endpoint and
private key you provide through environment variables, and no network is
hardcoded anywhere in this repository.

1. Copy `.env.example` to `.env` and fill in your values:

   | Variable      | Description                                    |
   |---------------|------------------------------------------------|
   | `PRIVATE_KEY` | Deployer private key (never commit the real value) |
   | `RPC_URL`     | RPC endpoint of the target chain               |
   | `CHAIN_ID`    | Chain ID of the target network                 |
   | `EXPLORER`    | (optional) Block explorer URL for verification |

2. Run the full deployment (fixtures → core → venues → periphery → wiring):

   ```bash
   forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify
   ```

   `Deploy.s.sol` writes the resulting address book to
   `deployments/<chainId>.json` — one file per chain, derived from the
   network the script actually runs against.

3. Optionally seed pools and exercise every product surface end-to-end
   (oracle prices, hook/bin/range pools, router swaps, a limit-order fill, a
   full launchpad graduation, and a borrow/repay/unpledge credit cycle):

   ```bash
   forge script script/PostDeploy.s.sol --rpc-url $RPC_URL --broadcast
   ```

   `PostDeploy.s.sol` reads back the address book written by `Deploy.s.sol`
   for the chain it runs against.

> **Note** — the first section of `Deploy.s.sol` deploys mock fixtures
> (`WETH`, `TestToken`, `MockOracle`). On a network with canonical WETH or a
> live oracle, replace those with the existing deployments before broadcasting.

## Security

- Contracts use UUPS proxies with ERC-7201 namespaced storage slots and are
  upgradeable by the admin role granted in each `initialize`.
- `Hub` carries a global emergency pause; role separation
  (admin / operator / keeper) gates all state-changing administration.
- The test suite covers fee modes, oracle staleness guards, lock/vesting
  semantics, routing, limit-order fills, launchpad graduation, and the full
  credit lifecycle including liquidation.
- **This code has not been audited.** It is provided as-is for research and
  testing purposes; see `LICENSE`.

## License

Released under the [MIT License](./LICENSE).
