# Architecture Map (code recon) — cite these file:line references

Monorepo root: `/Users/levan/Documents/projects/xrpl/lending-reference`. pnpm workspace, 8 packages under `packages/`.
Dependency layering: `shared` ← `bootstrap` ← `session` ← `engine`; `lifecycle`/`ingester`/`negative-suite`/`monitoring` are standalone consumers. Every CLI entry is `src/cli.ts` except engine (`src/main.ts`).

## shared — cross-cutting utilities
- `deriveAccount(seed, role, index)` → DerivedAccount — `accounts.ts:22-30`; `deriveAccountSet(seed, pool, {permissioned})` — `accounts.ts:45-60`; `allAccounts` — `accounts.ts:64-66`; `Role` — `accounts.ts:8`.
- `submitBatch(client, items)` — `client.ts:113-190`; `submit`/`submitOrThrow` `client.ts:44-81`; `classifyResult` `client.ts:85-96`; `connect` `client.ts:21-28`; `accountObjects` `client.ts:215-228`. `MAX_PER_ACCOUNT_PER_LEDGER=8` `client.ts:111`; `MAX_ATTEMPTS=4` `client.ts:116`.
- `roleReserveDrops(role, shape, rates)` `reserves.ts:84-86`; `readReserveRates(client)` `reserves.ts:18-25`; `peakObjectCount` `reserves.ts:51-73`; `ReserveRates` `reserves.ts:13-16`; `VaultShape` `reserves.ts:28-38`; FEE_HEADROOM 2 XRP `reserves.ts:77`.
- `fanOutFunding`/`fundTreasury`/`fundTreasuryForTargets` `funding.ts:27,68,80`.
- money: `decimalToScaled`/`scaledToDecimal`/`xrpToDropsBig`/`dropsToXrpString`/`clampIssuedValueUp` `money.ts:17,30,6,10,45`.
- config: `ConfigSchema`/`Config` `config/schema.ts:32-118`; `loadConfig`/`validateConfig`/`ConfigError` `config/index.ts:11`; `AssetConfigSchema`/`isXrpAsset` `config/asset.ts:32,42`; `Network` `config/schema.ts:5-6`.

## bootstrap — provisioning harness
- Exports (`index.ts:1-16`): `provision`/`ProvisionOptions` `provision.ts:45`; `teardown` `teardown.ts:22`; `saveEnvironment`/`loadEnvironment`/`deleteEnvironment` `store.ts:14,21,27`; `assertSingleOwner`/`assertCoverMeetsMinimum`/`InvariantError`; `isPermissioned(env)` `types.ts:50-52`; `ProvisionedEnvironment`/`ProvisionedAccount`/`StepRecord` `types.ts:5-44`.
- Step builders: `runBatch` `steps.ts:52-78`; `issuerFlagSteps` `steps.ts:82`; `trustSteps` `steps.ts:98`; `distributeSteps` `steps.ts:109`; `credentialCreateSteps` `steps.ts:134`; `credentialAcceptSteps` `steps.ts:144`; `createDomain` `steps.ts:154`; `createVault` `steps.ts:169`; `createBroker` `steps.ts:199`; `depositCover` `steps.ts:224`; `StepDeps`/`PlannedStep` `steps.ts:30-47`.
- Provisioning sequence (`provision.ts:71-121`): (1) derive accounts + read reserve rates + fund via treasury fan-out `:79-84`; (2) [IOU only] issuer flags `steps.ts:82-96`, trust lines `:98-107`, distributions `:109-118` (`provision.ts:92-104`); (3) [permissioned only] credentialCreate → credentialAccept → createDomain (`:108-112`); (4) createVault (domain-gated + tfVaultPrivate if permissioned; WithdrawalPolicy=firstComeFirstServe) `steps.ts:169-197`; (5) createBroker `steps.ts:199-222`; (6) assertSingleOwner `:117`; (7) depositCover + assertCoverMeetsMinimum `:119-120`. `fundingPlan` `provision.ts:153-173`.
- `ledger-lookups.ts` lives HERE: `findDomainId`/`findVault`/`findBrokerId`/`findBrokerCover` `:12-39`; `hasAcceptedCredential`/`hasTrustLine`/`issuedBalance`/`accountHasFlag` `:42-108`; `encodeCredentialType` `:8-10`; `lsfAccepted 0x00010000` `:62`.

## engine — HTTP service (Fastify :4000)
App wiring (`app.ts:16-48`): CORS `@fastify/cors` (CORS_ORIGIN, default permissive) `:22`; EngineStore.connect() fail-fast `:24-25`; SessionService+BotService `:27-28`; loadPersisted on boot `:30`; stopAll+disconnect on close `:42-45`. Config via ENGINE_CONFIG/ENGINE_SEED/ENGINE_NETWORK/PORT(4000)/HOST(0.0.0.0) `config.ts:12-31`.

