# Perpetual order book (testnet only)

Imported from `stable-poc-contract` at commit `5d9d655` (2026-01-23) when that repository was archived.

**Status: testnet reference implementation, not audited, not for production.**

- Prices are hard-coded placeholders (`PerpetualEngine._getMarketPrice`, `OrderManager.executeMarketOrder`).
- `Liquidator.liquidate` and most of `ADLEngine` are placeholders.
- `DeployPerpetual.s.sol` deploys only `PerpetualEngine`, `OrderManager`, `PositionManager` and `MarginManager`; it is not part of `DeployAll`.

## Consumer: indexer-go `perp_orderbook` venue

indexer-go (`pkg/features/dex`) decodes, by hard-coded signature:

- `PerpetualEngine`: `MarketCreated` (base token is always `address(0)`; symbols via `getMarketSymbols`)
- `OrderManager`: `OrderCreated`, `OrderPartiallyFilled`, `OrderCancelled`, `OrderExpired`, `OrderModified`, `OrderTriggered`, `MarketOrderExecuted`, `OrdersMatched`
- `OrderManager.getOrder(bytes32)` return words by index (status=5, size=8, filled=9, price=10)

`test/perpetual/OrderManager.t.sol` pins these. Changing any of them is a breaking change for the indexer:
update both repositories together and re-run `./script/export-venue-abi.sh` (CI checks `abi/perpetual` is current).
