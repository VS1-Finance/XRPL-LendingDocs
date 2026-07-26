---
label: Reads (state/balances/log)
order: 30
---

# Read Routes

Three `GET` routes give a client a session's live, unmemoized picture: on-chain protocol state,
per-account balances, and the durable action log. None takes a body; all three 404 on an unknown
session id, checked before the read runs (`routes/sessions.ts:75-94`). These are the routes a
front end polls to watch a session evolve — see
[Live State & Balances Reads](../03-architecture/state-and-balances.md) for how the two ledger-backed
reads are composed under the hood.

| Method | Path | Reader | Status |
|---|---|---|---|
| GET | `/sessions/:id/state` | `readSessionState` (`state-service.ts`) | 200 / 404 |
| GET | `/sessions/:id/balances` | `readBalances` (`balances-service.ts`) | 200 / 404 |
| GET | `/sessions/:id/log` | `sessions.log` → `store.getLog` (`store.ts`) | 200 / 404 |

## GET /sessions/:id/state

Looks the session up; if it doesn't exist, `404` with `{ "error": "no session <id>" }`
(`routes/sessions.ts:76-77`). Otherwise returns `readSessionState(session)` (`routes/sessions.ts:78`),
read live from the validated ledger — no cached copy backs this response.

**Response shape** (`SessionState`, `state-service.ts:8-28`):

```ts
interface SessionState {
  setupId: string;
  vault: { assetsTotal: string; assetsAvailable: string; shareMptId?: string } | null;
  broker: { coverAvailable: string } | null;
  loans: {
    loanId: string;
    borrower: string;
    principalOutstanding: string;
    totalOutstanding: string;
    paymentRemaining: number;
    defaulted: boolean;
    defaultableNow: boolean;
    defaultableInSeconds: number | null;
  }[];
  seats: { key: string; occupant: string; participant?: string }[];
  credentials: { address: string; status: "accepted" | "pending" | "none" }[];
}
```

Field notes, all traced to `state-service.ts:93-104`:

- `vault` / `broker` are `null` if the owner account has no Vault or LoanBroker object yet
  (`firstObject` returns `undefined`, `state-service.ts:46-47,95-96,107-109`); otherwise
  `assetsTotal`/`assetsAvailable`/`coverAvailable` are rendered as whole XRP (via
  `dropsToXrpString`) when the session asset is native XRP, or as the raw issued-amount string
  otherwise (`assetValue`, `state-service.ts:40-43`). `shareMptId` is present only once the vault
  has one (`session.env.objects.shareMptId`, `state-service.ts:95`).
- `loans[]` — one entry per Loan object owned by each borrower account, from
  `account_objects type:"loan"` (`state-service.ts:50-51`). `defaulted` reads
  `LSF_LOAN_DEFAULTED = 0x00010000` off the Loan's `Flags` (`:30,53`). `defaultableNow` is true
  only when not already defaulted, `paymentRemaining > 0`, and the ripple-epoch clock has passed
  `NextPaymentDueDate + GracePeriod` (`:57-59`). `defaultableInSeconds` is the remaining wait when
  not yet defaultable, else `null` (defaulted, fully paid, or already defaultable —
  `state-service.ts:68`).
