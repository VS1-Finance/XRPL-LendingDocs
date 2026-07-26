---
label: Loan Lifecycle Walkthrough
order: 60
---

# A Full Loan Lifecycle

This page walks a single loan end to end through the engine's HTTP action API — the same verbs documented in [Action Routes](../04-api/actions.md), executed against a session already carrying a provisioned vault, broker, and (if permissioned) domain/credentials as described in [the protocol composition](../02-protocol/xls66-lending-protocol.md). It mirrors the four-step sequence the reference `lifecycle` package drives directly against the ledger (`deposit.ts`, `originate.ts`, `repay.ts`, `close.ts`) — the engine exposes the same transactions through `POST /sessions/:id/actions` instead of a signed-client call.

Every call below has the shape fixed by the action route (`routes/actions.ts:8-43`, per [Action Routes](../04-api/actions.md)):

```
POST /sessions/:id/actions
{ participant, seat, action, params }
```

and returns `{ action, code, hash? }`, where `code` is the ledger's own result string (`tesSUCCESS` or a `tec*`) taken verbatim from `result.engineResult` (`action-service.ts:67`). A `tec*` is HTTP **200** — the transaction reached a ledger and was correctly rejected on its own terms, not an API error. See [Result Codes §1](../07-reference/result-codes.md#1-on-ledger-result-codes).

> [!NOTE]
> Interval/grace values below use `"60"` / `"60"`. This is the shortest `PaymentInterval`/`GracePeriod` pair we have observed succeed on Devnet, and is also the engine's own default when `interval`/`grace` are omitted (`action-service.ts:210-211`). The published XLS-66 text defines both as plain `UINT32` seconds fields with **no documented minimum**; our evidence is only that `30`/`1` returned `temINVALID` while `60`/`60` succeeded (`.docsource/XLS-VERIFICATION.md` item #3). Treat "≥ 60s" as observed behavior on this ledger build, not an asserted protocol floor — full detail in [XLS-66 §6](../02-protocol/xls66-lending-protocol.md#6-paymentinterval--graceperiod--note-on-the-60-second-floor).

## Cast

| Seat | Role | Holds |
|---|---|---|
| `depositor:0` | depositor | supplies vault liquidity, holds vault shares |
| `owner:0` | owner (vault-manager + originator, must be one account — `tecNO_PERMISSION` otherwise) | originates and manages the loan |
| `borrower:0` | borrower | receives principal, repays |

A session's seats are claimed via [Seat Routes](../04-api/seats.md) before any action below; that step is out of scope here — this page starts once all three seats are held.

---

## Arc 1 — Happy path: deposit, originate, repay in full, settle

### Step 1 — depositor deposits liquidity

`deposit` builds `VaultDeposit` against the session's vault for the validated `amount` param (`action-service.ts:77-83`, table row in [Action Routes](../04-api/actions.md#the-11-action-verbs)):

```
POST /sessions/:id/actions
{
  "participant": "alice",
  "seat": "depositor:0",
  "action": "deposit",
  "params": { "amount": "30000" }
}
```

**Expected:** `{ "action": "deposit", "code": "tesSUCCESS", "hash": "..." }`.

The reference lifecycle asserts this by reading the depositor's share balance before and after and requiring it grew (`deposit.ts:26-39`) — a deposit that mints no shares is treated as a failure even if the transaction itself settles. The default lifecycle CLI deposit amount is `30000` (`cli.ts:13`), used here for continuity with that reference run.

### Step 2 — owner originates a loan to the borrower (bilateral)

Origination is not a single-signer action — it is `LoanSet` signed by the owner and counter-signed by the borrower, submitted as one combined blob (`originate.ts:41-57`; engine equivalent `action-service.ts:202-228`). The engine still takes it through the same `/actions` route and re-derives both wallets from the session seed to produce the second signature (`action-service.ts:219-224`); the caller supplies only the owner seat and the borrower's seat key as a param:

```
POST /sessions/:id/actions
{
  "participant": "owner-co",
  "seat": "owner:0",
  "action": "originate",
  "params": {
    "borrower": "borrower:0",
    "principal": "10000",
    "interestRate": "50000",
    "interval": "60",
    "grace": "60"
  }
}
```

**Expected:** `{ "action": "originate", "code": "tesSUCCESS", "hash": "..." }`.

Guards enforced before the transaction is even built (`action-service.ts:188-201`):

- The acting seat must be `owner`-role — `only the owner seat can originate a loan` (**409**) otherwise.
- The named counterparty seat must be `borrower`-role — `${role} seat cannot be a loan counterparty` (**409**) otherwise.
- Unknown seats → **404**.

