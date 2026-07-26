---
label: Reserve Funding
order: 50
---

# Per-Role Reserve Funding

## The problem

Every XRPL account must hold XRP it cannot spend: a base account reserve, plus an incremental
reserve for each object it owns on ledger (trust lines, credentials, the vault, the broker, a loan,
an MPToken). That XRP is locked, not consumed — but an account that falls short of what its
eventual object set requires will have a transaction rejected with an insufficient-reserve result
the moment it tries to create one more object.

A provisioning run could sidestep this by over-funding every account with a large flat amount, but
that wastes XRP across a pool and makes the resulting accounts illegible to a reviewer — inspecting
a funded account's balance no longer tells you anything about what it is supposed to hold. This
system instead computes, per role, the minimum XRP that role needs to carry its own reserve
(`packages/shared/src/reserves.ts:4-9`) and funds exactly that (plus a small fee headroom), so a
reviewer can read an account's balance as a legible statement of its reserve floor.

## Reading live reserve rates

The base reserve and owner-reserve increment are network parameters, not constants baked into this
codebase — they are read from the connected server at provisioning time:

```ts
// reserves.ts:18-25
export async function readReserveRates(client: Client): Promise<ReserveRates> {
  const res = await client.request({ command: "server_state" });
  const ledger = res.result.state.validated_ledger;
  if (!ledger || ledger.reserve_base === undefined || ledger.reserve_inc === undefined) {
    throw new Error("server_state did not report reserve_base/reserve_inc");
  }
  return { baseDrops: Number(ledger.reserve_base), incDrops: Number(ledger.reserve_inc) };
}
```

`ReserveRates` is `{ baseDrops: number; incDrops: number }` (`reserves.ts:13-16`).

This deliberately calls `server_state`, not `server_info`. `server_info` reports reserve figures as
XRP floats; `server_state`'s `validated_ledger.reserve_base`/`reserve_inc` are reported in integer
drops (`reserves.ts:11-12,18-24`). Every downstream computation in this module stays in integer
drops for the same reason: funding sums many per-account amounts across a pool, and rounding to XRP
first would let floating-point error accumulate into a total the ledger's own drops conversion then
rejects (`reserves.ts:81-83`).

## The per-role object count

The reserve an account needs is driven by the ledger's `OwnerCount` for that account — not simply
the number of `account_objects` a reviewer sees, because some object types reserve more than one
owner-count unit. `peakObjectCount` returns this per-role peak, calibrated against measured devnet
`OwnerCount` values (`reserves.ts:40-73`):

```ts
// reserves.ts:51-73
function peakObjectCount(role: Role, shape: VaultShape): number {
  const cred = shape.permissioned ? 1 : 0;
  const trustLine = shape.isXrp ? 0 : 1;
  switch (role) {
    case "issuer":
      return 0;
    case "credentialIssuer":
      return shape.permissioned ? shape.credentialedMembers : 0;
    case "owner":
      return 5 + (shape.permissioned ? 1 : 0) + trustLine;
    case "depositor":
      return cred + trustLine + 1;
    case "borrower":
      return cred + trustLine + 2;
  }
}
```

| Role | Peak owner-count units | Reasoning (`reserves.ts`) |
|---|---|---|
| `issuer` | `0` | Owns no vault objects; the issuer side of a default-ripple trust line is not reserved by the issuer (`:43-44`). |
| `credentialIssuer` | `credentialedMembers` (permissioned only, else `0`) | Transient peak — see below (`:57-61`). |
| `owner` | `5 + domain(0/1) + trustLine(0/1)` | Vault + its share MPTokenIssuance + owner's own MPToken + broker + broker's cover = 5 base units, plus the domain object (permissioned) and a trust line (IOU). Matches a measured `OwnerCount` of 7 for an IOU permissioned vault (`:46-48,62-65`). |
| `depositor` | `cred(0/1) + trustLine(0/1) + 1` | Credential (permissioned) + trust line (IOU) + the share MPToken received after depositing (`:49,66-68`). |
| `borrower` | `cred(0/1) + trustLine(0/1) + 2` | Credential (permissioned) + trust line (IOU) + the loan object, which reserves two units (`:50,69-71`). |

### Why the credential issuer is funded for the full member count

`credentialIssuer`'s peak is not `0` and not `1` — it is `credentialedMembers`, the total number of
depositors plus borrowers being credentialed. The batcher submits every `CredentialCreate`
transaction before any `CredentialAccept` (per the transaction-batching model), so between those two
phases the issuer transiently holds a pending-credential reserve for *every* member awaiting
acceptance, not just one. Each `CredentialAccept` moves that member's reserve from the issuer to the
subject, but until every member has accepted, the issuer's own reserve must cover the whole
outstanding set (`reserves.ts:34-36,57-61`).

> [!NOTE]
> This is a transient peak, not a steady-state holding: once every credentialed member accepts,
> the issuer's actual `OwnerCount` returns toward zero. The issuer is funded for the peak because
> that is the moment its reserve requirement is highest, not because it holds that many objects
> indefinitely.

### VaultShape — the inputs that change the counts

```ts
// reserves.ts:28-38
export interface VaultShape {
  isXrp: boolean;
  permissioned: boolean;
  credentialedMembers: number;
}
```

- `isXrp` — native XRP vaults carry no trust lines (`trustLine = 0`); an issued-token (IOU) vault
  gives every holder and the owner a trust line (`trustLine = 1`) (`reserves.ts:29-30,53`).