ROUTE TABLE:
| Method | Path | Body/Params | Status | Source |
|---|---|---|---|---|
| GET | /health | — | 200 | app.ts:34 |
| POST | /sessions | ProvisionBody | 201 | routes/sessions.ts:29-32 |
| POST | /sessions/stream | ProvisionBody; SSE step/done/error | 200 (event-stream) | routes/sessions.ts:38-61 |
| GET | /sessions | — | 200 | routes/sessions.ts:64 |
| GET | /sessions/:id | — | 200/404 | routes/sessions.ts:67-71 |
| GET | /sessions/:id/state | — | 200/404 | routes/sessions.ts:75-79 |
| GET | /sessions/:id/balances | — | 200/404 | routes/sessions.ts:83-87 |
| GET | /sessions/:id/log | — | 200/404 | routes/sessions.ts:91-94 |
| POST | /sessions/:id/participants | {role} | 200/400/404/409/500 | routes/sessions.ts:99-117 |
| POST | /sessions/:id/seats/:seat/claim | {participant} | 200/400/404/409 | routes/seats.ts:13-28 |
| POST | /sessions/:id/seats/:seat/release | {participant} | 200/400/404/409 | routes/seats.ts:31-46 |
| POST | /sessions/:id/actions | {participant,seat,action,params} | 200/400/404/409/500 | routes/actions.ts:9-43 |
| POST | /sessions/:id/bots/start | {intervalSeconds?} default 15 | 200/404 | routes/bots.ts:8-16 |
| POST | /sessions/:id/bots/stop | — | 200/404 | routes/bots.ts:18-22 |

ACTION VERB → TxType (`action-service.ts:73-183` buildTransaction):
| Action | TransactionType | Seat | Source |
|---|---|---|---|
| deposit | VaultDeposit | depositor | action-service.ts:77-83 |
| withdraw | VaultWithdraw | depositor | action-service.ts:85-91 |
| repay | LoanPay | borrower | action-service.ts:93-101 |
| issue-credential | CredentialCreate | issuer | action-service.ts:104-110 |
| revoke-credential | CredentialDelete | issuer | action-service.ts:112-118 |
| accept-credential | CredentialAccept | subject | action-service.ts:123-129 |
| set-vault | VaultSet | owner | action-service.ts:132-139 |
| set-domain | PermissionedDomainSet | owner | action-service.ts:141-158 |
| manage-loan | LoanManage (Flags=tfLoanDefault 65536) | owner | action-service.ts:162-168 |
| deposit-cover | LoanBrokerCoverDeposit | owner | action-service.ts:172-178 |
| originate | LoanSet (bilateral) | owner+borrower | action-service.ts:188-232 |

`originate` bilateral: owner signs, borrower counter-signs via signLoanSetByCounterparty; wallets re-derived (`action-service.ts:202-228`). Role guards: owner.role==="owner", borrowerSeat.role==="borrower" (post-fix). `dispatchAction` enforces seat-held-by-participant `:57-71`. `asClientError` maps ValidationError/tem/bad-amount → 400 `:31-46`. `requireAmount` validates `^\d+(\.\d+)?$` & >0 `:247-252`.
Services: SessionService `session-service.ts:45-242` (create `:62-122`, addParticipant `:136-160`, loadPersisted `:164-177`, MAX_POOL=20 `:10`, CapacityError `:14`); BotService `bot-service.ts:19-77` (maxRounds via BOT_MAX_ROUNDS default 20 `:50`).

## session — session/seat/registry/bots
- Session `session.ts:10-17`; createSession/attachSession/closeSession `:22,35,41`; buildSeats `:45-64`.
- Seat/Occupant `seat.ts:7-20`; seatKey/keyOf/claim/release/fillWithBot/isBotDriven/isHumanHeld/SeatOccupancyError `seat.ts:23-68`. Occupancy exclusive: open|bot|human.
- Signer interface + ServerSigner (pluggable external-wallet seam) `signer.ts:12-34`.
- SessionRegistry/SessionSummary `registry.ts:7-85`.
- `addParticipant(session, role, seed, config)` `add-participant.ts:32-109`; partial-failure gap doc `:130-135`.
- Bots: borrower variants repayOnTime/repayLate/overpay/repayEarly/defaulter (`variants.ts:34`, `borrower-variants.ts:11,36,60,81`); depositor depositAndHold/depositWithdrawCycle/topUp (`variants.ts:7`,`depositor-variants.ts:13,49`); owner loanOriginator/brokerEnforcer/brokerOwner (`owner-variants.ts:20,75,98`). Presets profileVariants/ProfileName `profiles.ts:9-30`; scenarioWeights calm|defaults|mixed `weights.ts:24-46`. Scheduler `scheduler.ts:27-105` (GIVE_UP_AFTER=3 `:39`; maxRounds stop `:84-88`). assignWeighted seeded `weights.ts:51-60`.

