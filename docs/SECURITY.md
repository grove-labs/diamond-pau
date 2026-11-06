# Security

This document describes protocol-specific security considerations for PAU.

## Trust Assumptions

### Role Trust Levels

| Role                    | Trust Level               | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| ----------------------- | ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `DEFAULT_ADMIN_ROLE`    | **Fully trusted**         | Run by governance                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `ALLOCATOR_ROLE`        | **Assumed compromisable** | Logic must prevent unauthorized value movement. This should be a major consideration during auditing engagements.                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| Allocator role admin    | Trusted                   | The role (or module holding the role) that governance sets as the admin of `ALLOCATOR_ROLE`. Can grant and revoke `ALLOCATOR_ROLE`, including emergency revocation of a compromised allocator.                                                                                                                                                                                                                                                                                                                                                                                               |
| `MIDNIGHT_FREEZER_ROLE` | **Assumed compromisable** | Held by the incident freezer key. Reaches exactly two levers, `disableMake(marketId)` and `cancelOfferGroup`: it can halt maker mode on any market, and disable it again after each admin re-enable, but cannot enable or raise `maxMakeOfferSize` or move value. The Midnight freezer (`MIDNIGHT_FREEZER_ROLE` in `AccessControls`) can also cancel an offer group, which retires the group permanently. It cannot un-cancel a group. Its role admin is `DEFAULT_ADMIN_ROLE` unless governance calls `setRoleAdmin`, so revoking it is a governance action. |

### Allocator Compromise Mitigations

When assuming a compromised `ALLOCATOR`:

1. **Value movement restrictions:** Smart contract logic must prevent movement of value outside the PAU system of contracts
    - Exception: Asynchronous integrations (e.g., BUIDL) where `transferAsset` sends funds to whitelisted addresses, with LP tokens minted asynchronously, or OTC trades.

2. **Loss limitations:** Any action must be limited to "reasonable" slippage/losses/opportunity cost by rate limits

3. **Emergency response:** The allocator role admin must be able to stop harmful actions within max rate limits by revoking `ALLOCATOR_ROLE` from the compromised account

4. **DOS attacks:** A compromised allocator can perform DOS attacks. Recovery procedures are outlined in `Attacks.t.sol` test files.

For comprehensive threat modeling, attack vectors, and trust assumptions, see [Threat Model](./THREAT_MODEL.md).

---

## Protocol-Specific Considerations

### Ethena Integration

**Trust Assumption:** Ethena is a trusted counterparty in this system.

**Scenario:** An operation initiated by an allocator can continue after the allocator is revoked.

**Implication:** If the allocator role admin revokes `ALLOCATOR_ROLE` from an allocator while an Ethena mint/burn operation is pending, that operation will still complete.

**Rationale:**

- Ethena operations are asynchronous by design
- The delegated signer role provides sufficient safeguards (trusted to not honor requests with >50bps slippage)
- Ethena's API [Order Validity Checks](https://docs.ethena.fi/solution-design/minting-usde/order-validity-checks) provide protection against malicious delegated signers
- Worst-case loss is bounded by slippage limits and rate limits on the operation

**Security Note:** The delegated signer role can technically be set by a compromised allocator. Ethena's off-chain validation is trusted to prevent abuse in this scenario.

### EtherFi/weETH Integration

**Trust Assumption:** EtherFi is trusted to eventually process withdrawal requests.

**Risk:** Withdrawal requests can be invalidated by EtherFi admin without returning funds, but can also be revalidated.

**Architecture Note:** The weETH integration requires a dedicated `WEETHModule` contract to handle withdrawal NFTs and ETH conversion. See [weETH Integration](./WEETH_INTEGRATION.md) for details.

### OTC Desk Integration

**Trust Assumption:** All whitelisted exchanges/OTC desks will complete trades (no counterparty risk beyond slippage).

**Maximum Loss:** Bounded by single outstanding OTC swap amount per exchange.

See [Liquidity Operations](./LIQUIDITY_OPERATIONS.md) for OTC mechanics.

### Centrifuge Integration

