# Threat Model

This document outlines the threat model for PAU, including attack vectors, trust assumptions, and mitigations.

## Actors and Trust Levels

| Actor                                 | Trust Level   | Description                                                                                                                                                                                                                                                                              |
| ------------------------------------- | ------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Governance** (`DEFAULT_ADMIN_ROLE`) | Fully trusted | Controls all admin functions, can upgrade controllers, set rate limits                                                                                                                                                                                                                   |
| **Allocator** (`ALLOCATOR_ROLE`)      | **Untrusted** | Assumed to be potentially compromised at any time                                                                                                                                                                                                                                        |
| **Allocator role admin**              | Trusted       | Whichever role governance sets as the admin of `ALLOCATOR_ROLE` via `accessControls.setRoleAdmin`. Can grant and revoke `ALLOCATOR_ROLE`, including emergency revocation of compromised allocators. Typically delegated to a custom module that enforces a specific grant/revoke policy. |
| **External Protocols**                | Varies        | Trust depends on specific integration (see Protocol Trust section)                                                                                                                                                                                                                       |

---

## Core Assumption: 1:1 Asset Parity

**Assumption:** All stablecoin assets that share an underlying peg are treated as 1:1 with each other (USDC = USDT = DAI = USDS).

**Implication:** No price oracles are used for stablecoin swaps within the system.

**Risk:** If assets depeg significantly, the 1:1 assumption breaks down. This is an accepted protocol risk that should be monitored operationally.

---

## Primary Threat: Compromised Allocator

The system is designed with the assumption that an actor with `ALLOCATOR_ROLE` can be fully compromised by a malicious actor. This is the primary threat the architecture defends against.

### Attack Vectors

| Attack                                   | Mitigation                                                                 |
| ---------------------------------------- | -------------------------------------------------------------------------- |
| **Unauthorized fund transfer**           | Funds can only move to whitelisted addresses; rate limits bound exposure   |
| **Excessive slippage attacks**           | `maxSlippage` parameters enforce minimum acceptable returns                |
| **Rate limit exhaustion**                | Rate limits regenerate over time; bounded maximum exposure                 |
| **Interaction with malicious contracts** | Rate limit keys act as whitelist - only configured integrations work       |
| **DOS attacks**                          | Accepted risk; recovery procedures documented in `Attacks.t.sol`           |
| **Gas griefing**                         | Accepted risk; economic impact is minimal compared to rate-limited capital |

### Design Principles

1. **Value cannot leave the system** - All operations must keep funds within the PAU system of contracts
    - Exception: Asynchronous integrations (e.g., BUIDL, Ethena) where funds go to whitelisted addresses
    - Exception: Morpho Midnight maker mode, where the entry leg transits loan tokens through
      an immutable funding strategy, a periphery contract deployed from outside this repository
      that holds no balance between settlements and is drained by the singleton inside the same
      `take` that funded it

2. **Losses bounded by rate limits** - Any single attack is limited to the current rate limit capacity
    - Morpho Midnight maker fills are metered through `fundFill` in both directions, on the same
      per-direction market keys taker traffic spends, and no leg on either side restores. The
      fill still happens in a third party's transaction, so a maker fill that exceeds a meter
      reverts the taker rather than us; the price floors the ratifier enforces at signing time and
      six revocation levers that act retroactively on published offers are what bound the rest

3. **Allocator role admin can halt attacks** - The admin of `ALLOCATOR_ROLE` can revoke a compromised allocator within the rate limit window

4. **No trust in allocator input** - All allocator-provided parameters are validated against on-chain constraints

---

## Rate Limits as Security Boundary

Rate limits serve as the primary security boundary against compromised allocators.

### How Rate Limits Protect

- **Immediate attack capacity** = `lastAmount` plus accumulation since `lastUpdated` (current available limit)
- **Maximum attack capacity** = `maxAmount` (rate limit ceiling)
- **Recovery rate** = `slope` (tokens per second regeneration)

### Rate Limit Key Whitelisting

Rate limit keys (hash of function identifier + address) act as an implicit whitelist:

- Only governance-configured integrations have valid rate limit keys
- Attempting to use unconfigured addresses will revert
- Provides protection against interaction with malicious contracts

---

