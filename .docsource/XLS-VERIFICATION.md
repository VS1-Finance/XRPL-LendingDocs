# XLS Spec Verification — the 4 flagged items

Verified against authoritative XRPL sources (xrpl.org protocol docs + XLS standards repo). These results
override the recon's "VERIFY" flags: 3 are now confirmed FACTS with a citation; 1 stays documented-as-observed.

## ✅ #1 — lsfAccepted = 0x00010000 — CONFIRMED FACT
- **Spec:** xrpl.org Credential ledger-entry: `lsfAccepted = 0x00010000 (65536)`, "the subject has accepted the credential", off by default, enabled by a successful `CredentialAccept`.
- **Our code:** `ledger-lookups.ts:62`, `state-service.ts:31` hardcode `0x00010000` — **exact match.**
- **Doc treatment:** State as fact. Cite: `xrpl.org` Credential ledger-entry reference + XLS-70. Also: reserve burden shifts to subject on accept (issuer's dir → subject's dir) — a documentable detail.
- Source: https://xrpl.org/docs/references/protocol/ledger-data/ledger-entry-types/credential

## ✅ #2 — AcceptedCredentials cap = 1 to 10 — CONFIRMED FACT
- **Spec:** PermissionedDomainSet reference: "A list of 1 to 10 Accepted Credentials objects."
- **Our code:** `config/schema.ts:53-57` `.max(10)` — **exact match.**
- **Doc treatment:** State as fact. Cite: `xrpl.org` PermissionedDomainSet + XLS-80. (No specific error code documented for exceeding; don't invent one.)
- Source: https://xrpl.org/docs/references/protocol/transactions/types/permissioneddomainset

## ✅ #4 — Share scaling: Δshares = Δassets × 10^Scale (first deposit) — CONFIRMED + REFINED
- **Spec (XLS-65):** Vault has a `Scale` field = "power of 10 to multiply asset value by when converting to integer shares." Default 6 for IOU (configurable 0–18); **Scale = 0 for XRP**; 0 for MPT.
  - First deposit into empty vault: `Δ_shares = Δ_assets × σ` where `σ = 10^Scale`.
  - **Subsequent deposits are PROPORTIONAL** (recon didn't know this): `Δ_shares = (Δ_assets × Γ_shares) / Γ_assets`, rounded down.
  - Shares are MPTs; `MPTokenIssuance.AssetScale` = Vault Scale for IOU, else 0.
- **Our evidence:** 30,000 IOU → 30,000,000,000 shares (system-writeup §8) = ×10⁶, consistent with Scale=6 first deposit.
- **Doc treatment:** State the formula as fact (cite XLS-65). CORRECT the "flat ×10⁶" simplification — it's ×10^Scale on first deposit, proportional after, and Scale=0 for XRP (so an XRP vault's shares are 1:1 in drops-equivalent). This makes P-vault MORE accurate.
- Source: XLS-0065 single-asset-vault spec.

## ⚠️ #3 — PaymentInterval / GracePeriod minimum — DOCUMENT AS OBSERVED, do NOT assert a protocol floor
- **Spec (XLS-66):** `PaymentInterval` = "seconds between Loan payments" (UINT32); `GracePeriod` = "seconds after Payment Due Date before Default" (UINT32). **The accessible spec text documents NO minimum value** for either. (Full constraints may live in rippled PR #5270, not the published README.)
- **Our evidence:** our E2E run submitted `PaymentInterval: "30"` and `GracePeriod: "1"` and the ledger returned **`temINVALID` ("The transaction is ill-formed")**; `60`/`60` succeeds. This is an OBSERVED constraint, cite the E2E finding.
- **Doc treatment:** In P-lending (02-protocol/xls66) and API-actions (04-api/actions): state that WE OBSERVED `temINVALID` for interval/grace below 60s on Devnet, cite the test. Add a `> [!NOTE]` that the published XLS-66 text does not document a specific minimum — it appears to be a rippled implementation constraint (reference PR #5270). Do NOT write "the protocol minimum is 60 seconds" as bare fact.
- Sources: XLS-0066 lending-protocol README (no documented min); our e2e-data.json (observed temINVALID).

## Net effect on the content graph
- P-cred (xls70): WARNING #1 → FACT with xrpl.org citation.
- P-domain (xls80): WARNING #2 → FACT with xrpl.org citation.
- P-vault (xls65): WARNING #4 → FACT + refinement (Scale field, proportional subsequent deposits, XRP Scale=0).
- P-lending (xls66) + API-actions: item #3 stays as OBSERVED-behavior + a NOTE that the spec doesn't publish a minimum. Honest, cited, not asserted.
