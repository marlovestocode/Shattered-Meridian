# Software Architecture

The canonical system boundaries, folder ownership and data flow, **as the source actually is**. New
systems slot into this shape; don't invent a parallel structure for a new feature.

**This document is revised in the same change as the architecture it describes.** A change that moves
an ownership boundary, adds a System, or reroutes a flow updates the relevant section here in the same
diff. Dated findings and open work live in `docs/architecture/` (latest:
[`2026-09-28-progression-spine-audit.md`](architecture/2026-09-28-progression-spine-audit.md)); this
file is the standing description, not a changelog.

## Folder ownership

```
ReplicatedStorage/Shared/
  <Domain>/                 Damage/, Defense/, HitboxEngine/, Attack/, Grab/, Engagement/, Combat/,
                            Parkour/, Run/, Vessel/, Blimp/, Boat/, Vehicle/, Progression/, Bloodline/,
                            Race/, Kit/, Emotes/, Input/, ...
    <Domain>Constants.lua   replicated, genuinely shared tunables and wire (remote) names
    <Domain>Types.lua       the domain's DTOs/types, shared by server and client
    pure helpers            deterministic math, validation, asset resolution -- no services, no state
  core infrastructure       Trove, PlayerLifecycle, Lazy, AmortizedReclaim, CharacterUtil, NetworkBridge,
                            RateLimiter, RemoteHandler, ChangeNotifier, DataStoreRetry, Logger
  Constants.lua, Types.lua  COMPATIBILITY FACADES -- see "Types and configuration" below

ServerScriptService/Server/
  Main.server.lua           the composition root: explicit, commented, dependency-ordered boot
  Config/                   server-only: AdminConfig, StorageConfig, BootManifest
  Events/GameplayEvents.lua typed server-internal facts; transport only, no policy
  Network/AdminGate.lua     admin auth + rate limit for whitelist-gated remotes (server-only on purpose)
  Combat/                   the four combat layers and their sibling extensions
  Vessel/                   reusable crewed-vehicle mechanics (server half)
  Blimp/, Boat/             the two vehicle-specific halves (drive integrator, mode machine, fuel/water)
  Vehicles/                 vehicle catalog placement helpers
  Systems/                  one bounded player- or world-facing responsibility each
  Managers/                 registries/coordinators with no grab-bag ownership

StarterPlayerScripts/Client/
  Main.client.lua           client composition root (gated boot, below)
  <Domain>/                 input, prediction, local presentation, receiving server DTOs
  UI/                       shell, components, screens (see ui-ux-philosophy.md)
  FX/                       presentation only
  DevTools/                 admin-only; omitted from live.project.json builds
```

## Governing principles

- **Server owns truth, client owns feel.** Every client input is a *request*. Server Systems compute
  and validate state; client modules reflect it. Meaningful progression is earned only from real,
  server-confirmed PvP — never from passive or client-claimed activity.
- **Explicit composition roots.** `Main.server.lua` and `Main.client.lua` boot everything in written
  dependency order, with the reason for each position in a comment above it. No implicit discovery.
  `Server/Config/BootManifest.lua` declares what must boot and what remotes it must produce; it is
  checked at boot (`AssertBootComplete`) and in `Tests/Boot/BootManifest.spec.lua`.
- **Remotes are owned by the System that creates them.** The owning System calls
  `NetworkBridge.Create*` once in `Init`; both sides resolve with `Get*`. Every public handler is
  rate-limited (`RateLimiter`), every `RemoteFunction` is pcall-wrapped (`RemoteHandler`), and
  admin-only ones go through `AdminGate`. Wire names live in the owning domain's Constants.
- **Direct calls for real one-way dependencies; typed events for facts with many consumers.** A System
  may call another's documented public API when the dependency is real and one-directional. A fact with
  several independent consumers, or one where a direct call would form a cycle, goes through
  `Server/Events/GameplayEvents.lua` — a typed registry (named Fire/On helpers per signal), never a
  string-keyed bus. Events carry facts, never decisions or precomputed rewards.
- **One source of truth per state.** `Humanoid.Health` is health; `PlayerDataSystem` is the profile
  (read via `GetProfile` copies, written only via `Transform`); no System shadows another's state.
- **No framework for its own sake.** No service locator, DI container, generic event bus, catch-all
  manager or global replicated store.

## System ownership map

