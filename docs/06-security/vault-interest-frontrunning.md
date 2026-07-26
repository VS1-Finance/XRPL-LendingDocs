---
label: Vault Interest Front-Running
order: 70
---

# Vault Interest Front-Running — On-Chain Investigation

**Question investigated:** Can a vault depositor game profit disbursement by depositing immediately before a loan is originated, capturing the share-price increase, and withdrawing — skimming a share of the loan's interest with near-zero exposure and no default risk?

> [!WARNING]
> **Answer: Yes. The exploit completes on-chain.** A depositor who front-runs origination and then redeems their full share balance extracts their proportional share of the loan's entire term interest immediately, before the borrower has paid anything, with no default exposure.

**Amendment context.** Measured on a Devnet running the full lending stack **with the latest cleanup amendments enabled** — `LendingProtocol`, `SingleAssetVault`, `Credentials`, `PermissionedDomains`, `MPTokensV1`, plus **`fixCleanup3_1_3`** (`303ACB16…`) and **`fixCleanup3_2_0`** (`21B8D2F76F68…`), all enabled. This matters: `fixCleanup3_1_3` "corrects loan accounting when loans are defaulted or impaired" and `fixCleanup3_2_0` adds vault "precision and rounding fixes" — yet **neither changes how interest is recognized at origination**. So the up-front interest booking that drives this finding survives the most recent cleanup revisions; it is current behavior, not a stale early-preview artifact. Both cleanup amendments are "Open for Voting" (not yet on Mainnet), which is why this belongs upstream with the amendment authors before the protocol ships.

**Method.** Every claim below is measured against a live public XRPL **Devnet** node (`wss://s.devnet.rippletest.net:51233`, `rippled 3.2.0`), not read from specification prose. A scripted run provisioned a fresh permissioned vault + loan broker, seeded a patient depositor and an attacker, originated a loan, and redeemed the attacker's position. Each transaction cites its validated hash and can be re-fetched with `tx` against that node.

**Captured:** 2026-07-02. Raw evidence: `fullredeem-evidence.json` (machine-readable, every hash).

