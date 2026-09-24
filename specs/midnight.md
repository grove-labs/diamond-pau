---
facet: MidnightFacet
dir: midnight
chains: [mainnet]
integration_doc: MIDNIGHT_INTEGRATION.md
dependencies: []
---

# Midnight Integration Spec

## Summary

`MidnightFacet` lends stablecoins through Morpho Midnight fixed-term credit markets as a
taker: the ALMProxy buys credit units from makers' sell offers at a discount, sells them
back into makers' buy offers before maturity when it needs to exit early, and redeems
them at par out of repayments once they land. The purpose is fixed-rate, fixed-term yield
on idle USDC and USDS against overcollateralized borrowers, with every leg bounded by
governance price ticks, governance implied-yield rails and per-market rate limits. The facet never makes offers, never
supplies collateral, never borrows, never liquidates and never holds debt.

## External protocol

- **Protocol:** Morpho Midnight, `main` at commit
  `70607569ac348e9880b512ffd3b574be55405932` (the deployed code).
- **Contracts touched:**
  - `0x471686c42792F93528B000beF54bC10E3aa2045f` (mainnet): the Midnight singleton. The
    only contract the facet calls. Immutable, non-upgradeable.
  - `0xb72c416382c8A6399D0765CebfB032F040B00B3c` (mainnet): `SetterRatifier`. Not called
    by the facet; makers point their offers at it and the fork tests use it as the real
    ratifier instead of a test double.
- **Audited/battle-tested status:** eleven reports under
  `morpho-org/midnight/audits/` at the pinned commit (Spearbit, Cantina competition,
  Blackthorn, TrustSec, Stermi; 2026-04 through 2026-09). Live on mainnet since 2026-07
  with dust-sized depth on every market and none listed.