**Architecture Note:** Each Centrifuge cancel and claim-cancel path is gated by its own dedicated rate-limit key, each presence-checked via `_requireRateLimitExists`. Every key must be configured by governance before the corresponding path can be used.

**Security Node:** If a cancel key is set but its matching claim-cancel key is not, `cancel*Request` will succeed and `claimCancel*Request` will then revert. Because Centrifuge requests use `REQUEST_ID = 0`, no new deposit or redeem request can be submitted while a cancellation is pending, so the integration stays stuck until governance configures the missing claim-cancel key.

### Midnight Integration

**Trust Assumption:** The Midnight singleton is immutable and has no owner over positions or funds. Its `configurator` can enable collateral tiers, replace itself and appoint a `feeSetter`, a `feeClaimer` and a `tickSpacingSetter`; none of them can touch a lender's position or move its loan tokens. The facet is pinned to one singleton at construction, so repointing it takes a new facet and a spell.

**Risk:** Lender losses are socialized. A liquidation that cannot cover a borrower's debt writes the shortfall down across every lender in that market through a monotone `lossFactor`, so an oracle failure on any collateral tier is a lender loss. `maxLossFactor` gates entry only; a position already held cannot be shielded from it.

**Maximum Loss:** The credit outstanding in a market, if its collateral tiers fail and liquidations fall short of the debt. Entry is bounded per market by `LIMIT_MIDNIGHT_BUY`, which no exit restores.

**Maker Mode:** Resting the proxy's own offers moves two things outside this repository's reach. Authorizing a ratifier on the singleton is a blanket grant: the same `isAuthorized` entry also permits `withdraw`, `repay`, `supplyCollateral`, `withdrawCollateral`, `setConsumed` and `setIsAuthorized` on the proxy's behalf, so only a reviewed, non-upgradeable contract whose deployed runtime emits no external call at all should ever be authorized; that opcode scan is a precondition on the authorizing spell, not an assertion this suite can make. A maker exit then settles in a third party's transaction, so credit can leave the position with no code of ours in the stack: the ratifier's receiver invariant, `fundFill`'s price floor and zero-debt post-condition, and the strategy and market keys for the direction are what bound it. Funding strategies are trusted code, onboarded per market and per direction by their `LIMIT_MIDNIGHT_STRATEGY_BUY` and `LIMIT_MIDNIGHT_STRATEGY_SELL` keys and offboarded by zeroing them. Both periphery contracts ship, and are audited, from the periphery repository.

**Trust Model:** A keyed strategy can call `fundFill` with no fill behind it. The entry branch then pays the strategy, each call capped by `maxMakeOfferSize` and in total by the lesser of its strategy buy key and the market buy key, plus their slopes until it is offboarded. A ratifier freeze does not stop that. Zeroing the strategy's keys stops that strategy, and zeroing `maxMakeOfferSize` stops every strategy on the market, fabricated calls included, because it is `fundFill`'s first check. A key at `type(uint256).max` is unlimited by design and still counts as onboarded, leaving `maxMakeOfferSize` per fill and the market key as the bound. The market buy key is kept finite, which is the intended configuration; unlimited keys stay technically possible, but unlimited buy keys plus a faulty strategy expose the proxy's whole loan-token balance. A strategy holding `ALLOCATOR_ROLE` adds the whole allocator surface: every rate limit the role can spend, which only revoking the role ends. Per fill, the loan token `fundFill` sends it is bounded by the lesser of `maxMakeOfferSize`, its strategy key and the market key, and a venue key binds only what its sourcing draws through that venue. The role is granted and revoked by the allocator role admin, whichever role `setRoleAdmin` names (`ALLOCATOR_ADMIN_ROLE` in the reference deployment), and `DEFAULT_ADMIN_ROLE` can always reassign it.

