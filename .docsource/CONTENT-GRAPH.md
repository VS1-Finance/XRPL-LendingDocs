# Documentation Content Graph — XRPL Permissioned Lending Reference

**Target platform:** Retype (folder-structured Markdown + `retype.yml`, sidebar from folder order).
**Cumulative target:** 55–65 pages.
**Governing rule — ZERO HALLUCINATION.** Every page cites either (a) our code as `file:line`, or (b) a real XLS amendment / xrpl-library fact. Anything not verifiable is marked `> [!WARNING] VERIFY` and never asserted.
**Source of truth for writers:** the two recon maps (`docs-recon/code-map.md`, `docs-recon/amendment-map.md`) + the live code. Existing `docs/system-writeup.md`, `docs/vault-interest-frontrunning.md`, and package READMEs are prior art to build on — but three of them are STALE (see "Supersede list") and must not be copied verbatim.

---

## Structure (Retype folder layout)

```
docs/                                 (retype root)
  index.md                            0. Home / landing
  retype.yml                          (config: title, sidebar, favicon)
  01-overview/
    index.md                          1.1 What this is
    the-four-amendments.md            1.2 The amendment stack (exec-level)
    system-at-a-glance.md             1.3 Architecture in one diagram
    glossary.md                       1.4 Glossary & conventions
  02-protocol/                        THE XLS FOUNDATIONS
    index.md                          2.1 How the four amendments compose
    xls65-single-asset-vault.md       2.2 Vault + MPToken shares
    xls66-lending-protocol.md         2.3 Broker, cover, loans
    xls70-credentials.md              2.4 Credential lifecycle
    xls80-permissioned-domains.md     2.5 Domain gating
    composition-and-invariants.md     2.6 The chain + protocol invariants
    ledger-objects-reference.md       2.7 Every object/field we read/write
  03-architecture/
    index.md                          3.1 Package map & dependency layering
    provisioning-sequence.md          3.2 The bootstrap flow (object order)
    account-derivation.md             3.3 Deterministic wallets
    transaction-batching.md           3.4 submitBatch (per-ledger)
    reserve-funding.md                3.5 Per-role reserve sizing
    session-seat-model.md             3.6 Sessions, seats, occupancy
    bot-framework.md                  3.7 Variants, scheduler, scenarios
    persistence.md                    3.8 Engine store + ingester store
    state-and-balances.md             3.9 Live reads (state/balances)
  04-api/                             ENGINE HTTP API REFERENCE
    index.md                          4.1 Conventions, errors, status codes
    sessions.md                       4.2 Session lifecycle routes
    seats.md                          4.3 Seat claim/release
    actions.md                        4.4 The action vocabulary (11 verbs)
    participants.md                   4.5 Runtime add-participant
    bots.md                           4.6 Bot control
    reads.md                          4.7 state / balances / log
  05-guides/                          OPERATOR & INTEGRATOR
    index.md                          5.1 Quickstart (provision → act)
    configuration.md                  5.2 Config schema reference
    running-the-engine.md            5.3 Deploy & environment
    loan-lifecycle-walkthrough.md     5.4 A full loan, end to end
    the-cli-tools.md                  5.5 lifecycle / negatives / ingester CLIs
    signing-integration.md            5.6 The Signer seam (external wallets)
    monitoring.md                     5.7 Prometheus + Grafana stack
  06-security/                        ADVERSARIAL & CORRECTNESS
    index.md                          6.1 Security model & trust boundaries
    negative-suite.md                 6.2 N1–N15 rejection catalogue
    vault-interest-frontrunning.md    6.3 On-chain investigation (port existing)
    invariants-and-guards.md          6.4 Enforced invariants
    end-to-end-verification.md        6.5 The 109-scenario ledger-proof run
  07-reference/                       APPENDICES
    result-codes.md                   7.1 Every tes/tec code we observe
    transaction-map.md                7.2 Action → TxType → object cheat-sheet
    environment-variables.md          7.3 All env vars
    open-items.md                     7.4 Known gaps / verify-against-spec list
```

