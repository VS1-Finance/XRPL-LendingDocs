# XRPL Permissioned Lending — Documentation

Institutional-grade documentation for the XRPL Permissioned Lending reference implementation — a
credential-gated lending platform on the XRP Ledger composing four amendments (XLS-65 Single Asset
Vault, XLS-66 Lending Protocol, XLS-70 Credentials, XLS-80 Permissioned Domains).

Built with [Retype](https://retype.com). Every factual claim traces to the implementation source or a
published XLS specification.

## Contents

- **Overview** — what it is, the four amendments, the system at a glance
- **Protocol Foundations** — each XLS amendment as used here, how they compose, the ledger objects
- **Architecture** — provisioning, per-ledger batching, sessions and seats, persistence
- **Engine API** — the HTTP API: sessions, seats, the action vocabulary, reads
- **Guides** — quickstart, configuration, deployment, a full loan walkthrough, the CLIs
- **Security** — trust boundaries, the N1–N15 adversarial suite, on-chain investigations
- **Reference** — result codes, transaction map, environment variables, open items

## Develop

```bash
npm install
npx retypeapp start     # live preview at http://localhost:5000
npx retypeapp build     # static site → .retype/
```

## Run with Docker

The image builds the site from source (no host pre-build needed) and serves it from nginx:

```bash
docker build -t xrpl-lending-docs .
docker run --rm -p 8080:80 xrpl-lending-docs   # http://localhost:8080
```

A multi-stage build renders `docs/` in a Node stage, then copies the static output into a small nginx
image. It builds from a plain git checkout, so any platform that builds from the repo (EasyPanel, CI)
can deploy it directly — point it at this repo, and it exposes port 80.
