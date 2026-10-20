---
facet: MidnightFacet
dir: midnight
chains: [mainnet]
integration_doc: MIDNIGHT_INTEGRATION.md
dependencies: []
---

# Midnight Integration Spec

## Summary

`MidnightFacet` lends stablecoins through Morpho Midnight fixed-term credit markets in two
modes. As a **taker** the ALMProxy buys credit units from makers' sell offers at a discount,
sells them back into makers' buy offers before maturity when it needs to exit early, and
redeems them at par out of repayments once they land. As a **maker** it rests its own signed
offers on both sides: third parties call `take` on the singleton directly, a purpose-built
ratifier re-validates governance policy at fill time, and a funding strategy pulls the cash
for the entry leg through `fundFill`. The purpose is fixed-rate, fixed-term yield
on idle USDC and USDS against overcollateralized borrowers, with every leg bounded by
governance price ticks, governance implied-yield rails and per-market rate limits. The facet
never supplies collateral, never borrows, never liquidates and never holds debt.

Maker mode moves policy enforcement off the call path: the facet is not in the transaction
when a resting offer is filled on the exit side, so the ratifier is the only thing standing
between a published offer and a fill. Every bound it checks is read live from the facet's
storage, which makes the whole book retroactively revocable — tightening a bound, zeroing
`maxOfferSize`, retiring a group or de-authorizing the ratifier all kill offers that are
already signed and published, and therefore unrecallable.

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
  - **Authorizing a ratifier is a blanket grant, not a ratification-scoped one.** Maker mode
    needs `isAuthorized[proxy][ratifier]` (`Midnight.sol#L386`), and that same flat mapping
    gates `withdraw` (`#L518`), `repay` (`#L541`), `supplyCollateral` (`#L563`),
    `withdrawCollateral` (`#L594`), `setConsumed` (`#L762`) and `setIsAuthorized` (`#L770`)
    on the proxy's behalf. Upstream offers no narrower grant. The authorized address is
    therefore trusted with the entire position, which is why it is a purpose-built contract
    with no arbitrary-call surface and no upgrade path rather than an EOA or a shared
    ratifier, and why the controller's own view of the singleton declares no collateral,
    borrow, liquidate or flash-loan entry point at all.
  - A fill of one of our resting offers is driven entirely by the taker. The exit leg runs no
    code of ours, and the entry leg runs only the funding callback. Neither can be initiated,
    scheduled or front-run by the allocator.
- **House-constraint check:** loan tokens are USDC and USDS, non-rebasing, 6 and 18
  decimals, standard ERC-20. No oracle is read by the facet; Midnight's collateral
  oracles are a protocol-side solvency assumption, not a pricing leg. No seeding: the
  facet holds no intermediate token and uses no auxiliary module. A market must have been
  created once on the singleton (`touchMarket`, permissionless) before the facet can
  resolve its fee; the facet does not create markets.

## Functions

### `setMarketConfig(bytes32 marketId, uint16 maxBuyTick, uint16 minSellTick, uint16 minBuyYield, uint16 maxSellYield, uint16 maxContinuousFee, uint128 maxLossFactor)`

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

### `setDesignatedGroups(bytes32 marketId, bytes32 buyGroup, bytes32 sellGroup)`

- **Role:** DEFAULT_ADMIN_ROLE
- **Value direction:** config
- **Rate limit:** none
- **Refill:** none, config only
- **Loss bounds:** `DesignatedGroups { bytes32 buyGroup; bytes32 sellGroup; }` per `marketId`.
  `buyGroup != sellGroup` unless both are zero (`MidnightFacet/groups-not-distinct`), because
  a shared group would make neither book cancellable on its own. These two values are the
  only groups the ratifier will ratify an offer into, and therefore the only groups
  `cancelOfferGroup` needs to be able to retire.
- **External calls:** none
- **Zero-amount semantics:** both zero is the default and designates nothing. An acceptable
  ratifier refuses an undesignated direction outright, so a zero group must not act as a
  wildcard matching an offer that carries group zero. Designating only one side makes the
  market one-directional.

### `setMakeConfig(Market calldata market, uint256 maxOfferSize)`

