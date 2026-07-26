---
label: Session & Seat Model
order: 40
---

# The Session & Seat Model

A session is a provisioned environment plus a seat map over it. Every human- or bot-driven action in the system happens through a seat; the session is what ties those seats to a single running vault/broker graph.

## Session

`Session` (`session.ts:10-17`):

```ts
export interface Session {
  setupId: string;
  network: Network;
  seed: string;
  env: ProvisionedEnvironment;
  seats: Map<string, Seat>;
  client: Client;
}
```

`createSession` (`session.ts:22-30`) provisions a fresh environment via `provision` from `@lending/bootstrap`, connects an xrpl.js `Client`, and builds one seat per role with `buildSeats`. `attachSession` (`session.ts:35-39`) rebuilds the in-memory handle from an already-provisioned `ProvisionedEnvironment` — the path a second process uses to join a session it did not create, given the same seed. `closeSession` (`session.ts:41-43`) just disconnects the client.

`buildSeats` (`session.ts:45-64`) derives one seat per role in the environment: for each role/index/address triple, it recomputes the account with `deriveAccount(seed, role, index)` and throws if the derived address doesn't match the address already on the environment (`session.ts:49-51`) — a hard check that the seed given to the session actually matches the environment it's attaching to. Every seat is constructed with a `ServerSigner` over the derived wallet and starts `{ kind: "open" }`, then is immediately bot-filled (`session.ts:52-53`). Roles enumerated: `issuer` (always), `credentialIssuer` (only if `env.accounts.credentialIssuer` is set — permissioned sessions only), `owner`, one seat per pooled `depositor`, one seat per pooled `borrower` (`session.ts:57-62`). See [account derivation](./account-derivation.md) for how `(seed, role, index)` maps to a wallet.

> [!NOTE]
> A session's seat set is fixed at the roles present when `buildSeats` runs. Growing the depositor/borrower pool at runtime is a separate path (`add-participant.ts`) — see the note on account derivation's ["Runtime participant growth"](./account-derivation.md) and the [Participants API](../04-api/participants.md).

## Seat and Occupant

A seat is one role slot bound to a single on-chain account (`seat.ts:14-20`):

```ts
export interface Seat {
  role: Role;
  index: number;
  address: string;
  signer: Signer;
  occupant: Occupant;
}
```

Occupancy is exclusive and three-valued (`seat.ts:7-10`):

```ts
export type Occupant =
  | { kind: "open" }
  | { kind: "bot" }
  | { kind: "human"; id: string };
```

