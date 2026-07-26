---
label: Guides
order: 90
icon: rocket
---

# Quickstart

The fastest path from a clean checkout to a claimed seat and a settled `deposit`. Every command
below is quoted from the repository — the engine command from `packages/engine/README.md:11`, the
bootstrap command from the root `README.md:52`, and every `curl` from the route shapes documented
in [the Engine API](../04-api/index.md).

## Prerequisites

| Requirement | Why | Source |
|---|---|---|
| Node ≥ 22, pnpm 10 | Workspace toolchain. | root `README.md:33-34` |
| A reachable Postgres | The engine fails fast at boot if `ENGINE_DATABASE_URL` is unset (`store.ts:37-39`) — this is not optional. | `store.ts:33-41` |
| `ENGINE_DATABASE_URL` | Connection string for the engine's own operational store (sessions, seat occupancy, action log) — separate from the ingester's history database. | `packages/engine/.env.example:1-3` |
| `ENGINE_SEED` | Overrides the base config's `seed`; this is the secret every session's accounts derive from, so it belongs in the environment, not the committed config file. | `config.ts:16-19,27` |

> [!NOTE]
> `packages/engine/src/main.ts` loads `packages/engine/.env` automatically if that file exists
> (`main.ts:9-14`), and never overrides a variable already set in the process environment. Putting
> `ENGINE_DATABASE_URL` and `ENGINE_SEED` in `packages/engine/.env` means `pnpm engine` picks them up
> with no export step.

### Postgres for the engine

`packages/engine/docker-compose.yml` provisions the engine's Postgres, mapped to host port `5434` so
it never collides with the ingester's history database (default `5432`) or another local instance
(`docker-compose.yml:1-3,12-13`):

```sh
cd packages/engine
docker compose up -d
```

This starts a `postgres:16` container (`engine`/`engine`/`engine` for user/password/db,
`docker-compose.yml:6-11`) reachable at the connection string already shown in
`packages/engine/.env.example:3`:

```
ENGINE_DATABASE_URL="postgresql://engine:engine@localhost:5434/engine?schema=public"
```

Copy that file to `packages/engine/.env` (or export the variable yourself) before starting the
engine.

## Install

```sh
pnpm install
```

(root `README.md:39`)

## Start the engine

```sh
ENGINE_CONFIG=./packages/bootstrap/config.example.json PORT=4000 pnpm engine
```

(`packages/engine/README.md:11`; `pnpm engine` runs `tsx packages/engine/src/main.ts`, root
`package.json` `scripts.engine`). The engine listens on `PORT` (default `4000`) and `HOST` (default
`0.0.0.0`) (`config.ts:22-24`); `ENGINE_CONFIG` selects the base provisioning config every session is
templated from (default `./packages/bootstrap/config.example.json`, `config.ts:13`).

> [!WARNING]
> The store connection happens before the app accepts traffic — `EngineStore.connect()` runs a
> `SELECT 1` at boot and the process throws if Postgres is unreachable (`store.ts:37-39,45-47`,
> `app.ts:24-25`). Bring Postgres up first.

Confirm it's live:

```sh
curl http://localhost:4000/health
```

```json
{ "status": "ok" }
```

(`app.ts:34`)

> [!NOTE]
> This quickstart runs the engine directly against a live session. The standalone bootstrap harness
> (`pnpm bootstrap --config ./packages/bootstrap/config.example.json`, root `README.md:52`) provisions
> the same kind of environment outside the engine and is documented separately — see
> [the provisioning sequence](../03-architecture/index.md) and `packages/bootstrap/README.md`. The
> engine's `POST /sessions` runs that same recipe internally per session (`session-service.ts:62-122`).

## Provision a session

```sh
curl -X POST http://localhost:4000/sessions \
  -H 'Content-Type: application/json' \
  -d '{ "label": "quickstart", "permissioned": false }'
```

`permissioned: false` drops the domain/credential steps and provisions a public, non-gated vault —
the fastest environment to stand up (`session-service.ts:96-98`). Every field on the request body is
optional (`ProvisionBody`, `routes/sessions.ts:9-22`); omitting `asset` keeps the base config's asset.