- **Role:** DEFAULT_ADMIN_ROLE
- **Value direction:** config
- **Rate limit:** none
- **Refill:** none, config only
- **Loss bounds:** `MakeConfig { uint256 maxOfferSize; uint64 maturity; address loanToken; }`.
  `market.midnight` must equal the immutable singleton; the market must already be onboarded
  for taking (`marketConfigs[marketId].minSellTick != 0`,
  `MidnightFacet/market-not-onboarded`), so making can never run on a market whose price
  bounds were never set; `market.maturity <= type(uint64).max`;
  `maxOfferSize <= type(uint128).max`, since an offer's own size fields are `uint128` and a
  larger cap could never bind; and `toMarket(marketId).maturity == market.maturity`, which
  reverts unless the market exists on the singleton. `maxOfferSize` is intended to bound each
  single resting offer, in units or assets whichever the offer sets, rather than the book, but
  no contract enforces that: the facet reads it only as `!= 0` and the deployed ratifier does
  not read it at all, so a single fill is bounded only by the direction
  limit, not by this value.
- **External calls:** `midnight.toMarket(marketId)` (view only).
- **Zero-amount semantics:** `maxOfferSize == 0` is the default and means making is disabled.
  It is also the per-market kill switch, but not a graceful one: the ratifier does not read it,
  so a zeroed market keeps ratifying and the fill then fails inside `fundFill`
  (`MidnightFacet/make-not-enabled`), reverting the taker. `cancelOfferGroup` retires the book
  instead and is the better stop.

### `setRatifierAuthorization(address ratifier, bool authorized)`

- **Role:** DEFAULT_ADMIN_ROLE
- **Value direction:** config, but it grants a blanket authorization over the proxy's
  position on the venue. See the trust assumption above before using it.
- **Rate limit:** none
- **Refill:** none, config only
- **Loss bounds:** `ratifier != address(0)` (`MidnightFacet/zero-ratifier`). Nothing else is
  checked, because nothing on-chain can usefully constrain what the grantee is; the
  containment is that only a reviewed, non-upgradeable contract is ever granted it.
- **External calls:** `midnight.setIsAuthorized(ratifier, authorized, proxy)` via `doCall`.
- **Zero-amount semantics:** n/a. `authorized == false` revokes, and revocation is the global
  kill switch: it invalidates every resting offer naming that ratifier in one transaction,
  across all markets and both directions.

### `setCallbackAllowed(bytes32 marketId, address callback, bool allowed)`

- **Role:** DEFAULT_ADMIN_ROLE
- **Value direction:** config, but the entry it writes is what authorizes a contract to draw
  the proxy's loan token through `fundFill`.
- **Rate limit:** none
- **Refill:** none, config only
- **Loss bounds:** `callback != address(0)` (`MidnightFacet/zero-callback`). A zero callback is
  never invoked upstream, so allowing it would ratify fills that never reach the facet.
  Nothing else is checked: the containment is that only a reviewed, non-upgradeable strategy
  is ever whitelisted, and the make and direction limits bound what it can draw.
- **External calls:** none
- **Zero-amount semantics:** n/a. Setting the same value twice is a no-op write; see
  `removeCallback` for the allocator-level revocation.

### `removeCallback(bytes32 marketId, address callback)`

- **Role:** ALLOCATOR_ROLE
- **Value direction:** config, strictly tightening. It can only clear a whitelist entry, and
  re-setting one is `setCallbackAllowed` at admin level, which is why it is safe at allocator
  level while that setter is not.
- **Rate limit:** none
- **Refill:** none, config only
- **Loss bounds:** the entry must currently be set (`MidnightFacet/callback-not-allowed`), so
  the call is never a no-op. As a power handed to an allocator it is a subset of
  `cancelOfferGroup`, which the same role already holds and which stops a market's maker flow
  irreversibly. What it covers that no other lever does is a whitelisted strategy calling
  `fundFill` with no fill behind it, which involves no offer, group, ratifier or `take`.
- **External calls:** none
- **Zero-amount semantics:** n/a. Offers naming the removed callback are not recalled; their
  fills revert inside `fundFill` from here on, which fails the taker's transaction.

### `buy(bytes32 marketId, Offer calldata offer, bytes calldata ratifierData, uint256 units, uint256 maxAssetsIn) returns (uint256 assetsSpent)`

