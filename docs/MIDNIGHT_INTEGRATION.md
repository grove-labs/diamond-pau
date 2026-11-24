# Morpho Midnight Integration

This document describes the Morpho Midnight integration with the PAU system. It covers the `MidnightFacet`, the fixed-term credit markets it trades on, how a taker-only lending position is entered, exited and rate-limited, and the per-market price, fee and loss controls that govern entry.

Protocol behavior described here was checked against the Morpho Midnight codebase at commit `70607569ac348e9880b512ffd3b574be55405932` (`main`, 2026-09), which is the code deployed as the mainnet singleton `0x471686c42792F93528B000beF54bC10E3aa2045f` (identical bytecode on Base at `0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A`).

## Overview

Midnight is a **singleton, fixed-term, fixed-rate credit market**. A market is a `Market` struct (loan token, maturity, collateral tiers with oracle and LLTV, optional gates) and is identified by its `id`: the full 32-byte CREATE2 hash `keccak256(0xff ‖ market.midnight ‖ 0 ‖ keccak256(SSTORE2_PREFIX ‖ abi.encode(market)))`, whose low 20 bytes are the address the singleton stores the encoded config at. `MidnightIdLib.toId` computes it; an address-derivation helper would return only the truncated 20 bytes and never match. Inside a market every position is denominated in **units**: one unit is a claim on one loan token at maturity.

- A **borrower** supplies collateral and **sells** units: it receives the discounted price now and owes one loan token per unit at maturity (debt).
- A **lender** **buys** units at a discount and holds credit. At or after maturity, once borrowers have repaid, credit is **redeemed** at par.
- Trades are maker **offers** taken on-chain. A maker publishes an `Offer` (direction, tick, size, expiry, ratifier, optional callback) off-chain and a taker calls `take` with it. The maker's **ratifier** contract decides whether an offer is live; the singleton stores no order book.
- Price is a **tick**: `tickToPrice(tick)` maps `0..6744` onto a rising logistic curve rounded to `1e-7` WAD, with `3372` at exactly `0.5e18`. A tick of `4152` is roughly `0.98`, `4384` roughly `0.99`, and `6744` par.
- Fees: a **settlement fee** (per-market, resolved from a piecewise schedule over time to maturity) widens the spread on every take, and a **continuous fee** (per second, WAD) is crystallized on the buyer over the remaining term when credit is created.
- Loss: when a liquidation cannot cover a borrower's debt, the shortfall is **socialized** across all lenders in the market through a monotone `lossFactor` ratchet.

The `MidnightFacet` is a **taker-only, lender-only** integration: the ALMProxy buys units from makers' sell offers, sells them back into makers' buy offers before maturity, and redeems them at par once repayments land. It never makes offers, never supplies collateral, never borrows, never liquidates, and never holds debt. Every external call is pinned to a single immutable Midnight singleton.

Structs and the tick and id math are vendored verbatim, one file per upstream source: `MidnightInterfaces.sol` from `src/interfaces/IMidnight.sol`, `MidnightTickLib.sol` from `src/libraries/TickLib.sol`, and `MidnightIdLib.sol` from `src/libraries/IdLib.sol`, each naming its upstream file and the pinned commit in a header. They are vendored because the market id is a hash over the struct layout: any drift would silently change every id. The protocol repo is not importable as a Foundry library and only these few definitions are needed, so there is no `lib/` submodule, and the vendored `unchecked` blocks are kept exactly as upstream wrote them for the same parity reason. `MidnightUtils.sol` holds the facet's own yield math, which has no upstream counterpart, alongside a mirror of Midnight's continuous-fee ceiling. The mainnet-fork suite pins parity by recomputing three live market ids.

## Token Flow

```
Buy:     loanToken (ALMProxy) → transfer maxAssetsIn → take buffer ─┐
                                                                    ├→ midnight.take(sell offer), buffer as taker callback
         maker receives price, fee stays in venue ──────────────────┘
         take buffer → transferFrom whole balance → ALMProxy
         credit += units (position storage, no receipt token)

Sell:    midnight.take(buy offer) → loanToken (take buffer), net of settlement fee
         take buffer → transferFrom whole balance → ALMProxy
         credit -= units

Redeem:  midnight.withdraw(units) → loanToken (take buffer), at par
         take buffer → transferFrom whole balance → ALMProxy
         credit -= units
```

Only one path moves loan tokens out of the ALMProxy: `buy`, which moves `maxAssetsIn` to the take buffer, lets the `take` pull the offer price for the maker's `receiverIfMakerIsSeller` (never the proxy) and the settlement fee for the venue out of the buffer, and pulls whatever the buffer still holds back to the proxy. It is bounded by `maxAssetsIn` and metered against `LIMIT_MIDNIGHT_BUY`. `sell` and `redeem` only move loan tokens in, through the take buffer and on to the proxy in the same call. Credit is not a token and cannot leave the proxy's position except through those two paths.

