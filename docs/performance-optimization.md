# Performance & Optimization

Budgets and practices that keep a heavy-PvP game with dense combat VFX and frequent network
traffic performant at scale. These are constraints other reference files' recommendations must
fit within.

## Network budget

- Remote calls are batched wherever possible instead of firing one remote per small state
  change — target a hard ceiling on the order of a handful of calls per second per player for
  routine combat traffic (treat roughly 4 calls/sec/player as the budget to design against
  unless a specific system has an approved exception).
  All remotes are defined in `NetworkBridge.lua` per `software-architecture.md`, which is what
  makes this budget auditable in one place rather than scattered across systems.
- Combat-critical remotes (attack requests, parry requests) take priority in that budget over
  cosmetic/UI-sync remotes, which should be throttled first if a player is near the ceiling.

## VFX and instance pooling

- All temporary VFX (particles, hit-effect instances, projectile visuals) are object-pooled,
  never instanced-and-destroyed per use. A combat system generating garbage-collected instances
  every hit is a scaling failure waiting to happen once multiple fights are happening at once.
- Parent pooled/temporary effects under a managed cleanup path (see
  `luau-coding-standards.md`'s object conventions) so nothing leaks silently over a long play
  session.

## Animation loading

Combat animation tracks are pre-loaded on character spawn (see `animation-systems.md`) — no
first-cast hitching from cold-loading an `AnimationTrack` mid-fight.

## Server tick discipline

- Gameplay-critical validation and state resolution belongs on `RunService.Heartbeat`, not
  `RenderStepped` (client-only, non-authoritative) — keep this split enforced consistently
  across systems so server tick cost stays predictable as more systems are added.
- Systems that scan large collections of players/instances each tick (hazard checks, zone
  contest checks) should be budgeted or staggered rather than running a full scan every single
  Heartbeat once player counts scale up.

## Profiling practice

When performance is a concern for a new system, identify the likely cost driver up front
(network volume, VFX instance count, per-tick scan cost) and design the budget into the system
from the start rather than treating optimization as a later pass — a heavy-PvP game with dense
regional hazards (`world-design.md`) and layered combat VFX (`animation-systems.md`) accumulates
cost fast if every new system is designed in isolation.

## Extending this file

As real budgets get measured in production (actual remote call rates, actual instance counts
under load), replace the estimates above with measured numbers and note when/why they changed —
this file should tighten from "reasonable design-time budget" toward "measured production
ceiling" over the life of the project.