**Kill Switch:** The ratifier's `freeze()`, held by its `FREEZER_ROLE`, is the maker kill switch on both hosts: it stops new ratified maker fills in both directions, and only the ratifier admin can `unfreeze()`. Each host and chain has its own ratifier bound to one proxy and one controller, and `freeze()` stops only the ratifier it is called on. It does not stop a keyed strategy calling `fundFill` directly; zeroing that strategy's keys stops it, and zeroing `maxMakeOfferSize` stops every strategy on the market. The Midnight freezer (`MIDNIGHT_FREEZER_ROLE` in `AccessControls`) can disable making on a market with `disableMake(marketId)`, which sets `maxMakeOfferSize` to zero and changes nothing else; it reads nothing from Midnight and stops every strategy on that market, fabricated `fundFill` calls included. Only the admin can enable making again, through the market config setter. The Midnight freezer (`MIDNIGHT_FREEZER_ROLE` in `AccessControls`) can also cancel an offer group, which retires the group permanently. Runbook: 1) freeze every ratifier authorized for the affected proxy, a single one under the operating rule below; 2) before any proxy freeze, the Midnight freezer calls `disableMake` or the admin deauthorizes the ratifier, and an allocator or the Midnight freezer cancels the groups the quoter uses, because a proxy freeze stops maker buys but not maker sells and blocks `cancelOfferGroup` and `setRatifierAuthorization`; 3) governance zeroes the strategy keys and the allocator role admin revokes any operator role. A compromised quoter can sign offers in groups nobody has seen, so cancelling the groups the quoter uses does not retire them; the ratifier freezer calls `removeQuoter` on that key before any `unfreeze()`.

**One Ratifier per Proxy:** Exactly one ratifier is authorized per proxy. This is an operating rule, not a code check. Swapping ratifier logic means deploying a new ratifier, granting it its roles (quoter, freezer, manager), then authorizing it and deauthorizing the old one in the same governance action. Offers signed for the old ratifier die with its deauthorization, since the ratifier address is part of the offer.

**Proxy Freeze:** The deployment runs on the standard `ALMProxy` (`PAU_PROXY`, with `PAU_CONTROLLER` holding `CONTROLLER`), not on `ALMProxyFreezable`. A proxy freeze is the proxy admin revoking the controller's `CONTROLLER` role, a governance action, so it is never the fast stop.

**Compromised Strategy:** The ratifier freeze does not stop a keyed strategy's fabricated `fundFill` calls. The Midnight freezer (`MIDNIGHT_FREEZER_ROLE` in `AccessControls`) can disable making on a market with `disableMake(marketId)`, which sets `maxMakeOfferSize` to zero and changes nothing else; it reads nothing from Midnight and stops every strategy on that market, fabricated `fundFill` calls included. Only the admin can enable making again, through the market config setter. That is the fast stop for any strategy, roleless ones included. For an operator-role strategy the `ALLOCATOR_ROLE` admin revokes the role through `AccessControls`, which ends its allocator surface but not its `fundFill` calls, since those carry no role gate. To offboard the strategy, the rate limits admin zeroes its strategy keys and the admin restores `maxMakeOfferSize` with `setMarketConfig`. Until the freezer acts, fabricated buys draw down the remaining buy keys plus their slopes, at most `maxMakeOfferSize` per call. Every lever is visible in the mempool, and a compromised strategy can draw the remaining buy budget in front of it, so send the freezer's and governance's transactions through a private relay.

**Rulebook A-1 and A-2:** `fundFill` has no role gate. It is a callback entry point reached from a third party's transaction, so no role can sit on its path; the caller's strategy key bounds it per market and direction, and an unset key reverts before any state change. This departs from A-1 and A-2; no exception has been requested yet.

**Rulebook A-1 and A-2, Midnight Freezer:** `MIDNIGHT_FREEZER_ROLE` is a role local to the Midnight facet, which departs from facet rulebook rule A-1 (`standards/FACET_RULEBOOK.md:162-166`), which allows no facet-defined role and no bespoke auth check. `disableMake` is gated on that role with `onlyRole(MIDNIGHT_FREEZER_ROLE)`. `cancelOfferGroup` carries `nonReentrant` without `onlyRole` and checks its caller's role in a private helper. That departs from the deterministic part of A-2 (`standards/FACET_RULEBOOK.md:168-173`). The intent of A-2 holds: only `DEFAULT_ADMIN_ROLE` can loosen anything, and the freezer can only zero `maxMakeOfferSize` or retire an offer group. The role reaches exactly these two levers, `disableMake` and `cancelOfferGroup`: `buy`, `sell` and `redeem` stay `ALLOCATOR_ROLE`, `cancelOfferGroup` also stays open to `ALLOCATOR_ROLE`, and every other Midnight setter stays `DEFAULT_ADMIN_ROLE`. The `AccessControls` admin grants it in the spell to the incident freezer key. The role getter is not wired on `PAU_CONTROLLER`; the spell grants `keccak256("MIDNIGHT_FREEZER_ROLE")` = `0x734f97facdc17c5a0364162ede289ef3fc7501314999442287d4c3f97235a585`. No exception to A-1 and A-2 has been requested yet.