At any instant a seat's account is driven by exactly one party — open (nobody), bot, or a specific human — which preserves the one-account-one-signer rule on-chain (`seat.ts:5-6`). The seat's `signer` is independent of who occupies it: a bot-driven seat and a human-driven seat act through the same `Signer` surface (`seat.ts:12-13`; see [Signer seam](#the-signer-seam) below).

The stable key for addressing a seat is `role:index` (`seat.ts:23-29`):

```ts
export function seatKey(role: Role, index: number): string {
  return `${role}:${index}`;
}
export function keyOf(seat: Seat): string {
  return seatKey(seat.role, seat.index);
}
```

For example `depositor:0`, `borrower:2`. This is the same string used as the map key in `Session.seats` (`session.ts:54`) and as the `:seat` path parameter on the seat routes.

### claim / release / fillWithBot

| Function | Effect | Rejects when | Source |
|---|---|---|---|
| `claim(seat, humanId)` | Sets occupant to `{ kind: "human", id: humanId }` | Seat is `human`-held by a **different** `humanId` | `seat.ts:41-46` |
| `release(seat, humanId)` | Sets occupant back to `{ kind: "open" }` | Seat is not currently held by `humanId` (not human-held, or held by someone else) | `seat.ts:50-55` |
| `fillWithBot(seat)` | Sets occupant to `{ kind: "bot" }` | No-op unless the seat is `open` — a human-held seat is left untouched | `seat.ts:58-60` |

`claim` is idempotent for the same human re-claiming a seat they already hold (the guard only fires on a *different* human id), but always overwrites a `bot` or `open` occupant. Both `claim` and `release` throw `SeatOccupancyError` on conflict (`seat.ts:31-36`), a distinct error type from a generic `Error` so callers can pattern-match it. `isBotDriven`/`isHumanHeld` (`seat.ts:62-68`) are simple predicates over `occupant.kind`.

> [!NOTE]
> `SeatOccupancyError` → HTTP 409. The engine's seat routes catch it explicitly and map it to a 409 response; any other thrown error maps to 400 (`routes/seats.ts:49-53`, `seatError`). Guard precedence ahead of that: unknown session → 404, unknown seat → 404, missing `participant` in the body → 400 (`routes/seats.ts:9-10,16-20,33-38`).

### One human, one seat

A participant holds at most one seat at a time. Claiming a new seat first releases any other seat that participant currently holds — this is enforced one layer above `seat.ts`, in the engine's `SessionService.claimSeat` (`session-service.ts:200-215`):

```ts
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

The `claim`/`release` functions in `seat.ts` themselves have no notion of "one seat per human" — that invariant is a session-service-level policy applied before calling `SessionRegistry.claimSeat`, and each release/claim is separately persisted through `store.saveOccupancy` so it survives a restart. See the [Seats API](../04-api/seats.md) for the request/response shape this backs.

## The Signer seam

`Signer` (`signer.ts:12-15`) is the interface every seat submits transactions through:

```ts
export interface Signer {
  readonly address: string;
  submit(tx: SubmittableTransaction): Promise<SubmitResult>;
}
```

A seat holds a `Signer` and does not care how the signing happens (`signer.ts:8-11`) — this is the deliberate extensibility point. `ServerSigner` (`signer.ts:20-34`) is the only implementation today: it holds the account's `Wallet` directly, and on `submit` autofills the transaction, signs it locally, and calls `submitAndWait`, returning `{ hash, engineResult }` read off the transaction metadata (`signer.ts:27-33`). Every seat built by `buildSeats` — bot-driven or human-driven — is currently wired to a `ServerSigner` (`session.ts:52`).

> [!NOTE]
> Because `Signer` is an interface, a client-side signing implementation (e.g. wallet-extension or hardware-key signing where the private key never reaches the server) can be substituted without changing anything that calls `seat.signer.submit(...)` — the seam exists in the code today, but only `ServerSigner` is implemented. See [Signing Integration](../05-guides/signing-integration.md).

## SessionRegistry and SessionSummary

`SessionRegistry` is the in-memory index of live sessions, backed by on-disk persistence of each session's `ProvisionedEnvironment` so a separate process can attach to a session it didn't create (`registry.ts:18-20`):

| Method | Effect | Source |
|---|---|---|
| `register(session, dir?)` | Adds the session to the in-memory map and writes its environment to disk via `saveEnvironment` | `registry.ts:24-27` |
| `get(setupId)` | Returns the live `Session` if present | `registry.ts:29-31` |
| `list()` | Returns a `SessionSummary` for every live session | `registry.ts:33-35` |
| `attach(setupId, seed, dir?)` | Loads a session's environment from disk (`loadEnvironment`) if not already live, and attaches | `registry.ts:38-44` |
| `attachFrom(env, seed)` | Attaches from an already-loaded environment (e.g. read from a database) rather than disk | `registry.ts:48-54` |
| `claimSeat(setupId, seatKey, humanId)` | Looks up the seat and calls `claim` | `registry.ts:57-59` |
| `releaseSeat(setupId, seatKey, humanId)` | Looks up the seat and calls `release` | `registry.ts:62-64` |

`SessionSummary` (`registry.ts:7-16`) is the shape returned to API callers listing or inspecting sessions:

```ts
export interface SessionSummary {
  setupId: string;
  network: string;
  asset: string;
  permissioned: boolean;
  seats: { key: string; role: string; address: string; occupant: Occupant }[];
  openSeats: string[];
}
```

`summarize` (`registry.ts:75-85`) builds this from a live `Session`: `asset` is `session.env.asset.currency`; `permissioned` is `isPermissioned(session.env)` (from `@lending/bootstrap`); `seats` lists every seat's key, role, address, and current `Occupant`; `openSeats` is every seat key whose occupant is *not* `human` (`registry.ts:83`) — note this means a seat still shows as "open" for join purposes while it is bot-driven, since a bot occupant does not block a human claim.

## How this connects

- Humans claim and release seats through the engine's HTTP API — see [Seats API](../04-api/seats.md).
- Seats left `open` (including bot-occupied ones, per `openSeats` above) are filled by the bot framework so the session keeps producing activity without a human present — see [Bot Framework](./bot-framework.md).
- Client-side signing is designed as a drop-in replacement for `ServerSigner` against the same `Signer` interface — see [Signing Integration](../05-guides/signing-integration.md).
