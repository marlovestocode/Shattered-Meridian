# Software Architecture

The canonical system boundaries and folder structure. New systems slot into this shape; don't
invent a parallel structure for a new feature.

## Folder structure

```
ReplicatedStorage/
  Shared/
    Types.lua          -- all type definitions
    Constants.lua       -- all tunable numbers, single source of truth
    NetworkBridge.lua   -- every RemoteEvent/RemoteFunction, defined in one place

ServerScriptService/
  Server/
    Main.server.lua     -- boot sequence, initializes systems in dependency order
    Systems/
      PlayerDataSystem.lua
      TierSystem.lua
      ArtSystem.lua
      BloodlineSystem.lua
      CombatSystem.lua
      AbsorbSystem.lua
      RewardSystem.lua
      ProgressionSystem.lua
      MeridianSystem.lua
      AchievementSystem.lua
      QiDeviationSystem.lua
      RivalrySystem.lua
      BountySystem.lua
      TerritorySystem.lua
      WorldSystem.lua
      AwakeningSystem.lua
    Managers/
      FactionManager.lua
      ArtTreeManager.lua
      BloodlineManager.lua

StarterPlayerScripts/
  Client/
    Main.client.lua
    UI/           -- see ui-ux-philosophy.md for component conventions
    FX/           -- see animation-systems.md for timing/sync rules

Workspace/
  Map/
    SafeZones/ ContestedZones/ VoidFractureZones/ Territories/ MeridianStones/
  HierarchyBoards/
```

## Governing principles

- **Modularity over convenience.** Every system is a ModuleScript. No system reaches into
  another system's internals directly — communication happens through a central registry or
  event bus, never ad hoc `require()`-and-poke. `ProgressionSystem` is this principle's concrete
  instance for player progression specifically — see the dedicated section below.
- **Networking goes through one bridge.** All RemoteEvents/RemoteFunctions are defined in
  `NetworkBridge.lua`. Never scatter remote definitions across systems — this is what keeps the
  network surface auditable and lets `performance-optimization.md`'s call-budget rules be
  enforced in one place.
- **Server owns truth, client owns feel.** Reinforces `engineering-standards.md`'s
  server-authoritative rule at the architecture level: server Systems compute and validate state;
  client UI/FX modules only ever *reflect* it.
- **Boot order matters.** `Main.server.lua` initializes systems in explicit dependency order
  (data layer before anything that reads player data, etc.) — never rely on implicit load order
  from script instancing.

## System ownership map

| System | Owns |
|---|---|
| `PlayerDataSystem` | Canonical player data read/write, DataStore integration |
| `TierSystem` | Tier thresholds, tier-up validation and effects |
| `BloodlineSystem` / `BloodlineManager` | Bloodline awakening, stage unlocks, passive/active application |
| `ArtSystem` / `ArtTreeManager` | Art trees, mastery progression |
| `CombatSystem` | Combat state machine, hit validation, lock-on/parry/posture resolution |
| `AbsorbSystem` | Post-kill absorb mechanics -- computes and applies essence absorption from a confirmed PvP kill, called by `RewardSystem` |
| `RewardSystem` | Reward composition -- decides which reward types a completed gameplay event produces and delegates each type's magnitude to the system that owns it (e.g. `AbsorbSystem` for absorb); coordinates, does not calculate (see "RewardSystem and AbsorbSystem" below) |
| `ProgressionSystem` | Progression orchestration -- routes progression-contributing events to the subsystem that owns the relevant mechanic and triggers milestone checks; coordinates, does not calculate (see "ProgressionSystem: orchestration, not ownership" below) |
| `MeridianSystem` | Meridian XP calculation and balance -- the core progression currency (project-vision.md, progression-systems.md); read by `TierSystem` to evaluate tier-up eligibility (see "MeridianSystem and AchievementSystem" below) |
| `AchievementSystem` | Milestone/achievement definitions and unlock state -- evaluated when `ProgressionSystem` triggers a milestone check after a progression change lands (see "MeridianSystem and AchievementSystem" below) |
| `QiDeviationSystem` | Deviation risk/trigger/consequence |
| `TerritorySystem` / `WorldSystem` | Zone control, region state, hazards |
| `RivalrySystem` / `BountySystem` | Meta-progression social/competitive systems |
| `FactionManager` | Faction membership, standing, faction-gated content |
| `AwakeningSystem` | Human Ascension gate |