**External Audits:** Eleven reports under `morpho-org/midnight/audits/` at the pinned commit `70607569ac348e9880b512ffd3b574be55405932` (Spearbit, Cantina competition, Blackthorn, TrustSec, Stermi; 2026-04 through 2026-09), which is the code deployed as the mainnet singleton.

See [Midnight Integration](./MIDNIGHT_INTEGRATION.md) for the facet's controls, price and fee rails, and failure modes.

---

## Governance and Emergency Controls

### ETH Recovery Mechanism

**Guarantee:** Any ETH left in the `ALMProxy` can always be removed.

| Method                              | Access       | Description                                                              |
| ----------------------------------- | ------------ | ------------------------------------------------------------------------ |
| `ALMProxy.doCallWithValue`          | `CONTROLLER` | Allows arbitrary calls with ETH value attached from `ALMProxy`.          |
| `ALMProxyFreezable.doCallWithValue` | `ALLOCATOR`  | Allows arbitrary calls with ETH value attached from `ALMProxyFreezable`. |
| `WrapProxyETHFacet.wrapAll`         | `ALLOCATOR`  | Wraps all ETH in `ALMProxy` to WETH.                                     |

**Use Cases:**

- Recover accidentally sent ETH
- Withdraw ETH received from protocol operations
- Convert ETH to WETH for standard token handling
- Emergency fund extraction

**Security:**

- `ALMProxy.doCallWithValue` is gated by the `CONTROLLER` role, which is held only by the `Controller` contract. A compromised allocator can therefore only reach this function indirectly through facets wired into the `Controller`, where rate limits and per-facet logic apply.
- `ALMProxyFreezable.doCallWithValue` is gated by the `RELAYER` role directly and is callable by a compromised relayer. `ALMProxyFreezable` is not intended to hold funds, and the `FREEZER` role can revoke a compromised relayer via `removeRelayer` to halt further calls.
- Facet functionality gated by the `ALLOCATOR_ROLE` is protected by rate limits and other safeguards.
- `wrapAll` is accessible to allocators but only converts ETH to WETH within the `ALMProxy`, keeping funds in the system.

---

## Audit Considerations

### Gas Fee Losses

**Stated Assumption:** Gas fee losses are ignored for security audit purposes.

**Rationale:**

- Gas fees are operational costs, not security vulnerabilities
- Gas fee griefing by a compromised allocator is bounded by block production and MEV considerations
- Economic impact is minimal compared to rate-limited capital protection

**Implication:** Audits should focus on capital preservation and rate limit effectiveness.

---

## Operational Requirements

For detailed operational requirements including seeding, configuration, and onboarding checklists, see [Operational Requirements](./OPERATIONAL_REQUIREMENTS.md).

### Beacon Governance Surface

The Beacon manages all integration configurations (facet addresses and selector wiring) for every Controller that references it. Only the `DEFAULT_ADMIN_ROLE` on the Beacon can call `setIntegration` or `removeIntegration`. This is a critical security boundary: if a malicious integration were configured, the facet would gain arbitrary access to Controller storage and ALMProxy funds via `delegatecall`. The Beacon validates that facet addresses are non-zero and have deployed code, and protects hardcoded selectors from being overwritten. Auditors should verify that no path exists to bypass these validations, and that the admin-only gate on integration management cannot be circumvented.

---

## Audits

Audit reports are available in the [`audits/`](../audits/) directory. The system has been audited by:

- Cantina
- ChainSecurity
- Certora
- Unvariant

Each version release includes corresponding audit reports from these security firms.