**Section count:** 8 top-level (incl. home) · **48 leaf pages.** At ~1.2–1.5 pages each average (protocol/api/architecture pages run longer, index pages shorter) this lands at **58–66 cumulative pages** — meets the 50–60 floor with headroom.

---

## Supersede list (existing docs that are STALE — do NOT copy)
- `packages/engine/README.md` route/action table — missing `/sessions/stream`, `/balances`, `/log`, `/participants` + 3 actions. **04-api derives the table from source only.**
- Root `README.md` repo-layout block — lists only shared+bootstrap (predates 6 packages). **03-architecture/index rebuilds it.**
- `config/schema.ts:80` `fundingXrpPerAccount` — legacy, superseded by per-role reserves. **05-guides/configuration marks it legacy.**
- `bootstrap/README.md` order — describes only the IOU/permissioned path; XRP + public branches skip steps. **03-architecture/provisioning-sequence documents all modes.**

## Prior art to PORT (real, keep the substance)
- `docs/vault-interest-frontrunning.md` (258L, real tx hashes) → **06-security/vault-interest-frontrunning.md** (light edit for house style; it is genuine on-chain analysis).
- `docs/system-writeup.md` §5 invariants, §7 adversarial catalogue, §8 evidence → distributed into 02/06 with citations added.

## The four VERIFY-AGAINST-XLS-SPEC items (must appear as `> [!WARNING]` callouts, never as fact)
1. `lsfAccepted` credential flag `= 0x00010000` (hardcoded `ledger-lookups.ts:62`) → 02-protocol/xls70 + 07/result-codes.
2. `AcceptedCredentials` 10-cap (schema + writeup assert) → 02-protocol/xls80.
3. `PaymentInterval`/`GracePeriod` minimums — **our E2E observed a ledger `temINVALID` below 60s**; document as OBSERVED behavior, cite the test, and flag the protocol-minimum claim → 02-protocol/xls66 + 04-api/actions.
4. Share base units `= asset × 10^Scale` (evidenced 30k→30000000000, not asserted in code) → 02-protocol/xls65.

---

## CONTENT GRAPH — per-page work units (delegation-ready)

Each unit: **id · title · owner-section · primary sources (file:line / recon / XLS) · key content · dependencies · est. pages · reviewer focus.**
Writers receive: this row + the two recon maps + read access to the cited files. They must not invent; unverifiable → WARNING callout.

### Wave 0 — Foundation (write FIRST; everything links to these)
| id | title | sources | key content | deps | pg |
|----|-------|---------|-------------|------|----|
| G-glossary | 01-overview/glossary | recon both; accounts.ts:8; seat.ts:7-20 | Terms: seat, occupant, role, participant, setup, session, environment, credential-issuer vs currency-issuer, share (MPToken), cover, broker. Naming conventions. | — | 1.5 |
| G-codes | 07-reference/result-codes | e2e-data.json (8 codes); action-service.ts:31-46; state-service.ts:30-31 | Every observed code: tesSUCCESS + tecNO_AUTH/tecNO_TARGET/tecNO_ENTRY/tecDUPLICATE/tecINSUFFICIENT_FUNDS/tecINSUFFICIENT_PAYMENT/tecLIMIT_EXCEEDED/tecTOO_SOON/tecHAS_OBLIGATIONS + temINVALID. What each means, when we hit it. | — | 2 |
| G-txmap | 07-reference/transaction-map | code-map action table; action-service.ts:73-183 | Cheat-sheet: action verb → XRPL TransactionType → ledger object → seat/role → status. One dense table. | G-codes | 1.5 |