| System | Owns |
|---|---|
| `PlayerDataSystem` | Canonical profile load/save, schema migration, cross-server session lock, the single `Transform` write path |
| `PlayerDeathSystem` | Confirming every player death exactly once per life; kill attribution; sole publisher of `PlayerKilled`; the `Death_Notice` broadcast behind the death overlay and kill feed |
| `RespawnSystem` | Every `LoadCharacter` after the session's first |
| `HitboxEngine` → `DefenseSystem` → `DamageSystem` → `AttackRequestSystem` | The combat stack (below) |
| `GrabSystem`, `EngagementSystem`, `KnockbackAudit` | Combat siblings on `DamageSystem.OnApplied` (grab/throw; the combat tag; detecting clients that ignore knockback) |
| `WeaponInventorySystem`, `WeaponVisualSystem` | Weapon ownership/draw state; the held Tool |
| `RewardSystem` | Reward composition: which reward kinds a confirmed fact is eligible for (immutable manifest) |
| `ProgressionSystem` | The fight-to-grow legitimacy gate (source admission, no self-reward, the repeat-victim anti-farming weight) and routing of manifest components to their owners |
| `MeridianSystem` | Meridian XP amount, balance, replication; publishes `MeridianXPAwarded` |
| `TierSystem` | Tier thresholds and promotion; publishes `TierChanged` |
| `QiSystem`, `QiDeviationSystem`, `EffectSystem` | Qi pool/regen; deviation risk; the generic modifier engine |
| `ArtSystem`/`ArtTreeManager`, `RaceSystem`/`RaceManager`, `BloodlineSystem`/`BloodlineManager`, `KitAbilitySystem` | Kits, arts, races, bloodlines and their shared ability trigger |
| `RivalrySystem`, `BountySystem` | Standings; notoriety streaks and bounty claims |
| `ParkourSystem`, `RunSystem` | Parkour authority/plausibility; the sole `WalkSpeed` writer |
| `BlimpSystem`, `BoatSystem`, `VehicleManager` | The two vehicle bindings; the vehicle catalog/spawn layer |
| `SettingsSystem`, `CharacterSheetSystem`, `CharacterCreationSystem`, `EmoteSystem`/`EmoteUnlockService`, `ServerHopSystem`, `VersionWatchSystem`, `ResourceGatheringSystem`, `BugReportSystem`, `ModerationSystem` | As named |
| `DevMenuSystem`, `MoveEditorSystem`, `KitEditorSystem`, `LiveConsoleSystem`, `AdminActionSystem`, `DebugDummySystem` | Admin tooling (server halves always ship; `MoveEditor`/`KitEditor` Init hydrate content registries) |
| `FactionManager`, `AchievementSystem`, `AbsorbSystem`, `AwakeningSystem`, `TerritorySystem`, `WorldSystem` | **Roadmap placeholders** — empty `Init`, required only by `Main.server.lua`, booted in its PLANNED loop and listed in `BootManifest.Planned`. A spec fails the day one grows an API without moving to a numbered boot step. Design intent lives in their headers. |

## Combat stack

```
HitboxEngine     where the volume is, who is inside it
DefenseSystem    what kind of hit that was (clean, blocked, parried, trade, guard-broken, backstab)
DamageSystem     how much it hurts; hitstun; OnApplied (fires BEFORE the health write)
AttackRequestSystem   the Attack_Request remote; which move a press means; three CanAttack gates
```

Each layer knows only the layers below it and gets **exactly one narrow seam** into the one beneath
(`DefenseSystem.DrainGuard`, `DamageSystem.OnApplied`, the `CanAttack` gates). Heartbeat connection
order is load-bearing and asserted in each `Init`. `GrabSystem` and `EngagementSystem` are **siblings**
subscribing to `DamageSystem.OnApplied`, not a fifth layer; so are `KnockbackAudit` and
`PlayerDeathSystem`'s kill-credit subscription.

**Knockback** is DamageSystem's ("what it does to you"): a landed hit whose move authors a knock
(and no grab) resolves to one world-space launch (`Shared/Damage/Knockback.lua`, clamped by
`DamageConstants.Knockback`) on `DamageResult.Launch` before `OnApplied` fires. A server-owned body is
launched on the server; a player's launch rides the Defender copy of `Combat_Feedback` and is applied by
that client (`Client/Combat/KnockbackClient.lua`) after its hit-stop freeze -- a server write cannot
move a client-owned body. `Attributes.KnockbackUntil` keeps honest launches out of ParkourSystem's
cheater count, and `KnockbackAudit` flags a client that repeatedly does not honour them. New combat interactions default to that sibling shape. There is no `CombatSystem`
module — references to one in older comments describe code deleted by the combat rewrite.

## Deaths and the fight-to-grow spine

```
DamageSystem.OnApplied ──► PlayerDeathSystem (credit: health removed by another present player, same
                                              life, within DamageConstants.KillCredit.WindowSeconds)
Humanoid.Died          ──► PlayerDeathSystem.ConfirmDeath (exactly once per life)
                              │
          GameplayEvents.PlayerKilled(victim, killer?, deathId)
             ├─► RespawnSystem        every death respawns
             ├─► RewardSystem         attributed kills only → frozen RewardManifest
             │      └─► ProgressionSystem.Apply   legitimacy gate → route
             │             └─► MeridianSystem.AwardKillXP → PlayerDataSystem.Transform
             │                    └─► GameplayEvents.MeridianXPAwarded ─► TierSystem ─► TierChanged ─► Qi/Race
             ├─► RivalrySystem, BountySystem   their own standings/streaks
             ├─► BloodlineSystem      interim stage-advancement (to be routed through the spine)
             └─► Blimp/Boat/Emote     cleanup for the dead
```

