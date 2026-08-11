---
label: Sessions
order: 80
---

# Session Routes

A session is one fully-provisioned lending environment: its own derived account set, its own vault,
loan broker, and (if permissioned) domain and credentials — wired on-ledger by
[the provisioning sequence](../03-architecture/provisioning-sequence.md) and served under a unique
`setupId`. These routes create, list, and inspect sessions. They are registered by
`registerSessionRoutes` (`packages/engine/src/routes/sessions.ts:26`) against the engine's Fastify
app (`:4000`, no CORS restriction by default — `.docsource/code-map.md` app-wiring note).

All bodies below are the same `ProvisionBody` interface (`routes/sessions.ts:9-22`):

```ts
// routes/sessions.ts:9-22
interface ProvisionBody {
  label?: string;
  depositors?: number;
  borrowers?: number;
  asset?: string;
  coverRatePercent?: number;
  liquidationRatePercent?: number;
  managementFeePercent?: number;
  coverAmount?: string;
  debtMaximum?: string;
  scenario?: string;
  botSeed?: string;
  // Session-level default loan terms. interestRatePercent is a human percent; interval/grace seconds;
  // paymentTotal a payment count. Each overrides the config-file `loanDefaults` and is overridden by a
  // per-origination value.
  interestRatePercent?: number;
  paymentInterval?: number;
  gracePeriod?: number;
  paymentTotal?: number;
  // Whether the vault is permissioned (domain-gated, default) or public (open). false → public.
  permissioned?: boolean;
}
```

Every field is optional; anything omitted falls back to the engine's base `Config`
(`session-service.ts:83-104`). Field semantics, as implemented in `SessionService.create`
(`session-service.ts:62-122`):

| Field | Type | Behavior |
|---|---|---|
| `label` | `string?` | Folded into the session's derivation token for readability; does not affect on-ledger identity (`session-service.ts:82`, `:237-240`). |
| `depositors`, `borrowers` | `number?` | Pool sizes. Each is clamped to `[1, MAX_POOL]` with `MAX_POOL = 20` (`session-service.ts:10,21-24`); non-finite or omitted values fall back to the base config's pool sizes. |
| `asset` | `string?` | A non-XRP currency code. `"XRP"` (case-insensitive) is treated as the base config's asset and ignored as an override; anything else is normalized — a 3-character code is used as-is, a 40-hex-char string is upper-cased, otherwise the string is hex-encoded and padded to 40 chars (`session-service.ts:33-39,93-95`). The session provisions its own issuer; `issuer` is filled in at provision time and cannot be set here. |
| `permissioned` | `boolean?` | Omitted or `true` keeps the base config's `domain` (permissioned vault). Only explicit `false` drops `domain` entirely, producing a public (non-gated) vault (`session-service.ts:96-98`). See ["Domain → Vault"](../02-protocol/index.md) on the protocol composition page. |
| `coverAmount`, `debtMaximum` | `string?` | Whole-unit decimal strings, passed straight through onto the config (`session-service.ts:99-100`). |
| `coverRatePercent`, `liquidationRatePercent`, `managementFeePercent` | `number?` | Percentages, converted to the ledger's scaled-integer rate (`percent * 1000`, rounded, floored at 0) via `pctToScaled` (`session-service.ts:27-29,101-103`) onto `coverRateMinimum` / `coverRateLiquidation` / `managementFeeRate`. |
| `scenario` | `string?` | One of `calm` / `mixed` / `defaults` (`weights.ts:24-46`, cited in `.docsource/code-map.md`) — biases bot-variant weighting when the bot scheduler starts for this session (`bot-service.ts:41-42`). Stored per-session (`session-service.ts:50,108`), not validated against the enum at the route. |
| `botSeed` | `string?` | Fixes the bot variant assignment so a run's behaviour mix is reproducible; omitted → the engine generates a `seed-<hex>` value. A non-string is rejected `400` before provisioning. Echoed on the summary as `botSeed`. |
| `interestRatePercent` | `number?` | Session default interest rate as a human percent (0–100); the engine scales it to the ledger integer (`×1000`). Applied at origination when neither a per-origination value nor — below it — the config-file `loanDefaults` supplies one. |
| `paymentInterval`, `gracePeriod` | `number?` | Session default payment interval / grace period, in seconds (interval ≥ 60, grace ≤ interval). Same precedence as `interestRatePercent`. |
| `paymentTotal` | `number?` | Session default term length (payment count, positive integer); omitted leaves the schedule ledger-derived. |

