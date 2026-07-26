---
label: Invariants & Guards
order: 60
---

# Invariants & Guards

This page catalogues every correctness check the reference implementation performs, organized by
**when** it runs and **who** raises it. That framing matters more than it first appears: a
provisioning-time assertion, an engine-side HTTP guard, and a ledger rejection are three different
mechanisms with three different failure shapes, and conflating them misstates where the system's
actual guarantees come from.

## The three-tier model

1. **Provisioning-time invariants** (`packages/bootstrap/src/assertions.ts`) — checked **once**,
   when a session's environment is stood up. They confirm the object graph `provision()` just built
   is the one the harness intended, and they run against accounts and objects the harness itself
   controls. A failure here is an `InvariantError` and aborts provisioning outright — it means the
   provisioning code built the wrong thing, not that a caller sent a bad request.
2. **Request-time guards** (`packages/engine/src/action-service.ts`, `session-service.ts`,
   `routes/*.ts`) — checked on **every** API request, for the lifetime of a running session. They
   confirm the caller is allowed to do what they're asking (seat held, correct role) and that the
   request is well-formed (amount shape, session/seat exists, pool not full). A failure here is a
   4xx HTTP status with `{ "error": "<message>" }` — the request never reaches a signed transaction.
3. **Ledger-enforced rejections** (`tec*` codes) — **not** an application guard at all. The engine
   builds and submits the transaction unconditionally; `rippled` evaluates it against protocol rules
   (credential/domain matching, cover floors, time gates, share balances) the engine's own code does
   not re-check. A rejection here is `HTTP 200` with the ledger's `tec*` code in the response body —
   a settled, fee-claimed outcome, not an engine error.