- **Trust assumptions:**
  - The singleton has no owner over positions or funds. Its `configurator` can enable
    LLTV and liquidation-cursor tiers, replace itself, and appoint a `feeSetter` (moves
    any market's settlement and continuous fees within hard-coded ceilings), a
    `feeClaimer` (withdraws accrued continuous fee out of a market's repayment pool,
    reducing `withdrawable`) and a `tickSpacingSetter` (refines tick spacing only). None
    of them can touch positions or move a lender's loan tokens.
  - Lender losses are socialized: a liquidation that cannot cover a borrower's debt
    writes the shortfall down across all lenders in the market through a monotone
    `lossFactor`. Oracle failure on any collateral tier is therefore a lender loss.
  - Redemption is first come first served out of a shared per-market repayment pool.
  - Makers' offers may carry a callback that Midnight executes inside the taker's own
    `take`, after the transfers when the maker sells and before them when the maker
    buys.
  - Offers are validated by the maker's ratifier contract; the singleton stores no order
    book and signs nothing.
- **House-constraint check:** loan tokens are USDC and USDS, non-rebasing, 6 and 18
  decimals, standard ERC-20. No oracle is read by the facet; Midnight's collateral
  oracles are a protocol-side solvency assumption, not a pricing leg. No seeding: the
  facet holds no intermediate token and uses no auxiliary module. A market must have been
  created once on the singleton (`touchMarket`, permissionless) before the facet can
  resolve its fee; the facet does not create markets.

## Functions

### `setMarketConfig(bytes32 marketId, MarketConfig calldata config)`

- **Role:** DEFAULT_ADMIN_ROLE
- **Value direction:** config
- **Rate limit:** none
- **Refill:** none, config only
- **Loss bounds:** `MarketConfig { uint16 maxBuyTick; uint16 minSellTick;
  uint16 minBuyYield; uint16 maxSellYield; uint16 maxContinuousFee;
  uint128 maxLossFactor; }`. `maxBuyTick <= 6744`
  (`MidnightFacet/max-buy-tick-oob`), `1 <= minSellTick <= 6744`
  (`MidnightFacet/min-sell-tick-oob`), `maxSellYield != 0`
  (`MidnightFacet/max-sell-yield-not-set`), `maxContinuousFee <= 1_00_00`
  (`MidnightFacet/max-continuous-fee-oob`). Ticks feed `tickToPrice`, which reverts above
  6744. `maxContinuousFee` is in centi-basis points a year, converted to the per-second
  rate the market stores by flooring; its ceiling of one percent a year is Midnight's own.
  `maxBuyTick == 0` disables entry;
  `minSellTick != 0` marks the market onboarded and gates `sell` and `redeem`. The two
  yield fields are in basis points a year and bound each leg a second time, in rate rather
  than in absolute price; the stricter of the two bounds binds. A zero `maxSellYield`
  would only ever clear at par and brick the exit, so it is rejected; a zero `minBuyYield`
  is the loosest entry bound that still refuses to pay more than a unit returns.
- **External calls:** none
- **Zero-amount semantics:** all-zero config is the default and means not onboarded.
  A zero `minSellTick` or `maxSellYield` is rejected outright, so an onboarded market
  cannot be un-onboarded through the facet; closing a market means zeroing `maxBuyTick`
  and leaving the exits configured. A zero `minBuyYield` is accepted and is not a disabled
  bound: it still refuses to pay above what a unit returns.

### `buy(bytes32 marketId, Fill[] calldata fills, uint256 maxAssetsIn) returns (uint256 assetsSpent)`

- **Role:** ALLOCATOR_ROLE
- **Value direction:** outbound (loan token leaves custody, credit units accrue to the
  proxy's Midnight position)
- **Rate limit:** `LIMIT_MIDNIGHT_BUY`, `makeBytes32Key(_LIMIT_BUY, marketId)`;
  enforcing decrease of the measured loan-token balance delta.
- **Refill:** none; entry is refilled by the exits.
- **Loss bounds:** `maxAssetsIn` (non-zero, also the exact approval granted to Midnight
  for the call); per-offer `tickToPrice(offer.tick) + settlementFee(marketId,
  timeToMaturity) <= tickToPrice(maxBuyTick)` and `tickToPrice(offer.tick) + settlementFee
  <= maxBuyPrice(minBuyYield, timeToMaturity, continuousFee)`, the price at which the all-in
  cash flow still earns `minBuyYield` at simple interest over ACT/365 on a payoff of par
  less the continuous fee crystallized for the remaining term; market `continuousFee <=
  continuousFeePerSecond(maxContinuousFee)` and `lossFactor <= maxLossFactor` at call time;
  exact credit delta
  (`credit_after == credit_before + sum(units)`) and zero debt after the batch.
- **External calls:** `midnight.take(fills[i].offer, fills[i].ratifierData,
  fills[i].units, proxy, address(0), address(0), "")` via `doCall`, once per offer, with
  `offer.buy == false`. Reads
  `continuousFee`, `lossFactor`, `settlementFee`, `updatePositionView`, `debt` on the
  immutable singleton only. `fills[0].offer.market.midnight` must equal the immutable
  singleton and every `fills[i].offer.market` must hash to `marketId`; `fills[0]` is
  checked before the price bounds are computed, so a fabricated maturity cannot reach the
  bound arithmetic.
- **Zero-amount semantics:** empty batch, zero `maxAssetsIn` and zero per-offer units
  all revert in the facet. Midnight itself would accept a zero
  take; the facet forbids it because a zero fill still runs the maker's callback.

### `sell(bytes32 marketId, Fill[] calldata fills, uint256 minAssetsOut) returns (uint256 assetsReceived)`

- **Role:** ALLOCATOR_ROLE
- **Value direction:** returning (loan token to proxy, credit units leave the position)
- **Rate limit:** `LIMIT_MIDNIGHT_SELL`, `makeBytes32Key(_LIMIT_SELL, marketId)`;
  enforcing decrease of the measured loan-token balance delta.
- **Refill:** `_tryIncreaseRateLimit(LIMIT_MIDNIGHT_BUY key, assetsReceived)`.
- **Loss bounds:** `minAssetsOut` (non-zero) over the batch; per-offer
  `tickToPrice(offer.tick) >= tickToPrice(minSellTick) + settlementFee(marketId,
  timeToMaturity)` and `tickToPrice(offer.tick) >= minSellPrice(maxSellYield,
  timeToMaturity, continuousFee) + settlementFee`, so the proceeds give up at most
  `maxSellYield` on the same basis the buy leg uses; per-offer units capped at the proxy's
  remaining live credit and the batch stops when credit is exhausted, so a sell can never
  create debt; exact credit delta (`credit_before == credit_after + sum(cappedUnits)`) and
  zero debt after the batch. The yield floor converges on par as maturity approaches, so a
  post-maturity sell only clears at par and a discounted dump against an available par
  redemption is refused; with a live settlement fee it does not clear at all, leaving
  `redeem` as the exit.
- **External calls:** `midnight.take(fills[i].offer, fills[i].ratifierData, cappedUnits,
  proxy, proxy, address(0), "")` via `doCall`, once per offer, with `offer.buy == true`.
  Reads
  `settlementFee`, `continuousFee`, `updatePositionView` and `debt` on the singleton. Same
  venue and id binding as `buy`.
- **Zero-amount semantics:** as `buy`; additionally a batch whose first offer caps to
  zero units (no credit) stops before any take and fails `minAssetsOut`.

### `redeem(bytes32 marketId, uint256 units, uint256 minAssetsOut) returns (uint256 assetsWithdrawn)`

- **Role:** ALLOCATOR_ROLE
- **Value direction:** returning (loan token to proxy at par)
- **Rate limit:** `LIMIT_MIDNIGHT_REDEEM`, `makeBytes32Key(_LIMIT_REDEEM, marketId)`;
  enforcing decrease of the measured loan-token balance delta.
- **Refill:** `_tryIncreaseRateLimit(LIMIT_MIDNIGHT_BUY key, assetsWithdrawn)`.
- **Loss bounds:** `minAssetsOut` (non-zero); `units` capped at both the proxy's live
  credit and the market's `withdrawable`; zero debt after the call. Redemption is at par,
  so no price bound applies.
- **External calls:** `midnight.toMarket(marketId)` to resolve the market from the id on
  the singleton (no market from calldata), then `midnight.withdraw(market, units, proxy,
  proxy)` via `doCall`.
- **Zero-amount semantics:** a zero `minAssetsOut` reverts
  (`MidnightFacet/min-assets-out-not-set`), and a request that caps to zero reverts
  (`MidnightFacet/zero-units`). `type(uint256).max` redeems everything currently
  available.

### Views

`getBuyRateLimitKey(bytes32)`, `getSellRateLimitKey(bytes32)`,
`getRedeemRateLimitKey(bytes32)` (pure key derivations), `getMarketConfig(bytes32)`,
`midnight()` (immutable).

## Fund-exit map

| # | Path | Destination | Bounded by |
|---|------|-------------|------------|
| 1 | `doCall` `midnight.take` (buy leg, proxy pays `buyerAssets` per offer) | Midnight singleton (settlement fee) and the maker's `receiverIfMakerIsSeller`, which must not be the proxy | `LIMIT_MIDNIGHT_BUY` per `marketId`; `maxAssetsIn` as both the approval and the post-check |

`sell` and `redeem` only move loan tokens into the proxy. Credit units are not a token and
cannot leave the proxy's position except through those two paths, both of which require
the proxy as receiver.

## Storage & constructor

- **ERC-7201 storage fields:** `mapping(bytes32 marketId => MarketConfig) marketConfigs`
  at `sky.pau.storage.MidnightFacet.v1`.
- **Immutables:** `address midnight`, the singleton every call is pinned to. Fixed at
  deploy because the market id from calldata already commits to a venue address and the
  facet must not call an address it read from calldata; repointing means a new facet and
  a spell.
- **Auxiliary module:** none.

## Standing approvals & declared exceptions

None. `buy` approves exactly `maxAssetsIn` to the singleton and resets it to zero after the
batch. `sell` and `redeem` grant no approval.

Declared deviations from the usual facet shape, each with rationale:

- **Opaque calldata forwarded to third parties.** Each `Fill`'s offer and ratifier data are
  passed through to Midnight and, by Midnight, to the maker's ratifier and callback. The
  facet validates outcomes (venue, id, direction, price bound, deltas, debt), not the
  offer's provenance. Callback-backed offers are how makers source liquidity, so banning
  callbacks is not an option; the reentrancy guard held for the whole batch and the exact
  post-checks are the containment.
- **Yield bounds derived in the facet, not read from the venue.** `maxBuyPrice` and
  `minSellPrice` in `MidnightUtils.sol` have no upstream counterpart: Midnight prices
  everything in absolute ticks, so a rate bound has to be converted into the price it
  implies at the current time to maturity. Simple interest over ACT/365, one division per
  leg, rounded against the caller (down for the buy ceiling, up for the sell floor). Both
  Midnight fees are inside the comparison, so a fee change re-prices the bound instead of
  leaving it stale; within hours of maturity the sell floor plus the settlement fee can
  exceed par, which closes the sell leg until the fee falls or `maxSellYield` is widened.
  The arithmetic cannot overflow or underflow: upstream caps maturity 100 years
  out (`MaturityTooFar`) and the continuous fee at 1% a year, whose product stays below par.
- **Vendored structs and tick math.** `Market`, `Offer`, `CollateralParams`, `toId`
  and `tickToPrice` are copied verbatim into `MidnightUtils.sol` from the pinned commit,
  because the market id is a hash over `abi.encode(market)` and the price bound has to be
  bit-identical to the venue's. No `lib/` submodule: the protocol repo is not a Foundry
  library the facet can import cleanly and only these few definitions are needed. The
  fork suite proves parity against three live market ids. The `unchecked` blocks in the
  vendored `wExp` and `divHalfDownUnchecked` are kept as upstream wrote them for the same
  reason.
- **One shared config struct instead of per-knob setters**, packed into one slot: the
  four limits are only meaningful together and are set together in a spell.

## Dependencies

None added. Upstream reference for the vendored code:
`https://github.com/morpho-org/midnight` at `70607569ac348e9880b512ffd3b574be55405932`
(`src/interfaces/IMidnight.sol`, `src/libraries/TickLib.sol`, `src/libraries/IdLib.sol`,
`src/libraries/ConstantsLib.sol`). No new `RateLimitHelpers` shape: `makeBytes32Key`
exists.

## Attack surface (drives T-4 required tests)

- **Mutable third-party reads feeding keys/checks:** none feed a key; the only key salt is
  the governance-supplied `marketId`. `continuousFee`, `lossFactor`, `settlementFee`,
  `updatePositionView`, `withdrawable`, `debt` and `toMarket` feed guards that fail
  closed; `continuousFee` and `settlementFee` also feed the yield bounds, where a higher
  value can only tighten them. Required attack tests: a hostile maker callback
  attempting `take`, `withdraw`,
  `setIsAuthorized` and `repay` against the proxy from inside a fill
  (`test_attack_hostileMakerCallback_buyMidnight`); a callback draining the rest of the
  batch (`test_attack_hostileMakerCallbackDrainsBatch_buyMidnight`, whole buy unwinds); a
  callback socializing a third borrower's bad debt mid-fill in both directions
  (`test_attack_slashedMidBatch_{buy,sell}Midnight`, caught by the credit-delta check);
  mocked venue reads for the two guards a live venue cannot trip
  (`test_attack_debtReported_*`, `test_attack_loanTokenOvercharges_buyMidnight`).
- **Async/multi-step state a rogue allocator could grief:** none. Every operation settles
  in one transaction; there is no pending request state.
- **Value-manipulation surface (donation/inflation/rounding):** none on the proxy side.
  Units are not shares; credit is written down only by `lossFactor`, which is gated on
  entry and bounded on exit by the live-credit cap. A sell offer naming the proxy as
  proceeds receiver would net the spend to the fee and under-report it to the rate limit;
  rejected (`MidnightFacet/invalid-offer-receiver`).

## Operational requirements

1. Confirm the market exists on the singleton (`toMarket(marketId)` resolves and
   `settlementFee` does not revert); `touchMarket` it once otherwise.
2. Review what the id commits to: loan token, maturity, collateral tiers (LLTV,
   liquidation cursor, oracle), `rcfThreshold`, gates. An LLTV `1e18` tier is a
   due-diligence red flag.
3. `setMarketConfig(marketId, config)` with a reachable `minSellTick` (below par net of
   the settlement fee), the highest acceptable all-in `maxBuyTick` for the remaining
   term, a `minBuyYield` and a non-zero `maxSellYield` in basis points a year, and
   `maxContinuousFee` (centi-basis points a year) / `maxLossFactor` at the tolerances the
   position can absorb (both default to zero). The yield bounds track the shortening term
   on their own; the tick bounds do not and go stale as maturity approaches.
4. Configure `LIMIT_MIDNIGHT_BUY`, `LIMIT_MIDNIGHT_SELL` and `LIMIT_MIDNIGHT_REDEEM`
   keyed `marketId`, in the loan token's units. Exits are gated only by their own keys.
5. Monitoring: `lossFactor` per market (any increase is a realized write-down), fee
   setter and tier changes by the configurator, `withdrawable` against credit around
   maturity, collateral oracle health, maker concentration. The integration makes no
   liquidity claims; the exit before maturity is a maker's buy offer.
6. Address registry: `MIDNIGHT` and `SETTER_RATIFIER` are not in
   `grove-address-registry` yet; the fork tests carry local constants until they are.
