# Engineering Standards

Cross-cutting engineering practice, language-agnostic where possible. Luau-specific syntax and
style live in `luau-coding-standards.md`; system boundaries and structure live in
`software-architecture.md`. This file is the "how we build things well" layer between them.

## Non-negotiables

- **Server-authoritative for anything gameplay-affecting.** Damage, tier changes, absorbs,
  currency, inventory, and combat outcomes are computed and validated server-side. Clients
  display state and send *requests*, never facts. This is a security requirement, not a style
  preference — a PvP game with client-trusted combat math will be cheated immediately.
- **No stubs, no placeholder logic, no "TODO: implement later" in delivered work.** If a full
  implementation genuinely can't be completed in one response, say so explicitly and scope what
  was completed versus what remains — don't ship a function that silently does nothing.
- **Validate at every external boundary.** Anything coming from a client, a DataStore read, or
  an external API is untrusted until validated — type-checked, range-checked, and rejected
  loudly (logged, not swallowed) if it fails.
- **One source of truth per value.** Tunable numbers (cooldowns, damage multipliers, tier
  thresholds) live in a single constants module, never duplicated across systems. If two systems
  need the same number, they import it from the same place.
- **Atomic, reviewable units of work.** Prefer delivering one coherent module or system per
  response over sprawling multi-system changes that are hard to review or roll back.

## Error handling philosophy

Fail loudly in development, fail safely in production. A validation failure should never be
silently ignored — log it with enough context to diagnose, and either reject the action
(gameplay-affecting) or degrade gracefully (display-only, e.g., a missing cosmetic asset). Never
let a client-side error corrupt server-held state.

## Data integrity

Player data (tier, bloodline, arts, currency, inventory) is the most valuable asset in the
codebase and the hardest to recover if corrupted. Any system that touches `PlayerDataSystem`
must:

- Never assume a write succeeded without confirmation.
- Never perform two conflicting mutations to the same player's data in the same frame without
  going through a single serialized entry point.
- Treat DataStore failures as expected-but-rare events with explicit retry/backoff handling, not
  edge cases that can be ignored.

## Review bar

Before considering implementation work "done," check it against:

1. Would this survive a live PvP game with players actively looking for exploits?
2. Does every gameplay-affecting code path have server-side validation?
3. Are magic numbers pulled from `Constants`, not hardcoded inline?
4. Does this match the folder/module ownership in `software-architecture.md`?
5. Is there a plan for what happens when a dependency fails (network hiccup, missing asset,
   DataStore timeout)?

## Extending this file

As real engineering pain points surface during development (a specific exploit found, a
DataStore edge case that bit the project once), add them here as a named principle with a short
"why" — this file should read like hard-won studio wisdom, accumulating over years, not a
generic checklist.