> [!NOTE]
> `ProvisionBody` has no `network` or `seed` field — every session derives its seed from the engine's
> base seed plus a per-session token (`session-service.ts:85`), so sessions never collide on-chain
> regardless of caller input.

## POST /sessions

Provision a brand-new session synchronously and return its summary once provisioning has finished.

```ts
// routes/sessions.ts:29-32
app.post<{ Body: ProvisionBody }>("/sessions", async (request, reply) => {
  const summary = await sessions.create(request.body ?? {});
  return reply.code(201).send(summary);
});
```

- **Body:** `ProvisionBody` (all fields optional; `{}` is valid).
- **Status:** `201` with the `SessionSummary` (shape below).

> [!WARNING]
> Provisioning runs the full on-ledger recipe described in
> [Provisioning Sequence](../03-architecture/provisioning-sequence.md) — account derivation, funding,
> optional issuer/trust/distribution batches, optional credential/domain batches, vault creation,
> broker creation, and cover deposit. This is a blocking call against a live ledger and, per the
> route's own comment, "takes as long as a full environment provision" (`routes/sessions.ts:27-28`)
> — on the order of minutes, not milliseconds. Prefer `/sessions/stream` for anything driving a UI.

Example request body (IOU, permissioned, defaults otherwise):

```json
{
  "label": "demo-run",
  "depositors": 3,
  "borrowers": 2,
  "asset": "RLUSD",
  "coverRatePercent": 10,
  "liquidationRatePercent": 10,
  "managementFeePercent": 0,
  "coverAmount": "20000",
  "debtMaximum": "100000",
  "scenario": "mixed"
}
```

A public, native-XRP session needs only:

```json
{ "permissioned": false }
```

## POST /sessions/stream

Provision a session with the same `ProvisionBody`, but stream progress as Server-Sent Events instead
of blocking for one response.

```ts
// routes/sessions.ts:38-61
app.post<{ Body: ProvisionBody }>("/sessions/stream", async (request, reply) => {
  const body = request.body ?? {};

  reply.raw.writeHead(200, {
    "content-type": "text/event-stream",
    "cache-control": "no-cache",
    connection: "keep-alive",
    "access-control-allow-origin": request.headers.origin ?? "*",
  });

  const send = (event: string, data: unknown): void => {
    reply.raw.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
  };

  try {
    const summary = await sessions.create({ ...body, onStep: (record) => send("step", record) });
    send("done", summary);
  } catch (err) {
    send("error", { error: err instanceof Error ? err.message : String(err) });
  } finally {
    reply.raw.end();
  }
});
```

- **Body:** `ProvisionBody`, identical to `POST /sessions`.
- **Status:** always `200`, `content-type: text/event-stream` — the HTTP status is fixed at stream
  open, before provisioning result is known (`routes/sessions.ts:41-47`). Failure is signaled by an
  `error` event on the stream, not an HTTP status code.
- **CORS on the raw stream:** the route manually mirrors the request's `Origin` header onto
  `access-control-allow-origin` (falling back to `*`) because writing to `reply.raw` bypasses the
  `@fastify/cors` plugin's normal reply decoration (`routes/sessions.ts:46`).

Events emitted on the stream:

| Event | Payload | When |
|---|---|---|
| `step` | `StepRecord` — `{ action, correlationId, result, txHash?, skipped }` (`bootstrap/src/types.ts:5-11`) | Once per provisioning step, as it settles — passed through the `onStep` callback threaded into `sessions.create` (`routes/sessions.ts:54`, `session-service.ts:80,105`). |
| `done` | `SessionSummary` (shape below) | Once, after provisioning completes successfully. |
| `error` | `{ error: string }` | Once, if `sessions.create` throws; the caught error's `.message`, or its string form (`routes/sessions.ts:57`). |

In every case the handler calls `reply.raw.end()` in a `finally` block, closing the stream
(`routes/sessions.ts:58-60`).

> [!NOTE]
> The route does not emit a distinct SSE `id:` field or support resumption — it is a single
> best-effort event sequence for one provisioning run, not a durable/replayable stream.

## GET /sessions

List every live session.

```ts
// routes/sessions.ts:64
app.get("/sessions", async () => sessions.list());
```

- **Params:** none.
- **Status:** `200` with a JSON array of `SessionSummary`.

## GET /sessions/:id

Fetch one session's summary.

```ts
// routes/sessions.ts:67-71
app.get<{ Params: { id: string } }>("/sessions/:id", async (request, reply) => {
  const summary = sessions.summaryOf(request.params.id);
  if (!summary) return reply.code(404).send({ error: `no session ${request.params.id}` });
  return summary;
});
```

