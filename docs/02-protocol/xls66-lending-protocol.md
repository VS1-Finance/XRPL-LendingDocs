---
label: XLS-66 Lending
order: 80
---

# XLS-66 — Lending Protocol

XLS-66 defines the on-ledger lending primitives: a `LoanBroker` that originates and services loans against a vault's assets, backed by first-loss cover capital, and a `Loan` object per origination. This page covers the transactions we submit, the two ledger objects we read, the bilateral origination mechanic, the cover-rate math our bots use to size loans, and the time-gated default rule — each cited to the actual source in `lending-reference`.

Related: [Result Codes](../07-reference/result-codes.md), [Transaction Map](../07-reference/transaction-map.md).

## 1. Transactions we submit

| Transaction | Purpose | Key fields we set | Source |
|---|---|---|---|
| `LoanBrokerSet` | Create the broker over a vault; also used later to adjust broker parameters. | `VaultID`, `ManagementFeeRate`, `DebtMaximum`, `CoverRateMinimum`, `CoverRateLiquidation` | `steps.ts:199-222` |
| `LoanBrokerCoverDeposit` | Add first-loss cover capital to the broker. | `LoanBrokerID`, `Amount` | `steps.ts:224-249` (provisioning seed), `action-service.ts:172-178` (owner action `deposit-cover`) |
| `LoanBrokerCoverWithdraw` | Withdraw cover capital. | `LoanBrokerID`, `Amount` | Not an exposed action verb — exercised only by negative-suite N13 (`negative-suite/src/cases/lending.ts:154-171`), asserting `tecINSUFFICIENT_FUNDS` when a withdrawal would drop cover below the floor backing outstanding debt. |
| `LoanBrokerDelete` | Tear down the broker. | `LoanBrokerID` | `teardown.ts:41` |
| `LoanSet` | Originate a loan. Bilateral — see [§2](#2-bilateral-origination). | `LoanBrokerID`, `Counterparty`, `PrincipalRequested`, `InterestRate`, `PaymentInterval`, `GracePeriod`, `LoanOriginationFee` | `action-service.ts:188-232` |
| `LoanPay` | Repay against an outstanding loan. | `LoanID`, `Amount` | `action-service.ts:93-101` |
| `LoanManage` | Manage loan status; the only flag we set is the default flag. | `LoanID`, `Flags: tfLoanDefault (65536)` | `action-service.ts:162-168` |
| `LoanDelete` | Delete a closed loan. | `LoanID` | Not an exposed action verb — exercised only by negative-suite N15 (`negative-suite/src/cases/lending.ts:195-210`), asserting `tecHAS_OBLIGATIONS` against an active loan. |

> [!NOTE]
> The spec defines two additional `LoanManage` flags, `tfLoanImpair (131072)` and `tfLoanUnimpair (262144)`. This system does not use either — only `tfLoanDefault` (`amendment-map.md`, "XLS-66" section).

## 2. Bilateral origination

`LoanSet` is the one transaction in this system that is not single-signer. A loan cannot be created unilaterally by the broker owner — the borrower named as `Counterparty` must counter-sign the same transaction before it is submitted (`action-service.ts:188-232`).

The `originate` handler (`action-service.ts:188-232`):

1. Validates the acting seat holds `role === "owner"` and the named counterparty seat holds `role === "borrower"` — a misrouted request is rejected with a 409 `ActionError` rather than reaching the ledger with a wrong-account signature (`action-service.ts:194-200`).
2. Builds the `LoanSet` transaction:

   ```ts
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
   (`action-service.ts:202-213`)

3. Re-derives both the owner's and the borrower's wallets from the session seed (`deriveAccount(session.seed, "owner"|"borrower", index)`), autofills the transaction, signs it with the owner wallet, then combines the borrower's counter-signature via `signLoanSetByCounterparty` (an `xrpl` library helper) before submission (`action-service.ts:219-225`).

This is the only place in the engine where a transaction needs two raw signatures — every other action verb dispatches through the single-signer `dispatchAction` path (`action-service.ts:57-71`).

| Field | Meaning | Source of the value here |
|---|---|---|
| `LoanBrokerID` | The broker originating the loan. | `session.env.objects.brokerId` |
| `Counterparty` | The borrower's address. | Resolved from the named borrower seat |
| `PrincipalRequested` | Loan principal, in the broker's asset units (drops for XRP, whole tokens otherwise). | `brokerValue()` — converts a whole-token request param |
| `InterestRate` | Scaled-integer rate; defaults to `50000` (see [§4](#4-cover-rate-math-scaled-integers)). | Request param or default |
| `PaymentInterval` | Seconds between scheduled payments; defaults to `60`. | Request param or default — see [§6](#6-paymentinterval--graceperiod--note-on-the-60-second-floor) |
| `GracePeriod` | Seconds after the due date before the loan becomes defaultable; defaults to `60`. | Request param or default — see [§6](#6-paymentinterval--graceperiod--note-on-the-60-second-floor) |
| `LoanOriginationFee` | Always `"0"` in this system — no origination fee is charged. | Hardcoded |

`packages/negative-suite` case N10 confirms the bilateral requirement from the other direction: a `LoanSet` signed only by the owner (no counter-signature) is malformed and rejected before consensus (`negative-suite/src/cases/lending.ts:84-103`).

## 3. Ledger objects we read

### LoanBroker

Read via `account_objects` filtered `type: "loan_broker"` against the owner's account (the vault and broker share an `Owner`) (`state-service.ts:47`; `ledger-lookups.ts:24,32`).

| Field | Used for |
|---|---|
| `CoverAvailable` | First-loss cover currently held; surfaced in session state (`state-service.ts:96`) and read by bots for headroom math (`bots/reads.ts:156`). |
| `DebtTotal` | Total principal currently lent out; read by bots for headroom math (`bots/reads.ts:157`). |
| `DebtMaximum` | Configured lending ceiling (`bots/reads.ts:158`). |
| `CoverRateMinimum` | Scaled-integer minimum cover ratio (`bots/reads.ts:159`). |
| `Owner` | Asserted equal to the vault's owner — single-owner invariant (`assertions.ts:13-26`, per `amendment-map.md`). |

### Loan

Read via `account_objects` filtered `type: "loan"` against each borrower's account — loan objects live in the borrower's own directory, not the owner's (`state-service.ts:51`; confirmed by `bots/reads.ts:21-23`, which notes that scanning the owner would surface a different borrower's loan).

| Field | Used for |
|---|---|
| `PrincipalOutstanding` | Remaining principal; surfaced in session state (`state-service.ts:63`). |
| `TotalValueOutstanding` | Full remaining balance including accrued interest; surfaced in session state (`state-service.ts:64`) and used by bots to compute a full repayment amount (`bots/reads.ts:86-88`). |
| `PaymentRemaining` | Count of scheduled payments left; `0` means fully repaid (`state-service.ts:54,65-68`; `bots/reads.ts:53`). |
| `NextPaymentDueDate` | Ripple-epoch timestamp of the next scheduled payment; combined with `GracePeriod` to compute defaultability (`state-service.ts:57`). |
| `GracePeriod` | Echoes the value set at origination; added to `NextPaymentDueDate` for the default gate (`state-service.ts:57`). |
| `Flags` | Bit `0x00010000` (`LSF_LOAN_DEFAULTED`) marks a defaulted loan (`state-service.ts:30,53`). |

## 4. Cover-rate math (scaled integers)

Cover and fee rates on the ledger are scaled integers, where `100000` reads as `100%` (`config/schema.ts:27`). `maxOriginatable` (`bots/reads.ts:148-167`) computes the largest new loan the broker can currently back:

```ts
const coverSupportsTotal = (coverAvailable * 100000) / coverRate;
const coverHeadroom = coverSupportsTotal - debtTotal;
const debtHeadroom = debtMaximum > 0 ? debtMaximum - debtTotal : Infinity;

return Math.max(0, Math.min(available, coverHeadroom, debtHeadroom));
```
(`bots/reads.ts:162-166`, whole-token units)

In words: cover of `coverAvailable` at a minimum cover rate of `coverRate` supports total debt up to `coverAvailable × 100000 / coverRate`. Subtracting `DebtTotal` (debt already lent) gives the cover-side headroom. A new loan is bounded by the smallest of three ceilings:

1. `available` — the vault's spare liquidity (`AssetsAvailable`).
2. `coverHeadroom` — debt the remaining cover can still support.
3. `debtHeadroom` — room under the broker's configured `DebtMaximum` (unbounded if `DebtMaximum` is unset).

This is bot sizing logic, not a ledger-enforced formula we assert as protocol text — it is our own headroom calculation over fields the ledger reports.

**Invariant enforced at configuration time:** `coverRateLiquidation` must not exceed `coverRateMinimum` — enforced by a Zod `superRefine` that rejects a config where liquidation rate is set higher than the minimum cover rate (`config/schema.ts:108-115`, per `amendment-map.md`).

## 5. Time-gated default

A loan becomes defaultable only after its grace window has elapsed — not at any earlier point, regardless of missed payments. The gate is computed identically in two places:

```ts
const defaultableAt = Number(loan.NextPaymentDueDate ?? 0) + Number(loan.GracePeriod ?? 0);
const secondsUntil = defaultableAt - nowRipple();
const defaultableNow = !defaulted && paymentRemaining > 0 && defaultableAt > 0 && secondsUntil <= 0;
```
(`state-service.ts:57-59`)

`nowRipple()` converts the current wall-clock time to the Ripple epoch (2000-01-01, offset `946684800` seconds) before comparing (`state-service.ts:34-35`).

- **Premature default is rejected.** Submitting `LoanManage` with `Flags: tfLoanDefault (65536)` before `NextPaymentDueDate + GracePeriod` has passed returns `tecTOO_SOON` — observed directly (`e2e-data.json`, scenario "default a current (non-delinquent) loan -> tec*") and asserted by negative-suite case N14 (`negative-suite/src/cases/lending.ts:175-192`).
- **`tfLoanDefault = 65536`** is the only `LoanManage` flag this system sets, both from the owner action (`action-service.ts:51,162-168`) and from the `broker-enforcer` bot variant that submits the identical transaction automatically once a loan is delinquent (`session/src/bots/owner-variants.ts`, per `amendment-map.md`).
- Once the window passes, the identical `manage-loan` action settles `tesSUCCESS` (`result-codes.md` §1, "owner defaults the delinquent loan").

**Repayment minimums.** `LoanPay` is checked against the loan's scheduled minimum: a payment below what is currently due is rejected with `tecINSUFFICIENT_PAYMENT` — observed for a `repay` of `1` unit against a much larger scheduled payment (`result-codes.md` §1, scenario "underpay repay '1' ... -> tec*", hash `1BDB2294…`). A full repayment pays `TotalValueOutstanding`, which includes accrued interest, not just `PrincipalOutstanding` — bots compute this via `outstandingToPay()`, which reads `TotalValueOutstanding` and converts it to a whole-token repay amount (`bots/reads.ts:86-88`).

Separately, the *overpayment* flag's behavior is inverted from what its name suggests: a payment above the amount due is accepted **without** `tfLoanOverpayment (65536)` set, and **rejected** with `tecNO_PERMISSION` when the flag **is** set — asserted by negative-suite case N12 (`negative-suite/src/cases/lending.ts:129-150`, per `amendment-map.md`). We do not set this flag anywhere in the action or bot paths.

## 6. PaymentInterval / GracePeriod — note on the 60-second floor

> [!NOTE]
> The published XLS-66 spec text defines `PaymentInterval` and `GracePeriod` as plain `UINT32` seconds fields, with **no documented minimum value**. This system observed `temINVALID` when submitting `PaymentInterval: "30"` / `GracePeriod: "1"` on Devnet, while `60` / `60` succeeds (E2E scenario "originate interval < 60 -> 400", surfaced by the engine as `HTTP 400` via `asClientError`, `action-service.ts:31-46`; see `result-codes.md` §1 "tem — malformed" for the full citation). This reads as a rippled implementation constraint, not a published protocol rule — do not treat "60 seconds" as an XLS-66 floor. Our own defaults (`InterestRate ?? 50000`, `PaymentInterval ?? 60`, `GracePeriod ?? 60` in `action-service.ts:209-211`) simply stay above the observed threshold.

## 7. Where this fits in the composition chain

`LoanBrokerSet.VaultID` attaches the broker to a vault created under XLS-65 (Single Asset Vault); the broker's owner must equal the vault's owner, asserted as an invariant at provisioning time (`assertions.ts:13-26`, per `amendment-map.md`). Loan principal is bounded by the vault's available assets and the broker's cover headroom (`bots/reads.ts:148-167`) — lending capacity is a function of both objects together, not the broker alone.

See also: [Result Codes](../07-reference/result-codes.md) for the full `tec*`/`tem*`/HTTP table, and [Transaction Map](../07-reference/transaction-map.md) for the action-verb → transaction → ledger-object cross-reference.
