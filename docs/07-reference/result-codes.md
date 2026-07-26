---
label: Result Codes
order: 10
---

# Result Codes

Every ledger result and HTTP status this system produces, as observed in the 109-scenario, 122-transaction Devnet end-to-end run (`e2e-data.json`) and the negative suite (`packages/negative-suite`). Nothing on this page is asserted from protocol memory alone — each row cites either an observed transaction or the engine code path that produces it.

The load-bearing distinction for everything below: **a `tec*` code is not an engine error.** It is a transaction that the ledger claimed a fee for, applied, and rejected on its own terms — a correct, expected outcome. The engine returns it as `HTTP 200` with the `code` field set. Several of our own negative tests *expect* a `tec*` and would fail if they got `tesSUCCESS` instead. A `tem*` code, by contrast, means the transaction was malformed and never reached a ledger at all — our engine turns that into `HTTP 400` before the caller ever sees a ledger code.

## 1. On-ledger result codes

### tes — success

| Code | Meaning | Observed here |
|---|---|---|
| `tesSUCCESS` | The transaction was validated and fully applied. | The overwhelming majority of the 122 observed transactions: every provisioning step (`issuer-allow-clawback`, `trust-*`, `distribute-*`, `credential-create-*`, `credential-accept-*`, `domain-create`, `vault-create`, `broker-create`, `cover-deposit`), every clean `deposit`/`withdraw`/`repay`/`originate`/`deposit-cover`/`set-vault`/`set-domain`/`issue-credential`/`revoke-credential`, and a `manage-loan` default once the loan is actually delinquent (`e2e-data.json`, scenario "owner defaults the delinquent loan -> tesSUCCESS", hash `A70853CF…`). |

### tec — claimed cost, rejected effect

A `tec*` transaction consumes a fee and advances the account sequence, but its intended effect does not happen. The engine surfaces it as `HTTP 200` with `code` set to the `tec*` string — see [§2](#2-http-status-codes) for why this is not a 4xx/5xx.

| Code | Meaning | Concrete trigger in this system |
|---|---|---|
| `tecNO_AUTH` | The account is not authorized for the action — here, deposit into a domain-gated vault without an accepted credential of the type the domain admits. | Negative suite N1–N4: no credential (N1), wrong credential type (N2), credential from an unrecognized issuer (N3), revoked credential (N4) — all assert `tecNO_AUTH` on `VaultDeposit` (`packages/negative-suite/src/cases/credentials.ts:21-81`). Also N5, a share `Payment` to a non-member (`credentials.ts:85-101`). |
| `tecNO_TARGET` | The transaction's target account does not exist on-ledger (unfunded). | `issue-credential` (`CredentialCreate`) to a fresh, never-funded subject address — observed `tecNO_TARGET` (`e2e-data.json`, scenario "issue-credential to unfunded fresh subject -> tec* (tecNO_TARGET)", hash `568F259C…`). |
| `tecNO_ENTRY` | The ledger entry the transaction expects to act on does not exist. | `revoke-credential` (`CredentialDelete`) for a subject that never had a credential — observed `tecNO_ENTRY` (`e2e-data.json`, scenario "revoke-credential for never-existing subject -> tec* (tecNO_ENTRY)", hash `6B316076…`). |
| `tecDUPLICATE` | An equivalent ledger entry already exists; the transaction would create a redundant one. | `accept-credential` (`CredentialAccept`) submitted for a credential already accepted — observed `tecDUPLICATE` (`e2e-data.json`, scenario "accept-credential by the member -> settles", hash `10582383…`). |
| `tecINSUFFICIENT_FUNDS` | The acting account does not hold enough of the asset (or vault-share equivalent) to cover the requested amount. | Observed three ways: `withdraw` beyond a depositor's share balance (scenario "alice overdraw withdraw 9999999 -> tec*", hash `74A148EB…`); `deposit` beyond the holder's IOU balance (scenario "deposit 200000 (> holder's 60000 balance)", hash `70EDC0C6…`); `deposit-cover` beyond the owner's balance (scenario "owner cover 99999 (> owner's 16000)", hash `BAEE954F…`). Also the negative-suite floor case N13, withdrawing broker cover below the minimum required to back outstanding debt (`lending.ts:154-171`). |
| `tecINSUFFICIENT_PAYMENT` | A `LoanPay` amount is below the scheduled minimum payment due. | `repay` of `1` unit against a loan whose scheduled payment is far larger — observed `tecINSUFFICIENT_PAYMENT` (`e2e-data.json`, scenario "underpay repay '1' (below scheduled minimum) -> tec*", hash `1BDB2294…`). |
| `tecLIMIT_EXCEEDED` | The action would exceed a configured ceiling — here, the vault's `AssetsMaximum`. | Observed two ways: `set-vault` (`VaultSet`) lowering `AssetsMaximum` below the vault's current assets (scenario "set vault max 100 below current assets", hash `1510577D…`); `deposit` that would push `AssetsTotal` past the vault's current cap (scenario "deposit 5000 exceeding the 6000 cap headroom", hash `9BDF2A3C…`). |
| `tecTOO_SOON` | The action is time-gated and the gate has not yet opened — here, defaulting a loan before it is delinquent. | `manage-loan` (`LoanManage`, `Flags: tfLoanDefault`) on a loan that has not passed `NextPaymentDueDate + GracePeriod` — observed `tecTOO_SOON` (`e2e-data.json`, scenario "default a current (non-delinquent) loan -> tec*", hash `8D0F4506…`). The gate itself is computed in `state-service.ts:57-59` (`defaultableAt = NextPaymentDueDate + GracePeriod`) and the same test proves the loan becomes `defaultableNow=true` once that window passes, after which the identical `manage-loan` action settles `tesSUCCESS`. Also negative-suite N14, the same premature-default case (`lending.ts:175-192`). |
| `tecHAS_OBLIGATIONS` | The object being deleted still has outstanding obligations attached. | Not exercised in the E2E run (no delete actions in scope), but asserted in the negative suite: N7, `VaultDelete` while a `LoanBroker` is still attached to the vault (`lending.ts:23-35`); N15, `LoanDelete` on a loan that still has outstanding debt (`lending.ts:195-210`). |

