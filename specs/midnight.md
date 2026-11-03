---
facet: MidnightFacet
dir: midnight
chains: [mainnet]
integration_doc: MIDNIGHT_INTEGRATION.md
dependencies: []
---

# Midnight Integration Spec

## Summary

MidnightFacet lets the ALMProxy lend in Morpho Midnight fixed-term markets: as a taker it buys
fixed-maturity credit units, sells them back before maturity and redeems them at par after
repayment; as a maker it funds fills of offers the proxy has published, through a funding strategy
called back from inside Midnight's `take`. Purpose: fixed-rate yield on idle loan tokens.

## External protocol

- **Protocol:** Morpho Midnight, commit `70607569ac348e9880b512ffd3b574be55405932`.
- **Contracts touched:** Midnight singleton `0x471686c42792F93528B000beF54bC10E3aa2045f`
  (mainnet; not yet in the address registries); each market's loan token (ERC-20).
- **Audited/battle-tested status:** OPEN (owner to supply links).
- **Trust assumptions:** the singleton is immutable; its `configurator` appoints a `feeSetter`
  who can move settlement and continuous fees within hard-coded ceilings; lender losses are
  socialized through `lossFactor`; redemption is first come first served out of repayments;
  maker callbacks run inside the proxy's `take`; authorizing an address on the singleton
  (`setIsAuthorized`) is a blanket grant over the proxy's position.
- **House-constraint check:** loan tokens onboarded per market by governance (`setMarketConfig`);
  UNVERIFIED which loan tokens are intended (e.g. USDC, USDS). No oracle on the facet's legs.
  Seeding: a market must have been touched on Midnight (`touchMarket`) before trading.

## Functions

### `buy(bytes32 marketId, Offer offer, bytes ratifierData, uint256 units, uint256 maxAssetsIn)`
- **Role:** ALLOCATOR_ROLE
- **Value direction:** outbound (loan token for credit units)
- **Rate limit:** `LIMIT_MIDNIGHT_BUY`, `makeBytes32Key(_LIMIT_BUY, marketId)`; enforcing decrease
  of the higher of the proxy's balance delta and Midnight's reported `buyerAssets`
- **Refill:** none
- **Loss bounds:** `maxAssetsIn` (non-zero); admin `maxBuyTick` and `minBuyYield` on the all-in
  price incl. settlement fee; `maxContinuousFee`, `maxLossFactor` gates
- **External calls:** `ApproveLib.approve` to Midnight for `maxAssetsIn`, `take` via `doCall`
  (taker = proxy), approval reset to zero; offer receiver may not be the proxy
- **Zero-amount semantics:** `units == 0` reverts `MidnightFacet/zero-units`
- **Opaque bytes:** `ratifierData` is passed to Midnight unchanged; it is read only by the
  offer's ratifier (V-2 justification)

### `sell(bytes32 marketId, Offer offer, bytes ratifierData, uint256 units, uint256 minAssetsOut)`
- **Role:** ALLOCATOR_ROLE
- **Value direction:** outbound units, loan token returns to the proxy
- **Rate limit:** `LIMIT_MIDNIGHT_SELL`, `makeBytes32Key(_LIMIT_SELL, marketId)`; enforcing
  decrease of the loan token received
- **Refill:** none, because <OPEN: reason for no buy-key restore, see rule R-4>
- **Loss bounds:** `minAssetsOut` (non-zero); admin `minSellTick` and `maxSellYield` (floor off
  the fee the position carries); units capped at live credit
- **External calls:** `take` via `doCall`, proceeds to the proxy
- **Zero-amount semantics:** zero units, or zero credit after the cap, revert

### `redeem(bytes32 marketId, uint256 units, uint256 minAssetsOut)`
- **Role:** ALLOCATOR_ROLE
- **Value direction:** returning (to proxy)
- **Rate limit:** `LIMIT_MIDNIGHT_REDEEM`, `makeBytes32Key(_LIMIT_REDEEM, marketId)`; enforcing
  decrease of the loan token received
- **Refill:** none, because <OPEN>
- **Loss bounds:** `minAssetsOut` (non-zero); units capped at credit and `withdrawable`
- **External calls:** `withdraw(market, units, proxy, proxy)` via `doCall`

### `fundFill(bytes32 marketId, bool buying, uint256 assets, uint256 units, uint256 pendingFee)`
- **Role:** none; OPEN, depends on the upstream rulebook request (A-1, A-2, V-3). The caller's
  strategy key is the authorization.
