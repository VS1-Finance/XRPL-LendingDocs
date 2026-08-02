---
label: Environment Variables
order: 30
---

# Environment Variables

Every environment variable actually read by the codebase, grouped by component. This covers every
`process.env` read across the monorepo's `packages/*/src`, plus the two places a `DATABASE_URL` is
consumed outside a direct `process.env` call: Prisma's `env()` datasource directive and
docker-compose's `${...}` shell interpolation. No variable below is invented — each has a
`file:line` citation to a real read.

> [!NOTE]
> Only `packages/engine/src` contains direct `process.env.*` reads. The ingester and monitoring
> packages consume `DATABASE_URL` through Prisma's schema-level `env()` directive and Docker
> Compose variable interpolation, respectively — not through `process.env` in TypeScript source.
> Both are still real, required inputs and are documented below.

## Engine (`packages/engine`)

| Variable | Purpose | Default | Required | Source |
|---|---|---|---|---|
| `ENGINE_CONFIG` | Path to the JSON config file used as the template every session is provisioned from | `./packages/bootstrap/config.example.json` | No | `config.ts:13` |
| `ENGINE_SEED` | Overrides the config file's `seed` field — derives every account's keys for every session provisioned from this process. **Secret.** | falls back to config file's `seed` | No (but must be set to a real secret in any deployment) | `config.ts:19,27` |
| `ENGINE_NETWORK` | Overrides the config file's `network` field | falls back to config file's `network` | No | `config.ts:20,28` |
| `PORT` | Fastify listen port | `4000` | No | `config.ts:23` |
| `HOST` | Fastify listen host | `0.0.0.0` | No | `config.ts:24` |
| `CORS_ORIGIN` | `@fastify/cors` `origin` option | `true` (permissive — any origin) | No | `app.ts:22` |
| `LOG_LEVEL` | Fastify logger level | `info` | No | `app.ts:17` |
| `ENGINE_DATABASE_URL` | Postgres connection string for the engine's own operational store (sessions, seat occupancy, action log). **Secret** (embeds DB credentials). | — none | **Yes — fail-fast** | `store.ts:37-39` |
| `BOT_MAX_ROUNDS` | Caps how many scheduler rounds a session's bot pool runs before stopping on its own | `20` | No | `bot-service.ts:50` |
| `XRP_TREASURY_SEED` | Seed of a pre-funded internal treasury wallet that funds XRP vaults directly, instead of the public faucet. **Secret.** When set, XRP-vault provisioning draws reserves and liquidity from this wallet; it is **not** auto-refilled, so provisioning fails fast with a "top up `XRP_TREASURY_SEED`" error if the balance can't cover a pool. Unset falls back to the faucet, so a fresh clone needs no configuration. IOU vaults are unaffected (their liquidity is minted). | falls back to the public faucet | No | `funding.ts` (`resolveTreasury`) |

`ENGINE_DATABASE_URL` is the one hard-required variable in the system: `EngineStore`'s constructor
throws immediately if it is unset, before the store ever attempts a connection —

```ts
constructor() {
  if (!process.env.ENGINE_DATABASE_URL) {
    throw new Error("ENGINE_DATABASE_URL is required — the engine persists to Postgres (see packages/engine/.env.example)");
  }
  this.db = new PrismaClient();
}
```
(`store.ts:36-41`)

`buildApp` then calls `store.connect()` (a `SELECT 1`) before constructing any service or
registering any route, so an unreachable database also fails startup rather than letting the
engine accept traffic it cannot durably persist (`app.ts:24-25`, `store.ts:45-47`).

`packages/engine/.env.example` gives the matching connection string for the package's own
docker-compose Postgres (port 5434, chosen so it never collides with the ingester's history store
on 5432):

```
ENGINE_DATABASE_URL="postgresql://engine:engine@localhost:5434/engine?schema=public"
```
(`.env.example:3`)

`main.ts` loads `packages/engine/.env` automatically via Node's built-in `process.loadEnvFile`,
without overriding any variable already set in the process environment — this is what makes
`pnpm engine` work from the repo root without exporting variables by hand (`main.ts:7-14`).

