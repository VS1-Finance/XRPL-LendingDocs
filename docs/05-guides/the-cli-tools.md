---
label: CLI Tools
order: 50
---

# The CLI Tools

The reference implementation ships four runnable command-line tools, one per package, invoked as
root workspace scripts (`lending-reference/package.json:11-20`):

```json
"scripts": {
  "bootstrap": "tsx packages/bootstrap/src/cli.ts",
  "lifecycle": "tsx packages/lifecycle/src/cli.ts",
  "ingester": "tsx packages/ingester/src/cli.ts",
  "negatives": "tsx packages/negative-suite/src/cli.ts"
}
```
(`package.json:13-16`)

Each package also declares the same entry point as its own `bin`, e.g.
`"bootstrap": "./src/cli.ts"` (`packages/bootstrap/package.json:14-16`), and a `start` script that
runs it directly with `tsx` (e.g. `packages/bootstrap/package.json:18`) — so the same tool is
reachable either as `pnpm bootstrap` from the repo root or `pnpm --filter @lending/bootstrap start`
from within the workspace. The commands below use the root form, which is what the root README
documents (`README.md:50-58`).

There is a fifth root script, `pnpm session` (`tsx packages/session/src/cli.ts`,
`package.json:17`), and `pnpm engine` (`tsx packages/engine/src/main.ts`, `package.json:18`) starts
the long-running HTTP service rather than a one-shot CLI — see
[Running the Engine](running-the-engine.md). This page covers the four one-shot tools: bootstrap,
lifecycle, negative-suite, and ingester.

## bootstrap — provision and tear down environments

**Command:** `pnpm bootstrap` (`package.json:13`, runs `packages/bootstrap/src/cli.ts`).

Bootstrap is the foundation every other tool runs against. From a single JSON config it stands up
a fully wired permissioned lending environment, in order: funded accounts, issuer configuration,
trust lines and distribution, issued and accepted credentials, a permissioned domain, a
domain-gated single-asset vault, a loan broker on that vault, and seeded first-loss cover
(`packages/bootstrap/README.md:6-15`). Every transaction is tagged with the run's setup id and a
per-action correlation id, and the resulting object graph is written to `out/<setup-id>.json`
(`packages/bootstrap/README.md:17-18`).

Bootstrap's `cli.ts` recognizes one subcommand, `teardown`; anything else is treated as a
provision run (`packages/bootstrap/src/cli.ts:82`). The full usage string
(`packages/bootstrap/src/cli.ts:5-17`):

```
bootstrap — stand up or tear down a wired lending environment

usage:
  bootstrap --config <path> [--setup-id <id>] [--out-dir <dir>] [--dry-run]
  bootstrap teardown --setup-id <id> [--seed <seed>] [--out-dir <dir>]

options:
  --config    path to a JSON config file
  --setup-id  identifies the environment; generated on provision if omitted
  --seed      derivation seed for teardown (defaults to the config seed if provisioning)
  --out-dir   directory for the provisioned graph (default: out)
  --dry-run   validate config and derive accounts without touching the network
```

Real invocations:

```sh
# provision from config
pnpm bootstrap --config ./packages/bootstrap/config.example.json

# validate config and derive accounts without touching the network
pnpm bootstrap --config ./packages/bootstrap/config.example.json --dry-run

# tear an environment down (objects + stored graph)
pnpm bootstrap teardown --setup-id <id> --config ./packages/bootstrap/config.example.json
```
(`packages/bootstrap/README.md:22-31`, matching `README.md:52-58` at the repo root)

`--dry-run` short-circuits before any network call and only prints the resolved network and setup
id (`packages/bootstrap/src/cli.ts:51-54`). A real provision run prints the domain, vault, and
broker object ids on success (`packages/bootstrap/src/cli.ts:57-60`). Teardown requires `--seed`
either directly or via `--config`, from which the config's own `seed` field is read
(`packages/bootstrap/src/cli.ts:66-70`).

