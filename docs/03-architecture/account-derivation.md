---
label: Account Derivation
order: 70
---

# Deterministic Account Derivation

Every account in a provisioned environment — issuer, credential issuer, owner, each depositor, each borrower — is derived deterministically from `(seed, role, index)`. No private key is ever generated randomly and no private key is ever stored. Given the seed and the role/index scheme, any process can re-derive the exact same wallet at any time.

## The mechanism

`deriveAccount` (`accounts.ts:22-30`):

```ts
export function deriveAccount(seed: string, role: Role, index = 0): DerivedAccount {
  if (!Number.isInteger(index) || index < 0) {
    throw new Error(`account index must be a non-negative integer, got ${index}`);
  }
  const label = `xrpl-lending/account/v1\0${seed}\0${role}\0${index}`;
  const entropy = createHash("sha256").update(label).digest().subarray(0, 16);
  const wallet = Wallet.fromEntropy(Array.from(entropy));
  return { role, index, wallet, address: wallet.classicAddress };
}
```

Entropy is the first 16 bytes of `SHA-256("xrpl-lending/account/v1\0{seed}\0{role}\0{index}")`, fed to `Wallet.fromEntropy` (xrpl.js). The label is domain-separated: a fixed `xrpl-lending/account/v1` prefix plus NUL-separated `seed`, `role`, `index` fields, so a hash computed for this purpose cannot collide with a hash computed for any other purpose over the same raw inputs (`accounts.ts:17-21`).

The same `(seed, role, index)` always produces the same wallet and the same `classicAddress`. Re-running provisioning against the same seed reuses the same on-ledger accounts rather than funding fresh ones — provisioning is idempotent by construction, not by an explicit dedup check.

## The role/index scheme

`Role` (`accounts.ts:8`):

```ts
export type Role = "issuer" | "credentialIssuer" | "owner" | "depositor" | "borrower";
```

`deriveAccountSet` builds the full set for a session (`accounts.ts:45-60`):

```ts
export function deriveAccountSet(
  seed: string,
  pool: { depositors: number; borrowers: number },
  options: { permissioned?: boolean } = {},
): DerivedAccountSet {
  if (pool.depositors < 1 || pool.borrowers < 1) {
    throw new Error("pool must have at least one depositor and one borrower");
  }
  return {
    issuer: deriveAccount(seed, "issuer", 0),
    ...(options.permissioned ? { credentialIssuer: deriveAccount(seed, "credentialIssuer", 0) } : {}),
    owner: deriveAccount(seed, "owner", 0),
    depositors: range(pool.depositors).map((i) => deriveAccount(seed, "depositor", i)),
    borrowers: range(pool.borrowers).map((i) => deriveAccount(seed, "borrower", i)),
  };
}
```

| Role | Index | Present when |
|---|---|---|
| `issuer` | always `0` | always |
| `credentialIssuer` | always `0` | `options.permissioned` only (`accounts.ts:55`) |
| `owner` | always `0` | always |
| `depositor` | `0..depositors-1` | always (at least 1, `accounts.ts:50-52`) |
| `borrower` | `0..borrowers-1` | always (at least 1) |

The comment at `accounts.ts:4-7` explains the role split: the credential issuer is kept as a separate account from the currency issuer so the raw ledger stays legible — currency and credentials are never the same signer. The owner holds both the vault and the broker. Depositors and borrowers are pooled and therefore carry an index; the other three roles are singletons at index 0.

`allAccounts` (`accounts.ts:64-66`) flattens a `DerivedAccountSet` into a stable order: issuer, credential issuer (if any), owner, then depositors, then borrowers.

> [!NOTE]
> The `seed` passed into `deriveAccount` is not always the bare configured seed. The engine composes it per session as `` `${baseConfig.seed}-${token}` `` before deriving (`session-service.ts:167`), where `token` is a per-session value persisted alongside the environment. Derivation itself only ever sees one opaque `seed` string — it has no notion of a base seed plus token.

## Why this matters

**No key custody.** `deriveAccount` returns a `Wallet` computed on demand; nothing about the derivation requires storing it. The engine's persistence layer stores only the session's `token` and its public `env` (addresses, object ids) — never a key — and reconstructs every wallet at load by recombining the base seed with the stored token and re-running derivation (`schema.prisma:5-7,19-22`; `session-service.ts:162-177`, `loadPersisted`). See [Session Persistence](./persistence.md).

**Idempotent provisioning.** Because derivation is a pure function of `(seed, role, index)`, re-provisioning against the same seed lands on the same addresses instead of minting a new environment each time.

**Runtime participant growth.** Adding a participant after a session is already running derives the next free index for that role as however many accounts of that role already exist, then calls the same `deriveAccount`:

```ts
const index = session.env.accounts[plural].length;
const derived = deriveAccount(seed, role, index);
```

(`add-participant.ts:45-46`). This is the same function and the same index scheme as initial provisioning — there is no separate runtime derivation path. See [Participants API](../04-api/participants.md).

See also: [Session and Seat Model](./session-seat-model.md).
