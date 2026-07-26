---
label: Glossary
order: 10
---

# Glossary

Domain terms used across this reference, defined against the code that implements them. Alphabetical.

### Bootstrap

The provisioning harness package (`@lending/bootstrap`). Builds a `ProvisionedEnvironment` from a `Config`: derives accounts, submits the setup transactions in order, and persists the result. Entry point `provision()` (`provision.ts:45`).

### Broker (LoanBroker)

The on-ledger object (XLS-66 `LoanBrokerSet`) that attaches lending to a vault: it tracks `CoverAvailable`, `DebtTotal`, `DebtMaximum`, `CoverRateMinimum`, and `CoverRateLiquidation`, and is owned by the same account as its vault (`steps.ts:210-217`; read via `account_objects type:"loan_broker"`, `ledger-lookups.ts:24,32`). A single-owner invariant asserts the broker's `Owner` matches the vault's `Owner` (`assertions.ts:13-26`).

### Bot (occupant)

One of the three states an `Occupant` can hold for a seat: `{ kind: "bot" }` — the seat's account is driven autonomously rather than by a human. Assigned to any open seat via `fillWithBot` (`seat.ts:57-59`); stands down automatically once a human claims the seat (`seat.ts:38-40`).

### Cover / first-loss cover

Broker-held capital, deposited via `LoanBrokerCoverDeposit`, that absorbs losses before depositors do. Seeded during provisioning (`depositCover`, `steps.ts:224-249`) and asserted to meet the broker's minimum requirement post-seed (`assertCoverMeetsMinimum`, `assertions.ts:28-45`). `CoverRateMinimum` / `CoverRateLiquidation` are scaled integers where `100000` = 100% (`config/schema.ts:27-30`), with the invariant `coverRateLiquidation ≤ coverRateMinimum` enforced by schema (`config/schema.ts:108-115`).

### Credential

An XLS-70 ledger object (`account_objects type:"credential"`) attesting that a `Subject` was credentialed by an `Issuer` for a given `CredentialType` (`ledger-lookups.ts:48`, `state-service.ts:82`). Created via `CredentialCreate` and inert until the subject submits `CredentialAccept`, which sets `lsfAccepted = 0x00010000` (`ledger-lookups.ts:62`; XLS-70). Membership checks are always against the credential issuer, never the currency issuer (`state-service.ts:77-84`).

### Credential-issuer vs. currency-issuer split

A deliberate design point: two distinct derived accounts. The currency issuer mints the vault's asset (IOU) and holds clawback/`DefaultRipple` powers (`steps.ts:82-96,116`); the credential issuer grants domain credentials and is derived only for a permissioned session (`accounts.ts:8`, rationale at `accounts.ts:4-7`; derivation gated at `accounts.ts:36,55`). The domain's `AcceptedCredentials` names the credential issuer, not the currency issuer (`steps.ts:156-159`). Keeping them separate means the raw ledger stays legible — a currency-signing key is never also a credentialing key.

### Deterministic derivation

Every account is derived, not randomly generated: `Wallet.fromEntropy` over the first 16 bytes of `SHA-256("xrpl-lending/account/v1\0{seed}\0{role}\0{index}")` (`accounts.ts:22-30`). The same `(seed, role, index)` always yields the same address, so a re-run of `provision()` reuses existing accounts and skips steps already applied on-ledger, rather than funding a fresh set each time.

### Domain (PermissionedDomain)

An XLS-80 ledger object (`account_objects type:"permissioned_domain"`, `ledger-lookups.ts:13`) listing up to 10 `AcceptedCredentials` entries, each an `{Issuer, CredentialType}` pair (`.max(10)`, `config/schema.ts:53-57`). Created via `PermissionedDomainSet` (`steps.ts:154-167`) naming the credential issuer (`steps.ts:156-159`). Its id, once captured, is pinned into `VaultCreate` as `DomainID` — this is what makes a vault permissioned (`steps.ts:166`→`:189`).

### Drops

The XRP Ledger's smallest unit of XRP (1 XRP = 1,000,000 drops). Reserve rates are read from `server_state` in integer drops rather than `server_info`'s float XRP, specifically to avoid floating-point error (`reserves.ts:18-25`). Funding math is kept in integer drops end-to-end for the same reason — rounding to XRP before summing accumulates error the ledger's drops conversion then rejects (`reserves.ts:82-86`).

