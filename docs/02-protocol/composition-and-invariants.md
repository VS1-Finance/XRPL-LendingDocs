---
label: Composition & Invariants
order: 50
---

# Composition & Protocol Invariants

The [Protocol Foundations](./index.md) page documents the composition chain — how the four
amendments' objects feed one another (credential → domain → vault → broker). This page documents a
narrower thing: the **invariants** the reference implementation asserts or observes at each stage of
that chain, each tied to the exact code that enforces or observes it.

An invariant here is one of two kinds, and each subsection says which:

- **Enforced** — the implementation actively checks the condition at run time and raises before
  proceeding (an `InvariantError`, an `ActionError`, or an on-ledger rejection it depends on).
- **Observed** — a property of the ledger's own behavior that the implementation relies on and has
  verified, but does not itself assert in code.

## 1. Single-owner invariant

**What it is.** The vault and the loan broker attached to it must be owned by the same account. There
is no separate "originator" account distinct from the vault manager — by construction in this system,
one account plays both roles.

**Why it matters.** `LoanBrokerSet.VaultID` attaches a broker to a vault, but nothing in the
transaction itself prevents a caller from architecting a vault and broker under different owners.
This system never attempts that — the account that creates the vault is the same account that later
creates the broker (`provision.ts:113-114` per the code map) — and after both objects exist, it
checks that the ledger agrees before continuing.

**Code.**

```ts
// assertions.ts:13-26
export async function assertSingleOwner(client: Client, owner: string): Promise<void> {
  const vaults = await accountObjects(client, owner, "vault");
  const brokers = await accountObjects(client, owner, "loan_broker");
  const vault = vaults[0];
  const broker = brokers[0];
  if (!vault) throw new InvariantError("no vault found under the owner account");
  if (!broker) throw new InvariantError("no loan broker found under the owner account");

  const vaultOwner = (vault.Owner as string | undefined) ?? owner;
  const brokerOwner = (broker.Owner as string | undefined) ?? owner;
  if (brokerOwner !== vaultOwner) {
    throw new InvariantError(`broker owner ${brokerOwner} does not match vault owner ${vaultOwner}`);
  }
}
```