## ProgressionSystem: orchestration, not ownership

`ProgressionSystem` is the central coordinator for everything under project-vision.md's first
pillar — fight-to-grow. It's the concrete instance of this file's "communication happens through
a central registry or event bus" principle, scoped to player progression specifically: every
gameplay system that can grant progression reports through it, and every progression subsystem
receives dispatched, filtered progression from it.

It doesn't sit cleanly in the System/Manager split defined above — it's named and folder-located
as a System, but it behaves like a Manager (coordinates other systems rather than owning state of
its own). That's a deliberate, documented exception, not an oversight: progression needs one
narrow-waisted coordination point precisely because so many systems both feed into it (combat,
quests, world events) and read out of it (tier, bloodline, arts), and wiring each of those
systems directly to each other is exactly the ad hoc coupling "modularity over convenience" exists
to prevent.

### Responsibilities

- **Receives progression events** from gameplay systems — PvP victories, boss kills, world
  events, quests, discoveries, and anything else that can plausibly grant a player progression.
- **Determines whether an event actually contributes to progression.** This is a filter, not a
  calculation: the canonical check is project-vision.md's fight-to-grow pillar and
  progression-systems.md's Absorb-system rule that a kill "must always require an actual PvP
  kill, never a non-combat substitute" — ProgressionSystem is where that rule gets enforced
  across *all* progression sources, not just Absorb.
- **Routes accepted events to the subsystem that owns the relevant mechanic** (tier-relevant
  progress to `TierSystem`, bloodline-relevant progress to `BloodlineSystem`, art-relevant
  progress to `ArtSystem`, and so on) via each subsystem's own public API — never by reaching
  into their internal state.
- **Coordinates the progression pipeline; does not calculate it.** ProgressionSystem decides
  *that* an event should become tier progress, bloodline progress, or art mastery, and routes it
  to *who* computes that — it never computes an XP amount, a tier formula, or a bloodline's
  awakening condition itself. The day ProgressionSystem starts computing a number instead of
  routing to the system that owns that number is the day it's quietly become the monolith this
  section exists to prevent.
- **Triggers milestone checks after progression changes are applied.** Once a routed subsystem
  confirms a change landed, ProgressionSystem is responsible for kicking off whatever
  milestone/achievement evaluation follows — it owns *when* that check fires, not the milestone
  definitions or unlock logic themselves.
- **Acts as the single fight-to-grow coordinator.** Any new content type that grants progression
  (a new quest type, a new world event, a new encounter) integrates by reporting to
  ProgressionSystem, not by wiring a new direct path into TierSystem/BloodlineSystem/ArtSystem —
  this is what keeps the fight-to-grow pillar enforceable in one place instead of re-litigated
  per content type.

### Explicitly does NOT own

| Not owned | Owned instead by |
|---|---|
| Combat calculations, damage | `CombatSystem` |
| Meridian XP calculations | `MeridianSystem` |
| Tier formulas | `TierSystem` |
| Bloodline logic | `BloodlineSystem` |
| Martial art / art logic | `ArtSystem` |
| Inventory | Not yet formalized in this file — flag when it's built |
| Economy | Not yet formalized in this file — flag when it's built |
| Persistence | `PlayerDataSystem` |

ProgressionSystem calling into any of the above to *ask* them to compute or apply something is
correct. ProgressionSystem *containing* combat math, an XP formula, a tier threshold, or a
bloodline condition is a boundary violation, full stop — that logic belongs in, and only in, the
system listed above for it.

### Dependencies and communication pattern

- **Inbound.** Gameplay systems call into ProgressionSystem with a progression event (a typed
  payload describing what happened, not a pre-computed reward). This is a direct in-process call,
  not a `NetworkBridge` remote — progression events are server-internal by construction and never
  cross the client/server boundary.
- **Outbound.** ProgressionSystem calls into the owning subsystem's public API to apply the
  progression, then calls into whatever owns milestone checks to trigger evaluation.
- **One-directional by design.** Subsystems that receive routed progression (TierSystem,
  BloodlineSystem, ArtSystem, etc.) apply it and return — they don't call back into
  ProgressionSystem to report their own internal state changes. Milestone checks are triggered by
  ProgressionSystem itself as the last step of the pipeline it just ran, not by a subsystem
  reaching back into it. This avoids the circular event chains that make coordination layers
  unmaintainable.
