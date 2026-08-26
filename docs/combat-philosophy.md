# Combat Philosophy

This file governs the *feel and intent* of combat. For implementation (state machines,
networking, hitboxes), see `software-architecture.md` and `performance-optimization.md`. For
enemy-side behavior, see `ai-design.md`.

## Reference point

Sekiro-grade precision as the baseline feel: lock-on targeting, punishable block, a real parry
window, and a posture meter that makes aggression and defense both viable — not a stamina-drain
turtle simulator, not a pure damage race. Shattered Meridian layers cultivation power (bloodline
passives, arts, tier stats) on top of that combat skeleton, so raw mechanical skill and character
power both matter — see the Skill vs. power balance section below.

## Established systems (do not redesign without explicit request)

- **Lock-on targeting** — combat is target-locked, not free-aim spam.
- **Block / Parry / Disarm** — a formal defensive layer with a punishable timing window for
  parry, not a passive damage-reduction stance.
- **Posture meter** — the resource that turns sustained pressure into an opening, distinct from
  health. Aggression should be able to win through posture even against a healthier opponent.
- **Weapon switching with swap cooldown** — prevents instant weapon-cycling as a combo exploit.
- **Custom shift-lock camera** — combat camera behavior is bespoke, not default Roblox
  behavior.
- **Floating damage numbers, action VFX/SFX** — feedback layer; see `animation-systems.md` for
  timing rules and `ui-ux-philosophy.md` for damage-number presentation.

Full implementation detail for these systems (state machine legality, hitbox timing, weapon
registry) is engineering-owned — pull from the codebase / `software-architecture.md` rather than
re-deriving numbers from scratch.

## Balance principles

1. **Reads beat reflexes at the top, reflexes beat reads at the bottom.** New players should be
   able to win fights on raw reaction. Experienced players should be able to win fights by
   reading habits and baiting mistakes. Both need to stay true across the tier range.
2. **Bloodline and art power should expand a kit's decision space, not just its damage.** A
   bloodline stage that's purely "+X% damage" is underdesigned — see `gameplay-philosophy.md`'s
   anti-pattern on numbers-only progression.
3. **No true unblockable, no true unparryable, without an explicit, telegraphed cost.** Any
   ability that bypasses the core defensive layer needs a long tell, a hard cooldown, or a
   resource cost severe enough that using it is itself a risk.
4. **Corruption and Qi Deviation are the price of raw power**, not a separate minigame. Any new
   high-power tool (Demonic art, forbidden technique) should hook into the existing corruption
   cost model in `progression-systems.md` rather than inventing a parallel downside system.
5. **Skill vs. power balance.** A one-tier gap should be winnable by the better player; a
   multi-tier gap should be very hard but not mathematically impossible, preserving the
   "legible danger, real agency" pillar from `gameplay-philosophy.md`.

## Terrain and combat

Region hazards (see `world-design.md`) should be able to swing a fight — a corrupted zone in
The Void or a demonic geyser should matter tactically, not just visually. When designing new
terrain hazards, always answer: how does this change a fight's positioning, not just its
damage totals?

## Tuning process

Numeric balance changes (damage, cooldowns, posture values) are tuning decisions, not design
decisions — they can move without ceremony. Changes to the systems listed under "Established
systems" above are design decisions and should be flagged as such, with the ripple effects
(animation timing, UI feedback, AI behavior) called out explicitly per `development-workflow.md`.
