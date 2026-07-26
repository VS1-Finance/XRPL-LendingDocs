---
label: Signing Integration
order: 40
---

# Signing Integration

Every transaction that reaches the ledger on behalf of a seat goes through exactly one interface: `Signer` (`signer.ts:12-15`). This page documents that seam precisely — the interface contract, the one implementation that exists today, and where in the code a different implementation would be wired in. It does not describe a plugin system, because none exists: swapping the signer is a code change, not a runtime configuration option.

## The interface

`Signer` (`signer.ts:12-15`):

```ts
export interface Signer {
  readonly address: string;
  submit(tx: SubmittableTransaction): Promise<SubmitResult>;
}
```

`SubmitResult` (`signer.ts:3-6`):

```ts
export interface SubmitResult {
  hash: string;
  engineResult: string;
}
```

The contract is deliberately narrow: a `Signer` exposes the account's `address`, and a single async method that takes an already-built `SubmittableTransaction` and returns the ledger's response as `{ hash, engineResult }`. Nothing about the interface says how a signature is produced. The comment at `signer.ts:8-11` states the intent directly: "a bot-driven seat and a human-driven seat both act through this same surface. The only implementation today signs with a locally held key; a signer backed by an external wallet would implement the same shape without any change to callers."

## Where it's held: the Seat

Every `Seat` carries a `signer` alongside its role, index, address, and current occupant (`seat.ts:14-20`):

```ts
export interface Seat {
  role: Role;
  index: number;
  address: string;
  signer: Signer;
  occupant: Occupant;
}
```

`occupant` — open, bot, or a specific human (`seat.ts:7-10`) — governs *who may request* an action on the seat; `signer` governs *how that action reaches the ledger* once requested. The two are independent: occupancy changes on `claim`/`release` (`seat.ts:41-55`) without touching the seat's signer at all. This is what makes the signer a real extensibility point rather than an accident of the bot/human split — a human-held seat and a bot-held seat call `seat.signer.submit(...)` identically.

## The one call site: dispatchAction

`dispatchAction` (`action-service.ts:57-71`) is where a request becomes a signed submission, for every single-signer action (`deposit`, `withdraw`, `repay`, `issue-credential`, `revoke-credential`, `accept-credential`, `set-vault`, `set-domain`, `manage-loan`, `deposit-cover`):

```ts
export async function dispatchAction(session: Session, request: ActionRequest, participant: string): Promise<ActionResult> {
  const seat = session.seats.get(request.seat);
  if (!seat) throw new ActionError(`session has no seat ${request.seat}`, 404);
  if (seat.occupant.kind !== "human" || seat.occupant.id !== participant) {
    throw new ActionError(`${request.seat} is not held by ${participant}`, 409);
  }

  try {
    const tx = await buildTransaction(session, seat.address, request);
    const result = await seat.signer.submit(tx);
    return { action: request.action, code: result.engineResult, ...(result.hash ? { hash: result.hash } : {}) };
  } catch (err) {
    asClientError(err);
  }
}
```
(`action-service.ts:57-71`)

`buildTransaction` (`action-service.ts:73-183`) assembles the unsigned `SubmittableTransaction` from the action verb and its params; `seat.signer.submit(tx)` (`action-service.ts:66`) is the only place that transaction is turned into a ledger outcome. The engine's HTTP layer, the action-verb table, and `dispatchAction`'s own guard logic have no dependency on `ServerSigner` specifically — they depend only on `Signer`.

> [!NOTE]
> `originate` (`action-service.ts:188-232`) does **not** go through this seam. Origination is bilateral — the owner signs and the borrower counter-signs the same `LoanSet` via `signLoanSetByCounterparty` — which the single-signer `submit` shape does not express. Both wallets are re-derived directly from the session seed for that path (`action-service.ts:219-224`), bypassing `Signer` entirely. A remote/custody signer implementation would need its own bilateral-signing story to cover `originate`; the `Signer` interface as it stands only covers the single-signer verbs.

## The default: ServerSigner

`ServerSigner` (`signer.ts:20-34`) is the only implementation in the codebase today. It holds the account's `Wallet` directly and signs locally:

```ts
export class ServerSigner implements Signer {
  constructor(private readonly client: Client, private readonly wallet: Wallet) {}

  get address(): string {
    return this.wallet.address;
  }

  async submit(tx: SubmittableTransaction): Promise<SubmitResult> {
    const prepared = await this.client.autofill(tx);
    const res = await this.client.submitAndWait(this.wallet.sign(prepared).tx_blob);
    const meta = res.result.meta;
    const engineResult = typeof meta === "object" && meta && "TransactionResult" in meta ? meta.TransactionResult : "unknown";
    return { hash: res.result.hash, engineResult };
  }
}
```
(`signer.ts:20-34`)

`submit` does three things in sequence: `client.autofill(tx)` fills in `Sequence`/`Fee`/`LastLedgerSequence` and the rest of the fields the ledger requires, `wallet.sign(prepared)` produces the signed blob using the key held in `this.wallet`, and `client.submitAndWait` sends it and waits for a validated (or rejected) outcome. `engineResult` is read off the returned transaction metadata's `TransactionResult` field, falling back to `"unknown"` if the metadata shape is unexpected (`signer.ts:30-32`).

The key `ServerSigner` signs with is never generated randomly and never stored: it is the `Wallet` produced by `deriveAccount(seed, role, index)` from the session seed, per the deterministic derivation scheme — see [Account Derivation](../03-architecture/account-derivation.md). Because the engine's persistence layer stores only a per-session derivation token and the public environment, never a key, `ServerSigner`'s wallet is reconstructed from the seed on every process restart rather than read from disk — see [Persistence](../03-architecture/persistence.md#no-private-keys-are-ever-stored).

## Where it's constructed: buildSeats

`buildSeats` (`session.ts:45-64`) is the single injection point. For every role/index/address in a provisioned environment, it re-derives the wallet, verifies the derived address matches the environment's recorded address, and constructs the seat with a `ServerSigner` over that wallet:

```ts
const seat: Seat = { role, index, address, signer: new ServerSigner(client, derived.wallet), occupant: { kind: "open" } };
```
(`session.ts:52`)

This line is where `Signer` is chosen, not the `Signer` interface itself — every seat built by `createSession` or `attachSession`, bot-driven or human-driven, is wired to a `ServerSigner` here (`session.ts:22-30, 35-39`). There is no branch, flag, or config field that selects a different `Signer` implementation at this call site today.

## Implementing an alternative signer

To route a seat's signing through an external wallet — hardware key, custody service, browser extension signer — implement the `Signer` interface: a class (or object) exposing `address: string` and `submit(tx): Promise<SubmitResult>`, where `submit` obtains a signature for `tx` by whatever means the external system provides (a hardware-signed blob, a custody API round-trip, a browser-injected `wallet.sign`) and returns `{ hash, engineResult }` from the ledger's response — the same shape `ServerSigner` returns today, so nothing downstream of `seat.signer.submit(...)` needs to know which implementation produced it.

Two things follow directly from reading `buildSeats` and `dispatchAction`, and both are honest limits rather than roadmap items:

> [!WARNING]
> There is no runtime plugin mechanism, configuration flag, or dependency-injection point that selects a `Signer` implementation per seat, per session, or per deployment. The only construction site is `session.ts:52`, hardcoded to `new ServerSigner(...)`. Wiring in an alternative signer means changing that line (or the seat-construction logic around it) in code — for example, giving `buildSeats` a way to decide, per role, which `Signer` to construct — and redeploying. This is a statement about the code as it exists today, not a description of an intended extension API.

> [!NOTE]
> `originate`'s bilateral counter-signing (`action-service.ts:219-224`, above) does not go through any `Signer`. An external-wallet integration that needs to cover loan origination has to address that path separately — it is out of scope for a `Signer` implementation alone.

## How this connects

- [Session and Seat Model](../03-architecture/session-seat-model.md#the-signer-seam) — the seam in the context of the full seat/occupancy model, and how it relates to `claim`/`release`.
- [Account Derivation](../03-architecture/account-derivation.md) — where `ServerSigner`'s wallet comes from: `deriveAccount(seed, role, index)`, deterministic and never randomly generated.
- [Persistence](../03-architecture/persistence.md#no-private-keys-are-ever-stored) — why `ServerSigner`'s key survives an engine restart without ever being written to the store: it is re-derived from the seed and a persisted token, not read back from disk.
