---
label: The Four Amendments
order: 90
---

# The Four Amendments

This system is built entirely from four XRPL amendments, chained so that each one's ledger object
becomes the next one's input. Nothing in the chain is enforced by application code — access control,
capital pooling, and loan origination are all native ledger objects and transactions, checked by
consensus. This page is the plain-language on-ramp; each section links to the detailed, cited
protocol page for that amendment, and [Protocol Foundations](../02-protocol/index.md) documents the
exact seams between them with source citations.

## The four amendments, in plain language

### XLS-70 — Credentials: on-ledger identity

A credential is an attestation one account makes about another: an issuer asserts a typed claim
("this account is a verified depositor," for example) about a subject account. The credential does
nothing until the subject affirmatively accepts it — issuance and acceptance are two separate,
two-party transactions. Once accepted, the credential is a durable, native ledger object that other
protocol features can check.

Detail: [XLS-70 — Credentials](../02-protocol/xls70-credentials.md).

### XLS-80 — Permissioned Domains: a membership gate

A Permissioned Domain is a ledger object that lists which credential issuer and credential type pairs
it admits. It doesn't hold funds or users directly — it's a named admission list. Anything else that
references the domain's ID inherits that gate automatically, at the protocol level, with no
application logic evaluating "is this account a member" on the way in.

Detail: [XLS-80 — Permissioned Domains](../02-protocol/xls80-permissioned-domains.md).

### XLS-65 — Single Asset Vault: pooled capital

A vault is a pooled-liquidity object: depositors contribute one asset (XRP, an IOU, or an MPT) and
receive divisible ownership shares in return, represented as MPTokens. A vault can optionally be
created against a Permissioned Domain, in which case only accounts that clear the domain's gate may
deposit or hold shares; a vault created without a domain is open to any depositor.

Detail: [XLS-65 — Single Asset Vault](../02-protocol/xls65-single-asset-vault.md).

### XLS-66 — Lending Protocol: origination

A LoanBroker attaches to a vault and originates loans against its pooled assets. Loan origination is
bilateral: the broker's owner and the borrower must both sign the same transaction — a loan cannot be
created unilaterally. Every broker is backed by first-loss cover capital that absorbs losses before
depositors do, and the broker's owner must be the same account as the vault's owner.

Detail: [XLS-66 — Lending Protocol](../02-protocol/xls66-lending-protocol.md).

## The chain

Read top to bottom, each amendment's output becomes the next amendment's input: **on-ledger identity
gates a vault that funds a lending market.**

```mermaid
flowchart LR
    A["XLS-70 Credentials\nidentity"] --> B["XLS-80 Permissioned Domain\nmembership gate"]
    B --> C["XLS-65 Single Asset Vault\npooled capital"]
    C --> D["XLS-66 Lending Protocol\nloan origination"]
```

- **Identity → domain.** A domain names the same credential issuer and credential type that
  credentials were actually issued under, so it only admits accounts that were genuinely
  credentialed.
- **Domain → gated vault.** A vault created with that domain's ID attached becomes permissioned:
  deposits and share transfers are checked against domain membership by the ledger itself. A vault
  created without a domain is public — anyone may deposit.
- **Gated vault → lending market.** A loan broker attaches to the vault and originates loans against
  its pooled assets, backed by cover capital the broker's owner supplies. The broker and the vault
  must share one owner.

For the full seam-by-seam mechanics — exact fields, transaction order, and the negative-suite proof
that the gate holds at the protocol boundary — see [Protocol Foundations](../02-protocol/index.md).

## Read next

- [Protocol Foundations](../02-protocol/index.md) — the composition chain in full detail, cited to source.
- [XLS-70 — Credentials](../02-protocol/xls70-credentials.md)
- [XLS-80 — Permissioned Domains](../02-protocol/xls80-permissioned-domains.md)
- [XLS-65 — Single Asset Vault](../02-protocol/xls65-single-asset-vault.md)
- [XLS-66 — Lending Protocol](../02-protocol/xls66-lending-protocol.md)
