# Progression Systems

The mechanical layer of power growth. Lore meaning of races/bloodlines/factions lives in
`world-bible.md`; this file is where their numbers, gates, and interactions live. This is the
single source of truth for balance-relevant progression math — new content must be reconciled
against it, not designed in isolation.

## Structure of power

Nine power tiers form the backbone all other systems hook into. Tier gates are earned through
Meridian XP from PvP wins (see `gameplay-philosophy.md`'s core loop) and each tier-up should
change *how* a player plays, not just their raw stats (see the anti-pattern in
`gameplay-philosophy.md` against numbers-only progression).

## Races

Four races exist, each with a full passive/active skill kit. When designing or extending a
race's kit, keep faction/race identity mechanically distinct per `world-bible.md`'s faction
guidance (Celestial precision, Demonic risk/reward, Unbound flexibility/fragility). The
**Human Ascension gate** is the mechanism by which a Human can awaken power outside their birth
race — mechanically a distinct unlock path, narratively framed in `world-bible.md` as contested
rather than inherited authority.

## Bloodlines

Thirteen bloodlines, each with:
- A rarity tier
- An awakening condition (a real in-combat achievement, not a purchase or timer — reinforcing
  fight-to-grow)
- A flavor identity tying back to `world-bible.md`
- Staged unlocks (each stage is a new kit tool, not just a number increase)

When a Human awakens a bloodline that "belongs" to another race narratively, the mechanical
awakening condition should be harder or more specific than the native-race condition, reflecting
the "contested authority" framing without making it a lore-only distinction — the difficulty gap
itself should tell the story.

## Qi system

- **Qi types** map to faction/race identity and gate which arts a character can learn.
- **Qi Conflict** — mechanical friction when incompatible qi types are combined (e.g., mixing
  Celestial and Demonic techniques), which should always carry a real risk, not just a soft
  inefficiency, to keep faction identity mechanically meaningful.
- **Qi Deviation** — the failure state for qi misuse or overreach. This is the primary
  "power has a cost" mechanic outside of pure Corruption and should scale in severity with how
  far a player is overreaching their current tier/mastery.

## Arts system

Arts have mastery ranks that improve through use in combat (fight-to-grow, not passive
practice). Art trees are owned by `ArtTreeManager` (see `software-architecture.md`) and should
be designed with the same "each rank changes a decision, not just a number" standard as tiers.

## Absorb system

Post-kill mechanic: defeating another player can grant an absorb of some of their essence. This
is a core fight-to-grow incentive — it must always require an actual PvP kill, never a
non-combat substitute, and should be tuned so it rewards winning real fights without making
losing catastrophically punishing (see `gameplay-philosophy.md`'s anti-pattern on punishing
engagement).

## Corruption

The cost model for Demonic-leaning and forbidden power. New high-power tools that lean Demonic
or forbidden should hook into this existing cost model (per `combat-philosophy.md`) rather than
invent a parallel downside system — Corruption is meant to be legible and consistent across every
system that grants risky power.

## Ascension

The broader system governing the Human Ascension gate and any other cross-race power-claiming
mechanics. Should remain rare and earned — this is one of the most narratively loaded systems in
the game (see `world-bible.md`) and shouldn't be trivialized into a standard unlock.

## Faction alignment and standing

Tracks a player's standing with their faction, feeding into faction-gated content
(`FactionManager` ownership per `software-architecture.md`) and territory contest
(`world-design.md`). Standing changes should primarily come from PvP outcomes relevant to
faction conflict, not passive activity.

## Balance notes and known interactions

Maintain a running list here of known cross-system interaction flags (e.g., "Bloodline X stage 3
+ Art tree Y rank 4 creates an unintended unparryable combo") as they're discovered — this
section is a living balance log, not a one-time write.

## Extending this file

New races, bloodlines, arts, or tiers get added as entries under their existing section
following the established fields (rarity/condition/identity/stages, etc.) so balance review stays
consistent. Big structural additions (a fourth qi conflict type, a tenth tier) should be flagged
against `combat-philosophy.md`'s balance principles before being finalized.
