---
label: Actions
order: 60
---

# Action Routes

The single write path for human participants: every deposit, withdrawal, repayment, credential grant, vault edit, and origination arrives through one route. The engine confirms the requesting participant holds the named seat, builds the corresponding XRPL transaction, submits it under that seat's signer, and returns the ledger's own result code — success and rejection are reported the same way, because a rejection is still a settled, correctly-priced outcome.

> [!NOTE]
> This page documents the action vocabulary in isolation. For the full HTTP status/result-code contract (why a `tec*` is HTTP 200, what maps to 400/404/409/500) see [Result Codes](../07-reference/result-codes.md). For a flat verb→transaction→amendment→ledger-object table see the [Transaction Map](../07-reference/transaction-map.md).

## POST /sessions/:id/actions

`registerActionRoutes` (`routes/actions.ts:8-43`) registers the one route every human action goes through.

**Body:**

```
{ participant, seat, action, params }
```

| Field | Type | Notes |
|---|---|---|
| `participant` | string | The caller's participant id. Must match who currently holds `seat`. |
| `seat` | string | The seat key acting (e.g. `owner:0`, `depositor:1`). |
| `action` | string | One of the 11 verbs below. |
| `params` | object (string→string) | Action-specific parameters. Optional — omitted entirely if absent (`routes/actions.ts:24`). |

**Response:** `200` with:

```
{ action, code, hash? }
```

`code` is the ledger's own result — `tesSUCCESS` or a `tec*` string — taken verbatim from `result.engineResult` (`action-service.ts:67`) for single-signer actions, or from the transaction metadata's `TransactionResult` (`action-service.ts:227`) for `originate`. `hash` is present when the ledger returned one.