> [!WARNING]
> `ENGINE_SEED` and `ENGINE_DATABASE_URL` are both secrets. `ENGINE_SEED` derives every account key
> for every session this engine process provisions (`config.ts:16-18`); `ENGINE_DATABASE_URL`
> embeds database credentials. Neither should be committed to a config file or repo — supply both
> through the environment or a secret store in any real deployment.

## Ingester (`packages/ingester`)

| Variable | Purpose | Default | Required | Source |
|---|---|---|---|---|
| `DATABASE_URL` | Postgres connection string for the ingester's history store (transactions, events, outbox, projected state). **Secret.** | — none | Yes (Prisma throws if unset/unreachable) | `prisma/schema.prisma:12` (`env("DATABASE_URL")`); read implicitly by `db.ts:3-8` |

There is no direct `process.env` read in `packages/ingester/src` — `grep -rn "process.env"
packages/ingester --include="*.ts"` returns nothing. `db()` (`db.ts:6-9`) constructs a bare
`new PrismaClient()`; Prisma resolves `DATABASE_URL` itself from the datasource block in
`prisma/schema.prisma:10-13`, which declares `url = env("DATABASE_URL")`. The comment in `db.ts:3`
confirms the intent: *"DATABASE_URL is read from the environment."*

`packages/ingester/.env.example` gives the matching local connection string:

```
DATABASE_URL="postgresql://lending:lending@localhost:5432/lending?schema=public"
```
(`.env.example:2`)

This is a separate database from the engine's — see
[Persistence](../03-architecture/persistence.md) for why the two stores don't share a schema or a
connection string.

## Monitoring (`packages/monitoring`)

| Variable | Purpose | Default | Required | Source |
|---|---|---|---|---|
| `DATABASE_URL` | Same history-store Postgres the ingester writes to; fed into `postgres-exporter`'s `DATA_SOURCE_NAME` via Compose shell interpolation. **Secret.** | — none | Yes (`postgres-exporter` cannot connect without it) | `docker-compose.yml:14` (`DATA_SOURCE_NAME: ${DATABASE_URL}`) |

`packages/monitoring` has no TypeScript source (`code-map.md`; confirmed by `find packages/monitoring
-type f`) — no `process.env` read exists here at all. `DATABASE_URL` is a host-shell variable that
Docker Compose substitutes into the `postgres-exporter` service definition at
`docker-compose.yml:14`; the package's own header comment documents the invocation:

```
DATABASE_URL=postgresql://user:pass@host:5432/db docker compose up
```
(`docker-compose.yml:6`)

This is the **same variable name** as the ingester's `DATABASE_URL` above and is intended to point
at the same Postgres instance — the monitoring stack only ever reads derived state the ingester
already projected; it never queries the engine's store or the XRPL ledger directly (see
[Monitoring](../05-guides/monitoring.md)).

## Summary table

| Variable | Component | Secret | Required | Fail mode |
|---|---|---|---|---|
| `ENGINE_CONFIG` | Engine | No | No | falls back to `./packages/bootstrap/config.example.json` |
| `ENGINE_SEED` | Engine | **Yes** | No | falls back to config file's `seed` |
| `ENGINE_NETWORK` | Engine | No | No | falls back to config file's `network` |
| `PORT` | Engine | No | No | defaults to `4000` |
| `HOST` | Engine | No | No | defaults to `0.0.0.0` |
| `CORS_ORIGIN` | Engine | No | No | defaults to permissive (`true`) |
| `LOG_LEVEL` | Engine | No | No | defaults to `info` |
| `ENGINE_DATABASE_URL` | Engine | **Yes** | **Yes** | throws in `EngineStore` constructor (`store.ts:37-39`) — process never listens |
| `BOT_MAX_ROUNDS` | Engine | No | No | defaults to `20` |
| `DATABASE_URL` | Ingester | **Yes** | Yes (Prisma) | Prisma errors on an unset/unreachable datasource URL |
| `DATABASE_URL` | Monitoring | **Yes** | Yes (compose) | `postgres-exporter` cannot open a connection without it |

See [Running the Engine](../05-guides/running-the-engine.md) for the full engine startup sequence
(`.env` autoload, config resolution order, shutdown hooks) and
[Monitoring](../05-guides/monitoring.md) for the observability stack these variables feed.
