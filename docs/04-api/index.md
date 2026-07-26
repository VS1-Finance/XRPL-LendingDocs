---
label: Engine API
order: 90
icon: server
---

# Engine HTTP API

The engine is a Fastify HTTP service (`packages/engine/src/app.ts:16-48`). One process owns every session it provisions — seats, signers, bot schedulers, and the durable log — and exposes them over the routes on this page and its children.

## Base URL

No default host is baked into a client; the engine binds to `HOST`/`PORT` at boot (`config.ts:22-24`):

| Setting | Default | Source |
|---|---|---|
| `PORT` | `4000` | `config.ts:23` |
| `HOST` | `0.0.0.0` | `config.ts:24` |

So a local instance is reachable at `http://localhost:4000` unless `PORT`/`HOST` are overridden. `ENGINE_CONFIG` selects the base provisioning config (default `./packages/bootstrap/config.example.json`); `ENGINE_SEED` and `ENGINE_NETWORK` override the seed and network in that config (`config.ts:13-29`).

## Requests and responses

Every route takes and returns JSON, with one exception: `POST /sessions/stream` (below). There is no API-key or auth header on any route — a session is scoped by its `id` in the path, and a seat is scoped by the `participant` string a caller supplies in the body.

## CORS

The engine registers `@fastify/cors` with `origin: process.env.CORS_ORIGIN ?? true` (`app.ts:22`). Unset, this is **permissive** (any origin) — meant for local development where a web client runs on a different port than the engine. A deployment sets `CORS_ORIGIN` to the exact origin it should serve.

> [!NOTE]
> `POST /sessions/stream` mirrors CORS onto the raw response by hand (`access-control-allow-origin: request.headers.origin ?? "*"`, `routes/sessions.ts:46`) because writing directly to `reply.raw` bypasses the CORS plugin's normal reply decoration.

## The error model

Every route reports failure as `{ "error": "<message>" }` with an HTTP status chosen by one of two mechanisms, depending on the route family.

### ActionError (actions route)

`ActionError` is a plain `Error` subclass carrying a `status`, defaulting to `400` (`action-service.ts:18-23`):

```ts
export class ActionError extends Error {
  constructor(message: string, readonly status = 400) {
    super(message);
    this.name = "ActionError";
  }
}
```

Every guard inside `action-service.ts` throws one of these with an explicit status where it isn't the 400 default — unheld/wrong seat → `409` (`action-service.ts:61,192,197,200`), unknown seat → `404` (`:59,190,199`), public-vault action attempted where there's no domain/credential issuer → `409` (`:144,274,285`). The actions route (`routes/actions.ts:46-50`) catches `ActionError` and replies with its `.status`; anything else is an uncaught exception and becomes `500`.

`asClientError` (`action-service.ts:31-46`) additionally reclassifies certain thrown errors as a `400` `ActionError` before they reach the route: xrpl's `ValidationError` (malformed transaction/amount), a preliminary `tem*` rejection (the transaction never reached a ledger), and the amount-shape errors raised while building a transaction (`illegal amount`, `not a non-negative decimal`, `invalid amount`). Anything else is rethrown unchanged and surfaces as `500` — a genuine engine or connectivity fault, not a bad caller input.

### CapacityError (participants route)

Adding a participant when a pooled role is already at `MAX_POOL` (20, `session-service.ts:10`) throws `CapacityError` (`session-service.ts:14-19`), which the participants route maps to `409` (`routes/sessions.ts:114`). Any other failure adding a participant (an on-ledger or faucet failure while provisioning the new account) is `500` (`routes/sessions.ts:115`).

### SeatOccupancyError (seats route)

Claiming a seat held by a different participant, or releasing a seat you don't hold, throws `SeatOccupancyError` (`session/src/seat.ts:31-36,41-46,50-55`). The seats route maps it to `409`; any other thrown error on that route is `400` (`routes/seats.ts:49-53`).

### tec* is HTTP 200

**A `tec*` ledger rejection is not an engine error — it is HTTP 200.** The action (or origination) reached a validator, was applied, claimed its fee, and the ledger rejected its intended effect on the transaction's own terms. The engine returns this as a normal `200` response with the ledger's result code in the `code` field of the response body (`action-service.ts:67`, `ActionResult.code`, `:12-16`):

```ts
export interface ActionResult {
  action: string;
  code: string;
  hash?: string;
}
```

