---
label: End-to-End Verification
order: 50
---

# End-to-End Ledger-Proof Verification

A single run that exercises the live engine against a real XRPL Devnet, scenario by scenario, and records every HTTP result and every on-ledger transaction it produced. All figures on this page are read directly from that run's output, [`e2e-data.json`](../static/e2e-data.json) — nothing here is estimated or rounded.

> [!NOTE]
> **Run artifacts** — both are shipped with these docs:
> - [`e2e-data.json`](../static/e2e-data.json) — the machine-readable run output (every scenario, expectation, result, and transaction hash) that every figure on this page is drawn from.
> - [`e2e-report.html`](../static/e2e-report.html) — a self-contained ledger-proof report where every settled transaction hash is a clickable link to `devnet.xrpl.org`, for independent verification against the public ledger.

## Headline

| Metric | Value | Source |
|---|---|---|
| Scenarios run | 109 | `e2e-data.json:total` |
| Scenarios passed | 109 | `e2e-data.json:passed` |
| Scenarios failed | 0 | `e2e-data.json:failed` |
| On-ledger transactions | 122 | `e2e-data.json:txCount` (matches `len(transactions)`) |
| Engine under test | `http://localhost:4000` | `e2e-data.json:engine` |
| Run window | `2026-07-26T15:31:12.172Z` → `2026-07-26T15:50:02.518Z` | `e2e-data.json:started,finished` |

> [!NOTE]
> 109/109 is scenario-level pass/fail (`results[].ok`), not a transaction count. A scenario can pass without submitting any transaction at all (a 404 check, a state-shape assertion) or can bundle multiple transactions (a provisioning step settles 15–24 on-ledger steps in one scenario). The 122 figure is the separate, flat transaction ledger recorded in `transactions[]`.

## Methodology

Every scenario in the run talks to the live engine over HTTP, which in turn talks to a real XRPL Devnet node — there is no mocking layer in this suite. Two scenario shapes appear:

- **Positive scenarios** submit a real transaction and expect it to settle. The assertion is the ledger's own result code (`tesSUCCESS`) plus, where applicable, a state change visible through the engine's read routes (vault shares, loan `outstanding`, seat occupancy). Each settled transaction carries a real ledger hash, independently verifiable at `devnet.xrpl.org`.
- **Negative scenarios** submit a transaction (or a malformed request) that is *expected* to be rejected, and assert the specific rejection path: an on-ledger `tec*` code (the transaction reached consensus, claimed a fee, and was correctly refused), or an engine-side HTTP status (400/404/409) for a request that never reaches a ledger at all. A `tec*` in this run is not a defect — it is the correct, expected outcome the scenario is checking for. See [Result Codes](../07-reference/result-codes.md) for the full code taxonomy this run's outcomes are drawn from.

Every result row in `results[]` carries `expected` and `actual` fields; the run only records `ok: true` when they match exactly (`e2e-data.json:results[].expected,actual,ok`). All 109 do.

## Coverage by group

The 109 scenarios are organized into 13 lettered groups (`results[].group`). Counts below are the number of scenario rows tallied per group in `results[]`:

| Group | Scenarios | What it covers |
|---|---|---|
| A. Routing & validation negatives | 14 | Health check, session listing, 404s for unknown session on every read/write route, plus the first full provisioning run (permissioned-IOU-core, 24 on-ledger steps). |
| B. Permissioned IOU — reads & structure | 6 | Session-state shape: vault/broker/loans keys present, `credentialIssuer` seat present, all 7 seats funded on-ledger, all 4 pooled members' credentials `accepted`. |
| C. Depositor yield & liquidity | 7 | Deposit, repeat deposit, vault-share accounting, withdraw, overdraw-withdraw rejection, over-balance deposit rejection. |
| D. Owner: cover & vault management | 7 | `deposit-cover`, raising/lowering `set-vault` `AssetsMaximum`, cover and cap rejections, cap restore. |
| E. Full loan lifecycle | 5 | Originate → underpay (`tec*`) → full repay (`tesSUCCESS`) → loan settled with zero outstanding. |
| F. Loan default path | 5 | Originate → premature-default rejection (`tecTOO_SOON`) → delinquency window passes → owner defaults the loan (`tesSUCCESS`). |
| G. Loan & action negatives | 21 | Missing/invalid params across every verb, role guards (non-owner originate, non-borrower counterparty, wrong-seat action), malformed-amount matrix, one settled trimmed-amount deposit. |
| H. Seat lifecycle rules | 9 | Idempotent re-claim, claim-already-held, release-not-held, unknown-seat 404s, missing-participant 400s, one-human-one-seat auto-release, second full provisioning run (credentials, 24 on-ledger steps). |
| I. Credential handshake | 7 | Issue/re-issue, issue to unfunded subject (`tecNO_TARGET`), revoke on never-issued (`tecNO_ENTRY`), revoke then re-issue, missing-subject 400, re-accept (`tecDUPLICATE`). |
| J. Permissioned deposit gating & domain | 3 | Credentialed deposit settles, owner `set-domain` settles, third provisioning run (public vault, 15 on-ledger steps). |
| K. Public (non-permissioned) vault | 10 | No `credentialIssuer` seat, empty credentials list, domain/credential actions rejected with 409 on a public vault, ungated deposit/withdraw/originate/repay all settle, fourth provisioning run (multi-participant, 24 on-ledger steps). |
| L. Runtime add-participant | 10 | Adding depositor/borrower seats at runtime grows the pool live, bad-role 400s, a newly added seat can deposit and receive a loan, the addition is recorded in the action log. |
| M. Bots driving the pool | 5 | Bot start (idempotent on repeat), bots produce a settled on-ledger action, bot stop (idempotent on repeat). |

