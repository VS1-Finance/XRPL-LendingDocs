---
label: XLS-65 Vault
order: 90
---

# XLS-65 — Single Asset Vault

XLS-65 defines the Single Asset Vault: a ledger-native pooled-liquidity object that accepts one asset (XRP, an IOU, or an MPT), issues divisible ownership shares against deposits, and can be gated to a [permissioned domain](../02-protocol/xls80-permissioned-domains.md) (XLS-80). In this system the vault is the liquidity base a [LoanBroker](../02-protocol/xls66-lending-protocol.md) (XLS-66) attaches to and originates loans from. This page covers only the vault itself — creation, deposit/withdraw, admin, deletion, clawback, the ledger object's fields, and the share-accounting math. All four amendments are consumed via `xrpl@5.0.0` (`.docsource/amendment-map.md:3`); every transaction shape and ledger-object field below is quoted from that package's own model source (`node_modules/xrpl/src/models/transactions/vault*.ts`, `node_modules/xrpl/src/models/ledger/Vault.ts`).

## Transactions we use

| Transaction | Purpose | Seat / caller | Key fields we set | Source |
|---|---|---|---|---|
| `VaultCreate` | Create the vault. | owner | `Asset` (XRP `{currency:"XRP"}` or IOU `{currency, issuer}`); permissioned only: `DomainID` + `Flags: tfVaultPrivate (65536)`; always: `WithdrawalPolicy: vaultStrategyFirstComeFirstServe (1)` | `steps.ts:169-197` (build at `:186-192`) |
| `VaultDeposit` | Exchange asset for vault shares. | depositor | `VaultID`, `Amount` | `action-service.ts:77-83`; also `lifecycle/deposit.ts:31`, bots `depositor-variants.ts:25,63` |
| `VaultWithdraw` | Exchange vault shares for asset. | depositor | `VaultID`, `Amount` | `action-service.ts:85-91`; bots `depositor-variants.ts:36`; negative-suite N9 `lending.ts:65-80` |
| `VaultSet` | Modify a mutable vault field. | owner | `VaultID`, `AssetsMaximum` | `action-service.ts:132-139` (sets `AssetsMaximum` at `:138`) |
| `VaultDelete` | Delete the vault once empty of obligations. | owner | `VaultID` | `teardown.ts:44-47`; negative-suite N7 `lending.ts:21-35` |
| `VaultClawback` | Issuer reclaims an IOU holder's vault position. | issuer (currency) | `VaultID`, `Holder`, `Amount` | negative-suite N8 `lending.ts:41-60` (adversarial only — not used in provisioning or normal action flow) |

We never submit `VaultClawback` as part of normal operation; it appears only in the adversarial negative suite, exercised against a non-member holder to prove `tecNO_AUTH`-family rejection (see [result-codes.md](../07-reference/result-codes.md)). See the full verb/transaction cross-reference in [transaction-map.md](../07-reference/transaction-map.md).

### VaultCreate — Asset and mode

`createVault` (`steps.ts:169-197`) builds the `Asset` currency object from config: `{currency:"XRP"}` for an XRP vault, or `{currency, issuer: <currency issuer address>}` for an IOU vault (`steps.ts:176-178`). Whether the vault is permissioned is decided by one prior fact — whether a domain was created — not by a separate flag in config:

```ts
// steps.ts:171-174
const domainId = deps.env.objects.domainId;
const permissioned = domainId !== undefined;
```

If permissioned, the build spreads in `DomainID: domainId, Flags: VaultCreateFlags.tfVaultPrivate` (`steps.ts:189`); if not, neither field is sent and the vault is created public — open to deposits from any account. `WithdrawalPolicy` is always set to `VaultWithdrawalPolicy.vaultStrategyFirstComeFirstServe` (`steps.ts:190`), the only withdrawal-policy value the installed `xrpl` package defines (value `1`; see the exact enum below).

> [!NOTE]
> `xrpl@5.0.0`'s own `VaultCreate` validator throws `ValidationError("VaultCreate: Cannot set DomainID unless tfVaultPrivate flag is set.")` if `DomainID` is present without the flag (`vaultCreate.js:47-49`) — the two are coupled at the client-validation layer, and our code always sets them together (`steps.ts:189`).

