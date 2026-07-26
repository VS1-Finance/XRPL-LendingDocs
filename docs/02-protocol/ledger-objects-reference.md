---
label: Ledger Objects
order: 40
---

# Ledger Objects Reference

Every ledger object this system reads or writes, in one place: the `account_objects` type filter (or
`ledger_entry` request) used to fetch it, the XLS amendment that defines it, and the exact fields the
reference implementation consumes, cited to the reading code. For the transactions that create and
mutate these objects, see [XLS-65](./xls65-single-asset-vault.md), [XLS-66](./xls66-lending-protocol.md),
[XLS-70](./xls70-credentials.md), and [XLS-80](./xls80-permissioned-domains.md). For how a running
session's state and account balances are assembled from these reads end to end, see
[State and Balances](../03-architecture/state-and-balances.md).

## Summary

| Object | `account_objects` type / request | Amendment | Where read (this codebase) |
|---|---|---|---|
| Vault | `type:"vault"` | XLS-65 | `ledger-lookups.ts:17-22`, `state-service.ts:46,95,107-109` |
| MPTokenIssuance (vault shares, total) | `ledger_entry` with `mpt_issuance` | XLS-65 | `ingester/src/state.ts:61-67` |
| MPToken (vault shares, holder balance) | `type:"mptoken"` | XLS-65 | `balances-service.ts:65-70` |
| LoanBroker | `type:"loan_broker"` | XLS-66 | `ledger-lookups.ts:24-39`, `state-service.ts:47,96,107-109`, `assertions.ts:13-26,36-44` |
| Loan | `type:"loan"` | XLS-66 | `state-service.ts:51-70` |
| Credential | `type:"credential"` | XLS-70 | `ledger-lookups.ts:42-58`, `state-service.ts:78-91` |
| PermissionedDomain | `type:"permissioned_domain"` | XLS-80 | `ledger-lookups.ts:12-15` |

> [!NOTE]
> `LSF_LOAN_DEFAULTED` (on the **Loan** object) and `LSF_CREDENTIAL_ACCEPTED` / `lsfAccepted` (on the
> **Credential** object) are both the bit value `0x00010000` — but they are distinct flags on distinct
> object types with unrelated meanings. `state-service.ts:30-31` defines both as separate local
> constants precisely because they collide numerically; nothing links them, and the same bit value
> being set on a Loan says nothing about any Credential, and vice versa. Do not conflate them when
> reading flag checks in this codebase or in ledger data.

## Vault

XLS-65 Single Asset Vault. One vault is created per session, owned by the `owner` account
(`ledger-lookups.ts:17-22`, `steps.ts:169-193` per the amendment map).

Fetched with `account_objects account:<owner> type:"vault"` and taking the first result
(`ledger-lookups.ts:18`, `state-service.ts:46` via the shared `firstObject` helper at
`state-service.ts:107-109`).

| Field | Used for | Cited at |
|---|---|---|
| `index` | The vault's object ID, captured into `env.objects.vaultId` for later steps (broker creation reads it back) | `ledger-lookups.ts:17-22` |
| `ShareMPTID` | The vault's share MPT issuance ID, captured into `env.objects.shareMptId`; used to look up each holder's share balance and the share total | `ledger-lookups.ts:21`, `steps.ts:196` (amendment map) |
| `AssetsTotal` | Rendered in session state as the vault's total assets (converted from drops to whole XRP for an XRP vault) | `state-service.ts:95` |
| `AssetsAvailable` | Rendered in session state as the vault's available (undeployed) assets | `state-service.ts:95` |
| `AssetsMaximum` | Set (not read back) by `VaultSet` to cap vault size | amendment map, `steps.ts:138` (`VaultSet`) — not read in `state-service.ts`/`balances-service.ts` |
| `Scale` | Power-of-10 multiplier between asset units and integer shares; read by the ingester when projecting vault state to base units | `ingester/src/state.ts:47` (`Number(vault.Scale ?? 0)`) |

> [!NOTE]
> `AssetsMaximum` is written by the engine's `set-vault` action (`VaultSet`, `action-service.ts:132-139`
> per the amendment map) but this codebase's state/balances readers do not read it back — only
> `AssetsTotal`/`AssetsAvailable`/`ShareMPTID` are consumed from the Vault object at read time.

## MPTokenIssuance and MPToken (vault shares)

XLS-65 defines vault shares as an MPT (Multi-Purpose Token): the vault owns one `MPTokenIssuance`
(the share class), and each depositor holds an `MPToken` object recording their share balance. Two
different request shapes are used depending on whether the total or a single holder's balance is
needed.

