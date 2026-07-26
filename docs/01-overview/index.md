---
label: What This Is
order: 100
---

# What This Is

## The project

This is a **reference implementation** of permissioned, credential-gated lending on the XRP Ledger,
built for VS1 Finance / the XRP Ledger Foundation. It is not a product: it is a working proof that
four XRPL amendments — designed and specified independently — compose into a single lending platform,
with every claim backed by a validated transaction on real Devnet rather than by specification prose
(README, `lending-reference/README.md:1-16`; system-writeup, `docs/system-writeup.md:1-12`).

The four amendments, and the role each plays in the composition:

- **XLS-70 Credentials** — an issuer attests a typed credential to a subject account.
- **XLS-80 Permissioned Domains** — a domain admits only accounts holding an accepted
  issuer/credential-type pair, capped at ten pairs.
- **XLS-65 Single Asset Vault** — a vault holds one asset, mints fungible shares against deposits,
  and — when a domain is pinned to it — accepts deposits only from domain members.
- **XLS-66 Lending Protocol** — a loan broker attached to the vault originates loans against the
  vault's pooled liquidity, backed by first-loss cover.

(README, `lending-reference/README.md:6-16`.) The composition is documented in full, seam by seam, on
[How the Four Amendments Compose](../02-protocol/index.md).

## What it proves

The system's thesis is that **on-ledger identity gates a vault that funds a lending market** —
access policy enforced by ledger consensus, not by an application checking a database
(`docs/02-protocol/index.md:9-11`). Concretely, the reference implementation demonstrates:

- The four amendments chain so each one's output is the next one's input: a credential feeds the
  domain's accepted-credential list; the domain id is pinned into the vault at creation; the vault id
  is attached to the broker (`docs/system-writeup.md:15-19`).
- The gate is enforced at the protocol level, not in application code: an account without an accepted
  credential cannot deposit into a domain-gated vault — the transaction is rejected in consensus
  (`tecNO_AUTH`), not by a check in front of it (`docs/system-writeup.md:42-45`).
- A complete loan lifecycle — provisioning, credentialing, domain gating, deposit, bilateral
  origination, scheduled repayment, and close — runs end to end on XRPL **Devnet** (`rippled 3.2.0`,
  network id 2), with every step's transaction hash resolvable via a `tx` query
  (`docs/system-writeup.md:10-12`, `docs/status-report.md:6-12`).
- An enumerated adversarial suite (N1-N15, plus the public-vault counterpart P1) asserts the exact
  ledger rejection code for each way the platform must fail closed — credential and domain gating,
  object-lifecycle obligations, permission boundaries, issuer-power typing, cover economics, and time
  gating (`docs/system-writeup.md:339-364`; full catalogue on
  [Negative Suite](../06-security/negative-suite.md)).

> [!NOTE]
> This page cites the project's own framing documents (`system-writeup.md`, `status-report.md`,
> `README.md`) and the confirmed spec facts in `.docsource/XLS-VERIFICATION.md`. Where a claim is
> project-observed behavior rather than a documented protocol rule — for example, minimum
> `PaymentInterval`/`GracePeriod` values — the relevant page states it as observed, not as protocol
> fact.

## The shape

The reference implementation is a pnpm TypeScript monorepo of independent, single-responsibility
packages, layered so that each depends only on the ones below it. Full package map, dependency
graph, and the request-to-ledger path are on [Architecture & Package Map](../03-architecture/index.md);
summarized here:

**A provisioning harness (bootstrap).** A single command stands up a fully wired environment from one
config file — funded accounts, issued and accepted credentials, a permissioned domain, a domain-gated
single-asset vault, and a loan broker with first-loss cover seeded — idempotently, and tears it down
by setup id (README, `lending-reference/README.md:42-70`; `docs/system-writeup.md:176-190`).

**An engine (HTTP API).** A Fastify service that turns a provisioned environment into sessions whose
roles are seats: it claims and releases seats, dispatches per-role actions to the ledger under the
acting seat's signer, drives bots for unheld seats, and reports live state read back from the
validated ledger (`docs/03-architecture/index.md:24,46-51`). Routes are documented on
[Engine HTTP API](../04-api/index.md).

**Bots.** A deterministic transaction generator, not an autonomous agent, that fills every role a
human is not playing — weighted, reproducible behavioral variants (for borrowers: on-time, late,
early, overpayment, default; for depositors: hold, churn, top-up) drawn from a seeded generator, so a
run's bot behavior is inspectable before it executes and reproducible from its seed
(`docs/system-writeup.md:313-334`).

**An off-chain ingester.** A Postgres-backed persistence pipeline that subscribes to the transaction
stream, captures each transaction idempotently (keyed on transaction hash), normalizes it into typed
events carrying the run's setup and correlation ids, and projects current vault/loan/broker/credential
state — the durable source of history once a Devnet reset wipes the chain
(`docs/system-writeup.md:209-229`).

**An adversarial negative suite.** The enumerated N1-N15 (plus P1) rejection catalogue described
above, run on demand against the live network (`docs/system-writeup.md:231-238`).

Two guarantees run across every layer: every state-changing transaction is tagged with a setup id
(which environment) and a correlation id (which action), on-chain and in the store; and all monetary
values are integer base units, never floating point (`docs/system-writeup.md:125-135`).

## Where to go next

- **Integrating against the engine** — start with [Engine HTTP API](../04-api/index.md) for routes,
  request/response shapes, and the error model.
- **Reviewing the protocol composition** — start with
  [How the Four Amendments Compose](../02-protocol/index.md) for the seam-by-seam wiring between the
  four amendments, cited to source.
- **Operating an environment** — start with [Guides](../05-guides/index.md) for the quickstart from a
  clean checkout to a claimed seat and a settled deposit.
- **Assessing trust boundaries** — start with
  [Security Model & Trust Boundaries](../06-security/index.md) for who signs what, what the
  operational database can leak, and the adversarial evidence (negative suite, vault interest
  front-running) backing the claims made there.
- **Looking up a term** — see the [Glossary](./glossary.md) for domain terms defined against the code
  that implements them.