Account derivation is a pure function of `(seed, role, index)`, so re-running provision against a
partially provisioned environment reuses the same addresses and completes only the missing steps
rather than duplicating objects (`packages/bootstrap/README.md:34-38`). Two invariants are checked
at run time — the broker and vault report the same owner account, and seeded cover clears the
configured amount — and the run aborts with an error if either fails
(`packages/bootstrap/README.md:40-45`).

## lifecycle — run one loan lifecycle

**Command:** `pnpm lifecycle` (`package.json:14`, runs `packages/lifecycle/src/cli.ts`).

Lifecycle drives one complete loan against an environment that bootstrap has already provisioned,
observable end to end on Devnet: deposit (the depositor supplies liquidity and receives shares),
origination (a bilateral `LoanSet` — owner signs, borrower counter-signs, principal is delivered to
the borrower inside the same transaction), repayment (the borrower pays the scheduled installment
each interval until settled), and close (the loan is removed, automatically on full settlement or
via `LoanDelete` otherwise) (`packages/lifecycle/README.md:6-15`). The vault's total assets are read
before and after so earned yield is observed on-chain, and the step record — tx-hash-backed and
ordered — is written to `out/<setup-id>.lifecycle.json` (`packages/lifecycle/README.md:17-20`).

`cli.ts` recognizes one subcommand, `run` (`packages/lifecycle/src/cli.ts:74`). Usage
(`packages/lifecycle/src/cli.ts:5-18`):

```
lifecycle — run one loan lifecycle against a provisioned environment

usage:
  lifecycle run --provisioned <file> --seed <seed> [options]

options:
  --provisioned <file>   provisioned environment graph emitted by the bootstrap harness
  --seed <seed>          derivation seed for the environment's accounts
  --deposit <amount>     liquidity the depositor supplies      (default: 30000)
  --principal <amount>   loan principal                        (default: 10000)
  --interest <rate>      interest rate, scaled integer         (default: 50000)
  --interval <seconds>   payment interval, at least 60         (default: 60)
  --out-dir <dir>        directory for the run record          (default: out)
```

Real invocations:

```sh
pnpm lifecycle run --provisioned ./out/<setup-id>.json --seed <seed>

# shorter intervals and a smaller loan
pnpm lifecycle run --provisioned ./out/<setup-id>.json --seed <seed> --interval 60 --principal 5000
```
(`packages/lifecycle/README.md:24-29`)

`--seed` must be the seed the environment was provisioned with — wallets are re-derived from it and
checked against the provisioned addresses before the run starts
(`packages/lifecycle/README.md:31-32`). `--interval` is enforced to be at least 60 seconds by the
CLI itself (`packages/lifecycle/src/cli.ts:47`), independent of any protocol minimum. On completion
the CLI prints whether the run reached `repaid` and whether the loan was `closed`, and exits
non-zero if either did not happen (`packages/lifecycle/src/cli.ts:63-65`).

> [!NOTE]
> Repayment-and-close is the built-in terminal branch. The runner exposes a branch seam so an
> alternative terminal behavior can reuse deposit and origination unchanged
> (`packages/lifecycle/README.md:34-38`) — this is a code-level extension point, not a CLI flag.

## negative-suite — adversarial rejection-code assertions

**Command:** `pnpm negatives` (`package.json:16`, runs `packages/negative-suite/src/cli.ts`).

The negative suite runs cases N1–N15, each driving a disallowed or loss-bearing action against a
live environment it provisions itself, and asserting the exact result code the ledger returns — so
a regression that silently changes a rejection code is caught (`packages/negative-suite/README.md:3-8`).
The expected codes are observed on-chain outcomes, not values guessed from prose
(`packages/negative-suite/README.md:7`). For the full N1–N15 catalogue and expected codes, see
[Negative Suite](../06-security/negative-suite.md).

`cli.ts` recognizes one subcommand, `run` (`packages/negative-suite/src/cli.ts:56`). Usage
(`packages/negative-suite/src/cli.ts:5-14`):

```
negatives — run the adversarial negative-test suite against Devnet

usage:
  negatives run --config <file> [--only N1,N7,N15] [--out-dir <dir>]

options:
  --config    a bootstrap config file (the suite provisions its own environments from it)
  --only      comma-separated case ids to run (default: all)
  --out-dir   directory for the results record (default: out)
```

