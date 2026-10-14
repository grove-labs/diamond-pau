# Morpho Midnight Integration

This document describes the Morpho Midnight integration with the PAU system. It covers the `MidnightFacet`, the fixed-term credit markets it trades on, how a lending position is entered, exited and rate-limited, and the per-market price, fee and loss controls that govern entry.

> **Scope.** The integration has two modes. In **taker mode** the ALMProxy takes other makers' offers; that is the subject of [Operations](#operations) below. In **maker mode** the proxy rests its own signed offers and third parties take them through a purpose-built ratifier and funding strategy; see [Maker Mode](#maker-mode). Statements in the taker sections about what the facet "never" does are taker-mode statements.

Protocol behavior described here was checked against the Morpho Midnight codebase at commit `70607569ac348e9880b512ffd3b574be55405932` (`main`, 2026-09), which is the code deployed as the mainnet singleton `0x471686c42792F93528B000beF54bC10E3aa2045f` (identical bytecode on Base at `0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A`).

## Overview

Midnight is a **singleton, fixed-term, fixed-rate credit market**. A market is a `Market` struct (loan token, maturity, collateral tiers with oracle and LLTV, optional gates) and is identified by its `id`: the full 32-byte CREATE2 hash `keccak256(0xff ‖ market.midnight ‖ 0 ‖ keccak256(SSTORE2_PREFIX ‖ abi.encode(market)))`, whose low 20 bytes are the address the singleton stores the encoded config at. `MidnightUtils.toId` computes it; an address-derivation helper would return only the truncated 20 bytes and never match. Inside a market every position is denominated in **units**: one unit is a claim on one loan token at maturity.

- A **borrower** supplies collateral and **sells** units: it receives the discounted price now and owes one loan token per unit at maturity (debt).
- A **lender** **buys** units at a discount and holds credit. At or after maturity, once borrowers have repaid, credit is **redeemed** at par.
- Trades are maker **offers** taken on-chain. A maker publishes an `Offer` (direction, tick, size, expiry, ratifier, optional callback) off-chain and a taker calls `take` with it. The maker's **ratifier** contract decides whether an offer is live; the singleton stores no order book.
- Price is a **tick**: `tickToPrice(tick)` maps `0..6744` onto a rising logistic curve rounded to `1e-7` WAD, with `3372` at exactly `0.5e18`. A tick of `4152` is roughly `0.98`, `4384` roughly `0.99`, and `6744` par.
- Fees: a **settlement fee** (per-market, resolved from a piecewise schedule over time to maturity) widens the spread on every take, and a **continuous fee** (per second, WAD) is crystallized on the buyer over the remaining term when credit is created.
- Loss: when a liquidation cannot cover a borrower's debt, the shortfall is **socialized** across all lenders in the market through a monotone `lossFactor` ratchet.

In **taker mode**, the subject of this document, the `MidnightFacet` is a **lender-only** integration: the ALMProxy buys units from makers' sell offers, sells them back into makers' buy offers before maturity, and redeems them at par once repayments land. In **maker mode** it also rests its own offers on both sides, still lender-only and still `reduceOnly` on the sell side, so it never opens debt (see `specs/midnight.md`). In neither mode does it supply collateral, borrow, liquidate or hold debt. Every external call is pinned to a single immutable Midnight singleton.

Structs and the tick math are vendored verbatim into `MidnightUtils.sol` because the market id is a hash over the struct layout: any drift would silently change every id. The mainnet-fork suite pins parity by recomputing three live market ids.

## Token Flow

```
Buy:     loanToken (ALMProxy) → approve midnight ─┐
                                                   ├→ midnight.take(sell offer) per offer
         maker receives price, fee stays in venue ─┘
         credit += units (position storage, no receipt token)

Sell:    midnight.take(buy offer) per offer → loanToken (ALMProxy), net of settlement fee
         credit -= units

Redeem:  midnight.withdraw(units) → loanToken (ALMProxy), at par
         credit -= units
```

---

## Operations

### Buy (enter, take makers' sell offers)

**Function:** `buy(marketId, fills, maxAssetsIn) returns (assetsSpent)` (`ALLOCATOR_ROLE`)

**Flow:**

