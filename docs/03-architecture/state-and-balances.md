---
label: State & Balances
order: 10
---

# Live State & Balances Reads

The engine holds no cached model of a session's on-ledger truth. Every time a client asks "what is
this session's state" or "what does this account hold," the engine opens a fresh set of
`account_objects` / `account_info` / `account_lines` requests against `ledger_index: "validated"`
and assembles the answer from what comes back. The validated ledger **is** the source of truth —
there is no intermediate database row for a vault's assets, a loan's status, or an account's
balance that could drift from it. (The engine does persist session metadata — seats, tokens,
the action log — but never derived ledger state; see [Session Persistence](./persistence.md).)

This composition happens in two functions: `readSessionState` (`state-service.ts:37-105`) for a
session's protocol objects, and `readBalances` (`balances-service.ts:22-75`) for per-account
holdings. Both take a `Session` (which carries the connected `client: Client` and the derived
account set) and return a plain object built from live reads — no memoization between calls.

## readSessionState

`state-service.ts:37-105` composes five kinds of `account_objects` reads, all against
`ledger_index: "validated"`:

| Read | Account queried | `type` filter | Cardinality |
|---|---|---|---|
| Vault | `owner` | `"vault"` | first result (`firstObject`, `state-service.ts:107-109`) |
| LoanBroker | `owner` | `"loan_broker"` | first result (`firstObject`) |
| Loan | each `borrower` | `"loan"` | all results, per borrower |
| Credential | each depositor/borrower (permissioned sessions only) | `"credential"` | matched against the credential issuer |

**Vault and broker** (`state-service.ts:46-47`): one `account_objects` call each against the
`owner` account, taking the first object of that type via the shared `firstObject` helper
(`state-service.ts:107-109`). `assetValue()` (`state-service.ts:40-43`) renders `AssetsTotal` /
`AssetsAvailable` / `CoverAvailable` as whole XRP (via `dropsToXrpString`) when the session asset
is native XRP, or as the raw issued-amount string otherwise.

**Loans** (`state-service.ts:49-71`): one `account_objects account:<borrower> type:"loan"` call
per borrower, iterating every returned Loan object. For each loan:

```ts
const defaulted = (Number(loan.Flags ?? 0) & LSF_LOAN_DEFAULTED) !== 0;
const paymentRemaining = Number(loan.PaymentRemaining ?? 0);
const defaultableAt = Number(loan.NextPaymentDueDate ?? 0) + Number(loan.GracePeriod ?? 0);
const secondsUntil = defaultableAt - nowRipple();
const defaultableNow = !defaulted && paymentRemaining > 0 && defaultableAt > 0 && secondsUntil <= 0;
```
(`state-service.ts:53-59`)

`defaultableNow` is true only when the loan is not already defaulted, has payments remaining, and
the ripple-epoch clock (`nowRipple()`, offset `946684800` from Unix epoch, `state-service.ts:34-35`)
has passed `NextPaymentDueDate + GracePeriod`. When not yet defaultable, `defaultableInSeconds`
reports the remaining wait (`Math.max(0, secondsUntil)`); it is `null` once defaulted, fully paid,
or already defaultable (`state-service.ts:68`).

**Credentials** (`state-service.ts:73-91`): only evaluated for a permissioned session with a
`credentialIssuer` present (`isPermissioned(session.env)`, `state-service.ts:80`) — a public vault
has no credential subjects and the list returns empty without any per-account lookup. For each
depositor and borrower, one `account_objects account:<acct> type:"credential"` call, then:

```ts
const mine = creds.find((c) => c.Issuer === credentialIssuer && c.Subject === acct.address);
const status = !mine ? "none" : (Number(mine.Flags ?? 0) & LSF_CREDENTIAL_ACCEPTED) !== 0 ? "accepted" : "pending";
```
(`state-service.ts:84-89`)

Membership is judged against the session's **credential issuer** account, not the currency issuer
— the two are distinct derived accounts by design (see [Account Derivation](./account-derivation.md)
and the credential-issuer-vs-currency-issuer split in
[Ledger Objects Reference](../02-protocol/ledger-objects-reference.md)).