Real invocations:

```sh
pnpm negatives run --config ./packages/bootstrap/config.example.json
pnpm negatives run --config ./packages/bootstrap/config.example.json --only N1,N7,N14
```
(`packages/negative-suite/README.md:36-38`)

The suite provisions its own environments from the given config rather than reusing an existing
`out/<setup-id>.json` — cases that originate a loan each get a dedicated environment, since a broker
holds only one loan at a time, so they don't interfere with each other
(`packages/negative-suite/README.md:41-42`). A run emits a results record to
`out/<setup-id>.negatives.json` and the CLI prints how many cases passed, how many were deferred,
and how many were skipped as not applicable to the vault's mode
(`packages/negative-suite/src/cli.ts:41-45`); it exits non-zero if any asserted case failed
(`packages/negative-suite/src/cli.ts:47`).

## ingester — off-chain history store

**Command:** `pnpm ingester` (`package.json:15`, runs `packages/ingester/src/cli.ts`).

The ingester subscribes to the ledger transaction stream for a session's accounts, captures each
transaction idempotently into Postgres, normalizes it into a typed event, and projects current
derived state — because a ledger reset wipes the chain, this store is the durable record of what
happened (`packages/ingester/README.md:1-5`). For the schema, the operational-vs-history store
split, and why they're deliberately separate databases, see
[Persistence](../03-architecture/persistence.md).

`cli.ts` recognizes three subcommands — `start`, `follow`, `query`
(`packages/ingester/src/cli.ts:84-89`). Usage (`packages/ingester/src/cli.ts:7-23`):

```
ingester — capture and query a lending environment's history

usage:
  ingester start  --provisioned <file> [--from-ledger <n>] [--once]
  ingester follow --dir <dir> [--interval <seconds>]
  ingester query  --setup-id <id> [--correlation-id <id>] [--state]

options:
  --provisioned <file>   provisioned environment graph (which accounts to watch)
  --dir <dir>            directory of provisioned session files to follow (the engine's out/)
  --interval <seconds>   how often to re-scan the directory for new sessions (default 10)
  --from-ledger <n>      backfill from this ledger index instead of the stored cursor
  --once                 backfill and exit instead of holding the live stream open
  --setup-id <id>        the run to query
  --correlation-id <id>  narrow the action list to one correlation id
  --state                report current derived state instead of the action list
```

Real invocations, from the package README (`packages/ingester/README.md:36-48`):

```sh
# capture a run's history (backfill, then follow the live stream)
pnpm ingester start --provisioned ./out/<setup-id>.json

# backfill once and exit
pnpm ingester start --provisioned ./out/<setup-id>.json --once

# list a run's actions in order
pnpm ingester query --setup-id <id>

# show current derived state
pnpm ingester query --setup-id <id> --state
```

`follow` is a third mode, not covered by the package README's usage section but present in the
CLI's own usage string and implementation: it watches a directory of provisioned session files —
the engine's `out/` directory — and re-scans it on an interval (default 10 seconds) rather than
requiring one `--provisioned` file per session (`packages/ingester/src/cli.ts:11,56-62`).

```sh
pnpm ingester follow --dir <dir>
```

Requires Postgres reachable via `DATABASE_URL` (`packages/ingester/README.md:22-24`); before first
use, run migrations:

```sh
cp .env.example .env          # point DATABASE_URL at your Postgres
pnpm --filter @lending/ingester prisma:migrate
```
(`packages/ingester/README.md:29-32`, script defined at `packages/ingester/package.json:21`)

Each setup has an ingestion cursor recording the last fully-persisted ledger index; on restart the
subscriber resumes from there, and because capture is idempotent on tx hash, replaying a
already-seen transaction is a no-op — so a restart produces no gaps and no duplicates
(`packages/ingester/README.md:50-54`).

> [!NOTE]
> `query --state` and the general subscribe/capture/normalize/project pipeline are documented in
> depth in [Persistence](../03-architecture/persistence.md); this page covers only the CLI
> invocation.