### Wave 1 — Protocol foundations (the XLS spine; highest-value, cite amendment-map heavily)
| id | title | sources | key content | deps | pg |
|----|-------|---------|-------------|------|----|
| P-compose | 02-protocol/index | amendment-map "Composition Map"; steps.ts builder order; system-writeup §1 | The thesis: identity → domain → vault → lending. The 5 composition points. Diagram. | Wave 0 | 2 |
| P-vault | 02-protocol/xls65 | amendment-map XLS-65; steps.ts:186-197; balances-service.ts:65-75; ledger.ts:33-38 | VaultCreate/Deposit/Withdraw/Set/Delete/Clawback per our usage; tfVaultPrivate; MPToken shares; ShareMPTID; MPTAmount; scale. WARNING #4. | P-compose | 3 |
| P-lending | 02-protocol/xls66 | amendment-map XLS-66; steps.ts:210-222; action-service.ts:188-232; reads.ts:148-167 | LoanBrokerSet/Cover*/Loan*/Pay/Manage; bilateral origination (signLoanSetByCounterparty); cover-rate math; time-gated default; tfLoanDefault. WARNING #3. | P-compose | 3.5 |
| P-cred | 02-protocol/xls70 | amendment-map XLS-70; steps.ts:140-152; action-service.ts:104-129; ledger-lookups.ts:48-62 | Create/Accept/Delete; inert-until-accepted; lsfAccepted; credential-issuer distinction. WARNING #1. | P-compose | 2.5 |
| P-domain | 02-protocol/xls80 | amendment-map XLS-80; steps.ts:154-167; action-service.ts:141-158 | PermissionedDomainSet/Delete; AcceptedCredentials; DomainID pinned into vault. WARNING #2. | P-compose | 2 |
| P-invariants | 02-protocol/composition-and-invariants | assertions.ts:13-45; system-writeup §5; reads.ts:148-167 | Single-owner, first-loss floor, share conservation, bilateral origination, time-gated default. Each with the code that enforces/observes it. | P-vault,P-lending | 2.5 |
| P-objects | 02-protocol/ledger-objects-reference | amendment-map objects; state-service.ts:44-104; balances-service.ts | Every ledger object we touch (vault, mptoken, loan_broker, loan, credential, permissioned_domain) + the account_objects type filter + fields read. Table-heavy. | P-* | 3 |