**MPTokenIssuance — total shares outstanding.** Fetched with `ledger_entry mpt_issuance:<shareMptId>`,
not `account_objects` (the vault object itself carries no share total) (`ingester/src/state.ts:61-67`):

| Field | Used for | Cited at |
|---|---|---|
| `OutstandingAmount` | Total vault shares currently in issue, converted to a `bigint` | `ingester/src/state.ts:66` |

**MPToken — a holder's share balance.** Fetched with
`account_objects account:<holder> type:"mptoken"`, then filtered to the one issuance matching the
vault's share MPT ID:

| Field | Used for | Cited at |
|---|---|---|
| `MPTokenIssuanceID` | Matched against the vault's `ShareMPTID` to select this holder's share MPToken among any others they hold | `balances-service.ts:69` |
| `MPTAmount` | The holder's share balance in base units, returned as a string (`"0"` if no matching MPToken exists) | `balances-service.ts:70` |

> [!NOTE]
> Per `.docsource/XLS-VERIFICATION.md` (confirmed against the XLS-65 spec text): `Scale` defaults to 6
> for an IOU vault and is 0 for an XRP vault. First deposit into an empty vault mints
> `Δshares = Δassets × 10^Scale`; every subsequent deposit is proportional,
> `Δshares = (Δassets × Γshares) / Γassets`, rounded down. `MPTokenIssuance.AssetScale` mirrors the
> vault's `Scale` for an IOU vault and is 0 otherwise. This codebase does not assert these formulas in
> code — they are the protocol rule the observed 30,000 IOU → 30,000,000,000 shares result is
> consistent with.

## LoanBroker

XLS-66 Lending Protocol. One broker is attached to the vault, owned by the same `owner` account as
the vault (the single-owner invariant below).

Fetched with `account_objects account:<owner> type:"loan_broker"` and taking the first result
(`ledger-lookups.ts:24-39`, `state-service.ts:47`, `assertions.ts:14-19,36-38`).

