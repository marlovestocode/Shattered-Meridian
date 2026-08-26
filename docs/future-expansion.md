# Future Expansion Guidelines

How Shattered Meridian grows — new races, regions, factions, systems, or entire reference
categories — without breaking canon, architecture, or this skill's own structure. Read this
before proposing anything genuinely new (not an extension of an existing entry).

## Principle: extend, don't fork

New content should slot into an existing reference file's established structure (a new
bloodline follows the existing bloodline fields; a new region follows the seven-section
structure in `world-design.md`). Creating a parallel "new system" that duplicates an existing
one's responsibility is a sign the request should instead be reframed as an extension of what
already exists.

## Checklist for genuinely new content

1. **Does it fit the pillars?** Check against `project-vision.md` first — anything that
   conflicts with fight-to-grow, legible power, or the tone guardrails needs rework before
   anything else happens.
2. **Does it have a lore anchor?** New mechanical systems should be traceable to something in
   `world-bible.md` (the Meridian Particle, an existing faction philosophy, a region's thematic
   wound) rather than arriving as an unmotivated mechanic.
3. **Where does it live mechanically?** Identify which existing system in
   `software-architecture.md`'s ownership map it extends, or whether it genuinely needs a new
   system module (new state, new responsibility not covered by anything existing).
4. **What does it cost?** Per `combat-philosophy.md` and `progression-systems.md`, new power
   sources need a cost model — either hook into Corruption/Qi Deviation or justify a new cost
   mechanic explicitly.
5. **What does it ripple into?** New races/bloodlines affect tier balance math
   (`progression-systems.md`); new regions affect travel and matchmaking
   (`world-design.md`); new UI surfaces need to match the token set
   (`ui-ux-philosophy.md`). Name the ripple before finalizing.

## When a new reference file is warranted

Add a new reference file (rather than a new section in an existing one) when a topic area is
genuinely a new discipline with its own ongoing body of decisions — e.g., if the project adds
voice/audio design, a full economy/marketplace layer, or a matchmaking system substantial enough
to outgrow a subsection of an existing file. When this happens:

- Add the file under `references/` following the existing documentation voice (studio doc, not
  tutorial).
- Add a row to the reference index table in the root `SKILL.md`.
- Cross-link it from any existing file whose scope it overlaps, the same way existing files
  cross-reference each other.
- Do not restructure or rename existing files to accommodate it — this skill is designed so new
  disciplines can be added purely additively.

## When to extend an existing file instead

Default to this. A new bloodline, region, art, hazard, NPC archetype, or UI surface is an
extension of an existing discipline, not a new one — add it inline following that file's
established format.

## Canon conflict resolution

If new content would contradict established canon or a locked design decision (e.g., an
"established system" flagged in `combat-philosophy.md`), surface the conflict explicitly rather
than quietly resolving it one way. The project vision and world bible outrank system-level
decisions; system-level decisions outrank implementation details, per the precedence order in
the root `SKILL.md`.