### Wave 2 — Architecture (cite code-map heavily)
| id | title | sources | key content | deps | pg |
|----|-------|---------|-------------|------|----|
| A-map | 03-architecture/index | code-map dependency layering; all package READMEs | 8 packages, one-line each, dependency graph shared←bootstrap←session←engine + standalone consumers. Rebuilds the stale root layout. | Wave 1 | 2 |
| A-provision | 03-architecture/provisioning-sequence | code-map provisioning; provision.ts:71-121; steps.ts | The 7-step object-creation order; IOU vs XRP vs public branches (what each skips); idempotency; fundingPlan. | A-map,P-compose | 3 |
| A-derive | 03-architecture/account-derivation | accounts.ts:22-60 | SHA-256 domain-separated derivation; determinism; role/index scheme; why (no stored keys). | A-map | 1.5 |
| A-batch | 03-architecture/transaction-batching | client.ts:113-190; classifyResult:85-96 | submitBatch: per-account sequence assignment, MAX_PER_ACCOUNT_PER_LEDGER=8, LastLedgerSequence window, retry buckets, 4 attempts. The reviewer artifact. | A-map | 2.5 |
| A-reserve | 03-architecture/reserve-funding | reserves.ts:13-86 | readReserveRates (integer drops), roleReserveDrops, peakObjectCount per role, FEE_HEADROOM. Why integer drops. | A-map | 2 |
| A-session | 03-architecture/session-seat-model | session.ts:10-64; seat.ts:7-68; registry.ts; signer.ts | Session/Seat/Occupant model; open/bot/human exclusivity; registry; ServerSigner + Signer seam. | A-map | 2.5 |
| A-bots | 03-architecture/bot-framework | bots/*; scheduler.ts:27-105; weights.ts; profiles.ts | Variants per role; scheduler rounds; GIVE_UP_AFTER; assignWeighted (seeded); scenarios (calm/defaults/mixed). | A-session | 2.5 |
| A-persist | 03-architecture/persistence | store.ts; both prisma schemas; session-service.ts:164-177 | Engine store (3 models) vs ingester store (idempotent, resetEpoch); NO KEYS STORED (token+seed re-derive). | A-map | 2.5 |
| A-reads | 03-architecture/state-and-balances | state-service.ts:37-105; balances-service.ts:22-75; ledger-lookups.ts | What account_info/account_lines/account_objects each read composes; actNotFound→zero. | A-map,P-objects | 2 |

### Wave 3 — API reference (derive tables from source; ignore stale README)
| id | title | sources | key content | deps | pg |
|----|-------|---------|-------------|------|----|
| API-conv | 04-api/index | routes/*; action-service.ts:31-46; app.ts | Base URL, CORS, JSON, the error model (ActionError.status, CapacityError→409), status-code precedence, SSE note. | Wave 0 | 2 |
| API-sessions | 04-api/sessions | routes/sessions.ts:29-94 | POST /sessions (+ ProvisionBody fields), /stream (SSE), GET list/detail. Request/response examples from real shapes. | API-conv | 2.5 |
| API-seats | 04-api/seats | routes/seats.ts:13-46 | claim/release; 400/404/409 precedence; SeatOccupancyError. | API-conv | 1.5 |
| API-actions | 04-api/actions | routes/actions.ts; action-service.ts:73-232 | All 11 verbs, params each requires, TxType, expected results incl. tec paths. The centerpiece. | API-conv,G-txmap | 3.5 |
| API-part | 04-api/participants | routes/sessions.ts:99-117; add-participant.ts | POST /participants; role; MAX_POOL=20; CapacityError→409; funding+credentialing of new member. | API-conv | 2 |
| API-bots | 04-api/bots | routes/bots.ts:8-22; bot-service.ts | start (intervalSeconds), stop; idempotency; what running means. | API-conv | 1.5 |
| API-reads | 04-api/reads | routes/sessions.ts:75-94; state-service; balances-service | GET state/balances/log — response schemas field-by-field. | API-conv,A-reads | 2 |

### Wave 4 — Guides (task-oriented; lean on code + CLIs)
| id | title | sources | key content | deps | pg |
|----|-------|---------|-------------|------|----|
| GD-quick | 05-guides/index | README; engine config.ts; lifecycle README | Fastest path: env up → provision → claim → act. Copy-paste commands. | Waves 1-3 | 2 |
| GD-config | 05-guides/configuration | config/schema.ts:32-118; config.example.json | Every field, type, default, constraint. Legacy fundingXrpPerAccount flagged. informational-only issuer flagged. | API-conv | 3 |
| GD-run | 05-guides/running-the-engine | config.ts:12-31; app.ts; store.ts:37-39 | ENGINE_* env, PORT/HOST, Postgres requirement, loadPersisted, CORS_ORIGIN. | GD-config | 2 |
| GD-loan | 05-guides/loan-lifecycle-walkthrough | lifecycle/*; e2e groups E/F | Deposit→originate→repay→close AND default path, with the real actions + expected codes. | API-actions,P-lending | 2.5 |
| GD-cli | 05-guides/the-cli-tools | lifecycle/negative-suite/ingester READMEs + cli.ts each | The three runnable CLIs: what each does, how to run. | A-map | 2 |
| GD-sign | 05-guides/signing-integration | signer.ts:12-34 | The Signer interface as the external-wallet seam; ServerSigner as default. | A-session | 1.5 |
| GD-mon | 05-guides/monitoring | monitoring README; queries.yaml; ingester schema | The docker-compose Prometheus/Grafana stack over ingester history. | A-persist | 1.5 |

### Wave 5 — Security & verification (port real material, cite hard)
| id | title | sources | key content | deps | pg |
|----|-------|---------|-------------|------|----|
| S-model | 06-security/index | signer.ts; state-service.ts:77-84; accounts.ts | Trust boundaries: who signs what, no-keys-stored, ledger-enforced (not app-enforced) authorization, credential-vs-currency issuer. | Waves 1-2 | 2.5 |
| S-neg | 06-security/negative-suite | negative-suite/*; system-writeup §7 | N1–N15 catalogue: each case, the attack, the exact rejection code, cite the case file:line. | P-cred,P-lending | 3 |
| S-frontrun | 06-security/vault-interest-frontrunning | PORT docs/vault-interest-frontrunning.md | The real on-chain investigation (Findings A/B/C, tx hashes, fixes). House-style edit only. | P-vault | 3 |
| S-inv | 06-security/invariants-and-guards | assertions.ts; action-service guards; seat.ts | Every engine/protocol guard: single-owner, seat-held auth, role guards (originate), amount validation, capacity. | P-invariants | 2 |
| S-e2e | 06-security/end-to-end-verification | e2e-report.html; e2e-data.json | The 109-scenario ledger-proof run: coverage, methodology, 122 on-chain proofs, link to report. | S-neg | 2 |

### Wave 6 — Reference appendices (mostly tables)
| id | title | sources | key content | deps | pg |
|----|-------|---------|-------------|------|----|
| R-env | 07-reference/environment-variables | config.ts; store.ts; app.ts; ingester cli | All env vars across engine + ingester + monitoring. Table. | GD-run | 1.5 |
| R-open | 07-reference/open-items | the 4 VERIFY items; code-map flags 1-7 | Honest ledger of what's unverified-against-spec, stale, or a known gap (license, informational issuer, partial-add window). | all | 2 |

### Wave 7 — Overview & home (write LAST, after everything exists to summarize)
| id | title | sources | key content | deps | pg |
|----|-------|---------|-------------|------|----|
| O-home | index.md | all | Landing: what it is, who it's for, the 4-amendment one-liner, nav to sections. | all | 1 |
| O-what | 01-overview/index | README; system-writeup §1 | What this is, why it exists (VS1/Foundation reference impl), what it proves. | all | 1.5 |
| O-amend | 01-overview/the-four-amendments | amendment-map; system-writeup §1 | Exec-level: the four XLS in plain language + the chain. Links to 02. | P-compose | 1.5 |
| O-glance | 01-overview/system-at-a-glance | code-map; A-map | One architecture diagram + the request→ledger path in 6 sentences. | A-map | 1.5 |

---

## Delegation protocol (how subagents execute this graph)
1. **Waves are dependency-ordered.** Wave 0 first (foundations everyone links). Waves 1–6 can each fan out in parallel *within* the wave. Wave 7 last.
2. **One subagent per page** (or per small cluster of sibling pages). Each gets: its graph row, both recon maps, the cited files, house-style rules, and the "unverifiable→WARNING, never assert" rule.
3. **Per-page review:** a reviewer checks every factual claim resolves to a citation and no VERIFY item is stated as fact. (Same pattern as the code SDD.)
4. **Cross-link pass:** after pages exist, one pass wires internal links (Retype relative links) + the sidebar order.
5. **Build & publish:** `retype build` locally to catch broken links, then publish (Retype static site, or the HTML as an artifact for preview).

## House style (all pages)
- Every non-obvious factual claim carries a citation: `` (`file.ts:line`) `` for code, `XLS-NN` for spec.
- Unverifiable protocol claims → `> [!WARNING] Verify against XLS-NN: …`.
- Code blocks show REAL signatures/shapes from source, never invented.
- Tables for anything enumerable (routes, verbs, fields, codes, objects).
- Terse, precise, present tense. No marketing. Audience: protocol-literate engineers + institutional reviewers.
- Mermaid for the composition chain, provisioning sequence, request path.
