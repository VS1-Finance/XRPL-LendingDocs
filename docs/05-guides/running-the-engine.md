---
label: Running the Engine
order: 70
---

# Running the Engine

The engine is a Fastify HTTP service (`packages/engine`) that provisions sessions, dispatches
per-role actions to the ledger, drives the bot pools, and persists all of it to Postgres. This page
covers what it takes to start one process: environment variables, the Postgres dependency, and
startup/shutdown behavior.

## Environment variables

| Variable | Default | Required | Source |
|---|---|---|---|
| `ENGINE_CONFIG` | `./packages/bootstrap/config.example.json` | No | `config.ts:13` |
| `ENGINE_SEED` | — (falls back to the config file's `seed`) | No, but secret if set | `config.ts:19,27` |
| `ENGINE_NETWORK` | — (falls back to the config file's `network`) | No | `config.ts:20,28` |
| `PORT` | `4000` | No | `config.ts:23` |
| `HOST` | `0.0.0.0` | No | `config.ts:24` |
| `CORS_ORIGIN` | permissive (`true`) | No | `app.ts:22` |
| `ENGINE_DATABASE_URL` | — | **Yes** | `store.ts:37-39` |
| `BOT_MAX_ROUNDS` | `20` | No | `bot-service.ts:50` |

`ENGINE_CONFIG` points at a JSON config file validated against the shared `Config` schema
(`loadConfig`, `config.ts:1,14`); the base config is the template every session is provisioned
from, and each session gets its own setup id and derivation seed derived from it, so sessions do
not collide on-chain (`config.ts:3-5`). The path is resolved by Node relative to the process's
current working directory, not relative to the engine package.

`ENGINE_SEED` and `ENGINE_NETWORK`, when set, override the corresponding fields of the loaded base
config (`config.ts:25-29`); when unset, the config file's own `seed`/`network` apply. Both are
`.trim()`-ed before use (`config.ts:19-20`).

> [!WARNING]
> `ENGINE_SEED` derives every account's keys for every session provisioned from this engine
> process. It is a secret and must be supplied through the environment (or a secret store) in any
> deployment, never committed to a config file (`config.ts:16-18`).

`BOT_MAX_ROUNDS` bounds how many scheduler rounds a session's bot pool runs before stopping on its
own — enough for the pool to complete one or two full lifecycles (deposit, originate, repay or
default, withdraw) rather than driving the market forever; starting the pool again resumes it
(`bot-service.ts:47-50`).

## Postgres is a hard dependency

The engine persists every session, seat occupancy, and action to its own Postgres. It refuses to
construct its store — and therefore refuses to start — if `ENGINE_DATABASE_URL` is unset:

```ts
constructor() {
  if (!process.env.ENGINE_DATABASE_URL) {
    throw new Error("ENGINE_DATABASE_URL is required — the engine persists to Postgres (see packages/engine/.env.example)");
  }
  this.db = new PrismaClient();
}
```
(`store.ts:36-41`)

`buildApp` then calls `store.connect()` before constructing any service or registering any route
(`app.ts:24-25`); `connect()` runs `SELECT 1` against the database, so an unreachable Postgres also
fails startup rather than letting the engine accept traffic it cannot durably record
(`store.ts:45-47`).

The package ships a `docker-compose.yml` with a dedicated Postgres 16 container on host port
`5434` — chosen specifically so it never collides with the ingester's history store (default 5432)
or another local Postgres instance (`docker-compose.yml:1-3,12-13`). `packages/engine/.env.example`
gives the matching connection string:

```
ENGINE_DATABASE_URL="postgresql://engine:engine@localhost:5434/engine?schema=public"
```

Bring the database up with `pnpm --filter @lending/engine db:up` (`docker compose up -d`,
`packages/engine/package.json:13`), or `docker compose up -d` from `packages/engine/`.

For what the store persists (sessions, seat occupancy, the action log) and why it is a separate
database from the ingester's history store, see [Persistence](../03-architecture/persistence.md).

## Startup behavior

`main()` loads the engine package's own `.env` (if present) via Node's built-in loader, without
overriding any variable already set in the process environment, so `pnpm engine` works from the
repo root without exporting variables by hand (`main.ts:10-14`). It then loads the engine config,
builds the app, and listens on the configured `host`/`port` (`main.ts:17-19,28`).

`buildApp` (`app.ts:16-48`) wires the process in this order:

1. Register CORS with `CORS_ORIGIN` (`app.ts:22`).
2. Construct `EngineStore` and `connect()` — fail-fast per above (`app.ts:24-25`).
3. Construct `SessionService` and `BotService` over the store and base config (`app.ts:27-28`).
4. Call `sessions.loadPersisted()` — every session previously saved to Postgres is restored into
   memory, its wallets re-derived from the configured seed and each session's stored derivation
   token rather than from any stored key material (`app.ts:30-32`). See
   [Persistence](../03-architecture/persistence.md) for what is stored and
   [Account Derivation](../03-architecture/account-derivation.md) for how the token re-derives
   wallets.
5. Register `/health` and the session, seat, action, and bot routes (`app.ts:34-39`).

On shutdown (`SIGINT`/`SIGTERM`, `main.ts:21-26`, or any `app.close()`), the `onClose` hook stops
every running bot scheduler and disconnects the store (`app.ts:42-45`).

## Running it

From the repo root, using the root `package.json` script:

```sh
pnpm engine
```

This runs `tsx packages/engine/src/main.ts` (`package.json:18`, root). Because `ENGINE_CONFIG`'s
default (`./packages/bootstrap/config.example.json`) is resolved relative to the current working
directory, the engine must be started from the repo root unless `ENGINE_CONFIG` is set to an
absolute path.

A full local invocation, overriding the defaults that matter for a given environment:

```sh
ENGINE_CONFIG=./packages/bootstrap/config.example.json \
ENGINE_DATABASE_URL="postgresql://engine:engine@localhost:5434/engine?schema=public" \
PORT=4000 \
pnpm engine
```

`ENGINE_DATABASE_URL` can also be supplied via `packages/engine/.env`, which `main.ts` loads
automatically (`main.ts:10-14`) — this is how `.env.example` is intended to be used: copy it to
`.env` and adjust.

> [!NOTE]
> `CORS_ORIGIN` defaults to permissive (`origin: true`, `app.ts:22`) so a web app on a different
> local port can call the engine during development. Set `CORS_ORIGIN` to a known origin in any
> deployment — the default allows any origin to call the API.