## Protocol Trust Matrix

### Fully Trusted

| Protocol                  | Trust Reason                         |
| ------------------------- | ------------------------------------ |
| **Sky Allocation System** | Core protocol, governance controlled |
| **PSM**                   | Core protocol, immutable             |

### Trusted with Caveats

| Protocol      | Caveat                                                                                                                                                                                                                                          |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Ethena**    | Delegated signer can be set by allocator; Ethena's off-chain validation trusted                                                                                                                                                                 |
| **EtherFi**   | Withdrawal requests can be invalidated (and revalidated) by admin                                                                                                                                                                               |
| **OTC Desks** | Assumed to complete trades; max loss bounded by single swap amount                                                                                                                                                                              |
| **Maple**     | Permissioned pools with slower dynamics                                                                                                                                                                                                         |
| **Aave V4**   | All spoke/hub contracts are proxies upgradeable by Aave governance; withdrawals blockable via reserve pause or hub-side spoke halt/deactivation; hub reinvestment controller can deploy idle liquidity, reducing immediately withdrawable funds |
| **Morpho Midnight** | Singleton is immutable and holds no admin over positions, but its `configurator` appoints a `feeSetter` who can move any market's settlement and continuous fees within hard-coded ceilings; lender losses are socialized through a monotone `lossFactor`; redemption is first come first served out of a shared repayment pool; makers' offer callbacks execute inside the proxy's own `take` |

### External Protocol Risks

