# Perpetual order book (testnet only)

Imported from `stable-poc-contract` at commit `5d9d655` (2026-01-23) when that repository was archived.

**Status: testnet reference implementation, not audited, not for production.**

## Prices and settlement

Trading, liquidation and ADL require an `IMarkPriceOracle` implementing
`getMarkPriceData(uint32)`. Prices use 18 decimals. A missing feed, a zero price,
a future timestamp, data older than five minutes, or a reverting feed stops the
operation; there is no synthetic price fallback. Market orders fill at the mark
in this reference venue; `maxSlippage` is a tolerance, not a price surcharge.

Only **18-decimal collateral and isolated-margin settlement** are supported.
`MarginManager` rejects other collateral decimals, and the engine rejects cross
margin mode. Six-decimal USDC requires a separate unit-conversion implementation.
The engine propagates market configuration and oracle changes to its components.

`Liquidator` reads real positions, checks the funding-adjusted maintenance margin,
reduces open interest and position margin, and settles the released margin slice
in `MarginManager`. Full and partial liquidation use the current mark price.
Partial liquidation rejects bankrupt positions and configured minimum-size dust.
A partial liquidation reduces exposure but does not promise to restore a healthy
margin ratio; keepers must recheck the residual position.

Liquidator's fee schedule is authoritative for these settlement calls. Fees are
capped at positive equity, split between keeper/protocol/insurance, and backed by
actual collateral transfers. An insolvent position pays no liquidation fee.
The older direct `PositionManager.liquidatePosition` admin/engine method is a
ledger-only primitive, not a substitute for the coordinated Liquidator path.

Insurance coverage consumes the market allocation first, then the common pool,
and transfers the covered collateral into `MarginManager`. Any uncovered loss
is registered once in `ADLEngine` against the liquidated position's original
market, direction and size. This registration activates ADL for that market.

ADL reads live, profitable opposite-side positions in the same market. It ranks
funding-adjusted profit/equity multiplied by current notional/equity. Execution
reduces a real counterparty position at the registered liquidation mark, releases
proportional margin, and withholds realized profit equal to the proportional
registered debt. Fixing the settlement mark prevents later price moves from
inflating the payout against a loss already fixed at liquidation. The net payout
must also not exceed the counterparty's live funding-adjusted profit.
The debt share rounds up and cannot exceed that slice's profit. A candidate with
insufficient profit is rejected; automatic execution skips it. If enough
candidates are unavailable, debt remains unresolved for a later authorized call.
The last successful settlement clears the market's ADL flag when all registered
debt has been resolved. Low insurance funding alone does not authorize a haircut:
execution always requires registered debt.

While registered debt remains, ordinary position close/reduce and margin removal
are blocked for that market, including when an admin pauses ADL. Keepers cannot
choose arbitrary debt amounts or seize unrelated collateral. Batch liquidation
skips failed subcalls and rewards the original keeper; batch ADL is atomic and
calls internal execution without losing authorization to external self-calls.
Position enumeration is bounded at 200 open positions per market side, and ADL
returns/processes at most 50 candidates per call.

## Component wiring

Before enabling settlement, the component admin must configure:

- `PerpetualEngine.setComponents` with all six component addresses, after setting
  the engine address in PositionManager, MarginManager and OrderManager.
- `PositionManager.setLiquidator` and `setADLEngine`, and the corresponding
  `MarginManager` setters. These grant only the dedicated settlement endpoints.
- `Liquidator.setPositionManager`, `setMarginManager`, `setInsuranceFund` and
  `setADLEngine`.
- `ADLEngine.setPositionManager`, `setMarginManager`, `setInsuranceFund` and
  `setLiquidator`; its execution/queue calls remain admin/engine-authorized.
- `InsuranceFund.setLiquidator`, so fee deposits and loss coverage are authorized.
- `PerpetualEngine.setOracles` for each market, with a configured, fresh mark feed.

All collateral-holding components must use the same 18-decimal collateral token.
`DeployPerpetual.s.sol` still deploys only PerpetualEngine, OrderManager,
PositionManager and MarginManager and leaves liquidation/ADL disabled. It is not
part of `DeployAll`. Override `PERP_COLLATERAL` with an 18-decimal test token;
manual component/oracle wiring is required. No deployment is included in this
change.

## Remaining reference-implementation limits

This change implements liquidation and registered-debt ADL, not a complete
perpetual exchange. FundingRateManager still has position/oracle settlement
TODOs; liquidation/ADL use PositionManager's configured cumulative funding index.
Matching orders does not itself settle positions, ordinary profit credits still
require a solvent collateral pool, and ordinary close/reduce funding settlement
and the remaining margin-query TODOs need separate work. Reopening a closed
trader/market/side position key is not supported by the imported ledger. Market/position data and
fee-on-transfer collateral have not been production-audited. Production use also
requires a validated price adapter, unit conversion if using USDC, liquidity and
risk controls, and a full deployment/upgrade plan.

## Local verification

With a local Prague Anvil node on chain 31337:

```bash
forge test --match-path 'test/perpetual/*.t.sol' \
  --fork-url http://127.0.0.1:8545 --chain-id 31337 -vv
```

For the full repository suite, use a fresh private Anvil node with genesis
timestamp 1: some existing subscription/hook tests assume that starting time.
Do not reset a shared node to satisfy this assumption.

```bash
anvil --host 127.0.0.1 --port 18545 --chain-id 31337 --hardfork prague --timestamp 1 --silent
# In another terminal:
forge test --fork-url http://127.0.0.1:18545 --chain-id 31337 -vv
```

The tests use simulated calls against the local fork; they do not broadcast
transactions. They cover actual ledger/asset settlement, long and short
liquidations, partial/batch paths, fee caps, funding, insurance coverage, live ADL
selection, profit limits, authorization, debt replay, blocked ordinary exits,
failed-call rollback, oracle failures and collateral-conservation fuzz cases.

## Consumer: indexer-go `perp_orderbook` venue

indexer-go (`pkg/features/dex`) decodes, by hard-coded signature:

- `PerpetualEngine`: `MarketCreated` (base token is always `address(0)`; symbols via `getMarketSymbols`)
- `OrderManager`: `OrderCreated`, `OrderPartiallyFilled`, `OrderCancelled`, `OrderExpired`, `OrderModified`, `OrderTriggered`, `MarketOrderExecuted`, `OrdersMatched`
- `OrderManager.getOrder(bytes32)` return words by index (status=5, size=8, filled=9, price=10)

`test/perpetual/OrderManager.t.sol` pins these event signatures and tuple offsets.
They remain unchanged by the settlement implementation. Added administrative
functions/errors require refreshed ABI exports. After interface changes, run
`./script/export-venue-abi.sh` (CI checks `abi/perpetual` is current).