### Engine

The HTTP service (`@lending/engine`, Fastify, port 4000) that fronts sessions: `POST /sessions` provisions, `/sessions/:id/actions` dispatches participant actions, `/sessions/:id/seats/:seat/claim|release` manages occupancy, `/sessions/:id/bots/start|stop` runs autonomous traffic (`app.ts:16-48`; route table in `.docsource/code-map.md`). Persists sessions, seat occupancy, and an action log to Postgres so state survives a restart (`store.ts`; models in `packages/engine/prisma/schema.prisma`), storing no private keys — only the seed and token needed to re-derive wallets (`schema.prisma:19-22`, `session-service.ts:164-177`).

### Environment (ProvisionedEnvironment)

The wired object graph a provisioning run produces: `setupId`, `network`, `asset`, the derived `accounts` (issuer, optional credentialIssuer, owner, depositors, borrowers), the on-ledger `objects` (domainId, vaultId, shareMptId, brokerId), and the `steps` taken to build it (`types.ts:20-44`). Whether it is permissioned is derived solely from `objects.domainId` being present — never from `credentialType` or `credentialIssuer`, which merely travel alongside it (`isPermissioned`, `types.ts:50-52`).

### Loan

An XLS-66 ledger object (`account_objects type:"loan"`) created bilaterally by `LoanSet` — the owner signs and the borrower counter-signs (`action-service.ts:188-232`; fields `LoanBrokerID`, `Counterparty`, `PrincipalRequested`, `InterestRate`, `PaymentInterval`, `GracePeriod`, `LoanOriginationFee`, `lifecycle/originate.ts:44-50`). Tracks `PaymentRemaining`, `NextPaymentDueDate`, `GracePeriod`, `PrincipalOutstanding`, `TotalValueOutstanding`, `PeriodicPayment`, and `Flags` (`state-service.ts:53-68`). Repaid via `LoanPay`; defaulted via `LoanManage` with `Flags: tfLoanDefault (65536)`, only after `NextPaymentDueDate + GracePeriod` has passed — earlier attempts return `tecTOO_SOON` (`state-service.ts:57-59`, `owner-variants.ts:126-130`).

### Occupant

The state of a seat: `{kind:"open"}`, `{kind:"bot"}`, or `{kind:"human", id}` (`seat.ts:7-9`). Occupancy is exclusive — exactly one party drives a seat's account at any instant, preserving the one-account-one-signer rule on-chain (`seat.ts:5-6`).

### Participant

The human identity (an `id` string) that can claim a seat. `claim(seat, humanId)` transitions occupancy to `{kind:"human", id: humanId}`; a seat already held by a different human rejects the claim (`seat.ts:38-44`). `release` returns a held seat to open (`seat.ts:47-52`).

### Permissioned vault vs. public vault

A vault is permissioned if it was created with a `DomainID` and `Flags: tfVaultPrivate (65536)`; it is public if created with neither (`steps.ts:169-193`). The presence of `domainId` is the sole switch between the two modes — checked once in `isPermissioned` and never re-derived from other fields (`types.ts:50-52`, `steps.ts:173-174`, `action-service.ts:143`). A permissioned vault's deposits are domain-gated (rejected `tecNO_AUTH` without an accepted credential); a public vault accepts deposits from anyone.

### Provisioning

The end-to-end sequence that stands up an `Environment`: derive accounts → fund via treasury fan-out → (IOU only) issuer flags, trust lines, distributions → (permissioned only) `CredentialCreate` → `CredentialAccept` → `PermissionedDomainSet` → `VaultCreate` → `LoanBrokerSet` → assert single owner → `LoanBrokerCoverDeposit` → assert cover meets minimum (`provision.ts:71-121`). Idempotent: each step's `alreadyDone` check skips work already reflected on-ledger.

### Reserve

The XRP an account must hold to own ledger objects: a base reserve plus an increment per object, read live from `server_state` (`reserves.ts:18-25`). `roleReserveDrops(role, shape, rates)` computes each role's minimum funding as `baseDrops + incDrops × peakObjectCount(role, shape) + 2,000,000` (2 XRP fee headroom) (`reserves.ts:77,84-86`), so accounts are funded to what they actually need rather than a flat amount — keeping the raw ledger legible for review.

