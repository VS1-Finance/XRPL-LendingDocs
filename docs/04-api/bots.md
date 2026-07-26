---
label: Bots
order: 40
---

# Bot Control Routes

Two routes start and stop a session's bot scheduler. Both are registered on the engine's Fastify app by `registerBotRoutes` (`routes/bots.ts:7`), which wires `SessionService` (session lookup) and `BotService` (scheduler lifecycle) together.

While a session's bots are running, the scheduler drives every seat no human currently holds; claiming a seat stands its bot down on the scheduler's next round, and releasing it lets the bot resume (`routes/bots.ts:5-6`). See [The Bot Framework](../03-architecture/bot-framework.md) for the variant model, scenario weighting, and per-round scheduler mechanics.

## POST /sessions/:id/bots/start

Starts the bot scheduler for a session.

| | |
|---|---|
| Body | `{ intervalSeconds?: number }` |
| 200 | `{ setupId, bots: "running" }` |
| 404 | unknown session |

Source: `routes/bots.ts:8-16`.

`intervalSeconds` defaults to `15` when omitted (`routes/bots.ts:13`) — this is the number of seconds the scheduler sleeps between rounds (`scheduler.ts:14,43,89`, per [The Bot Framework](../03-architecture/bot-framework.md#the-scheduler)).

On start, every seat not held by a human is filled with a bot (`bot-service.ts:39`), so starting bots runs the whole market, not only seats already bot-occupied. Starting an already-running session is a no-op — `BotService.start` returns immediately if a scheduler for that `setupId` is already tracked (`bot-service.ts:34-35`).

> [!NOTE]
> Each bot action is recorded in the session's log via `onOutcome`, translating the submitted transaction type (e.g. `VaultDeposit`, `LoanPay`) to the engine's action vocabulary (e.g. `deposit`, `repay`) so a bot action reads the same as an equivalent human action (`bot-service.ts:7-13,51-60`).

## POST /sessions/:id/bots/stop

Stops the bot scheduler for a session.

| | |
|---|---|
| Body | — |
| 200 | `{ setupId, bots: "stopped" }` |
| 404 | unknown session |

Source: `routes/bots.ts:18-22`.

Stopping a session with no running scheduler is a clean no-op: `BotService.stop` calls `.stop()` on whatever is in the `running` map for that `setupId` (a no-op if nothing is there) and then deletes the entry unconditionally (`bot-service.ts:67-70`).

## Round budget

A started scheduler does not run forever. `BotService.start` sets `maxRounds` from the `BOT_MAX_ROUNDS` environment variable, defaulting to `20` (`bot-service.ts:50`) — enough rounds for the pool to complete one or two full lifecycles (deposit, originate, repay or default, withdraw) before stopping on its own. Starting the session's bots again resumes driving it. See the scheduler's stop conditions in [The Bot Framework](../03-architecture/bot-framework.md#the-scheduler).

## See also

- [The Bot Framework](../03-architecture/bot-framework.md) — variant model, scenario weighting, and scheduler round mechanics.
- [Session and Seat Model](../03-architecture/session-seat-model.md) — claim/release and how human occupancy interacts with bot-driven seats.
