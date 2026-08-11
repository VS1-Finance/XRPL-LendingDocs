---
label: Bot Framework
order: 30
---

# The Bot Framework

A provisioned session has a fixed set of seats — one per role, pooled for depositors and borrowers (see [Session and Seat Model](./session-seat-model.md)). A seat that no human has claimed is filled by a bot, so a session runs end-to-end (deposits, originations, repayments, defaults) without a person driving every role. When a human claims a seat, that seat's bot stands down on its next round; releasing it lets a bot resume (`seat.ts:41-45,58-64`; `scheduler.ts:57`).

## The variant model

The unit of bot behavior is a `BotVariant`: a role plus a `tick` function that reads session state and, at most, submits one action (`variant.ts:16-22`).

```ts
export interface BotVariant {
  role: Role;
  name: string;
  tick(ctx: BotContext): Promise<StepOutcome>;
}
```

`tick` returns `{ acted: false }` (nothing to do this round) or `{ acted: true, action, result, hash? }` (`variant.ts:24-28`). A variant is a pure strategy: it acts through the seat's `signer` and reads state off the session, so the same variant implementation works for any seat of its role (`variant.ts:12-15`). Implementations are expected to check current state before acting, so a repeated tick does not double-act (`variant.ts:19-20`) — for example, `depositAndHold` checks its own share balance before depositing (`variants.ts:12-13`).

### Every variant, by role

| Variant | Role | Behavior | Source |
|---|---|---|---|
| `repayOnTime` | borrower | Pays a loan's full outstanding balance as soon as one exists. | `variants.ts:34-51` |
| `repayLate` | borrower | Waits until ledger time is past `NextPaymentDueDate`, then pays in full. | `borrower-variants.ts:11-31` |
| `overpay` | borrower | Pays outstanding plus a fixed extra (default `1000`), with `TF_LOAN_OVERPAYMENT` (65536) set on `LoanPay`. | `borrower-variants.ts:35-56` |
| `repayEarly` | borrower | Pays the full outstanding amount immediately, without waiting on the payment schedule. | `borrower-variants.ts:60-77` |
| `defaulter` | borrower | Never pays; `tick` is a no-op. The loan is left to be defaulted from the broker/owner side. | `borrower-variants.ts:81-87` |
| `depositAndHold` | depositor | Deposits a target amount (default `20000`, capped to available headroom) once, when it holds no shares; holds thereafter. | `variants.ts:7-30` |
| `depositWithdrawCycle` | depositor | Deposits when it holds no shares; withdraws its full share position when it does — cycling in and out. | `depositor-variants.ts:13-44` |
| `topUp` | depositor | Deposits a fixed increment (default `5000`) per tick until contributed total reaches a target (default `20000`), then holds. | `depositor-variants.ts:49-71` |
| `loanOriginator` | owner | Finds a borrower with no loan and originates one (bilateral `LoanSet`, owner + borrower counter-sign), sized to available vault/broker headroom. One origination per tick; idle once every borrower has a loan. | `owner-variants.ts:20-68` |
| `brokerEnforcer` | owner | Scans borrowers' loans for one past its due date plus grace period with payment still outstanding, and defaults it via `LoanManage` with `tfLoanDefault` (65536). | `owner-variants.ts:75-92,113-135` |
| `brokerOwner` | owner | Combined behavior: tries `loanOriginator` first; if it doesn't act (every borrower already has a loan), falls through to `brokerEnforcer`. | `owner-variants.ts:98-110` |

`brokerOwner` is what runs both sides of the owner role — lending and enforcement — in a single variant so the lifecycle turns unattended (`owner-variants.ts:94-97`). It is also the only owner variant `assignWeighted` picks (see below) — the owner seat is not weighted across alternatives the way borrower and depositor seats are (`weights.ts:81-83`).

Origination is bilateral by construction: the owner and target borrower's wallets are both re-derived from the session seed (`deriveAccount`, per [Account Derivation](./account-derivation.md)), the owner signs first, and `signLoanSetByCounterparty` (xrpl.js) combines the borrower's counter-signature onto the same `LoanSet` (`owner-variants.ts:57-62`) — the same bilateral path a human-driven origination uses.

## Scenarios and weighting

Two independent ways to pick which variants run:

**Fixed profiles** (`profiles.ts:9-30`) — `profileVariants(name)` for `ProfileName = "happy" | "adversarial"`:

- `happy`: `depositAndHold` + `repayOnTime` only — every seat behaves well (`profiles.ts:13`).
- `adversarial`: `depositAndHold`, `depositWithdrawCycle`, `repayOnTime`, `repayLate`, `overpay`, `defaulter`, `brokerEnforcer` — the full behavioral range at once, including real on-chain defaults (`profiles.ts:17-25`).

These lists are spread across seats round-robin by seat index via `assignAutomatically`, keyed by role (`assignment.ts:15-30`): given two borrower variants and three borrower seats, seats 0 and 2 get the first variant and seat 1 the second.