- **Value direction:** buying: outbound to the calling strategy; selling: moves nothing (Midnight
  has already taken the proxy's units)
- **Rate limit:** buying: `LIMIT_MIDNIGHT_STRATEGY_BUY`,
  `makeAddressBytes32Key(_LIMIT_STRATEGY_BUY, msg.sender, marketId)`, then `LIMIT_MIDNIGHT_BUY`
  for the market, both enforcing decreases of `assets`; selling: `LIMIT_MIDNIGHT_STRATEGY_SELL`
  then `LIMIT_MIDNIGHT_SELL`
- **Refill:** none
- **Loss bounds:** `assets <= maxOfferSize`; entry `assets * WAD <= units * maxFillPrice` from
  config only; exit `assets * WAD >= units * minFillPrice`; fee and loss-factor gates on entry;
  zero debt on exit
- **External calls:** buying: `transfer(msg.sender, assets)` on the loan token via `doCall`
- **Zero-amount semantics:** zero `assets` or `units` revert

### `cancelOfferGroup(bytes32 group)`
- **Role:** ALLOCATOR_ROLE or `MIDNIGHT_FREEZER_ROLE`; OPEN, depends on the upstream request (A-1, A-2)
- **Value direction:** config (risk-reducing, retires a group)
- **External calls:** `setConsumed(group, type(uint128).max, proxy)` via `doCall`

### `setMakeConfig(Market market, uint256 maxOfferSize)`
- **Role:** DEFAULT_ADMIN_ROLE; `MIDNIGHT_FREEZER_ROLE` only for `maxOfferSize == 0`; OPEN as above
- **Value direction:** config (per-fill cap for maker mode)
- **External calls:** `toMarket(marketId)` (view)

### `setMarketConfig(bytes32 marketId, uint16 maxBuyTick, uint16 minSellTick, uint16 minBuyYield, uint16 maxSellYield, uint16 maxContinuousFee, uint128 maxLossFactor)`
- **Role:** DEFAULT_ADMIN_ROLE. **Value direction:** config (onboards a market; `minSellTick != 0`)

### `setDesignatedGroups(bytes32 marketId, bytes32 buyGroup, bytes32 sellGroup)`
- **Role:** DEFAULT_ADMIN_ROLE. **Value direction:** config (groups the ratifier accepts per market)

### `setRatifierAuthorization(address ratifier, bool authorized)`
- **Role:** DEFAULT_ADMIN_ROLE. **Value direction:** config, a blanket grant on the singleton
- **External calls:** `setIsAuthorized(ratifier, authorized, proxy)` via `doCall`

Views: `getBuyRateLimitKey`, `getSellRateLimitKey`, `getRedeemRateLimitKey`,
`getStrategyBuyRateLimitKey`, `getStrategySellRateLimitKey`, `getDesignatedGroups`,
`getMakeConfig`, `getMarketConfig`, `isCallbackAllowed`, `midnight`, `MIDNIGHT_FREEZER_ROLE`,
`VERSION`.

Setting `maxBuyTick` to zero closes entry: `isCallbackAllowed` then returns false for buys, so the ratifier refuses buy offers, resting ones included, and maker buy fills, fabricated `fundFill` calls included, revert with `fill-price-too-high`.

## Fund-exit map

| # | Path | Destination | Bounded by |
|---|------|-------------|------------|
| 1 | `buy`: approval + `take` | offer maker (seller); proxy receives credit units | `LIMIT_MIDNIGHT_BUY` per market; `maxAssetsIn`; price and yield ceilings |
| 2 | `fundFill`, buying: `transfer` | calling strategy, which funds Midnight's pull in the same `take` | strategy buy key per (strategy, market), then `LIMIT_MIDNIGHT_BUY`; `maxOfferSize` per call; config price ceiling |
| 3 | `sell`: `take` | credit units to the offer maker; loan token to the proxy | `LIMIT_MIDNIGHT_SELL` per market; `minAssetsOut`; price and yield floors |
| 4 | maker sell fill (units taken by Midnight before `fundFill`) | offer taker | strategy sell key, then `LIMIT_MIDNIGHT_SELL`; config price floor |
| 5 | `setRatifierAuthorization` | authorized address can act on the proxy's position | `DEFAULT_ADMIN_ROLE` only |

## Storage & constructor

- **ERC-7201 storage fields:** `marketConfigs`, `makeConfigs`, `designatedGroups` (per `marketId`),
  namespace `sky.pau.storage.MidnightFacet.v1`.
- **Immutables:** `midnight` (the singleton; zero-checked in the constructor).
- **Auxiliary module:** none.

## Standing approvals & declared exceptions

No standing ERC-20 approval (the `buy` approval is reset in the same call). Standing authorization:
the ratifier's `setIsAuthorized` grant on the singleton (row 5 above). OPEN: the role and callback
departures from A-1, A-2 and V-3 are listed here only once the upstream request is decided.

## Dependencies

None as a `lib/` submodule. OPEN: three source files modified from
`https://github.com/morpho-org/midnight/tree/70607569ac348e9880b512ffd3b574be55405932`
(`src/interfaces/IMidnight.sol`, `src/libraries/TickLib.sol`, `src/libraries/IdLib.sol`), shape
and license per the owner's ruling on S-1/S-2. `RateLimitHelpers`: existing `makeBytes32Key` and
`makeAddressBytes32Key`, no new shape.

## Attack surface (drives T-4 required tests)

- **Mutable third-party reads feeding keys/checks:** `continuousFee`, `settlementFee`, `lossFactor`,
  `toMarket`, `updatePositionView`, `debt`, `withdrawable`; the offer's market hashes to the
  governance-supplied `marketId`.
- **Async/multi-step state a rogue allocator could grief:** resting maker offers, designated
  groups, ratifier authorization.
- **Value-manipulation surface:** loan token pushed into the proxy during a `take`; socialized
  losses through `lossFactor`; fee changes between configuration and trade.

## Operational requirements

Order: `touchMarket` on Midnight, `setMarketConfig`, rate-limit keys, then for maker mode
`setDesignatedGroups`, `setRatifierAuthorization`, strategy keys, `setMakeConfig`. The fork tests
need an EVM with CLZ (`evm_version = 'osaka'`), which is a repository setting outside this facet
PR. Deploy scripts are out of scope.