### Take Buffer

The take buffer is a `MidnightTakeBufferStrategy` contract bound at deployment to the ALMProxy and the Midnight singleton. Every `buy`, `sell` and `redeem` routes the loan token through it, and the facet sizes each leg by the buffer's balance delta rather than the proxy's. The proxy itself never approves Midnight.

- Midnight's `take` has no payer parameter: on a take buy it pulls the payment from the taker callback when one is set. The facet names the buffer as taker callback, and the buffer's `onBuy` consents only when Midnight calls it for a buy whose buyer is the ALMProxy (`AddressNotMidnight()`, `AddressNotProxy()` otherwise). Taking as the proxy needs the proxy's own call or an authorization it never grants, so no one else can make the buffer pay.
- `approve(token)`, callable by anyone, grants the ALMProxy and Midnight the maximum allowance on that token. `setMarketConfig` calls it for every market it onboards. The buffer has no other function, no storage, no roles and no events, and implements none of Midnight's other callbacks, so repay, liquidation and flash-loan pulls from it revert.
- The buffer holds loan token only inside a call. Each leg ends by pulling the buffer's whole balance to the ALMProxy with `transferFrom`, including anything donated to it beforehand.

---

## Operations

### Buy (enter, take makers' sell offers)

**Function:** `buy(marketId, offer, ratifierData, units, maxAssetsIn) returns (assetsSpent)` (`ALLOCATOR_ROLE`)

**Flow:**

