# Four-Amendment Map (XLS recon) — cite these for protocol pages

All four amendments consumed via `xrpl@5.0.0` (verified: every TxType/flag/field the code uses is a real export of that version's models). See XLS-VERIFICATION.md for the 4 spec-confirmed items.

## XLS-65 — Single Asset Vault
Transactions we use (file:line):
- VaultCreate `steps.ts:186` — Asset (XRP `{currency:"XRP"}` or IOU `{currency,issuer}` `:176-178`); permissioned adds `DomainID` + `Flags: tfVaultPrivate(65536)` `:189` + `WithdrawalPolicy: firstComeFirstServe(1)` `:190`. xrpl enforces "DomainID requires tfVaultPrivate".
- VaultDeposit `action-service.ts:79`; also lifecycle/deposit.ts:31, bots depositor-variants.ts:25,63.
- VaultWithdraw `action-service.ts:87`; depositor-variants.ts:36; negative N9 lending.ts:74.
- VaultSet `action-service.ts:134` — sets AssetsMaximum `:138`. Real fields: VaultID, AssetsMaximum?, DomainID?.
- VaultDelete `teardown.ts:46`; negative N7 lending.ts:30 (tecHAS_OBLIGATIONS while broker attached).
- VaultClawback `negative-suite/src/cases/lending.ts:53` (N8, IOU-only, adversarial).
Objects: Vault via `account_objects type:"vault"` (`ledger-lookups.ts:18`, `state-service.ts:107-109`); fields index/ShareMPTID `:21`, AssetsTotal/AssetsAvailable (`state-service.ts:95`, reads.ts:122,155), AssetsMaximum, LossUnrealized, Scale.
SHARES (see XLS-VERIFICATION #4 — CONFIRMED): Scale field default 6 IOU / 0 XRP; first deposit Δshares=Δassets×10^Scale; subsequent PROPORTIONAL Δshares=(Δassets×Γshares)/Γassets rounded down. ShareMPTID captured `steps.ts:196`. Depositor share balance = MPToken matched MPTokenIssuanceID===shareMptId, value MPTAmount, via `account_objects type:"mptoken"` (`balances-service.ts:65-70`, `lifecycle/ledger.ts:33-38`, `bots/reads.ts:15-18`). Total = OutstandingAmount on MPTokenIssuance via `ledger_entry mpt_issuance` (`ingester/state.ts:61-66`).

## XLS-66 — Lending Protocol
Transactions we use:
- LoanBrokerSet `steps.ts:210` — VaultID, ManagementFeeRate `:213`, DebtMaximum `:215`, CoverRateMinimum `:216`, CoverRateLiquidation `:217`.
- LoanBrokerCoverDeposit `steps.ts:247` (seed cover); `action-service.ts:174` (owner adds).
- LoanBrokerCoverWithdraw negative N13 lending.ts:165 (tecINSUFFICIENT_FUNDS below floor).
- LoanBrokerDelete `teardown.ts:41`.
- LoanSet `action-service.ts:203`; lifecycle/originate.ts:42; owner-variants.ts:43 — BILATERAL: owner signs + borrower counter-signs via signLoanSetByCounterparty. Fields LoanBrokerID, Counterparty, PrincipalRequested, InterestRate, PaymentInterval, GracePeriod, LoanOriginationFee (`originate.ts:44-50`).
- LoanPay `action-service.ts:96`; repay.ts:53; bots borrower-variants.ts:23,47,69; negatives N11/N12.
- LoanManage `action-service.ts:164`; owner-variants.ts:84; N14 — defaults via Flags: tfLoanDefault(65536).
- LoanDelete `lifecycle/close.ts:28`; N15 lending.ts:205 (tecHAS_OBLIGATIONS while active).
Objects: LoanBroker via `account_objects type:"loan_broker"` (`ledger-lookups.ts:24,32`, `state-service.ts:47`, `assertions.ts:14-19`); fields CoverAvailable, DebtTotal, DebtMaximum, CoverRateMinimum, Owner. Loan via `account_objects type:"loan"` (`state-service.ts:51`, `bots/reads.ts:25`); fields PaymentRemaining, NextPaymentDueDate, GracePeriod, PrincipalOutstanding, TotalValueOutstanding, PeriodicPayment, Flags (`state-service.ts:53-68`).
Constraints:
- tfLoanDefault=65536 (`action-service.ts:51`, owner-variants.ts:12). Real xrpl LoanManageFlags. tfLoanImpair(131072)/tfLoanUnimpair(262144) exist in spec but WE don't use them.
- tfLoanOverpayment=65536 on LoanPay — N12 observed INVERTED: overpay accepted WITHOUT flag, rejected tecNO_PERMISSION WITH (lending.ts:129-131).
- Time-gated default: defaultable only after NextPaymentDueDate+GracePeriod (`state-service.ts:57-59`, owner-variants.ts:126-130). Premature → tecTOO_SOON (N14). Ripple-epoch offset 946684800.
- Cover-rate math: coverSupports = coverAvailable×100000/coverRateMinimum − DebtTotal; loan ≤ min(vaultAvailable, coverHeadroom, debtHeadroom) (`bots/reads.ts:148-167`). Rates scaled ints 100000=100% (schema.ts:27-30). Invariant coverRateLiquidation≤coverRateMinimum (schema.ts:108-115).
- PaymentInterval/GracePeriod: WE observed temINVALID below 60s (E2E). Spec text documents NO minimum (UINT32 seconds). Document as OBSERVED, not asserted — see XLS-VERIFICATION #3.
- Invariants: single-owner (vault+broker share Owner) `assertions.ts:13-26`; first-loss floor `assertions.ts:31-45`.

## XLS-70 — Credentials
Transactions: CredentialCreate `steps.ts:140` / `action-service.ts:106` (Subject, CredentialType hex from ASCII `ledger-lookups.ts:8-10`); CredentialAccept `steps.ts:150` / `action-service.ts:125` (Issuer, CredentialType; inert until accepted); CredentialDelete `teardown.ts:79` / `action-service.ts:114`.
Object: Credential via `account_objects type:"credential"` (`ledger-lookups.ts:48`, `state-service.ts:82`); Issuer/Subject/CredentialType/Flags. lsfAccepted=0x00010000 CONFIRMED FACT (xrpl.org + XLS-70; set by CredentialAccept; reserve shifts issuer→subject dir on accept). status accepted/pending/none `state-service.ts:87`.
Membership judged vs CREDENTIAL issuer, not currency issuer (`state-service.ts:77-84`). N1-N5 prove tecNO_AUTH boundaries (no cred / wrong type / rogue issuer / revoked / share-to-nonmember).

## XLS-80 — Permissioned Domains
Transactions: PermissionedDomainSet `steps.ts:164` (create, admits credential issuer+type) / `action-service.ts:146` (owner swaps AcceptedCredentials) — AcceptedCredentials:[{Credential:{Issuer,CredentialType}}]; PermissionedDomainDelete `teardown.ts:51`.
Object: PermissionedDomain via `account_objects type:"permissioned_domain"` (`ledger-lookups.ts:13`).
Constraints: DomainID captured `steps.ts:166`, pinned into VaultCreate `steps.ts:189` — presence of domainId is the SOLE permissioned/public switch (`steps.ts:173-174`, `action-service.ts:143`). AcceptedCredentials cap = 1 to 10 CONFIRMED FACT (xrpl.org PermissionedDomainSet + XLS-80; schema `.max(10)` `:53-57`). Domain admits the CREDENTIAL issuer, not currency issuer `steps.ts:156-159`.

## Composition (the chain)
1. Credentials→Domain: PermissionedDomainSet.AcceptedCredentials lists the same credHex/issuer that CredentialCreate grants (`steps.ts:158-164` vs `:136-140`).
2. Domain→Vault: domainId pinned into VaultCreate with tfVaultPrivate (`steps.ts:166`→`:189`). Deposits domain-gated — N1 tecNO_AUTH vs P1 tesSUCCESS public.
3. Vault→Lending: LoanBrokerSet.VaultID attaches broker; single-owner asserted (`steps.ts:210-213`→`assertions.ts:13-26`). Loan principal from vault available, bounded by cover.
4. Provisioning order encodes the chain: issuer flags→credentials→domain→vault→broker→cover.
5. State projection reads all four object families per env (`state-service.ts:44-104`).

## Credential-issuer vs currency-issuer split (design point)
Two distinct derived accounts by design. Role enum `"issuer"|"credentialIssuer"|...` `accounts.ts:8` (rationale `:4-7`). credentialIssuer derived only permissioned `accounts.ts:36,55`. Domain admits credential issuer `steps.ts:156-159`. Membership judged vs credential issuer `state-service.ts:77-84`, `action-service.ts:282-287`. Currency issuer separately mints IOU + clawback/DefaultRipple `steps.ts:82-96,116`.