> [!WARNING]
> `POST /sessions` is a **blocking call that provisions on a live ledger** — funding, optional
> issuer/credential/domain steps, vault creation, broker creation, cover deposit. Per the route's own
> comment this "takes as long as a full environment provision" (`routes/sessions.ts:27-28`) — minutes,
> not milliseconds. For a UI, prefer `POST /sessions/stream`, which emits one SSE `step` event per
> provisioning step (`routes/sessions.ts:38-61`); see [Sessions](../04-api/sessions.md#post-sessionsstream).

Response — `201` with a `SessionSummary` (`registry.ts:7-16`, shape and full field notes in
[Sessions](../04-api/sessions.md#the-sessionsummary-shape)):

```json
{
  "setupId": "session-a1b2c3d4-quickstart",
  "network": "devnet",
  "asset": "XRP",
  "permissioned": false,
  "seats": [
    { "key": "owner:0", "role": "owner", "address": "rOWNER...", "occupant": { "kind": "bot" } },
    { "key": "depositor:0", "role": "depositor", "address": "rDEP0...", "occupant": { "kind": "bot" } },
    { "key": "borrower:0", "role": "borrower", "address": "rBOR0...", "occupant": { "kind": "bot" } }
  ],
  "openSeats": ["owner:0", "depositor:0", "borrower:0"]
}
```

> [!NOTE]
> Addresses above are illustrative placeholders — the field names, `permissioned: false` behavior, and
> every seat shape are drawn from source (`registry.ts:7-16,75-85`), not copied from a live response.

Every seat starts bot-occupied (`openSeats` lists every non-human seat, `registry.ts:83`) — claim one
to act as that role yourself.

## Claim a seat

```sh
curl -X POST http://localhost:4000/sessions/session-a1b2c3d4-quickstart/seats/depositor:0/claim \
  -H 'Content-Type: application/json' \
  -d '{ "participant": "alice" }'
```

Standing down the bot on `depositor:0` and handing it to participant `alice`
(`routes/seats.ts:13-28`). Response is `200` with the updated `SessionSummary`; that seat's
`occupant` is now `{ "kind": "human", "id": "alice" }`. Full guard order and status table in
[Seats](../04-api/seats.md#post-sessionsidseatsseatclaim).

## Act: deposit

```sh
curl -X POST http://localhost:4000/sessions/session-a1b2c3d4-quickstart/actions \
  -H 'Content-Type: application/json' \
  -d '{
    "participant": "alice",
    "seat": "depositor:0",
    "action": "deposit",
    "params": { "amount": "1000" }
  }'
```

`deposit` builds a `VaultDeposit` against the session's vault for the validated `amount`
(`action-service.ts:77-83`); the seat must currently be held by `participant`
(`action-service.ts:57-62`). Response is `200` with the ledger's own result code — success and
rejection are reported the same way:

```json
{ "action": "deposit", "code": "tesSUCCESS", "hash": "9B4E21...771A" }
```

(`ActionResult`, `action-service.ts:12-16`)

> [!NOTE]
> A `tec*` code here is still **HTTP 200** — the transaction reached a ledger and was correctly
> rejected on its own terms, not an engine error. See
> [the error model](../04-api/index.md#the-error-model) and
> [Result Codes](../07-reference/result-codes.md) for the full contract and every other action verb
> (`withdraw`, `repay`, `originate`, credential and broker actions).

## Read state

```sh
curl http://localhost:4000/sessions/session-a1b2c3d4-quickstart/state
```

Returns live on-chain state — vault totals, broker cover, every loan, seat occupancy, and (on a
permissioned session) credential status — read fresh from the validated ledger on every call, no
cache (`state-service.ts:8-28`, `routes/sessions.ts:75-79`). Full shape and field notes in
[Reads](../04-api/reads.md#get-sessionsidstate).

For per-account balances (XRP, asset held, vault shares) use `GET /sessions/:id/balances`; for the
durable action log (including the provisioning steps that ran as this session's genesis) use
`GET /sessions/:id/log` — both documented on the same page.

## Read next

- [Configuration](./configuration.md) — the full `Config` schema this session was provisioned from,
  and every override `POST /sessions` accepts.
- [Running the Engine](./running-the-engine.md) — deployment: CORS, persistence, and process
  lifecycle.
- [Loan Lifecycle Walkthrough](./loan-lifecycle-walkthrough.md) — a complete
  deposit → originate → repay (or default) run through the actions above.
- [Engine HTTP API](../04-api/index.md) — the full route table, error model, and guard-order
  reference for every route touched in this guide.
