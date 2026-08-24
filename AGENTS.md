# Lansi Codex Provider Manager Instructions

## Authority

1. Follow the user's latest explicit instruction.
2. Use `PRODUCT_CONTRACT.md` as the product completion baseline.
3. Use the approved program design and technical documents as implementation
   references only where they do not weaken the product contract.

## Mainline Execution

- Before product work, name one primary `LCP-*` acceptance ID and the
  user-visible capability the slice will add.
- Prefer a complete native UI-to-persistence-to-switch flow over isolated data
  layers, safety primitives, tests, documentation, CI, or packaging.
- Supporting work is allowed when it directly unblocks or proves the selected
  acceptance ID. It is not a standalone product milestone.
- Two consecutive slices with no user-visible capability delta constitute
  drift; return immediately to the nearest incomplete `LCP-*` flow.
- The current fixed three-Provider applications are prototypes. Do not label
  them Beta or complete.

## Protected State

- Never expose or commit secrets or use a real Codex home as an automated test fixture.
- Preserve sessions, conversation identifiers and content, Skills, plugins,
  MCP configuration, AGENTS instructions, unrelated config, and project state.
- A failed switch must report failure and verify recovery; it may not be
  represented as success.
- Keep the two untracked pre-migration source directories untouched unless the
  user explicitly requests their removal or migration.

## Workflow

- Ordinary single-owner development uses the Fast lane in the current checkout.
- Do not require a new worktree, plan document, task record, PR, reviewer, or
  release operation for each implementation slice.
- Use stronger Git/release governance only for actual concurrent writers,
  formal integration, production-impacting changes, or release publication.
- `确认`, `继续`, and `下一步` never authorize a reduction of `LCP-*` scope.