Real `xrpl@5.0.0` enum values used here, taken from the installed package's transaction models:

```ts
// node_modules/xrpl/src/models/transactions/vaultCreate.ts (compiled: vaultCreate.js:9-17)
export enum VaultWithdrawalPolicy {
  vaultStrategyFirstComeFirstServe = 1,
}
export enum VaultCreateFlags {
  tfVaultPrivate = 65536,
  tfVaultShareNonTransferable = 131072,
}
```

We use `tfVaultPrivate`; we do not set `tfVaultShareNonTransferable` anywhere in this codebase.

After submission, `createVault` reads the resulting object back with `findVault` and captures both its ledger index and its share MPT id for the rest of the session:

```ts
// steps.ts:194-196
const vault = await findVault(deps.client, owner.address);
deps.env.objects.vaultId = vault?.index;
deps.env.objects.shareMptId = vault?.shareMptId;
```

### VaultDeposit / VaultWithdraw

Both are single-field-pair transactions — `VaultID` and `Amount` — dispatched from the engine's action layer for the seat the caller holds:

```ts
// action-service.ts:76-91
case "deposit":
  return { TransactionType: "VaultDeposit", Account: account, VaultID: session.env.objects.vaultId!, Amount: assetAmount(session, required(p, "amount")) };
case "withdraw":
  return { TransactionType: "VaultWithdraw", Account: account, VaultID: session.env.objects.vaultId!, Amount: assetAmount(session, required(p, "amount")) };
```

`xrpl@5.0.0`'s own model for `VaultWithdraw` additionally supports an optional `Destination` and `DestinationTag` (send the withdrawn assets somewhere other than the withdrawing account) — this system does not use either; every withdrawal returns assets to the withdrawing seat itself.

### VaultSet — what we mutate

