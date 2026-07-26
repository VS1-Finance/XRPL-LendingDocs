---
label: Negative Suite (N1-N15)
order: 80
---

# The Negative Suite

`@lending/negative-suite` is an adversarial test suite: each case drives a disallowed (or
loss-bearing) action against a live, freshly provisioned environment and asserts the exact engine
result the ledger returns (`packages/negative-suite/README.md:3-8`). The suite does not assert codes
guessed from prose — a case passes only when the ledger reproduces the outcome the case's author
observed on-chain (`README.md:7-8`).

This matters because a `tec*` rejection is not an engine bug — it is the ledger doing its job. The
negative suite exists to catch the opposite failure: a regression that silently changes which code a
rejection returns, or turns a rejection into a `tesSUCCESS`. See [Result Codes](../07-reference/result-codes.md)
for the general `tes`/`tec`/`tem`/`ter` taxonomy this page's codes belong to.

> [!NOTE]
> Every case below was confirmed against the case source in `packages/negative-suite/src/cases/credentials.ts`
> (N1-N5, P1) and `packages/negative-suite/src/cases/lending.ts` (N6-N15), not taken from the
> package README alone. Both files were read in full for this page.

## How a case runs

Each case is a `NegativeCase`: an id, title, the invariant it `guards`, an `expected` outcome, an
optional `appliesTo(env)` predicate, and a `run(ctx)` that performs the attack
(`packages/negative-suite/src/types.ts:30-43`). `Expectation` is one of four kinds
(`types.ts:9-13`):