`interestRate` defaults to `50000` and `interval`/`grace` each default to `60` when omitted (`action-service.ts:209-211`) — shown explicitly above for clarity, but they need not be passed.

Principal is delivered to the borrower **inside** the `LoanSet` itself — there is no separate draw transaction. The reference lifecycle confirms this by reading the borrower's asset balance before and after and asserting it grew by the principal for non-XRP assets (`originate.ts:37,68-71`).

> [!NOTE]
> `LoanOriginationFee` is hardcoded to `"0"` in both the reference lifecycle (`originate.ts:50`) and the engine action (`action-service.ts:212`) — this walkthrough does not exercise a nonzero origination fee.

### Step 3 — borrower repays the full outstanding balance

`repay` builds `LoanPay` for a required `loanId` and `amount`, with the amount additionally clamped via `clampIssuedValueUp` before conversion to a ledger `Amount` (`action-service.ts:93-101`). A full settlement must pay `TotalValueOutstanding` — **not** `PrincipalOutstanding` — because it includes accrued interest since the last payment. The reference `repay()` reads this directly off the live loan object and pays it verbatim on the final installment (`repay.ts:44-53`):

```ts
// repay.ts:44-46
const ledgerDue = remaining <= 1 ? String(loan.TotalValueOutstanding) : String(loan.PeriodicPayment);
const due = ledgerToWhole(env, ledgerDue);
```

Bot-driven repayment (`outstandingToPay()`, `reads.ts:86-88`) follows the identical pattern — reading `TotalValueOutstanding` off the loan node, not the principal.

```
POST /sessions/:id/actions
{
  "participant": "bob",
  "seat": "borrower:0",
  "action": "repay",
  "params": { "loanId": "<loanId>", "amount": "<TotalValueOutstanding, whole-token units>" }
}
```

**Expected:** `{ "action": "repay", "code": "tesSUCCESS", "hash": "..." }`.

> [!WARNING]
> A payment below the loan's scheduled minimum due is rejected with **`tecINSUFFICIENT_PAYMENT`** — observed directly: a `repay` of `1` unit against a loan whose scheduled payment was far larger returned `tecINSUFFICIENT_PAYMENT` (hash `1BDB2294…`, per [Result Codes](../07-reference/result-codes.md#1-on-ledger-result-codes) and [Action Routes — repay](../04-api/actions.md#repay)). Underpaying does not partially apply — the transaction is rejected outright.

The reference lifecycle's `repay()` loop reads `PaymentRemaining` off the loan object each iteration; once it reaches `0` (or the loan object disappears entirely — settlement removes it from the ledger), repayment is complete (`repay.ts:33-41,58-61`).

### Step 4 — loan settles

A loan fully repaid to `TotalValueOutstanding` is removed from the ledger by the payment itself — there is no separate settlement transaction. The reference lifecycle's `repay()` detects this by loan-object absence (`repay.ts:35-38`), and its `close()` step is a documented no-op in that case:

```ts
// close.ts:21-22
const existing = await readLoan(client, loanId);
if (!existing) return { closed: true };
```

Only if the loan object still exists (repayment did not fully settle it) does `close()` issue an owner-signed `LoanDelete` (`close.ts:24-30`) — and `LoanDelete` against a loan that still carries outstanding debt is itself rejected with `tecHAS_OBLIGATIONS` (negative-suite N15, `negative-suite/src/cases/lending.ts:195-210`; also table row in [Transaction Map](../07-reference/transaction-map.md)). `LoanDelete` is not one of the engine's 11 exposed action verbs — it is only exercised by the negative suite, not the human-facing API.

> [!NOTE]
> After settlement, query [`GET /sessions/:id/state`](../04-api/reads.md) — the loan disappears from the `loans[]` array entirely (the ledger object is gone), rather than appearing with `principalOutstanding: "0"`. The depositor's earned yield is instead visible as growth in the vault's `AssetsTotal`, since the depositor holds a fixed share count and the vault's total assets rise as loans are repaid with interest (`close.ts:39-51`).

---

## Arc 2 — Default path: missed payment, time-gated default

### Step 1 — owner originates (as above)

Identical to Arc 1 Step 2 — a fresh loan with `interval: "60"`, `grace: "60"`.

### Step 2 — borrower misses the payment

No action is submitted. The reference `defaulter` bot variant models this literally — it is the absence of a `LoanPay`, holding the loan to be defaulted from the broker side once its window elapses (`borrower-variants.ts:81-87`):

```ts
// borrower-variants.ts:81-87
export const defaulter = (): BotVariant => ({
  role: "borrower",
  name: "default",
  async tick(): Promise<StepOutcome> {
    return idle;
  },
});
```