1. Read the market config for `marketId`; revert `MidnightFacet/buy-not-enabled` if `maxBuyTick` is zero. Require `maxAssetsIn != 0` (`MidnightFacet/max-assets-in-not-set`) and a non-empty batch (`MidnightFacet/empty-batch`). Each `Fill` carries an offer, its ratifier data and its size together, so the three cannot be misaligned.
2. Require `fills[0].offer.market.midnight == midnight` (`MidnightFacet/invalid-midnight`) and `toId(fills[0].offer.market) == marketId` (`MidnightFacet/market-mismatch`). Every subsequent read and call goes to the immutable singleton, so the market from calldata is only usable once it names that venue, and binding it to the id here keeps a fabricated maturity out of the bound arithmetic in step 4. Snapshot the proxy's live credit (`updatePositionView`) and loan-token balance.
3. Require the market's `continuousFee`, a per-second rate, to be within `maxContinuousFee` converted out of its annual form (`MidnightFacet/continuous-fee-too-high`) and `lossFactor <= maxLossFactor` (`MidnightFacet/loss-factor-too-high`). Entering crystallizes the continuous fee over the remaining term and buys into whatever loss has already been socialized, so both are entry-only gates.
4. Resolve two price ceilings and apply both. The tick ceiling is `tickToPrice(maxBuyTick)`. The yield-implied price ceiling is `maxBuyPrice(minBuyYield, timeToMaturity, continuousFee)`: the highest all-in price that still earns `minBuyYield` basis points a year at simple interest over ACT/365, measured on what a unit returns (par less the continuous fee crystallized for the remaining term). Both are ceilings on the all-in price the proxy pays, the settlement fee is added to each offer's price before either comparison, and the stricter ceiling binds.
5. Approve `loanToken` from the ALMProxy to Midnight for exactly `maxAssetsIn`.
6. For each offer, in order: require `toId(offer.market) == marketId` (`MidnightFacet/market-mismatch`), `offer.buy == false` (`MidnightFacet/invalid-offer-direction`), `fills[i].units != 0` (`MidnightFacet/zero-units`), `tickToPrice(offer.tick) + settlementFee <= tickCeiling` (`MidnightFacet/buy-price-too-high`), `tickToPrice(offer.tick) + settlementFee <= yieldCeiling` (`MidnightFacet/buy-yield-too-low`) and `offer.receiverIfMakerIsSeller != proxy` (`MidnightFacet/invalid-offer-receiver`, see [Security Considerations](#self-paying-offers)). Then `doCall` `midnight.take(fills[i].offer, fills[i].ratifierData, fills[i].units, proxy, 0, 0, "")`.
7. Reset the approval to zero in case Midnight did not pull the full amount.
8. Measure `assetsSpent` as the ALMProxy balance delta rather than trusting the take return values, and require `assetsSpent <= maxAssetsIn` (`MidnightFacet/max-assets-in-exceeded`).
9. Require the live credit to have grown by exactly the units taken (`MidnightFacet/credit-delta-mismatch`) and the proxy's debt to be zero (`MidnightFacet/debt-not-zero`). Anything a maker callback did to market state during the batch surfaces here.
10. Decrement `LIMIT_MIDNIGHT_BUY` keyed `marketId` by `assetsSpent`.

**Rate Limit:** `LIMIT_MIDNIGHT_BUY` via `makeBytes32Key(LIMIT_MIDNIGHT_BUY, marketId)`.

The key is salted with the governance-supplied `marketId` only. Nothing read from the protocol feeds a key: the id is itself a commitment to the full market config (venue, loan token, maturity, collateral tiers, gates), so there is nothing a counterparty can remap.

**Event:** `MidnightBuy(marketId, units, assetsSpent)`, where `units` is the batch total and `assetsSpent` the measured balance delta, fees included.

**Zero units:** the facet rejects a zero per-offer size (`MidnightFacet/zero-units`) before reaching Midnight.

**Untouched market:** `settlementFee` reverts (`MarketNotCreated()`) on a market that has never been created on the singleton. Anyone can create one with a single permissionless `touchMarket(market)` call; the facet does not do it.

**Post-maturity:** Midnight refuses to let a maker take on new debt after maturity (`CannotIncreaseDebtPostMaturity()`), but a maker that already holds credit can still sell it, so a `buy` from such a maker succeeds after maturity. The facet does not check maturity; closing entry means zeroing `maxBuyTick`.

### Sell (exit early, take makers' buy offers)

**Function:** `sell(marketId, fills, minAssetsOut) returns (assetsReceived)` (`ALLOCATOR_ROLE`)

**Flow:**

1. Read the market config; revert `MidnightFacet/sell-not-enabled` if `minSellTick` is zero. Require `minAssetsOut != 0` (`MidnightFacet/min-assets-out-not-set`) and a well-formed batch as for `buy`.
2. Require `fills[0].offer.market.midnight == midnight` (`MidnightFacet/invalid-midnight`), snapshot credit and balance.
3. Resolve two price floors and apply both. The tick floor is `tickToPrice(minSellTick)`. The yield-implied price floor is `minSellPrice(maxSellYield, timeToMaturity, credit, pendingFee)`: the lowest net price that gives up no more than `maxSellYield` basis points a year on the same ACT/365 basis as the buy leg. The two legs measure the continuous fee differently, and deliberately so. A buy fixes the market's current rate onto the new units for their whole term, so the entry ceiling uses that rate; a position then keeps the fee it was bought at, so the exit floor uses the lien that position still carries, `pendingFee / credit` as reported by `updatePositionView`. Pricing the exit off the market's live rate instead would move the floor on every fee change: a rise would drop it below the configured policy and let a cheaper exit through, and a cut would raise it and block exits the position's own economics justify. Selling receives the tick price less the fee, so `settlementFee(marketId, timeToMaturity)` is added to each floor before comparison, and the stricter floor binds.
4. For each offer, in order: the same id, direction (`offer.buy == true`) and non-zero-units checks as `buy`, then `tickToPrice(offer.tick) >= tickFloor + settlementFee` (`MidnightFacet/sell-price-too-low`) and `tickToPrice(offer.tick) >= yieldFloor + settlementFee` (`MidnightFacet/sell-yield-too-high`). The per-offer size is capped at the proxy's **remaining live credit**; once credit is exhausted the rest of the batch is skipped rather than filled with debt. Then `doCall` `midnight.take(fills[i].offer, fills[i].ratifierData, cappedUnits, proxy, proxy, 0, "")`.
5. Measure `assetsReceived` as the ALMProxy balance delta and require `assetsReceived >= minAssetsOut` (`MidnightFacet/min-assets-out-not-met`).
6. Require the live credit to have shrunk by exactly the units sold (`MidnightFacet/credit-delta-mismatch`) and the proxy's debt to be zero (`MidnightFacet/debt-not-zero`).
7. Decrement `LIMIT_MIDNIGHT_SELL` keyed `marketId` by `assetsReceived`, and `_tryIncreaseRateLimit` the buy key by the same amount (see [Try-Increase](./RATE_LIMITS.md#try-increase-not-gate-check): the refill silently no-ops when the buy key is unconfigured, and the buy key is not a precondition for exit).

**Rate Limit:** `LIMIT_MIDNIGHT_SELL` via `makeBytes32Key(LIMIT_MIDNIGHT_SELL, marketId)`.

**Event:** `MidnightSell(marketId, units, assetsReceived)`, where `units` is the total actually sold after capping and `assetsReceived` the measured balance delta, net of fees.

**Credit drifts down:** the live credit read from `updatePositionView` already reflects accrued continuous fee and any socialized loss, so the cap in step 4 is what keeps a sell from ever creating debt. A batch sized against a stale credit reading fills what is left and stops.

**Post-maturity:** selling stays open only at par. The settlement fee schedule resolves at zero time to maturity, and so does the yield-implied price floor: with no term left, any discount gives up unbounded yield against a redemption that pays par, so the floor collapses onto par and refuses every discounted offer (`MidnightFacet/sell-yield-too-high`). A crystallized lien is fully accrued by maturity, so this holds for a position bought under a live continuous fee as well: its `pendingFee` is zero by then and the floor is exactly par. A par offer (tick `6743` or `6744`) still clears when the settlement fee is zero. This is deliberate, and it costs nothing: `redeem` pays exactly par with no fee, while a sell pays the tick price less the settlement fee, so `sell <= par - settlementFee <= redeem` for every offer. A post-maturity sell can therefore never beat redemption; the floor blocks a guaranteed loss rather than a trade, and the one case it still permits (par price, zero fee) is cash-identical to redeeming while not drawing on `withdrawable`. Note that no configuration value reopens a discounted exit: the yield-implied price floor at zero time to maturity is par regardless of `maxSellYield`, and `minSellTick` only feeds the looser of the two floors, so changing this would take a new facet deployment, not a spell.

### Redeem (exit at par from repayments)

**Function:** `redeem(marketId, units, minAssetsOut) returns (assetsWithdrawn)` (`ALLOCATOR_ROLE`)

**Flow:**

1. Require the market to be onboarded, `minSellTick != 0` (`MidnightFacet/market-not-onboarded`). Redemption reads no other config value; the onboarded config is what authenticates the id. Require `minAssetsOut != 0` (`MidnightFacet/min-assets-out-not-set`), as on `sell`.
2. Resolve the `Market` struct from the id on the singleton (`toMarket(marketId)`), so redemption never trusts a market from calldata.
3. Cap `units` at both the proxy's live credit and the market's `withdrawable` amount (repaid, not yet withdrawn), then require the result to be non-zero (`MidnightFacet/zero-units`). Passing `type(uint256).max` redeems everything currently available.
4. Snapshot the balance, `doCall` `midnight.withdraw(market, units, proxy, proxy)`, and measure `assetsWithdrawn` as the balance delta. Require `assetsWithdrawn >= minAssetsOut` (`MidnightFacet/min-assets-out-not-met`).
5. Require the proxy's debt to be zero (`MidnightFacet/debt-not-zero`).
6. Decrement `LIMIT_MIDNIGHT_REDEEM` keyed `marketId` by `assetsWithdrawn`, and `_tryIncreaseRateLimit` the buy key by the same amount.

**Rate Limit:** `LIMIT_MIDNIGHT_REDEEM` via `makeBytes32Key(LIMIT_MIDNIGHT_REDEEM, marketId)`.

**Event:** `MidnightRedeem(marketId, units, assetsWithdrawn)`, where `units` is the capped amount actually withdrawn.

**Withdrawable is shared:** repayments fill one per-market pool that every lender draws from, first come first served, and the fee claimer draws on the same pool. Redemption is possible before maturity whenever borrowers have repaid early, and after maturity only as fast as repayments and liquidations land. Before maturity, a slow-repaying market can still be exited by selling. After maturity that option is gone by design (see `sell` above), so a market whose borrowers do not repay leaves credit waiting on repayment or liquidation. Liquidation is permissionless after maturity and credits repaid units straight to the pool, so this is a timing exposure rather than a loss, unless liquidations fall short of the debt.

### Set Market Config (admin)

**Function:** `setMarketConfig(marketId, maxBuyTick, minSellTick, minBuyYield, maxSellYield,
maxContinuousFee, maxLossFactor)` (`DEFAULT_ADMIN_ROLE`)

Sets the governance limits for one market. Every limit is set in the one call, and they are stored
together in a single slot:

| Field              | Type      | Meaning                                                                                                                                 |
| ------------------ | --------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `maxBuyTick`       | `uint16`  | Ceiling on an offer's price plus the settlement fee. `0` disables entry. Must be `<= 6744` (`MidnightFacet/max-buy-tick-oob`).   |
| `minSellTick`      | `uint16`  | Floor an offer's price must clear once the settlement fee is added to it. Non-zero marks the market as onboarded and gates `sell` and `redeem`. Must be in `1..6744` (`MidnightFacet/min-sell-tick-oob`). |
| `minBuyYield`      | `uint16`  | Lowest implied yield a buy may accept, in basis points a year (max `655.35%`). `0` is the loosest setting that still refuses to pay more than a unit returns. |
| `maxSellYield`     | `uint16`  | Highest implied yield a sell may give up, in basis points a year. Must be non-zero (`MidnightFacet/max-sell-yield-not-set`); zero would only clear at par and brick the exit. |
| `maxContinuousFee` | `uint16`  | Highest market continuous fee a buy tolerates, in centi-basis points a year. Must be `<= 1_00_00`, one percent a year, Midnight's own ceiling (`MidnightFacet/max-continuous-fee-oob`). |
| `maxLossFactor`    | `uint128` | Highest market loss factor a buy tolerates, as a fraction of `type(uint128).max`. `0` means no socialized loss is tolerated.            |

- All values default to zero, the strictest setting: nothing is onboarded, nothing can be entered.
- `minSellTick` is an exit floor and has to stay reachable: below par net of the settlement fee, or every sell reverts on price. `setMarketConfig` rejects a zero `minSellTick` outright, so a market once onboarded cannot be un-onboarded through the facet; closing a market means zeroing `maxBuyTick` and leaving the exits configured.
- Each leg carries a tick bound and a yield bound, and the stricter binds. Ticks are absolute prices and go stale as the term shortens: a tick that is a fair entry at 180 days is a giveaway at 5. The yield bounds are denominated in rate, so they track the term on their own and need no spell as maturity approaches. Both fees are inside the comparison, so a fee change does not need a reconfiguration either.
- Yield granularity is one basis point a year, worth about `1.0` basis points of price at a 360 day term, `0.5` at 180 days and `0.02` at 7 days. Set `maxSellYield` well above the market rate: it is a gross-mispricing rail, not a spread control, and it tightens towards par on its own as maturity approaches.
- `maxContinuousFee` is an annual rate, while Midnight stores the fee itself per second. The facet converts the ceiling as `cbps * 1e12 / 365 days` and floors, so the effective ceiling never sits above the rate named; `1_00_00` maps exactly onto Midnight's own `0.01e18 / 365 days` cap. Reading the venue's `continuousFee(id)` against the configured value therefore needs that conversion.
- Write the value grouped as `percent_bp_cbp`, so the digits carry their own units: `1_00_00` is one percent a year, `50_00` is 50 basis points, `1` is one centi-basis point.
- The fee and loss guards apply to entry only. Exits are bounded by `minSellTick`, `maxSellYield`, `minAssetsOut` and the rate limits.

**Event:** `MidnightMarketConfigSet(marketId, maxBuyTick, minSellTick, minBuyYield, maxSellYield, maxContinuousFee, maxLossFactor)`

Together with the rate-limit keys, a non-zero `minSellTick` acts as the per-market whitelist: both must be configured by governance before the first trade.

### Views

| Function                        | Returns                                                                 |
| ------------------------------- | ----------------------------------------------------------------------- |
| `getBuyRateLimitKey(marketId)`    | `makeBytes32Key(LIMIT_MIDNIGHT_BUY, marketId)`                        |
| `getSellRateLimitKey(marketId)`   | `makeBytes32Key(LIMIT_MIDNIGHT_SELL, marketId)`                       |
| `getRedeemRateLimitKey(marketId)` | `makeBytes32Key(LIMIT_MIDNIGHT_REDEEM, marketId)`                     |
| `getStrategyRateLimitKey(strategy, marketId)` | `makeAddressBytes32Key(LIMIT_MIDNIGHT_STRATEGY, strategy, marketId)` |
| `getMarketConfig(marketId)`       | Configured `MarketConfig`, all-zero when not onboarded                |
| `getMakeConfig(marketId)`         | Configured `MakeConfig`, all-zero when making is disabled             |
| `getDesignatedGroups(marketId)`   | Configured `DesignatedGroups`, all-zero when nothing is designated    |
| `midnight()`                      | The immutable Midnight singleton every call is pinned to              |

The last three are not diagnostics: the ratifier reads `getMakeConfig`, `getDesignatedGroups` and `getMarketConfig` on every maker fill, so they are the live policy interface maker mode runs on.

---

## Maker Mode

In maker mode the proxy stops waiting for someone else's offer and publishes its own. An off-chain **quoter** key signs an `Offer` naming the proxy as maker; a third party finds it, calls `midnight.take` directly, and the settlement happens with no transaction of ours in the call stack. Two immutable periphery contracts stand in for the facet inside that stack:

- **`MidnightRatifier`** (`src/periphery/MidnightRatifier.sol`) is the contract Midnight asks whether an offer is live. It is a pure `view`: it recovers the quoter's signature over the offer, then re-reads the facet's own `MakeConfig`, `DesignatedGroups` and `MarketConfig` and applies the same bounds the facet would. It never calls the singleton.
- **`ProxyFundingStrategy`** (`src/periphery/ProxyFundingStrategy.sol`) is named as the `callback` on buy offers and is therefore the payer Midnight pulls from. It calls `fundFill` to draw the exact amount from the proxy, approves the singleton for it, and is drained inside the same `take`.

The proxy is still lender-only in this mode: buy offers acquire credit, sell offers are required to be `reduceOnly` so a fill can only shed credit the proxy already holds, and nothing opens debt or supplies collateral.

```
Maker buy:   taker calls midnight.take(proxy's buy offer)
             → ratifier.isRatified(offer, sig, taker)                  [view, reverts to refuse]
             → strategy.onBuy(...) → controller.fundFill(...)
                 → loanToken (ALMProxy) → strategy
             → midnight pulls buyerAssets from strategy
             credit += units (proxy's position)

Maker sell:  taker calls midnight.take(proxy's sell offer)
             → ratifier.isRatified(offer, sig, taker)                  [view, reverts to refuse]
             → loanToken (taker) → ALMProxy, net of settlement fee
             credit -= units        (no facet call, no rate limit; see below)
```

### Fund Fill (strategy, no role)

**Function:** `fundFill(marketId, assets, units)` (**no role**, see below)

Called by an authorized funding strategy from inside Midnight's `onBuy`, never by an allocator. It is the only facet function reached from a third party's transaction.

**Flow:**

1. Derive `makeAddressBytes32Key(LIMIT_MIDNIGHT_STRATEGY, msg.sender, marketId)` and require it to exist (`MidnightFacet/strategy-not-authorized`).
2. Require `makeConfig.maxOfferSize != 0` (`MidnightFacet/make-not-enabled`), `assets != 0` (`MidnightFacet/zero-assets`), `units != 0` (`MidnightFacet/zero-units`).
3. Require `lossFactor(marketId) <= maxLossFactor` (`MidnightFacet/loss-factor-too-high`), read live, so a market whose lenders have already been slashed stops funding fills.
4. Require `assets <= units * maxFillPrice / WAD` (`MidnightFacet/fill-price-too-high`), where `maxFillPrice` is the lesser of `tickToPrice(maxBuyTick)` and `maxBuyPrice(minBuyYield, timeToMaturity, continuousFeePerSecond(maxContinuousFee))`.
5. Decrement the pair key and `LIMIT_MIDNIGHT_BUY`, both by `assets`.
6. `doCall` `loanToken.transfer(msg.sender, assets)` as the last step, so every gate and both meters have already passed. The loan token comes from stored `MakeConfig`, never from the caller.

**No role, deliberately.** The existence of the strategy's pair rate limit is the authorization: onboarding a strategy is one `setRateLimitData`, revoking it is one zeroing, and there is no role grant to track separately. The amount is bounded by that same key plus the market's shared buy key, both debited before the transfer, so the existence check is the whitelist and the decrease is the bound.

**Rate Limit:** two, both enforcing and both debited by `assets`: `LIMIT_MIDNIGHT_STRATEGY` via `makeAddressBytes32Key(LIMIT_MIDNIGHT_STRATEGY, strategy, marketId)`, and `LIMIT_MIDNIGHT_BUY` keyed `marketId`, the same key taker entry spends. Maker and taker entry therefore share one per-market budget and the pair key caps any single strategy inside it.

**Refill:** none of its own. The buy key is refilled by the exits; the pair key by configuration only.

**Event:** `MidnightFillFunded(marketId, strategy, assets, units)`

**Maker entry is bounded more tightly than `buy`.** `fundFill` prices the continuous fee at the *configured cap*, while `buy` prices the market's *live* rate, because an offer is signed before the rate it will settle at is known and the ratifier has to agree with `fundFill` at signing time. At a 180 day term with the 1%/year cap the two bounds differ by about 48 basis points, so a tick that taker entry accepts can still be refused for a maker buy. Verify an intended `maxBuyTick` against the capped-fee bound before publishing.

**Zero-asset callbacks:** Midnight places no lower bound on `units`, so a consumed offer stays pokeable at zero units forever and `onBuy` keeps firing with `buyerAssets == 0`. The strategy returns success without calling the facet in that case; reverting would fail an unrelated taker's transaction.

### The Maker Exit Leg

A third party taking a resting **sell** offer moves credit out of the proxy's position with no code of ours executing. There is no facet call in that path and therefore no rate limit on it: the only thing deciding whether the fill happens, and where the proceeds land, is the ratifier's `view`. The exposure is bounded instead by what was signed (price floor, tick floor, `reduceOnly`, group, size, expiry, window, signature), by the offer's own `maxUnits` against the group's consumed counter, and by the revocation levers below. The ratifier requires `receiverIfMakerIsSeller == proxy` on every sell offer, so the proceeds cannot be redirected.

### Set Make Config (admin)

**Function:** `setMakeConfig(market, maxOfferSize)` (`DEFAULT_ADMIN_ROLE`)

Takes the full `Market` struct, not an id, because `MakeConfig` caches the maturity and loan token the ratifier and `fundFill` price against. Requires `market.midnight == midnight` (`MidnightFacet/invalid-midnight`), the market to be onboarded for taking already (`minSellTick != 0`, `MidnightFacet/market-not-onboarded`), `market.maturity <= type(uint64).max` (`MidnightFacet/maturity-oob`), `maxOfferSize <= type(uint128).max` (`MidnightFacet/max-offer-size-oob`), since an offer's own size fields are `uint128` and a larger cap could never bind, and `toMarket(marketId).maturity == market.maturity` (`MidnightFacet/market-mismatch`), which reverts unless the market exists on the singleton.

`maxOfferSize` caps each single resting offer, in units or assets whichever the offer sets, not the size of the book. Zero is the default and means making is disabled; it is also the per-market kill switch, because the ratifier reads it on every fill.

**Event:** `MidnightMakeConfigSet(marketId, maxOfferSize, maturity, loanToken)`

### Set Designated Groups (admin)

**Function:** `setDesignatedGroups(marketId, buyGroup, sellGroup)` (`DEFAULT_ADMIN_ROLE`)

Midnight tracks consumed size per `offer.group`. These two values are the only groups the ratifier will ratify an offer into, and therefore the only groups `cancelOfferGroup` needs to be able to retire. `buyGroup != sellGroup` unless both are zero (`MidnightFacet/groups-not-distinct`): a shared group would make neither book cancellable on its own. Both zero is the default and designates nothing; a zero group is not a wildcard, since the ratifier refuses an undesignated direction outright. Designating one side only makes the market one-directional.

**Event:** `MidnightDesignatedGroupsSet(marketId, buyGroup, sellGroup)`

### Set Ratifier Authorization (admin)

**Function:** `setRatifierAuthorization(ratifier, authorized)` (`DEFAULT_ADMIN_ROLE`)

`doCall`s `midnight.setIsAuthorized(ratifier, authorized, proxy)`. Only `ratifier != address(0)` is checked (`MidnightFacet/zero-ratifier`); nothing on-chain can usefully constrain what the grantee is. See [Ratifier Authorization Is a Blanket Grant](#ratifier-authorization-is-a-blanket-grant) before using it. `authorized == false` revokes and is the global kill switch: it invalidates every resting offer naming that ratifier in one transaction, across all markets and both directions.

**Event:** `MidnightRatifierAuthorizationSet(ratifier, authorized)`

### Cancel Offer Group (allocator)

**Function:** `cancelOfferGroup(group)` (`ALLOCATOR_ROLE`)

`doCall`s `midnight.setConsumed(group, type(uint128).max, proxy)`. Midnight rejects any amount below what the group has already consumed, so the call can only retire a group and never reopen one, which is why it sits at allocator level while the setters above are admin-only. Groups are per direction, so entries can be retired while exits stay fillable. Retiring a group is irreversible for that group. A group nothing ever used is retired just the same.

**Event:** `MidnightOfferGroupCancelled(group)`

---

## Rate Limit Keys

| Limit                      | Key tuple               | Helper                   |
| -------------------------- | ----------------------- | ------------------------ |
| `LIMIT_MIDNIGHT_BUY`       | `(marketId)`            | `makeBytes32Key`         |
| `LIMIT_MIDNIGHT_SELL`      | `(marketId)`            | `makeBytes32Key`         |
| `LIMIT_MIDNIGHT_REDEEM`    | `(marketId)`            | `makeBytes32Key`         |
| `LIMIT_MIDNIGHT_STRATEGY`  | `(strategy, marketId)`  | `makeAddressBytes32Key`  |

All four are denominated in the market's loan token. `LIMIT_MIDNIGHT_STRATEGY` is both the funding strategy's authorization and its per-market cap; it is debited alongside `LIMIT_MIDNIGHT_BUY` on every maker fill, so maker entry spends the same per-market budget as taker entry. The three taker limits are sized by measured balance deltas. `sell` and `redeem` refill the buy key by the amount returned (`_tryIncreaseRateLimit`), so capital rotated out of a market restores entry headroom for that market without governance action. Splitting sell from redeem lets governance price the two exits differently: redemption is at par and only limited by repayments, while a sell crosses the spread and the settlement fee.

---

## Security Considerations

### Immutable Venue

The Midnight singleton is an immutable, non-upgradeable contract with no owner over funds. Its `configurator` can enable LLTV and liquidation-cursor tiers, replace itself, and appoint three roles: a `feeSetter` who can move the settlement and continuous fees of any market within hard-coded ceilings, a `feeClaimer` who withdraws accrued continuous fee out of a market's repayment pool (`claimContinuousFee` decrements `withdrawable`, so it competes with lenders for the same pool `redeem` draws from), and a `tickSpacingSetter` who can only refine a market's tick spacing. None of them can touch positions or move a lender's loan tokens. The facet binds to one singleton at construction, so a repoint requires a new facet deployment and a governance spell.

### Maker Callbacks Run Inside Our Take

An offer may name a `callback` contract with opaque `callbackData`; Midnight calls it inside `take`, after the transfers when the maker sells and before them when the maker buys. The facet cannot vet what it does and does not try to: banning callbacks is not viable because callback-backed offers are how makers source liquidity. Instead the facet relies on three post-conditions that hold for the whole batch:

- The controller's reentrancy guard is held for the entire call, so the callback cannot re-enter any facet.
- The approval to Midnight is exactly `maxAssetsIn`, and Midnight only pulls from the proxy on the proxy's own take. A callback that tries to spend the open approval needs the proxy as payer of some other flow, which Midnight refuses (the proxy authorizes no ratifier and no operator, and is not a repay callback).
- The exact credit-delta, zero-debt and `maxAssetsIn` checks after the batch catch any change to the proxy's position or balance that did not come from the requested fills, including a socialized loss landing mid-batch. The mainnet-fork attack tests drive a hostile maker through take, withdraw, authorization and repayment attempts, and slash a third borrower from inside a fill, in both directions.

### Ratifier Data Is Opaque

`fills[i].ratifierData` is forwarded as-is to the **maker's** ratifier, which decides whether the offer is live. The facet validates outcomes (price bound, direction, id, deltas), not the offer's provenance; an offer that fails ratification reverts the batch inside Midnight.

### Self-Paying Offers

If a sell offer named the ALMProxy as `receiverIfMakerIsSeller`, the proxy would pay the maker's proceeds to itself, netting the balance delta to the fee alone and under-reporting the spend to the rate limit. The facet rejects such offers (`MidnightFacet/invalid-offer-receiver`). On the sell side the proxy is the seller and always names itself as receiver.

### Socialized Loss Is a Ratchet

`lossFactor` only ever increases. A buy into a market that has already been slashed buys in at the written-down value, so `maxLossFactor` gates entry and defaults to zero. It never gates exit: after a slash the live credit is lower, the sell cap follows it, and redemption returns what is left. A market whose `lossFactor` saturates at `type(uint128).max` makes `take` revert for everyone; that is a monitoring concern, not one the facet can act on.

### Mutable Reads Feed Guards, Not Keys

`continuousFee`, `lossFactor`, `settlementFee`, `updatePositionView`, `withdrawable` and `toMarket` are all read from the singleton at call time and can change between calls. Each one feeds a guard that fails closed (a tighter bound, a smaller cap, a revert), and none of them is used to derive a rate-limit key. The only key salt is the governance-supplied `marketId`.

### Measured Deltas, Not Return Values

All three operations size their rate-limit accounting from observed balance changes on the ALMProxy, and the two take paths additionally reconcile the credit delta against the units requested, so neither the venue's return values nor a maker's callback can skew accounting.

### No Standing Approvals

The buy approval is set to `maxAssetsIn` and reset to zero after the batch. Outside a `buy` transaction Midnight holds no allowance on ALMProxy funds. `sell`, `redeem` and `fundFill` grant no approval from the proxy at all, and maker mode adds no standing grant from the proxy to the singleton.

The funding strategy does approve the singleton, but it holds no proxy funds between settlements: `onBuy` sets the allowance with `forceApprove` to exactly the amount Midnight is about to pull, and the pull consumes it inside the same `take`. A disagreement between what `fundFill` sent and what the singleton pulls leaves the pull unfunded and reverts the whole settlement, so nothing accumulates. `skim` is permissionless and sends any stray balance to the proxy.

### Ratifier Authorization Is a Blanket Grant

Midnight gates maker fills on `isAuthorized[maker][ratifier]`, and that is one flat mapping: the same entry also authorizes `withdraw`, `repay`, `supplyCollateral`, `withdrawCollateral`, `setConsumed` and `setIsAuthorized` on the proxy's behalf. (`borrow` and `liquidate` are not on that list.) Authorizing a ratifier therefore hands it the proxy's whole position on the venue, not just the right to answer ratification questions. There is no narrower grant to ask for.

The containment is that the authorized contract is incapable of using the grant: `MidnightRatifier` is non-upgradeable, has no constructor or admin path that can reach the singleton, and its only external interactive function is `setQuoter`. The integration test suite asserts this structurally by scanning the facet's own call surface for the forbidden selectors with `take` as a positive control, and the fork suite asserts that `isAuthorized[proxy][x]` holds for the ratifier and no other address. Nothing but a reviewed, immutable contract should ever be passed to `setRatifierAuthorization`.

### Maker Exits Carry No Meter

`fundFill` meters maker entry, but the exit leg has no facet call to meter (see [The Maker Exit Leg](#the-maker-exit-leg)). This is the one path in the integration where value moves out of the proxy's Midnight position without any of our code running. It is bounded by the signed offer, the group's consumed counter and the revocation levers, never by a rate limit, so the signing policy on the quoter key is a control surface in its own right.

### Nested Controller Entry

A taker could try to reach the controller from inside a maker fill: take a resting offer, and from the callback call back into `buy` or `fundFill`. Two independent layers refuse it. `fundFill` is `nonReentrant`, so the second entry reverts on the guard; and with that guard removed the outer settlement still fails the facet's exact credit reconciliation (`MidnightFacet/credit-delta-mismatch`), because the nested fill moved the position mid-batch. The fork suite asserts both, the second by removing the guard and showing the outer call still reverts.

### Reentrancy

All interactive functions are `nonReentrant`, `fundFill` included, and the funding strategy carries its own guard so a hostile token cannot re-enter `onBuy` from either the transfer or the approval.

---

## Failure Modes

| Revert                                   | Origin      | Cause                                                                                     |
| ---------------------------------------- | ----------- | ----------------------------------------------------------------------------------------- |
| `MidnightFacet/buy-not-enabled`          | facet       | `buy` on a market whose `maxBuyTick` is zero                                              |
| `MidnightFacet/sell-not-enabled`         | facet       | `sell` on a market whose `minSellTick` is zero                                            |
| `MidnightFacet/market-not-onboarded`     | facet       | `redeem` on a market whose `minSellTick` is zero                                          |
| `MidnightFacet/max-assets-in-not-set`    | facet       | `buy` with zero `maxAssetsIn`                                                             |
| `MidnightFacet/min-assets-out-not-set`   | facet       | `sell` or `redeem` with zero `minAssetsOut`                                               |
| `MidnightFacet/empty-batch`              | facet       | `buy`/`sell` with no offers                                                               |
| `MidnightFacet/invalid-midnight`         | facet       | `fills[0].offer.market.midnight` is not the configured singleton                          |
| `MidnightFacet/market-mismatch`          | facet       | `fills[0]`'s or any offer's market does not hash to `marketId`                            |
| `MidnightFacet/invalid-offer-direction`  | facet       | a buy offer passed to `buy`, or a sell offer passed to `sell`                             |
| `MidnightFacet/zero-units`               | facet       | a zero per-offer size, or a `redeem` that caps to nothing                                 |
| `MidnightFacet/continuous-fee-too-high`  | facet       | `buy` while the market's continuous fee exceeds `maxContinuousFee`                        |
| `MidnightFacet/loss-factor-too-high`     | facet       | `buy` while the market's loss factor exceeds `maxLossFactor`                              |
| `MidnightFacet/buy-price-too-high`       | facet       | an offer whose price plus the settlement fee exceeds `tickToPrice(maxBuyTick)`            |
| `MidnightFacet/sell-price-too-low`       | facet       | an offer whose price is under `tickToPrice(minSellTick)` plus the settlement fee          |
| `MidnightFacet/buy-yield-too-low`        | facet       | an all-in offer price whose implied yield is under `minBuyYield` for the remaining term   |
| `MidnightFacet/sell-yield-too-high`      | facet       | an offer whose net proceeds give up more than `maxSellYield` for the remaining term       |
| `MidnightFacet/invalid-offer-receiver`   | facet       | a sell offer paying its proceeds to the ALMProxy                                          |
| `MidnightFacet/max-assets-in-exceeded`   | facet       | measured spend above `maxAssetsIn`                                                        |
| `MidnightFacet/min-assets-out-not-met`   | facet       | measured proceeds below `minAssetsOut`                                                    |
| `MidnightFacet/credit-delta-mismatch`    | facet       | live credit did not move by exactly the units taken                                       |
| `MidnightFacet/debt-not-zero`            | facet       | the venue reports debt against the ALMProxy after a trade                                 |
| `MidnightFacet/max-buy-tick-oob`         | facet       | `setMarketConfig` with `maxBuyTick > 6744`                                                |
| `MidnightFacet/min-sell-tick-oob`        | facet       | `setMarketConfig` with `minSellTick` zero or `> 6744`                                     |
| `MidnightFacet/max-continuous-fee-oob`   | facet       | `setMarketConfig` with `maxContinuousFee` above Midnight's ceiling                        |
| `MidnightFacet/max-sell-yield-not-set`   | facet       | `setMarketConfig` with a zero `maxSellYield`                                               |
| `MidnightFacet/tick-out-of-range`        | facet       | an offer tick above `6744`                                                                |
| `MidnightFacet/zero-midnight`            | facet       | constructor with a zero singleton address                                                 |
| `MidnightFacet/groups-not-distinct`      | facet       | `setDesignatedGroups` with one group used for both directions                              |
| `MidnightFacet/maturity-oob`             | facet       | `setMakeConfig` with a maturity above `type(uint64).max`                                  |
| `MidnightFacet/max-offer-size-oob`       | facet       | `setMakeConfig` with a cap above `type(uint128).max`                                      |
| `MidnightFacet/zero-ratifier`            | facet       | `setRatifierAuthorization` with a zero address                                            |
| `MidnightFacet/strategy-not-authorized`  | facet       | `fundFill` from a caller with no `(strategy, marketId)` pair limit                        |
| `MidnightFacet/make-not-enabled`         | facet       | `fundFill` on a market whose `maxOfferSize` is zero                                       |
| `MidnightFacet/zero-assets`              | facet       | `fundFill` with zero assets                                                               |
| `MidnightFacet/fill-price-too-high`      | facet       | `fundFill` paying above the lesser of the tick and capped-fee yield bounds                 |
| `RateLimits/rate-limit-exceeded`         | rate limits | trade exceeding the configured limit                                                      |
| `RateLimits/zero-maxAmount`              | rate limits | key unconfigured                                                                          |
| `MarketNotCreated()`                     | Midnight    | market never touched on the singleton                                                     |
| `RatifierUnauthorized()`                 | Midnight    | maker has not authorized its ratifier                                                     |
| `NotRatified()`                          | ratifier    | the maker's `SetterRatifier` does not recognize the offer (bubbles through Midnight)      |
| `ConsumedUnits()`, `ConsumedAssets()`    | Midnight    | offer already filled past its cap, including by someone else in the same block            |
| `OfferExpired()`, `OfferNotStarted()`    | Midnight    | offer outside its validity window                                                         |
| `CannotIncreaseDebtPostMaturity()`       | Midnight    | `buy` after maturity from a maker that would have to incur debt to fill it                |
| `SellerIsLiquidatable()`                 | Midnight    | the maker selling to us would be left unhealthy                                           |
| `MarketLossFactorMaxedOut()`             | Midnight    | market has lost everything; no takes are possible                                         |

### Maker Mode

Every revert below refuses a fill against one of the proxy's own resting offers. The taker sees it bubble out of `midnight.take`.

| Revert                                        | Origin   | Cause                                                                              |
| --------------------------------------------- | -------- | ---------------------------------------------------------------------------------- |
| `MidnightRatifier/invalid-signature`          | ratifier | the offer was not signed by the current quoter, so a rotation voids every old offer |
| `MidnightRatifier/maker-not-proxy`            | ratifier | an offer naming someone else as maker                                              |
| `MidnightRatifier/not-our-ratifier`           | ratifier | an offer naming a different ratifier                                               |
| `MidnightRatifier/invalid-midnight`           | ratifier | an offer on a different singleton                                                  |
| `MidnightRatifier/invalid-receiver`           | ratifier | a sell offer not paying the proxy, or a buy offer naming a receiver at all         |
| `MidnightRatifier/make-not-enabled`           | ratifier | `maxOfferSize` is zero for that market                                             |
| `MidnightRatifier/offer-too-large`            | ratifier | the offer's `maxUnits`/`maxAssets` exceeds `maxOfferSize`                           |
| `MidnightRatifier/offer-expired`              | ratifier | the offer's expiry has passed                                                      |
| `MidnightRatifier/offer-window-inverted`      | ratifier | an offer whose expiry precedes its start                                           |
| `MidnightRatifier/offer-window-too-long`      | ratifier | a validity window longer than the ratifier's `maxOfferWindow`                      |
| `MidnightRatifier/sell-not-reduce-only`       | ratifier | a sell offer that could open debt                                                  |
| `MidnightRatifier/group-not-designated`       | ratifier | that direction has no designated group                                             |
| `MidnightRatifier/wrong-group`                | ratifier | the offer's group is not the designated one                                        |
| `MidnightRatifier/sell-has-callback`           | ratifier | a sell offer naming a callback, which Midnight would route to `onSell`             |
| `MidnightRatifier/strategy-not-authorized`    | ratifier | a buy offer whose callback holds no pair limit for that market                     |
| `MidnightRatifier/tick-above-max-buy`         | ratifier | a buy offer above `maxBuyTick`                                                     |
| `MidnightRatifier/tick-below-min-sell`        | ratifier | a sell offer below `minSellTick`                                                   |
| `MidnightRatifier/buy-yield-too-low`          | ratifier | a buy offer above the capped-fee yield ceiling                                     |
| `MidnightRatifier/sell-yield-too-high`        | ratifier | a sell offer below the yield-implied price floor                                   |
| `MidnightRatifier/fee-cap-too-high`           | ratifier | an offer tolerating a continuous fee above `maxContinuousFee`                      |
| `ProxyFundingStrategy/not-midnight`           | strategy | `onBuy` called by anything but the singleton                                       |
| `ProxyFundingStrategy/buyer-not-proxy`        | strategy | `onBuy` for a fill the proxy is not buying, i.e. a stranger's offer naming it      |
| `ProxyFundingStrategy/nothing-to-skim`        | strategy | `skim` on a token the strategy holds none of                                       |
| `ConsumedUnits()`                             | Midnight | the designated group is exhausted, including by `cancelOfferGroup`                 |
| `MakerCreditOrDebtIncreased()`                | Midnight | a `reduceOnly` sell fill that would have increased the position                    |
| `UnusedReceiverMustBeZero()`                  | Midnight | a buy offer naming a receiver, refused before ratification runs                    |
| `RatifierUnauthorized()`                      | Midnight | the ratifier's authorization was revoked                                           |

---

## Operational Requirements

### Configuration (before first trade)

Per market (`marketId`):

1. Confirm the market exists on the singleton (`toMarket(marketId)` resolves, `settlementFee` does not revert). If not, anyone can `touchMarket(market)` once; the facet does not.
2. Review the market config the id commits to: loan token, maturity, collateral tiers (LLTV, liquidation cursor, oracle), `rcfThreshold`, gates. A tier at LLTV `1e18` lets a borrower sell against the full collateral value, so any adverse oracle move leaves bad debt for lenders; treat it as a due-diligence red flag.
3. `setMarketConfig(marketId, ...)`: required, and every limit is passed in the one call. `minSellTick` non-zero and below par net of the settlement fee; `maxBuyTick` at the highest all-in price acceptable for the remaining term; `minBuyYield` at the lowest rate worth entering for and `maxSellYield` (non-zero) at the widest give-up an exit may pay, both in basis points a year; `maxContinuousFee` (centi-basis points a year) and `maxLossFactor` at the tolerances the position can absorb, both defaulting to zero.
4. Configure `LIMIT_MIDNIGHT_BUY`, `LIMIT_MIDNIGHT_SELL` and `LIMIT_MIDNIGHT_REDEEM` keyed `marketId`, in the loan token's units. The exits are gated only by their own keys; zeroing the buy key pauses entry without touching exits.

No seeding is required: the integration holds no intermediate token and uses no auxiliary module. Offers are sourced off-chain from makers (or the Morpho API) and passed in calldata by the allocator together with each maker's ratifier data.

### Enabling maker mode on a market

Steps 1 to 3 above are prerequisites. Maker mode is off until all of the following are done, and each one on its own is a kill switch.

5. Deploy `MidnightRatifier` (admin, singleton, proxy, controller, rate limits, quoter, `maxOfferWindow`) and `ProxyFundingStrategy` (singleton, proxy, controller). Both are immutable; rotating either means a new deployment and a spell. Review the deployed bytecode against the reviewed source before authorizing anything.
6. `setMakeConfig(market, maxOfferSize)` on an already-onboarded market, passing the full `Market` struct.
7. `setDesignatedGroups(marketId, buyGroup, sellGroup)` with two distinct non-zero groups. Leave a side zero to make the market one-directional. These are the only groups `cancelOfferGroup` can retire, so publish offers into nothing else.
8. Configure `LIMIT_MIDNIGHT_STRATEGY` keyed `(strategy, marketId)`. Its existence is the strategy's authorization; its size caps that strategy inside the market's shared `LIMIT_MIDNIGHT_BUY` budget.
9. `setRatifierAuthorization(ratifier, true)` **last**, once everything above is in place and verified. This is the blanket grant described above, and it is what makes resting offers fillable at all.
10. Set the quoter on the ratifier (`setQuoter`, ratifier admin) to the signing key that will publish offers. Rotating it invalidates every offer signed by the old key.

Verify the intended `maxBuyTick` against `maxBuyPrice(minBuyYield, timeToMaturity, continuousFeePerSecond(maxContinuousFee))` before publishing, not against the live fee: maker entry is bounded by the capped-fee ceiling, which at a 180 day term with the 1%/year cap sits about 48 basis points below the live-fee ceiling taker entry uses.

**Revoking, fastest first.** All five levers act on offers already signed and published, which cannot be recalled from the venue:

| Lever                                       | Scope                                                   | Role      |
| ------------------------------------------- | ------------------------------------------------------- | --------- |
| `setRatifierAuthorization(ratifier, false)` | every market, both directions, one transaction          | admin     |
| `setMakeConfig(market, 0)`                  | one market, both directions                             | admin     |
| zero `LIMIT_MIDNIGHT_STRATEGY`              | one strategy on one market, entry only                  | admin     |
| tighten `setMarketConfig` ticks or yields   | one market, the tightened direction                     | admin     |
| `cancelOfferGroup(group)`                   | one direction on one market, irreversible for that group | allocator |

### Liquidity

The facet makes no liquidity claims. At the time of writing every live mainnet market carries dust-sized depth and is unlisted; the counterparty for any meaningful size is a maker publishing offers against the position, not standing on-chain liquidity. Position sizing has to assume the exit is a maker's buy offer or the repayment pool, whichever comes first.

### Monitoring

- **`lossFactor` per market**: any increase means a liquidation socialized bad debt against the position. Entry is gated by `maxLossFactor`; the write-down on the existing position is immediate and unrecoverable.
- **Fee changes** (`continuousFee`, settlement fee schedule): raised fees widen the spread on every trade and can lift every offer's all-in cost over `maxBuyTick` (`MidnightFacet/buy-price-too-high`) or push the `minSellTick` floor over par, wedging that side until governance reconfigures. Both fees sit inside the yield bounds, so a fee rise re-prices those rather than leaving them stale, with one exception: close to maturity the sell floor is already near par, and adding the fee on top can push it above par, so `sell` reverts (`MidnightFacet/sell-yield-too-high`) until the fee falls or governance widens `maxSellYield`. With the schedule at the protocol ceiling that window is roughly the last hour at a `maxSellYield` of `10_00` and the last six at `2_00`, and it scales with the fee: a 50 bp fee landing in the shortest bucket would widen it to 18 and 92 days respectively. Past maturity the floor is exactly par, so any live settlement fee closes the sell path and `redeem` is the only exit, which costs nothing because a post-maturity sell can never beat redemption anyway (see `sell` above). At the time of writing every fee on every live market is zero and no `feeSetter` has been appointed, so the whole schedule can go from zero to the protocol ceilings on one configurator action with no notice.
- **Role and tier changes** by the singleton's `configurator` (`feeSetter`, `feeClaimer`, `tickSpacingSetter`, tiers, the configurator itself): the privileged levers on the venue. Fee claims reduce `withdrawable`, so they show up as slower redemption.
- **`withdrawable` vs. credit** around maturity: redemption is first come first served out of repayments. Slow repayment after maturity means slow redemption, not loss, unless liquidations fall short.
- **Oracle health** of every collateral tier in the market: a stale or manipulated oracle is what turns a borrower's default into a lender's loss.
- **Maker concentration**: the position's exit before maturity depends on makers willing to buy. A single maker on both sides of the book is a liquidity risk, not a solvency one.

When maker mode is enabled, additionally:

- **`isAuthorized[proxy][x]` on the singleton**: must hold for the ratifier and no other address. Any other entry is a blanket grant over the proxy's position.
- **The quoter key's custody**: it is the only thing that can create a fillable offer, and the maker exit leg has no rate limit behind it. Treat a rotation (`setQuoter`) as the fastest way to void everything signed so far.
- **Published offers** against `maxOfferSize` and against the designated groups' consumed counters, which is what bounds how much of a signed offer can still be filled.
- **`LIMIT_MIDNIGHT_STRATEGY` drawdown** as the maker entry rate, read against `LIMIT_MIDNIGHT_BUY`, which maker and taker entry share.

## Related Documentation

- [ARCHITECTURE.md](./ARCHITECTURE.md): overall facet architecture and Controller dispatch.
- [RATE_LIMITS.md](./RATE_LIMITS.md): rate-limit key construction, try-increase and gate-check patterns.
- [THREAT_MODEL.md](./THREAT_MODEL.md): protocol trust matrix and external risk surface.