### Role

The fixed enum of positions in a provisioned environment: `"issuer" | "credentialIssuer" | "owner" | "depositor" | "borrower"` (`accounts.ts:8`). The issuer mints the asset; the credential issuer (permissioned only) grants domain credentials; the owner owns both the vault and the broker; depositors supply liquidity; borrowers take loans (`accounts.ts:4-7`).

### Seat

One role slot in a session, bound to a single on-chain account: `{role, index, address, signer, occupant}` (`seat.ts:12-18`). Addressed by a stable key `"role:index"` (e.g. `"depositor:0"`) via `seatKey`/`keyOf` (`seat.ts:22-27`). The signer is how the seat's account acts, independent of who currently occupies it.

### Session

A provisioned environment plus its seat map: `{setupId, network, seed, env, seats, client}` (`session.ts:10-17`). Created by provisioning a fresh environment and building one bot-filled seat per role, each backed by a `ServerSigner` over its derived account (`session.ts:19-21`). Humans claim seats to take over roles from bots.

### setupId

The identifier for one provisioning run, either supplied in config or generated (`config.setupId ?? generateSetupId()`, `provision.ts:48`). Config schema bounds it to 1–64 characters (`config/schema.ts:42`). Re-provisioning with the same `seed` and `setupId` reuses the same derived accounts and skips already-applied steps.

### Submit batcher (submitBatch)

`submitBatch(client, items)` (`client.ts:113-190`) submits many transactions across the minimum number of ledgers: transactions are grouped by signing account, each account's `Sequence` is fetched once and assigned locally (N, N+1, …) so a single account's transactions land in one ledger (`client.ts:147`), all share `LastLedgerSequence = current + 40` (`client.ts:148`), submissions are fire-and-forget then polled for validation in parallel (`client.ts:170-179`). Capped at `MAX_PER_ACCOUNT_PER_LEDGER = 8` per account per attempt, with overflow carried to the next attempt rather than treated as an error (`client.ts:111,137-139`); retryable engine results (`terQUEUED`, `terPRE_SEQ`, `tefPAST_SEQ`, `tecINSUFFICIENT_FEE`, `tel*`) are retried up to `MAX_ATTEMPTS = 4` via `classifyResult`, while any other failure is fatal and throws the whole batch (`client.ts:85-96,116`).

### The four amendments

- **XLS-65 (Single Asset Vault)** — the vault itself: `VaultCreate`/`VaultDeposit`/`VaultWithdraw`/`VaultSet`/`VaultDelete`/`VaultClawback`, and the share-MPT accounting described under *vault share* below.
- **XLS-66 (Lending Protocol)** — the broker and loan objects: `LoanBrokerSet`/`LoanBrokerCoverDeposit`/`LoanBrokerCoverWithdraw`/`LoanBrokerDelete`, `LoanSet`/`LoanPay`/`LoanManage`/`LoanDelete`.
- **XLS-70 (Credentials)** — `CredentialCreate`/`CredentialAccept`/`CredentialDelete` and the accepted-credential membership check.
- **XLS-80 (Permissioned Domains)** — `PermissionedDomainSet`/`PermissionedDomainDelete`, which gate vault access via `DomainID`.

All four are consumed via `xrpl@5.0.0` (`.docsource/amendment-map.md:3`).

### Vault share (MPToken)

The vault's ownership unit, issued as a Multi-Purpose Token (`ShareMPTID` captured at `steps.ts:196`). On first deposit, `Δshares = Δassets × 10^Scale` (Scale defaults to 6 for IOU, 0 for XRP); every subsequent deposit is proportional: `Δshares = (Δassets × Γshares) / Γassets`, rounded down (`.docsource/amendment-map.md:14`). A holder's share balance is its `MPToken` object where `MPTokenIssuanceID` matches the vault's `shareMptId`, read as the `MPTAmount` field (`balances-service.ts:65-70`). Total shares outstanding is the `OutstandingAmount` on the `MPTokenIssuance`, read via `ledger_entry mpt_issuance` (`.docsource/amendment-map.md:14`, ingester `state.ts:61-66`).