| Kind | Meaning |
|---|---|
| `reject` | the ledger must return one specific `code` |
| `reject-any` | any of a list of `codes` satisfies the case (kept broad so an acceptable code change doesn't break the case) |
| `success` | the action must settle `tesSUCCESS` (a correctness case, not a rejection) |
| `deferred` | reported but not executed — the outcome is a pending protocol decision, not an observable code |

The runner (`packages/negative-suite/src/runner.ts:22-71`) provisions a base environment for the
non-loan cases and, separately, a dedicated fresh environment per loan-originating case
(`N11`-`N15`, since one broker holds only one loan at a time on this build — `runner.ts:8-11,49-60`).
A per-run nonce is folded into the seed so re-running the suite never collides with a previous run's
leftover on-chain state (`runner.ts:30-32,113-115`).

Submission goes through two helpers in `packages/negative-suite/src/assert.ts`:

- `submitExpectReject` (`assert.ts:9-29`) autofills and submits the transaction, and captures the
  observed code whether it comes back in `meta.TransactionResult` from a validated ledger, or is
  thrown client-side at preflight (a malformed or bad-signer transaction that never reaches
  consensus) — either way the case gets a code to compare, not an unhandled exception.
- `submitExpectSuccess` (`assert.ts:32-47`) does the same for the correctness case (N9) and asserts
  `tesSUCCESS`.

`evaluate()` (`assert.ts:50-61`) matches the observed code against the expectation; `matchesCode`
(`assert.ts:66-68`) accepts either an exact match or a substring match, since a client-side throw can
carry a longer message (e.g. `temBAD_SIGNER: ...`) around the bare code.

A case whose `appliesTo(env)` returns `false` for the provisioned environment is reported **skipped**,
not failed or passed (`runner.ts:76-79`, `types.ts:36-38,52-54`) — this is how the same catalogue
stays honest across both a permissioned (domain-gated) vault and a public vault.

## The catalogue

| Case | Attack | Asserted outcome | Source |
|---|---|---|---|
| N1 | Deposit into the vault with no credential at all | `tecNO_AUTH` | `credentials.ts:21-31` |
| N2 | Deposit holding an accepted credential of the wrong type (not the type the domain admits) | `tecNO_AUTH` | `credentials.ts:34-45` |
| N3 | Deposit holding the right credential type but issued by a rogue, unrecognized issuer | `tecNO_AUTH` | `credentials.ts:49-63` |
| N4 | Deposit by a member whose credential was just revoked | `tecNO_AUTH` | `credentials.ts:67-81` |
| N5 | Transfer a vault share (share-MPT `Payment`) to a non-member | `tecNO_AUTH` | `credentials.ts:85-101` |
| N6 | Issuer/credential rotation mid-flight | deferred — not asserted | `lending.ts:11-19` |
| N7 | `VaultDelete` on a vault that still has a `LoanBroker` attached | `tecHAS_OBLIGATIONS` | `lending.ts:23-35` |
| N8 | `VaultClawback` against an account that never held vault shares | `tecNO_AUTH` (`reject-any`, also accepts `tecPRECISION_LOSS`/`tecNO_PERMISSION`/`tecNO_LINE`/`tecNO_ENTRY`) | `lending.ts:41-60` |
| N9 | Depositor withdraws under a cover-protected loss | `tesSUCCESS` (correctness case) | `lending.ts:65-80` |
| N10 | `LoanSet` origination signed by only the owner (no counterparty signature) | rejected (`reject-any`: `temBAD_SIGNER`/`temMALFORMED`/`Counterparty`) | `lending.ts:84-103` |
| N11 | An unrelated stranger submits `LoanPay` against another account's loan | `tecNO_PERMISSION` | `lending.ts:107-127` |
| N12 | `LoanPay` above the amount due, with the `tfLoanOverpayment` flag (65536) set | `tecNO_PERMISSION` | `lending.ts:132-150` |
| N13 | `LoanBrokerCoverWithdraw` of the full cover while a loan is active (drops the cover below the floor backing outstanding debt) | `tecINSUFFICIENT_FUNDS` | `lending.ts:154-171` |
| N14 | `LoanManage` with `tfLoanDefault` (65536) before the payment window plus grace period has elapsed | `tecTOO_SOON` | `lending.ts:175-192` |
| N15 | `LoanDelete` on a loan that still has outstanding debt | `tecHAS_OBLIGATIONS` | `lending.ts:195-210` |
| P1 | Public-vault counterpart to N1: deposit with no credential, against a vault with no domain | `tesSUCCESS` | `credentials.ts:107-123` |

All fifteen `tec*`/rejection codes above were read directly from the `expected` field in each case
object in `credentials.ts` and `lending.ts` — not inferred from the README table, though the two
agree everywhere they overlap (`packages/negative-suite/README.md:12-28`).

## Case notes

**N1-N5 — the deposit-side domain gate.** These five apply only when the environment has a
permissioned (domain-gated) vault — guarded by `appliesTo: permissionedOnly`, defined as
`env.credentialType !== undefined` (`credentials.ts:11`). A public vault has no domain and no gate,
so N1-N5 are skipped there; P1 asserts the mirror-image behavior on exactly that configuration
(`credentials.ts:9-10,103-106`). N3's rogue issuer is a second, freshly funded account that issues and
has accepted its own credential of the right type/hex — proving the rejection is about the issuer's
identity, not the credential's shape (`credentials.ts:49-63`). N4 revokes a second depositor's
credential (provisioning always gives the suite at least two depositors, `runner.ts:34-35,98`) so the
primary depositor's state is undisturbed (`credentials.ts:74-75`).

**N8 — issuer-power typing.** Clawback is an issued-asset issuer power; XRP has no clawback, so this
case's `appliesTo` requires `env.asset.issuer !== undefined` and is skipped on an XRP vault
(`lending.ts:47`). The expectation is `reject-any` across five codes rather than one exact code — the
comment in source says the point is that the issuer power has no authorized target to act against,
and several distinct engine paths could produce that outcome depending on ledger state; a *success*
is what would fail the case, not which of the five codes comes back (`lending.ts:37-46`).

**N9 — correctness, not rejection.** Under a cover-protected default, first-loss broker capital
absorbs the loss before depositors do, so a depositor's `VaultWithdraw` still returns value and must
settle `tesSUCCESS` (`lending.ts:62-69`). This is the suite's only pure correctness assertion (besides
P1); everything else in the catalogue is an expected rejection.

