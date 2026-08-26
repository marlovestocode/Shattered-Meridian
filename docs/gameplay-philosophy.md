# Gameplay Philosophy

## The core loop

Fight → gain Meridian XP / art mastery / possible absorb → grow stronger → seek harder fights.
Everything else in the game (world systems, territory, hierarchy boards, bounties, rivalries)
exists to feed players into that loop more often and with better matchups, not to offer an
alternate path around it.

When designing or evaluating any new system, ask: **does this get a player into a better fight
sooner, or does it let them avoid one?** Systems that answer "avoid one" need rework or a hard
scope boundary (cosmetic-only, social-only).

## What "fun" means here

- **Tension over grind.** A session should feel like a series of stakes-bearing decisions
  (engage this fight? disengage? commit to this art?), not a checklist of dailies.
  Not what this game is: reward pop-ups.
- **Legible danger.** A player should be able to look at an opponent's tier, bloodline, and
  visible aura and make an informed decision about whether to fight. Hidden power is anti-fun
  in a PvP-only progression game because it removes agency from the decision to engage.
  Mysteries live in narrative discovery, not on the fields.
- **Earned swings, not free ones.** Comeback mechanics are fine if they're earned mid-fight
  (reading a parry window, baiting an overextension), not fine if they're a passive stat buff
  handed to whoever is losing.

## Anti-patterns to avoid

- **Power without a fight.** Any mechanic that grants meaningful combat power from
  non-combat activity (login streaks, passive timers, purchases) violates the core pillar in
  `project-vision.md` and should be redirected to cosmetic/QoL rewards instead.
- **Numbers-only progression.** A tier-up or bloodline stage should always change *how* a
  player plays, not just their damage output. If a new unlock is purely a stat bump with no new
  decision it enables, it's underdesigned — send it back through `progression-systems.md` for a
  mechanical hook.
- **Punishing engagement.** Losing a fight should cost something (this is a heavy-PvP game and
  losses should sting) but should never make a player *less able to find another fight* — no
  long lockouts, no permanent stat loss that removes them from viable matchmaking.
- **Snowballing without counterplay.** A winning player should be rewarded, but the game needs
  visible counters to a dominant player (bounties, rivalry escalation, faction response) so the
  server doesn't calcify around one untouchable player. This is a systems-design responsibility
  shared with `progression-systems.md` and `world-design.md` (territory contest).

## Session shape

A good session for a mid-tier player: several PvP engagements of varying stakes, at least one
real decision about faction/bloodline/art commitment, and visible proof of growth (tier
progress, art mastery movement, absorb count) by the time they log off. If a proposed feature
doesn't fit into that shape for a typical session, question whether it belongs in the core loop
or should be scoped as a minor side system.

## Extending this file

Add new anti-patterns here as they're discovered in playtesting or design review — this file
should accumulate hard-won judgment calls over the life of the project, not just restate the
pillars.
