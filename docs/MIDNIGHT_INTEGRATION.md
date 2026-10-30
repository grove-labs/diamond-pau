# Morpho Midnight Integration

This document describes the Morpho Midnight integration with the PAU system. It covers the `MidnightFacet`, the fixed-term credit markets it trades on, how a lending position is entered, exited and rate-limited, and the per-market price, fee and loss controls that govern entry.

> **Scope.** The integration has two modes. In **taker mode** the ALMProxy takes other makers' offers; that is the subject of [Operations](#operations) below. In **maker mode** the proxy rests its own signed offers and third parties take them through a purpose-built ratifier and funding strategy; see [Maker Mode](#maker-mode). Statements in the taker sections about what the facet "never" does are taker-mode statements.

Protocol behavior described here was checked against the Morpho Midnight codebase at commit `70607569ac348e9880b512ffd3b574be55405932` (`main`, 2026-09), which is the code deployed as the mainnet singleton `0x471686c42792F93528B000beF54bC10E3aa2045f` (identical bytecode on Base at `0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A`).

## Overview

Midnight is a **singleton, fixed-term, fixed-rate credit market**. A market is a `Market` struct (loan token, maturity, collateral tiers with oracle and LLTV, optional gates) and is identified by its `id`: the full 32-byte CREATE2 hash `keccak256(0xff ‖ market.midnight ‖ 0 ‖ keccak256(SSTORE2_PREFIX ‖ abi.encode(market)))`, whose low 20 bytes are the address the singleton stores the encoded config at. `MidnightIdLib.toId` computes it; an address-derivation helper would return only the truncated 20 bytes and never match. Inside a market every position is denominated in **units**: one unit is a claim on one loan token at maturity.

- A **borrower** supplies collateral and **sells** units: it receives the discounted price now and owes one loan token per unit at maturity (debt).
- A **lender** **buys** units at a discount and holds credit. At or after maturity, once borrowers have repaid, credit is **redeemed** at par.
- Trades are maker **offers** taken on-chain. A maker publishes an `Offer` (direction, tick, size, expiry, ratifier, optional callback) off-chain and a taker calls `take` with it. The maker's **ratifier** contract decides whether an offer is live; the singleton stores no order book.
- Price is a **tick**: `tickToPrice(tick)` maps `0..6744` onto a rising logistic curve rounded to `1e-7` WAD, with `3372` at exactly `0.5e18`. A tick of `4152` is roughly `0.98`, `4384` roughly `0.99`, and `6744` par.
- Fees: a **settlement fee** (per-market, resolved from a piecewise schedule over time to maturity) widens the spread on every take, and a **continuous fee** (per second, WAD) is crystallized on the buyer over the remaining term when credit is created.
- Loss: when a liquidation cannot cover a borrower's debt, the shortfall is **socialized** across all lenders in the market through a monotone `lossFactor` ratchet.

In **taker mode**, the subject of this document, the `MidnightFacet` is a **lender-only** integration: the ALMProxy buys units from makers' sell offers, sells them back into makers' buy offers before maturity, and redeems them at par once repayments land. In **maker mode** it also rests its own offers on both sides, still lender-only, with every maker exit required to leave the position debt-free. In neither mode does it supply collateral, borrow, liquidate or hold debt. Every external call is pinned to a single immutable Midnight singleton.

Structs and the tick and id math are vendored verbatim, one file per upstream source: `MidnightInterfaces.sol` from `src/interfaces/IMidnight.sol`, `MidnightTickLib.sol` from `src/libraries/TickLib.sol`, and `MidnightIdLib.sol` from `src/libraries/IdLib.sol`, each naming its upstream file and the pinned commit in a header. They are vendored because the market id is a hash over the struct layout: any drift would silently change every id. The protocol repo is not importable as a Foundry library and only these few definitions are needed, so there is no `lib/` submodule, and the vendored `unchecked` blocks are kept exactly as upstream wrote them for the same parity reason. `MidnightUtils.sol` holds the facet's own yield math, which has no upstream counterpart, alongside a mirror of Midnight's continuous-fee ceiling. The mainnet-fork suite pins parity by recomputing three live market ids.

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

