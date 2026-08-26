# Animation Systems

Governs animation, VFX timing, and their synchronization with combat and ability systems. For
what abilities exist and their balance intent, see `combat-philosophy.md` and
`progression-systems.md`; for performance budgets on effects, see `performance-optimization.md`.

## Core principle

Animation is feedback, not decoration. Every combat-relevant animation (attack windup, parry
window, art cast) must communicate accurate timing information to the opponent — a visually
impressive animation that misrepresents its actual hitbox/parry timing breaks the "reads beat
reflexes" pillar in `combat-philosophy.md`. When animation and hitbox timing must diverge for
gameplay reasons, the visual tell should still land inside a fair reaction window, not after
the fact.

## Pipeline conventions

- All combat animation tracks are pre-loaded on character spawn, not loaded on first use —
  first-cast animation hitching is a bug, not an acceptable cold-start cost.
- Animations are driven through `Animator`/`AnimationTrack`, with `RunService.Heartbeat` used
  for gameplay-timing-critical sync points and `RunService.RenderStepped` reserved for
  purely visual (camera, non-authoritative) work.
- Bloodline- and art-specific visual identity (aura color, particle language, camera behavior)
  should be traceable to that bloodline/art's lore identity in `world-bible.md` — a Celestial
  dragon-vein art and a Demonic corruption art should never share a visual language.

## VFX conventions

- All VFX are object-pooled, never instanced-and-destroyed per use — see
  `performance-optimization.md` for the pooling requirement and budget.
- Region-specific environmental VFX (Void corruption stacks, Demonic geyser warning cues,
  Paradise weather) are implementation-ready specs, not mood-board references — trigger
  conditions, visual/audio cues, and timing should be precise enough for an artist to build
  without follow-up questions.
- Cross-region transition FX exist to make region boundaries in `world-design.md` feel like a
  real shift in the world's physics, not just a texture change.

## Sync with combat state

Every state in the combat state machine (see `software-architecture.md`'s `CombatSystem`
ownership) that has a visible player-facing moment — windup, active frame, recovery, parry
window, posture break — needs a corresponding animation and VFX cue. When a new combat state is
added, animation and VFX coverage for it is not optional polish; it's part of the state's
definition of done.

## Damage numbers and combat feedback

Floating damage numbers and hit-confirm VFX/SFX are part of the animation/feedback layer (see
`ui-ux-philosophy.md` for their visual styling) — they should fire in the same frame as the
server-validated hit confirmation, never optimistically before validation, to avoid
client-perceived hits that the server later rejects.

## Extending this file

As new arts, bloodlines, or regions are added, add their specific animation/VFX identity here
(or in a growing sub-section) so future additions to that lineage stay visually consistent
without needing to re-derive the style from scratch.