- `permissioned` — a permissioned vault gates access with a domain and per-holder credentials
  (`cred = 1`); a public vault has neither (`cred = 0`) (`reserves.ts:31-32,52`).
- `credentialedMembers` — the count of depositors + borrowers who receive a credential; `0` when
  the vault is not permissioned (`reserves.ts:33-37`). Set at the call site to
  `config.pool.depositors + config.pool.borrowers` when `config.domain` is present, else `0`
  (`provision.ts:157`).

## roleReserveDrops — the funding floor

```ts
// reserves.ts:84-86
export function roleReserveDrops(role: Role, shape: VaultShape, rates: ReserveRates): number {
  return rates.baseDrops + rates.incDrops * peakObjectCount(role, shape) + FEE_HEADROOM_DROPS;
}
```

`FEE_HEADROOM_DROPS = 2_000_000` (2 XRP) is added on top of the reserve so every account can pay its
own transaction fees without needing a top-up mid-run — a handful of transactions at roughly 10
drops each is negligible next to a flat 2 XRP margin (`reserves.ts:75-77`).

This is the **reserve floor only**. A caller adds any liquidity the role must additionally hold on
top of it — for example, an XRP-vault depositor is funded for this floor plus the amount it intends
to deposit, since an XRP vault has no minting step to supply that liquidity separately
(`reserves.ts:79-83`). The call site, `fundingPlan` in `provision.ts`, builds exactly this
role-shape-and-liquidity function:

```ts
// provision.ts:153-172 (relevant excerpt)
function fundingPlan(config: Config, rates: ReserveRates): (account: DerivedAccount) => number {
  const shape: VaultShape = {
    isXrp: isXrpAsset(config.asset),
    permissioned: config.domain !== undefined,
    credentialedMembers: config.domain ? config.pool.depositors + config.pool.borrowers : 0,
  };
  const liquidityDrops = (value: string) => Number(decimalToScaled(value, 6));
  return (account) => {
    const reserve = roleReserveDrops(account.role, shape, rates);
    if (!shape.isXrp) return reserve; // IOU liquidity is minted, not funded
    switch (account.role) {
      case "owner":
        return reserve + liquidityDrops(coverAndLiquidity(config));
      case "depositor":
      case "borrower":
        return reserve + liquidityDrops(liquidityPerHolder(config));
      default:
        return reserve; // issuer and credential issuer own no liquidity in an XRP session
    }
  };
}
```

For an IOU vault, `roleReserveDrops` alone is every account's funding target — liquidity arrives
later via issuer distribution, not the initial XRP fan-out (`provision.ts:162`).

> [!NOTE]
> `config/schema.ts`'s `fundingXrpPerAccount` field (default `30` XRP) is a legacy flat-funding
> knob, superseded by this per-role computation — see `.docsource/code-map.md` STALE-docs item 3.

## The treasury fan-out

Funding an entire pool from the public faucet one account at a time would be slow and rate-limited,
so this system faucets a single treasury account sized to the whole pool's total need, then pays
each derived account its computed target from that treasury in batched transactions.

**Sizing and funding the treasury** — `fundTreasuryForTargets` (`funding.ts:80-114`) faucets a
fresh wallet (`fundTreasury`, `funding.ts:68-75`), then repeatedly tops it up from the faucet (the
faucet grants a fixed amount per call) until its balance clears the pool's total drops plus a
20,000,000-drop headroom (`funding.ts:86-87`), bounded by a `maxGrants` safety ceiling so a stuck
faucet cannot loop forever (`funding.ts:92-96`). If the ceiling is hit before the treasury reaches
the required total, it throws rather than proceeding under-funded (`funding.ts:107-112`).

**Paying out to each account** — `fanOutFunding` (`funding.ts:27-64`) takes the treasury and the
full list of derived accounts, and for each one:

1. Reads the account's current on-ledger balance (`accountBalanceDrops`, treating a not-yet-funded
   account as zero — `funding.ts:116-124`).
2. If the balance already meets the target, skips it — logged as already-funded
   (`funding.ts:40-42`).
3. Otherwise queues a `Payment` from the treasury for exactly the shortfall (`funding.ts:44,49-51`).

All shortfall payments are submitted as one batch via `submitBatch`, wrapped in retry for transient
faucet/network failures (`funding.ts:54-57`; retry classification at `funding.ts:133-147`). This
makes a re-run of provisioning idempotent for funding: an account that already holds its target
balance from a prior run is left untouched, and only the gap is paid on a repeat run
(`funding.ts:25-26`).

## Summary

| Step | Function | Source |
|---|---|---|
| Read live reserve rates (integer drops) | `readReserveRates` | `reserves.ts:18-25` |
| Compute per-role peak object count | `peakObjectCount` | `reserves.ts:51-73` |
| Compute per-role reserve floor | `roleReserveDrops` | `reserves.ts:84-86` |
| Size and faucet the treasury | `fundTreasuryForTargets` | `funding.ts:80-114` |
| Pay each account its target (idempotent) | `fanOutFunding` | `funding.ts:27-64` |

Related: [Transaction Batching](./transaction-batching.md) for how the funding payments and the
credential-create/accept phases are batched per ledger, and
[Provisioning Sequence](./provisioning-sequence.md) for where the funding fan-out sits in the full
provisioning order.