> [!NOTE]
> A `tec*` result is returned as **HTTP 200**, not an error status. The transaction reached a ledger, claimed its fee, and was correctly rejected on its own terms — that is a successful API call reporting an unsuccessful transaction. See [Result Codes §1](../07-reference/result-codes.md#1-on-ledger-result-codes) for the full code catalog and observed examples of each.

### Guard order

Guards run in a fixed sequence, checked before any per-action logic (`routes/actions.ts:12-24`):

1. **404** — unknown session: `sessions.get(request.params.id)` returns nothing (`routes/actions.ts:12-13`).
2. **400** — missing `participant`: `if (!participant) ...` (`routes/actions.ts:16`).
3. **400** — missing `seat` or `action`: `if (!seat || !action) ...` (`routes/actions.ts:17`).
4. Per-action dispatch: `originate` takes its own bilateral path; every other verb goes through `dispatchAction` (`routes/actions.ts:21-24`).

Whatever the outcome — settlement or rejection — the action is written to the session log via `sessions.recordAction`, including `code` and, if present, `hash` (`routes/actions.ts:29-37`).

### Authorization: seat must be held by the caller

Inside `dispatchAction` (non-`originate` verbs):

```
const seat = session.seats.get(request.seat);
if (!seat) throw new ActionError(`session has no seat ${request.seat}`, 404);
if (seat.occupant.kind !== "human" || seat.occupant.id !== participant) {
  throw new ActionError(`${request.seat} is not held by ${participant}`, 409);
}
```
(`action-service.ts:57-62`)

- Unknown seat → **404**.
- Seat exists but is bot-driven, unheld, or held by a different participant → **409**.

`originate` repeats the identical check for the owner seat (`action-service.ts:190-193`) before its additional role guards (below).

## Amount validation

Every action that carries an `amount` goes through `assetAmount` → `requireAmount` (`action-service.ts:247-252,254-260`):

```
function requireAmount(value: string): string {
  if (!/^\d+(\.\d+)?$/.test(value.trim()) || Number(value) <= 0) {
    throw new ActionError(`invalid amount: ${value}`, 400);
  }
  return value;
}
```

Non-numeric, negative, zero, or otherwise malformed amount strings are rejected as **400** before any transaction is built. `assetAmount` then converts the validated string into a ledger `Amount`: `xrpToDrops` for a native-XRP session, or a `{currency, issuer, value}` object for an issued asset — throwing a **500** if the session's issued asset is missing an issuer, on the theory that is an engine misconfiguration rather than a caller mistake (`action-service.ts:254-260`). `brokerValue` (`action-service.ts:264-267`) applies the same `requireAmount` check for plain numeric fields (loan principal) that are not full `Amount` objects.

`asClientError` (`action-service.ts:31-46`) is the second line of defense: it catches whatever the ledger/`xrpl` layer throws during submission and reclassifies client-caused failures as **400** rather than letting them fall through to an opaque 500 — specifically `xrpl`'s `ValidationError`, a preliminary `tem*` rejection (the transaction never reached a ledger), and the amount-shape errors thrown deep in the IOU serializer (`illegal amount`, `not a non-negative decimal`, `invalid amount`). An already-thrown `ActionError` passes through untouched (`action-service.ts:32`). Anything else is rethrown and surfaces as a 500 at the route (`routes/actions.ts:47-49`).

## The 11 action verbs

All 11 are handled in `buildTransaction`'s switch (`action-service.ts:76-182`), except `originate`, which has its own function.

| Verb | Seat / role | Required params | TransactionType | Source |
|---|---|---|---|---|
| `deposit` | depositor | `amount` | VaultDeposit | action-service.ts:77-83 |
| `withdraw` | depositor | `amount` | VaultWithdraw | action-service.ts:85-91 |
| `repay` | borrower | `loanId`, `amount` | LoanPay | action-service.ts:93-101 |
| `issue-credential` | issuer | `subject`, `credentialType`? | CredentialCreate | action-service.ts:104-110 |
| `revoke-credential` | issuer | `subject`, `credentialType`? | CredentialDelete | action-service.ts:112-118 |
| `accept-credential` | subject (depositor/borrower) | `issuer`?, `credentialType`? | CredentialAccept | action-service.ts:123-129 |
| `set-vault` | owner | `assetsMaximum`? | VaultSet | action-service.ts:132-139 |
| `set-domain` | owner | `issuer`?, `credentialType`? | PermissionedDomainSet | action-service.ts:141-158 |
| `manage-loan` | owner | `loanId` | LoanManage (`Flags: tfLoanDefault` = 65536) | action-service.ts:162-168 |
| `deposit-cover` | owner | `amount` | LoanBrokerCoverDeposit | action-service.ts:172-178 |
| `originate` | owner (+ borrower counter-signs) | `borrower`, `principal`, `interestRate`?, `interval`?, `grace`? | LoanSet | action-service.ts:188-232 |

`?` marks a param with a session-derived default (credential type, credential issuer) rather than a hard requirement — see `resolveCredentialType`/`resolveCredentialIssuer` below. A missing hard-required param throws `ActionError("missing parameter ${key}")` at default status **400** (`required`, `action-service.ts:293-296`; `ActionError`'s default `status = 400`, `action-service.ts:19`). An unrecognized `action` string falls through the switch's `default` and throws a plain **400** (`action-service.ts:181`, no explicit status given).

### deposit

`VaultDeposit` against `session.env.objects.vaultId` for the amount-validated `amount` param (`action-service.ts:77-83`). Common rejections:

- Amount exceeding the depositor's IOU balance → `tecINSUFFICIENT_FUNDS` (observed: deposit 200000 against a 60000 balance, `e2e-data.json` hash `70EDC0C6…`, per [Result Codes](../07-reference/result-codes.md)).
- Deposit pushing `AssetsTotal` past the vault's `AssetsMaximum` → `tecLIMIT_EXCEEDED` (observed, hash `9BDF2A3C…`).
- No accepted credential on a permissioned vault → `tecNO_AUTH` (negative suite N1–N4, `negative-suite/src/cases/credentials.ts:21-81`).

### withdraw

`VaultWithdraw` against the same `vaultId`, same amount validation path (`action-service.ts:85-91`). Withdrawing beyond the depositor's share balance → `tecINSUFFICIENT_FUNDS` (observed, hash `74A148EB…`).

### repay

`LoanPay` against a required `loanId`, with the amount additionally passed through `clampIssuedValueUp` before `assetAmount` (`action-service.ts:93-101`). An underpayment below the loan's scheduled minimum due → `tecINSUFFICIENT_PAYMENT` (observed: repay `1` against a much larger scheduled payment, hash `1BDB2294…`).

### issue-credential

Issuer-seat action: `CredentialCreate` for a required `subject`, `CredentialType` resolved by `resolveCredentialType` and hex-encoded (`action-service.ts:104-110,289-291`). Rejected on a public vault — see [Public-vault gating](#public-vault-gating-409) below. A `CredentialCreate` to an unfunded subject address → `tecNO_TARGET` (observed, hash `568F259C…`).

### revoke-credential

Issuer-seat action: `CredentialDelete`, same subject/type resolution as `issue-credential` (`action-service.ts:112-118`). Revoking a credential that was never issued → `tecNO_ENTRY` (observed, hash `6B316076…`).

### accept-credential

Subject-seat action (the depositor or borrower the credential was issued to): `CredentialAccept`, with `Issuer` defaulting to `resolveCredentialIssuer(session)` when `params.issuer` is absent (`action-service.ts:123-129,283-287`). This is the second half of the issue/accept handshake — a credential is inert until accepted. Re-accepting an already-accepted credential → `tecDUPLICATE` (observed, hash `10582383…`).

### set-vault

Owner-seat (vault-manager) action: `VaultSet` against `vaultId`, optionally setting `AssetsMaximum` (in vault asset units — drops for XRP, whole tokens otherwise) when `params.assetsMaximum` is given (`action-service.ts:132-139`). Lowering `AssetsMaximum` below the vault's current assets → `tecLIMIT_EXCEEDED` (observed, hash `1510577D…`).

### set-domain

Owner-seat action: `PermissionedDomainSet` against the session's `domainId`, replacing `AcceptedCredentials` with a single-entry list built from the resolved issuer/type (`action-service.ts:141-158`). Rejected on a public vault — see [Public-vault gating](#public-vault-gating-409) below.

### manage-loan

Owner-seat action: `LoanManage` against a required `loanId` with `Flags: tfLoanDefault` (65536) — this is the same transaction the broker-enforcer bot submits automatically each round, exposed here so a human can default a delinquent loan by hand (`action-service.ts:48-51,162-168`). Defaulting a loan before `NextPaymentDueDate + GracePeriod` has passed → `tecTOO_SOON` (observed, hash `8D0F4506…`; the gate is computed in `state-service.ts:57-59`).

### deposit-cover

Owner-seat action: `LoanBrokerCoverDeposit` against `session.env.objects.brokerId` for the amount-validated `amount` (`action-service.ts:172-178`). Cover backs outstanding loans, so raising it raises how much can be originated within the minimum cover rate. Amount exceeding the owner's balance → `tecINSUFFICIENT_FUNDS` (observed, hash `BAEE954F…`).

### originate

The only bilateral action, documented separately below.

## originate — bilateral, role-guarded

`originate` does not go through `dispatchAction`/`buildTransaction` — it is dispatched directly from the route (`routes/actions.ts:22-23`) and has its own signing path, because a `LoanSet` here needs two raw signatures on one transaction: the owner signs, then the borrower counter-signs the same prepared transaction via `signLoanSetByCounterparty` (`action-service.ts:185-187,222-224`).

### Guards, in order (`action-service.ts:188-201`)

1. **404** — unknown owner seat: `session.seats.get(ownerSeatKey)` returns nothing (`:190`).
2. **409** — owner seat not held by the calling participant: same occupant check as `dispatchAction` (`:191-193`).
3. **409** — acting seat is not role `"owner"`: `if (owner.role !== "owner") throw new ActionError("only the owner seat can originate a loan", 409)` (`:197`).
4. **404** — named `borrower` param does not resolve to a seat: `session.seats.get(required(params, "borrower"))` (`:198-199`).
5. **409** — the named counterparty seat is not role `"borrower"`: `` `${borrowerSeat.role} seat cannot be a loan counterparty` `` (`:200`).

The role guards exist because the signing wallets below are re-derived by role rather than by seat identity — a non-owner or non-borrower seat would sign with an account that does not match `Account`/`Counterparty`, and the ledger would reject it opaquely. Guarding here turns a misdirected request into a clean rejection instead of an inscrutable failure downstream (`action-service.ts:194-196`).

### Building and signing the LoanSet (`action-service.ts:202-228`)

```
const loanSet = {
  TransactionType: "LoanSet" as const,
  Account: owner.address,
  LoanBrokerID: session.env.objects.brokerId!,
  Counterparty: borrowerSeat.address,
  PrincipalRequested: brokerValue(session, required(params, "principal")),
  InterestRate: Number(params.interestRate ?? 50000),
  PaymentInterval: Number(params.interval ?? 60),
  GracePeriod: Number(params.grace ?? 60),
  LoanOriginationFee: "0",
};
```

The owner and borrower wallets are re-derived from the session seed by role and seat index (`deriveAccount(session.seed, "owner", owner.index)` / `deriveAccount(session.seed, "borrower", borrowerSeat.index)`, `:219-220`) — the derived addresses match the seats' on-ledger accounts, which is what binds each raw signature to the correct identity. The transaction is autofilled, signed by the owner wallet, counter-signed by the borrower wallet via `signLoanSetByCounterparty`, and submitted with `submitAndWait` (`:221-225`). The result `code` is read from the transaction metadata's `TransactionResult` (`:226-228`), the same ledger-result contract as every other action.

> [!NOTE]
> `PaymentInterval` and `GracePeriod` default to `60` (seconds) when the caller omits `interval`/`grace` (`action-service.ts:210-211`). This default was **not** chosen arbitrarily by the docs — it mirrors an observed constraint, covered next.

### PaymentInterval / GracePeriod minimum — observed, not a documented protocol floor

> [!NOTE]
> The published XLS-66 spec text defines `PaymentInterval` and `GracePeriod` as plain `UINT32` seconds fields and **does not document a minimum value** for either. What we can state as fact is only what we observed: submitting `originate` with `PaymentInterval: "30"` (below 60) was rejected with **`temINVALID`** before it ever reached a ledger — `HTTP 400`, detail `"LoanSet: PaymentInterval must be greater than or equal to 60"` (`e2e-data.json`, scenario "originate interval < 60 -> 400"); `60`/`60` succeeds. Treat "≥ 60s" as this system's demonstrated behavior on Devnet — most likely a rippled preflight/implementation constraint (possibly from rippled PR #5270) rather than a rule published in the XLS-66 README. Do not assert it as a protocol minimum. See [Result Codes — tem](../07-reference/result-codes.md#tem--malformed-never-reaches-consensus) for the same finding with its full citation, and [XLS-66](../02-protocol/xls66-lending-protocol.md) for the field definitions.

Because a `temINVALID` never reaches a ledger, it is not a `code` in the action response at all — `asClientError` maps the preliminary `tem` rejection straight to **HTTP 400** (`action-service.ts:39-44`).

## Public-vault gating (409)

Three helpers reject credential/domain-related actions outright when the session is a public (non-permissioned) vault, rather than silently no-op'ing or letting a client re-enable them by supplying an explicit param:

| Helper | Guards | Source |
|---|---|---|
| `resolveCredentialType` | `issue-credential`, `revoke-credential`, `accept-credential`, `set-domain` — throws if `session.env.objects.domainId === undefined` | action-service.ts:272-279 |
| `resolveCredentialIssuer` | `accept-credential` (default `Issuer`), `set-domain` (default `Issuer`) — throws if no `credentialIssuer` account exists | action-service.ts:283-287 |
| inline guard in `set-domain` | throws directly if `session.env.objects.domainId` is absent, before building `AcceptedCredentials` | action-service.ts:143-144 |

All three throw `ActionError(..., 409)`. Observed: `"set-domain on public vault -> 409"`, `"issue-credential on public vault -> 409"`, `"revoke-credential on public vault -> 409"` (`e2e-data.json`, groups G/H/K, per [Result Codes](../07-reference/result-codes.md)).

## See also

- [Transaction Map](../07-reference/transaction-map.md) — flat verb → TransactionType → amendment → ledger-object table, plus the full TransactionType→amendment grouping across provisioning, actions, bots, and teardown.
- [Result Codes](../07-reference/result-codes.md) — the complete `tes`/`tec`/`tem`/`ter` catalog and the HTTP status contract (200/201/400/404/409/500), each row cited to an observed transaction or a code path.
- [XLS-65 — Single Asset Vault](../02-protocol/xls65-single-asset-vault.md) — `deposit`, `withdraw`, `set-vault`.
- [XLS-66 — Lending Protocol](../02-protocol/xls66-lending-protocol.md) — `repay`, `manage-loan`, `deposit-cover`, `originate`, and the `PaymentInterval`/`GracePeriod` fields.
- [XLS-70 — Credentials](../02-protocol/xls70-credentials.md) — `issue-credential`, `revoke-credential`, `accept-credential`.
- [XLS-80 — Permissioned Domains](../02-protocol/xls80-permissioned-domains.md) — `set-domain`.
