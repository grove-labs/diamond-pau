# Security

This document describes protocol-specific security considerations for PAU.

## Trust Assumptions

### Role Trust Levels

| Role                 | Trust Level               | Description                                                                                                                                                                                    |
| -------------------- | ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `DEFAULT_ADMIN_ROLE` | **Fully trusted**         | Run by governance                                                                                                                                                                              |
| `ALLOCATOR_ROLE`     | **Assumed compromisable** | Logic must prevent unauthorized value movement. This should be a major consideration during auditing engagements.                                                                              |
| Allocator role admin | Trusted                   | The role (or module holding the role) that governance sets as the admin of `ALLOCATOR_ROLE`. Can grant and revoke `ALLOCATOR_ROLE`, including emergency revocation of a compromised allocator. |

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

**Trust Model:** A keyed strategy can call `fundFill` with no fill behind it. The entry branch then pays the strategy, bounded by the lesser of its strategy buy key and the market buy key, plus their slopes until it is offboarded. A ratifier freeze does not stop that; zeroing the strategy's keys does. A key at `type(uint256).max` is unlimited by design and still counts as onboarded, leaving `maxOfferSize` per fill and the market key as the bound. A strategy holding `ALLOCATOR_ROLE` adds the whole allocator surface: per fill it is bounded by the lesser of its strategy key, the market key and each venue key its sourcing touches, and the role is granted and revoked by the allocator role admin.

**Kill Switch:** The facet has no freezer. The ratifier's `freeze()`, held by its `FREEZER_ROLE`, is the maker kill switch on both hosts: it stops new ratified maker fills in both directions, and only the ratifier admin can `unfreeze()`. It does not stop a keyed strategy calling `fundFill` directly; only zeroing that strategy's keys does. Runbook: 1) freeze the ratifier; 2) before any proxy freeze, the admin zeroes `maxOfferSize` or deauthorizes the ratifier and an allocator cancels the designated groups, because a proxy freeze stops maker buys but not maker sells and blocks `cancelOfferGroup` and `setRatifierAuthorization`; 3) governance zeroes the strategy keys and the allocator role admin revokes any operator role.

**Rulebook Exception:** `fundFill` has no role gate, a documented exception to facet rulebook rules A-1 and A-2 for callback entry points reached from a third party's transaction. The strategy key bounds it per market and direction exactly as a role would, and an unset key reverts before any state change. An upstream exemption for callback entry points is being requested separately.

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
