---
label: Seats
order: 70
---

# Seat Routes

Two routes let a participant take over a seat from a bot (or another idle state) and hand it back. Both are POSTs, both take a single `participant` string in the body, both return the session's `SessionSummary` on success. Registered by `registerSeatRoutes` (`routes/seats.ts:11-47`).

> [!NOTE]
> Background on what a seat is, the exclusive `open | bot | human` occupancy model, and the `claim`/`release` functions these routes call sit in [The Session & Seat Model](../03-architecture/session-seat-model.md). This page documents the HTTP surface only.

## POST /sessions/:id/seats/:seat/claim

Claims `:seat` for `participant`. On success, that seat's occupant becomes `{ kind: "human", id: participant }` and the response is the session's updated `SessionSummary` (`routes/seats.ts:13-28`).

**Body**

```json
{ "participant": "string" }
```

**Guard order** (`routes/seats.ts:16-24`), resource-first — each check runs only if the previous one passed:

1. `sessions.get(id)` — session must exist (`:16-17`).
2. `session.seats.has(seat)` — seat key must exist on that session (`:18`).
3. `request.body?.participant` — must be a non-empty string (`:19-20`).
4. `sessions.claimSeat(id, seat, participant)` — may throw `SeatOccupancyError`, caught and mapped by `seatError` (`:21-25`, `:49-53`).

| Status | Condition | Source |
|---|---|---|
| `200` | Claim succeeded (including re-claiming a seat `participant` already holds — idempotent). Body is the updated `SessionSummary`. | `routes/seats.ts:26` |
| `404` | No session with id `:id`. | `routes/seats.ts:17` |
| `404` | Session exists but has no seat keyed `:seat`. | `routes/seats.ts:18` |
| `400` | Body has no `participant` (missing or empty). | `routes/seats.ts:19-20` |
| `409` | Seat is currently held by a **different** human — `SeatOccupancyError` from `claim()`. | `seat.ts:41-44`, mapped at `routes/seats.ts:24` via `seatError` (`:50`) |

The seat is derived from the session before the occupancy call runs specifically so an unknown seat 404s rather than falling through to the 400 a bare registry lookup error would otherwise produce (`routes/seats.ts:8-10`).

Claiming a seat `participant` already holds is idempotent: `claim()` only rejects when the seat is human-held by a **different** id, so re-claiming your own seat re-sets the same occupant and returns `200` (`seat.ts:41-46`).

Claiming auto-releases any other seat the same participant holds — one human holds at most one seat at a time. This is enforced in `SessionService.claimSeat`, one layer above `seat.ts`'s `claim`/`release`, before the requested seat is claimed:

```ts
// session-service.ts:200-215
async claimSeat(setupId: string, seatKey: string, humanId: string): Promise<void> {
  const session = this.get(setupId);
  if (session) {
    for (const [key, seat] of session.seats) {
      if (key !== seatKey && seat.occupant.kind === "human" && seat.occupant.id === humanId) {
        this.registry.releaseSeat(setupId, key, humanId);
        const released = session.seats.get(key);
        if (released) await this.store.saveOccupancy(setupId, key, released.occupant);
      }
    }
  }
  this.registry.claimSeat(setupId, seatKey, humanId);
  await this.store.saveOccupancy(setupId, seatKey, { kind: "human", id: humanId });
}
```

Each release and the final claim is persisted separately via `store.saveOccupancy` (`session-service.ts:209,214`), so the net effect (old seat open, new seat held) survives a restart.

**Example**

Request:

```
POST /sessions/session-abc123/seats/depositor:1/claim
Content-Type: application/json

{ "participant": "alice" }
```

Response — `200`:

```json
{
  "setupId": "session-abc123",
  "network": "devnet",
  "asset": "XRP",
  "permissioned": true,
  "seats": [
    { "key": "depositor:1", "role": "depositor", "address": "rAliceSeatAddr...", "occupant": { "kind": "human", "id": "alice" } }
  ],
  "openSeats": ["depositor:0", "borrower:0"]
}
```

(`SessionSummary` shape per `registry.ts:7-16`, described in [Session & Seat Model](../03-architecture/session-seat-model.md#sessionregistry-and-sessionsummary).)

## POST /sessions/:id/seats/:seat/release

Releases `:seat` back to `{ kind: "open" }`, provided `participant` is the human currently holding it (`routes/seats.ts:31-46`).

**Body**

```json
{ "participant": "string" }
```

**Guard order** (`routes/seats.ts:34-42`) — identical shape to claim:

1. `sessions.get(id)` — session must exist (`:34-35`).
2. `session.seats.has(seat)` — seat key must exist (`:36`).
3. `request.body?.participant` — must be a non-empty string (`:37-38`).
4. `sessions.releaseSeat(id, seat, participant)` — may throw `SeatOccupancyError`, caught by `seatError` (`:39-43`, `:49-53`).

| Status | Condition | Source |
|---|---|---|
| `200` | Release succeeded; seat's occupant is now `{ kind: "open" }`. Body is the updated `SessionSummary`. | `routes/seats.ts:44` |
| `404` | No session with id `:id`. | `routes/seats.ts:35` |
| `404` | Session exists but has no seat keyed `:seat`. | `routes/seats.ts:36` |
| `400` | Body has no `participant` (missing or empty). | `routes/seats.ts:37-38` |
| `409` | Seat is not currently held by `participant` — either not human-held at all, or held by someone else — `SeatOccupancyError` from `release()`. | `seat.ts:50-53`, mapped at `routes/seats.ts:42` via `seatError` (`:50`) |

Unlike claim, release has no idempotent case: calling release twice in a row 409s the second time, because after the first call the seat is `open`, not held by `participant` (`seat.ts:50-53`).

**Example**

Request:

```
POST /sessions/session-abc123/seats/depositor:1/release
Content-Type: application/json

{ "participant": "alice" }
```

Response — `200`:

```json
{
  "setupId": "session-abc123",
  "network": "devnet",
  "asset": "XRP",
  "permissioned": true,
  "seats": [
    { "key": "depositor:1", "role": "depositor", "address": "rAliceSeatAddr...", "occupant": { "kind": "open" } }
  ],
  "openSeats": ["depositor:0", "depositor:1", "borrower:0"]
}
```

A released seat is not immediately re-filled by a bot in this response — `openSeats` reports it open, and the bot scheduler picks it up on its own next tick (see [Bot Framework](../03-architecture/bot-framework.md)).

## Error body shape

Both routes report an error as `{ "error": string }`, not a `SessionSummary` — `seatError` is the single mapping point for both (`routes/seats.ts:49-53`):

```ts
// routes/seats.ts:49-53
function seatError(reply: FastifyReply, err: unknown) {
  if (err instanceof SeatOccupancyError) return reply.code(409).send({ error: err.message });
  const message = err instanceof Error ? err.message : String(err);
  return reply.code(400).send({ error: message });
}
```

The 404 and 400-missing-participant cases are returned directly by the route body (`{ error: "no session ..." }`, `{ error: "no seat ..." }`, `{ error: "participant is required" }`) rather than through `seatError`, since they're checked before the occupancy call is even attempted. See [the error model](./index.md) for how this fits the engine's HTTP error conventions generally.
