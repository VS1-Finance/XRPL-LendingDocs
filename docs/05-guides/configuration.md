---
label: Configuration
order: 80
---

# Configuration Reference

A run of the harness — bootstrap provisioning, or an engine session — is driven by one JSON object
validated against `ConfigSchema` (`packages/shared/src/config/schema.ts:32-118`). The schema is a
Zod object with `.strict()` (`schema.ts:107`): **any key not listed below is rejected** at load
time, not silently ignored. Loading goes through `loadConfig`/`validateConfig`
(`packages/shared/src/config/load.ts:14-40,16-20`), which throws a `ConfigError` with one line per
failed field rather than a raw Zod dump (`load.ts:43-49`).

This page documents every field on `Config` (`schema.ts:118`) — name, type, default, constraint,
and meaning — plus the asset union (`packages/shared/src/config/asset.ts`) and the worked example
shipped at `packages/bootstrap/config.example.json`.

> [!NOTE]
> This is the config for **bootstrap** (a standalone provisioning run) and the engine's *base*
> config. An engine session created via `POST /sessions` overrides a handful of these fields
> per-request through `ProvisionBody` — see [Session Routes](../04-api/sessions.md) — but every
> session still starts from one `Config` loaded this way.

## Field table

| Field | Type | Default | Constraint | Source |
|---|---|---|---|---|
| `seed` | `string` | — (required) | min 16 characters | `schema.ts:36` |
| `network` | `"devnet" \| "wasm-devnet"` | — (required) | enum | `schema.ts:5-6,38` |
| `setupId` | `string?` | generated if omitted | 1–64 characters | `schema.ts:42` |
| `asset` | `XrpAssetSchema \| IouAssetSchema` | — (required) | see [Asset](#asset) | `asset.ts:20-38`, `schema.ts:44` |
| `withdrawalPolicy` | `"first-come-first-serve"` | `"first-come-first-serve"` | enum (single value) | `schema.ts:11,46` |
| `domain` | `{ acceptedCredentials: AcceptedCredential[] }?` | omitted (public vault) | array 1–10 | `schema.ts:51-59` |
| `domain.acceptedCredentials[].issuer` | `string?` | — | classic r-address; informational only | `schema.ts:20-23` |
| `domain.acceptedCredentials[].credentialType` | `string` | — | 1–64 characters | `schema.ts:24` |
| `coverRateMinimum` | `number` (scaled rate) | — (required) | non-negative integer | `schema.ts:30,61` |
| `coverRateLiquidation` | `number` (scaled rate) | — (required) | non-negative integer; ≤ `coverRateMinimum` | `schema.ts:30,62,108-115` |
| `managementFeeRate` | `number` (scaled rate) | — (required) | non-negative integer | `schema.ts:30,63` |
| `coverAmount` | `string` (decimal) | — (required) | matches `^\d+(\.\d+)?$` | `schema.ts:67` |
| `debtMaximum` | `string` (decimal) | — (required) | matches `^\d+(\.\d+)?$` | `schema.ts:70` |
| `pool.depositors` | `number` | — (required) | integer ≥ 1 | `schema.ts:73` |
| `pool.borrowers` | `number` | — (required) | integer ≥ 1 | `schema.ts:74` |
| `fundingXrpPerAccount` | `number` | `30` | positive integer | `schema.ts:80` |
| `bots.seed` | `string` | `"bots"` | min 1 character | `schema.ts:87` |
| `bots.borrowerWeights.onTime` | `number` | `1` | non-negative | `schema.ts:90` |
| `bots.borrowerWeights.late` | `number` | `0` | non-negative | `schema.ts:91` |
| `bots.borrowerWeights.early` | `number` | `0` | non-negative | `schema.ts:92` |
| `bots.borrowerWeights.overpay` | `number` | `0` | non-negative | `schema.ts:93` |
| `bots.borrowerWeights.default` | `number` | `0` | non-negative | `schema.ts:94` |
| `bots.depositorWeights.hold` | `number` | `1` | non-negative | `schema.ts:99` |
| `bots.depositorWeights.churn` | `number` | `0` | non-negative | `schema.ts:100` |
| `bots.depositorWeights.topUp` | `number` | `0` | non-negative | `schema.ts:101` |

`bots` itself defaults to `{}` (`schema.ts:105`), and its two weight objects each default to `{}`
(`schema.ts:96,103`) — a config can omit `bots` entirely and still get the defaults above at every
level.

## seed, network, setupId

```ts
// schema.ts:34-42
seed: z.string().min(16, "seed must be at least 16 characters of entropy"),
network: NetworkSchema,
setupId: z.string().min(1).max(64).optional(),
```

- **`seed`** — entropy for deterministic account derivation (see
  [Account Derivation](../03-architecture/account-derivation.md)). The same seed reproduces the
  same accounts on a re-run instead of leaking fresh ones (`schema.ts:34-35`).
- **`network`** — one of `devnet` or `wasm-devnet` (`NetworkSchema`, `schema.ts:5-6`). These are the
  only two networks the harness knows how to reach; both carry the full vault + lending amendment
  stack (`schema.ts:4`).
- **`setupId`** — identifies a provisioned environment end to end: stamped on every transaction and
  used as the key for idempotent re-runs and scoped teardown. Generated if omitted (`schema.ts:40-42`).

## asset

```ts
// asset.ts:20-38
export const XrpAssetSchema = z.object({
  currency: z.literal("XRP"),
});

export const IouAssetSchema = z.object({
  currency: Currency.refine((c) => c !== "XRP", "IOU currency cannot be XRP"),
  issuer: ClassicAddress,
});

export const AssetConfigSchema = z.union([
  XrpAssetSchema,
  z.object({
    currency: Currency.refine((c) => c !== "XRP", "IOU currency cannot be XRP"),
    issuer: ClassicAddress.optional(),
  }),
]);
```

`asset` is a discriminated union on `currency` (`asset.ts:32-38`):

| Shape | `currency` | `issuer` | Meaning |
|---|---|---|---|
| XRP | literal `"XRP"` | not present | Native XRP vault. |
| IOU | 3-char code, or 40-char hex, not `"XRP"` | classic r-address, **optional** | Issued-currency vault. |

- **Currency format** — `"XRP"`, a 3-character code matching
  `[A-Za-z0-9?!@#$%^&*<>(){}[\]|]{3}`, or a 40-character hex code, per xrpl.js conventions
  (`asset.ts:10-14`).
- **IOU `issuer` is optional in config**: when omitted, the harness stands up its own issuer account
  and fills `issuer` in at provision time from the derived issuer account (`asset.ts:29-31`).
- **`isXrpAsset(a)`** — the type guard the rest of the codebase branches on: `a.currency === "XRP"`
  (`asset.ts:42-44`). Wherever the codebase forks XRP vs. IOU behavior (funding, trust lines,
  issuer-flag steps), it dispatches on this switch.

> [!NOTE]
> The default asset shape in the codebase's own comments is an issued currency, "because issuer
> powers (clawback, freeze) only exist on an issued asset — they cannot be exercised on an XRP
> vault, which has no issuer" (`asset.ts:5-6`). This is a design note in the source, not a schema
> default — `asset` itself has no default and must be supplied.

## withdrawalPolicy

```ts
// schema.ts:8-12
export const WithdrawalPolicySchema = z.enum(["first-come-first-serve"]);
```

Defaults to `"first-come-first-serve"` (`schema.ts:46`). This is currently the **only** value the
enum accepts — the comment in source is explicit that only one withdrawal policy is exposed by the
current ledger build, and the enum is kept single-valued so additional policies can slot in later
without a config break (`schema.ts:8-10`).

## domain (permissioned vs. public)

```ts
// schema.ts:51-59
domain: z
  .object({
    acceptedCredentials: z
      .array(AcceptedCredentialSchema)
      .min(1, "a domain needs at least one accepted credential")
      .max(10, "a domain accepts at most 10 credentials"),
  })
  .optional(),
```

`domain` is optional and gates the whole permissioning branch:

- **Present** → the vault is permissioned: a `PermissionedDomain` gates access, and only holders of
  an accepted credential may deposit or borrow — the `tecNO_AUTH` enforcement story
  (`schema.ts:48-49`).
- **Omitted** → the vault is public: anyone may deposit without a credential, and no domain or
  credentials are provisioned (`schema.ts:49-50`).

`acceptedCredentials` is an array of 1 to 10 entries (`schema.ts:56-57`). The 1–10 bound matches the
ledger's own `PermissionedDomainSet` constraint ("a list of 1 to 10 Accepted Credentials objects"),
confirmed against xrpl.org's `PermissionedDomainSet` reference.

Each entry (`AcceptedCredentialSchema`, `schema.ts:16-25`):

```ts
// schema.ts:16-25
const AcceptedCredentialSchema = z.object({
  issuer: z
    .string()
    .regex(/^r[1-9A-HJ-NP-Za-km-z]{24,34}$/, "must be a classic r-address")
    .optional(),
  credentialType: z.string().min(1).max(64),
});
```

| Field | Type | Constraint | Meaning |
|---|---|---|---|
| `issuer` | `string?` | classic r-address | See warning below. |
| `credentialType` | `string` | 1–64 characters | Readable ASCII in config; hex-encoded for the ledger at provision time (`schema.ts:14-15`). |

> [!WARNING]
> `acceptedCredentials[].issuer` is **optional and currently informational — not yet honored** by
> provisioning. The harness always issues credentials from its own derived credential-issuer
> account (a separate account from the currency issuer), so a configured `issuer` here has no
> effect on which account actually issues the credential at provision time (`schema.ts:17-19`). It
> is kept in the schema for forward compatibility. Do not rely on it to point provisioning at an
> external issuer today.

## coverRateMinimum, coverRateLiquidation, managementFeeRate

```ts
// schema.ts:27-30,61-63
const ScaledRate = z.number().int().nonnegative();

coverRateMinimum: ScaledRate,
coverRateLiquidation: ScaledRate,
managementFeeRate: ScaledRate,
```

All three are scaled integers on the ledger: a rate of `100000` reads as 100% (`schema.ts:27-28`).
Each is validated here only as a non-negative integer — semantic bounds are enforced at provision
time against live broker fields, not at config-parse time (`schema.ts:28-29`).

The schema's `superRefine` adds one cross-field constraint (`schema.ts:108-115`):

```ts
// schema.ts:108-115
.superRefine((cfg, ctx) => {
  if (cfg.coverRateLiquidation > cfg.coverRateMinimum) {
    ctx.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["coverRateLiquidation"],
      message: "coverRateLiquidation cannot exceed coverRateMinimum",
    });
  }
});
```

`coverRateLiquidation` must be ≤ `coverRateMinimum`, or the whole config fails validation with that
message attached to the `coverRateLiquidation` path.

## coverAmount, debtMaximum

```ts
// schema.ts:67,70
coverAmount: z.string().regex(/^\d+(\.\d+)?$/, "coverAmount must be a positive decimal string"),
debtMaximum: z.string().regex(/^\d+(\.\d+)?$/, "debtMaximum must be a positive decimal string"),
```

Both are decimal strings (not numbers), in whole asset units:

- **`coverAmount`** — first-loss capital seeded into the broker. Must clear the minimum cover
  requirement; checked on-ledger after the broker exists (`schema.ts:65-66`).
- **`debtMaximum`** — maximum aggregate debt the broker may originate (`schema.ts:69`).

The regex `^\d+(\.\d+)?$` accepts a non-negative integer or decimal, with no sign and no exponent
notation — it does not itself reject `"0"`, despite the error messages saying "positive."

## pool

```ts
// schema.ts:72-75
pool: z.object({
  depositors: z.number().int().min(1),
  borrowers: z.number().int().min(1),
}),
```

Both `depositors` and `borrowers` are required integers, each with a floor of 1 — a pool must have
at least one of each role.

## fundingXrpPerAccount

```ts
// schema.ts:76-80
// Legacy flat per-account funding amount. Funding is now sized per role from the live reserve rates
// (see shared/reserves.ts), so this is only a fallback for the fan-out and no longer the primary
// driver. Kept for config compatibility.
fundingXrpPerAccount: z.number().int().positive().default(30),
```

Positive integer, defaults to `30`.

> [!NOTE]
> **Legacy field.** Per the source comment, funding is now sized per role from live reserve rates
> (base reserve + owner-reserve increment × the role's expected object count, read from
> `server_state` at provisioning time) rather than this flat amount. `fundingXrpPerAccount` remains
> only as a fallback for the funding fan-out and is kept for config compatibility, not as the
> primary funding driver. See [Per-Role Reserve Funding](../03-architecture/reserve-funding.md) for
> the mechanism that supersedes it.

## bots

```ts
// schema.ts:82-105
bots: z
  .object({
    seed: z.string().min(1).default("bots"),
    borrowerWeights: z
      .object({
        onTime: z.number().nonnegative().default(1),
        late: z.number().nonnegative().default(0),
        early: z.number().nonnegative().default(0),
        overpay: z.number().nonnegative().default(0),
        default: z.number().nonnegative().default(0),
      })
      .default({}),
    depositorWeights: z
      .object({
        hold: z.number().nonnegative().default(1),
        churn: z.number().nonnegative().default(0),
        topUp: z.number().nonnegative().default(0),
      })
      .default({}),
  })
  .default({}),
```

`bots` configures the optional bot-driven traffic generator. The whole block is optional — a run
without it uses built-in defaults at every level (`schema.ts:82-83`).

| Field | Default | Meaning |
|---|---|---|
| `seed` | `"bots"` | Makes a bot run reproducible — the same seed drives the same sequence of variant assignments and timings. |
| `borrowerWeights.{onTime,late,early,overpay,default}` | `1,0,0,0,0` | Relative weights biasing how borrower bot variants (on-time repayer, late payer, early payer, overpayer, defaulter) are spread across the borrower pool. |
| `depositorWeights.{hold,churn,topUp}` | `1,0,0` | Relative weights for depositor bot variants (deposit-and-hold, deposit/withdraw cycle, top-up). |

Weights are relative and need not sum to one (`schema.ts:83-84`). See
[Bot Framework](../03-architecture/bot-framework.md) for what each named variant actually does.

## .strict() and unknown keys

`ConfigSchema` is built with `.strict()` (`schema.ts:107`), placed after the object body and before
the `superRefine`. Any key in a config file that is not one of the fields above — a typo, a
leftover field from an older config shape, an engine-only field like `label` mistakenly placed in a
bootstrap config — fails validation. There is no lenient/pass-through mode.

## Worked example

`packages/bootstrap/config.example.json`, verbatim:

```json
{
  "seed": "example-deterministic-seed-change-me",
  "network": "devnet",
  "asset": {
    "currency": "524C555344000000000000000000000000000000"
  },
  "withdrawalPolicy": "first-come-first-serve",
  "domain": {
    "acceptedCredentials": [{ "credentialType": "LENDPARTY" }]
  },
  "coverRateMinimum": 100000,
  "coverRateLiquidation": 100000,
  "managementFeeRate": 0,
  "coverAmount": "20000",
  "debtMaximum": "100000",
  "pool": {
    "depositors": 2,
    "borrowers": 2
  },
  "fundingXrpPerAccount": 30,
  "bots": {
    "seed": "bots-demo",
    "borrowerWeights": { "onTime": 5, "late": 1, "early": 1, "overpay": 1, "default": 2 },
    "depositorWeights": { "hold": 3, "churn": 1, "topUp": 1 }
  }
}
```

Notes on this example:

- `asset.currency` is a 40-character hex code with no `issuer` — an IOU vault where the harness
  provisions its own issuer.
- `domain.acceptedCredentials` has exactly one entry with only `credentialType` set (no `issuer`) —
  the permissioned branch, using the informational-only `issuer` field left unset.
- `coverRateMinimum` and `coverRateLiquidation` are both `100000` (100%) — equal, which satisfies
  the `liquidation ≤ minimum` constraint at the boundary.
- `managementFeeRate` is `0`.
- `fundingXrpPerAccount` is present at its default (`30`) even though it is superseded by per-role
  reserve funding for the actual amounts moved — see the note above.