## standalone consumers
- ingester: off-chain history store; subscribe→capture(idempotent on txHash)→normalize→project. CLI `src/cli.ts`; barrel `index.ts:1-8`. Separate Postgres via DATABASE_URL; schema `packages/ingester/prisma/schema.prisma` (Transaction/Event/Outbox/IngestCursor + VaultState/LoanState/BrokerState/CredentialState; resetEpoch on every table).
- lifecycle: one full loan lifecycle (deposit→originate→repay→close). CLI `src/cli.ts`; barrel `index.ts:1-9` (runLifecycle/deposit/originate/repay/close).
- negative-suite: adversarial N1–N15. CLI `src/cli.ts`; runSuite `runner.ts:22`; cases under `src/cases/{credentials,lending}.ts`.
- monitoring: docker-compose Prometheus+Grafana over ingester DB via postgres_exporter. NO TS source — `queries.yaml` + `grafana/` + compose.

## cross-cutting
- Account derivation: SHA-256 of `xrpl-lending/account/v1\0{seed}\0{role}\0{index}` first 16 bytes → Wallet.fromEntropy (`accounts.ts:22-30`). Deterministic; issuer/owner index 0; credentialIssuer only permissioned.
- submitBatch: group pending by account each attempt; fetch Sequence once, assign N,N+1,… (`client.ts:147`); LastLedgerSequence=current+40 `:148`; cap 8/account/attempt, overflow carried `:137-139`; submit-no-wait, poll hashes parallel `:170-179`; classifyResult buckets ok/retry/fatal `:85-96` (retryable: terQUEUED/terPRE_SEQ/tefPAST_SEQ/tecINSUFFICIENT_FEE/tel*; fatal throws whole batch); 4 attempts.
- reserves: readReserveRates reads server_state validated_ledger reserve_base/reserve_inc in integer drops `:18-25`; roleReserveDrops = base + inc×peakObjectCount + 2XRP `:84-86`; peakObjectCount `:51-73` (issuer=0, credentialIssuer=credentialedMembers, owner=5+domain+trustline, depositor=cred+trustline+1, borrower=cred+trustline+2).
- engine persistence: store.ts + `packages/engine/prisma/schema.prisma`; models Session/SeatOccupancy/ActionLog; provisioning steps seeded as genesis log `store.ts:138-155`; NO KEYS STORED — token+seed re-derive wallets (`schema.prisma:19-22`, `session-service.ts:164-177`).
- config fields (`config/schema.ts:32-118`): seed(min16)/network/setupId?/asset/withdrawalPolicy/domain.acceptedCredentials[]?(1-10)/coverRateMinimum/coverRateLiquidation/managementFeeRate/coverAmount/debtMaximum/pool{depositors,borrowers}/fundingXrpPerAccount(default30, LEGACY)/bots{seed,borrowerWeights,depositorWeights}. .strict() + liquidation≤minimum superRefine `:108-115`. Example `packages/bootstrap/config.example.json`.
- state reads: readSessionState `state-service.ts:37-105` (account_objects type=vault/loan_broker on owner; type=loan per borrower; type=credential per member vs credentialIssuer; LSF_LOAN_DEFAULTED/LSF_CREDENTIAL_ACCEPTED 0x00010000 `:30-31`). readBalances `balances-service.ts:22-75` (account_info XRP; account_lines peer=issuer IOU; account_objects type=mptoken matched on shareMptId; actNotFound→zero).

## STALE existing docs (supersede, don't copy)
1. `packages/engine/README.md:19-46` route/action table — missing /sessions/stream, /balances, /log, /participants + 3 actions.
2. root `README.md:22-29` layout — lists only shared+bootstrap.
3. `config/schema.ts:80` fundingXrpPerAccount — legacy, superseded by per-role reserves.
4. `bootstrap/README.md` — describes only IOU/permissioned path; XRP+public branches skip steps.
5. AcceptedCredentialSchema.issuer "informational / not yet honored" `config/schema.ts:20-23`.
6. License: root README says "Proprietary" — intended Apache-2.0 relicense is an open gap (no LICENSE file).