**Weighted scenarios** (`weights.ts:24-46`) — `scenarioWeights(scenario, seed)` for `"calm" | "defaults" | "mixed"` (default), returning relative weights per borrower behavior (`onTime`, `late`, `early`, `overpay`, `default`) and per depositor behavior (`hold`, `churn`, `topUp`):

| Scenario | Borrower weights (onTime/late/early/overpay/default) | Depositor weights (hold/churn/topUp) | Source |
|---|---|---|---|
| `calm` | 8 / 1 / 2 / 1 / 0 | 6 / 1 / 2 | `weights.ts:26-31` |
| `defaults` | 1 / 3 / 0 / 0 / 5 | 3 / 2 / 1 | `weights.ts:32-37` |
| `mixed` (default) | 5 / 1 / 1 / 1 / 2 | 3 / 1 / 1 | `weights.ts:38-44` |

`assignWeighted(session, weights)` draws a variant per seat from these weights via a seeded random stream (`seededStream(weights.seed, "variant-assignment")`), so the same seed and pool produce the same assignment every run — a weighted scenario is both configurable and reproducible (`weights.ts:48-60`). Weights need not sum to one; a weight of `0` excludes a behavior entirely (`weights.ts:13`).

> [!NOTE]
> `pickForRole` treats the owner seat as unweighted: it always returns `brokerOwner()` regardless of the weights argument (`weights.ts:81-83`).

## The scheduler

`BotScheduler` (`scheduler.ts:27-105`) drives every bot-held seat in a session, one round at a time.

Each round (`scheduler.ts:53-90`):

1. Iterate every seat in the session (`scheduler.ts:55`).
2. Skip a seat a human currently holds (`isBotDriven(seat)` false) — this is how claiming a seat stands its bot down without a restart, since occupancy is read live each round (`scheduler.ts:57`, class comment `scheduler.ts:23-26`).
3. Skip a seat already marked exhausted (`scheduler.ts:59`).
4. Run the seat's assigned variant's `tick` (`scheduler.ts:63`).
5. If it acted, report the outcome via `onOutcome` and track consecutive identical rejections per seat; a `tesSUCCESS` clears the streak (`scheduler.ts:64-72`).
6. If the same non-success result repeats `GIVE_UP_AFTER = 3` times in a row for a seat, that seat is added to `exhausted` and skipped for the rest of the run — so a seat stuck against a wall (e.g. a depositor hitting a full vault) does not keep burning rounds and ledger submissions (`scheduler.ts:39,73-76`).
7. A `tick` that throws is caught and logged; it does not stop the scheduler (`scheduler.ts:79-81`).

The round stops the scheduler when `maxRounds` is reached, or when every bot-driven seat with an assigned variant has become exhausted (`scheduler.ts:84-88`, `allExhausted` at `:95-104`). Otherwise it paces the next round on **ledger progression** — `waitForLedgerAdvance` waits until the validated ledger has advanced at least one ledger (`intervalSeconds` bounds the wait so a stalled network cannot wedge the pool), rather than sleeping a fixed wall-clock interval. Pacing on the ledger, not the host clock, is what lets two runs with the same seed observe ledger state at the same logical points — the basis of deterministic behavior (below).

Variant assignment is resolved once at `run()` start: an explicit `assignment` if given, otherwise `assignAutomatically(session, options.variants)` (`scheduler.ts:44`).

> [!NOTE]
> The engine's default `maxRounds` for a started bot run is governed by `BOT_MAX_ROUNDS` (default 20) — see `bot-service.ts:50` per the engine API.

## Determinism

Bot behavior is deterministic. Three properties combine to guarantee that, for the same conditions, a bot always takes the same action:

1. **Seed-fixed strategy.** The seed fixes which variant each seat runs, drawn once at `run()` start from a seeded stream (`seededStream(weights.seed, "variant-assignment")`). The same seed and pool produce the same seat→variant map every run.
2. **Pure decisions.** Every variant's per-tick decision is a pure function of the observed ledger state — the loan/vault/broker objects it reads and the ledger's own `close_time`. There is no `Math.random`, no host-clock read, and no dependence on ledger height in any decision; amounts are `Math.min(fixedValue, floor(headroom))`, a pure function of read state. Given the same observed state, a variant computes the same action.
3. **Ledger-paced sampling.** Rounds advance on ledger progression (`waitForLedgerAdvance`), not the wall clock, and seats are visited in a fixed order (by role, then numeric index). So two runs with the same seed sample ledger state at the same logical points and act in the same order.

Together: **the same seed, against equivalent starting state, produces the same bot behavior** — the same strategy per seat and the same sequence of actions. This is verifiable directly: two sessions provisioned with the same `botSeed`, scenario, and pool produce matching per-seat action sequences.

What is *not* identical across two separate runs is account identity: each run provisions fresh accounts, so the wallet addresses, and therefore the transaction hashes and a loan's absolute due-date timestamps, differ. That is a property of running against a live network with fresh provisioning, not bot nondeterminism — the *behavior* (which seat does what, in what order) reproduces.

## See also

- [Bots API](../04-api/bots.md) — starting and stopping a session's bot scheduler over HTTP.
- [Session and Seat Model](./session-seat-model.md) — seats, occupancy, and how claim/release interact with bot-driven seats.