> [!NOTE]
> **Correction note.** An earlier version of this report concluded the exploit was blocked. That was wrong: it tested withdrawal amounts of 30,001 (above the attacker's fair share) and 30,000 (below it) and never probed the profit interval between them. Redeeming the attacker's **full share balance** — the correct test — realizes the skim. This version supersedes that conclusion.

## Summary

| Question | Answer |
|---|---|
| Does share price rise at origination, before payment? | **Yes** — `AssetsTotal` jumps by the full booked interest. |
| Can a front-runner extract their share of it, immediately? | **Yes** — full-share redemption delivers deposit + proportional skim. |
| Skim realized | **`+0.380518`** on a 30,000 deposit (= 1/3 of the 1.14 interest, the attacker's share) |
| Default risk taken to earn it | **None** — extracted before the borrower paid anything |
| Protocol-level or config error? | **Protocol** — survives on a vanilla public vault; no setup-level guard exists |

The vault recognizes a loan's **entire expected term interest** into share price the instant the loan is set. Because shares can be minted (deposit) and burned (withdraw) at that price freely and instantly, a depositor who is present only across the origination event captures their proportional slice of interest they did not fund and were not exposed to. The patient depositors who hold the loan for its term are diluted by exactly that amount.

## Test environment

| Role | Address |
|---|---|
| Issuer | `r3Bj38E87mKvzhUewGRNWoSKPL3pNzE8L` |
| Vault + broker owner | `rNhu3S9bmvtaccJXr3VDiLdYLVcURWZCBS` |
| Patient depositor (60,000) | `rUqmMtuV2UVXPGH42w7Fk2dSgGoB8MFuUD` |
| Attacker / front-runner (30,000) | `rHaMCBaaDB48Pa4pNmRf7frFWQwNNMSjVu` |
| Borrower | `rD7QWjj8aAu8GpzVXK5WJjwhwjogHbPA9V` |

| Object | ID |
|---|---|
| Single-asset vault (private, domain-gated) | `ECCF19D94396BB0179FE785EEAA541327EC17604A054F758FDB176BBC34012BF` |
| Share MPT issuance | `000000014F0322768EB0A4F55195928E86D2AF9524D20C05` |

Vault asset is an issued currency (an IOU). The patient depositor holds 60,000 and the attacker deposits 30,000 immediately before origination, so the attacker owns **30,000 / 90,000 = 1/3 of the shares**, and the vault is fully liquid (90,000 available) — liquidity is never the binding constraint.

Attacker deposit (30,000): `D414CF1AC0B1158932DD37418AB9336A33BFE433A7B516FAE638414C2B4DE92B`

## Finding A — The share price rises at origination, by the full booked interest, before any payment

The loan was originated with a bilateral `LoanSet`. Vault totals were read from the validated ledger immediately before and after, with **no payment in between**.

| Snapshot | `AssetsTotal` | `AssetsAvailable` |
|---|---|---|
| Before `LoanSet` | `90000` | `90000` |
| Immediately after `LoanSet` | **`90001.14155251138`** | `80000` |

- **`AssetsTotal` jumped by `1.141553` at origination**, before the borrower paid anything.
- The loan's booked interest is `TotalValueOutstanding − PrincipalOutstanding` = `10001.14155251138 − 10000` = **`1.141553`** — identical to the jump.
- `AssetsAvailable` fell by `10000` (the principal delivered to the borrower inside `LoanSet`).

`LoanSet` (bilateral): `A5A84B56391543014F2BD70C6187CCCF427089121F2D7C1B620769CB470FB699`

Loan object at origination:

```
PrincipalOutstanding   10000
TotalValueOutstanding  10001.14155251138
InterestRate           100000  (the ledger's maximum; interest is pro-rated for the term)
PaymentInterval        3600   GracePeriod 3600   PaymentRemaining 1
```

## Finding B — Full-share redemption extracts the attacker's proportional skim

The attacker owns 1/3 of the shares. After the `+1.141553` booking, their shares are worth `90001.14155251138 / 3 ≈ 30000.380518` — their 30,000 deposit **plus** one-third of the booked interest. The decisive test redeems the attacker's **entire** share balance (burning all shares via an MPT-amount withdrawal) and measures delivered assets against the 30,000 deposited.

| Quantity | Value |
|---|---|
| Attacker shares redeemed | `30000000000` (all of them) |
| Withdrawal result | **`tesSUCCESS`** |
| Assets delivered | **`30000.380518`** |
| Deposited | `30000` |
| **Net skim** | **`+0.380518`** |
| Shares remaining after | `0` |

**The redemption succeeded and returned more than was deposited.** The `+0.380518` is exactly the attacker's 1/3 of the `1.141553` interest booked at origination — captured with no term exposure and no default risk, since the borrower had not paid a thing.

Full-share redemption: `9D4815E7B25AF9CABA4068B81B5AEC3F3371E51AC1D81D42881CCDCBF3A3E05D`

> [!NOTE]
> **Verify from the transaction metadata, not the explorer's `Amount` field.** The submitted `Amount` is an **MPT (share) amount** — `{ mpt_issuance_id: <share MPT>, value: "30000000000" }`, i.e. burn all 30,000,000,000 shares — but some explorers render this as a bare `30000`, which looks misleadingly like a plain 30,000-asset withdrawal (the control case). The proof is in the affected nodes of this transaction:

| Ledger effect (from tx metadata) | Before → After | Change |
|---|---|---|
| Attacker's IOU trust-line balance | `70000` → `100000.3805175038` | **+`30000.380518`** delivered |
| Attacker's share MPToken | `30000000000` → deleted | all shares burned |
| Share issuance `OutstandingAmount` | `90000000000` → `60000000000` | −30,000,000,000 |
| Vault `AssetsTotal` | `90001.14155251138` → `60000.76103500759` | −`30000.380518` |
| Vault `AssetsAvailable` | `80000` → `49999.61948249621` | −`30000.380518` |

The attacker's own balance rose by `30000.380518` against a 30,000 deposit — a `+0.380518` skim, recorded in the ledger's metadata for this single transaction, independent of any off-chain arithmetic.

### Why the earlier test missed it

The attacker's fair share value is `30000.380518`. The prior report tested:

- `30001` → `tecINSUFFICIENT_FUNDS`. This is **above** `30000.380518`; the attacker genuinely does not own that many shares' worth, so rejection is correct and uninformative.
- `30000` → success, delivering exactly 30,000 but leaving **leftover shares**. This is **below** `30000.380518`; it deliberately under-withdrew, and the leftover shares *were the unclaimed skim*, not an unconvertible paper claim.

The profit interval `(30000, 30000.380518]` was never probed. Redeeming by **share count** rather than guessing an asset amount removes the ambiguity and settles it: the skim is real and extractable.

## Interpretation

Both halves of the claim now hold on-chain:

1. **The mechanism is real** (Finding A): the vault books a loan's full expected interest into share price at origination, before it is earned — the asymmetry noted in the original scenario (gains up-front, losses marked down before bad loans) is confirmed.
2. **The exploit completes** (Finding B): a front-runner redeeming their full position extracts their proportional share of that unearned interest immediately, diluting the patient depositors who fund the loan for its term.

The value is not created — it is transferred from patient depositors to the front-runner. The front-runner takes interest-rate risk and default risk for *seconds*; the patient depositor takes it for the full term but shares the yield with anyone who was present at the origination block.

This is a genuine economic vulnerability in profit disbursement, exactly as originally flagged.

## Finding C — This is protocol-level, not a configuration error

Two follow-up tests establish that the vulnerability lives in the amendment logic, not in how this vault was provisioned.

### C1 — The skim survives on a vanilla, public, ordinary-rate vault

The test was re-run stripping every setup choice that could be blamed: a **public** vault (`Flags = 0`, no `tfVaultPrivate`), with **no permissioned domain and no credentials**, at an **ordinary 10% interest rate** (`InterestRate = 10000`, not the earlier `100000` maximum).

| | Permissioned vault (Findings A/B) | Vanilla public vault (C1) |
|---|---|---|
| Vault flags | private, domain-gated | `0` (public, no domain) |
| Interest rate | `100000` (max) | `10000` (10%) |
| `AssetsTotal` jump at `LoanSet` | `1.141553` | `0.114155` |
| Net skim on full redemption | `+0.380518` | **`+0.038052`** |
| Result | `tesSUCCESS` | **`tesSUCCESS`** |

The skim shrinks in proportion to the interest rate (one-tenth the rate → one-tenth the skim) but the mechanism is **identical and still profitable** with zero permissioned configuration. The setup parameters (rate, term, loan-to-vault ratio) control only the *magnitude*; they do not create the vulnerability. Share-price computation, up-front interest recognition, and mint/burn-at-current-price are all amendment logic, not vault knobs.

Vanilla `LoanSet` (10%): `7AE36D2228396002FC…` — full hash in `vanilla-evidence.json`
Vanilla full-share redemption: `A20412630AC5A6290E…` — full hash in `vanilla-evidence.json`

### C2 — No setup-level mitigation exists in this amendment build

The transaction models were enumerated for any vault-side fee or holding-period parameter that an operator could set as a stopgap. There is **none**:

- `VaultCreate` exposes `Asset`, `Data`, `AssetsMaximum`, `MPTokenMetadata`, `WithdrawalPolicy`, `DomainID`, `Scale` — no withdrawal fee, no deposit fee, no lock-up/holding-period.
- `VaultSet` (mutable after creation) exposes only `Data`, `AssetsMaximum`, `DomainID`.
- `VaultWithdraw` / `VaultDeposit` carry no fee or timelock field.
- Every fee in the amendment (`LoanOriginationFee`, `LoanServiceFee`, `LatePaymentFee`, `ClosePaymentFee`, `OverpaymentFee`, `ManagementFeeRate`) is charged on the **loan**, to the borrower — none apply to share redemption.

So a vault operator **cannot** configure a redemption fee or a minimum holding period against this front-run. The only levers are protocol-level. This is why the finding belongs upstream with the amendment authors rather than as a deployment note.

See [XLS-65 — Single Asset Vault](../02-protocol/xls65-single-asset-vault.md) for the full `VaultCreate`/`VaultSet` field reference and the share-accounting math (`Scale`, mint/burn conversion) that underlies both findings.

## Recommended fixes

For the protocol authors to weigh. Only the first is available today; the other two would require new amendment fields.

| # | Fix | Availability |
|---|---|---|
| 1 | **Accrue interest over the term, not at origination.** Recognize interest into `AssetsTotal` gradually as it is earned (or as payments arrive) rather than booking the full expected amount at `LoanSet`. This removes the instantaneous price jump that makes the front-run possible, and is the root-cause fix. The mirror guard already exists on the loss side — extending symmetric treatment to the gain side is the principled version of this. | **Purely protocol-level; no configuration equivalent exists.** |
| 2 | **Redemption lock-up / minimum holding period.** | Would require a *new* vault field; **not currently expressible** in this amendment build (see C2). |
| 3 | **Redemption/deposit fee.** | Would require a *new* vault fee field; **not currently expressible** either (all fees are loan-side, charged to the borrower). |

Even a fee or lock-up (were they added) only makes extraction unprofitable while leaving the shares mispriced; option 1 corrects the mispricing itself.

## Reproducibility

All results come from scripted runs against `wss://s.devnet.rippletest.net:51233` (`rippled 3.2.0`, a **pre-release amendment build**), captured 2026-07-02. Every hash above resolves via `tx` on that node; the `LoanSet` bookings and both full-share redemptions (permissioned and vanilla) were re-fetched and confirmed `validated=true`. Machine-readable evidence — all hashes plus the pre/post vault snapshots and computed fair-share values — is in `fullredeem-evidence.json` (Findings A/B) and `vanilla-evidence.json` (Finding C1).

Because this is a pre-release amendment build, a genuine mispricing here belongs upstream with the amendment authors. The behavior should be reproduced on the current build before escalation, since a pre-release build can change.

## Related pages

- [Security model](./index.md) — how this finding fits the broader security posture.
- [XLS-65 — Single Asset Vault](../02-protocol/xls65-single-asset-vault.md) — vault share accounting, `AssetsTotal`/`AssetsAvailable`, and the `VaultDeposit`/`VaultWithdraw` transaction shapes referenced above.