- **Boot order.** ProgressionSystem's own `Init()` doesn't require the subsystems it routes to be
  initialized first — it registers itself, it doesn't call out during boot. By the time any real
  gameplay event can fire, `Main.server.lua`'s full boot sequence has already brought up every
  subsystem it might route to.

### Typical progression flow

```
CombatSystem
  → RewardSystem
  → ProgressionSystem
  → MeridianSystem
  → TierSystem
  → BloodlineSystem
  → ArtSystem
  → AchievementSystem
```

Reading this: a PvP kill resolves in `CombatSystem`, which hands off *what happened* (not a
reward) to `RewardSystem`, which determines what that outcome grants. `ProgressionSystem` decides
whether that grant is progression-contributing and routes it onward — Meridian XP, tier
progress, bloodline progress, and art mastery each get applied by the subsystem that owns that
slice. ("Martial art logic" in this file's terms is `ArtSystem`'s existing scope, not a separate
module — the two names refer to the same system.) `AchievementSystem` runs the milestone check
ProgressionSystem triggers once those updates land.

Every system named in this flow is now formalized: `RewardSystem` and `AbsorbSystem` below, and
`MeridianSystem` and `AchievementSystem` in the section after that.

## RewardSystem and AbsorbSystem: reward composition vs. mechanic ownership