### Step 3 — premature default attempt → `tecTOO_SOON`

Before `NextPaymentDueDate + GracePeriod` has elapsed, defaulting the loan is rejected. `manage-loan` builds `LoanManage` with `Flags: tfLoanDefault` (`65536`) against a required `loanId` (`action-service.ts:162-168`):

```
POST /sessions/:id/actions
{
  "participant": "owner-co",
  "seat": "owner:0",
  "action": "manage-loan",
  "params": { "loanId": "<loanId>" }
}
```

**Expected (submitted before the window opens):** `{ "action": "manage-loan", "code": "tecTOO_SOON", "hash": "..." }`.

This is observed directly (hash `8D0F4506…`) and asserted by negative-suite case N14, which submits the identical `LoanManage`/`tfLoanDefault` transaction against a freshly-originated (non-delinquent) loan and expects exactly `tecTOO_SOON` (`negative-suite/src/cases/lending.ts:175-192`).

### Step 4 — the default gate opens

The engine computes defaultability directly from the loan object, exposed via `GET /sessions/:id/state` as `defaultableNow` / `defaultableInSeconds` per loan (`state-service.ts:55-59,68`):

```ts
// state-service.ts:57-59
const defaultableAt = Number(loan.NextPaymentDueDate ?? 0) + Number(loan.GracePeriod ?? 0);
const secondsUntil = defaultableAt - nowRipple();
const defaultableNow = !defaulted && paymentRemaining > 0 && defaultableAt > 0 && secondsUntil <= 0;
```

With `interval`/`grace` both `"60"`, `NextPaymentDueDate + GracePeriod` is at most a couple of minutes out from origination — poll [`GET /sessions/:id/state`](../04-api/reads.md) and wait for the target loan's `defaultableNow: true` before resubmitting, rather than sleeping a fixed duration.

### Step 5 — owner defaults the loan → `tesSUCCESS`

The identical `manage-loan` request from Step 3, resubmitted once `defaultableNow` is true:

```
POST /sessions/:id/actions
{
  "participant": "owner-co",
  "seat": "owner:0",
  "action": "manage-loan",
  "params": { "loanId": "<loanId>" }
}
```

**Expected:** `{ "action": "manage-loan", "code": "tesSUCCESS", "hash": "..." }`.

Once settled, `GET /sessions/:id/state` reports the loan with `defaulted: true` (the `LSF_LOAN_DEFAULTED` flag, `0x00010000`, set on the loan object — `state-service.ts:30,53`). This is the same transaction the `broker-enforcer` bot variant submits automatically every round once a loan is delinquent (`action-service.ts:48-51`, `owner-variants.ts`) — `manage-loan` simply exposes the identical path to a human.

> [!NOTE]
> The `broker-enforcer` bot reads `NextPaymentDueDate` and `GracePeriod` off the loan the same way the engine's state read does, to decide when to submit its own `tfLoanDefault` (`owner-variants.ts:126-127`). A human racing the bot to default the same loan will see whichever transaction lands first settle `tesSUCCESS`; the second attempt against an already-defaulted loan is a different rejection, not covered by this page.

---

## Result-code summary for this walkthrough

| Step | Action | Expected code | Grounding |
|---|---|---|---|
| Deposit | `deposit` | `tesSUCCESS` | `deposit.ts:26-39` (shares-minted assertion) |
| Originate | `originate` | `tesSUCCESS` | `originate.ts:57-63`; `action-service.ts:225-228` |
| Repay (full outstanding) | `repay` | `tesSUCCESS` | `repay.ts:44-53` (pays `TotalValueOutstanding`) |
| Repay (underpay) | `repay` | `tecINSUFFICIENT_PAYMENT` | Observed, hash `1BDB2294…` — [Result Codes](../07-reference/result-codes.md) |
| Default (premature) | `manage-loan` | `tecTOO_SOON` | Observed, hash `8D0F4506…`; negative-suite N14 (`lending.ts:175-192`) |
| Default (window open) | `manage-loan` | `tesSUCCESS` | `state-service.ts:57-59` gate; `action-service.ts:162-168` |

---

## Related pages

- [Action Routes](../04-api/actions.md) — the full 11-verb vocabulary, guard order, and amount validation this walkthrough exercises.
- [XLS-66 — Lending Protocol](../02-protocol/xls66-lending-protocol.md) — `LoanSet`/`LoanPay`/`LoanManage` field definitions and the `PaymentInterval`/`GracePeriod` floor note.
- [End-to-End Verification](../06-security/end-to-end-verification.md) — the underlying e2e runs these observed result codes and hashes are drawn from.