| Protocol            | Risk                                                                                                                                          | Mitigation                                                                                                                                                                                                     |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **ERC-4626 Vaults** | Rounding/donation attacks                                                                                                                     | Require burned shares; maxExchangeRate mechanism                                                                                                                                                               |
| **Curve Pools**     | Unseeded pool manipulation                                                                                                                    | Require pools to be seeded before whitelisting                                                                                                                                                                 |
| **CCTP**            | Bridge delays                                                                                                                                 | Operational consideration only                                                                                                                                                                                 |
| **Aave V4**         | Socialized bad debt (hub deficit) never marks down supplier share price; loss surfaces as exit-liquidity shortfall for the last suppliers out | Deposits revert while `getAssetDeficitRay` exceeds the per-Hub-asset tolerance, which defaults to zero and is governance-set; hub liquidity vs. position size monitored operationally                          |
| **Aave V4**         | Spoke remaps a reserve's `underlying`, `hub` or `assetId`                                                                                     | Deposit rate-limit key embeds all three, so any remap invalidates the configured budget; withdrawals are deliberately unaffected (they key only on `(spoke, reserveId)`), so exits are never wedged by a remap |
| **Aave V4**         | Credited position short of supplied amount (rounding/misreport)                                                                               | Position delta measured on-chain and enforced against per-market `maxSlippage` floor                                                                                                                           |
| **Morpho Midnight** | Maker callback runs inside the proxy's `take` while the buy approval is open, and may move market state (take, withdraw, authorize, repay, liquidate a third borrower) | Reentrancy guard held for the whole call; approval is exactly `maxAssetsIn` and Midnight only pulls from the proxy on the proxy's own flows; exact credit-delta, zero-debt and `maxAssetsIn` post-checks unwind any take whose outcome differs from the fill requested; the buy meters the higher of the balance delta and the `buyerAssets` the take reports, so loan token pushed into the proxy mid-fill cannot shrink the charge |
| **Morpho Midnight** | Socialized bad debt (`lossFactor`) writes down every lender's credit, including mid-transaction                                               | Entry gated by per-market `maxLossFactor` (default zero); sell sizes capped at live credit so a write-down can never leave the proxy in debt; exits never blocked                                               |
| **Morpho Midnight** | Sell offer naming the ALMProxy as proceeds receiver nets the spend to the fee and under-reports it to the rate limit                          | `receiverIfMakerIsSeller != proxy` enforced on every buy leg                                                                                                                                                   |
| **Morpho Midnight** | Fee setter raises settlement or continuous fee between configuration and trade                                                                | Price bounds are fee-adjusted at call time and fail closed; continuous fee gated on entry by `maxContinuousFee`; both fees sit inside the implied-yield bounds, the entry ceiling off the market's live rate and the exit floor off the lien the position itself carries, so neither bound goes stale when the fee moves and a later rise cannot pull the floor below the configured policy, though within hours of maturity the sell floor plus the fee can exceed par and wedge `sell` until the fee falls or `maxSellYield` widens (`redeem` is unaffected); exits unaffected by fee gates                                                                  |
| **Morpho Midnight** | Rogue allocator sells credit into a maker's buy offer at a deep discount while a par exit is available, handing the difference to the maker. Per-call `minAssetsOut` is no defence: the caller chooses it | Governance `maxSellYield` caps the implied yield an exit may give up for the term actually left, and `minSellTick` floors the absolute price. The yield-implied price floor converges on par as maturity approaches, so a post-maturity dump is refused outright and the exit is `redeem`. Sizing is still capped by `LIMIT_MIDNIGHT_SELL` |
| **Morpho Midnight** | Rogue allocator enters at a price whose yield does not compensate for the term, or above what a unit returns net of the continuous fee | Governance `minBuyYield` bounds the all-in entry price in rate terms and `maxBuyTick` bounds it absolutely; a zero `minBuyYield` still refuses any price above the unit's payoff |
| **Morpho Midnight** | Fee claimer withdraws accrued continuous fee out of a market's repayment pool, competing with lenders for `withdrawable`                       | Redemption units are capped at live `withdrawable` and bounded by `minAssetsOut`; the claim is a timing cost on redemption, not a write-down (credit is untouched); the sell path remains the exit           |
| **Morpho Midnight** | Offer market from calldata names a different venue or market than governance onboarded                                                       | Every call is pinned to the immutable singleton; each offer's market must hash to the governance-supplied `marketId`, which commits to venue, loan token, maturity, collateral tiers and gates; keys are salted by that id only |
| **Morpho Midnight** (maker) | Authorizing a ratifier on the singleton is a blanket grant: the same `isAuthorized` mapping that permits ratification also permits `withdraw`, `repay`, `supplyCollateral`, `withdrawCollateral`, `setConsumed` and `setIsAuthorized` on the proxy's behalf. Upstream has no narrower grant | Only a purpose-built, immutable, non-upgradeable contract is ever granted it, which must be verified by opcode scan to contain no code-borrowing, self-destruction or arbitrary-call surface. That scan is a **deployment precondition on the authorizing spell**: the ratifier ships from the periphery repository, so this repository cannot run it. What it does assert: the controller's own view of the singleton declares no collateral, borrow, liquidate or flash-loan entry point, so no other contract in the system can perform the permitted operations even if authorized, and the fork suite asserts `isAuthorized[proxy][x]` holds for exactly one address. Revocable in one admin transaction, which also kills every resting offer, but the grant permits `setIsAuthorized`, so a revoke clears only the address it names: alert on `SetIsAuthorized` with `onBehalf` equal to the proxy and revoke every entry it reports |
| **Morpho Midnight** (maker) | The exit leg executes in a third party's transaction with no code of ours in it, so no post-check, balance-delta measurement or rate limit can apply to it, and no test in this repository can exercise the policy that bounds it | The ratifier is the sole gate and is consulted on every fill, reading policy live from facet storage rather than from anything signed, and is verified against that policy in the periphery repository; `receiverIfMakerIsSeller` must be the proxy, so proceeds cannot be redirected. The exit is not left to the ratifier: `onSell` reaches `fundFill`, which prices the fill against `maxSellYield` and `minSellTick`, meters it, and requires the position to hold zero debt afterwards, so a fill can shed credit but never open a short |
| **Morpho Midnight** (maker) | `fundFill` has no role gate and is reachable directly from any address, since it must be callable from inside the singleton's `onBuy` and `onSell` | A per-market callback whitelist is the authorization, so an unlisted caller is rejected outright and removal revokes retroactively; the market's entry meter on a buy or exit meter on a sell is debited before any transfer; `assets * WAD <= units * maxFillPrice` at the configured fee cap on an entry, `assets * WAD >= units * minFillPrice` on an exit, both cross-multiplied so no rounding widens them; live `lossFactor`, live continuous fee and make-enabled checks on an entry, a zero-debt post-condition on an exit; the transfer pays `msg.sender` only, so an unauthorized caller can never direct funds elsewhere. A whitelisted callback can still report a fill that never happened: an entry pays it out, bounded by the remaining buy meter rather than by the price bound, since the caller picks `units`; an exit moves nothing, restores nothing, and only burns the sell meter, so it cannot manufacture entry room. The buy meter and its slope are the cumulative bound, and `removeCallback` ends it in one allocator transaction |
| **Morpho Midnight** (maker) | Quoter signing key is compromised and used to sign offers the operator never intended | A signature authorizes nothing on its own: a signed offer only reaches settlement through a whitelisted callback, and that callback's `fundFill` re-validates it against live governance policy (tick bounds, both yield rails, make-enabled, the live continuous fee, the live loss factor, and zero debt after an exit) while the ratifier independently re-checks the parties, the designated group, the receiver and the offer window, so a stolen key can only trade inside policy, never outside it; `maxOfferWindow` caps how long any signature stays live; revoking the quoter's role on the ratifier invalidates every outstanding signature at once, because the role is checked at ratification rather than at signing |
| **Morpho Midnight** (maker) | Rogue allocator halts maker mode on a market: `cancelOfferGroup` retires a designated group, `removeCallback` clears one strategy's whitelist entry | Both are liveness-only and move no value: they can refuse a fill, never redirect or reprice one. `removeCallback` is strictly tightening, is a subset of the retirement power the role already holds, and is the reversible one of the two, since re-whitelisting is admin-only while a retired group is gone for good. Neither recalls a published offer, so it is the taker's fill that reverts |

