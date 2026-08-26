# World Design

Governs geography, zones, landmarks, hazards, and map-level pacing. Thematic meaning of regions
lives in `world-bible.md`; this file is the buildable spec layer.

## Regions

### The Void
Ethereal, reality-fragmenting nothingness. Environmental identity is built around a
**corruption stack** mechanic — prolonged presence accumulates a stacking status that escalates
risk the longer a fight lingers there, giving the region a built-in "don't overstay" pressure
that rewards decisive PvP over camping.

### The Median Paradise
Lush, contested heartland — the closest region to neutral ground and the one most factions
actually contest, broken into distinct named sub-biomes rather than one uniform landscape.
Dynamic weather on a defined timing cycle is part of its identity, giving it visible rhythm
across a play session rather than static scenery.

### The Demonic Disastrous Landscape
Hellish chaos-zone terrain with active environmental hazards — geysers, corruption creep,
terrain takeover. Every hazard here should have: a trigger condition, a visual/audio warning
cue, a damage value, and clear counterplay. A hazard without a telegraphed warning cue is a
design bug, not a difficulty feature — see `combat-philosophy.md`'s "legible danger" principle,
which extends to terrain as well as opponents.

## Structural spec sections (apply to every region)

When building out or extending a region, cover:

1. **Map overview** — how the region fits into the broader world and travel between regions.
2. **Sub-zone/landmark breakdown** — named locations with a reusable landmark entry template
   (identity, mechanical role, notable features).
3. **Hazard specs** — trigger, warning cue, damage/effect, counterplay, per hazard.
4. **Loot/resource distribution** — how contested a location is should correlate with what it
   offers, reinforcing the fight-to-grow loop rather than offering safe, zero-risk value.
5. **Zone transitions** — how movement between regions/zones is telegraphed and paced.
6. **Spawn and circle/contest logic** — where players enter a region and how contested-zone
   pressure is structured over time.
7. **Implementation checklist** — a developer-facing punch list so a region spec is actually
   buildable, not just descriptive prose.

## Pacing philosophy

Region design should push players toward faction and territory conflict, not away from it —
per `gameplay-philosophy.md`, systems that let players find pure risk-free value anywhere on
the map are anti-patterns. Safe zones exist deliberately and should stay clearly bounded (see
`SafeZones/` in `software-architecture.md`'s Workspace structure) so risk-on/risk-off is always
a legible player choice, not an accident of level design.

## Hazard-combat interplay

Hazards should be able to swing a fight tactically (positioning, forced disengagement, area
denial), not just apply chip damage. Coordinate with `combat-philosophy.md` when a new hazard
is powerful enough to meaningfully alter fight outcomes — that's a balance-relevant addition,
not just an art pass.

## Extending this file

New regions follow the same seven-section structure above. Before adding a region, confirm its
thematic anchor exists (or is added) in `world-bible.md` first — geography follows lore here,
not the other way around.
