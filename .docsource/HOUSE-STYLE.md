# House style — every page MUST follow

**Platform is Retype (plain Markdown + HTML), NOT MDX/Docusaurus.**
- NO JSX. Never write `style={{ ... }}` (object syntax) or `<Component />`. It renders as literal text.
- Do NOT wrap tables in `<div style=...>` — Retype styles tables responsively itself. Plain Markdown tables only.
- If you truly need raw HTML, use plain attributes: `<div style="overflow-x:auto">` — but for tables you never need it.

**Front matter** (every page starts with it):
```
---
label: Short Sidebar Label
order: <number>   # higher = earlier in that folder's sidebar
---
```
Then a single H1 `# Page Title`.

**Zero hallucination (the governing rule):**
- Every non-obvious factual claim carries a citation: `` (`file.ts:line`) `` for code, `XLS-NN` or an xrpl.org URL for spec.
- READ the actual source file before citing it — do not trust the recon summaries blindly (they use shorthand paths; the real file is e.g. `packages/engine/src/balances-service.ts`). Cite the bare filename + line.
- If a claim is not verifiable from code or the confirmed-spec list, DESCRIBE WHAT THE CODE DOES / WHAT WE OBSERVED, and do not assert the protocol rule. Use a `> [!NOTE]` or `> [!WARNING]` Retype callout for anything spec-adjacent that isn't confirmed.
- The 4 spec-checked items are settled in `.docsource/XLS-VERIFICATION.md` — 3 are FACT (cite the source given there), 1 (PaymentInterval/GracePeriod minimum) is OBSERVED-ONLY.

**Retype callouts** (use these, not custom HTML):
```
> [!NOTE]
> ...
> [!WARNING]
> ...
> [!TIP]
```

**Voice:** terse, precise, present tense. Audience = protocol-literate engineers + institutional reviewers. No marketing, no emoji, no filler.

**Tables** for anything enumerable (routes, verbs, fields, codes, objects). Code blocks show REAL signatures/shapes copied from source, never invented.

**Internal links:** relative Markdown links to other pages, e.g. `[the action API](../04-api/actions.md)`. Link liberally to the glossary, result-codes, and transaction-map foundation pages.

**Mermaid** is supported by Retype for diagrams (```mermaid fenced blocks) — use for the composition chain, provisioning sequence, request path.
