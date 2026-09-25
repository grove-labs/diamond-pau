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

2. **Losses bounded by rate limits** - Any single attack is limited to the current rate limit capacity

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
| **Morpho Midnight** | Maker callback runs inside the proxy's `take` while the batch approval is open, and may move market state (take, withdraw, authorize, repay, liquidate a third borrower) | Reentrancy guard held for the whole batch; approval is exactly `maxAssetsIn` and Midnight only pulls from the proxy on the proxy's own flows; exact credit-delta, zero-debt and `maxAssetsIn` post-checks unwind any batch whose outcome differs from the fills requested |
| **Morpho Midnight** | Socialized bad debt (`lossFactor`) writes down every lender's credit, including mid-transaction                                               | Entry gated by per-market `maxLossFactor` (default zero); sell sizes capped at live credit so a write-down can never leave the proxy in debt; exits never blocked                                               |
| **Morpho Midnight** | Sell offer naming the ALMProxy as proceeds receiver nets the spend to the fee and under-reports it to the rate limit                          | `receiverIfMakerIsSeller != proxy` enforced on every buy leg                                                                                                                                                   |
| **Morpho Midnight** | Fee setter raises settlement or continuous fee between configuration and trade                                                                | Price bounds are fee-adjusted at call time and fail closed; continuous fee gated on entry by `maxContinuousFee`; both fees sit inside the implied-yield bounds, so a fee rise re-prices them instead of leaving them stale, though within hours of maturity the sell floor plus the fee can exceed par and wedge `sell` until the fee falls or `maxSellYield` widens (`redeem` is unaffected); exits unaffected by fee gates                                                                  |
| **Morpho Midnight** | Rogue allocator sells credit into a maker's buy offer at a deep discount while a par exit is available, handing the difference to the maker. Per-call `minAssetsOut` is no defence: the caller chooses it | Governance `maxSellYield` caps the implied yield an exit may give up for the term actually left, and `minSellTick` floors the absolute price. The yield floor converges on par as maturity approaches, so a post-maturity dump is refused outright and the exit is `redeem`. Sizing is still capped by `LIMIT_MIDNIGHT_SELL` |
| **Morpho Midnight** | Rogue allocator enters at a price whose yield does not compensate for the term, or above what a unit returns net of the continuous fee | Governance `minBuyYield` bounds the all-in entry price in rate terms and `maxBuyTick` bounds it absolutely; a zero `minBuyYield` still refuses any price above the unit's payoff |
| **Morpho Midnight** | Fee claimer withdraws accrued continuous fee out of a market's repayment pool, competing with lenders for `withdrawable`                       | Redemption units are capped at live `withdrawable` and bounded by `minAssetsOut`; the claim is a timing cost on redemption, not a write-down (credit is untouched); the sell path remains the exit           |
| **Morpho Midnight** | Offer market from calldata names a different venue or market than governance onboarded                                                       | Every call is pinned to the immutable singleton; each offer's market must hash to the governance-supplied `marketId`, which commits to venue, loan token, maturity, collateral tiers and gates; keys are salted by that id only |

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
