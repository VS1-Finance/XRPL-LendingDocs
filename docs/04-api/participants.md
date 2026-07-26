---
label: Add Participant
order: 50
---

# Add Participant

Adds one participant — a depositor or a borrower — to an already-provisioned, running session. The
new account is derived, funded, and (for a permissioned session) credentialed on the ledger, then
seated bot-occupied so it is immediately part of the session. This is the same on-ledger recipe
`create` runs per member during provisioning (see [Provisioning Sequence](../03-architecture/provisioning-sequence.md)),
run once, at runtime, for a single new member.

## Request

```
POST /sessions/:id/participants
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `role` | `"depositor"` \| `"borrower"` | yes | Any other value, or a missing field, is rejected. |

Source: `routes/sessions.ts:99-117`.

## Response

`200` with the session's updated `SessionSummary` (`registry.ts:7-16`) — the same shape returned by
`GET /sessions/:id` — now carrying one more seat, occupied by a bot.

| Status | Condition | Source |
|---|---|---|
| 200 | Participant added; updated `SessionSummary` returned | `routes/sessions.ts:106,110` |
| 400 | `role` missing or not `depositor`/`borrower` | `routes/sessions.ts:103` |
| 404 | No session with the given `:id` | `routes/sessions.ts:100-101` |
| 409 | The role's pool is already at `MAX_POOL` (20) | `routes/sessions.ts:114`, `CapacityError` at `session-service.ts:14`, `MAX_POOL` at `session-service.ts:10` |
| 500 | An on-ledger or faucet failure during provisioning of the new account | `routes/sessions.ts:115` |

`SessionService.addParticipant` (`session-service.ts:136-160`) checks capacity before touching the
ledger: `session.env.accounts[plural].length >= MAX_POOL` throws `CapacityError`
(`session-service.ts:141`), which the route maps to 409 (`routes/sessions.ts:114`). Any other thrown
error — an on-ledger submission failure or a faucet failure while funding the new account — is
mapped to 500 (`routes/sessions.ts:115`).

## What happens on the ledger

The on-ledger recipe is `addParticipant` in `packages/session/src/add-participant.ts:32-109`,
invoked from `SessionService.addParticipant` (`session-service.ts:153`). It mirrors the per-member
slice of provisioning:

1. **Derive the next-index account.** The next index for the role is however many accounts of that
   role the environment already holds — `session.env.accounts[plural].length`
   (`add-participant.ts:45`) — then `deriveAccount(seed, role, index)` (`add-participant.ts:46`)
   produces the same deterministic wallet provisioning would have produced at that index. See
   [Deterministic Account Derivation](../03-architecture/account-derivation.md).
2. **Fund it.** Reserve rates are read live from the ledger (`readReserveRates`,
   `add-participant.ts:52`) and `roleReserveDrops` (`add-participant.ts:54`) computes the role's
   reserve floor. For a native-XRP vault, the new account additionally needs the XRP liquidity it
   will move — recovered from the owner's broker `DebtMaximum` (`add-participant.ts:56-59`), since
   an XRP vault holds that value already in drops rather than minting it. The total is funded from a
   treasury fanned out for this one target (`add-participant.ts:63-64`). See
   [Per-Role Reserve Funding](../03-architecture/reserve-funding.md).
3. **Credential it, if the session is permissioned.** For a non-XRP (IOU) asset, the account first
   gets a trust line then an issuer distribution (`trustSteps` / `distributeSteps`,
   `add-participant.ts:91-94`); both are no-ops on an XRP asset, guarded explicitly by `isXrp` rather
   than relying on the builders' own short-circuit. If the session is permissioned, the account then
   receives `CredentialCreate` followed by a separate `CredentialAccept`
   (`credentialCreateSteps` / `credentialAcceptSteps`, `add-participant.ts:96-97`). A public XRP vault
   does neither — funding alone is sufficient membership.
4. **Seat it, bot-occupied.** A new `Seat` is built and immediately filled with a bot
   (`fillWithBot`, `add-participant.ts:101-102`), then set into the session's seat map. The account
   is appended to `session.env.accounts[plural]` (`add-participant.ts:106`) — the same environment
   object the engine persists.

`SessionService.addParticipant` then persists the result: `store.updateSessionEnv` writes the
updated environment, `store.createOccupancy` records the new seat as bot-occupied, and an
`add-participant` system action is appended to the log (`session-service.ts:155-157`) — so the new
seat survives an engine restart. See [Engine Persistence](../03-architecture/persistence.md).

## Bots are restarted over the new seat

A running bot scheduler assigns variants to seats once, at start, so it will not pick up a seat
added mid-run on its own. The route checks whether bots were running before the add
(`bots.isRunning`, `routes/sessions.ts:104`) and, if so, stops and restarts the scheduler afterward
over the now-larger seat map (`bots.stop` / `bots.start`, `routes/sessions.ts:109`) so the new
participant is driven immediately.

> [!NOTE]
> **Partial-failure window.** `session-service.ts:131-135` documents a known gap: if the on-ledger
> call throws after `CredentialCreate` lands but before the following `CredentialAccept` settles, a
> retry re-runs `CredentialCreate` from scratch, which the ledger rejects as a duplicate
> (`tecDUPLICATE`) — a fatal result, not a retryable one. This is inherited from the shared
> provisioning step builders and is out of scope to fix at this layer. `SessionService.addParticipant`
> only guarantees it never persists a half-added seat: the store writes run once the on-ledger call
> has returned successfully, not before.