| Field | Used for | Cited at |
|---|---|---|
| `index` | The broker's object ID, captured into `env.objects.brokerId` | `ledger-lookups.ts:24-27` |
| `CoverAvailable` | First-loss cover currently held; rendered in session state, checked against a required minimum after seeding cover, and read by lookup helpers used elsewhere in provisioning | `state-service.ts:96`, `assertions.ts:40-43`, `ledger-lookups.ts:31-39` |
| `Owner` | Compared against the vault's `Owner` to enforce the single-owner invariant (vault and broker must share one owner); falls back to the queried account address if the field is absent | `assertions.ts:21-24` |
| `DebtTotal` | Read by the ingester when projecting broker state (not read by `state-service.ts`/`ledger-lookups.ts`) | `ingester/src/state.ts:78` (`toBaseUnits(broker.DebtTotal, 6)`) |
| `DebtMaximum` | Set (not read back in this codebase's state/lookup readers) by `LoanBrokerSet` to cap total origination | amendment map, `steps.ts:215` |
| `CoverRateMinimum` | Set (not read back in this codebase's state/lookup readers) by `LoanBrokerSet`; used off-ledger in cover-headroom math from the configured value, not a ledger read | amendment map, `steps.ts:216`, `bots/reads.ts:148-167` |

> [!NOTE]
> `assertSingleOwner` (`assertions.ts:13-26`) is a provisioning-time invariant check in this codebase,
> not a protocol-enforced constraint we have verified rippled itself rejects — the reference
> implementation only ever creates one owner-derived account per session, so the two `Owner` fields
> are expected to match by construction; the assertion catches a bug in the harness, not an
> adversarial on-ledger state.

## Loan

XLS-66 Lending Protocol. One object per originated loan, owned by the borrower.

Fetched with `account_objects account:<borrower> type:"loan"`, once per borrower in the session
(`state-service.ts:51`):

| Field | Used for | Cited at |
|---|---|---|
| `Flags` | Masked against `LSF_LOAN_DEFAULTED = 0x00010000` to determine `defaulted` status | `state-service.ts:30,53` |
| `PaymentRemaining` | Number of payments left; used both for display and to gate `defaultableNow` (a fully-paid loan with `paymentRemaining <= 0` is never marked defaultable) | `state-service.ts:54,59,68` |
| `NextPaymentDueDate` | Combined with `GracePeriod` to compute the ripple-epoch timestamp after which the loan becomes defaultable | `state-service.ts:57` |
| `GracePeriod` | Added to `NextPaymentDueDate` to compute the defaultable-at timestamp | `state-service.ts:57` |
| `PrincipalOutstanding` | Rendered in session state as the loan's remaining principal | `state-service.ts:63` |
| `TotalValueOutstanding` | Rendered in session state as the loan's total remaining value (principal + accrued interest/fees) | `state-service.ts:64` |
| `index` | The loan's object ID, surfaced in session state as `loanId` | `state-service.ts:61` |

`state-service.ts:57-59` computes `defaultableAt = NextPaymentDueDate + GracePeriod` and compares it
to the current ripple-epoch time (`nowRipple()`, offset `946684800` from Unix epoch, `state-service.ts:34-35`);
`defaultableNow` is true only when the loan is not already defaulted, has payments remaining, and
`defaultableAt` has passed (`state-service.ts:59`).

> [!NOTE]
> Per `.docsource/XLS-VERIFICATION.md` item 3: the reference implementation observed `temINVALID` when
> submitting `LoanSet` with `PaymentInterval: "30"` / `GracePeriod: "1"` (both below 60 seconds) against
> Devnet, while `60`/`60` succeeded. The accessible XLS-66 spec text does not publish a documented
> minimum for either field — this is recorded as an **observed** rippled constraint, not an asserted
> protocol rule.

## Credential

XLS-70 Credentials. One object per (issuer, subject, credential type) triple.

Fetched with `account_objects account:<subject> type:"credential"`, once per credentialed
participant — depositors and borrowers only, and only for a permissioned session
(`state-service.ts:80-82`); also fetched per-subject during provisioning idempotency checks
(`ledger-lookups.ts:48`):

| Field | Used for | Cited at |
|---|---|---|
| `Issuer` | Matched against the session's **credential issuer** address (not the currency issuer) to select this participant's own credential among any others; also matched during provisioning idempotency checks | `state-service.ts:84`, `ledger-lookups.ts:51` |
| `Subject` | Matched against the queried account address, confirming the credential belongs to this participant | `state-service.ts:84`, `ledger-lookups.ts:52` |
| `CredentialType` | Matched against the expected hex-encoded credential type during provisioning idempotency checks | `ledger-lookups.ts:53` |
| `Flags` | Masked against `lsfAccepted = 0x00010000` to classify status as `"accepted"` vs `"pending"` (state-service) or as already-provisioned (ledger-lookups) | `state-service.ts:31,87`, `ledger-lookups.ts:60-63` |

Session-state status derivation (`state-service.ts:85-89`): no matching credential found →
`"none"`; found but `lsfAccepted` clear → `"pending"`; found with `lsfAccepted` set → `"accepted"`.

> [!NOTE]
> Membership is judged against the **credential issuer**, a derived account distinct from the
> **currency issuer** that mints the vault's IOU asset — `state-service.ts:78,84` compares
> `c.Issuer === credentialIssuer`, never the currency issuer. See the amendment map's
> "Credential-issuer vs currency-issuer split" and the [XLS-70](./xls70-credentials.md) page.

> [!NOTE]
> `lsfAccepted = 0x00010000` is a confirmed protocol fact (xrpl.org Credential ledger-entry reference:
> "the subject has accepted the credential", off by default, set by a successful `CredentialAccept`),
> per `.docsource/XLS-VERIFICATION.md` item 1. This is the **same bit value** as `LSF_LOAN_DEFAULTED`
> on the unrelated Loan object — see the note at the top of this page.

## PermissionedDomain

XLS-80 Permissioned Domains. One object per session, owned by the `owner` account, present only for
a permissioned (non-public) vault.

Fetched with `account_objects account:<owner> type:"permissioned_domain"`, taking the first result
(`ledger-lookups.ts:12-15`):

| Field | Used for | Cited at |
|---|---|---|
| `index` | The domain's object ID, captured into `env.objects.domainId` and pinned into the vault's `DomainID` at `VaultCreate` | `ledger-lookups.ts:12-15`, amendment map (`steps.ts:166`→`:189`) |

`ledger-lookups.ts` only reads `index` off this object in this codebase — the domain's
`AcceptedCredentials` list is written by `PermissionedDomainSet` (`steps.ts:154-165`,
`action-service.ts:141-158` per the amendment map) but is not read back by any reader cited in
`state-service.ts` or `balances-service.ts`.

## Read next

- [XLS-65 — Single Asset Vault](./xls65-single-asset-vault.md)
- [XLS-66 — Lending Protocol](./xls66-lending-protocol.md)
- [XLS-70 — Credentials](./xls70-credentials.md)
- [XLS-80 — Permissioned Domains](./xls80-permissioned-domains.md)
- [State and Balances](../03-architecture/state-and-balances.md)