- **Role:** ALLOCATOR_ROLE
- **Value direction:** outbound (loan token leaves custody, credit units accrue to the
  proxy's Midnight position)
- **Rate limit:** `LIMIT_MIDNIGHT_BUY`, `makeBytes32Key(_LIMIT_BUY, marketId)`;
  enforcing decrease of the measured loan-token balance delta.
- **Refill:** none; entry is refilled by the exits.
- **Loss bounds:** `maxAssetsIn` (non-zero, also the exact approval granted to Midnight
  for the call); `tickToPrice(offer.tick) + settlementFee(marketId,
  timeToMaturity) <= tickToPrice(maxBuyTick)` and `tickToPrice(offer.tick) + settlementFee
  <= maxBuyPrice(minBuyYield, timeToMaturity, continuousFee)`, the price at which the all-in
  cash flow still earns `minBuyYield` at simple interest over ACT/365 on a payoff of par
  less the continuous fee crystallized for the remaining term; market `continuousFee <=
  continuousFeePerSecond(maxContinuousFee)` and `lossFactor <= maxLossFactor` at call time;
  exact credit delta
  (`credit_after == credit_before + units`) and zero debt after the take.
- **External calls:** `midnight.take(offer, ratifierData, units, proxy, address(0),
  address(0), "")` via `doCall`, once, with `offer.buy == false`. Reads
  `continuousFee`, `lossFactor`, `settlementFee`, `updatePositionView`, `debt` on the
  immutable singleton only. `offer.market.midnight` must equal the immutable
  singleton and `offer.market` must hash to `marketId`; both are
  checked before the price bounds are computed, so a fabricated maturity cannot reach the
  bound arithmetic.
- **Zero-amount semantics:** zero `maxAssetsIn` and zero `units`
  both revert in the facet. Midnight itself would accept a zero
  take; the facet forbids it because a zero fill still runs the maker's callback.
- **Batching:** none. One call takes one offer; a relayer wanting several issues several
  calls in one transaction, each with its own bound, allowance and meter decrease.

### `sell(bytes32 marketId, Offer calldata offer, bytes calldata ratifierData, uint256 units, uint256 minAssetsOut) returns (uint256 assetsReceived)`

- **Role:** ALLOCATOR_ROLE
- **Value direction:** returning (loan token to proxy, credit units leave the position)
- **Rate limit:** `LIMIT_MIDNIGHT_SELL`, `makeBytes32Key(_LIMIT_SELL, marketId)`;
  enforcing decrease of the measured loan-token balance delta.
- **Refill:** `_tryIncreaseRateLimit(LIMIT_MIDNIGHT_BUY key, assetsReceived)`.
- **Loss bounds:** `minAssetsOut` (non-zero);
  `tickToPrice(offer.tick) >= tickToPrice(minSellTick) + settlementFee(marketId,
  timeToMaturity)` and `tickToPrice(offer.tick) >= minSellPrice(maxSellYield,
  timeToMaturity, credit, pendingFee) + settlementFee`, so the proceeds give up at most
  `maxSellYield` on the same basis the buy leg uses. A position keeps the continuous fee it
  was bought at, so the floor is measured against the lien that position still carries
  (`pendingFee / credit` from `updatePositionView`) rather than the market's current rate,
  which a later fee change would otherwise move in either direction; `units`
  capped at the proxy's live credit, and a cap to zero reverts
  (`MidnightFacet/no-credit-to-sell`), so a sell can never create debt; exact credit delta
  (`credit_before == credit_after + cappedUnits`) and zero debt after the take. A lien is fully accrued by maturity, so
  the yield-implied price floor converges on par, and a post-maturity sell only clears at
  par; a discounted dump against an available par redemption is refused, and with a live
  settlement fee it does not clear at all, leaving `redeem` as the exit. That costs
  nothing: a sell nets the tick price less the settlement fee while `redeem` pays par with
  no fee, so no post-maturity sell can beat redemption. No configuration reopens a
  discounted exit either, since the floor at zero time to maturity is par for every
  `maxSellYield`.
- **External calls:** `midnight.take(offer, ratifierData, cappedUnits,
  proxy, proxy, address(0), "")` via `doCall`, once, with `offer.buy == true`.
  Reads `settlementFee`, `updatePositionView` and `debt` on the singleton; the market's
  `continuousFee` is not read, since the floor comes from the position. Same venue and id
  binding as `buy`.
- **Zero-amount semantics:** as `buy`; additionally an ask against a position with no live
  credit caps to zero and reverts `MidnightFacet/no-credit-to-sell` before any take.
- **Batching:** none, as `buy`.

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

### `cancelOfferGroup(bytes32 group)`

- **Role:** ALLOCATOR_ROLE
- **Value direction:** none
- **Rate limit:** none
- **Refill:** none
- **Loss bounds:** sets the group's consumed counter to `type(uint128).max`. Midnight rejects
  any amount below what the group has already consumed, so the call can only ever retire a
  group and never reopen one, which is why it is safe at allocator level while the setters
  above are admin-only. Groups are per direction, so entries can be retired while exits stay
  fillable.
- **External calls:** `midnight.setConsumed(group, type(uint128).max, proxy)` via `doCall`.
- **Zero-amount semantics:** a group nothing ever used is retired just the same, with no
  effect beyond making it permanently unusable.

### `fundFill(bytes32 marketId, bool buying, uint256 assets, uint256 units, uint256 pendingFee)`

Called by a whitelisted funding strategy from inside Midnight's `onBuy` or `onSell`, never by
an allocator. It is the only facet function reached from a third party's transaction.

- **Role:** none, deliberately. The per-market callback whitelist is the authorization
  (`MidnightFacet/callback-not-allowed`), so onboarding is one `setCallbackAllowed` and
  revoking is that same call with `false` at admin level or `removeCallback` at allocator
  level, with no role grant to track separately.
- **Value direction:** outbound on an entry (loan token leaves custody to the calling
  strategy; credit units accrue to the proxy's position in the same `take`). None on an exit:
  Midnight paid the proxy before calling back, so that branch meters and prices only.
- **Rate limit:** `LIMIT_MIDNIGHT_BUY` keyed `marketId` on an entry, `LIMIT_MIDNIGHT_SELL` on
  an exit, decremented by `assets` before any transfer. There is no separate maker budget:
  maker and taker traffic share one per-market budget per direction.
- **Refill:** neither maker leg restores anything, so entry room comes back only from the buy
  key's own slope. A maker exit burns exit room without returning entry room.
- **Loss bounds, both directions:** `makeConfig.maxOfferSize != 0`; non-zero `assets` and
  `units`. On an entry: `lossFactor(marketId) <= maxLossFactor` and
  `continuousFee(marketId) <= continuousFeePerSecond(maxContinuousFee)`, both read live, so a
  market whose lenders have already been slashed stops funding fills and a live fee above the
  rate the bound was priced at cannot slip through, and `assets * WAD <= units * maxFillPrice`,
  where `maxFillPrice` is the lesser of `tickToPrice(maxBuyTick)` and
  `maxBuyPrice(minBuyYield, timeToMaturity, continuousFeePerSecond(maxContinuousFee))`. The
  transfer is the last step, after both meters have been debited. On an exit:
  `assets * WAD >= units * minFillPrice`, where `minFillPrice` is the greater of
  `tickToPrice(minSellTick)` and `minSellPrice(maxSellYield, timeToMaturity, WAD, feePerUnit)`,
  plus `debt(marketId, proxy) == 0` as a post-condition. Neither the loss factor nor the live
  fee is checked on an exit, since a slashed market is when an exit matters most and an exit
  moves none of our money. Both comparisons are cross-multiplied, so no division widens them.
- **External calls:** on an entry, `midnight.lossFactor(marketId)` and
  `midnight.continuousFee(marketId)` (views) then `loanToken.transfer(msg.sender, assets)` via
  `doCall`, with the loan token read from stored `MakeConfig` rather than from the caller. On
  an exit, `midnight.toMarket`, `midnight.updatePositionView` and `midnight.debt`, all views.
- **Zero-amount semantics:** zero `assets` and zero `units` both revert, in either direction.
  The strategy short-circuits a zero-asset callback before it reaches here.

**The exit floor's fee basis is clamped to what the position carries.** `onSell` reports
`sellerPendingFeeDecrease`, the lien the fill sheds, and a shed lien justifies a lower price
because the proxy gives up less than par. That argument only holds for a lien that exists, and
the reported number is not evidence of one: an unverified `pendingFee` is the one input that
*lowers* the floor, and at the limit it lowers it to nothing. The facet therefore reads the
position back with `toMarket` + `updatePositionView` and uses
`min(pendingFee / units, carriedFee / credit)`. Midnight splits `pendingFee` pro rata with
`credit`, so the per-unit lien remaining equals the per-unit lien shed and the venue read is
exact rather than approximate. A full exit leaves `credit == 0` and therefore no ratio to read;
that case falls back to a zero fee per unit, the strictest basis available. Overstating is
clamped away, understating only tightens the floor.

**The maker entry bound is strictly tighter than `buy`'s.** `fundFill` prices the continuous
fee at the *configured cap*, while `buy` prices the market's *live* rate, because an offer is
signed before the rate it will settle at is known and the ratifier has to agree with
`fundFill` at signing time. At a 180 day term with the 1%/year cap the gap is about 48 basis
points. An operator who sets `maxBuyTick` at the edge of what taker entry accepts will find
maker buys at that same tick rejected with `buy-yield-too-low`; the maker entry tick has to
clear the capped-fee bound, not the live-fee one.

### Views

`getBuyRateLimitKey(bytes32)`, `getSellRateLimitKey(bytes32)`,
`getRedeemRateLimitKey(bytes32)` (pure key derivations),
`getMarketConfig(bytes32)`, `getMakeConfig(bytes32)`, `getDesignatedGroups(bytes32)`,
`isCallbackAllowed(bytes32, address)`, `midnight()` (immutable). The ratifier staticcalls
`getDesignatedGroups` and `isCallbackAllowed` on every fill, so those two views are a live
policy interface, not diagnostics. Upstream declares `isRatified` as `view`, so that read path
has to survive a static context: the controller's dispatch does no write of its own, and
`MidnightWiring.t.sol` pins it.

## Fund-exit map

| # | Path | Destination | Bounded by |
|---|------|-------------|------------|
| 1 | `doCall` `midnight.take` (taker buy leg, proxy pays `buyerAssets` per offer) | Midnight singleton (settlement fee) and the counterparty maker's `receiverIfMakerIsSeller`, which must not be the proxy | `LIMIT_MIDNIGHT_BUY` per `marketId`; `maxAssetsIn` as both the approval and the post-check |
| 2 | `doCall` `loanToken.transfer` inside `fundFill` (maker entry leg) | the calling funding strategy, which approves the exact amount to the singleton and is drained by it in the same `take` | per-market callback whitelist as the authorization; `LIMIT_MIDNIGHT_BUY`, debited by `assets` before the transfer; `assets * WAD <= units * maxFillPrice`; live `lossFactor` and live `continuousFee` |
| 3 | a third party's `take` against a resting proxy sell offer (maker exit leg) | `offer.receiverIfMakerIsSeller`, which the ratifier requires to be the proxy | the ratifier at fill time (parties, group, expiry, window, receiver, signature, callback whitelist); the offer's own `maxUnits` against the group's consumed counter; `fundFill` through `onSell`, which enforces `assets * WAD >= units * minFillPrice` on the clamped fee basis, requires zero debt afterwards, and debits `LIMIT_MIDNIGHT_SELL` |

Path 3 is the one asymmetry in the integration: **credit units can leave the proxy's position
without any transaction of ours.** A third party calls the singleton directly, and whether the
fill happens at all is decided by the ratifier's view call. `onSell` then reaches `fundFill`,
so the realized price and the meters are enforced by the facet, but a revert there reverts the
*taker*, not us. That is why the receiver check is a ratifier invariant rather than a facet
post-check, and why the exit floor clamps the reported lien against the one the position still
carries rather than trusting the number it is handed. One post-condition is available and is
used: positions are written before `onSell` fires, so `debt(marketId, proxy) == 0` reads the
result of the fill being reported and is what keeps the proxy lender-only. Upstream's own
check at the end of `take` is weaker on both counts, since it accepts a merely *healthy*
seller and is skipped altogether for the inner take of a nested one. The credit delta itself
still cannot be re-derived, since the callback carries no offer. The exposure is bounded by
what is signed, by the offer's `maxUnits` against the group counter, by the two meters, and by
the six revocation levers.

Path 2 moves loan tokens to a contract that is not the proxy, which no other facet path does.
The containment is that the strategy is reviewed, non-upgradeable, holds no balance between
settlements, and is drained by the singleton inside the same `take` that funded it; a
disagreement between what `fundFill` sent and what the singleton pulls leaves the pull
unfunded and reverts the whole settlement.

`sell`, `redeem` and path 3 all move loan tokens into the proxy. Credit units are not a token:
they cannot leave the proxy's position except through `sell`, `redeem` or path 3, and all
three require the proxy as receiver.

## Storage & constructor

- **ERC-7201 storage fields:** at `sky.pau.storage.MidnightFacet.v1`,
  `mapping(bytes32 marketId => MarketConfig) marketConfigs`,
  `mapping(bytes32 marketId => MakeConfig) makeConfigs` and
  `mapping(bytes32 marketId => DesignatedGroups) designatedGroups`. The last two are
  maker-only and read by the ratifier on every fill.
- **Immutables:** `address midnight`, the singleton every call is pinned to. Fixed at
  deploy because the market id from calldata already commits to a venue address and the
  facet must not call an address it read from calldata; repointing means a new facet and
  a spell.
- **Auxiliary module:** none.

## Standing approvals & declared exceptions

None. `buy` approves exactly `maxAssetsIn` to the singleton and resets it to zero after the
take. `sell`, `redeem`, `fundFill` and the maker exit leg grant no approval from the proxy.

The funding strategy does approve the singleton, but not standingly: it is a periphery
contract holding no proxy funds, it sets the allowance with `forceApprove` to exactly the
amount Midnight is about to pull, and the pull consumes it inside the same `take`. Nothing
accumulates across fills, and the fork suite asserts the strategy ends every settlement
holding zero tokens and granting zero allowance. There is deliberately no
`setMakerAllowance`-style standing grant from the proxy to the singleton for maker mode; that
design was considered and rejected.

Declared deviations from the usual facet shape, each with rationale:

- **Opaque calldata forwarded to third parties.** The offer and its ratifier data are
  passed through to Midnight and, by Midnight, to the maker's ratifier and callback. The
  facet validates outcomes (venue, id, direction, price bound, deltas, debt), not the
  offer's provenance. Callback-backed offers are how makers source liquidity, so banning
  callbacks is not an option; the reentrancy guard held for the whole call and the exact
  post-checks are the containment.
- **Yield bounds derived in the facet, not read from the venue.** `maxBuyPrice` and
  `minSellPrice` in `MidnightUtils.sol` have no upstream counterpart: Midnight prices
  everything in absolute ticks, so a rate bound has to be converted into the price it
  implies at the current time to maturity. Simple interest over ACT/365, one division per
  leg, rounded against the caller (down for the buy ceiling, up for the sell floor). Both
  Midnight fees are inside the comparison, so a fee change re-prices the bound instead of
  leaving it stale; within hours of maturity the sell floor plus the settlement fee can
  exceed par, which closes the sell leg until the fee falls or `maxSellYield` is widened.
  Past maturity widening does not help, because the floor is par for every value.
  The arithmetic cannot overflow or underflow: upstream caps maturity 100 years
  out (`MaturityTooFar`) and the continuous fee at 1% a year, whose product stays below par.
  That bound applies because the market is checked against `marketId` before the floor is
  computed; a fabricated maturity would otherwise underflow it.
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
- **A facet function with no role gate.** `fundFill` is reached from a third party's
  transaction, so the caller is a contract address rather than a role holder. A per-market
  callback whitelist is the authorization: onboarding is one `setCallbackAllowed`, revoking is
  that same call with `false` or `removeCallback`, and there is no separate role grant that
  could be left behind after revocation. Every other gate on the function is unconditional.
- **Maker legs that restore nothing.** The whitelist makes a callback usable but carries no
  amount, so the per-direction keys are what bound all whitelisted callbacks on a market,
  alongside taker traffic. Neither maker leg calls `_tryIncreaseRateLimit`, unlike the taker
  exits, which is what stops a fabricated exit from manufacturing entry room: it burns the
  sell key and returns nothing.
- **Two periphery contracts that are not facets, and do not ship from this repository.** A
  ratifier must be standalone because the singleton calls `isRatified` on the address named in
  the offer and that address holds the blanket authorization; a funding strategy must be
  standalone because the singleton calls `onBuy` or `onSell` on the address named in the
  offer's callback field and on an entry that address temporarily receives proxy funds. Both are immutable with no upgrade
  path and hold no proxy funds between settlements. Neither is in the diamond, so neither can
  be reached through the controller, and neither is audited or opcode-scanned here: both come
  from the periphery repository, which also carries the integration tests that exercise real
  policy against this facet. The dummies under `test/mocks` carry none of it.
- **Policy read back through the controller.** The ratifier reads `getDesignatedGroups` and
  `isCallbackAllowed` through `IMidnightController` rather than holding its own copy, and
  `fundFill` reads the rest per fill. One source of truth, and it is what makes every bound
  retroactive over published offers; the cost is that both depend on the diamond being live.

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
  (`test_attack_hostileMakerCallback_buyMidnight`); a
  callback socializing a third borrower's bad debt mid-fill in both directions
  (`test_attack_slashedMidFill_{buy,sell}Midnight`, caught by the credit-delta check);
  mocked venue reads for the two guards a live venue cannot trip
  (`test_attack_debtReported_*`, `test_attack_loanTokenOvercharges_buyMidnight`).
- **Async/multi-step state a rogue allocator could grief:** none. Every operation settles
  in one transaction; there is no pending request state.
- **Value-manipulation surface (donation/inflation/rounding):** none on the proxy side.
  Units are not shares; credit is written down only by `lossFactor`, which is gated on
  entry and bounded on exit by the live-credit cap. A sell offer naming the proxy as
  proceeds receiver would net the spend to the fee and under-report it to the rate limit;
  rejected (`MidnightFacet/invalid-offer-receiver`).
- **Maker mode, third-party entry into `fundFill`:** the function is role-free and reachable
  from any transaction, so it is the only facet entry point an attacker can call directly.
  Required attack tests: a direct call from an address that is not whitelisted; a call from an
  address whose whitelist entry was removed; a call whitelisted on a different market; a call
  claiming more `assets` than `units` can justify at the configured entry bound; a call
  reporting fewer `assets` than the configured exit floor allows; a call on a market with
  making disabled or never onboarded; a call on a slashed market. All seven fail closed, and
  the funding path is additionally pinned by the strategy refusing any `buyer` other than the
  proxy and any `msg.sender` other than the singleton.
- **Maker mode, a whitelisted strategy reporting fills that never happened:** nothing in
  `fundFill` proves a fill occurred, because `onBuy` fires before the singleton's transfers
  and `onSell` carries no offer, so neither a credit delta nor a debt-free post-condition is
  available. An entry reported out of band pays out only to `msg.sender`, and is bounded by
  the remaining buy budget rather than by the price bound, which only ties `assets` to a
  `units` the caller picks. An exit reported out of band moves nothing and restores nothing,
  so it cannot manufacture entry room; it only burns the sell budget. Required attack test: a
  fabricated exit, asserting the entry budget is unchanged and a later entry still reverts.
- **Maker mode, forged or substituted offers:** an attacker can publish an offer naming the
  proxy as maker, our ratifier, or our strategy, and call `take` on it. Required attack
  tests: an offer naming the proxy as maker with an attacker's ratifier (fails on
  `isAuthorized`, which only the admin can grant); an offer naming our ratifier but signed by
  anything other than the quoter (fails on the signature, checked first); an offer naming our
  strategy with `buyer != proxy` (fails in the strategy); a self-take (fails upstream with
  `SelfTake()`).
- **Maker mode, upstream validation that runs before ours:** the singleton checks taker
  authorization, `lossFactor`, offer caps, the continuous-fee cap, tick alignment, `start`,
  `expiry`, `SelfTake` and `UnusedReceiverMustBeZero` *before* it calls `isRatified`
  (`Midnight.sol#L372-387`). A ratifier invariant that contradicts one of those makes an
  offer unfillable rather than unsafe, but it is a liveness bug that only a test against real
  singleton bytecode can find: requiring `receiverIfMakerIsSeller == proxy` on a buy offer
  contradicts `#L382-385` and silently bricked the entire entry side until the fork suite
  caught it. Required test: a full maker lifecycle against the deployed singleton, not a mock.
- **Maker mode, a consumed offer stays pokeable:** `take` has no zero-unit guard, the per-group
  cap `newConsumed <= offer.maxUnits` passes trivially at zero, and the buy callback is guarded
  only by `buyerCallback != address(0)` (`Midnight.sol#L481`). Any resting offer of ours,
  including a fully consumed one, can therefore be poked indefinitely with `units = 0`, reaching
  the strategy's `onBuy` with `buyerAssets = 0`. The strategy returns the success value without
  calling `fundFill`, nothing moves, and the two zero-value settlement legs need no allowance, so
  the no-standing-approval model holds. Without that short-circuit the poke reverts
  `MidnightFacet/zero-assets`, which fails an unrelated taker's transaction rather than ours.
  Required test: a zero-unit poke on a consumed offer against the deployed singleton.
- **Maker mode, nested entry into the controller:** filling one of our resting buy offers runs
  through `fundFill`, so a hostile callback reached during one of our own takes can attempt a
  second controller entry. Two independent layers refuse it: the diamond's shared reentrancy
  guard fires first, and the buy path's credit-delta check rejects any credit change that lands
  inside a fill, whatever moved it. Required tests: a hostile sell-offer callback taking one of
  our resting buy offers inside one of our own takes, asserting which guard refused; and a
  callback that writes the position down mid-fill, asserting `MidnightFacet/credit-delta-mismatch`.

## Operational requirements

1. Confirm the market exists on the singleton (`toMarket(marketId)` resolves and
   `settlementFee` does not revert); `touchMarket` it once otherwise.
2. Review what the id commits to: loan token, maturity, collateral tiers (LLTV,
   liquidation cursor, oracle), `rcfThreshold`, gates. An LLTV `1e18` tier is a
   due-diligence red flag.
3. `setMarketConfig(marketId, ...)` with a reachable `minSellTick` (below par net of
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

### Enabling maker mode on a market

Maker mode is off until all six of these are done, and each one on its own is a kill switch.
Steps 1 to 4 are prerequisites for taking as well, the rate limits included: a maker entry
debits the buy key and a maker exit the sell key, and `_decreaseRateLimit` has no existence
guard, so an unset key reverts `RateLimits/zero-maxAmount` instead of passing.

7. Deploy the ratifier and the funding strategy from the periphery repository. Both are
   immutable; rotating either means a new deployment and a spell. Before authorizing
   anything: review the deployed bytecode against the audited source, confirm the ratifier
   enforces the policy list in `docs/MIDNIGHT_INTEGRATION.md`, and run the opcode scan over
   its runtime. None of those three is verifiable from this repository.
8. `setMakeConfig(market, maxOfferSize)` on an already-onboarded market. Non-zero enables
   making; it is stored as a per-offer cap but nothing on chain enforces it as one, so size
   the rate limits to bound a fill.
9. `setDesignatedGroups(marketId, buyGroup, sellGroup)` with two distinct non-zero groups.
   Leave a side zero to make the market one-directional. These are the only groups
   `cancelOfferGroup` can retire, so publish offers into nothing else.
10. `setCallbackAllowed(marketId, callback, true)` per callback, then configure
    the per-direction keys from step 4. The whitelist is the callback's authorization; those
    keys are the aggregate cap on all whitelisted callbacks, shared with taker traffic.
    Onboarding a callback needs a spell; ejecting one does not, since the allocator holds
    `removeCallback`.
    Size `LIMIT_MIDNIGHT_SELL` with maker exits in mind as well, since a maker sell debits it
    and exhausting it reverts the taker's fill rather than ours.
11. `setRatifierAuthorization(ratifier, true)` **last**, once everything above is in place
    and verified. This is the blanket grant described in the trust assumptions, and it is
    what makes resting offers fillable at all.
12. Grant the ratifier's quoter role (`grantRole(QUOTER_ROLE, key)`, held by its `MANAGER_ROLE`)
    to the signing key that will publish offers. The role is checked at ratification rather
    than at signing, so revoking it voids every offer the old key signed without a redeploy.

**Choosing the maker entry tick.** `maxBuyTick` has to clear `fundFill`'s capped-fee bound,
not the live-fee bound that taker entry uses. At a 180 day term with the 1%/year cap the two
differ by about 48 basis points, so a tick that taker entry accepts can still be rejected for
a maker buy with `buy-yield-too-low`. Verify the intended tick against
`maxBuyPrice(minBuyYield, timeToMaturity, continuousFeePerSecond(maxContinuousFee))` before
publishing, not against the live fee.

**Revoking, fastest first.** Every lever acts on offers already signed and published, which
cannot be recalled from the venue. Only the first two rows avoid a spell, and the fastest lever
of all is in the periphery: revoking the quoter's role voids every outstanding signature.

| Lever | Scope | Role |
|---|---|---|
| `removeCallback(marketId, callback)` | one callback on one market, both directions | allocator |
| `cancelOfferGroup(group)` | one direction on one market, irreversible for that group | allocator |
| `setRatifierAuthorization(ratifier, false)` | every market, both directions, one transaction | admin |
| `setCallbackAllowed(marketId, callback, false)` | one callback on one market, both directions | admin |
| `controller.removeIntegrations(["MIDNIGHT_FACET"])` | every Midnight function, `fundFill` included, so maker exits stop too | admin |
| revoke the controller's `CONTROLLER` role on `RateLimits` | every metered path in the system, maker exits included | limits admin |

`setMakeConfig(market, 0)`, zeroing a direction key and tightening `setMarketConfig` are
dominated by the rows above: same spell, and each refuses the fill inside `fundFill` after
ratification has passed, so it reverts a stranger's transaction rather than stopping the book.

Order anything that needs the proxy first. `cancelOfferGroup` and `setRatifierAuthorization`
reach the venue through `IALMProxy.doCall`, so both die with the controller's `CONTROLLER` role
on the ALMProxy, and `removeIntegrations` unwires them. That proxy cutoff stops maker entries
but not maker exits, since the exit branch makes no proxy call. `removeCallback` touches only
facet storage, so it survives either cutoff. Both fast levers are visible in the mempool before
they land, so send them through a private relay.

13. Monitoring, maker-specific: published offers against the designated groups' consumed
    counters, and against `maxOfferSize` off chain since nothing enforces it on chain;
    buy and sell key drawdown as the maker turnover rate; the quoter key's custody; and
    `isAuthorized[proxy][x]` on the singleton, which must hold for the ratifier and no
    other address. Alert on `SetIsAuthorized` with `onBehalf` equal to the proxy, not only on
    the mapping: the grant permits `setIsAuthorized`, so an authorized contract can add an
    entry that revoking the ratifier does not clear.