A `tem*` rejection, by contrast, never reaches a ledger — `asClientError` turns that into `HTTP 400` before the caller sees a ledger code at all (`action-service.ts:40`). See [Result Codes §2](../07-reference/result-codes.md#2-http-status-codes) for the full status-code table and [§1](../07-reference/result-codes.md#1-on-ledger-result-codes) for every `tes*`/`tec*`/`tem*` code this system has produced or documented.

### Status code summary

| Status | Meaning here | Where it comes from |
|---|---|---|
| 200 | Request settled — **including a `tec*` ledger rejection**, reported via the `code` field, not the HTTP status. | Route handler's normal return |
| 201 | A new session was created. | `POST /sessions` only (`routes/sessions.ts:31`) |
| 400 | Validation failure: missing/malformed body field, a `tem*` ledger rejection, or a malformed amount. | Route body checks; `asClientError` (`action-service.ts:31-46`) |
| 404 | Unknown session, unknown seat, or unknown borrower seat referenced in `originate`. | Route/service lookups (`session.get`/`session.seats.get` returning nothing) |
| 409 | State conflict: seat already held by another participant, seat not held by the requester, role guard (e.g. non-owner attempting `originate`), an action requiring a domain/credential issuer on a public (non-permissioned) vault, or pool at `MAX_POOL`. | `SeatOccupancyError`, `ActionError` with an explicit status, `CapacityError` |
| 500 | Unexpected failure: an on-ledger/faucet fault, a dropped connection, or any error not classified above. | Uncaught exception in the route handler |

## Guard precedence

Each route family checks preconditions in a fixed order; a client relying on "which status wins" when multiple things are wrong at once should read the order for that specific route family, not assume it's uniform.

**Actions** (`POST /sessions/:id/actions`, `routes/actions.ts:12-17`) — session existence is checked before the body is validated:

1. Session exists? No → `404`.
2. `participant` present in body? No → `400`.
3. `seat` and `action` present in body? No → `400`.
4. (inside the handler) seat exists, is held by `participant`, role guards, action-specific guards → `404`/`409` per `ActionError.status`.

**Seats** (`POST /sessions/:id/seats/:seat/claim` and `/release`, `routes/seats.ts:16-20,34-38`) — session existence, then seat existence, then body validation; the route's own comment states this explicitly (`routes/seats.ts:8-10`):

1. Session exists? No → `404`.
2. Seat exists on that session? No → `404`.
3. `participant` present in body? No → `400`.
4. (inside the service) occupancy conflict → `409` via `SeatOccupancyError`.

**Participants** (`POST /sessions/:id/participants`, `routes/sessions.ts:100-103`) — session existence, then body validation:

1. Session exists? No → `404`.
2. `role` is `"depositor"` or `"borrower"`? No → `400`.
3. (inside the service) pool at capacity → `409` via `CapacityError`; other provisioning failure → `500`.

> [!NOTE]
> All three route families check session existence (`404`) before validating the request body (`400`) — there is no route in this engine where a body-shape error is reported ahead of an unknown session. Where they differ is what comes *after* the session check: actions validates the remaining body fields next; seats interposes a seat-existence check between the session check and the body check; participants validates its one body field (`role`) immediately after the session check.

## Server-Sent Events: `POST /sessions/stream`

This route is not a normal JSON-status endpoint. It always responds `200` with `content-type: text/event-stream` (`routes/sessions.ts:41-47`) and stays open, writing one event per provisioning step:

| Event | Payload | When |
|---|---|---|
| `step` | A `StepRecord` (the provisioning step's action/result/hash) | Once per ledger step, as it settles (`routes/sessions.ts:54`, via `onStep`) |
| `done` | The session summary | Provisioning completed successfully (`:55`) |
| `error` | `{ "error": "<message>" }` | Provisioning threw; the failure is reported as an event, not an HTTP error status (`:57`) |

A client must read the event stream to learn whether provisioning succeeded — the HTTP status alone (`200`) does not tell you.

## Route table

| Method | Path | Purpose | Detail page |
|---|---|---|---|
| GET | `/health` | Liveness check. | — |
| POST | `/sessions` | Provision a new session synchronously; `201` on success. | [Sessions](./sessions.md) |
| POST | `/sessions/stream` | Provision a new session, streaming progress as SSE. | [Sessions](./sessions.md) |
| GET | `/sessions` | List all live sessions. | [Sessions](./sessions.md) |
| GET | `/sessions/:id` | One session's summary (seats, occupancy). | [Sessions](./sessions.md) |
| GET | `/sessions/:id/state` | Live on-chain state: vault, broker, loans, credentials. | [Reads](./reads.md) |
| GET | `/sessions/:id/balances` | Live per-account balances: XRP, asset, vault shares. | [Reads](./reads.md) |
| GET | `/sessions/:id/log` | The session's action log, oldest first. | [Reads](./reads.md) |
| POST | `/sessions/:id/participants` | Add one depositor or borrower to a running session. | [Participants](./participants.md) |
| POST | `/sessions/:id/seats/:seat/claim` | A participant claims an open (or bot-held) seat. | [Seats](./seats.md) |
| POST | `/sessions/:id/seats/:seat/release` | A participant releases a seat back to open. | [Seats](./seats.md) |
| POST | `/sessions/:id/actions` | Submit a human action (deposit, withdraw, repay, originate, …) under a held seat. | [Actions](./actions.md) |
| POST | `/sessions/:id/bots/start` | Start the bot scheduler for every seat not held by a human. | [Bots](./bots.md) |
| POST | `/sessions/:id/bots/stop` | Stop the bot scheduler. | [Bots](./bots.md) |

Source: `packages/engine/src/routes/{sessions,seats,actions,bots}.ts`; wiring in `app.ts:36-39`.
