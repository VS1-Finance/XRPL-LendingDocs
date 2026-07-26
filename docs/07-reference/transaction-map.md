---
label: Transaction Map
order: 20
---

# Transaction Map

Cross-reference cheat-sheet: every action verb the engine exposes, the XRPL transaction and amendment it maps to, the ledger object it touches, and where that object is read back.

## Action verb → TransactionType

All 11 action verbs handled by `buildTransaction` / `originate` in `action-service.ts`.

| Verb | TransactionType | Amendment | Ledger object | Seat | Note | Source |
|---|---|---|---|---|---|---|
| `deposit` | VaultDeposit | XLS-65 | Vault | depositor | — | action-service.ts:77-83 |
| `withdraw` | VaultWithdraw | XLS-65 | Vault | depositor | — | action-service.ts:85-91 |
| `repay` | LoanPay | XLS-66 | Loan | borrower | Amount run through `clampIssuedValueUp` before send | action-service.ts:93-101 |
| `issue-credential` | CredentialCreate | XLS-70 | Credential | issuer | CredentialType hex-encoded from ASCII | action-service.ts:104-110 |
| `revoke-credential` | CredentialDelete | XLS-70 | Credential | issuer | — | action-service.ts:112-118 |
| `accept-credential` | CredentialAccept | XLS-70 | Credential | subject | Second half of issue/accept handshake; credential is inert until accepted | action-service.ts:123-129 |
| `set-vault` | VaultSet | XLS-65 | Vault | owner | Sets `AssetsMaximum` | action-service.ts:132-139 |
| `set-domain` | PermissionedDomainSet | XLS-80 | PermissionedDomain | owner | Swaps `AcceptedCredentials`; rejected on a public vault (no domain) | action-service.ts:141-158 |
| `manage-loan` | LoanManage | XLS-66 | Loan | owner | `Flags: tfLoanDefault (65536)` — defaults a delinquent loan | action-service.ts:162-168 |
| `deposit-cover` | LoanBrokerCoverDeposit | XLS-66 | LoanBroker | owner | Adds first-loss cover | action-service.ts:172-178 |
| `originate` | LoanSet | XLS-66 | Loan | owner + borrower | Bilateral: owner signs, borrower counter-signs via `signLoanSetByCounterparty`; wallets re-derived from session seed | action-service.ts:188-232 |


Seat/role guards on `originate`: the acting seat must be `role === "owner"`, and the named counterparty seat must be `role === "borrower"` — otherwise `ActionError` 409 (action-service.ts:197, 200). Every other verb is dispatched through `dispatchAction`, which requires the seat be held by the requesting participant before `buildTransaction` runs (action-service.ts:57-71). `asClientError` maps xrpl `ValidationError` and preliminary `tem` rejections to a 400; anything else surfaces as a 500 (action-service.ts:31-46).

## TransactionType → XLS amendment

Every transaction type this system submits, grouped by amendment, per `amendment-map.md`.

| Amendment | TransactionType | Where used | Source |
|---|---|---|---|
| XLS-65 (Single Asset Vault) | VaultCreate | provisioning | bootstrap/steps.ts:186 |
| XLS-65 | VaultDeposit | action `deposit`; lifecycle; bots | action-service.ts:79 |
| XLS-65 | VaultWithdraw | bots; negative N9 | action-service.ts:87 |
| XLS-65 | VaultSet | action `set-vault` | action-service.ts:134 |
| XLS-65 | VaultDelete | teardown | teardown.ts:46 |
| XLS-65 | VaultClawback | negative-suite N8 (IOU-only, adversarial) | negative-suite/src/cases/lending.ts:53 |
| XLS-66 (Lending Protocol) | LoanBrokerSet | provisioning | bootstrap/steps.ts:210 |
| XLS-66 | LoanBrokerCoverDeposit | provisioning (seed cover); action `deposit-cover` | bootstrap/steps.ts:247; action-service.ts:174 |
| XLS-66 | LoanBrokerCoverWithdraw | negative-suite N13 (tecINSUFFICIENT_FUNDS below floor) | negative-suite/src/cases/lending.ts:165 |
| XLS-66 | LoanBrokerDelete | teardown | teardown.ts:41 |
| XLS-66 | LoanSet | action `originate`; lifecycle; bots (bilateral) | action-service.ts:203 |
| XLS-66 | LoanPay | action `repay`; lifecycle; bots; negatives N11/N12 | action-service.ts:96 |
| XLS-66 | LoanManage | action `manage-loan`; bots; negative N14 | action-service.ts:164 |
| XLS-66 | LoanDelete | lifecycle close; negative N15 (tecHAS_OBLIGATIONS while active) | lifecycle/close.ts:28 |
| XLS-70 (Credentials) | CredentialCreate | provisioning; action `issue-credential` | bootstrap/steps.ts:140; action-service.ts:106 |
| XLS-70 | CredentialAccept | provisioning; action `accept-credential` | bootstrap/steps.ts:150; action-service.ts:125 |
| XLS-70 | CredentialDelete | teardown; action `revoke-credential` | teardown.ts:79; action-service.ts:114 |
| XLS-80 (Permissioned Domains) | PermissionedDomainSet | provisioning (create); action `set-domain` (swap AcceptedCredentials) | bootstrap/steps.ts:164; action-service.ts:146 |
| XLS-80 | PermissionedDomainDelete | teardown | teardown.ts:51 |


## Ledger object → account_objects filter → where read

| Ledger object | `account_objects` `type` filter | Read against | Where read | Source |
|---|---|---|---|---|
| Vault | `"vault"` | owner | `readSessionState` (state), `findVault` (provisioning idempotency) | state-service.ts:46,107-109; ledger-lookups.ts:17-22 |
| LoanBroker | `"loan_broker"` | owner | `readSessionState` (state), `findBrokerId`/`findBrokerCover` (provisioning) | state-service.ts:47; ledger-lookups.ts:24-39 |
| Loan | `"loan"` | each borrower | `readSessionState` (state) | state-service.ts:51 |
| Credential | `"credential"` | each depositor/borrower (permissioned only), judged vs credential issuer | `readSessionState` (state), `hasAcceptedCredential` (provisioning idempotency) | state-service.ts:78-91; ledger-lookups.ts:42-58 |
| PermissionedDomain | `"permissioned_domain"` | owner | `findDomainId` (provisioning idempotency) | ledger-lookups.ts:12-15 |
| MPToken (vault shares) | `"mptoken"`, matched on `MPTokenIssuanceID === shareMptId` | each seat | `readShares` in `readBalances` | balances-service.ts:65-75 |


Two additional non-`account_objects` reads feed balances: `account_info` for XRP balance (balances-service.ts:42-50) and `account_lines` (peer = issuer) for IOU trust-line balance (balances-service.ts:53-62); both return `"0"` on `actNotFound` rather than throwing (balances-service.ts:77-80). `account_lines` is also how `ledger-lookups.ts` checks/reads trust lines during provisioning (`hasTrustLine` ledger-lookups.ts:67-80, `issuedBalance` ledger-lookups.ts:83-97).

Flag bits used across these objects: `lsfAccepted` / `LSF_CREDENTIAL_ACCEPTED` = `0x00010000` (state-service.ts:31; ledger-lookups.ts:62); `LSF_LOAN_DEFAULTED` = `0x00010000` on Loan (state-service.ts:30, distinct field from the Credential flag despite the same bit value).
