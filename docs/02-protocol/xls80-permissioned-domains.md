---
label: XLS-80 Domains
order: 60
---

# XLS-80 — Permissioned Domains

XLS-80 gives the ledger a native access-control object: a **PermissionedDomain** lists which
credential issuer/type pairs it admits. Any other object that references the domain's ID — here,
a vault — inherits that gate at the protocol level. This system uses XLS-80 for exactly one thing:
turning a vault from open-to-anyone into credential-gated, without any application-level check.

## Transactions

| Transaction | Purpose | Who signs | Source |
|---|---|---|---|
| `PermissionedDomainSet` (create) | Creates the domain, naming the accepted credential issuer + type | owner | `steps.ts:154-167` |
| `PermissionedDomainSet` (update) | Swaps the domain's `AcceptedCredentials` on the existing `DomainID` | owner | `action-service.ts:141-158` |
| `PermissionedDomainDelete` | Removes the domain (teardown) | owner | `teardown.ts:51` |

`PermissionedDomainSet` is reused for both create and update: the same `TransactionType` either
establishes a new domain (no `DomainID` given) or replaces `AcceptedCredentials` on an existing one
(`DomainID` given). This system's `createDomain` step does the former; the engine's `set-domain`
action does the latter.

### Create — `createDomain` (`steps.ts:154-167`)

```ts
// steps.ts:154-167
export async function createDomain(deps: StepDeps): Promise<void> {
  const owner = deps.accounts.owner.wallet;
  // The domain accepts credentials from the credential issuer (not the currency issuer), matching what
  // issueCredentials grants.
  const issuer = requireCredentialIssuer(deps);
  const credHex = encodeCredentialType(requireCredentialType(deps));

  await runBatch(deps, [{
    action: "domain-create",
    alreadyDone: async () => (await findDomainId(deps.client, owner.address)) !== undefined,
    build: () => ({ wallet: owner, tx: { TransactionType: "PermissionedDomainSet", Account: owner.address, AcceptedCredentials: [{ Credential: { Issuer: issuer.address, CredentialType: credHex } }] } }),
  }]);
  deps.env.objects.domainId = await findDomainId(deps.client, owner.address);
}
```

The owner account submits and signs. `AcceptedCredentials` is an array of `{Credential: {Issuer,
CredentialType}}` entries — here, exactly one, naming the credential issuer's address and the
hex-encoded credential type. After submission, the step re-reads the domain back off the ledger
(`findDomainId`) and stores its ID on the environment (`deps.env.objects.domainId`) rather than
trusting a locally-computed ID.

### Update — `set-domain` action (`action-service.ts:141-158`)

```ts
// action-service.ts:141-158
case "set-domain": {
  // Swapping the accepted credentials only makes sense for a permissioned vault, which has a domain.
  const domainId = session.env.objects.domainId;
  if (!domainId) throw new ActionError("this session is a public vault and has no domain to configure", 409);
  return {
    TransactionType: "PermissionedDomainSet",
    Account: account,
    DomainID: domainId,
    AcceptedCredentials: [
      {
        Credential: {
          Issuer: p.issuer ?? resolveCredentialIssuer(session),
          CredentialType: encodeCredentialType(resolveCredentialType(session, p)),
        },
      },
    ],
  };
}
```

This path targets the domain already on the session (`DomainID: domainId`) and replaces its
`AcceptedCredentials` wholesale — it is a swap, not an append. Calling `set-domain` against a
public-vault session (no `domainId`) is rejected before a transaction is even built, with a 409
(`action-service.ts:144`).

### Delete — teardown (`teardown.ts:51`)

```ts
// teardown.ts:49-53
if (env.objects.domainId) {
  await tryDelete(log, "domain", () =>
    submit(client, owner, { TransactionType: "PermissionedDomainDelete", Account: owner.address, DomainID: env.objects.domainId! }, ctx("domain")),
  );
}
```

Only attempted when a `domainId` was recorded on the environment — a public-vault run has none, so
this step is skipped entirely.

## The PermissionedDomain ledger object

Read via `account_objects` filtered to `type: "permissioned_domain"`, against the owner account:

```ts
// ledger-lookups.ts:12-15
export async function findDomainId(client: Client, owner: string): Promise<string | undefined> {
  const objs = await accountObjects(client, owner, "permissioned_domain");
  return objs[0]?.index as string | undefined;
}
```

`findDomainId` is used twice: as the idempotency check inside `createDomain` (skip re-creating a
domain that already exists, `steps.ts:163`), and as the read that populates
`deps.env.objects.domainId` (`steps.ts:166`) — the only place that value enters the provisioning
state.

## The central mechanic: DomainID pinned into VaultCreate

The domain by itself does nothing to the vault. The gate exists only because the domain's ID is
captured at creation and then written into `VaultCreate` alongside `tfVaultPrivate`:

```ts
// steps.ts:169-193
export async function createVault(deps: StepDeps): Promise<void> {
  const owner = deps.accounts.owner.wallet;
  // A permissioned vault has a domain (created just before this) and is private + domain-gated. A public
  // vault has no domain: it is created open, so anyone may deposit without a credential.
  const domainId = deps.env.objects.domainId;
  const permissioned = domainId !== undefined;

  const asset: Currency = isXrpAsset(deps.config.asset)
    ? { currency: "XRP" }
    : { currency: deps.config.asset.currency, issuer: deps.accounts.issuer.address };

  await runBatch(deps, [{
    action: "vault-create",
    alreadyDone: async () => (await findVault(deps.client, owner.address)) !== undefined,
    build: () => ({
      wallet: owner,
      tx: {
        TransactionType: "VaultCreate",
        Account: owner.address,
        Asset: asset,
        ...(permissioned ? { DomainID: domainId, Flags: VaultCreateFlags.tfVaultPrivate } : {}),
        WithdrawalPolicy: VaultWithdrawalPolicy.vaultStrategyFirstComeFirstServe,
      },
    }),
  }]);
  const vault = await findVault(deps.client, owner.address);
  deps.env.objects.vaultId = vault?.index;
  deps.env.objects.shareMptId = vault?.shareMptId;
}
```

`deps.env.objects.domainId` (populated by `createDomain`, `steps.ts:166`) is read at `steps.ts:173`,
and its mere presence — not its value — decides `permissioned` at `steps.ts:174`. When permissioned,
`DomainID` and `Flags: VaultCreateFlags.tfVaultPrivate` are both spread into the transaction
(`steps.ts:189`); when not, neither field is present and the vault is created open.

The engine's runtime read of the same switch mirrors it exactly:

```ts
// action-service.ts:143
const domainId = session.env.objects.domainId;
if (!domainId) throw new ActionError("this session is a public vault and has no domain to configure", 409);
```

> [!NOTE]
> **`domainId` presence is the sole permissioned/public switch** — checked once at
> `steps.ts:173-174` and again at `action-service.ts:143`, never re-derived from `credentialType` or
> any other config value. This is a deliberate implementation choice: one boolean, computed from one
> field, rather than several config flags that could disagree with each other.

Because the gate is `DomainID` sitting inside the vault object itself, enforcement happens inside
`rippled` when it processes `VaultDeposit`/`VaultWithdraw` — the application layer never evaluates
"is this depositor a domain member." The negative suite proves this at the protocol boundary, not
by inspecting application code:

| Case | Vault | Deposit by non-credentialed account | Result |
|---|---|---|---|
| N1 | permissioned (`DomainID` set) | attempted | `tecNO_AUTH` (`negative-suite/src/cases/credentials.ts:20-31`) |
| P1 | public (no `DomainID`) | attempted | `tesSUCCESS` (`negative-suite/src/cases/credentials.ts:107-121`) |

Same transaction, same absence of a credential, opposite outcomes — the only variable between the
two environments is whether `VaultCreate` carried a `DomainID`.

## AcceptedCredentials: 1 to 10 entries

> **Fact:** a `PermissionedDomainSet` accepts a list of 1 to 10 `AcceptedCredentials` entries. Source:
> [xrpl.org — PermissionedDomainSet](https://xrpl.org/docs/references/protocol/transactions/types/permissioneddomainset)
> ("A list of 1 to 10 Accepted Credentials objects"), XLS-80.

This system's config schema enforces the same bound before a domain is ever submitted:

```ts
// config/schema.ts:51-59
domain: z
  .object({
    // The ledger caps a domain at 10 accepted credentials.
    acceptedCredentials: z
      .array(AcceptedCredentialSchema)
      .min(1, "a domain needs at least one accepted credential")
      .max(10, "a domain accepts at most 10 credentials"),
  })
  .optional(),
```

`.max(10)` matches the ledger's own cap exactly. The current provisioning path only ever builds a
domain with a single entry (`createDomain`, `steps.ts:164`, and the `set-domain` action,
`action-service.ts:149-157`, both construct a one-element `AcceptedCredentials` array) — the schema's
1–10 range is not yet exercised past 1 by this codebase, but the bound it validates against is the
real ledger constraint. No specific rejection code for exceeding the cap is documented by the cited
source, and none is invented here.

## Domain admits the credential issuer, not the currency issuer

`createDomain` builds `AcceptedCredentials` from `requireCredentialIssuer`, a distinct derived
account from the currency issuer that mints the vault's asset:

```ts
// steps.ts:154-159
export async function createDomain(deps: StepDeps): Promise<void> {
  const owner = deps.accounts.owner.wallet;
  // The domain accepts credentials from the credential issuer (not the currency issuer), matching what
  // issueCredentials grants.
  const issuer = requireCredentialIssuer(deps);
  const credHex = encodeCredentialType(requireCredentialType(deps));
```

`requireCredentialIssuer` (`steps.ts:128-132`) pulls `deps.accounts.credentialIssuer` — a role
derived only for a permissioned session (`Role` enum, `accounts.ts:8`) — and throws if it is unset,
since a domain with no credential issuer would be a programming error, not a valid state. The
currency issuer plays no part in `AcceptedCredentials`; it is a separate account used only to mint
the IOU and hold clawback/`DefaultRipple` powers (`amendment-map.md`, "Credential-issuer vs
currency-issuer split"). Keeping the two apart means a domain's admission list, read raw off the
ledger, names only the identity that grants membership — never the identity that issues the asset.

## Read next

- [XLS-70 — Credentials](./xls70-credentials.md)
- [XLS-65 — Single Asset Vault](./xls65-single-asset-vault.md)
- [Negative suite](../06-security/negative-suite.md)