> [!NOTE]
> Tier 3 is documented in full on [Result Codes](../07-reference/result-codes.md) and is only
> summarized here for contrast. The [Security](./index.md) page states the same three-tier
> distinction as an institutional trust-boundary claim ("the engine's own code enforces very
> little"); this page is the exhaustive catalogue backing that claim, one guard at a time, with the
> exact source line for each.

## Tier 1 — provisioning-time invariants

Both invariants live in `packages/bootstrap/src/assertions.ts` and share one `InvariantError` class
(`assertions.ts:4-9`):

```ts
// assertions.ts:4-9
export class InvariantError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "InvariantError";
  }
}
```

### Single-owner invariant

`assertSingleOwner(client, owner)` (`assertions.ts:13-26`) reads the vault and loan broker
`account_objects` under a candidate owner address and confirms both exist and report the same
`Owner`:

```ts
// assertions.ts:13-26
export async function assertSingleOwner(client: Client, owner: string): Promise<void> {
  const vaults = await accountObjects(client, owner, "vault");
  const brokers = await accountObjects(client, owner, "loan_broker");
  const vault = vaults[0];
  const broker = brokers[0];
  if (!vault) throw new InvariantError("no vault found under the owner account");
  if (!broker) throw new InvariantError("no loan broker found under the owner account");

  const vaultOwner = (vault.Owner as string | undefined) ?? owner;
  const brokerOwner = (broker.Owner as string | undefined) ?? owner;
  if (brokerOwner !== vaultOwner) {
    throw new InvariantError(`broker owner ${brokerOwner} does not match vault owner ${vaultOwner}`);
  }
}
```

Called once, immediately after `createBroker` and before `depositCover` (`provision.ts:117`) — the
moment both objects exist on ledger. This system never creates a separate "originator" account; the
vault-manager and loan-originator are the same seat by construction, and this assertion is the
run-time proof that construction held.

### First-loss cover floor

`assertCoverMeetsMinimum(client, owner, expectedMinimum)` (`assertions.ts:31-45`) reads the broker's
`CoverAvailable` back from ledger and compares it against the configured minimum:

```ts
// assertions.ts:31-45
export async function assertCoverMeetsMinimum(
  client: Client,
  owner: string,
  expectedMinimum: string,
): Promise<{ cover: string }> {
  const brokers = await accountObjects(client, owner, "loan_broker");
  const broker = brokers[0];
  if (!broker) throw new InvariantError("no loan broker found under the owner account");

  const cover = readAmount(broker.CoverAvailable);
  if (Number(cover) < Number(expectedMinimum)) {
    throw new InvariantError(`broker cover ${cover} is below the required ${expectedMinimum}`);
  }
  return { cover };
}
```

Called right after `depositCover`, at `provision.ts:119-120` — the configured `coverAmount` is
checked against what the ledger actually reports as `CoverAvailable`, not merely the amount the
deposit transaction requested.

Both calls sit at the tail of `provision()` (`provision.ts:113-121`):

```ts
// provision.ts:113-121 (excerpt)
await createVault(deps);
await createBroker(deps);

// The single-owner invariant is checked the moment both objects exist.
await assertSingleOwner(client, accounts.owner.address);

await depositCover(deps);
const { cover } = await assertCoverMeetsMinimum(client, accounts.owner.address, config.coverAmount);
```

Neither invariant is re-checked once a session is running — they gate the environment's creation,
not any subsequent request. See [Composition & Invariants](../02-protocol/composition-and-invariants.md#1-single-owner-invariant)
for the full protocol-level rationale (why the object graph can go wrong without this check, and how
cover interacts with bot-side loan sizing) — this page states only the mechanism.

## Tier 2 — request-time guards (engine)

Every guard below runs inside the running engine, on the request path, before a transaction is built
or submitted. They are the complete list of application-enforced authorization — see the
[Security](./index.md#ledger-enforced-not-app-enforced-authorization) page for why that list is
deliberately short.

### Seat-held authorization

`dispatchAction` (`action-service.ts:57-71`) is the single entry point for every non-`originate`
action. It checks the named seat exists, then that it is held by the requesting participant:

```ts
// action-service.ts:57-62
export async function dispatchAction(session: Session, request: ActionRequest, participant: string): Promise<ActionResult> {
  const seat = session.seats.get(request.seat);
  if (!seat) throw new ActionError(`session has no seat ${request.seat}`, 404);
  if (seat.occupant.kind !== "human" || seat.occupant.id !== participant) {
    throw new ActionError(`${request.seat} is not held by ${participant}`, 409);
  }
```

Unknown seat → `404`. Seat not currently human-held, or held by a different participant, → `409`.
`originate` (`action-service.ts:188-232`) repeats the identical check for the owner seat
(`:190-193`).

### Originate role guards

`originate` (`action-service.ts:188-232`) adds two role checks after the seat-held check, both
before any wallet is derived or transaction built:

```ts
// action-service.ts:194-200
// Origination is owner-only: the signing wallets below are re-derived by role, so a non-owner seat
// would sign with the wrong account (Account ≠ key) and the ledger would reject it opaquely. Guard
// the roles here so a misdirected request is a clean rejection, not a 500.
if (owner.role !== "owner") throw new ActionError("only the owner seat can originate a loan", 409);
const borrowerSeat = session.seats.get(required(params, "borrower"));
if (!borrowerSeat) throw new ActionError(`session has no seat ${params.borrower}`, 404);
if (borrowerSeat.role !== "borrower") throw new ActionError(`${borrowerSeat.role} seat cannot be a loan counterparty`, 409);
```

The acting seat must have `role === "owner"` (`:197`, `409` otherwise); the named `borrower` seat
must exist (`:199`, `404` otherwise) and have `role === "borrower"` (`:200`, `409` otherwise). Both
exist because `originate`'s signing wallets are re-derived by role
(`deriveAccount(session.seed, "owner"|"borrower", index)`, `:219-220`) — a misrouted seat would
otherwise sign with an account that doesn't match the transaction's `Account`/`Counterparty` fields,
surfacing as an opaque ledger-level failure instead of a clean 409 at the engine boundary.

### Amount validation

`requireAmount` (`action-service.ts:247-252`) is the single amount-shape check every action that
carries an amount goes through (`deposit`, `withdraw`, `repay`, `deposit-cover`, and, via
`brokerValue`, `originate`'s principal):

```ts
// action-service.ts:247-252
function requireAmount(value: string): string {
  if (!/^\d+(\.\d+)?$/.test(value.trim()) || Number(value) <= 0) {
    throw new ActionError(`invalid amount: ${value}`, 400);
  }
  return value;
}
```

A non-numeric or non-positive string is rejected as `400` before it reaches either serialization
path (XRP's `xrpToDrops` or the IOU amount object) — both of which would otherwise throw a
differently-shaped, opaque error deep inside submission.

### asClientError — reclassifying thrown errors as 400

`asClientError` (`action-service.ts:31-46`) is not a precondition check but a catch-site
reclassifier: it turns specific thrown errors into a clean `400 ActionError` rather than letting them
fall through as an undifferentiated `500`.

```ts
// action-service.ts:31-46
function asClientError(err: unknown): never {
  if (err instanceof ActionError) throw err;
  const name = (err as { name?: string })?.name ?? "";
  const message = err instanceof Error ? err.message : String(err);
  if (
    name === "ValidationError" ||
    /Transaction failed, tem/.test(message) ||
    /illegal amount|not a non-negative decimal|invalid amount/.test(message)
  ) {
    throw new ActionError(message, 400);
  }
  throw err;
}
```

It reclassifies exactly three failure shapes as caller error: xrpl's `ValidationError` (a malformed
transaction/amount caught by the `xrpl` library itself), a preliminary `tem*` rejection (the
transaction never reached a ledger — see [Result Codes](../07-reference/result-codes.md#tem--malformed-never-reaches-consensus)),
and the amount-shape errors thrown while building a transaction (`illegal amount`,
`not a non-negative decimal`). Anything else — a dropped connection, an RPC fault — is rethrown
unchanged and becomes `500` at the route (`routes/actions.ts:46-50`). Both `dispatchAction`
(`:69`) and `originate` (`:230`) route their catch block through this function.

### Pool capacity

`SessionService.addParticipant` (`session-service.ts:136-160`) checks the target pool against
`MAX_POOL` before doing any on-ledger work:

```ts
// session-service.ts:10,14-19,141
const MAX_POOL = 20;

export class CapacityError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "CapacityError";
  }
}
...
if (session.env.accounts[plural].length >= MAX_POOL) throw new CapacityError(`the ${plural} pool is at capacity (${MAX_POOL})`);
```

`CapacityError` is a distinct class specifically so the participants route can map it to `409` (a
state conflict) rather than the `400`/`500` a generic validation or provisioning failure would get
(`routes/sessions.ts:114`). `clampPool` (`session-service.ts:21-24`) enforces the same `MAX_POOL`
ceiling at session-creation time by silently clamping a requested pool size rather than rejecting
the request — capacity is only ever an explicit request-time error on the *add-participant* path,
where a caller could otherwise push a running session past the ceiling one seat at a time.

### Public-vault feature gating

Three call sites reject a credential/domain action outright when the session has no domain — i.e.
`permissioned: false` was set at session creation (`session-service.ts:96-98`). All three are `409`,
all three are engine-side (no ledger round-trip needed to know the session has no domain):

```ts
// action-service.ts:141-145 (set-domain)
case "set-domain": {
  const domainId = session.env.objects.domainId;
  if (!domainId) throw new ActionError("this session is a public vault and has no domain to configure", 409);
  ...
```

```ts
// action-service.ts:272-278 (resolveCredentialType — issue-credential, revoke-credential, accept-credential, set-domain)
function resolveCredentialType(session: Session, p: Record<string, string>): string {
  if (session.env.objects.domainId === undefined) {
    throw new ActionError("this session is a public vault and has no credential scheme", 409);
  }
  ...
```

```ts
// action-service.ts:283-287 (resolveCredentialIssuer — accept-credential, set-domain default issuer)
function resolveCredentialIssuer(session: Session): string {
  const address = session.env.accounts.credentialIssuer?.address;
  if (!address) throw new ActionError("this session is a public vault and has no credential issuer", 409);
  return address;
}
```

These exist because a public session's `env.objects.domainId` and
`env.accounts.credentialIssuer` are simply absent (`session-service.ts:96-98`,
[Public Vault](../02-protocol/xls80-permissioned-domains.md) provisioning skips both) — without this
gate, a credential action against a public session would fail deep inside transaction-building with
an undefined-field error rather than a clean, explanatory `409`.

### Route-level status-code guards

Above the service layer, each route family checks resource existence and body shape before calling
into the service, in a fixed per-family order (`routes/actions.ts:12-17`, `routes/seats.ts:16-20,34-38`,
`routes/sessions.ts:100-103`):

| Route family | Order | Source |
|---|---|---|
| Actions (`POST /sessions/:id/actions`) | session exists (404) → `participant` present (400) → `seat`+`action` present (400) → seat/role guards inside the handler (404/409) | `routes/actions.ts:12-17` |
| Seats (`claim`/`release`) | session exists (404) → seat exists (404) → `participant` present (400) → occupancy conflict (409) | `routes/seats.ts:16-20,34-38` |
| Participants (`POST /sessions/:id/participants`) | session exists (404) → `role` is `depositor`/`borrower` (400) → pool capacity (409) / provisioning failure (500) | `routes/sessions.ts:100-103,112-116` |

All three families check session existence before any body validation — there is no route where a
body-shape error outranks an unknown session. Full per-route precedence and the complete status-code
table are on [Engine API — the error model](../04-api/index.md#the-error-model).

## Tier 3 — ledger-enforced rejections (for contrast, not this page's subject)

Everything **not** listed above — a borrower attempting an owner-only action past the role guards
that don't exist for it, a depositor with no accepted credential depositing into a gated vault,
withdrawing more cover than the floor allows, defaulting a loan before its grace period elapses — is
not checked in engine code at all. The engine builds the transaction and submits it unconditionally;
`rippled` evaluates it and returns a `tec*` code, which the engine relays as `HTTP 200` with that code
in the response body (`action-service.ts:67`, `ActionResult.code`). This is a settled, fee-claimed
ledger outcome, not an engine error — see [Result Codes §on-ledger result codes](../07-reference/result-codes.md#1-on-ledger-result-codes)
for the full `tec*` table with concrete triggers, and [Composition & Invariants](../02-protocol/composition-and-invariants.md)
for the protocol-level invariants (bilateral origination, share conservation, time-gated default)
that tier 3 actually enforces.

## Summary

| Guard | Layer | Trigger | Code | Source |
|---|---|---|---|---|
| Single owner (vault + broker share `Owner`) | Provisioning invariant | Called once after `createBroker`, before `depositCover` | `InvariantError` (aborts provisioning) | `assertions.ts:13-26`, called at `provision.ts:117` |
| First-loss cover floor (`CoverAvailable` ≥ configured minimum) | Provisioning invariant | Called once after `depositCover` | `InvariantError` (aborts provisioning) | `assertions.ts:31-45`, called at `provision.ts:119-120` |
| Seat exists | Engine guard | Any action against an unknown seat key | `404` | `action-service.ts:59,190,199` |
| Seat held by requester | Engine guard | Action submitted by a participant who doesn't hold the named seat | `409` | `action-service.ts:60-62,191` |
| Originate: acting seat is owner | Engine guard | `originate` called from a non-owner seat | `409` | `action-service.ts:197` |
| Originate: counterparty is borrower | Engine guard | `originate` names a non-borrower seat as counterparty | `409` | `action-service.ts:200` |
| Amount shape (`^\d+(\.\d+)?$`, > 0) | Engine guard | `deposit`/`withdraw`/`repay`/`deposit-cover`/`originate` principal with a malformed or non-positive amount | `400` | `action-service.ts:247-252` |
| Reclassified client errors (`ValidationError`, `tem*`, illegal-amount) | Engine guard | Caught at the `dispatchAction`/`originate` catch site | `400` | `action-service.ts:31-46` |
| Pool capacity (`MAX_POOL=20`) | Engine guard | `addParticipant` on a pool already at 20 | `409` | `session-service.ts:10,14-19,141`, mapped at `routes/sessions.ts:114` |
| Public-vault feature gating (`set-domain`, credential actions) | Engine guard | Credential/domain action on a session provisioned with `permissioned: false` | `409` | `action-service.ts:144,274,285` |
| Everything else (role separation, credential/domain membership, cover floor at run time, time-gated default, share balance limits) | Ledger rejection | Protocol-level rule violated by an otherwise well-formed, submitted transaction | `tec*` (`HTTP 200`) | See [Result Codes](../07-reference/result-codes.md#1-on-ledger-result-codes) |

## Read next

- [Composition & Invariants](../02-protocol/composition-and-invariants.md) — the protocol-level
  invariants (bilateral origination, share conservation, time-gated default) that tier 3 above
  enforces, with the same enforced-vs-observed framing applied to protocol behavior rather than
  engine code.
- [Engine API — the error model](../04-api/index.md#the-error-model) — the full HTTP status-code
  reference and per-route guard precedence this page's tier 2 section draws from.
- [Result Codes](../07-reference/result-codes.md) — every `tes*`/`tec*`/`tem*` code this system has
  produced or documented, with the observed transaction or negative-suite case behind each.
- [Security](./index.md) — the narrative trust-boundary framing ("the engine's own code enforces
  very little") that this page's tier 2/tier 3 split backs with a complete, line-cited inventory.