- **Params:** `id` — the session's `setupId`.
- **Status:** `200` with the `SessionSummary`, or `404` with `{ error: string }` if no session with
  that id is registered.

## The SessionSummary shape

Every route above that returns session data returns this shape, built by `summarize`
(`packages/session/src/registry.ts:75-85`) from the `SessionSummary` interface
(`registry.ts:7-16`):

```ts
// registry.ts:7-16
export interface SessionSummary {
  setupId: string;
  network: string;
  // The vault asset: "XRP" for a native vault, or the currency code for an IOU vault.
  asset: string;
  // Whether the vault is domain-gated (permissioned) or open (public).
  permissioned: boolean;
  seats: { key: string; role: string; address: string; occupant: Occupant }[];
  openSeats: string[];
}
```

```ts
// registry.ts:75-85
function summarize(session: Session): SessionSummary {
  const seats = [...session.seats.values()].map((s) => ({ key: `${s.role}:${s.index}`, role: s.role, address: s.address, occupant: s.occupant }));
  return {
    setupId: session.setupId,
    network: session.network,
    asset: session.env.asset.currency,
    permissioned: isPermissioned(session.env),
    seats,
    openSeats: seats.filter((s) => s.occupant.kind !== "human").map((s) => s.key),
  };
}
```

- `asset` is `session.env.asset.currency` — the raw currency code (`"XRP"` or the normalized IOU
  code), not an issuer-qualified amount.
- `permissioned` is derived from the on-ledger domain, not from stored config: `isPermissioned(env)`
  returns `env.objects.domainId !== undefined` (`bootstrap/src/types.ts:50-52`) — a permissioned
  session always has a domain, a public one never does.
- `seats[].key` is `"{role}:{index}"` (e.g. `"depositor:0"`), matching `seatKey` (`session/src/seat.ts:23-25`).
- `seats[].occupant` is one of three shapes (`session/src/seat.ts:7-10`):
  ```ts
  type Occupant =
    | { kind: "open" }
    | { kind: "bot" }
    | { kind: "human"; id: string };
  ```
  Occupancy is exclusive — a seat is driven by exactly one of these at a time (`seat.ts:5-6`).
- `openSeats` lists the `key` of every seat *not* held by a human — that is, `open` or `bot`
  occupants both count as open for the purposes of a human joining (`registry.ts:83`, filter is
  `occupant.kind !== "human"`). A bot-filled seat is still listed as available to claim, since
  claiming stands the bot down (`session/src/seat.ts:41-46`).

Example `SessionSummary` (two depositors, one borrower, permissioned IOU vault, one seat human-held):

```json
{
  "setupId": "session-a1b2c3d4-demo-run",
  "network": "devnet",
  "asset": "524C555344000000000000000000000000000000",
  "permissioned": true,
  "seats": [
    { "key": "issuer:0", "role": "issuer", "address": "rISSUER...", "occupant": { "kind": "bot" } },
    { "key": "credentialIssuer:0", "role": "credentialIssuer", "address": "rCRED...", "occupant": { "kind": "bot" } },
    { "key": "owner:0", "role": "owner", "address": "rOWNER...", "occupant": { "kind": "bot" } },
    { "key": "depositor:0", "role": "depositor", "address": "rDEP0...", "occupant": { "kind": "human", "id": "alice" } },
    { "key": "depositor:1", "role": "depositor", "address": "rDEP1...", "occupant": { "kind": "bot" } },
    { "key": "borrower:0", "role": "borrower", "address": "rBOR0...", "occupant": { "kind": "bot" } }
  ],
  "openSeats": ["issuer:0", "credentialIssuer:0", "owner:0", "depositor:1", "borrower:0"]
}
```

> [!NOTE]
> Field values in the example (`setupId`, addresses) are illustrative — shaped to match the cited
> interfaces and derivation rules, not copied from a live response. `network: "devnet"` reflects a
> real enum member (`config/schema.ts:5`). Only the field names, types, and the `credentialIssuer`
> seat's permissioned-only presence are drawn from source.

## Read next

- [Provisioning Sequence](../03-architecture/provisioning-sequence.md) — the on-ledger steps a
  `POST /sessions` call runs, and how they branch by vault mode
- [Protocol Foundations](../02-protocol/index.md) — what gets provisioned and why the four amendments
  are chained in this order
- [Session & Seat Model](../03-architecture/session-seat-model.md) — occupancy, claiming, and bot
  fill-in for the seats returned above