### tem — malformed, never reaches consensus

A `tem*` transaction fails local/preflight checks and is never applied to a ledger. There is no ledger `code` to report for it — the engine's own validation, or `xrpl`'s preliminary rejection, stops the request before submission, and it surfaces as `HTTP 400`.

| Code | Meaning | Concrete trigger in this system |
|---|---|---|
| `temINVALID` (and related `tem*` family) | The transaction is malformed as submitted. | Observed: `originate` (`LoanSet`) with `PaymentInterval < 60` seconds is rejected before it reaches a ledger — `HTTP 400`, detail `"LoanSet: PaymentInterval must be greater than or equal to 60"` (`e2e-data.json`, scenario "originate interval < 60 -> 400"). |

> [!WARNING]
> This 60-second floor is an **observed** local/preflight rejection, not a documented protocol minimum — the XLS-66 spec text does not state a minimum for `PaymentInterval`/`GracePeriod` (both are plain `UINT32` seconds). Treat "PaymentInterval must be ≥ 60s" as this system's demonstrated behavior on Devnet, not as an asserted protocol rule.

Because a `tem*` rejection never reaches a ledger, our engine's `asClientError` maps it straight to `HTTP 400` rather than returning a ledger `code` field at all — see `action-service.ts:31-46`:

```ts
// Client-caused failures: xrpl's ValidationError (malformed tx/amount), a preliminary `tem` rejection
// (the tx never reached a ledger), and the amount-shape errors thrown while building the tx...
if (
  name === "ValidationError" ||
  /Transaction failed, tem/.test(message) ||
  /illegal amount|not a non-negative decimal|invalid amount/.test(message)
) {
  throw new ActionError(message, 400);
}
```

### ter — retryable (batch submission only)