- `seats[]` is not a ledger read — sourced from the in-memory `session.seats` map. `key` is
  `` `${role}:${index}` ``; `occupant` is the occupant kind (`"open" | "bot" | "human"`); `participant`
  (the human's id) is present only when `occupant === "human"` (`state-service.ts:98-102`).
- `credentials[]` is populated only for a permissioned session with a credential issuer present
  (`isPermissioned(session.env) && credentialIssuer`, `state-service.ts:80`) — a public vault
  returns `[]`. Status is judged against the session's **credential issuer**, not the currency
  issuer: `"none"` if no Credential object matches `{ Issuer: credentialIssuer, Subject: address }`;
  otherwise `"accepted"` if `LSF_CREDENTIAL_ACCEPTED = 0x00010000` is set on that object's `Flags`,
  else `"pending"` (`state-service.ts:31,84-89`).

> [!NOTE]
> `LSF_LOAN_DEFAULTED` and `LSF_CREDENTIAL_ACCEPTED` are the same numeric bit (`0x00010000`) but
> distinct flags on distinct object types (Loan vs. Credential) — see
> [Live State & Balances Reads](../03-architecture/state-and-balances.md#the-shared-flag-bit) for
> the full explanation; do not conflate them.

**Example — permissioned session, one loan not yet defaultable:**

```json
{
  "setupId": "session-abc123",
  "vault": {
    "assetsTotal": "10000",
    "assetsAvailable": "7000",
    "shareMptId": "00080000C29AF3F...9B2E"
  },
  "broker": {
    "coverAvailable": "500"
  },
  "loans": [
    {
      "loanId": "A1B2C3D4...",
      "borrower": "rBorrowerAddr...",
      "principalOutstanding": "2800",
      "totalOutstanding": "2940",
      "paymentRemaining": 11,
      "defaulted": false,
      "defaultableNow": false,
      "defaultableInSeconds": 259200
    }
  ],
  "seats": [
    { "key": "owner:0", "occupant": "bot" },
    { "key": "depositor:0", "occupant": "human", "participant": "alice" },
    { "key": "borrower:0", "occupant": "bot" }
  ],
  "credentials": [
    { "address": "rDepositor0Addr...", "status": "accepted" },
    { "address": "rBorrower0Addr...", "status": "pending" }
  ]
}
```

**404** (unknown session):

```json
{ "error": "no session session-doesnotexist" }
```

## GET /sessions/:id/balances

Looks the session up; `404` with `{ "error": "no session <id>" }` on miss
(`routes/sessions.ts:84-85`). Otherwise returns `readBalances(session)` (`routes/sessions.ts:86`).

**Response shape** (`SessionBalances` / `AccountBalance`, `balances-service.ts:6-18`):

```ts
interface AccountBalance {
  seat: string;
  role: string;
  address: string;
  xrp: string;
  assetHeld: string;
  shares: string;
}

interface SessionBalances {
  asset: string;
  accounts: AccountBalance[];
}
```

`asset` is the vault's currency code (`session.env.asset.currency`, `balances-service.ts:23,38`).
`accounts` has one entry per seat in `session.seats`, read in parallel
(`balances-service.ts:27-37`):

- `seat` — `` `${role}:${index}` ``; `role` and `address` copied straight off the seat
  (`balances-service.ts:35`).
- `xrp` — whole-XRP string from `account_info.account_data.Balance` (drops → XRP via
  `dropsToXrpString`) (`balances-service.ts:42-50`).
- `assetHeld` — the holder's trust-line balance to the issuer for an IOU vault
  (`account_lines`, matched by `currency`); fixed `"0"` when the asset is XRP or has no issuer
  (`balances-service.ts:32,53-62`).
- `shares` — the holder's vault-share MPT balance (`account_objects type:"mptoken"`, matched on
  `MPTokenIssuanceID === shareMptId`); fixed `"0"` if the vault has no `shareMptId` yet
  (`balances-service.ts:33,65-75`).

> [!NOTE]
> **An unfunded (not-yet-activated) account reads as all-zero, not an error.** Each of `readXrp`,
> `readIssued`, `readShares` catches `actNotFound` and returns `"0"` instead of throwing
> (`isAccountNotFound`, `balances-service.ts:77-80`). A seat can be derived (has an address) before
> its funding transaction has settled on-ledger; this read renders that seat as
> `{ xrp: "0", assetHeld: "0", shares: "0" }` rather than failing the whole response.

**Example:**

```json
{
  "asset": "XRP",
  "accounts": [
    {
      "seat": "owner:0",
      "role": "owner",
      "address": "rOwnerAddr...",
      "xrp": "48.999988",
      "assetHeld": "0",
      "shares": "0"
    },
    {
      "seat": "depositor:0",
      "role": "depositor",
      "address": "rDepositor0Addr...",
      "xrp": "22.5",
      "assetHeld": "0",
      "shares": "3000000000"
    },
    {
      "seat": "depositor:1",
      "role": "depositor",
      "address": "rDepositor1Addr...",
      "xrp": "0",
      "assetHeld": "0",
      "shares": "0"
    }
  ]
}
```

(`depositor:1` above is unfunded — all-zero per the note.)

**404** (unknown session):

```json
{ "error": "no session session-doesnotexist" }
```

## GET /sessions/:id/log

Checks the session exists (`sessions.get(id)`); `404` with `{ "error": "no session <id>" }` if not
(`routes/sessions.ts:92`). Otherwise returns `sessions.log(id)` (`routes/sessions.ts:93`), which
calls `EngineStore.getLog(setupId)` (`session-service.ts:230-232` → `store.ts:158-174`) — the
persisted action log for the session, ordered oldest-first (`orderBy: { seq: "asc" }`,
`store.ts:161`). Unlike `/state` and `/balances`, this is a database read, not a ledger read.

**Response shape** (`StoredAction`, `store.ts:21-31`), an array of:

```ts
interface StoredAction {
  seq: number;
  ts: number;
  actor: string;
  role: string;
  by: "human" | "bot" | "system";
  action: string;
  code: string;
  hash?: string;
  params?: Record<string, string>;
}
```

- `seq` — assigned per-session, monotonically increasing, starting at 1 (`store.ts:113-122,146`).
- `ts` — the row's timestamp as epoch milliseconds (`r.ts.getTime()`, `store.ts:165`).
- `actor` / `role` / `by` — who acted: `actor` is the seat key (or `"system"` for provisioning),
  `role` its role string, `by` one of `"human" | "bot" | "system"` (`store.ts:123-125,147-149`).
- `action` / `code` — the action name and its resulting ledger/result code (e.g. `tesSUCCESS`)
  (`store.ts:126-127,150-151`).
- `hash` — the transaction hash, when the action produced one; omitted otherwise
  (`hash ?? undefined`, `store.ts:171`).
- `params` — the raw action parameters as supplied, when present; omitted otherwise
  (`store.ts:172`).

**Provisioning steps appear as genesis entries.** Right after a session is created, its
provisioning steps are recorded as the first log rows, before any human or bot action
(`session-service.ts:115-120` calling `saveProvisioningSteps`, `store.ts:138-155`). These rows are
attributed `actor: "system"`, `role: "system"`, `by: "system"`, `seq` starting at 1
(`store.ts:146-153`) — they have no `params` field (only `action`, `code`, optional `hash`; see
`saveProvisioningSteps`'s `data` mapping, `store.ts:144-154`, which omits `params` entirely).

**Example** — a session's log starting with provisioning genesis, then a human deposit. Genesis
`action` values are real step names from the provisioning builders (`steps.ts:162,181,205,241` —
`domain-create`, `vault-create`, `broker-create`, `cover-deposit`; the full step list is in
[Provisioning Sequence](../03-architecture/provisioning-sequence.md)):

```json
[
  {
    "seq": 1,
    "ts": 1750000000000,
    "actor": "system",
    "role": "system",
    "by": "system",
    "action": "domain-create",
    "code": "tesSUCCESS",
    "hash": "F3C1A9...D02E"
  },
  {
    "seq": 2,
    "ts": 1750000001200,
    "actor": "system",
    "role": "system",
    "by": "system",
    "action": "vault-create",
    "code": "tesSUCCESS",
    "hash": "A02B7E...119C"
  },
  {
    "seq": 3,
    "ts": 1750000060000,
    "actor": "depositor:0",
    "role": "depositor",
    "by": "human",
    "action": "deposit",
    "code": "tesSUCCESS",
    "hash": "9B4E21...771A",
    "params": { "amount": "1000" }
  }
]
```

**404** (unknown session):

```json
{ "error": "no session session-doesnotexist" }
```

## See also

- [Live State & Balances Reads](../03-architecture/state-and-balances.md) — how `readSessionState`
  and `readBalances` compose their ledger reads, field by field.
- [Session Persistence](../03-architecture/persistence.md) — the store behind `/log`, including
  what survives an engine restart.
- [Engine HTTP API](./index.md) — the full route table and error-model conventions shared across
  every route, including these three.