Four of these groups' scenarios are themselves full provisioning runs, each settling many transactions in one scenario row: permissioned-IOU-core (24 tx, group A), credentials (24 tx, group H), public (15 tx, group J), multi-participant (24 tx, group K) — `e2e-data.json:results[].detail` (`"24 tx"`, `"15 tx"`).

## Result codes observed

The distinct `code` values across all 122 recorded transactions (`transactions[].code`):

| Code | Count | Class |
|---|---|---|
| `tesSUCCESS` | 112 | Settled — every provisioning step plus every clean action |
| `tecINSUFFICIENT_FUNDS` | 3 | Rejected, on-ledger — overdraw withdraw, over-balance deposit, over-balance cover deposit |
| `tecLIMIT_EXCEEDED` | 2 | Rejected, on-ledger — `AssetsMaximum` lowered below current assets; deposit past the cap |
| `tecINSUFFICIENT_PAYMENT` | 1 | Rejected, on-ledger — repay below the scheduled minimum |
| `tecTOO_SOON` | 1 | Rejected, on-ledger — default attempted before the delinquency gate opens |
| `tecNO_TARGET` | 1 | Rejected, on-ledger — credential issued to an unfunded subject |
| `tecNO_ENTRY` | 1 | Rejected, on-ledger — revoke on a subject that never had a credential |
| `tecDUPLICATE` | 1 | Rejected, on-ledger — re-accepting an already-accepted credential |

112 + 3 + 2 + 1 + 1 + 1 + 1 + 1 = 122, the full `transactions[]` count. Every non-`tesSUCCESS` code here is a `tec*` — a transaction that reached consensus, was charged, and was correctly refused. No `tem*` appears in the transaction ledger because a `tem*` rejection never reaches a ledger in the first place (the `originate interval < 60` case in group G is recorded as an HTTP 400 in `results[]`, not as a ledger transaction). See [Result Codes](../07-reference/result-codes.md) for what each code means and every other trigger this system is known to produce, and [Actions](../04-api/actions.md) for the verb each transaction type belongs to.

## Report artifact

The run also emits a self-contained HTML ledger-proof report — [`e2e-report.html`](../static/e2e-report.html) — in which every settled transaction hash is a clickable link to `devnet.xrpl.org`, so a reviewer can independently confirm each transaction against the public ledger without trusting this document or the JSON it was generated from.

> [!NOTE]
> This page is generated from [`e2e-data.json`](../static/e2e-data.json), the machine-readable form of the same run. It does not reproduce the HTML report's hash-by-hash links; open [`e2e-report.html`](../static/e2e-report.html) to click through to `devnet.xrpl.org` for any individual transaction.

## See also

- [Negative Suite](./negative-suite.md) — the dedicated adversarial test suite (`tecNO_AUTH`, `tecHAS_OBLIGATIONS`, and other rejection paths not exercised by this end-to-end run).
- [Actions](../04-api/actions.md) — the 11 action verbs, their required params, and the guard order each request passes through before reaching a ledger.
- [Result Codes](../07-reference/result-codes.md) — the full `tes`/`tec`/`tem`/`ter` catalog and the HTTP status contract, each row cited to an observed transaction or a code path.