Not surfaced to API callers as a result code at all — these only appear inside `submitBatch`'s internal retry classification during provisioning, and a caller never sees a `ter*` in an action response. Listed here for completeness of what the codebase recognizes as a ledger code family. `classifyResult` (`shared/client.ts:85-96`) buckets `terQUEUED`, `terPRE_SEQ`, `tefPAST_SEQ`, and `tecINSUFFICIENT_FEE`/`tel*` as retryable within a batch attempt (up to `MAX_ATTEMPTS=4`, `client.ts:116`); anything else is fatal and throws the whole batch. This machinery is internal to provisioning's `runBatch` (`bootstrap/steps.ts:52-78`) and is not part of the action-response contract documented in [§2](#2-http-status-codes).

## 2. HTTP status codes

The engine's HTTP layer distinguishes a settled ledger outcome (including a `tec*` rejection) from an engine-side or request-side error. Precedence is resource-first: an unknown session or seat is checked before anything else, so a request against a nonexistent resource always 404s regardless of what else is wrong with it (`routes/seats.ts:8-10`).

| Status | Meaning here | Source |
|---|---|---|
| `200` | The request was processed and the response body carries the outcome — for `/actions`, this includes both `tesSUCCESS` **and every `tec*` code**. A `tec*` is a settled ledger result, not a failure of the HTTP call. | `routes/actions.ts:38` returns `result` (with its `code` field) on the success path of `dispatchAction`/`originate`; a `tec*` reaches this same return, it is not caught as an error. |
| `201` | A new session was provisioned. | `POST /sessions` — `routes/sessions.ts:29-32`. |
| `400` | The request itself is invalid: a missing or malformed parameter, an unknown action verb, or a client-caused ledger rejection that never reached consensus (`tem*`, `ValidationError`, an illegal amount shape). | `ActionError` default status `action-service.ts:19` (e.g. `required()` at `:293-296` throws "missing parameter X"; `requireAmount()` at `:247-252` throws "invalid amount: X"; unknown action at `:181`); `asClientError` at `:31-46` for `tem*`/`ValidationError`; seat/claim routes' `participant is required` (`routes/seats.ts:20,38`); `role must be depositor or borrower` (`routes/sessions.ts:103`). Observed: `originate interval < 60 -> 400`, `deposit bad amount 'abc'/'1.2.3'/'-5'/'0'/'1e5' -> 400`, `unknown action verb -> 400`, `claim missing participant -> 400` (`e2e-data.json`, group G/H). |
| `404` | The named session or seat does not exist. | `routes/sessions.ts:69,77,85,92,101` (unknown session, `/state`, `/balances`, `/log`, `/participants`); `routes/seats.ts:17-18,35-36` (unknown session, unknown seat); `routes/actions.ts:13` and `ActionError` thrown at status 404 for an unknown seat inside `dispatchAction`/`originate` (`action-service.ts:59,190,199`). Observed throughout group A ("GET unknown session -> 404", etc.) and group G ("originate to unknown borrower seat -> 404", "action on nonexistent seat -> 404"). |
| `409` | A state conflict: the seat is held by someone else, a role guard rejects the request, or a public-vault session is asked for a domain/credential action it does not have. | Seat occupancy: `SeatOccupancyError` mapped to 409 in `routes/seats.ts:50-51` (claim-already-held, release-not-held). Action-side seat guard: `ActionError(…, 409)` in `dispatchAction` when the seat is not held by the requesting participant (`action-service.ts:61`). Origination role guards: non-owner seat originating, non-borrower counterparty (`action-service.ts:197,200`). Public-vault feature gates: `set-domain` on a public vault (`:144`), credential actions on a public vault via `resolveCredentialType`/`resolveCredentialIssuer` (`:274,285`). Pool capacity: `CapacityError` on `/participants` mapped to 409 (`routes/sessions.ts:114`, thrown by `session-service.ts:141` at `MAX_POOL=20`). Observed: "other participant claims held seat -> 409", "non-owner originate -> 409 [role guard]", "originate to non-borrower counterparty -> 409", "bob acts on alice's seat -> 409", "set-domain on public vault -> 409", "issue-credential on public vault -> 409", "revoke-credential on public vault -> 409" (`e2e-data.json`, groups G/H/K). |
| `500` | An unexpected engine-side or ledger-connectivity fault — anything `asClientError` does not recognize as client-caused is rethrown and falls through to a bare 500. | `actionError()` fallback in `routes/actions.ts:46-49` (`return reply.code(500)...` for any error that is not an `ActionError`); the `/participants` route's fallback for any error that is not a `CapacityError` (`routes/sessions.ts:115`, "an on-ledger or faucet failure during provisioning of the new account"); `assetAmount()`'s internal `issued asset has no issuer` guard is itself thrown at status 500 (`action-service.ts:258`), on the theory that a session with no issuer configured is an engine misconfiguration, not a caller mistake. Not exercised in the E2E run (all 109 scenarios passed with no unexpected faults) — this is a code-path citation, not an observed transaction. |

Session-creation (`POST /sessions`, `POST /sessions/stream`) has no equivalent try/catch mapping in the route itself (`routes/sessions.ts:29-32,38-61`) — a provisioning failure there propagates as Fastify's default error response, or, on the streaming path, is sent as an `error` SSE event (`:56-57`) rather than an HTTP status.
