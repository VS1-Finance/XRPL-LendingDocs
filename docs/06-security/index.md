---
label: Security
order: 90
icon: shield
---

# Security Model & Trust Boundaries

This page states, precisely and with citations, where trust sits in the reference implementation: who holds signing keys, what the operational database can and cannot leak, and — the load-bearing point — which authorization guarantees come from the engine's own code and which come from the XRP Ledger itself. The two subsequent pages ([Negative Suite](./negative-suite.md), [Vault Interest Front-Running](./vault-interest-frontrunning.md)) are the adversarial evidence for the claims made here.

## Who signs what

Every transaction submitted on behalf of a seat goes through the `Signer` interface (`signer.ts:12-15`):

```ts
export interface Signer {
  readonly address: string;
  submit(tx: SubmittableTransaction): Promise<SubmitResult>;
}
```

The only implementation today is `ServerSigner` (`signer.ts:20-34`): it holds the account's `Wallet` directly and signs server-side, for both bot-driven and human-driven seats alike (`signer.ts:8-11`, comment). That `Wallet` is never generated randomly and never read back from disk — it comes from `deriveAccount(seed, role, index)`, a pure function over a domain-separated SHA-256 label (`accounts.ts:22-30`; see [Account Derivation](../03-architecture/account-derivation.md)). The same `(seed, role, index)` always reconstructs the same wallet, which is what lets a restarted engine process re-derive every seat's signing key rather than persist it.

`Signer` is a narrow, pluggable seam by design: the interface says nothing about how a signature is produced, and nothing downstream of `seat.signer.submit(...)` depends on `ServerSigner` specifically (`signer.ts:8-11`). Routing a seat through an external wallet — hardware key, custody service, browser-injected signer — means implementing this interface and wiring it in at the one construction site, `buildSeats` (`session.ts:52`). That construction site is hardcoded to `new ServerSigner(...)` today; there is no runtime flag or config field that selects a different signer. Full detail, including the bilateral `originate` path that bypasses `Signer` entirely, is on [Signing Integration](../05-guides/signing-integration.md).

## No keys stored

The engine's operational database persists a session's derivation `token` (a short per-session string) and its public `env` — account addresses and object ids — as JSON. It never persists a wallet or a private key (`schema.prisma:5-7`, header comment; `schema.prisma:19-22`, `Session` model comment).

On boot, `SessionService.loadPersisted` recombines the process's configured base seed with each session's stored `token` into the same seed string used at provisioning, and re-derives every wallet from it (`session-service.ts:164-177`):

```ts
// session-service.ts:164-177
async loadPersisted(): Promise<number> {
  const stored = await this.store.loadAllSessions();
  for (const s of stored) {
    const seed = `${this.baseConfig.seed}-${s.token}`;
    const session = await this.registry.attachFrom(s.env, seed);
    ...
```

The base seed is an engine process environment variable (`ENGINE_SEED`), never written to the store. Consequently: **compromising the operational Postgres instance alone yields session metadata — which addresses exist, who held which seat, what actions were logged — but not signing capability.** Reconstructing a signing key requires both the stored `token` and the process's `ENGINE_SEED`, which live in different trust domains (database vs. process environment). See [Persistence](../03-architecture/persistence.md#no-private-keys-are-ever-stored) for the full store schema and re-derivation chain.

> [!NOTE]
> This property depends on `ENGINE_SEED` actually being kept out of the database's reach (secrets manager, process env, not a config table). The codebase enforces the *architectural* separation — token in the DB, seed in the process env — not a runtime check that the two never co-mingle.

## Ledger-enforced, not app-enforced authorization

This is the central institutional point: **the engine's own code enforces very little.** What it enforces, precisely, is:

1. **The named seat exists** in the session (`ActionError(..., 404)` if not — `action-service.ts:59`, `:190`, `:199`).
2. **The seat is held by the requesting participant.** `dispatchAction` checks `seat.occupant.kind !== "human" || seat.occupant.id !== participant` and returns `409` otherwise (`action-service.ts:60-62`):

```ts
// action-service.ts:57-62
export async function dispatchAction(session: Session, request: ActionRequest, participant: string): Promise<ActionResult> {
  const seat = session.seats.get(request.seat);
  if (!seat) throw new ActionError(`session has no seat ${request.seat}`, 404);
  if (seat.occupant.kind !== "human" || seat.occupant.id !== participant) {
    throw new ActionError(`${request.seat} is not held by ${participant}`, 409);
  }
```

`originate` repeats the identical occupancy check for the owner seat (`action-service.ts:191-193`), plus two role guards checked in application code — `owner.role !== "owner"` and `borrowerSeat.role !== "borrower"` (`action-service.ts:197`, `:200`) — both there purely to turn a misdirected request into a clean `409` instead of an opaque ledger rejection, since the signing wallets are re-derived by role and a role mismatch would otherwise sign with the wrong account (`action-service.ts:194-196`, comment).

That is the entire list of application-enforced authorization: **seat exists, seat held by caller, and (for `originate` only) a same-process role sanity check.** Everything else — a borrower attempting an owner-only action, a depositor with no credential attempting to deposit into a gated vault, a non-member's share transfer, withdrawing more cover than a floor allows — is not caught by an `if` statement in this codebase at all. It is submitted to the ledger exactly as requested, and the **ledger** rejects it, returning a `tec*` code that the engine passes straight through as `HTTP 200` with that code in the response body (`routes/actions.ts:38`; see [Result Codes §2](../07-reference/result-codes.md#2-http-status-codes) for why a `tec*` is a settled outcome, not an engine error).