**Seats** (`state-service.ts:98-102`): not a ledger read at all — sourced from the in-memory
`session.seats` map (`key: role:index`, `occupant: "open"|"bot"|"human"`, plus `participant` id
when human-held). This is the one field of `SessionState` that reflects engine process state
rather than the ledger.

### The shared flag bit

```ts
const LSF_LOAN_DEFAULTED = 0x00010000;
const LSF_CREDENTIAL_ACCEPTED = 0x00010000;
```
(`state-service.ts:30-31`)

Both constants are the same numeric bit, `0x00010000`. They are **distinct flags on distinct
object types** that happen to share a bit position — `LSF_LOAN_DEFAULTED` is read off `Flags` on a
**Loan** object (`state-service.ts:53`); `LSF_CREDENTIAL_ACCEPTED` is read off `Flags` on a
**Credential** object (`state-service.ts:87`), and matches the protocol's documented `lsfAccepted`
(confirmed per `.docsource/XLS-VERIFICATION.md` item 1: xrpl.org Credential ledger-entry reference,
"the subject has accepted the credential," off by default, set by `CredentialAccept`). Nothing
links the two constants — a Loan's default bit says nothing about any Credential's acceptance bit,
and vice versa. `state-service.ts` defines them as two separate local constants precisely because
they collide numerically; do not conflate them when reading flag-check code here or elsewhere in
this codebase.

> [!NOTE]
> See the same note, restated against the full object field tables, in
> [Ledger Objects Reference](../02-protocol/ledger-objects-reference.md).

## readBalances

`balances-service.ts:22-75` reads three values per seat, in parallel across all seats
(`Promise.all` over `session.seats`, `balances-service.ts:28-37`) and in parallel per seat across
the three reads (`balances-service.ts:30-34`):

| Read | Request | Field extracted | Source |
|---|---|---|---|
| XRP | `account_info account:<addr> ledger_index:"validated"` | `account_data.Balance` (drops → whole XRP via `dropsToXrpString`) | `balances-service.ts:42-50` |
| Issued asset held | `account_lines account:<addr> peer:<issuer> ledger_index:"validated"` | line matching `currency`, its `balance` | `balances-service.ts:53-62` |
| Vault shares | `account_objects account:<addr> type:"mptoken" ledger_index:"validated"` | object matching `MPTokenIssuanceID === shareMptId`, its `MPTAmount` | `balances-service.ts:65-75` |

The issued-asset read is skipped (`assetHeld` fixed to `"0"`) when the session asset is XRP or has
no issuer (`balances-service.ts:32`); the share read is skipped when the vault has no
`shareMptId` yet, i.e. before `VaultCreate` has run (`balances-service.ts:33`).

**Not-yet-funded accounts read as zero, not an error.** Each of the three read functions
(`readXrp`, `readIssued`, `readShares`) wraps its request in a `try/catch` and, on
`actNotFound`, returns `"0"` instead of throwing:

```ts
function isAccountNotFound(err: unknown): boolean {
  const code = (err as { data?: { error?: string } })?.data?.error;
  return code === "actNotFound" || /actnotfound|account not found/i.test(String((err as { message?: string })?.message ?? err));
}
```
(`balances-service.ts:77-80`)

This matters because a session's seat map can include accounts that are derived (they have an
address) but not yet on-ledger (never funded/activated) — for example a freshly grown seat pool
before its funding transaction has settled. `readBalances` renders such a seat as
`{ xrp: "0", assetHeld: "0", shares: "0" }` rather than surfacing a ledger lookup failure to the
caller.

## Which endpoint surfaces which read

| Endpoint | Calls | Returns |
|---|---|---|
| `GET /sessions/:id/state` | `readSessionState` | `{ setupId, vault, broker, loans[], seats[], credentials[] }` |
| `GET /sessions/:id/balances` | `readBalances` | `{ asset, accounts[] }` — one `{ seat, role, address, xrp, assetHeld, shares }` per seat |

Both routes 404 if the session id is unknown before calling the reader
(`routes/sessions.ts:75-79,83-87`); neither takes a request body. See
[Reads API](../04-api/reads.md) for the full request/response contract, and
[Ledger Objects Reference](../02-protocol/ledger-objects-reference.md) for the field-by-field
detail of every object these reads consume.
