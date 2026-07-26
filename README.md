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

Build the static site first, then build and run the nginx image that serves it:

```bash
npx retypeapp build                            # renders docs/ → .retype/
docker build -t xrpl-lending-docs .
docker run --rm -p 8080:80 xrpl-lending-docs   # http://localhost:8080
```

The image only serves the pre-built `.retype/` output — the retype toolchain is not shipped in the
container — so the image stays small (~85 MB) and the build has no network dependency.