This resolves the open item raised when `ProgressionSystem` was formalized above. `RewardSystem`
sits between event sources (`CombatSystem` today; other event producers as they're built) and
`ProgressionSystem` in the progression pipeline, and its job could plausibly overlap with
`AbsorbSystem`'s existing "post-kill absorb mechanics" ownership. It doesn't, once the boundary is
drawn the same way `ProgressionSystem`'s is drawn one layer up: **`RewardSystem` composes reward
manifests. It doesn't compute reward magnitudes.**

### Resolution: delegation, not supersession

A confirmed PvP kill produces more than one reward type at once — Meridian XP and absorbed
essence are both named as separate "meaningful gains" in project-vision.md. `RewardSystem` decides
*which* reward types a completed event produces and asks the system that owns each type to
compute (and, where that system already applies its own effect, apply) that type's magnitude:

- **Absorb** — delegated entirely to `AbsorbSystem`, which keeps its existing scope unchanged: it
  computes the essence amount and applies the transfer. `RewardSystem` doesn't duplicate that
  math; it recognizes "this was a PvP kill" and calls into `AbsorbSystem` for the absorb
  component of the reward.
- **Meridian XP** — delegated to `MeridianSystem` (see "MeridianSystem and AchievementSystem"
  below).
- Any future reward type (loot, currency, once those systems exist) follows the same pattern:
  `RewardSystem` recognizes the event, the owning system computes and applies its own slice.

`AbsorbSystem` is untouched by this — same ownership row, same responsibility it always had. What
changes is *who calls it*. Before this section existed, this file never specified how a completed
kill actually reached `AbsorbSystem`; now it's explicit: `CombatSystem` reports the kill to
`RewardSystem`, and `RewardSystem` is the one that calls `AbsorbSystem` — not `CombatSystem`
directly, and not `ProgressionSystem`.

### RewardSystem responsibilities

- Receives completed-event notifications from event-producing systems (`CombatSystem` today; any
  future quest/world-event/discovery system as they're built).
- Determines which reward types a given event is structurally eligible for — a PvP kill is
  absorb-eligible and Meridian-XP-eligible; a non-combat event (a discovery, a quest turn-in) may
  be Meridian-XP-eligible without being absorb-eligible, since absorb is explicitly gated to real
  PvP kills (progression-systems.md). This is a taxonomy check ("does this event shape support
  this reward type"), not the fight-to-grow legitimacy check — that judgment call stays with
  `ProgressionSystem`, so it isn't duplicated in two places.
- Delegates computation (and application, for systems that own both, like `AbsorbSystem`) of each
  reward type to the system that owns it — never computes a reward amount itself.
- Packages the resulting reward types into a single manifest and hands it to `ProgressionSystem`,
  which decides whether/how each component contributes to progression and routes it onward.

### Explicitly does NOT own

| Not owned | Owned instead by |
|---|---|
| Absorb essence calculation and application | `AbsorbSystem` |
| Meridian XP calculation | `MeridianSystem` |
| Whether a reward contributes to progression | `ProgressionSystem` |
| Combat resolution / kill confirmation | `CombatSystem` |

### Dependencies and communication pattern

- **Inbound.** Event-producing systems (`CombatSystem` today) call into `RewardSystem` with a
  completed-event description once the event is confirmed — a kill, not a request to kill. Direct
  in-process call, same as `ProgressionSystem`'s inbound pattern; never a `NetworkBridge` remote.
- **Outbound.** `RewardSystem` calls into each reward-type owner (`AbsorbSystem` for absorb) to
  compute/apply that type, then calls into `ProgressionSystem` with the composed reward manifest.
- **Boot order.** `AbsorbSystem` boots before `RewardSystem` in `Main.server.lua`, since
  `RewardSystem` is the one with the runtime dependency on it, not the reverse.

## MeridianSystem and AchievementSystem: completing the progression flow

The last two links in the typical-progression-flow chain, formalized the same way `RewardSystem`
was above.

### MeridianSystem

Owns Meridian XP calculation and balance — the resource named throughout project-vision.md and
progression-systems.md as the core progression currency ("Tier gates are earned through Meridian
XP from PvP wins"). `ProgressionSystem` routes Meridian-XP-eligible reward components here;
`MeridianSystem` computes the amount and updates the player's balance through `PlayerDataSystem`'s
API (never a direct DataStore write of its own — see `engineering-standards.md`'s data-integrity
rule on a single serialized entry point per player).

`MeridianSystem` does not own tier-up validation itself — `TierSystem` owns that, and reads the
Meridian XP balance from `MeridianSystem` to decide whether a threshold has been crossed. This is
why `MeridianSystem` boots before `TierSystem` in `Main.server.lua`: the resource has to exist
before the system gating on it can meaningfully check it, mirroring the "data layer before
anything that reads player data" pattern this file already establishes for `PlayerDataSystem`.

| Not owned | Owned instead by |
|---|---|
| Tier-up validation and effects | `TierSystem` |
| Canonical persistence | `PlayerDataSystem` |
| Deciding whether an event is progression-eligible | `ProgressionSystem` |

### AchievementSystem

Owns milestone/achievement definitions and unlock state. It doesn't own any of the progression
values it watches — Tier, Bloodline stage, Meridian XP, art mastery all stay owned by the systems
that already own them (`TierSystem`, `BloodlineSystem`, `MeridianSystem`, `ArtSystem`).
`AchievementSystem` reads those values through each owner's public API when `ProgressionSystem`
triggers a milestone check, compares them against milestone definitions, and applies unlock state
for milestones it owns — the same "coordinate/read, don't duplicate state" discipline as every
other cross-cutting system in this file.

| Not owned | Owned instead by |
|---|---|
| The progression values a milestone checks against | Whichever System owns that value (`TierSystem`, `BloodlineSystem`, `MeridianSystem`, `ArtSystem`) |
| Deciding *when* to check milestones | `ProgressionSystem` (triggers the check; `AchievementSystem` evaluates it) |

### Dependencies and communication pattern (both)

- **Inbound.** `ProgressionSystem` calls into `MeridianSystem` with a Meridian-XP-eligible
  progression component, the same way it calls into `TierSystem`/`BloodlineSystem`/`ArtSystem`.
  Separately, `ProgressionSystem` calls into `AchievementSystem`'s milestone-check entry point as
  the last step of a completed pipeline run.
- **Outbound.** `MeridianSystem` writes through `PlayerDataSystem`. `AchievementSystem` reads
  through whichever System owns the value it's checking, via that System's public API.
- **Boot order.** `MeridianSystem` boots before `TierSystem` (see above). `AchievementSystem` has
  no Init()-time dependency on the systems it later reads from — same reasoning as
  `ProgressionSystem`'s own boot-order note.

## Extending the architecture

A new system gets its own ModuleScript under `Systems/` (or a new `Managers/` entry if it's
coordinating other systems rather than owning state), registered in `Main.server.lua`'s boot
order, and added to the ownership table above. Don't fold new responsibilities into an existing
system's file just because it's related — see `future-expansion.md` for the fuller process on
when a new system earns its own module versus extending an existing one.