Concretely, membership gating on a permissioned vault happens by matching the domain's `AcceptedCredentials` against a live `Credential` ledger object — there is no in-process "is this account a member" check anywhere in `action-service.ts`. `readSessionState` reads the same ledger-level fact for display purposes, not enforcement (`state-service.ts:73-91`):

```ts
// state-service.ts:77-84
// Credentials are issued by the credential issuer (present only for a permissioned session), so
// membership is judged against that account, not the currency issuer.
const credentialIssuer = session.env.accounts.credentialIssuer?.address;
const credentials: SessionState["credentials"] = [];
const subjects = isPermissioned(session.env) && credentialIssuer ? [...session.env.accounts.depositors, ...session.env.accounts.borrowers] : [];
for (const acct of subjects) {
  const res = await session.client.request({ command: "account_objects", account: acct.address, type: "credential", ledger_index: "validated" });
  const creds = res.result.account_objects as unknown as Record<string, unknown>[];
  const mine = creds.find((c) => c.Issuer === credentialIssuer && c.Subject === acct.address);
```

This function reports whether a subject's credential is `"accepted" | "pending" | "none"` (`state-service.ts:85-89`) so the front end can show status — it does not gate any transaction. The actual gate is XLS-80's `PermissionedDomain` object plus the vault's domain check, evaluated by `rippled` when the `VaultDeposit` (or share transfer) is processed. `action-service.ts` builds and submits the transaction unconditionally; the ledger decides `tesSUCCESS` or `tecNO_AUTH`.

> [!NOTE]
> The practical consequence: the security guarantees this system relies on for membership and role separation are the **ledger's** guarantees (XLS-70 credential accept/revoke semantics, XLS-80 domain matching, `Loan`/`LoanBroker` state machine rules enforced by `rippled`), not this codebase's. The engine trusts the ledger's `tec*` response as the authoritative answer and simply relays it. A bug in this application's own guard logic (items 1–2 above) can misroute a request to the wrong signer or the wrong session; it cannot forge a ledger-level authorization the protocol itself would refuse.

## Credential issuer vs. currency issuer

Membership under a permissioned domain is judged against the **credential issuer**, a distinct derived account from the **currency issuer** — never the same signer (`accounts.ts:4-7`, comment; `state-service.ts:77-78`, comment). `Role` includes both as separate enum members (`accounts.ts:8`), and `credentialIssuer` is derived only when the session is permissioned (`accounts.ts:35-36,55`):

```ts
// accounts.ts:32-40
export interface DerivedAccountSet {
  issuer: DerivedAccount;
  // Present only for a permissioned session: the account that issues the domain credentials, kept
  // distinct from the currency issuer. A public session has no credentials and so no credential issuer.
  credentialIssuer?: DerivedAccount;
  owner: DerivedAccount;
  depositors: DerivedAccount[];
  borrowers: DerivedAccount[];
}
```

Every credential-membership check in the codebase — the live state read shown above (`state-service.ts:77-84`), the domain's `AcceptedCredentials`, and provisioning's own idempotency check — matches against `credentialIssuer`, never against `issuer`. The reason, stated directly in source: keeping the two separate means "currency movement and identity attestation are never signed by the same account," so the raw ledger stays legible even to an observer with no side information. Full transaction-level detail is on [XLS-70 Credentials](../02-protocol/xls70-credentials.md#design-point-membership-is-judged-against-the-credential-issuer-not-the-currency-issuer).

## The adversarial evidence

Two pieces of evidence back the claims above with actual on-ledger outcomes rather than assertion:

- **[The Negative Suite](./negative-suite.md)** — cases N1–N15 (`packages/negative-suite/src/cases/{credentials,lending}.ts`) deliberately submit rejected transactions — wrong credential, wrong issuer, revoked credential, non-member share transfer, premature default, cover below the floor, deleting an object with outstanding obligations — and assert the specific `tec*` each one produces. These are the empirical proof that the rejection boundaries described above are real, not aspirational: every one of N1–N5 is a `tecNO_AUTH` returned by the ledger's domain/credential check, with zero corresponding logic in `action-service.ts` (see [XLS-70 Credentials](../02-protocol/xls70-credentials.md#gating-boundaries-the-negative-suite-proves) and [Result Codes](../07-reference/result-codes.md#tec--claimed-cost-rejected-effect)).
- **[Vault Interest Front-Running](./vault-interest-frontrunning.md)** — a real, on-chain-confirmed finding: a loan's full expected interest is booked into the vault's share price (`AssetsTotal`) at origination (`LoanSet`), before the borrower has paid any of it. A depositor who deposits immediately before origination and redeems their full share balance immediately after captures a proportional slice of that booked interest with no term exposure. This is not a defect in this codebase's authorization logic — it is a protocol-level economic property of how the vault accrues interest, and it is documented separately with the confirming transaction evidence.

## Read next

- [Signing Integration](../05-guides/signing-integration.md) — the `Signer` seam in full: interface, `ServerSigner`, the bilateral `originate` exception, and how to wire in an external signer.
- [Persistence](../03-architecture/persistence.md) — the operational store schema and the no-keys-stored property in full.
- [Account Derivation](../03-architecture/account-derivation.md) — the deterministic derivation function every wallet comes from.
- [XLS-70 Credentials](../02-protocol/xls70-credentials.md) and [XLS-80 Permissioned Domains](../02-protocol/xls80-permissioned-domains.md) — the ledger-level mechanics that do the actual gating.
- [Result Codes](../07-reference/result-codes.md) — the full `tec*`/`tem*`/HTTP status reference.
- [Negative Suite](./negative-suite.md) and [Vault Interest Front-Running](./vault-interest-frontrunning.md) — the adversarial evidence pages.
