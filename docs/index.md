---
label: Home
order: 100
icon: home
---

# XRPL Permissioned Lending

A reference implementation of permissioned, credential-gated lending on the XRP Ledger. It composes
five ledger amendments into one working platform, provisioned and exercised end to end on the XRPL
Devnet.

> **On-ledger identity gates a vault that funds a lending market — stood up atomically.**

Four amendments chain so that each one's output is the next one's input:

- **XLS-70 Credentials** — an issuer grants a credential; the subject accepts it. On-ledger identity.
- **XLS-80 Permissioned Domains** — a domain admits holders of specific credentials. A membership gate.
- **XLS-65 Single Asset Vault** — depositors supply an asset and receive shares (MPTokens). Pooled capital.
- **XLS-66 Lending Protocol** — a broker on the vault originates loans, backed by first-loss cover.

A fifth amendment holds it all together:

- **XLS-56 Batch** — cross-account setup steps commit as one all-or-nothing transaction. The atomicity layer.

The [Protocol Foundations](./02-protocol/index.md) section documents each amendment as this system uses
it, with citations to the code and the XLS specifications.

## Who this is for

Protocol engineers evaluating the amendment stack, integrators building on the engine's HTTP API, and
institutional reviewers assessing correctness and trust boundaries.

## What is verified

The system runs live on the XRP Ledger Devnet. A 109-scenario end-to-end run produced **109 passing
scenarios and 122 on-ledger transaction proofs**, each linkable to the public explorer. Authorization is
enforced by the ledger, not by application logic. See
[End-to-End Verification](./06-security/end-to-end-verification.md) and the
[Security Model](./06-security/index.md).

## Navigate

| Section | What it covers |
|---|---|
| [Overview](./01-overview/index.md) | What this is, the amendments in plain language, the system at a glance. |
| [Protocol Foundations](./02-protocol/index.md) | The five XLS amendments, how they compose, and the ledger objects. |
| [Architecture](./03-architecture/index.md) | Provisioning, per-ledger batching, sessions and seats, persistence. |
| [Engine API](./04-api/index.md) | The HTTP API — sessions, seats, the action vocabulary, reads. |
| [Guides](./05-guides/index.md) | Quickstart, configuration, deployment, a full loan walkthrough, the CLIs. |
| [Security](./06-security/index.md) | Trust boundaries, the N1–N15 adversarial suite, and the on-chain investigations. |
| [Reference](./07-reference/result-codes.md) | Result codes, the transaction map, and environment variables. |