**N12 — the overpayment-flag finding.** The case's own comment states the observed behavior
precisely: a payment above the amount due is accepted *without* the overpayment flag, and is
**rejected** with `tecNO_PERMISSION` when `tfLoanOverpayment` (flag value `65536`) *is* set
(`lending.ts:129-131,141`). That is the inverse of what the flag's name suggests — a caller might
expect the flag to be what *permits* an overpayment, not what triggers its rejection. The suite
asserts the rejection this flag actually produces, not the naive reading of its name
(`lending.ts:132-150`).

**N13 — the cover floor.** The case first funds the vault, originates a live loan against the broker,
then has the owner attempt to withdraw the *entire* cover balance in one `LoanBrokerCoverWithdraw`
(`lending.ts:159-169`). With the loan active, the cover is backing that loan's outstanding debt, so
withdrawing all of it would drop cover below the required floor — rejected `tecINSUFFICIENT_FUNDS`.

**N14 — the time gate.** `LoanManage` with `tfLoanDefault` is submitted immediately after origination,
well before `SHORT_TERM`'s `paymentInterval: 60` plus `gracePeriod: 60` seconds have elapsed
(`lending.ts:6,175-192`) — asserting `tecTOO_SOON`. [Result Codes §1](../07-reference/result-codes.md)
documents the same gate's formula (`defaultableAt = NextPaymentDueDate + GracePeriod`,
`state-service.ts:57-59`) and the companion E2E observation that the identical action settles
`tesSUCCESS` once that window passes.

**N7 / N15 — object-lifecycle obligations.** Both assert `tecHAS_OBLIGATIONS`: N7 on `VaultDelete`
while a `LoanBroker` is still attached to the vault (`lending.ts:23-35`), N15 on `LoanDelete` while the
loan still carries outstanding debt (`lending.ts:195-210`). Neither object can be torn down while it
still represents a live claim.

## What the suite proves — and what it doesn't

Every rejection boundary in this catalogue is enforced **by the ledger itself**, not by the engine or
any off-chain check. The suite's cases submit real transactions through `xrpl.js` against a live
network and read back `meta.TransactionResult` (or a client-side preflight throw) — there is no mock
or simulated rejection anywhere in this path (`assert.ts:9-47`). What the suite adds on top of that is
the assertion of the **exact** code, not merely "did it fail": `evaluate()` fails a case that rejects
with the wrong code just as it fails one that unexpectedly succeeds (`assert.ts:50-61`). That is the
guard against a silent regression — a protocol or engine change that alters *which* rejection comes
back would be caught even though the transaction still fails.

Two cases are explicitly outside that guarantee. N6 (issuer rotation mid-flight) is reported without
being run at all — the suite's own author judged the intended outcome to be an open protocol
question, not a settled code to assert (`lending.ts:8-19`, `types.ts:7-8`). N8 widens its assertion to
five acceptable codes rather than pinning one, trading precision for resilience to a code change on a
path the author considered secondary to the point being tested (`lending.ts:37-46`). Both choices are
in the source, not omissions from this page.

> [!NOTE]
> Result counting: a run's `ran`/`passed` totals exclude both `skipped` cases (not applicable to the
> provisioned vault mode) and the one `deferred` case, N6 (`runner.ts:66-69`). A full permissioned run
> exercises all fifteen N-cases; a public-vault run skips N1-N5 and N8 is skipped or not depending on
> the configured asset, while P1 runs in their place.

## Running it

```sh
negatives run --config ./packages/bootstrap/config.example.json
negatives run --config ./packages/bootstrap/config.example.json --only N1,N7,N14
```

The suite provisions its own environments from the given config and writes a results record to
`out/<setup-id>.negatives.json`, exiting non-zero if any asserted (non-skipped, non-deferred) case
fails (`packages/negative-suite/README.md:34-44`).

## See also

- [Result Codes](../07-reference/result-codes.md) — the full `tes`/`tec`/`tem`/`ter` taxonomy these
  cases' codes belong to, including the E2E-run evidence for codes this suite shares with the
  broader engine (`tecNO_AUTH`, `tecINSUFFICIENT_FUNDS`, `tecTOO_SOON`, `tecHAS_OBLIGATIONS`).
- [index](./index.md) — security section landing page.