---

## Attack Scenarios and Responses

### Scenario 1: Allocator Key Compromise

**Attack:** Attacker gains access to allocator private key

**Response:**

1. The allocator role admin revokes `ALLOCATOR_ROLE` from the compromised account
2. System switches to backup allocator
3. Maximum loss bounded by rate limits at time of compromise

### Scenario 2: Repeated High-Slippage Transactions

**Attack:** Compromised allocator repeatedly executes trades at maximum allowed slippage

**Response:**

1. Rate limits bound total value extracted
2. Allocator role admin revokes `ALLOCATOR_ROLE` when attack detected
3. Slippage parameters limit per-transaction loss

### Scenario 3: DOS Attack

**Attack:** Compromised allocator spams transactions to prevent legitimate operations

**Response:**

1. Accept temporary operational disruption
2. Allocator role admin revokes `ALLOCATOR_ROLE` from the compromised account
3. Resume operations with backup allocator
4. Recovery procedures documented in `Attacks.t.sol`

### Scenario 4: Malicious Contract Interaction Attempt

**Attack:** Compromised allocator tries to interact with malicious contract

**Response:**

1. Rate limit key not configured for malicious contract
2. Transaction reverts automatically
3. No funds at risk

---

## Assets NOT Considered Threats

| Item                       | Rationale                                       |
| -------------------------- | ----------------------------------------------- |
| **Gas costs**              | Operational expense, not security vulnerability |
| **Temporary DOS**          | Acceptable; recovery procedures exist           |
| **Slippage within limits** | Bounded by configuration; operational cost      |

---

## Security Invariants

The following invariants must always hold:

1. **Funds stay in system** - ALMProxy balance can only decrease through governance-approved operations
2. **Rate limits enforced** - No operation can exceed its configured rate limit
3. **Whitelist enforced** - Only configured addresses can be interacted with
4. **Allocator role admin can halt** - The admin of `ALLOCATOR_ROLE` can always revoke `ALLOCATOR_ROLE` from any allocator
5. **Governance supreme** - `DEFAULT_ADMIN_ROLE` can always recover funds and reconfigure system

---

## Audit Focus Areas

**Focus on:**

1. Rate limit bypass - Can any path avoid rate limit checks?
2. Whitelist bypass - Can unconfigured addresses be used?
3. Fund extraction - Can funds leave the PAU system unexpectedly?
4. Slippage manipulation - Can `maxSlippage` checks be bypassed?
5. Access control - Are role checks correctly implemented?

**Do NOT focus on:**

- Gas optimization (unless it affects security)
- DOS prevention (accepted risk, but still preferable to be mitigated if possible)
- Theoretical attacks requiring governance compromise