`assertSingleOwner` is called once, immediately after `createBroker` and before `depositCover`
(`provision.ts:117`, per the [Protocol Foundations](./index.md#3-vault--lending) composition-point-3
citation). A failure here is `InvariantError`, not a ledger rejection — it means the provisioning
code itself built the wrong object graph, and provisioning aborts rather than seeding cover into a
broker with a mismatched owner.

> [!NOTE]
> This system enforces the tighter policy of never issuing a separate originator account at all —
> vault-manager and loan-originator are the same seat by construction, not merely by an
> after-the-fact check. `assertSingleOwner` is the run-time proof that the construction held.

## 2. First-loss cover floor

**What it is.** The loan broker's `CoverAvailable` — first-loss capital that absorbs losses before
depositors do — must clear a configured minimum once seeded, and stays load-bearing afterward: bot
logic bounds every new loan's size by how much debt the current cover can still support.

**Why it matters.** Cover is the buffer between a defaulted loan and depositor principal. A broker
seeded below its intended minimum would let origination proceed on a thinner safety margin than the
deployment configured, so the assertion runs once at provisioning time, right after cover is
deposited — not as an ongoing ledger-enforced constraint this system asserts as protocol text.

**Code — the provisioning-time floor check.**

```ts
// assertions.ts:31-45
export async function assertCoverMeetsMinimum(
  client: Client,
  owner: string,
  expectedMinimum: string,
): Promise<{ cover: string }> {
  const brokers = await accountObjects(client, owner, "loan_broker");
  const broker = brokers[0];
  if (!broker) throw new InvariantError("no loan broker found under the owner account");

  const cover = readAmount(broker.CoverAvailable);
  if (Number(cover) < Number(expectedMinimum)) {
    throw new InvariantError(`broker cover ${cover} is below the required ${expectedMinimum}`);
  }
  return { cover };
}
```

Called right after `depositCover`, at `provision.ts:119-120` (per the code map) — the configured
cover amount is checked against what the ledger actually reports as `CoverAvailable`, not merely the
amount the deposit transaction requested.

**Code — cover-rate math bounds new loans (bot sizing logic, not asserted protocol text).**
`maxOriginatable` reads the broker's live `CoverAvailable`, `DebtTotal`, `DebtMaximum`, and
`CoverRateMinimum`, and computes the largest new loan the broker can currently back:

```ts
// bots/reads.ts:148-167 (relevant excerpt)
export async function maxOriginatable(session: Session): Promise<number> {
  const vault = await ownerObject(session, "vault");
  const broker = await ownerObject(session, "loan_broker");
  if (!vault || !broker) return 0;

  const available = readWholeTokens(session, vault.AssetsAvailable);
  const coverAvailable = readWholeTokens(session, broker.CoverAvailable);
  const debtTotal = readWholeTokens(session, broker.DebtTotal);
  const debtMaximum = readWholeTokens(session, broker.DebtMaximum);
  const coverRate = readNumber(broker.CoverRateMinimum) || 100000;

  const coverSupportsTotal = (coverAvailable * 100000) / coverRate;
  const coverHeadroom = coverSupportsTotal - debtTotal;
  const debtHeadroom = debtMaximum > 0 ? debtMaximum - debtTotal : Infinity;

  return Math.max(0, Math.min(available, coverHeadroom, debtHeadroom));
}
```

This is our own headroom arithmetic over ledger-reported fields, used to size bot-originated loans —
it is **not** a ledger-enforced formula the protocol asserts. A new loan is bounded by the smallest of
three ceilings: the vault's spare liquidity (`available`), the debt the remaining cover can still
support at the minimum cover rate (`coverHeadroom`), and room under the broker's configured debt
ceiling (`debtHeadroom`). The full derivation and rate-scaling convention (`100000` = `100%`) are on
the [Lending Protocol](./xls66-lending-protocol.md#4-cover-rate-math-scaled-integers) page.

> [!NOTE]
> A related configuration-time invariant — `coverRateLiquidation` must not exceed
> `coverRateMinimum` — is enforced by a Zod `superRefine` before any transaction is built
> (`config/schema.ts:108-115`, per `amendment-map.md`), not on ledger. It is a guard against a
> self-contradictory deployment config, not a protocol assertion.

## 3. Bilateral origination

**What it is.** A loan cannot be created unilaterally by the broker owner. `LoanSet` requires two
signatures on the same transaction: the owner signs, and the named `Counterparty` (the borrower)
counter-signs before it is submitted.

**Why it matters.** Origination commits the borrower to a repayment obligation, so the ledger
requires the borrower's own signature as consent — a broker owner cannot originate a loan against an
unwilling or absent counterparty. On top of that ledger-level requirement, the engine adds its own
role guards so a misrouted request fails cleanly before it ever reaches signing.

**Code — the bilateral sign.**

```ts
// action-service.ts:188-232 (relevant excerpt)
export async function originate(session: Session, ownerSeatKey: string, params: Record<string, string>, participant: string): Promise<ActionResult> {
  const owner = session.seats.get(ownerSeatKey);
  if (!owner) throw new ActionError(`session has no seat ${ownerSeatKey}`, 404);
  if (owner.occupant.kind !== "human" || owner.occupant.id !== participant) {
    throw new ActionError(`${ownerSeatKey} is not held by ${participant}`, 409);
  }
  if (owner.role !== "owner") throw new ActionError("only the owner seat can originate a loan", 409);
  const borrowerSeat = session.seats.get(required(params, "borrower"));
  if (!borrowerSeat) throw new ActionError(`session has no seat ${params.borrower}`, 404);
  if (borrowerSeat.role !== "borrower") throw new ActionError(`${borrowerSeat.role} seat cannot be a loan counterparty`, 409);

  const loanSet = {
    TransactionType: "LoanSet" as const,
    Account: owner.address,
    LoanBrokerID: session.env.objects.brokerId!,
    Counterparty: borrowerSeat.address,
    PrincipalRequested: brokerValue(session, required(params, "principal")),
    InterestRate: Number(params.interestRate ?? 50000),
    PaymentInterval: Number(params.interval ?? 60),
    GracePeriod: Number(params.grace ?? 60),
    LoanOriginationFee: "0",
  };

  const ownerWallet = deriveAccount(session.seed, "owner", owner.index).wallet;
  const borrowerWallet = deriveAccount(session.seed, "borrower", borrowerSeat.index).wallet;
  const prepared = await session.client.autofill(loanSet);
  const ownerSigned = ownerWallet.sign(prepared);
  const combined = signLoanSetByCounterparty(borrowerWallet, ownerSigned.tx_blob);
  const res = await session.client.submitAndWait(combined.tx_blob);
  ...
}
```

**The two role guards** (`action-service.ts:197,200`): the acting seat must have `role === "owner"`
(`:197`) and the named counterparty seat must have `role === "borrower"` (`:200`) — each checked
*before* wallets are derived or a transaction is built. Both are enforced as a 409 `ActionError`, not
left to surface as an opaque ledger rejection: because the signing wallets are re-derived by role
(`deriveAccount(session.seed, "owner"|"borrower", index)`), a misrouted seat would otherwise sign with
an account that does not match the intended `Account`/`Counterparty` fields, and the ledger's
rejection of that mismatch would be far less legible than a clean 409 at the engine boundary.

The bilateral requirement itself is a ledger-level fact, not merely an engine-side convention:
negative-suite case N10 confirms it from the rejection side — a `LoanSet` signed only by the owner,
with no counter-signature, is rejected before consensus (per `amendment-map.md` and the
[Lending Protocol](./xls66-lending-protocol.md#2-bilateral-origination) page).

## 4. Share conservation

**What it is.** A vault deposit mints shares proportional to the assets deposited — a depositor's
minted share balance is a deterministic function of what they put in, never an arbitrary or
governance-set amount.

**Why it matters.** Shares are the depositor's claim on the vault's underlying assets, including
accrued interest; conservation is what makes a share a meaningful, transferable unit of that claim
rather than an accounting artifact. This system relies on, but does not itself compute or re-derive,
the ledger's own minting rule — deposits go on ledger via `VaultDeposit` and the resulting share
balance is read back, not calculated client-side.

**Reference.** The exact minting formula — first-deposit scaling by `10^Scale` and proportional
minting on every subsequent deposit — is protocol-level XLS-65 behavior, not engine logic, and is
derived in full on the [Single Asset Vault](./xls65-single-asset-vault.md) page. This page states only
the conservation property; see that page for the `Δshares` formula, the `Scale` field's per-asset
default, and the worked numeric example.

> [!NOTE]
> Share conservation is an **observed** protocol property here, not one this codebase asserts with
> its own run-time check — there is no `assertShareConservation` alongside `assertSingleOwner` and
> `assertCoverMeetsMinimum`. The implementation reads the minted share balance back from the ledger
> (`account_objects type:"mptoken"`, per `amendment-map.md`) and trusts it as the source of truth.

## 5. Time-gated default

**What it is.** A loan cannot be defaulted before its next payment's due date plus its grace period
has elapsed — regardless of how delinquent it appears by other measures.

**Why it matters.** Without a time gate, a broker owner could default a loan the moment a payment is
merely due, before the borrower's grace window to pay has actually run out. The gate protects the
borrower's contracted grace period as a hard floor, not a courtesy the owner can choose to skip.

**Code.**

```ts
// state-service.ts:57-59
const defaultableAt = Number(loan.NextPaymentDueDate ?? 0) + Number(loan.GracePeriod ?? 0);
const secondsUntil = defaultableAt - nowRipple();
const defaultableNow = !defaulted && paymentRemaining > 0 && defaultableAt > 0 && secondsUntil <= 0;
```

`nowRipple()` converts wall-clock time to the Ripple epoch (2000-01-01, offset `946684800` seconds)
before the comparison (`state-service.ts:34-35`). This same gate is what the session-state projection
uses to tell the front end whether a loan is defaultable right now, and if not, how many seconds
remain (`state-service.ts:14,21-22`, `:68`).

The gate is enforced on ledger, not merely computed here for display: submitting `LoanManage` with
`Flags: tfLoanDefault (65536)` before `NextPaymentDueDate + GracePeriod` has passed is rejected with
`tecTOO_SOON` — asserted by negative-suite case N14 and observed directly in this system's E2E run
(per `amendment-map.md` and the
[Lending Protocol](./xls66-lending-protocol.md#5-time-gated-default) page). The state-service
computation above is this system's client-side prediction of that same ledger gate, used so the UI
can show a countdown rather than only a binary allowed/rejected outcome.

## Summary

| Invariant | Enforced or observed | Code citation |
|---|---|---|
| Single owner (vault + broker share one `Owner`) | Enforced (engine-side, at provisioning) | `assertions.ts:13-26` |
| First-loss cover floor (cover ≥ configured minimum) | Enforced (engine-side, at provisioning) | `assertions.ts:31-45` |
| Cover-rate loan sizing (new loan ≤ cover/debt/liquidity headroom) | Enforced (bot sizing logic, not asserted protocol text) | `bots/reads.ts:148-167` |
| Bilateral origination (owner + borrower both sign `LoanSet`) | Enforced (ledger-level, plus engine role guards) | `action-service.ts:188-232`, guards at `:197,200` |
| Share conservation (deposit mints shares proportional to assets) | Observed (ledger-level XLS-65 rule; not re-derived here) | see [Single Asset Vault](./xls65-single-asset-vault.md) |
| Time-gated default (`NextPaymentDueDate + GracePeriod` must pass) | Enforced (ledger-level, `tecTOO_SOON`); computed client-side for display | `state-service.ts:57-59` |

Related: [Protocol Foundations](./index.md) for the composition chain these invariants sit on top of,
and the forthcoming [Invariants & Guards](../06-security/invariants-and-guards.md) page for the fuller
engine-side guard inventory (seat-held authorization, amount validation, session capacity) alongside
the protocol invariants documented here.
