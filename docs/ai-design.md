# AI Design

Governs NPC and enemy behavior across all archetypes. Combat feel intent lives in
`combat-philosophy.md`; this file is about how non-player agents make decisions.

## NPC archetype categories

- **Hostile enemies** — target specific factions or all players depending on faction rule
  configuration (supports `"ALL"` targets, empty passive lists, or explicit race/faction lists,
  with runtime faction registration for new factions).
- **Interactable/story NPCs** — dialogue and quest givers, driven by `DialogueSystem` and
  `QuestManager`.
- **Training bots** — player-facing practice opponents with fully configurable behavior weights,
  sent client-side and applied server-side for validation.
- **General-purpose NPCs** — shopkeepers, guards, and other non-combat-primary roles.

## Combat AI decision model

Enemy combat behavior uses weighted action selection (attack / block / parry / dodge /
reposition) rather than a fixed script, so the same enemy archetype can be tuned across
difficulty tiers by adjusting weights rather than rewriting logic. Combo chaining and hitbox
timing follow the same state-machine legality rules as player combat (see
`combat-philosophy.md`), so an enemy never performs an action a player couldn't also be
countering with the standard defensive kit.

Boss-tier enemies use phase transitions layered on top of the same weighted model — a phase
change adjusts the weight table and may unlock phase-exclusive actions, but should never bypass
the core block/parry/dodge counterplay entirely (see the "no true unparryable" rule in
`combat-philosophy.md`).

## Difficulty scaling

Difficulty tiers are expressed as different weight tables and reaction-time parameters on the
same underlying decision model, not as separate hand-authored AI per difficulty. This keeps new
content additions (a new enemy type) automatically compatible with the existing difficulty
ladder.

## Training bots

Training bots exist so players can practice combat mechanics without needing a live opponent.
They support preset modes (attack-only, block-only, parry-only, dodge-only, full-fight,
aggressor, turtle, custom) with per-parameter weights configurable by the requesting client and
validated/applied server-side — training bots must not become a backdoor for
client-authoritative combat state.

## Dialogue and quests

- `DialogueSystem` drives story NPC conversation trees; quest data flows through `QuestManager`
  with a defined schema (see `progression-systems.md` for how quest rewards interact with
  progression, since quests are not a power-granting side door per the fight-to-grow pillar).
- Dialogue and quest content should read in the world-bible voice (see `world-bible.md`) —
  faction NPCs speak with their faction's established identity, not generic fantasy-NPC filler.

## Navigation and world awareness

NPCs use pathfinding with stuck detection for open-world movement, and should respect the
hazard/terrain rules defined in `world-design.md` — an NPC that ignores a region's environmental
hazards breaks immersion and can create unfair fights.

## Extending this file

New AI archetypes (new boss, new NPC role) should be added as a subsection under "NPC archetype
categories" with their decision model described in the same weighted-action terms used above,
so difficulty scaling and combat-legality rules apply automatically rather than needing to be
reinvented per enemy.
