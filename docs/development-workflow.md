# Development Workflow

How work moves from idea to shipped, and how Claude should structure multi-step work on this
project across sessions that don't share memory of each other.

## Design before build

For anything nontrivial (a new system, a new content type, a significant balance change), state
the design decision and its rationale before producing code or final lore text. This is what
lets a future session — or a human reviewer — pick up the thread without re-deriving intent from
implementation alone.

## Classifying a change

- **Tuning** — numeric-only adjustments within existing systems (damage, cooldowns, thresholds).
  Low ceremony; can be done directly, flagged as tuning.
- **Design change** — alters an established system's behavior, adds a new mechanic, or touches
  anything listed as "established" in `combat-philosophy.md` or `software-architecture.md`.
  Requires calling out what it affects downstream before implementing.
  New canon content (race, bloodline, region, faction) — requires checking
  `world-bible.md`/`progression-systems.md` for consistency and updating them as part of the
  same unit of work, not as a follow-up.

## Sequencing large work

When a request implies multiple systems or files, sequence work in dependency order (data layer
before systems that read it, types before implementation, per `engineering-standards.md`) and
deliver in atomic, reviewable units rather than one sprawling change. State the plan up front so
the scope is clear before diving in.

## State and continuity

Because sessions don't retain memory of each other, any nontrivial in-progress design or
implementation work should leave enough written context (in the response itself, or in project
files if working in an environment that persists them) that a fresh session could resume without
re-litigating decisions already made. Treat this skill's reference files as the durable memory of
the project — canon and standing decisions belong here, not just in chat history.

## Review gates

Before calling implementation work done, check it against:
1. Does it match the relevant reference file(s), or does it require updating one?
2. Does it pass the review bar in `engineering-standards.md`?
3. Have downstream effects on other systems been called out?
4. If it's new canon, has `world-bible.md` or `progression-systems.md` been updated to include
   it — not left as an orphaned one-off?

## Versioning canon

When a design decision changes an established one (not just extends it), note what changed and
why in the relevant reference file rather than silently overwriting — a short "superseded"
note is more useful long-term than pretending the old decision never existed, especially for
balance-relevant reversals.

## Extending this file

As real production patterns emerge (a recurring type of request, a recurring failure mode in
how work got sequenced), codify them here so the next similar request follows a known-good
process automatically.