1. Read the market config for `marketId`; revert `MidnightFacet/buy-not-enabled` if `maxBuyTick` is zero. Require `maxAssetsIn != 0` (`MidnightFacet/max-assets-in-not-set`).
2. Require the take buffer to be set (`MidnightFacet/take-buffer-not-set`). Require `offer.market.midnight == midnight` (`MidnightFacet/invalid-midnight`) and `toId(offer.market) == marketId` (`MidnightFacet/market-mismatch`). Every subsequent read and call goes to the immutable singleton, so the market from calldata is only usable once it names that venue, and binding it to the id here keeps a fabricated maturity out of the bound arithmetic in step 4. Snapshot the proxy's live credit (`updatePositionView`).
3. Require the market's `continuousFee`, a per-second rate, to be within `maxContinuousFee` converted out of its annual form (`MidnightFacet/continuous-fee-too-high`) and `lossFactor <= maxLossFactor` (`MidnightFacet/loss-factor-too-high`). Entering crystallizes the continuous fee over the remaining term and buys into whatever loss has already been socialized, so both are entry-only gates.
4. Resolve two price ceilings and apply both. The tick ceiling is `tickToPrice(maxBuyTick)`. The yield-implied price ceiling is `maxBuyPrice(minBuyYield, timeToMaturity, continuousFee)`: the highest all-in price that still earns `minBuyYield` basis points a year at simple interest over ACT/365, measured on what a unit returns (par less the continuous fee crystallized for the remaining term). Both are ceilings on the all-in price the proxy pays, the settlement fee is added to each offer's price before either comparison, and the stricter ceiling binds.
5. Require `offer.buy == false` (`MidnightFacet/invalid-offer-direction`), `units != 0` (`MidnightFacet/zero-units`), `tickToPrice(offer.tick) + settlementFee <= tickCeiling` (`MidnightFacet/buy-price-too-high`), `tickToPrice(offer.tick) + settlementFee <= yieldCeiling` (`MidnightFacet/buy-yield-too-low`) and `offer.receiverIfMakerIsSeller != proxy` (`MidnightFacet/invalid-offer-receiver`, see [Security Considerations](#self-paying-offers)).
6. `doCall` the loan token's `transfer` of `maxAssetsIn` from the ALMProxy to the take buffer (`MidnightFacet/transfer-failed` if the token returns `false`). The proxy has to hold `maxAssetsIn`, since it moves up front. Every check above runs before any loan token moves.
7. Snapshot the buffer's loan-token balance, then `doCall` `midnight.take(offer, ratifierData, units, proxy, 0, buffer, "")`. Midnight pulls the payment from the buffer through its `onBuy` consent.
8. Require the buffer's loan-token balance not to have grown during the take (`MidnightFacet/buffer-balance-increased`), then size `assetsSpent` as the drop in it. Require `assetsSpent <= maxAssetsIn` (`MidnightFacet/max-assets-in-exceeded`) and `assetsSpent == buyerAssets`, the figure the take reports (`MidnightFacet/buyer-assets-mismatch`; see [Measured Deltas and the Venue's Figure](#measured-deltas-and-the-venues-figure)). Then `doCall` the loan token's `transferFrom` of the buffer's whole balance to the ALMProxy (`MidnightFacet/transferFrom-failed` if the token returns `false`): the unspent part of `maxAssetsIn`, plus anything donated to the buffer before the call.
9. Require the live credit to have grown by exactly the units taken (`MidnightFacet/credit-delta-mismatch`) and the proxy's debt to be zero (`MidnightFacet/debt-not-zero`). Anything a maker callback did to market state during the fill surfaces here.
10. Decrement `LIMIT_MIDNIGHT_BUY` keyed `marketId` by `assetsSpent`.

**Rate Limit:** `LIMIT_MIDNIGHT_BUY` via `makeBytes32Key(LIMIT_MIDNIGHT_BUY, marketId)`.

The key is salted with the governance-supplied `marketId` only. Nothing read from the protocol feeds a key: the id is itself a commitment to the full market config (venue, loan token, maturity, collateral tiers, gates), so there is nothing a counterparty can remap.

**Event:** `MidnightBuy(marketId, units, assetsSpent)`, where `assetsSpent` is the metered spend, fees included.

**Taking more than one offer:** a call takes exactly one offer. A relayer sweeping several offers issues several calls in one transaction. Each call carries its own price bound, moves its own `maxAssetsIn` through the take buffer and back, and decrements the same meter, so the aggregate matches what a single batched call used to do, while a bad offer only costs that one call.

**Zero units:** the facet rejects a zero size (`MidnightFacet/zero-units`) before reaching Midnight.

**Untouched market:** `settlementFee` reverts (`MarketNotCreated()`) on a market that has never been created on the singleton. Anyone can create one with a single permissionless `touchMarket(market)` call; the facet does not do it.

**Post-maturity:** Midnight refuses to let a maker take on new debt after maturity (`CannotIncreaseDebtPostMaturity()`), but a maker that already holds credit can still sell it, so a `buy` from such a maker succeeds after maturity. With no term left the yield-implied ceiling is par whatever `minBuyYield` is set to, so only `maxBuyTick` still binds on an offer's price. The facet does not check maturity; closing entry means zeroing `maxBuyTick`.

### Sell (exit early, take makers' buy offers)

**Function:** `sell(marketId, offer, ratifierData, units, minAssetsOut) returns (assetsReceived)` (`ALLOCATOR_ROLE`)

**Flow:**

1. Read the market config; revert `MidnightFacet/sell-not-enabled` if `minSellTick` is zero. Require `minAssetsOut != 0` (`MidnightFacet/min-assets-out-not-set`).
2. Require the take buffer to be set (`MidnightFacet/take-buffer-not-set`), `offer.market.midnight == midnight` (`MidnightFacet/invalid-midnight`) and `toId(offer.market) == marketId` (`MidnightFacet/market-mismatch`), and snapshot credit.
3. Resolve two price floors and apply both. The tick floor is `tickToPrice(minSellTick)`. The yield-implied price floor is `minSellPrice(maxSellYield, timeToMaturity, credit, pendingFee)`: the lowest net price that gives up no more than `maxSellYield` basis points a year on the same ACT/365 basis as the buy leg. The two legs measure the continuous fee differently, and deliberately so. A buy fixes the market's current rate onto the new units for their whole term, so the entry ceiling uses that rate; a position then keeps the fee it was bought at, so the exit floor uses the lien that position still carries, `pendingFee / credit` as reported by `updatePositionView`. Pricing the exit off the market's live rate instead would move the floor on every fee change: a rise would drop it below the configured policy and let a cheaper exit through, and a cut would raise it and block exits the position's own economics justify. Selling receives the tick price less the fee, so `settlementFee(marketId, timeToMaturity)` is added to each floor before comparison, and the stricter floor binds.
4. Apply the same direction (`offer.buy == true`) and non-zero-units checks as `buy`. Cap `units` at the proxy's **live credit** and require what is left to be non-zero (`MidnightFacet/no-credit-to-sell`), so a sell can never be filled with debt. Then `tickToPrice(offer.tick) >= tickFloor + settlementFee` (`MidnightFacet/sell-price-too-low`) and `tickToPrice(offer.tick) >= yieldFloor + settlementFee` (`MidnightFacet/sell-yield-too-high`). Then snapshot the take buffer's loan-token balance and `doCall` `midnight.take(offer, ratifierData, cappedUnits, proxy, buffer, 0, "")`, so the proceeds land in the buffer.
5. Measure `assetsReceived` as the buffer's balance delta. Require `assetsReceived == sellerAssets`, the figure the take reports (`MidnightFacet/seller-assets-mismatch`), and `assetsReceived >= minAssetsOut` (`MidnightFacet/min-assets-out-not-met`). Then pull the buffer's whole balance to the ALMProxy, as on `buy`.
6. Require the live credit to have shrunk by exactly the units sold (`MidnightFacet/credit-delta-mismatch`) and the proxy's debt to be zero (`MidnightFacet/debt-not-zero`).
7. Decrement `LIMIT_MIDNIGHT_SELL` keyed `marketId` by `assetsReceived`. The buy key is not read, so it is neither a precondition for the exit nor restored by it.

**Rate Limit:** `LIMIT_MIDNIGHT_SELL` via `makeBytes32Key(LIMIT_MIDNIGHT_SELL, marketId)`.

**Event:** `MidnightSell(marketId, units, assetsReceived)`, where `units` is what was actually sold after capping and `assetsReceived` the measured buffer delta, net of fees.

**Credit drifts down:** the live credit read from `updatePositionView` already reflects accrued continuous fee and any socialized loss, so the cap in step 4 is what keeps a sell from ever creating debt. An ask sized against a stale credit reading is trimmed to what is left, and one against an exhausted position reverts.

**Post-maturity:** selling stays open only at par. The settlement fee schedule resolves at zero time to maturity, and so does the yield-implied price floor: with no term left, any discount gives up unbounded yield against a redemption that pays par, so the floor collapses onto par and refuses every discounted offer (`MidnightFacet/sell-yield-too-high`). A crystallized lien is fully accrued by maturity, so this holds for a position bought under a live continuous fee as well: its `pendingFee` is zero by then and the floor is exactly par. A par offer (tick `6743` or `6744`) still clears when the settlement fee is zero. This is deliberate, and it costs nothing: `redeem` pays exactly par with no fee, while a sell pays the tick price less the settlement fee, so `sell <= par - settlementFee <= redeem` for every offer. A post-maturity sell can therefore never beat redemption; the floor blocks a guaranteed loss rather than a trade, and the one case it still permits (par price, zero fee) is cash-identical to redeeming while not drawing on `withdrawable`. Note that no configuration value reopens a discounted exit: the yield-implied price floor at zero time to maturity is par regardless of `maxSellYield`, and `minSellTick` only feeds the looser of the two floors, so changing this would take a new facet deployment, not a spell.

### Redeem (exit at par from repayments)

**Function:** `redeem(marketId, units, minAssetsOut) returns (assetsWithdrawn)` (`ALLOCATOR_ROLE`)

**Flow:**

1. Require the market to be onboarded, `minSellTick != 0` (`MidnightFacet/market-not-onboarded`). Redemption reads no other config value; the onboarded config is what authenticates the id. Require `minAssetsOut != 0` (`MidnightFacet/min-assets-out-not-set`), as on `sell`, and the take buffer to be set (`MidnightFacet/take-buffer-not-set`).
2. Resolve the `Market` struct from the id on the singleton (`toMarket(marketId)`), so redemption never trusts a market from calldata. Require the returned market to name the configured singleton (`MidnightFacet/invalid-midnight`) and to hash to `marketId` (`MidnightFacet/market-mismatch`).
3. Cap `units` at both the proxy's live credit and the market's `withdrawable` amount (repaid, not yet withdrawn), then require the result to be non-zero (`MidnightFacet/zero-units`). Passing `type(uint256).max` redeems everything currently available.
4. Snapshot the take buffer's balance, `doCall` `midnight.withdraw(market, units, proxy, buffer)`, and measure `assetsWithdrawn` as the buffer's balance delta. `withdraw` returns nothing, so there is no venue figure to compare it with. Require `assetsWithdrawn >= minAssetsOut` (`MidnightFacet/min-assets-out-not-met`), then pull the buffer's whole balance to the ALMProxy, as on `buy`.
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
| `minSellTick`      | `uint16`  | Floor an offer's price must clear once the settlement fee is added to it. Non-zero marks the market as onboarded and gates `sell` and `redeem`. Must be `<= 6744` and price above zero (`tickToPrice(minSellTick) != 0`), so ticks `0` and `1` are rejected (`MidnightFacet/min-sell-tick-oob`). |
| `minBuyYield`      | `uint16`  | Lowest implied yield a buy may accept, in basis points a year (max `655.35%`). `0` is the loosest setting that still refuses to pay more than a unit returns. |
| `maxSellYield`     | `uint16`  | Highest implied yield a sell may give up, in basis points a year. Must be non-zero (`MidnightFacet/max-sell-yield-not-set`); zero would only clear at par and brick the exit. |
| `maxContinuousFee` | `uint16`  | Highest market continuous fee a buy tolerates, in centi-basis points a year. Must be `<= 1_00_00`, one percent a year, Midnight's own ceiling (`MidnightFacet/max-continuous-fee-oob`). |
| `maxLossFactor`    | `uint128` | Highest market loss factor a buy tolerates, as a fraction of `type(uint128).max`. `0` means no socialized loss is tolerated.            |

- All values default to zero, the strictest setting: nothing is onboarded, nothing can be entered.
- Onboarding readies the take buffer for the market's loan token. The call requires the buffer to be set (`MidnightFacet/take-buffer-not-set`), reads the loan token from the singleton with `toMarket(marketId)`, which reverts `MarketNotCreated()` for a market never created there, and calls the buffer's `approve(loanToken)` before storing the config. The buffer has to be set and the market has to exist before the market is onboarded.
- `minSellTick` is an exit floor and has to stay reachable: below par net of the settlement fee, or every sell reverts on price. `setMarketConfig` rejects a zero `minSellTick` outright, so a market once onboarded cannot be un-onboarded through the facet; closing a market means zeroing `maxBuyTick` and leaving the exits configured.
- Each leg carries a tick bound and a yield bound, and the stricter binds. Ticks are absolute prices and go stale as the term shortens: a tick that is a fair entry at 180 days is a giveaway at 5. The yield bounds are denominated in rate, so they track the term on their own and need no spell as maturity approaches. Both fees are inside the comparison, so a fee change does not need a reconfiguration either.
- Yield granularity is one basis point a year, worth about `1.0` basis points of price at a 360 day term, `0.5` at 180 days and `0.02` at 7 days. Set `maxSellYield` well above the market rate: it is a gross-mispricing rail, not a spread control, and it tightens towards par on its own as maturity approaches.
- The yield bounds cannot overflow or underflow. Midnight refuses a maturity more than 100 years out (`MaturityTooFar()`) and caps the continuous fee at one percent a year, so the fee crystallized over any reachable term stays below par. That holds only because the market from calldata is bound to `marketId` before any bound is computed; a fabricated maturity would otherwise reach the arithmetic.
- `maxContinuousFee` is an annual rate, while Midnight stores the fee itself per second. The facet converts the ceiling as `cbps * 1e12 / 365 days` and floors, so the effective ceiling never sits above the rate named; `1_00_00` maps exactly onto Midnight's own `0.01e18 / 365 days` cap. Reading the venue's `continuousFee(id)` against the configured value therefore needs that conversion.
- Write the value grouped as `percent_bp_cbp`, so the digits carry their own units: `1_00_00` is one percent a year, `50_00` is 50 basis points, `1` is one centi-basis point.
- The fee and loss guards apply to entry only. Exits are bounded by `minSellTick`, `maxSellYield`, `minAssetsOut` and the rate limits.

**Event:** `MidnightMarketConfigSet(marketId, maxBuyTick, minSellTick, minBuyYield, maxSellYield, maxContinuousFee, maxLossFactor)`

Together with the rate-limit keys, a non-zero `minSellTick` acts as the per-market whitelist: both must be configured by governance before the first trade.

### Set Take Buffer (admin)

**Function:** `setTakeBuffer(buffer)` (`DEFAULT_ADMIN_ROLE`)

Sets the take buffer that `buy`, `sell` and `redeem` route the loan token through, stored at the end of the facet's ERC-7201 storage. Refuses the zero address (`MidnightFacet/zero-take-buffer`). While no buffer is set, `buy`, `sell`, `redeem` and `setMarketConfig` revert (`MidnightFacet/take-buffer-not-set`).

The buffer has to be deployed with this ALMProxy and the facet's Midnight singleton. Loan tokens onboarded before a change of buffer are not approved on the new one: call its `approve(token)` for each of them, or onboard their markets again.

**Event:** `MidnightTakeBufferSet(buffer)`

### Views

| Function                        | Returns                                                                 |
| ------------------------------- | ----------------------------------------------------------------------- |
| `getBuyRateLimitKey(marketId)`    | `makeBytes32Key(LIMIT_MIDNIGHT_BUY, marketId)`                        |
| `getSellRateLimitKey(marketId)`   | `makeBytes32Key(LIMIT_MIDNIGHT_SELL, marketId)`                       |
| `getRedeemRateLimitKey(marketId)` | `makeBytes32Key(LIMIT_MIDNIGHT_REDEEM, marketId)`                     |
| `getMarketConfig(marketId)`       | Configured `MarketConfig`, all-zero when not onboarded                |
| `midnight()`                      | The immutable Midnight singleton every call is pinned to              |
| `takeBuffer()`                    | The configured take buffer, zero while unset                          |

---

## Rate Limit Keys

| Limit                    | Key tuple    | Helper           |
| ------------------------ | ------------ | ---------------- |
| `LIMIT_MIDNIGHT_BUY`     | `(marketId)` | `makeBytes32Key` |
| `LIMIT_MIDNIGHT_SELL`    | `(marketId)` | `makeBytes32Key` |
| `LIMIT_MIDNIGHT_REDEEM`  | `(marketId)` | `makeBytes32Key` |

All three are denominated in the market's loan token and sized by what moved through the take buffer. Every leg only ever decrements, and only the key for its own direction: a buy spends the buy key, a sell the sell key, a redemption the redeem key. No leg restores another, so entry headroom comes back only from the buy key's own slope, and governance sizes that slope to the pace of entry it wants rather than to the pace of exits.

That is a deliberate trade for a smaller blast radius. A refilling buy key makes the cumulative entry bound unbounded in the number of round trips, because each exit buys back the room the next entry spends. Without it the bound over any window is the buy key's `maxAmount` plus its slope, independent of how much is rotated. The cost is that a genuine rotation now waits on the slope, and that an operator who wants a faster re-entry has to raise the buy limit rather than rely on the exit to fund it.

Splitting sell from redeem lets governance price the two exits differently: redemption is at par and only limited by repayments, while a sell crosses the spread and the settlement fee.

---

## Security Considerations

### Immutable Venue

The Midnight singleton is an immutable, non-upgradeable contract with no owner over funds. Its `configurator` can enable LLTV and liquidation-cursor tiers, replace itself, and appoint three roles: a `feeSetter` who can move the settlement and continuous fees of any market within hard-coded ceilings, a `feeClaimer` who withdraws accrued continuous fee out of a market's repayment pool (`claimContinuousFee` decrements `withdrawable`, so it competes with lenders for the same pool `redeem` draws from), and a `tickSpacingSetter` who can only refine a market's tick spacing. None of them can touch positions or move a lender's loan tokens. The facet binds to one singleton at construction, so a repoint requires a new facet deployment and a governance spell.

### Maker Callbacks Run Inside Our Take

An offer may name a `callback` contract with opaque `callbackData`; Midnight calls it inside `take`, after the transfers when the maker sells and before them when the maker buys. The facet cannot vet what it does and does not try to: banning callbacks is not viable because callback-backed offers are how makers source liquidity. Instead the facet relies on three post-conditions that hold for the whole call:

- The controller's reentrancy guard is held for the entire call, so the callback cannot re-enter any facet.
- The ALMProxy grants Midnight no approval, and the take buffer pays only a buy whose buyer is the proxy. A callback that tries to make the proxy or the buffer pay for some other flow is refused (the proxy authorizes no ratifier and no operator, and neither the proxy nor the buffer is a repay callback).
- The exact credit-delta, zero-debt, `maxAssetsIn` and venue-figure checks after the take catch any change to the proxy's position or to the buffer's balance that did not come from the requested fill, including a socialized loss landing mid-fill. The mainnet-fork attack tests drive a hostile maker through take, withdraw, authorization and repayment attempts, and slash a third borrower from inside a fill, in both directions.

### Ratifier Data Is Opaque

`ratifierData` is forwarded as-is to the **maker's** ratifier, which decides whether the offer is live. The facet validates outcomes (price bound, direction, id, deltas), not the offer's provenance; an offer that fails ratification reverts inside Midnight. Makers on mainnet point at Morpho's deployed `SetterRatifier` (`0xb72c416382c8A6399D0765CebfB032F040B00B3c`), which treats `ratifierData` as a Merkle proof of the offer against the maker's committed root; the mainnet-fork tests ratify through that contract rather than a test double.

### Self-Paying Offers

If a sell offer named the ALMProxy as `receiverIfMakerIsSeller`, the maker's proceeds would come straight back to the proxy while the buy key is charged the full spend. The facet rejects such offers outright (`MidnightFacet/invalid-offer-receiver`). On the sell side the proxy is the seller and the facet names the take buffer as receiver.

### Socialized Loss Is a Ratchet

`lossFactor` only ever increases. A buy into a market that has already been slashed buys in at the written-down value, so `maxLossFactor` gates entry and defaults to zero. It never gates exit: after a slash the live credit is lower, the sell cap follows it, and redemption returns what is left. A market whose `lossFactor` saturates at `type(uint128).max` makes `take` revert for everyone; that is a monitoring concern, not one the facet can act on.

### Mutable Reads Feed Guards, Not Keys

`continuousFee`, `lossFactor`, `settlementFee`, `updatePositionView`, `withdrawable` and `toMarket` are all read from the singleton at call time and can change between calls. Each one feeds a guard that fails closed (a tighter bound, a smaller cap, a revert), and none of them is used to derive a rate-limit key. The only key salt is the governance-supplied `marketId`. `toMarket` also names the loan token `setMarketConfig` approves on the take buffer, an approval that only ever grants the ALMProxy and Midnight. The facet reads no oracle: Midnight's collateral oracles are a protocol-side solvency assumption, not a pricing input here. Loan tokens are standard non-rebasing ERC-20s (USDC and USDS, 6 and 18 decimals), so a measured balance delta is exact.

### Measured Deltas and the Venue's Figure

All three operations size their rate-limit accounting, `maxAssetsIn` and `minAssetsOut` from observed balance changes on the take buffer rather than from the caller's arguments or the venue's figures, and the two take paths additionally reconcile the credit delta against the units requested.

Nothing of ours is sent to the buffer except the buy's own `maxAssetsIn`, so its balance delta around a take is exactly what Midnight moved. Loan token reaching the ALMProxy while the take is in flight, from a maker callback or a bridge delivery bundled ahead of it, lands outside the measurement and changes neither the spend nor the proceeds.

The figure the take returns, `buyerAssets` on a buy and `sellerAssets` on a sell, is used only as a tripwire: the measured delta has to equal it (`MidnightFacet/buyer-assets-mismatch`, `MidnightFacet/seller-assets-mismatch`). Loan token sent to the buffer during a take therefore reverts that call, and on a buy one larger than the spend reverts before the comparison, because the buffer's balance has grown (`MidnightFacet/buffer-balance-increased`): the sender can grief a take but gains nothing. Loan token sent to the buffer before a call sits outside the before-and-after window: it is swept to the proxy with the rest of the buffer's balance and counted as neither spend nor proceeds. `redeem` has no figure to compare, since `withdraw` returns nothing, and relies on the buffer delta alone.

### No Standing Approvals

The ALMProxy grants no approval at all: `buy` moves `maxAssetsIn` to the take buffer with a `transfer`, and every leg ends by pulling the buffer's whole balance back. The buffer holds maximum allowances to the ALMProxy and to Midnight for every onboarded loan token, but no loan token outside a call other than a donation the next call sweeps, and Midnight pulls from it only through `onBuy`, for a buy by the proxy.

### Reentrancy

All interactive functions are `nonReentrant`.

---

## Failure Modes

| Revert                                   | Origin      | Cause                                                                                     |
| ---------------------------------------- | ----------- | ----------------------------------------------------------------------------------------- |
| `MidnightFacet/buy-not-enabled`          | facet       | `buy` on a market whose `maxBuyTick` is zero                                              |
| `MidnightFacet/sell-not-enabled`         | facet       | `sell` on a market whose `minSellTick` is zero                                            |
| `MidnightFacet/market-not-onboarded`     | facet       | `redeem` on a market whose `minSellTick` is zero                                          |
| `MidnightFacet/max-assets-in-not-set`    | facet       | `buy` with zero `maxAssetsIn`                                                             |
| `MidnightFacet/min-assets-out-not-set`   | facet       | `sell` or `redeem` with zero `minAssetsOut`                                               |
| `MidnightFacet/invalid-midnight`         | facet       | `offer.market.midnight`, or on `redeem` the market `toMarket(marketId)` returns, does not name the configured singleton |
| `MidnightFacet/market-mismatch`          | facet       | the offer's market, or on `redeem` the market `toMarket(marketId)` returns, does not hash to `marketId` |
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
| `MidnightFacet/max-assets-in-exceeded`   | facet       | measured spend above `maxAssetsIn`                                                        |
| `MidnightFacet/min-assets-out-not-met`   | facet       | measured proceeds below `minAssetsOut`                                                    |
| `MidnightFacet/take-buffer-not-set`      | facet       | `buy`, `sell`, `redeem` or `setMarketConfig` while no take buffer is set                  |
| `MidnightFacet/zero-take-buffer`         | facet       | `setTakeBuffer` with the zero address                                                     |
| `MidnightFacet/buffer-balance-increased` | facet       | the buffer's balance grew during a buy's take: a donation larger than the spend           |
| `MidnightFacet/buyer-assets-mismatch`    | facet       | the take buffer's delta on a buy differs from the `buyerAssets` the take reports          |
| `MidnightFacet/seller-assets-mismatch`   | facet       | the take buffer's delta on a sell differs from the `sellerAssets` the take reports        |
| `MidnightFacet/transfer-failed`          | facet       | the loan token returned `false` when the ALMProxy moved `maxAssetsIn` to the take buffer  |
| `MidnightFacet/transferFrom-failed`      | facet       | the loan token returned `false` when the ALMProxy pulled the take buffer's balance        |
| `AddressNotMidnight()`, `AddressNotProxy()` | take buffer | a take buffer deployed for another singleton or another ALMProxy                          |
| loan token's own revert                  | loan token  | `buy` with `maxAssetsIn` above the ALMProxy's balance, or below what the take costs       |
| `MidnightFacet/credit-delta-mismatch`    | facet       | live credit did not move by exactly the units taken                                       |
| `MidnightFacet/debt-not-zero`            | facet       | the venue reports debt against the ALMProxy after a trade                                 |
| `MidnightFacet/max-buy-tick-oob`         | facet       | `setMarketConfig` with `maxBuyTick > 6744`                                                |
| `MidnightFacet/min-sell-tick-oob`        | facet       | `setMarketConfig` with `minSellTick` zero, `> 6744`, or a tick whose price rounds to zero (tick `1`) |
| `MidnightFacet/max-continuous-fee-oob`   | facet       | `setMarketConfig` with `maxContinuousFee` above Midnight's ceiling                        |
| `MidnightFacet/max-sell-yield-not-set`   | facet       | `setMarketConfig` with a zero `maxSellYield`                                               |
| `MidnightTickLib/tick-out-of-range`      | facet       | an offer tick above `6744`                                                                |
| `MidnightFacet/zero-midnight`            | facet       | constructor with a zero singleton address                                                 |
| `RateLimits/rate-limit-exceeded`         | rate limits | trade exceeding the configured limit                                                      |
| `RateLimits/zero-maxAmount`              | rate limits | key unconfigured                                                                          |
| `MarketNotCreated()`                     | Midnight    | market never touched on the singleton, on a trade or on `setMarketConfig`                 |
| `RatifierUnauthorized()`                 | Midnight    | maker has not authorized its ratifier                                                     |
| `NotRatified()`                          | ratifier    | the maker's `SetterRatifier` does not recognize the offer (bubbles through Midnight)      |
| `InvalidProof()`                         | ratifier    | the `ratifierData` Merkle proof does not place the offer under the maker's root           |
| `ConsumedUnits()`, `ConsumedAssets()`    | Midnight    | offer already filled past its cap, including by someone else in the same block            |
| `OfferExpired()`, `OfferNotStarted()`    | Midnight    | offer outside its validity window                                                         |
| `CannotIncreaseDebtPostMaturity()`       | Midnight    | `buy` after maturity from a maker that would have to incur debt to fill it                |
| `SellerIsLiquidatable()`                 | Midnight    | the maker selling to us would be left unhealthy                                           |
| `MarketLossFactorMaxedOut()`             | Midnight    | market has lost everything; no takes are possible                                         |

---

## Operational Requirements

### Configuration (before first trade)

Once per facet: deploy a `MidnightTakeBufferStrategy` bound to the ALMProxy and the Midnight singleton, and set it with `setTakeBuffer(buffer)` before onboarding any market. `setMarketConfig`, `buy`, `sell` and `redeem` revert until it is set.

Per market (`marketId`):

1. Confirm the market exists on the singleton (`toMarket(marketId)` resolves, `settlementFee` does not revert). If not, anyone can `touchMarket(market)` once; the facet does not. `setMarketConfig` reverts (`MarketNotCreated()`) until it exists.
2. Review the market config the id commits to: loan token, maturity, collateral tiers (LLTV, liquidation cursor, oracle), `rcfThreshold`, gates. A tier at LLTV `1e18` lets a borrower sell against the full collateral value, so any adverse oracle move leaves bad debt for lenders; treat it as a due-diligence red flag.
3. `setMarketConfig(marketId, ...)`: required, and every limit is passed in the one call. `minSellTick` non-zero and below par net of the settlement fee; `maxBuyTick` at the highest all-in price acceptable for the remaining term; `minBuyYield` at the lowest rate worth entering for and `maxSellYield` (non-zero) at the widest give-up an exit may pay, both in basis points a year; `maxContinuousFee` (centi-basis points a year) and `maxLossFactor` at the tolerances the position can absorb, both defaulting to zero. The same call approves the market's loan token on the take buffer.
4. Configure `LIMIT_MIDNIGHT_BUY`, `LIMIT_MIDNIGHT_SELL` and `LIMIT_MIDNIGHT_REDEEM` keyed `marketId`, in the loan token's units. The exits are gated only by their own keys; zeroing the buy key pauses entry without touching exits. Size the buy key's slope to the pace of entry the market should sustain, not to the size of the position: no exit refills it, so rotating out and straight back in waits on that slope.

No seeding is required: the integration holds no intermediate token, and the take buffer needs no funding since it holds loan token only inside a call. Offers are sourced off-chain from makers (or the Morpho API) and passed in calldata by the allocator together with each maker's ratifier data.

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

## Related Documentation

- [ARCHITECTURE.md](./ARCHITECTURE.md): overall facet architecture and Controller dispatch.
- [RATE_LIMITS.md](./RATE_LIMITS.md): rate-limit key construction, try-increase and gate-check patterns.
- [SECURITY.md](./SECURITY.md): venue trust assumptions and the external protocol's audit status.
- [THREAT_MODEL.md](./THREAT_MODEL.md): protocol trust matrix and external risk surface.
