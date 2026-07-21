# Luau Coding Standards — Project Amendments

This repo follows the Shattered Meridian studio bible's `luau-coding-standards.md` (see the
`shattered-meridian-studio` skill's own reference file for the full style guide: typing,
server/client split, networking conventions, object/instance conventions, comments). This file
exists only to record settled amendments to that guide once the codebase itself has established a
convention the skill's bundled copy doesn't yet reflect — same reasoning as `docs/ui-ux-philosophy.md`
being checked into the repo so decisions like this persist and travel with the code instead of
living only in an external tool's session cache.

## Amendment: `SCREAMING_SNAKE_CASE` is allowed for module-level constant lookup tables

The base style guide says: *"`SCREAMING_SNAKE_CASE` is not used — constants live in `Constants.lua`
as PascalCase table fields."* That rule governs shared, cross-system tunables (cooldowns, damage
multipliers, thresholds) that belong in `Constants.lua` per the single-source-of-truth rule — it was
never meant to police purely internal, module-private lookup tables that have no reason to live in
`Constants.lua` at all (they aren't tunable/shared, just a local dispatch table).

In practice, this codebase has independently and consistently used `SCREAMING_SNAKE_CASE` for exactly
that second category — e.g. `CombatSystem.lua`'s `ACTION_GATES`/`REQUIRED_DEFINITION_NUMBER_FIELDS`,
`DevMenuSystem.lua`'s `HITBOX_CATEGORIES`/`HITBOX_TIMING_FIELDS`/`STANDALONE_ATTACK_NAMES`/
`HITBOX_STANDALONE_FIELDS`/`FLIGHT_TUNING_FIELDS`, `TrainingBotSystem.lua`'s
`PRESET_WEIGHTS`/`VALID_PRESET_NAMES`, `HitboxTuning.lua`'s `CLAMP_MIN_SECONDS`/`CLAMP_MAX_SECONDS`/
`CLAMP_MIN_OFFSET_STUDS`/`CLAMP_MAX_OFFSET_STUDS`/`STANDALONE_ATTACK_NAMES`, `FlightTuning.lua`'s
`FIELD_ORDER`/`FIELD_DISPLAY_NAMES`/`FIELD_LIMITS`, and `HitboxResolver.lua`'s
`DEBUG_PART_LIFETIME`/`DEBUG_PART_COLOR`/`DEBUG_PART_TRANSPARENCY`.

**Rule going forward:** `SCREAMING_SNAKE_CASE` is permitted specifically for a module-level constant
lookup/dispatch table that is private to that module and never a shared tunable (i.e., nothing another
system imports or that a design pass would retune). Anything a second system needs, or any actual
gameplay/balance number, still belongs in `Constants.lua` as a PascalCase field per the base rule —
this amendment doesn't create a second place to hide a tunable. No existing identifiers are being
renamed to comply with this — the amendment codifies what the codebase already does consistently.