Maker:   see Maker Mode below; both legs reach the facet through a strategy's callback
```

Three paths move value out of the ALMProxy's control, and every other leg only moves loan tokens in:

| # | Path | Destination | Bounded by |
| - | ---- | ----------- | ---------- |
| 1 | `doCall` `midnight.take` inside `buy` (taker entry) | the maker's `receiverIfMakerIsSeller`, which must not be the proxy, plus the settlement fee left in the venue | `LIMIT_MIDNIGHT_BUY` per `marketId`; `maxAssetsIn` as both the allowance and the post-check |
| 2 | `doCall` `loanToken.transfer` inside `fundFill` (maker entry) | the calling funding strategy, which approves the exact amount to the singleton and is drained by it inside the same `take` | the caller's own `LIMIT_MIDNIGHT_STRATEGY_BUY` key for that market as the authorization, then `LIMIT_MIDNIGHT_BUY`, both debited by `assets` before the transfer; `assets * WAD <= units * maxFillPrice`; live `lossFactor` and live `continuousFee` |
| 3 | a third party's `take` against a resting proxy sell offer (maker exit) | `offer.receiverIfMakerIsSeller`, which the ratifier requires to be the proxy | the ratifier at fill time (freeze flag, parties, group, expiry, window, receiver, `reduceOnly`, signature, a non-zero callback keyed for the market and direction); the offer's own `maxUnits` against its group's consumed counter; `fundFill` through `onSell`, which enforces the exit floor on the clamped fee basis, requires zero debt afterwards, and debits `LIMIT_MIDNIGHT_STRATEGY_SELL` then `LIMIT_MIDNIGHT_SELL` |

Path 3 is the integration's one asymmetry: **credit units can leave the proxy's position without any transaction of ours**, and whether a fill happens at all is decided by the ratifier's view call. Path 2 is the only path here that sends loan tokens to a contract that is not the proxy; the containment is that the strategy is reviewed, non-upgradeable, holds no balance between settlements, and is drained inside the same `take` that funded it.

`sell`, `redeem` and path 3 all move loan tokens into the proxy. Credit is not a token: it cannot leave the proxy's position except through `sell`, `redeem` or path 3, and all three name the proxy as receiver.

---

## Operations

### Buy (enter, take makers' sell offers)

**Function:** `buy(marketId, offer, ratifierData, units, maxAssetsIn) returns (assetsSpent)` (`ALLOCATOR_ROLE`)

**Flow:**

1. Read the market config for `marketId`; revert `MidnightFacet/buy-not-enabled` if `maxBuyTick` is zero. Require `maxAssetsIn != 0` (`MidnightFacet/max-assets-in-not-set`).
2. Require `offer.market.midnight == midnight` (`MidnightFacet/invalid-midnight`) and `toId(offer.market) == marketId` (`MidnightFacet/market-mismatch`). Every subsequent read and call goes to the immutable singleton, so the market from calldata is only usable once it names that venue, and binding it to the id here keeps a fabricated maturity out of the bound arithmetic in step 4. Snapshot the proxy's live credit (`updatePositionView`) and loan-token balance.
3. Require the market's `continuousFee`, a per-second rate, to be within `maxContinuousFee` converted out of its annual form (`MidnightFacet/continuous-fee-too-high`) and `lossFactor <= maxLossFactor` (`MidnightFacet/loss-factor-too-high`). Entering crystallizes the continuous fee over the remaining term and buys into whatever loss has already been socialized, so both are entry-only gates.
4. Resolve two price ceilings and apply both. The tick ceiling is `tickToPrice(maxBuyTick)`. The yield-implied price ceiling is `maxBuyPrice(minBuyYield, timeToMaturity, continuousFee)`: the highest all-in price that still earns `minBuyYield` basis points a year at simple interest over ACT/365, measured on what a unit returns (par less the continuous fee crystallized for the remaining term). Both are ceilings on the all-in price the proxy pays, the settlement fee is added to each offer's price before either comparison, and the stricter ceiling binds.
5. Require `offer.buy == false` (`MidnightFacet/invalid-offer-direction`), `units != 0` (`MidnightFacet/zero-units`), `tickToPrice(offer.tick) + settlementFee <= tickCeiling` (`MidnightFacet/buy-price-too-high`), `tickToPrice(offer.tick) + settlementFee <= yieldCeiling` (`MidnightFacet/buy-yield-too-low`) and `offer.receiverIfMakerIsSeller != proxy` (`MidnightFacet/invalid-offer-receiver`, see [Security Considerations](#self-paying-offers)).
6. Approve `loanToken` from the ALMProxy to Midnight for exactly `maxAssetsIn`, then `doCall` `midnight.take(offer, ratifierData, units, proxy, 0, 0, "")`. Every check above runs before the allowance exists.
7. Reset the approval to zero in case Midnight did not pull the full amount.
8. Size `assetsSpent` as the higher of the ALMProxy balance delta and the `buyerAssets` the take reports, and require `assetsSpent <= maxAssetsIn` (`MidnightFacet/max-assets-in-exceeded`). Loan token arriving at the proxy inside the take shrinks the delta, so the venue's own figure floors what the meter sees (see [Measured Deltas and the Venue's Figure](#measured-deltas-and-the-venues-figure)).
9. Require the live credit to have grown by exactly the units taken (`MidnightFacet/credit-delta-mismatch`) and the proxy's debt to be zero (`MidnightFacet/debt-not-zero`). Anything a maker callback did to market state during the fill surfaces here.
10. Decrement `LIMIT_MIDNIGHT_BUY` keyed `marketId` by `assetsSpent`.

**Rate Limit:** `LIMIT_MIDNIGHT_BUY` via `makeBytes32Key(LIMIT_MIDNIGHT_BUY, marketId)`.

The key is salted with the governance-supplied `marketId` only. Nothing read from the protocol feeds a key: the id is itself a commitment to the full market config (venue, loan token, maturity, collateral tiers, gates), so there is nothing a counterparty can remap.

**Event:** `MidnightBuy(marketId, units, assetsSpent)`, where `assetsSpent` is the metered spend, fees included.

**Taking more than one offer:** a call takes exactly one offer. A relayer sweeping several offers issues several calls in one transaction. Each call carries its own price bound, grants and clears its own allowance, and decrements the same meter, so the aggregate matches what a single batched call used to do, while a bad offer only costs that one call.

**Zero units:** the facet rejects a zero size (`MidnightFacet/zero-units`) before reaching Midnight.

**Untouched market:** `settlementFee` reverts (`MarketNotCreated()`) on a market that has never been created on the singleton. Anyone can create one with a single permissionless `touchMarket(market)` call; the facet does not do it.

**Post-maturity:** Midnight refuses to let a maker take on new debt after maturity (`CannotIncreaseDebtPostMaturity()`), but a maker that already holds credit can still sell it, so a `buy` from such a maker succeeds after maturity. With no term left the yield-implied ceiling is par whatever `minBuyYield` is set to, so only `maxBuyTick` still binds on an offer's price. The facet does not check maturity; closing entry means zeroing `maxBuyTick`.

### Sell (exit early, take makers' buy offers)

**Function:** `sell(marketId, offer, ratifierData, units, minAssetsOut) returns (assetsReceived)` (`ALLOCATOR_ROLE`)

**Flow:**

1. Read the market config; revert `MidnightFacet/sell-not-enabled` if `minSellTick` is zero. Require `minAssetsOut != 0` (`MidnightFacet/min-assets-out-not-set`).
2. Require `offer.market.midnight == midnight` (`MidnightFacet/invalid-midnight`) and `toId(offer.market) == marketId` (`MidnightFacet/market-mismatch`), snapshot credit and balance.
3. Resolve two price floors and apply both. The tick floor is `tickToPrice(minSellTick)`. The yield-implied price floor is `minSellPrice(maxSellYield, timeToMaturity, credit, pendingFee)`: the lowest net price that gives up no more than `maxSellYield` basis points a year on the same ACT/365 basis as the buy leg. The two legs measure the continuous fee differently, and deliberately so. A buy fixes the market's current rate onto the new units for their whole term, so the entry ceiling uses that rate; a position then keeps the fee it was bought at, so the exit floor uses the lien that position still carries, `pendingFee / credit` as reported by `updatePositionView`. Pricing the exit off the market's live rate instead would move the floor on every fee change: a rise would drop it below the configured policy and let a cheaper exit through, and a cut would raise it and block exits the position's own economics justify. Selling receives the tick price less the fee, so `settlementFee(marketId, timeToMaturity)` is added to each floor before comparison, and the stricter floor binds.
4. Apply the same direction (`offer.buy == true`) and non-zero-units checks as `buy`. Cap `units` at the proxy's **live credit** and require what is left to be non-zero (`MidnightFacet/no-credit-to-sell`), so a sell can never be filled with debt. Then `tickToPrice(offer.tick) >= tickFloor + settlementFee` (`MidnightFacet/sell-price-too-low`) and `tickToPrice(offer.tick) >= yieldFloor + settlementFee` (`MidnightFacet/sell-yield-too-high`). Then `doCall` `midnight.take(offer, ratifierData, cappedUnits, proxy, proxy, 0, "")`.
5. Measure `assetsReceived` as the ALMProxy balance delta and require `assetsReceived >= minAssetsOut` (`MidnightFacet/min-assets-out-not-met`).
6. Require the live credit to have shrunk by exactly the units sold (`MidnightFacet/credit-delta-mismatch`) and the proxy's debt to be zero (`MidnightFacet/debt-not-zero`).
7. Decrement `LIMIT_MIDNIGHT_SELL` keyed `marketId` by `assetsReceived`. The buy key is not read, so it is neither a precondition for the exit nor restored by it.

**Rate Limit:** `LIMIT_MIDNIGHT_SELL` via `makeBytes32Key(LIMIT_MIDNIGHT_SELL, marketId)`.

**Event:** `MidnightSell(marketId, units, assetsReceived)`, where `units` is what was actually sold after capping and `assetsReceived` the measured balance delta, net of fees.

**Credit drifts down:** the live credit read from `updatePositionView` already reflects accrued continuous fee and any socialized loss, so the cap in step 4 is what keeps a sell from ever creating debt. An ask sized against a stale credit reading is trimmed to what is left, and one against an exhausted position reverts.

**Post-maturity:** selling stays open only at par. The settlement fee schedule resolves at zero time to maturity, and so does the yield-implied price floor: with no term left, any discount gives up unbounded yield against a redemption that pays par, so the floor collapses onto par and refuses every discounted offer (`MidnightFacet/sell-yield-too-high`). A crystallized lien is fully accrued by maturity, so this holds for a position bought under a live continuous fee as well: its `pendingFee` is zero by then and the floor is exactly par. A par offer (tick `6743` or `6744`) still clears when the settlement fee is zero. This is deliberate, and it costs nothing: `redeem` pays exactly par with no fee, while a sell pays the tick price less the settlement fee, so `sell <= par - settlementFee <= redeem` for every offer. A post-maturity sell can therefore never beat redemption; the floor blocks a guaranteed loss rather than a trade, and the one case it still permits (par price, zero fee) is cash-identical to redeeming while not drawing on `withdrawable`. Note that no configuration value reopens a discounted exit: the yield-implied price floor at zero time to maturity is par regardless of `maxSellYield`, and `minSellTick` only feeds the looser of the two floors, so changing this would take a new facet deployment, not a spell.

### Redeem (exit at par from repayments)

**Function:** `redeem(marketId, units, minAssetsOut) returns (assetsWithdrawn)` (`ALLOCATOR_ROLE`)

**Flow:**

1. Require the market to be onboarded, `minSellTick != 0` (`MidnightFacet/market-not-onboarded`). Redemption reads no other config value; the onboarded config is what authenticates the id. Require `minAssetsOut != 0` (`MidnightFacet/min-assets-out-not-set`), as on `sell`.
2. Resolve the `Market` struct from the id on the singleton (`toMarket(marketId)`), so redemption never trusts a market from calldata.
3. Cap `units` at both the proxy's live credit and the market's `withdrawable` amount (repaid, not yet withdrawn), then require the result to be non-zero (`MidnightFacet/zero-units`). Passing `type(uint256).max` redeems everything currently available.
4. Snapshot the balance, `doCall` `midnight.withdraw(market, units, proxy, proxy)`, and measure `assetsWithdrawn` as the balance delta. Require `assetsWithdrawn >= minAssetsOut` (`MidnightFacet/min-assets-out-not-met`).
5. Require the proxy's debt to be zero (`MidnightFacet/debt-not-zero`).
6. Decrement `LIMIT_MIDNIGHT_REDEEM` keyed `marketId` by `assetsWithdrawn`. As on `sell`, the buy key is not read.

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
- The yield bounds cannot overflow or underflow. Midnight refuses a maturity more than 100 years out (`MaturityTooFar()`) and caps the continuous fee at one percent a year, so the fee crystallized over any reachable term stays below par. That holds only because the market from calldata is bound to `marketId` before any bound is computed; a fabricated maturity would otherwise reach the arithmetic.
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
| `getStrategyBuyRateLimitKey(strategy, marketId)`  | `makeAddressBytes32Key(LIMIT_MIDNIGHT_STRATEGY_BUY, strategy, marketId)`  |
| `getStrategySellRateLimitKey(strategy, marketId)` | `makeAddressBytes32Key(LIMIT_MIDNIGHT_STRATEGY_SELL, strategy, marketId)` |
| `getMarketConfig(marketId)`       | Configured `MarketConfig`, all-zero when not onboarded                |
| `getMakeConfig(marketId)`         | Configured `MakeConfig`, all-zero when making is disabled             |
| `getDesignatedGroups(marketId)`   | Configured `DesignatedGroups`, all-zero when nothing is designated    |
| `isCallbackAllowed(marketId, callback, buying)` | Whether `callback` may settle this market's fills in that direction |
| `midnight()`                      | The immutable Midnight singleton every call is pinned to              |

`getDesignatedGroups` and `isCallbackAllowed` are not diagnostics: the ratifier staticcalls both on every maker fill, so they are the live policy interface maker mode runs on. `isCallbackAllowed` is true only when the callback is non-zero, the market's `maxOfferSize` is non-zero, and both the strategy key and the market key for that direction have a non-zero `maxAmount`. It reads configuration, not remaining capacity, so an exhausted key still ratifies and the fill then reverts in `fundFill`. The zero address is refused outright, so a key funded for it by mistake cannot ratify an offer whose fills would never reach the facet. The rest of the policy is read by `fundFill` itself.

---

## Maker Mode

In maker mode the proxy stops waiting for someone else's offer and publishes its own. An off-chain **quoter** key signs an `Offer` naming the proxy as maker; a third party finds it, calls `midnight.take` directly, and the settlement happens with no transaction of ours in the call stack. Two immutable periphery contracts stand in for the facet inside that stack:

- a **ratifier**, the contract Midnight asks whether an offer is live. It must be a pure `view` that recovers the quoter's signature over the offer, reads this facet's `DesignatedGroups` and `isCallbackAllowed` view, and refuses anything outside them. It must never call the singleton.
- a **funding strategy**, named as the `callback` on offers in both directions. On a buy it is the payer Midnight pulls from: it calls `fundFill` to draw the exact amount from the proxy, approves the singleton for it, and is drained inside the same `take`. On a sell it funds nothing, since Midnight has already paid the proxy by the time `onSell` fires; it calls `fundFill` only so the exit is metered.

**Neither contract ships from this repository.** Both are deployed, audited and tested in the periphery repository, against this facet and the ALM controller's matching surface. The ratifier this repo's fork suite uses is Morpho's `SetterRatifier`, and its mock strategy only mirrors the caller and party checks of the real one; neither carries the ratifier policy, so a maker test here proves the facet's own gates and nothing about an acceptable ratifier. What an acceptable one must enforce is listed below, and that list is the acceptance spec the periphery repository is built against.

The proxy is still lender-only in this mode: buy offers acquire credit, every sell fill must leave the position with zero debt so it can only shed credit the proxy already holds, and nothing borrows or supplies collateral.

```
Maker buy:   taker calls midnight.take(proxy's buy offer)
             → ratifier.isRatified(offer, sig, taker)                  [view, reverts to refuse]
             → strategy.onBuy(...) → controller.fundFill(..., buying = true)
                 → loanToken (ALMProxy) → strategy
             → midnight pulls buyerAssets from strategy
             credit += units (proxy's position)

Maker sell:  taker calls midnight.take(proxy's sell offer)
             → ratifier.isRatified(offer, sig, taker)                  [view, reverts to refuse]
             → loanToken (taker) → ALMProxy, at the offer's tick price
             → strategy.onSell(...) → controller.fundFill(..., buying = false)
                 → meters only, moves nothing
             credit -= units (proxy's position)
```

The settlement fee always falls on the taker, so on a maker sell the proxy receives the offer's full tick price and the taker pays that plus the fee.

### What an Acceptable Ratifier Must Enforce

The facet cannot see a resting offer, so anything decidable only from the signed offer is enforced by the ratifier or not at all. A ratifier passed to `setRatifierAuthorization` must refuse an offer unless:

1. the ratifier is not frozen. Its `freeze()` is the maker kill switch: it refuses every offer, across markets and directions, until its admin calls `unfreeze()`;
2. it carries a current signature from the quoter over the offer digest, so rotating the quoter voids every outstanding offer;
3. `maker` is the proxy, `ratifier` is the ratifier itself, and `market.midnight` is the configured singleton;
4. `receiverIfMakerIsSeller` is the proxy on a sell and zero on a buy, so proceeds cannot be redirected;
5. `reduceOnly == !buy`, so a sell offer can only shed credit and a buy offer is never reduce-only;
6. the offer has not expired, its window is not inverted, and the window is no longer than a configured maximum;
7. the offer's group is the designated group for its direction, and that direction has one designated;
8. the callback is non-zero and `isCallbackAllowed(marketId, callback, offer.buy)` holds, which needs that strategy's key and the market key for the offer's direction to be configured. Midnight routes a buy offer's callback to `onBuy` and a sell offer's to `onSell`, and skips the callback entirely when it is zero, so this is what makes metering unavoidable: an offer naming no callback would settle without reaching the facet at all.

Deliberately **not** on that list: price, size, the continuous fee, the loss factor and make-enabled. All of those depend on the fill rather than on the offer, so they are enforced per fill in `fundFill`, which every fill reaches through its keyed callback. The `reduceOnly` requirement and `fundFill`'s zero-debt post-condition give the same guarantee twice, once promised by the offer and once read from the result. The split is a division of labour, not a gap, and it means the ratifier never has to predict a price it cannot know at signing time.

### Strategy Conformance Rules

Strategies are trusted code: the facet does not cross-check what a strategy reports, it bounds it with the price gates and the keys. Every strategy must:

- be callable only by the Midnight singleton, and check that the `buyer`, `seller` or `receiver` it is told about is the proxy;
- call `fundFill` with the callback's direction and exactly Midnight's `assets`, `units` and pending fee value;
- leave no allowance behind, and no balance in the strategy itself;
- never take amounts, venues or slippage parameters from callback data;
- return success without calling `fundFill` on a dust callback, as described under [Fund Fill](#fund-fill-callback-no-role);
- not short-circuit a sell whose assets round to zero (`units > 0`, `sellerAssets == 0`): it reverts by design, as described under [Fund Fill](#fund-fill-callback-no-role).

**Pass-through strategies** hold no role.

**Operator-role strategies** source their own liquidity inside `onBuy` and hold `ALLOCATOR_ROLE` in `AccessControls`. Each must be immutable, run one hardcoded sourcing sequence, and be audited on its own. Onboarding takes two authorities: governance sets the strategy keys for each market and direction it serves, and the allocator role admin grants it `ALLOCATOR_ROLE`. That admin is whichever role `setRoleAdmin` names (`ALLOCATOR_ADMIN_ROLE` in the reference deployment), and `DEFAULT_ADMIN_ROLE` can always reassign it. Offboarding is the reverse: zero its keys, and have the allocator role admin revoke the role. Midnight pays a sell's proceeds to the proxy before it calls `onSell`, so a sell strategy can redeploy them in the same callback. Sourcing may leave residual dust on the proxy, or run a cleanup step after `fundFill`; the strategy itself still ends every callback empty.

The role is the whole allocator surface, not just the sequence the strategy's code runs: it can spend every rate limit `ALLOCATOR_ROLE` can spend, and only revoking the role ends that. Per fill, the loan token `fundFill` sends it is at most the lesser of `maxOfferSize`, its strategy key and the market key for the direction; a venue key binds only the amount the sourcing sequence draws through that venue.

**Phase 3 design considerations.** These describe risks, not restrictions; which strategies phase 3 builds is not decided.

- The taker chooses the timing and size of a fill, so sourcing inside `onBuy` runs when the taker wants. Sourcing with price impact can be sandwiched inside the same transaction, and a slippage bound derived from a spot price the taker can move protects nothing.
- Sourcing paths share venue rate limits with human allocators, and a taker can consume that capacity.
- USDS minting is available on this host. The ALM controller's Midnight integration lives on `ForeignController`, which has no mint integration, so mint-based sourcing is diamond-only.
- The periphery's conformance test base covers pass-through strategies. A variant that runs role-holding strategies against the real hosts is future work.

### Fund Fill (callback, no role)

**Function:** `fundFill(marketId, buying, assets, units, pendingFee)` (**no role**, see below)

Called by a funding strategy keyed for the market and direction, from inside Midnight's `onBuy` or `onSell`, never by an allocator. It is the only facet function reached from a third party's transaction.

**Flow, both directions:**

1. Require `makeConfig.maxOfferSize != 0` (`MidnightFacet/make-not-enabled`), `assets != 0` (`MidnightFacet/zero-assets`), `units != 0` (`MidnightFacet/zero-units`), and `assets <= makeConfig.maxOfferSize` (`MidnightFacet/offer-size-too-large`).

**Then, when `buying` is true (an entry):**

2. Require `continuousFee(marketId) <= continuousFeePerSecond(maxContinuousFee)` (`MidnightFacet/continuous-fee-too-high`), read live. The price bound below is computed at the configured ceiling, so a live rate above it would let the fill clear the bound while earning less than `minBuyYield`.
3. Require `lossFactor(marketId) <= maxLossFactor` (`MidnightFacet/loss-factor-too-high`), read live, so a market whose lenders have already been slashed stops funding fills.
4. Require `assets * WAD <= units * maxFillPrice` (`MidnightFacet/fill-price-too-high`), where `maxFillPrice` is the lesser of `tickToPrice(maxBuyTick)` and `maxBuyPrice(minBuyYield, timeToMaturity, continuousFeePerSecond(maxContinuousFee))`. `pendingFee` is accepted and ignored on an entry.
5. Decrement the caller's `LIMIT_MIDNIGHT_STRATEGY_BUY` key for `marketId`, then `LIMIT_MIDNIGHT_BUY` keyed `marketId`, the same market key a taker `buy` spends, each by `assets`. An unset strategy key reverts here (`RateLimits/zero-maxAmount`) before anything moves.
6. `doCall` `loanToken.transfer(msg.sender, assets)` as the last step, so every gate and the meters have already passed, and require it to return nothing or `true` (`MidnightFacet/transfer-failed`). The loan token comes from stored `MakeConfig`, never from the caller.

**Then, when `buying` is false (an exit):**

2. Require `assets * WAD >= units * minFillPrice` (`MidnightFacet/fill-price-too-low`), where `minFillPrice` is the greater of `tickToPrice(minSellTick)` and `minSellPrice(maxSellYield, timeToMaturity, WAD, feePerUnit)`, and `feePerUnit` is `min(pendingFee * WAD / units, carried * WAD / creditPost)` read from the proxy's position after the fill. A full exit (`creditPost == 0`) uses a zero fee per unit, so its floor is the zero-fee yield floor. So does a near-full exit whose carried fee rounds to zero: Midnight rounds the fee a fill sheds up, so a position left with dust credit can carry no fee at all. Both only tighten the floor, but a quoter that prices such an exit at the fee-adjusted floor will see the taker's fill revert with `fill-price-too-low`. Neither the loss factor nor the live fee is checked: a slashed market is when an exit matters most, and an exit moves no money of ours.
3. Require `debt(marketId, proxy) == 0` (`MidnightFacet/debt-not-zero`), so an exit can shed credit but never open a short. Positions are already written when `onSell` fires, so this reads the result of the fill being reported.
4. Decrement the caller's `LIMIT_MIDNIGHT_STRATEGY_SELL` key for `marketId`, then `LIMIT_MIDNIGHT_SELL` keyed `marketId`, the same market key a taker `sell` spends, each by `assets`. Nothing is restored on any leg.
5. Move nothing. Midnight paid the proxy before calling back, so the exit branch is a meter, a price gate and a post-condition only.

Both price comparisons are cross-multiplied rather than divided, so neither bound is loosened by a wei of flooring.

**No role, deliberately.** The caller's strategy key is the authorization. A strategy is onboarded for one market and one direction by giving its `LIMIT_MIDNIGHT_STRATEGY_BUY` or `LIMIT_MIDNIGHT_STRATEGY_SELL` key a non-zero `maxAmount`, and offboarded by zeroing it; there is no separate whitelist, setter, event or role. A caller with no key for the market and direction reverts in the rate limits before anything moves. The amount is bounded by the strategy's own key and then by the market's key for that direction, both debited before any transfer.

**Rulebook exception.** The facet rulebook requires `nonReentrant onlyRole(...)` on every state-changing external function (A-2) and forbids bespoke caller allowlists (A-1). `fundFill` is a documented exception to both, as a callback entry point reached from a third party's transaction: its caller is whichever strategy the offer names, running inside a stranger's `take`, so no role of ours can sit on that path. The strategy key bounds it per market and direction exactly as a role would, and an unset key reverts before any state change, so the default is still deny. An upstream exemption for callback entry points is being requested separately.

**Rate Limit:** `LIMIT_MIDNIGHT_STRATEGY_BUY` keyed `(strategy, marketId)` then `LIMIT_MIDNIGHT_BUY` keyed `marketId` on an entry; `LIMIT_MIDNIGHT_STRATEGY_SELL` then `LIMIT_MIDNIGHT_SELL` on an exit; each debited by `assets`. The market keys are shared with taker traffic, so maker and taker flow draw on one per-market budget per direction, and each strategy additionally has its own budget per market and direction.

**Refill:** no maker leg restores anything, so entry room comes back only from each key's own slope. A maker exit burns exit room without returning entry room, and no leg spends or restores a key of the other direction.

**Exits can be metered to a stop.** The strategy and market sell keys gate a maker sell, and a fill that exceeds either reverts the *taker's* transaction, not ours. Sizing them too tightly therefore makes a resting sell offer look broken to the outside. `cancelOfferGroup` on the sell group is the control to use when the exit budget is nearly spent, since it retires the book instead of leaving it failing.

**Event:** `MidnightFillFunded(marketId, strategy, buy, assets, units)`

**Maker entry is bounded more tightly than `buy`.** `fundFill` prices the continuous fee at the *configured cap*, while `buy` prices the market's *live* rate, because an offer is signed before the rate it will settle at is known and the ratifier has to agree with `fundFill` at signing time. At a 180 day term with the 1%/year cap the two bounds differ by about 48 basis points, so a tick that taker entry accepts can still be refused for a maker buy. Verify an intended `maxBuyTick` against the capped-fee bound before publishing.

**Dust callbacks.** Midnight places no lower bound on `units`, so any offer can be taken for zero units and the callback still fires, and a small enough buy fill rounds `buyerAssets` down to zero. The strategy returns success without calling `fundFill` when `buyerAssets == 0` on a buy, or when `units == 0` on a sell or a zero-unit take. Nothing is metered and nothing moves. A zero-asset buy gives the proxy free dust credit. This is a conformance rule: `fundFill` refuses both cases, so a strategy that called it would fail an unrelated taker's transaction.

A sell whose assets round to zero (`units > 0`, `sellerAssets == 0`) reverts by design; strategies do not short-circuit it. Midnight has already taken the proxy's units when `onSell` runs, so a short-circuit would hand those units away with no floor and no meter; the revert (`MidnightFacet/zero-assets`) costs only the dust taker. Midnight rounds a maker sell's assets up, so only an offer priced at zero (tick 0) reaches this case.

### The Maker Exit Leg

A third party taking a resting **sell** offer moves credit out of the proxy's position with none of our transactions in the stack, but `onSell` does reach `fundFill`, so the exit is priced and metered by the facet.

What the facet can check there is narrower than on the taker exit. The callback carries no offer, so size, expiry, window, group and the identity binds are the ratifier's job or nobody's. What the facet does enforce is the realized price against the configured exit floor, the debt post-condition, and the two meters. Two differences from taker `sell` are deliberate:

- there is no `minAssetsOut`, because no caller of ours chooses the size of a maker fill. The configured floor is the whole price defence.
- the floor's fee basis is **the lesser of what the fill reports and what the position still carries**. `onSell` hands over `sellerPendingFeeDecrease`, the lien the fill sheds, and shedding a lien means the proxy gives up less than par, so a larger lien justifies a lower price. That argument only holds for a lien that exists, and the reported number is not evidence of one. The facet therefore reads the position back from the venue and takes the smaller of the two. Overstating the lien is clamped away; understating it only tightens the floor, which is the caller's loss to take.

The pro-rata split makes the venue read exact rather than approximate: Midnight reduces `pendingFee` and `credit` in the same proportion, so the fee per unit remaining after the fill is the fee per unit the fill shed. A **full** exit leaves no ratio to read, and prices as though no lien was shed, which is the strictest basis available. A near-full exit whose carried fee rounds to zero lands on the same basis.

One post-condition is available and is used: `debt(marketId, proxy) == 0`. Upstream's own end-of-take check only requires the seller to be *healthy*, which collateral alone can satisfy, and it is skipped entirely for the inner take of a nested one. The debt check is therefore both stricter and always run: it backs up the ratifier's `reduceOnly` requirement rather than replacing it. Beyond that the facet takes the caller's word for `assets` and `units` and bounds the damage with the meters. The ratifier requires `receiverIfMakerIsSeller == proxy` on every sell offer, so the proceeds cannot be redirected.

### Set Make Config (admin)

Operators and spells call each function through `PAU_CONTROLLER` as `midnight_<name>`.

**Function:** `setMakeConfig(market, maxOfferSize)` (`DEFAULT_ADMIN_ROLE`)

Takes the full `Market` struct, not an id, because `MakeConfig` caches the maturity and loan token the ratifier and `fundFill` price against. Requires `market.midnight == midnight` (`MidnightFacet/invalid-midnight`), the market to be onboarded for taking already (`minSellTick != 0`, `MidnightFacet/market-not-onboarded`), `market.maturity <= type(uint64).max` (`MidnightFacet/maturity-oob`), `maxOfferSize <= type(uint128).max` (`MidnightFacet/max-offer-size-oob`), since Midnight moves at most that much in one fill and a larger cap could never bind, and `toMarket(marketId).maturity == market.maturity` (`MidnightFacet/market-mismatch`), which reverts unless the market exists on the singleton.

`maxOfferSize` is two things. It is the make-enabled flag (`!= 0`) and the per-market kill switch, and it is the cap on the loan token a **single fill** may move, in either direction: `fundFill` refuses `assets > maxOfferSize` (`MidnightFacet/offer-size-too-large`). It is a per-fill cap, not a cap on an offer's total size: an offer can be filled many times, each fill bounded by `maxOfferSize` and all of them together bounded by the strategy and direction keys. Size the keys accordingly. Zeroing it makes `isCallbackAllowed` return false, so the ratifier stops ratifying the market's offers in both directions; a fill that races the change still fails inside `fundFill` with `make-not-enabled`. On this host only the admin can zero it.

`setMakeConfig` reads the venue (`toMarket`) even when it zeroes `maxOfferSize`, so the kill switch depends on that read. This is accepted: the Midnight singleton is immutable and market records are permanent, so the read cannot start failing.

**Event:** `MidnightMakeConfigSet(marketId, loanToken, maturity, maxOfferSize)`

### Set Designated Groups (admin)

**Function:** `setDesignatedGroups(marketId, buyGroup, sellGroup)` (`DEFAULT_ADMIN_ROLE`)

Midnight tracks consumed size per `offer.group`. These two values are the only groups the ratifier will ratify an offer into, and therefore the only groups `cancelOfferGroup` needs to be able to retire. Both groups must be non-zero and distinct (`MidnightFacet/invalid-groups`): zero is the ratifier's "not designated" sentinel, and a shared group would make neither book cancellable on its own. Both zero is the unset default and designates nothing; a zero group is not a wildcard, since the ratifier refuses an undesignated direction outright. A market meant to trade in one direction only gets both groups and leaves the other direction's rate limit keys unset. Reusing a group across markets is an operational rule, not a code check: do not, since cancelling it retires every market's book that names it.

**Event:** `MidnightGroupsSet(marketId, buyGroup, sellGroup)`

### Set Ratifier Authorization (admin)

**Function:** `setRatifierAuthorization(ratifier, authorized)` (`DEFAULT_ADMIN_ROLE`)

`doCall`s `midnight.setIsAuthorized(ratifier, authorized, proxy)`. Only `ratifier != address(0)` is checked (`MidnightFacet/zero-ratifier`); nothing on-chain can usefully constrain what the grantee is. See [Ratifier Authorization Is a Blanket Grant](#ratifier-authorization-is-a-blanket-grant) before using it. `authorized == false` revokes and is the global kill switch: it invalidates every resting offer naming that ratifier in one transaction, across all markets and both directions.

**Exactly one authorized ratifier per proxy.** This is an operating rule, not a code check: the facet accepts any non-zero address. Swapping ratifier logic means deploying a new ratifier and swapping the authorization: grant the new ratifier its roles (quoter, freezer, manager), then authorize it and deauthorize the old one in the same governance action. Offers signed for the old ratifier die with its deauthorization, since the ratifier address is part of the offer.

**Event:** `MidnightRatifierAuthorizationSet(ratifier, authorized)`

### Cancel Offer Group (allocator)

**Function:** `cancelOfferGroup(group)` (`ALLOCATOR_ROLE`)

`doCall`s `midnight.setConsumed(group, type(uint128).max, proxy)`. Midnight rejects any amount below what the group has already consumed, so the call can only retire a group and never reopen one, which is why it sits at allocator level while the setters above are admin-only. Groups are per direction, so entries can be retired while exits stay fillable. Retiring a group is irreversible for that group. A group nothing ever used is retired just the same. A group cancel sets the group's consumed amount to the `uint128` maximum, so afterwards even a zero-unit take of an offer whose `maxUnits` (or `maxAssets`, when set) is below that maximum reverts in Midnight (`ConsumedUnits()` or `ConsumedAssets()`) before any callback. An offer capped at the `uint128` maximum still reaches its callback at zero units, where the dust rule makes it a no-op.

**Event:** `MidnightOfferGroupCancelled(group)`

---

## Rate Limit Keys

| Limit                          | Key tuple                | Helper                   |
| ------------------------------ | ------------------------ | ------------------------ |
| `LIMIT_MIDNIGHT_BUY`           | `(marketId)`             | `makeBytes32Key`         |
| `LIMIT_MIDNIGHT_SELL`          | `(marketId)`             | `makeBytes32Key`         |
| `LIMIT_MIDNIGHT_REDEEM`        | `(marketId)`             | `makeBytes32Key`         |
| `LIMIT_MIDNIGHT_STRATEGY_BUY`  | `(strategy, marketId)`   | `makeAddressBytes32Key`  |
| `LIMIT_MIDNIGHT_STRATEGY_SELL` | `(strategy, marketId)`   | `makeAddressBytes32Key`  |

All five are denominated in the market's loan token. The three market keys are shared by taker and maker traffic: a taker `buy` or `sell` spends only its market key, `redeem` only `LIMIT_MIDNIGHT_REDEEM`, and a maker fill spends exactly two keys, its strategy key for its direction and then the market key for the same direction. The taker limits are sized by what moved, the buy taking the higher of its balance delta and the spend the venue reports; the maker legs are sized by what the strategy reports, which is why both are also price-bounded. Every leg only ever decrements, and only keys of its own direction, so no leg restores another and entry headroom comes back only from the buy keys' own slopes.

That is a deliberate trade for a smaller blast radius. A refilling buy key makes the cumulative entry bound unbounded in the number of round trips, because each exit buys back the room the next entry spends. Without it the bound over any window is the buy key's `maxAmount` plus its slope, independent of how much is rotated, and a compromised strategy fabricating exits cannot manufacture entry room at all. The cost is that a genuine rotation waits on the slope, and that an operator who wants a faster re-entry has to raise the buy limit rather than let the exit fund it.

Splitting sell from redeem lets governance price the two exits differently: redemption is at par and only limited by repayments, while a sell crosses the spread and the settlement fee.

The strategy keys are the strategy whitelist, per market and per direction: a non-zero `maxAmount` onboards the strategy for that market and direction, and zeroing it offboards it. A key for one market cannot fund another, a buy key cannot fund a sell, and two strategies on one market are metered independently, while the market key bounds all of them together alongside taker traffic. A key at `type(uint256).max` is unlimited and still counts as set, see [Keyed Strategies Are Trusted](#keyed-strategies-are-trusted).

---

## Security Considerations

### Immutable Venue

The Midnight singleton is an immutable, non-upgradeable contract with no owner over funds. Its `configurator` can enable LLTV and liquidation-cursor tiers, replace itself, and appoint three roles: a `feeSetter` who can move the settlement and continuous fees of any market within hard-coded ceilings, a `feeClaimer` who withdraws accrued continuous fee out of a market's repayment pool (`claimContinuousFee` decrements `withdrawable`, so it competes with lenders for the same pool `redeem` draws from), and a `tickSpacingSetter` who can only refine a market's tick spacing. None of them can touch positions or move a lender's loan tokens. The facet binds to one singleton at construction, so a repoint requires a new facet deployment and a governance spell.

### Maker Callbacks Run Inside Our Take

An offer may name a `callback` contract with opaque `callbackData`; Midnight calls it inside `take`, after the transfers when the maker sells and before them when the maker buys. The facet cannot vet what it does and does not try to: banning callbacks is not viable because callback-backed offers are how makers source liquidity. Instead the facet relies on three post-conditions that hold for the whole call:

- The controller's reentrancy guard is held for the entire call, so the callback cannot re-enter any facet.
- The approval to Midnight is exactly `maxAssetsIn`, and Midnight only pulls from the proxy on the proxy's own take. A callback that tries to spend the open approval needs the proxy as payer of some other flow, which Midnight refuses (the only address the proxy authorizes is the ratifier, which makes no calls; a proxy maker buy always pays through its keyed callback, whose `fundFill` the held guard blocks; and the proxy is not a repay callback).
- The exact credit-delta, zero-debt and `maxAssetsIn` checks after the take catch any change to the proxy's position or balance that did not come from the requested fill, including a socialized loss landing mid-fill. The mainnet-fork attack tests drive a hostile maker through take, withdraw, authorization and repayment attempts, and slash a third borrower from inside a fill, in both directions.

### Ratifier Data Is Opaque

`ratifierData` is forwarded as-is to the **maker's** ratifier, which decides whether the offer is live. The facet validates outcomes (price bound, direction, id, deltas), not the offer's provenance; an offer that fails ratification reverts inside Midnight. Makers on mainnet point at Morpho's deployed `SetterRatifier` (`0xb72c416382c8A6399D0765CebfB032F040B00B3c`), which treats `ratifierData` as a Merkle proof of the offer against the maker's committed root; the mainnet-fork tests ratify through that contract rather than a test double.

### Self-Paying Offers

If a sell offer named the ALMProxy as `receiverIfMakerIsSeller`, the proxy would pay the maker's proceeds to itself, netting the balance delta to the fee alone. The metered spend would not follow the delta down, since the take still reports the gross, but the facet rejects such offers outright (`MidnightFacet/invalid-offer-receiver`). On the sell side the proxy is the seller and always names itself as receiver.

### Socialized Loss Is a Ratchet

`lossFactor` only ever increases. A buy into a market that has already been slashed buys in at the written-down value, so `maxLossFactor` gates entry and defaults to zero. It never gates exit: after a slash the live credit is lower, the sell cap follows it, and redemption returns what is left. A market whose `lossFactor` saturates at `type(uint128).max` makes `take` revert for everyone; that is a monitoring concern, not one the facet can act on.

### Mutable Reads Feed Guards, Not Keys

`continuousFee`, `lossFactor`, `settlementFee`, `updatePositionView`, `withdrawable` and `toMarket` are all read from the singleton at call time and can change between calls. Each one feeds a guard that fails closed (a tighter bound, a smaller cap, a revert), and none of them is used to derive a rate-limit key. The only key salt is the governance-supplied `marketId`. The facet reads no oracle: Midnight's collateral oracles are a protocol-side solvency assumption, not a pricing input here. Loan tokens are standard non-rebasing ERC-20s (USDC and USDS, 6 and 18 decimals), so a measured balance delta is exact.

### Measured Deltas and the Venue's Figure

All three operations size their rate-limit accounting from observed balance changes on the ALMProxy rather than from the caller's arguments, and the two take paths additionally reconcile the credit delta against the units requested.

On the buy the delta alone is not enough. Anything that moves loan token into the proxy while the take is in flight, a maker callback or a bridge delivery bundled ahead of it, shrinks the delta and would under-charge `LIMIT_MIDNIGHT_BUY` by that amount, since the approval is cleared and the fill still settles. The buy therefore charges the higher of the delta and the `buyerAssets` the take returns: an inbound transfer can no longer hide part of the spend, and a venue that over-reported would only over-charge our own meter. The exits need no such reconciliation, because an inbound transfer inflates a measured receipt, which over-charges the exit key, and the credit delta still has to match the units sold.

### No Standing Approvals

The buy approval is set to `maxAssetsIn` and reset to zero after the take. Outside a `buy` transaction Midnight holds no allowance on ALMProxy funds. `sell`, `redeem` and `fundFill` grant no approval from the proxy at all, and maker mode adds no standing grant from the proxy to the singleton.

The funding strategy does approve the singleton, but it holds no proxy funds between settlements: `onBuy` sets the allowance with `forceApprove` to exactly the amount Midnight is about to pull, and the pull consumes it inside the same `take`. A disagreement between what `fundFill` sent and what the singleton pulls leaves the pull unfunded and reverts the whole settlement, so nothing accumulates. `rescue` is permissionless and sends any stray balance to the proxy.

### Ratifier Authorization Is a Blanket Grant

Midnight gates maker fills on `isAuthorized[maker][ratifier]`, and that is one flat mapping: the same entry also authorizes `withdraw`, `repay`, `supplyCollateral`, `withdrawCollateral`, `setConsumed` and `setIsAuthorized` on the proxy's behalf. (`borrow` and `liquidate` are not on that list.) Authorizing a ratifier therefore hands it the proxy's whole position on the venue, not just the right to answer ratification questions. There is no narrower grant to ask for.

The containment is that the authorized contract must be *incapable* of using the grant: non-upgradeable, with no constructor or admin path that can reach the singleton, and with a deployed runtime containing no `CALL`, `CALLCODE`, `DELEGATECALL`, `CREATE`, `CREATE2` or `SELFDESTRUCT` opcode at all. That is the property to scan for, and it is weaker than "every function is `view`": the deployed ratifier does hold mutable role state, so it can grant and revoke its own quoter, but a contract that cannot emit a call cannot touch the position the grant covers.

**That containment is not verified in this repository, and cannot be.** The ratifier ships from the periphery repository, which is where the opcode scan over its deployed runtime belongs. This repo's fork suite ratifies through Morpho's own deployed `SetterRatifier`, so there is no test double here to scan, and scanning that address would in any case prove nothing about the contract a spell will actually authorize. Two things here are unaffected: the facet's own call surface is still scanned for the forbidden selectors with `take` as a positive control, and the fork suite still asserts that `isAuthorized[proxy][x]` holds for exactly one address. The scan over the real ratifier's bytecode is therefore a **deployment precondition** on the authorizing spell, not an assertion this suite can make. Nothing but a reviewed, immutable, scanned contract should ever be passed to `setRatifierAuthorization`.

### Maker Exits Run in a Stranger's Transaction

`onSell` reaches `fundFill`, so a maker exit is priced and metered like any other leg. What it cannot have is a caller of ours: the settlement is a third party's transaction, so a revert inside `fundFill` fails *their* take, not anything of ours. That makes the sell keys a liveness surface as well as a loss bound, and it is why `cancelOfferGroup` is the lever to reach for when the exit budget is nearly spent rather than letting a resting offer start failing. The facet still cannot re-derive the credit delta, since the callback carries no offer, so the price floor, the strategy and market sell keys and the zero-debt post-condition are what bound the fill.

### Keyed Strategies Are Trusted

A keyed strategy can call `fundFill` with no fill behind it, and that call involves no offer, no group, no ratifier and no `take`, so neither `cancelOfferGroup` nor the ratifier's `freeze()` can touch it. The entry branch pays `msg.sender`, and the price bound only ties `assets` to `units`, which the caller chooses, so what bounds a fabricated entry is the strategy's remaining buy key and the market's buy key, not the price. A fabricated exit pays nothing and restores nothing, so it cannot reopen entry room; it only burns the sell budgets. Cumulative exposure is therefore the lesser of the two buy keys' remaining capacity plus whatever their slopes refill before the strategy is offboarded, with each call capped by `maxOfferSize`. Zeroing a strategy's keys stops that strategy and leaves the rest of the market trading. Zeroing `maxOfferSize` (`setMakeConfig(market, 0)`) stops every strategy on that market, fabricated calls included, because make-enabled is the first check `fundFill` makes. This is why every strategy has to meet the [conformance rules](#strategy-conformance-rules) and be reviewed before it is keyed.

A strategy key set to `type(uint256).max` is unlimited, the `RateLimits` special case: it is never debited, and it still counts as set, so the strategy is onboarded and `isCallbackAllowed` holds. This is intended configuration that governance may choose deliberately. Such a strategy is then bounded per fill by `maxOfferSize` and cumulatively by the market key for the direction alone.

The market **buy** key is kept finite; that is the intended configuration. Unlimited keys stay technically possible, but unlimited buy keys plus a faulty strategy expose the proxy's whole loan-token balance.

Offers naming an offboarded strategy stay published and signed. They are not recalled; the ratifier stops ratifying them once the key is zero, so their fills revert before reaching the facet.

### Nested Controller Entry

A taker could try to reach the controller from inside a maker fill: take a resting offer, and from the callback call back into `buy` or `fundFill`. Two independent layers refuse it. `fundFill` is `nonReentrant`, so the second entry reverts on the guard; and the facet's exact credit reconciliation (`MidnightFacet/credit-delta-mismatch`) rejects any credit change that lands inside a fill, whatever moved it. The fork suite asserts both separately: the nested-entry test shows the inner call reverting on the guard, with the buy meter debited by the outer fill alone and credit and `consumed` matching it, and the write-down-mid-fill tests show the reconciliation catching a credit change made from a callback.

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
| `MidnightFacet/invalid-midnight`         | facet       | `offer.market.midnight` is not the configured singleton                                   |
| `MidnightFacet/market-mismatch`          | facet       | the offer's market does not hash to `marketId`                                             |
| `MidnightFacet/invalid-offer-direction`  | facet       | a buy offer passed to `buy`, or a sell offer passed to `sell`                             |
| `MidnightFacet/zero-units`               | facet       | a zero size, or a `redeem` that caps to nothing                                           |
| `MidnightFacet/no-credit-to-sell`        | facet       | `sell` against a position with no live credit left                                        |
| `MidnightFacet/continuous-fee-too-high`  | facet       | `buy` while the market's continuous fee exceeds `maxContinuousFee`                        |
| `MidnightFacet/loss-factor-too-high`     | facet       | `buy` while the market's loss factor exceeds `maxLossFactor`                              |
| `MidnightFacet/buy-price-too-high`       | facet       | an offer whose price plus the settlement fee exceeds `tickToPrice(maxBuyTick)`            |
| `MidnightFacet/sell-price-too-low`       | facet       | an offer whose price is under `tickToPrice(minSellTick)` plus the settlement fee          |
| `MidnightFacet/buy-yield-too-low`        | facet       | an all-in offer price whose implied yield is under `minBuyYield` for the remaining term   |
| `MidnightFacet/sell-yield-too-high`      | facet       | an offer whose net proceeds give up more than `maxSellYield` for the remaining term       |
| `MidnightFacet/invalid-offer-receiver`   | facet       | a sell offer paying its proceeds to the ALMProxy                                          |
| `MidnightFacet/max-assets-in-exceeded`   | facet       | metered spend above `maxAssetsIn`                                                         |
| `MidnightFacet/min-assets-out-not-met`   | facet       | measured proceeds below `minAssetsOut`                                                    |
| `MidnightFacet/credit-delta-mismatch`    | facet       | live credit did not move by exactly the units taken                                       |
| `MidnightFacet/debt-not-zero`            | facet       | the venue reports debt against the ALMProxy after a trade                                 |
| `MidnightFacet/max-buy-tick-oob`         | facet       | `setMarketConfig` with `maxBuyTick > 6744`                                                |
| `MidnightFacet/min-sell-tick-oob`        | facet       | `setMarketConfig` with `minSellTick` zero or `> 6744`                                     |
| `MidnightFacet/max-continuous-fee-oob`   | facet       | `setMarketConfig` with `maxContinuousFee` above Midnight's ceiling                        |
| `MidnightFacet/max-sell-yield-not-set`   | facet       | `setMarketConfig` with a zero `maxSellYield`                                               |
| `MidnightTickLib/tick-out-of-range`      | facet       | an offer tick above `6744`                                                                |
| `MidnightFacet/zero-midnight`            | facet       | constructor with a zero singleton address                                                 |
| `MidnightFacet/invalid-groups`           | facet       | `setDesignatedGroups` with a zero group or one group used for both directions             |
| `MidnightFacet/maturity-oob`             | facet       | `setMakeConfig` with a maturity above `type(uint64).max`                                  |
| `MidnightFacet/max-offer-size-oob`       | facet       | `setMakeConfig` with a cap above `type(uint128).max`                                      |
| `MidnightFacet/zero-ratifier`            | facet       | `setRatifierAuthorization` with a zero address                                            |
| `MidnightFacet/make-not-enabled`         | facet       | `fundFill` on a market whose `maxOfferSize` is zero                                       |
| `MidnightFacet/offer-size-too-large`     | facet       | `fundFill` moving more than the market's `maxOfferSize` in one fill                       |
| `MidnightFacet/zero-assets`              | facet       | `fundFill` with zero assets, including a sell whose assets round to zero                  |
| `MidnightFacet/fill-price-too-high`      | facet       | `fundFill` paying above the lesser of the tick and capped-fee yield bounds                 |
| `MidnightFacet/fill-price-too-low`       | facet       | `fundFill` on an exit realizing below the greater of the tick and yield floors             |
| `RateLimits/rate-limit-exceeded`         | rate limits | trade exceeding the configured limit                                                      |
| `RateLimits/zero-maxAmount`              | rate limits | key unconfigured                                                                          |
| `MarketNotCreated()`                     | Midnight    | market never touched on the singleton                                                     |
| `RatifierUnauthorized()`                 | Midnight    | maker has not authorized its ratifier                                                     |
| `NotRatified()`                          | ratifier    | the maker's `SetterRatifier` does not recognize the offer (bubbles through Midnight)      |
| `InvalidProof()`                         | ratifier    | the `ratifierData` Merkle proof does not place the offer under the maker's root           |
| `ConsumedUnits()`, `ConsumedAssets()`    | Midnight    | offer already filled past its cap, including by someone else in the same block            |
| `OfferExpired()`, `OfferNotStarted()`    | Midnight    | offer outside its validity window                                                         |
| `CannotIncreaseDebtPostMaturity()`       | Midnight    | `buy` after maturity from a maker that would have to incur debt to fill it                |
| `SellerIsLiquidatable()`                 | Midnight    | the maker selling to us would be left unhealthy                                           |
| `MarketLossFactorMaxedOut()`             | Midnight    | market has lost everything; no takes are possible                                         |

### Maker Mode

Every revert below refuses a fill against one of the proxy's own resting offers. The taker sees it bubble out of `midnight.take`.

Reverts raised by the ratifier and the funding strategy are theirs to document, since neither ships from here. The policy the ratifier has to refuse on is the numbered list under [What an Acceptable Ratifier Must Enforce](#what-an-acceptable-ratifier-must-enforce); everything else is in the table below.

| Revert                                        | Origin   | Cause                                                                              |
| --------------------------------------------- | -------- | ---------------------------------------------------------------------------------- |
| `RateLimits/zero-maxAmount`                  | rate limits | `fundFill` from a strategy with no key for that market and direction        |
| `MidnightFacet/make-not-enabled`              | facet    | `fundFill` on a market whose `maxOfferSize` is zero                                |
| `MidnightFacet/offer-size-too-large`          | facet    | `fundFill` moving more than the market's `maxOfferSize` in one fill                |
| `MidnightFacet/transfer-failed`               | facet    | `fundFill` entry whose loan token transfer returned `false` or malformed data       |
| `MidnightFacet/fill-price-too-high`           | facet    | `fundFill` above the configured entry bound, fee priced at the cap                 |
| `MidnightFacet/fill-price-too-low`            | facet    | `fundFill` below the configured exit floor, on the clamped fee basis                |
| `MidnightFacet/loss-factor-too-high`          | facet    | `fundFill` entry on a market whose lenders have already been slashed               |
| `MidnightFacet/continuous-fee-too-high`       | facet    | `fundFill` entry while the live fee exceeds the configured ceiling                 |
| `MidnightFacet/debt-not-zero`                 | facet    | `fundFill` exit leaving the proxy's position holding debt                          |
| `RatifierFailed()`                            | Midnight | the ratifier returned anything other than the success value                        |
| `ConsumedUnits()`, `ConsumedAssets()`         | Midnight | the designated group is exhausted, including by `cancelOfferGroup`                 |
| `UnusedReceiverMustBeZero()`                  | Midnight | a buy offer naming a receiver, refused before ratification runs                    |
| `RatifierUnauthorized()`                      | Midnight | the ratifier's authorization was revoked                                           |
| `RatifierFrozen()`                            | ratifier | the ratifier has been frozen                                                       |

---

## Operational Requirements

### Configuration (before first trade)

Per market (`marketId`):

1. Confirm the market exists on the singleton (`toMarket(marketId)` resolves, `settlementFee` does not revert). If not, anyone can `touchMarket(market)` once; the facet does not.
2. Review the market config the id commits to: loan token, maturity, collateral tiers (LLTV, liquidation cursor, oracle), `rcfThreshold`, gates. A tier at LLTV `1e18` lets a borrower sell against the full collateral value, so any adverse oracle move leaves bad debt for lenders; treat it as a due-diligence red flag.
3. `setMarketConfig(marketId, ...)`: required, and every limit is passed in the one call. `minSellTick` non-zero and below par net of the settlement fee; `maxBuyTick` at the highest all-in price acceptable for the remaining term; `minBuyYield` at the lowest rate worth entering for and `maxSellYield` (non-zero) at the widest give-up an exit may pay, both in basis points a year; `maxContinuousFee` (centi-basis points a year) and `maxLossFactor` at the tolerances the position can absorb, both defaulting to zero.
4. Configure `LIMIT_MIDNIGHT_BUY`, `LIMIT_MIDNIGHT_SELL` and `LIMIT_MIDNIGHT_REDEEM` keyed `marketId`, in the loan token's units. The strategy keys are maker-only and come with step 8 below. The exits are gated only by their own keys; zeroing the buy key pauses entry without touching exits. Size the buy key's slope to the pace of entry the market should sustain, not to the size of the position: no exit refills it, so rotating out and straight back in waits on that slope.

No seeding is required: the integration holds no intermediate token and uses no auxiliary module. Offers are sourced off-chain from makers (or the Morpho API) and passed in calldata by the allocator together with each maker's ratifier data.

### Enabling maker mode on a market

Steps 1 to 4 above are prerequisites, the rate limits included: a maker entry debits the buy key and a maker exit the sell key, and an unset key reverts with `RateLimits/zero-maxAmount` rather than passing. Maker mode is off until all of the following are done, and each one on its own is a kill switch.

5. Deploy the ratifier and the funding strategy from the periphery repository. Both are immutable; rotating either means a new deployment and a spell. Before authorizing anything: review the deployed bytecode against the audited source, confirm the ratifier enforces the full numbered list above, check the strategy against the [conformance rules](#strategy-conformance-rules), and run the opcode scan over the ratifier's runtime, which this repository cannot do for you.
6. `setMakeConfig(market, maxOfferSize)` on an already-onboarded market, passing the full `Market` struct. `maxOfferSize` caps each fill, not each offer.
7. `setDesignatedGroups(marketId, buyGroup, sellGroup)` with two distinct non-zero groups. These are the only groups `cancelOfferGroup` can retire, so publish offers into nothing else, and never reuse a group on another market, since cancelling it would retire both books. A market meant to trade in one direction only still gets both groups; the other direction is closed by leaving its keys unset in step 8.
8. Set `LIMIT_MIDNIGHT_STRATEGY_BUY` and `LIMIT_MIDNIGHT_STRATEGY_SELL` keyed `(strategy, marketId)` for each funding strategy the market's offers may name and each direction it should serve. The keys are the authorization, so onboarding a strategy and sizing it are one step. Size the market keys from step 4 with maker flow in mind as well: maker fills share them with taker traffic, and exhausting any key on a fill's path reverts the taker's fill rather than ours. Keep the market buy key finite, see [Keyed Strategies Are Trusted](#keyed-strategies-are-trusted).
9. `setRatifierAuthorization(ratifier, true)` **last**, once everything above is in place and verified. This is the blanket grant described above, and it is what makes resting offers fillable at all. It must be the only ratifier authorized for the proxy, see [Set Ratifier Authorization](#set-ratifier-authorization-admin).
10. Grant the ratifier's quoter role (`grantRole(QUOTER_ROLE, key)`, held by its `MANAGER_ROLE`) to the signing key that will publish offers, and its `FREEZER_ROLE` to the incident key. The quoter role is checked at ratification, not at signing, so revoking it invalidates every offer the old key signed, in one transaction and with no redeployment.

A strategy that sources liquidity inside `onBuy` also needs `ALLOCATOR_ROLE` granted to it in `AccessControls` by the allocator role admin, which also revokes it. That admin is whichever role `setRoleAdmin` names (`ALLOCATOR_ADMIN_ROLE` in the reference deployment), and `DEFAULT_ADMIN_ROLE` can always reassign it. The strategy also needs the rate-limit keys of every venue its sourcing sequence touches. Nothing else is required: no facet change and no controller change.

Verify the intended `maxBuyTick` against `maxBuyPrice(minBuyYield, timeToMaturity, continuousFeePerSecond(maxContinuousFee))` before publishing, not against the live fee: maker entry is bounded by the capped-fee ceiling, which at a 180 day term with the 1%/year cap sits about 48 basis points below the live-fee ceiling taker entry uses.

**Revoking, fastest first.** Operators and spells call each function through `PAU_CONTROLLER` as `midnight_<name>`. The ratifier's `freeze()`, `unfreeze()`, `removeQuoter` and `blockOffer` are called on the ratifier itself, `removeIntegrations` on `PAU_CONTROLLER` under its own name, and the role revokes on `RateLimits`, the ALMProxy and `AccessControls`. Every lever here acts on offers already signed and published, which cannot be recalled from the venue. The facet has no freezer of its own: the ratifier's `freeze()` is the maker kill switch, and the first four rows avoid a spell.

| Lever                                                     | Scope                                                                         | Role                 |
| --------------------------------------------------------- | ----------------------------------------------------------------------------- | -------------------- |
| ratifier `freeze()`                                       | every market, both directions, until the ratifier admin calls `unfreeze()`    | ratifier freezer     |
| ratifier `removeQuoter(key)`                              | every offer that key signed                                                   | ratifier freezer     |
| ratifier `blockOffer(offerDigest)`                        | one signed offer, until the freezer or admin unblocks it                      | ratifier freezer     |
| `cancelOfferGroup(group)`                                 | one direction on one market, irreversible for that group                      | allocator            |
| zero a strategy's `LIMIT_MIDNIGHT_STRATEGY_*` key         | one strategy on one market and direction, fabricated `fundFill` calls included | rate limits admin    |
| `setMakeConfig(market, 0)`                                | one market, both directions, fabricated `fundFill` calls included             | admin                |
| `setRatifierAuthorization(ratifier, false)`               | every market, both directions, one transaction                                | admin                |
| `controller.removeIntegrations(["MIDNIGHT_FACET"])`       | every Midnight function at once, `fundFill` included, so maker exits stop too | admin                |
| revoke the controller's `CONTROLLER` role on `RateLimits` | every metered path in the system, maker exits included                        | limits admin         |
| revoke the controller's `CONTROLLER` role on the ALMProxy | maker buys, fabricated ones included, not maker sells; see Proxy freeze below | proxy admin          |

Two more admin levers exist and are dominated by the rows above. Zeroing a market key stops one direction on that market, fabricated `fundFill` calls included, and also stops taker traffic on that side, which is a blunter instrument than zeroing the strategy key. Tightening `setMarketConfig` refuses the fill inside `fundFill` after ratification has already passed, so it reverts a stranger's transaction instead of stopping the book; treat it as configuration, not as an incident response.

**Ratifier freeze.** The ratifier's `freeze()`, held by its `FREEZER_ROLE`, is the maker kill switch on both hosts: it stops new ratified maker fills in both directions, and only the ratifier admin can `unfreeze()`. Each host and chain has its own ratifier deployment, bound to one proxy and one controller, and `freeze()` stops only the ratifier it is called on. Exactly one ratifier is authorized per proxy (see [Set Ratifier Authorization](#set-ratifier-authorization-admin)), so one `freeze()` covers the proxy's book. A freeze does not stop a keyed strategy calling `fundFill` directly. Zeroing that strategy's keys stops it, zeroing `maxOfferSize` stops every strategy on the market, and `removeIntegrations` or the `RateLimits` revoke stops all of them.

**Proxy freeze.** The deployment runs on the standard `ALMProxy` (`PAU_PROXY`, with `PAU_CONTROLLER` holding its `CONTROLLER` role), not on `ALMProxyFreezable`, so the proxy has no freezer of its own. A proxy freeze is the proxy admin revoking the controller's `CONTROLLER` role, a governance action. It stops maker buys, fabricated `fundFill` buys included, because the entry transfer is a proxy call, but not maker sells, because the exit branch of `fundFill` makes no proxy call and Midnight pays the proxy directly. It also blocks `cancelOfferGroup` and `setRatifierAuthorization`, which reach the venue through `IALMProxy.doCall`.

**Runbook.**

1. Freeze every ratifier authorized for the affected proxy; under the one-ratifier rule that is a single `freeze()`.
2. Before any proxy freeze, the admin zeroes `maxOfferSize` (`setMakeConfig(market, 0)`) or deauthorizes the ratifier (`setRatifierAuthorization(ratifier, false)`), and an allocator calls `cancelOfferGroup` on the designated groups, because a proxy freeze leaves maker sells live and blocks both of those calls. `removeIntegrations` unwires them outright.
3. Governance zeroes the strategy keys, and the allocator role admin revokes any operator role a strategy holds.

Freezing the ratifier and zeroing a strategy key touch neither the proxy nor the facet, so both still work after a proxy freeze.

**Strategy compromised.** The ratifier freeze does not stop a keyed strategy calling `fundFill` with no fill behind it, and no fast role on this host reaches that call.

- For an operator-role strategy, the `ALLOCATOR_ROLE` admin revokes its role through `AccessControls`. That ends its allocator surface, every venue key the role can spend, but not its `fundFill` calls, which carry no role gate.
- For any strategy, roleless ones included, only the admin can stop the fabricated calls: the rate limits admin zeroes its strategy keys, or the controller admin zeroes `maxOfferSize` on every market it is keyed for. For a roleless strategy these are the only levers.

This is a known slow path. Until the admin action lands, fabricated buys draw down the lesser of the strategy's and the market's remaining buy keys plus their slopes, at most `maxOfferSize` per call, which is why the market buy key is kept finite. A proxy freeze also stops fabricated buys, but it is a governance action as well and comes after runbook step 2.

**Every lever announces itself.** A compromised strategy watching the mempool can draw whatever budget is left in front of an offboarding transaction, so send it through a private relay.

### Divergences from the ALM Controller

The periphery serves this facet and the ALM controller with the same ratifier and strategy contracts, deployed once per host, through `midnight_fundFill`, `midnight_isCallbackAllowed` and `midnight_getDesignatedGroups`, whose selectors and semantics are identical on both hosts. The rest differs by design:

- **Roles.** Admin maps to `DEFAULT_ADMIN_ROLE`, the ALM `RELAYER` to `ALLOCATOR_ROLE` in `AccessControls`. The ALM `FREEZER` has no equivalent here, so per-market `maxOfferSize` zeroing is admin-only on the diamond while the ALM lets its freezer do it; the ratifier's `freeze()` is the fast stop on both. A compromised strategy's fabricated `fundFill` calls are therefore stopped by the freezer on the ALM and only by governance here, see Strategy compromised under [Revoking](#enabling-maker-mode-on-a-market).
- **Group cancels.** `cancelOfferGroup` is `ALLOCATOR_ROLE` only. The ALM's `cancelMidnightOfferGroup` is open to its `RELAYER` and its `FREEZER`, so there the freezer can retire a book, and here only an allocator can.
- **Operator roles.** A phase 3 strategy's `ALLOCATOR_ROLE` is granted and revoked by the allocator role admin in `AccessControls`, a different authority from the governance that sets its keys. On the ALM the admin grants `RELAYER`, and the freezer can also `removeRelayer`.
- **Make config.** `setMakeConfig` takes the full `Market` struct here and a `marketId` on the ALM. The cached maturity is a `uint64` here and a `uint48` on the ALM; Midnight caps maturity at 100 years, so neither width binds.
- **Key getters.** `getStrategyBuyRateLimitKey` and `getStrategySellRateLimitKey` exist only here. The ALM exposes the ids as `MidnightLib` constants; the key encodings are identical on both hosts.
- **Error prefixes.** Facet errors are `MidnightFacet/...` here and `MidnightLib/...` or `FC/...` on the ALM. The suffixes match for every maker check, except the zero ratifier (`MidnightFacet/zero-ratifier` vs `FC/ratifier-zero-address`) and the transfer (`MidnightFacet/transfer-failed` vs `ERC20Lib/transfer-failed`). An unset key reverts `RateLimits/zero-maxAmount` on both.
- **Transfer return data.** The entry transfer here accepts empty return data or exactly 32 bytes encoding `true`. The ALM's `ERC20Lib.transfer` decodes the first word of any return of 32 bytes or more. The two differ only for a non-standard token returning more than 32 bytes, which the ALM accepts and this host rejects.
- **Setter guards and events.** The Midnight config setters are `nonReentrant` here and not on the ALM; both are admin-only. Taker legs emit `MidnightBuy`, `MidnightSell` and `MidnightRedeem` here and no event on the ALM. The maker events are identical.
- **Full exit with an oversized fee.** This host computes `pendingFee * WAD / units` before the full-exit short-circuit, so a full exit reporting a `pendingFee` above about `1.16e59` reverts on overflow here and passes on the ALM. It is unreachable in practice: Midnight's fee is a `uint128`, and a conforming strategy forwards it unchanged.
- **USDS mint.** Available as a sourcing venue here only, see [Strategy Conformance Rules](#strategy-conformance-rules).
- **Naming.** Every Midnight function is wired on the controller with the `midnight_` prefix, as for every other facet. The ALM controller carries the prefix only on the three periphery-facing functions.

### Liquidity

The facet makes no liquidity claims. At the time of writing every live mainnet market carries dust-sized depth and is unlisted; the counterparty for any meaningful size is a maker publishing offers against the position, not standing on-chain liquidity. Position sizing has to assume the exit is a maker's buy offer or the repayment pool, whichever comes first.

### Monitoring

- **`lossFactor` per market**: any increase means a liquidation socialized bad debt against the position. Entry is gated by `maxLossFactor`; the write-down on the existing position is immediate and unrecoverable.
- **Fee changes** (`continuousFee`, settlement fee schedule): raised fees widen the spread on every trade and can lift every offer's all-in cost over `maxBuyTick` (`MidnightFacet/buy-price-too-high`) or push the `minSellTick` floor over par, wedging that side until governance reconfigures. Both fees sit inside the yield bounds, so a fee rise re-prices those rather than leaving them stale, with one exception: close to maturity the sell floor is already near par, and adding the fee on top can push it above par, so `sell` reverts (`MidnightFacet/sell-yield-too-high`) until the fee falls or governance widens `maxSellYield`. With the schedule at the protocol ceiling that window is roughly the last hour at a `maxSellYield` of `10_00` and the last six at `2_00`, and it scales with the fee: a 50 bp fee landing in the shortest bucket would widen it to 18 and 92 days respectively. Past maturity the floor is exactly par, so any live settlement fee closes the sell path and `redeem` is the only exit, which costs nothing because a post-maturity sell can never beat redemption anyway (see `sell` above). At the time of writing every fee on every live market is zero and no `feeSetter` has been appointed, so the whole schedule can go from zero to the protocol ceilings on one configurator action with no notice.
- **Role and tier changes** by the singleton's `configurator` (`feeSetter`, `feeClaimer`, `tickSpacingSetter`, tiers, the configurator itself): the privileged levers on the venue. Fee claims reduce `withdrawable`, so they show up as slower redemption.
- **`withdrawable` vs. credit** around maturity: redemption is first come first served out of repayments. Slow repayment after maturity means slow redemption, not loss, unless liquidations fall short.
- **Time to maturity per market**: the yield bounds tighten towards par on their own, but they stop binding at maturity. With no term left the buy ceiling is par whatever `minBuyYield` says, so `maxBuyTick` is the only value still pricing an entry (see `buy` above); a market being wound down wants it zeroed rather than left at the level that opened the term.
- **Oracle health** of every collateral tier in the market: a stale or manipulated oracle is what turns a borrower's default into a lender's loss.
- **Maker concentration**: the position's exit before maturity depends on makers willing to buy. A single maker on both sides of the book is a liquidity risk, not a solvency one.
- **Buy key headroom per market**: entry draws it down and nothing but its own slope puts it back, so a market that is rotated frequently will run out of entry room while both exits stay open. That is the intended failure direction, but it is a liveness event worth seeing before the allocator does.

When maker mode is enabled, additionally:

- **`isAuthorized[proxy][x]` on the singleton**: must hold for the ratifier and no other address. Any other entry is a blanket grant over the proxy's position. Alert on the `SetIsAuthorized` event with `onBehalf` equal to the proxy rather than only sampling the mapping: the grant permits `setIsAuthorized`, so an authorized contract can add an entry of its own, and revoking the ratifier does not clear it.
- **The quoter key's custody**: it is the only thing that can create a fillable offer. Revoking its role on the ratifier is the fastest way to void everything signed so far, since the role is checked at ratification rather than at signing.
- **Published offers** against the designated groups' consumed counters, which is what bounds how much of a signed offer can still be filled, and against `maxOfferSize` as an off-chain check, since on chain it only caps each fill, never an offer's total size.
- **Buy and sell key drawdown**, market and strategy keys alike, as the maker turnover rate, since maker flow shares the market keys with taker traffic and no leg on either side restores anything. A market whose key for a direction is near zero has a book that will start reverting takers' fills on that side; retire the groups rather than leaving it there.

## Related Documentation

- [ARCHITECTURE.md](./ARCHITECTURE.md): overall facet architecture and Controller dispatch.
- [RATE_LIMITS.md](./RATE_LIMITS.md): rate-limit key construction, try-increase and gate-check patterns.
- [SECURITY.md](./SECURITY.md): venue trust assumptions and the external protocol's audit status.
- [THREAT_MODEL.md](./THREAT_MODEL.md): protocol trust matrix and external risk surface.