`xrpl@5.0.0`'s `VaultSet` model allows three optional mutable fields: `Data`, `AssetsMaximum`, `DomainID` (`vaultSet.ts:20-43`). This system's `set-vault` action only ever sets `AssetsMaximum` (in the vault's asset units — drops for XRP, whole tokens otherwise):

```ts
// action-service.ts:132-139
case "set-vault":
  return {
    TransactionType: "VaultSet",
    Account: account,
    VaultID: session.env.objects.vaultId!,
    ...(p.assetsMaximum ? { AssetsMaximum: brokerValue(session, p.assetsMaximum) } : {}),
  };
```

We never send `Data` or `DomainID` through `VaultSet`; domain membership is instead managed through `PermissionedDomainSet` (see [xls80-permissioned-domains.md](../02-protocol/xls80-permissioned-domains.md)). The ledger rejects lowering `AssetsMaximum` below current `AssetsTotal` unless the new value is `0` — this is documented directly on the field in the installed model (`vaultSet.ts:33-36`) and is observed on Devnet as `tecLIMIT_EXCEEDED` (see [result-codes.md](../07-reference/result-codes.md)).

### VaultDelete

Teardown deletes the vault only after the broker attached to it is already deleted, in explicit dependency order (broker → vault → domain → credentials):

```ts
// teardown.ts:44-47
if (env.objects.vaultId) {
  await tryDelete(log, "vault", () =>
    submit(client, owner, { TransactionType: "VaultDelete", Account: owner.address, VaultID: env.objects.vaultId! }, ctx("vault")),
  );
}
```

Negative-suite case N7 proves the ordering matters: deleting a vault while its broker is still attached is rejected `tecHAS_OBLIGATIONS` (`lending.ts:21-35`) — the broker is an outstanding obligation on the vault.

### VaultClawback (adversarial only)

`VaultClawback` is the issuer's power to force-withdraw an IOU holder's vault position, sending the underlying asset to the issuer. Per the installed model's own doc comment: "Conceptually, the transaction performs `VaultWithdraw` on behalf of the Holder... In case there are insufficient funds for the entire `Amount` the transaction will perform a partial Clawback, up to the `Vault.AssetsAvailable`" (`vaultClawback.ts:14-20`). XRP has no clawback power, so negative-suite case N8 gates this case to IOU vaults only (`appliesTo: (env) => env.asset.issuer !== undefined`, `lending.ts:47`) and fires it against a non-member stranger, expecting rejection from the `tecNO_AUTH` family (`lending.ts:41-60`). This is the only place `VaultClawback` appears in the codebase — it is never part of provisioning or a normal engine action.

## The Vault ledger object

Read via `account_objects` filtered `type:"vault"` against the vault owner's account — `findVault` for provisioning idempotency (`ledger-lookups.ts:17-22`), `readSessionState`/`firstObject` for live session state (`state-service.ts:46,107-109`), and `readBalances` for the share MPT id (`balances-service.ts:25,33`).

| Field | Meaning | Read where |
|---|---|---|
| `ShareMPTID` | Id of the share MPTokenIssuance object — captured once and pinned into `env.objects.shareMptId` for the rest of the session. | `steps.ts:196`; `ledger-lookups.ts:21` |
| `AssetsTotal` | Total value of the vault (assets deposited, including any lent out). | `state-service.ts:95` (`assetValue(vault.AssetsTotal)`) |
| `AssetsAvailable` | Asset amount currently available in the vault (not out on loan). | `state-service.ts:95` |
| `AssetsMaximum` | Configured cap on `AssetsTotal`; `0` means uncapped. Mutated via `VaultSet`. | set via `action-service.ts:138`; not separately read back by this codebase's state/balances services |
| `Scale` | Power-of-10 scaling factor for converting the asset value into integer vault shares. | not read directly by `state-service.ts`/`balances-service.ts` in this codebase, but is the field that determines the share math below (`ingester/src/state.ts:47` reads it for the ingester's own scaled projection) |
| `LossUnrealized` | Potential loss not yet realized, expressed in the vault's asset. | `ingester/src/state.ts:52`; not read by the engine's own state service |
| `Owner` | The vault's owner account. Asserted equal to the attached broker's `Owner` (single-owner invariant). | `assertions.ts:13-26` |
| `WithdrawalPolicy` | The withdrawal strategy in force — always `1` (first-come-first-serve) in this system, set at creation. | set at `steps.ts:190`, not re-read |

The complete field set on the installed model (`node_modules/xrpl/src/models/ledger/Vault.ts:11-89`) also includes `LedgerIndex`, `Flags`, `Sequence`, `OwnerNode`, `Account` (the vault's pseudo-account address), `Asset`, and `Data` — this codebase does not read any of those beyond what is tabled above. `VaultFlags.lsfVaultPrivate = 0x00010000` is the ledger-side flag corresponding to the `tfVaultPrivate` transaction flag (`Vault.ts:91-96`); we do not check it directly (permissioned/public is tracked in our own `env.objects.domainId`, per `isPermissioned`, `types.ts:50-52`).

## MPToken shares — share accounting

Vault ownership is represented as a Multi-Purpose Token (MPT): each vault has exactly one share `MPTokenIssuance`, whose id is the vault's `ShareMPTID`. This section states the share-conversion formula as fact — it is CONFIRMED against the XLS-65 spec text (see `.docsource/XLS-VERIFICATION.md` item #4) and matches this system's own observed data.

### The Scale field and the conversion formula

Per XLS-65, the vault's `Scale` field is "the power of 10 to multiply asset value by when converting to integer shares." Defaults and bounds:

- IOU vault: `Scale` defaults to `6`, configurable `0`–`18`.
- XRP vault: `Scale = 0` — an XRP vault's shares are 1:1 with drops-equivalent.
- MPT vault: `Scale = 0`.

This matches the installed model directly: `Vault.Scale?: number` is documented "Only applicable for IOU assets. Valid values are between 0 and 18 inclusive. For XRP and MPT, this is always 0." (`Vault.ts:84-88`); `MAX_SCALE = 18` is enforced in the same package's `VaultCreate` validator (`vaultCreate.js:8`).

The conversion is two-part:

1. **First deposit into an empty vault:** `Δshares = Δassets × 10^Scale` (i.e. `× σ` where `σ = 10^Scale`).
2. **Every subsequent deposit is proportional to the vault's existing share/asset ratio, not a flat multiple:** `Δshares = (Δassets × Γshares) / Γassets`, rounded down — where `Γshares`/`Γassets` are the vault's share supply and asset total immediately before the deposit.

> [!NOTE]
> The share MPT's own `MPTokenIssuance.AssetScale` is set to the vault's `Scale` for an IOU vault, and `0` otherwise — this is the same scaling factor surfaced on the token issuance itself, not a separate parameter.

Our own observed evidence is consistent with a Scale=6 first deposit: a 30,000-unit IOU deposit into an empty vault produced 30,000,000,000 shares — exactly `30,000 × 10^6`.

### Reading share balances

A depositor's share balance is not a field on the `Vault` object itself — it is the depositor's own `MPToken` object, matched by issuance id:

```ts
// balances-service.ts:64-75
async function readShares(session: Session, holder: string, shareMptId: string): Promise<string> {
  try {
    const res = await session.client.request({ command: "account_objects", account: holder, type: "mptoken", ledger_index: "validated" });
    const objs = res.result.account_objects as unknown as Record<string, unknown>[];
    const share = objs.find((o) => o.MPTokenIssuanceID === shareMptId);
    return String((share?.MPTAmount as string | undefined) ?? "0");
  } catch (err) {
    if (isAccountNotFound(err)) return "0";
    throw err;
  }
}
```

This is invoked once per seat inside `readBalances` (`balances-service.ts:22-39`), which composes it with an XRP read (`account_info`) and, for an IOU vault, a trust-line read (`account_lines`) to give the front end one balance snapshot per account. An account with no share MPT object (or that does not exist on-ledger yet) reads as `"0"` rather than throwing (`balances-service.ts:71-73,77-80`) — the same not-found-tolerant pattern used throughout this read path.

The vault's total shares outstanding is not on the `Vault` object either — it is the `OutstandingAmount` field on the share `MPTokenIssuance`, fetched by `ledger_entry` with `mpt_issuance: shareMptId`:

```ts
// ingester/src/state.ts:61-66
async function shareOutstanding(client: Client, shareMptId: string | undefined): Promise<bigint> {
  if (!shareMptId) return 0n;
  const res = await client.request({ command: "ledger_entry", mpt_issuance: shareMptId, ledger_index: "validated" });
  const node = res.result.node as unknown as Record<string, unknown> | undefined;
  return BigInt(String(node?.OutstandingAmount ?? "0"));
}
```

The installed `xrpl@5.0.0` `MPTokenIssuance` ledger-entry model confirms both fields exist exactly as used: `AssetScale?: number` and `OutstandingAmount: string` (`node_modules/xrpl/src/models/ledger/MPTokenIssuance.ts:3-14`).

### Summary table — share math

| Quantity | Formula / source | Where read/computed |
|---|---|---|
| First deposit into empty vault | `Δshares = Δassets × 10^Scale` | XLS-65 spec; `.docsource/XLS-VERIFICATION.md` #4 |
| Subsequent deposit | `Δshares = (Δassets × Γshares) / Γassets`, rounded down | XLS-65 spec; `.docsource/XLS-VERIFICATION.md` #4 |
| Vault `Scale` default | `6` for IOU (0–18 configurable); `0` for XRP; `0` for MPT | `Vault.ts:84-88` (installed `xrpl@5.0.0` model) |
| Share `MPTokenIssuance.AssetScale` | = vault `Scale` for IOU; `0` otherwise | XLS-65 spec |
| Holder's share balance | `MPToken` object, `MPTokenIssuanceID === shareMptId`, value = `MPTAmount` | `balances-service.ts:65-70` |
| Total shares outstanding | `OutstandingAmount` on the share `MPTokenIssuance`, via `ledger_entry mpt_issuance` | `ingester/src/state.ts:61-66` |
| Observed evidence | 30,000 IOU deposited → 30,000,000,000 shares (`×10^6`, consistent with Scale=6 first deposit) | system-writeup §8, per `.docsource/XLS-VERIFICATION.md` #4 |

## Related pages

- [Transaction Map](../07-reference/transaction-map.md) — every action verb and transaction type this system submits, cross-referenced by amendment.
- [Result Codes](../07-reference/result-codes.md) — `tec*`/`tem*`/HTTP status behavior observed for vault actions, including `tecLIMIT_EXCEEDED` (AssetsMaximum), `tecINSUFFICIENT_FUNDS` (overdraw), and `tecHAS_OBLIGATIONS` (VaultDelete with an attached broker).
- [Glossary](../01-overview/glossary.md) — see "Vault share (MPToken)" and "Permissioned vault vs. public vault".