- `killer` is nil for every unattributed death; a non-nil killer is always a different, still-present
  player. `deathId` is monotonic per server and is RewardSystem's replay guard.
- **RewardSystem composes, ProgressionSystem judges and routes, owners compute.** RewardSystem holds the
  taxonomy (`PvPKill → { MeridianXP }`); ProgressionSystem holds `LEGITIMATE_SOURCES` and the route
  table; the amount lives in `MeridianSystem` (`Constants.Meridian.BaseXPPerKill`). Neither coordinator
  computes a number or owns a remote — a client-requestable grant is what the first pillar forbids.
- A new progression source is a new `RewardSource` **and** a deliberate `LEGITIMATE_SOURCES` entry; a
  new reward kind is a taxonomy entry **and** a route to its owner's public API. Direct subscriptions
  to `PlayerKilled` that grant progression outside this path are debt (Bloodline stage-ups and Bounty
  payouts today — see the dated audit).
- **Anti-farming lives in the gate.** ProgressionSystem weighs each kill by how many times this killer
  has already killed this victim in an open run (`ProgressionConstants.RepeatVictim`, keyed by UserId so
  a rejoin does not reset it) and passes the 0..1 weight to each owner, which scales its own amount. A
  weight of 0 refuses the manifest.
- Deaths are also told to every client (`Death_Notice`): the victim's overlay and everyone's kill feed
  (`Client/Combat/DeathNoticeClient.lua`). The killer's "+N" comes from MeridianSystem's own per-grant
  update, not the notice -- two remotes have no ordering guarantee.
- `AchievementSystem`/`AbsorbSystem` are not called: they have no behaviour yet, and a call into them
  would be a fake check.

## Crewed vehicles (Vessel)

`Shared/Vessel/` and `Server/Vessel/` hold every mechanic two crewed vehicles share, each a
`New(config)` factory bound once: tagging and stations, assembly (anchored meshes → one constrained
body), mounting/release, arm and pilot poses (client-side `Motor6D.Transform`), filtered hull motion,
the speed ladder/stage audio, and the contact-speed clamp. `Blimp` and `Boat` each own exactly the
drive integrator and the mode machine (plus fuel / water). A second copy of any shared piece is a
regression; the next vehicle is one more binding of the same set. `VehicleManager` is the catalog and
meets the vehicle Systems only through a cloned CollectionService tag.

## Client boot gates

`Main.client.lua` runs these in order, each blocking the next:

```
StartMenuClient.Run → LoadingClient.Run (asset preload) → IntroClient.Run (onboarding, first-timers only)
  → UI.Mount → SettingsClient.RestoreSettings → gameplay input/presentation clients → SettingsClient.Start
```

Nothing that can react to a press starts before settings are restored; nothing that needs a UI handle
starts before `UI.Mount` returns. `Client/DevTools` and `UI/Screens/DevTools` are resolved by
`FindFirstChild`, so a `live.project.json` build (which omits them) boots without them.

## Types and configuration

- **Touch-based migration, no sweep.** `Shared/Constants.lua` and `Shared/Types.lua` are compatibility
  facades with ~135 and ~116 consumers. New tunables go in the owning domain's `<Domain>Constants.lua`;
  new types in `<Domain>Types.lua`; server-only names and secrets in `Server/Config/`. When you touch a
  consumer, import the domain module directly; do not add new domain content to either facade.

| Adding... | Goes in |
|---|---|
| a gameplay tunable for one domain | `Shared/<Domain>/<Domain>Constants.lua` |
| a remote name | the owning domain's Constants (`Network.RemoteNames` / `RemoteNames`) and that System's `BootManifest` entry |
| a DTO or domain type | `Shared/<Domain>/<Domain>Types.lua` |
| a server-internal fact | a typed signal in `Server/Events/GameplayEvents.lua` (+ its subscriber inventory) |
| a secret, DataStore name, admin list | `Server/Config/` |
| a pure helper | beside its domain's types/constants in `Shared/<Domain>/` |

## Extending the architecture

A new server System gets its own ModuleScript under `Systems/` (or `Managers/` for a registry), a
numbered, commented step in `Main.server.lua`, a `BootManifest` entry declaring its remotes, and a row
in the ownership table above. It must have a non-zero inbound use from outside its own folder before
it is called wired. A new top-level `Server/` or `Client/` folder needs a `test.project.json` mapping.
See `future-expansion.md` for when a new System earns its own module versus extending one.
