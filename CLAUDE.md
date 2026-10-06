# Shattered Meridian — working notes

Roblox Luau project. Rojo-managed, TestEZ specs, selene + stylua gates. Full style rules live in
[`docs/luau-coding-standards.md`](docs/luau-coding-standards.md) (amendments to the studio bible) and
[`docs/ui-ux-philosophy.md`](docs/ui-ux-philosophy.md). Architecture/performance findings are tracked
in dated audits under `docs/architecture/` — read the latest one before a large change, and don't
restate a finding it already covers without re-verifying against current source first (audits date
fast on this branch; most of the tree is uncommitted at any given time).

## Shared modules — reach for these before hand-rolling

Every one of these exists because the pattern it replaces was independently hand-written wrong, or
inconsistently, at 3+ call sites first. If you're about to write one of the patterns on the left,
stop and use the module on the right instead.

| If you're about to... | Use | Not... |
|---|---|---|
| track connections/instances to tear down together | [`Shared/Trove.lua`](src/ReplicatedStorage/Shared/Trove.lua) — `Trove.New()`, `:Add()`, `:Connect(signal, fn)`, `:Extend()` for a nested scope, `:Clean()` | a bare `local conn: RBXScriptConnection? = nil` field that someone has to remember to nil-check and disconnect |
| bind to a player's/local player's successive characters | [`Shared/PlayerLifecycle.lua`](src/ReplicatedStorage/Shared/PlayerLifecycle.lua) — `BindLocalCharacter` (client) / `BindAllPlayers` (server) | raw `CharacterAdded`/`CharacterRemoving`/`Players.PlayerAdded` wiring — it silently loses 3 races: Humanoid-not-replicated-yet, binding on the synchronous boot thread, and a fast respawn during the wait leaving you bound to a corpse |
| build something expensive only for the players who'll use it (admin UI, etc.) | [`Shared/Lazy.lua`](src/ReplicatedStorage/Shared/Lazy.lua) — `Lazy.new(name, buildFn)`, `:Get()`, `:IsResolved()` | building it unconditionally at boot for every player |
| sweep a per-Model table every frame just to drop entries whose Model despawned, with no other per-entry work | [`Shared/AmortizedReclaim.lua`](src/ReplicatedStorage/Shared/AmortizedReclaim.lua) — `AmortizedReclaim.New()`, `:Step(map)` | a full `for key in map do ... end` scan every tick. **Only for reclaim-only sweeps** — a loop that also does per-entry work (advances physics, releases holds, calls `Humanoid:Move`) must keep its full walk; skipping entries there drops a frame of gameplay, not just delays cleanup |
| look up a Model's/Player's Humanoid or HumanoidRootPart | [`Shared/CharacterUtil.lua`](src/ReplicatedStorage/Shared/CharacterUtil.lua) — `HumanoidOf`, `LiveHumanoidOf` (excludes dead), `RootOf`, `LiveRig(player)`; `AwaitHumanoid`/`AwaitRoot` on a bind path, where the part may not have replicated yet (these YIELD — that is why they are separate names and not a flag) | `model:FindFirstChildOfClass("Humanoid")` copy-pasted at the call site, or a `WaitForChild(..., Constants.Network.WaitForChildTimeoutSeconds)` + `IsA` + cast written out per binder |
| find-or-create an Animator to load an AnimationTrack onto | [`Shared/AnimatorUtil.lua`](src/ReplicatedStorage/Shared/AnimatorUtil.lua) — `GetOrCreateAnimator(character)` | duplicating the Humanoid→Animator lookup in every FX/animator module |
| create or resolve a RemoteEvent/RemoteFunction | [`Shared/NetworkBridge.lua`](src/ReplicatedStorage/Shared/NetworkBridge.lua) — owning System calls `Create*` once in `Init()`; both sides call `Get*` at point of use (lookups are memoized, so this is cheap now — no need to hoist into a module-scope cache yourself) | instancing a Remote ad hoc outside the owning System, or hand-rolling a resolution cache |
| rate-limit a RemoteEvent/RemoteFunction handler | [`Shared/RateLimiter.lua`](src/ReplicatedStorage/Shared/RateLimiter.lua) — `RateLimiter.New(maxPerSecond)`, `:IsLimited(player)`, `:Clear(player)` on `PlayerRemoving` | no bucket at all — every public remote in this codebase has one; a new one without it is a gap, not a style choice |
| pcall-wrap a `RemoteFunction.OnServerInvoke` handler so an internal error can't throw across the remote boundary | [`Shared/RemoteHandler.lua`](src/ReplicatedStorage/Shared/RemoteHandler.lua) — `RemoteHandler.WrapInvoke(logger, name, errorResult, handler)`, or `RemoteHandler.Scoped(logger, errorResult)` when a System has many remotes | a bare `pcall(handler, player, ...)` hand-written per System, or a local `wrapHandler` that only differs by baking in the logger and error result (both are already parameters). `ServerHopSystem` is the one real exemption — a `(boolean, string?)` multi-return `WrapInvoke`'s single-`Result` generic cannot express |
| fade a transient surface in and out (an overlay, a banner, a tooltip) | [`UI/Components/Fade.lua`](src/StarterPlayer/StarterPlayerScripts/Client/UI/Components/Fade.lua) — `Fade.New(scope, visible)`, read `.Transparency` (or `.Alpha` to compose with another) | a hand-built `scope:Spring` over a visibility boolean plus an inverting Computed. `Tokens.Motion.FadeSpring` already shared the NUMBERS; three components still wrote the arithmetic. Note what the split encodes: presence is an instant boolean, only appearance eases — springing the visibility itself leaves a half-faded panel still catching input |
| render "the player is on this control" state on an interactive UI primitive | [`UI/Components/Selection.lua`](src/StarterPlayer/StarterPlayerScripts/Client/UI/Components/Selection.lua) — `Selection.New(scope, pressing?)`, read `.Active`, bind its four pre-built handlers | a bare `local isHovering = scope:Value(false)` — every GuiButton here sets `AutoButtonColor = false`, so a control with no `SelectionGained`/`SelectionLost` wiring shows a gamepad player *nothing* as they traverse to it |
| push a value to clients only when it actually changed | [`Shared/ChangeNotifier.lua`](src/ReplicatedStorage/Shared/ChangeNotifier.lua) — `:New()`, `:Update(player, value)` returns whether it changed, `:Clear(player)` | firing a remote unconditionally every tick |
| write to a DataStore | [`Shared/DataStoreRetry.lua`](src/ReplicatedStorage/Shared/DataStoreRetry.lua) — `DataStoreRetry.Scoped(logger, Constants.Storage.RetryPolicy)` once at module scope, then `withRetry(name, fn)` at call sites (`Attempt` directly only if you genuinely need a different policy) | a bare `pcall` around one `SetAsync`/`GetAsync` with no retry, a local `withRetry` that re-binds the same two things, or a fifth copy of the retry numbers in `Constants.lua` |
| resolve a weapon's authored content — the `Workspace.Weapons` folder, an asset id an author pasted, or the Animation in one slot folder | [`Shared/Combat/WeaponAssets.lua`](src/ReplicatedStorage/Shared/Combat/WeaponAssets.lua) — `Container(logger)`, `NormalizeAssetId`, `SlotAnimation`, `ResolveAnimation(logger, weaponId, slot)` | a seventh `Workspace:FindFirstChild("Weapons")`, or a fifth copy of the `rbxassetid://` normaliser (note it handles the legacy asset-URL form too — the three animation copies did not, and would silently pass one through) |
| play a sound tied to a parkour movement state | [`Client/FX/ParkourAudio.lua`](src/StarterPlayer/StarterPlayerScripts/Client/FX/ParkourAudio.lua) — a one-line entry in its `ONE_SHOTS` or `LOOPS` table | a new `<State>Audio.lua` module plus a require in `ParkourController`, a require in `AssetPreloader` and a call in `onTransition` |
| drive a looped sound's volume/pitch from a 0..1 intensity | [`Client/FX/SoundManager.lua`](src/StarterPlayer/StarterPlayerScripts/Client/FX/SoundManager.lua) — `DriveLoop(name, intensity, maxVolume, minSpeed, maxSpeed)`; `RegisterAll(table)` for a run of registrations | a third hand-rolled clamp-scale-lerp |
| add a new server System | Add an entry to [`Server/Config/BootManifest.lua`](src/ServerScriptService/Server/Config/BootManifest.lua) (`Name`, `Path`, `Remotes`) — checked at boot (`AssertBootComplete`) and in `Tests/Boot/BootManifest.spec.lua` | leaving it boot-list-only — a System dropped from `Main.server.lua` or never declared here fails silently: clients `WaitForChild`-timeout one at a time instead of the boot itself erroring |
| size a container by subtracting its siblings' heights from its parent's (`UDim2.new(1, 0, 1, -HEADER_ALLOWANCE)`) | [`UI/Components/Stack.lua`](src/StarterPlayer/StarterPlayerScripts/Client/UI/Components/Stack.lua) — `Stack.New`/`Stack.Row` for the container, `Stack.Fill(scope, child)` to mark the one child that takes what is left (a `UIFlexItem`; works inside ANY `UIListLayout`, not just a Stack's) | a hand-summed allowance constant — it is correct for exactly one set of child heights, and a one-pixel type change invalidates it silently, with no compile error and no runtime error, just a container that clips |
| put a decorative element (a closing rule, a pinned close button, a corner bracket) in a frame that has a `UIListLayout` | [`UI/Components/Layer.lua`](src/StarterPlayer/StarterPlayerScripts/Client/UI/Components/Layer.lua) — `Flow`/`Content` for what the layout arranges, `Over`/`Under` for what is pinned to the container | dropping it in beside the flow children — a `UIListLayout` positions EVERY `GuiObject` child, so it gets swept into the run; this caused three separate bugs in one session |
| make a button for something irreversible (delete, ban, wipe, reset) | [`UI/Components/ArmedButton.lua`](src/StarterPlayer/StarterPlayerScripts/Client/UI/Components/ArmedButton.lua) — first press arms and says so, a second inside `WindowSeconds` commits | a per-screen `isArmed` Value + generation counter; the old admin roster had two of those in one row |
| draw a key the player is being told to press (a bordered well with a mono glyph in it) | [`UI/Components/KeyCap.lua`](src/StarterPlayer/StarterPlayerScripts/Client/UI/Components/KeyCap.lua) — `Tone = "Quiet"` inside a legend, `"Lit"` for the one cap that IS the call to action; `KeyHint` stacks them in a fixed column, `KeyLegend` runs them inline | a Frame + UICorner + UIStroke + mono Label written out per screen — three surfaces did it independently, at two different sizes and two different border weights, before this existed |
| write a `UIPadding` with four `UDim.new(0, ...)` lines | [`UI/Components/Inset.lua`](src/StarterPlayer/StarterPlayerScripts/Client/UI/Components/Inset.lua) — `Inset(scope, Tokens.Space.L)` or `Inset(scope, { X = 20, Top = 12 })` | six lines of boilerplate and four independent places for a typo |
| build a new full-screen modal (tab strip, body, footer, close control) | [`UI/Components/ScreenFrame.lua`](src/StarterPlayer/StarterPlayerScripts/Client/UI/Components/ScreenFrame.lua) — `ScreenFrame.BodySize(w, h)` for the body budget, `NewTabState` for the shared tab Value+Computeds, `Mount` for the frame; pass `Tabs` OR `Title` | hand-rolling a header band, a tab row and a status line per screen — six screens did, which is how the layout bugs above got copied around. `ModalScreen` directly is still right for a differently-shaped panel (a content-sized form, a transient overlay) |
| ease a value toward a target where the OVERSHOOT is the information -- a camera on something heavy, a body braced against acceleration, anything whose job is to say "this has mass and is being pushed" | [`Shared/FlightMath.lua`](src/ReplicatedStorage/Shared/FlightMath.lua) -- `SpringStep(value, velocity, target, frequency, damping, dt)`, returning both as multiple returns | `EaseAlpha` (the right tool for a value with no mass of its own -- it arrives from one side and CANNOT overshoot), or a hand-rolled "ease with a bit of bounce", which is a spring somebody wrote badly. The implicit-Euler form there is also unconditionally stable at any `dt`; the semi-implicit one everybody writes first diverges and flings whatever it drives the first time a hitch exceeds `2/frequency` |
| build a **crewed vehicle** — a tagged hull a player mounts, steers and rides | [`Shared/Vessel/`](src/ReplicatedStorage/Shared/Vessel) + [`Server/Vessel/`](src/ServerScriptService/Server/Vessel) — every module there is a `New(config)` factory you bind once: `VesselTagging` (stations, the model walk, where a body stands and which way that makes the bow), `VesselAssembly` (a pile of anchored meshes → one AlignPosition/AlignOrientation-driven body), `VesselMount` (prompt, reach check, movement lock, weld, ordered release), `VesselArmPose`/`VesselPilotPose` (hands and lean, per-client, `Motor6D.Transform`), `VesselMotion` (the filtered hull sample both feed on), `VesselSpeedLadder`/`VesselSpeedStage` (an engine telegraph / sail rig, and the audio bands), `VesselSafety` (the contact-speed clamp). `Shared/Blimp` and `Shared/Boat` are each one binding of that set plus the parts that really are vehicle-specific | a second copy of any of it. The two vehicles differ in exactly two files each — the drive integrator and the mode machine — and everything else being shared is what keeps a mount cue, a station and a rung one shape on the wire rather than two that drift |
| find who the local player could be fighting (a lock-on pick, an aim assist, a step toward a target) | [`Client/Combat/CombatTargets.lua`](src/StarterPlayer/StarterPlayerScripts/Client/Combat/CombatTargets.lua) -- `All`, `NearestInCone`, `LiveRoot`, plus `YawOf`/`AngleDelta`; the lock-on target itself is `LockOnController.GetTarget()`, and "what would this swing track" is `SwingTracking.PickTarget(root)` | `Players:GetPlayers()` (misses training bots and dummies -- the `Combatant` tag HitboxEngine puts on every registered combatant is the list), or a fourth hand-rolled yaw-from-vector with the sign flipped |
| make a combat layer behave differently for a body standing in a realm (damage, guard, speed, seals, escapes) | [`Shared/Domain/DomainRules.lua`](src/ReplicatedStorage/Shared/Domain/DomainRules.lua) -- `Scale(humanoid, kind)`, `Has(humanoid, flag)`, `IsSealed(humanoid, moveId, traits)`, all read through the realm's `DomainUntil` lease; a new kind is a `DomainTypes.RuleKinds` entry plus one reader | a `require` of `DomainSystem` from a combat layer (it sits ABOVE all four), or a domain-specific branch |
| refund a combatant's network latency (a parry rewind, a swing lead, an air-combo deadline) | [`Server/Combat/NetworkLatency.lua`](src/ServerScriptService/Server/Combat/NetworkLatency.lua) -- `PingSeconds(model)` (a ROUND trip; 0 for a bot or dummy), `SetResolver(fn)` in a spec | a fifth hand-copied `player:GetNetworkPing()` pcall -- four combat modules each carried their own before it existed |
| decide whether two combatants are on the same side, or match a target filter | [`Shared/Combat/Allegiance.lua`](src/ReplicatedStorage/Shared/Combat/Allegiance.lua) -- `AreAllies`, `Matches(filter, owner, target)`, `MatchesType` | a second "is this an ally" check -- there is no party system yet, and this is the one function one will change |
| log inside a module | [`Shared/Logger.lua`](src/ReplicatedStorage/Shared/Logger.lua) — `Logger.scope("ModuleName")`, then `:info/:warn/:error/:debug` | `print`/`warn` directly — scoped logs feed the Live Console (F5) capture ring |

Full rationale for each module (why it exists, what it deliberately does NOT own, the specific bugs
it closes) is in that module's own header comment — read it before extending one, not just before
calling it.

Two more of these live outside `ReplicatedStorage/Shared` because of who's allowed to require them,
not because they're less canonical — the same "reach for this before hand-rolling" bar applies:

- Gating a remote handler behind the admin whitelist (auth check + rate limit + rejection logging)?
  Use [`Server/Network/AdminGate.lua`](src/ServerScriptService/Server/Network/AdminGate.lua) —
  `AdminGate.Check(player, actionName, limiter)` — not a hand-copied `isAuthorized` +
  `checkXPreconditions` pair per System (this exact pair was independently duplicated in three
  Systems before being collapsed here). Lives under `Server/`, not `Shared/`, because it requires
  `Server/Config/AdminConfig.lua`, which must never be reachable from a client-decompilable module.
  Always pass your own `RateLimiterInstance` — it never constructs or defaults one itself.
- Calling `RemoteFunction:InvokeServer(...)` from a client module and turning the result (or a
  thrown error) into a status string? Use
  [`Client/Network/RemoteInvoker.lua`](src/StarterPlayer/StarterPlayerScripts/Client/Network/RemoteInvoker.lua)
  — `RemoteInvoker.Invoke(remote, ...)` returns `(ok, Result...)`; `RemoteInvoker.InvokeAndReport(setStatus, remote, args, describe, errorStatus?)`
  wraps that plus the invoke→describe→setStatus shape every dev-tool client hand-wrote separately —
  not a bare `pcall(function() return remote:InvokeServer(...) end)` at the call site.

## Combat stack layering

`HitboxEngine → DefenseSystem → DamageSystem → AttackRequestSystem` — all four layers are built and
wired (`Main.server.lua` boots them in that order; each `Init()` asserts the layer below is already
available). Each layer is ignorant of the one above it and gets **exactly one narrow upward seam**
into the layer below when it needs something new (e.g. `DamageSystem.DrainGuard` reaching into
`DefenseSystem`'s guard pool). If a change seems to need more than one new seam, the layer boundary
is probably in the wrong place — don't widen the seam to fit it.

`GrabSystem` is a **sibling of `AttackRequestSystem`, not a fifth layer** stacked on top of it — it
subscribes to `DamageSystem.OnApplied` (that function's own documented extension point) and is read by
`AttackRequestSystem.Throw` as a third `CanAttack`-shaped gate, the same way `DefenseSystem.CanAttack`/
`DamageSystem.CanAttack` already are. It boots immediately after `AttackRequestSystem`. Extending combat
with a new interaction kind should default to this sibling shape (subscribe to an existing extension
point, get read through a narrow gate) before assuming it needs to become a fifth stacked layer.

**Projectile moves are delivery, not a fifth layer** (2026-09-30). A move carrying a `Projectile` block
(`Shared/HitboxEngine/ProjectileTypes.lua`) runs the ordinary swing lifecycle, but its Active window
launches a volley that `Server/Combat/HitboxEngine/ProjectileSimulator.lua` flies inside `HitboxEngine`'s
own substep loop; contacts leave through `OnHit` as ordinary `HitReport`s with `HitReport.Projectile`
attached, so block/parry/evade/damage are decided by the existing layers. The defence layer's one
projectile seam is `HitboxEngine.ParryProjectile`/`PassProjectile` — the shot's counterparts of
`CancelAttack` — never cancelling the thrower's current swing unless the move chose `ExistingParry`. A new
projectile behaviour belongs in the simulator or `ProjectileTypes`, not in a layer above.

**Realms (domains) are a sibling, not a fifth layer** (2026-09-30, `docs/design/domains.md`). A move carrying a
`Domain` block (`Shared/Domain/DomainTypes.lua`) opens a realm when `AttackRequestSystem.OnSwingAccepted`
reports its swing; `Server/Combat/Domain/DomainSystem.lua` runs it. It delivers effects only through
existing public entry points (`HitboxEngine.LaunchVolley` -- the realm's one engine seam, with
`SetProjectileBarrier` for closed edges -- `DamageSystem.ExtendHitstun`, `DefenseSystem.DrainGuard`,
`AttackRequestSystem.ThrowMove`), so a strike is blocked/parried/priced/credited exactly as the move it
names. Its RULES reach the layers as Humanoid Attributes through `Shared/Domain/DomainRules.lua` (every rule
read through the `DomainUntil` lease); no combat layer requires `DomainSystem`. A new realm behaviour is a new
effect kind or rule kind there, never a domain-specific branch in a layer.

**Two swings that meet clash** (2026-09-30, `DefenseConstants.Clash`). Two Clean melee hits on each other in one
batch, or a hit on a defender whose own Active volume already reaches the attacker (`HitboxEngine.ActiveSwingReaches`),
resolve as a `Trade` (`OutcomeResolver.ArbitrateClashes`): no damage or stun, both swings cancelled, both pushed
apart, both strings kept. A defender still WINDING UP loses -- a time window would turn every M1 mash-out into a
clash. Player swings are also started half a round trip early (`AttackConstants.Latency`), so "who landed first"
means who pressed first, not who has the lower ping.

**M1s link; the answer is the stun parry** (2026-10-06, `docs/architecture/2026-10-06-combat-feel-pass.md`). A
landed Basic with a next stage stuns until that next hit lands (`DamageConstants.Hitstun.LinkBasicString`,
derived in `AttackCatalog.Get` from the clip-synced timeline -- never hand-type an M1 stun again). A stunned
ground body follows the air combo's held-body rule (`DefenseConstants.StunParry`, `DefenseSystem.parriesThroughStun`):
the guard does nothing, an evade is refused, a timed parry counts and ends the stun (`DamageSystem.endHitstunOf`).
`LinkMarginSeconds` must stay above `Parry.RewindMaxSeconds` -- the rewind hold delays the hit that extends the stun.

**Seams added by the 2026-10-06 consolidation** (`docs/architecture/2026-10-06-combat-consolidation-plan.md`):
- Damage that is not a swing or a shot goes through `DamageSystem.ApplyImpact`, never a bare `TakeDamage`. That keeps
  kill credit, engagement, realm scaling and feedback.
- "Where did this contact come from" is `HitboxTypes.SourceOf(report)` / `IsShot`. Never infer it from `Report.Projectile`.
- A rule that turns a guard off is a `ResolveInput.GuardDisabled` cause. Never patch a result after `OutcomeResolver.Resolve`.
- Post-pricing multipliers live in `DamageResolver.ApplyScales`. Add a stage there, in order.
- Attack presses carry `PressId`. A press that won't throw is answered: `AttackRequestSystem.OnPressRefused`, plus a
  "Refused" `Attack_Cancelled`.
- `Server/Combat/CombatTrace.lua` logs each step to the Live Console (search "CombatTrace"). Read it before guessing
  why a hit resolved the way it did.

`TrainingBotSystem` (`Server/Combat/TrainingBot/`, the AI sparring partner) is the same sibling shape
from the other direction: it only ever acts through the public player entry points
(`AttackRequestSystem.Throw/Feint`, `DefenseSystem.SetBlocking/BeginEvade`) and reads through queries
(`AttackRequestSystem.GetInFlight` is the one it added). If a bot or NPC seems to need a special case
inside a combat layer, the player path is missing a public entry point — add that, not a bot branch.

## Deaths, kill credit and the progression spine

`PlayerDeathSystem` is the **only** publisher of `GameplayEvents.PlayerKilled(victim, killer?, deathId)`
and the only owner of kill credit (it subscribes to `DamageSystem.OnApplied`; DamageSystem never learns
about deaths). Progression from a kill flows `RewardSystem` (eligibility, frozen manifest) →
`ProgressionSystem` (fight-to-grow gate, routes) → the owner's public API (`MeridianSystem.AwardKillXP`
today) → `MeridianXPAwarded` → `TierSystem`. Don't add a new direct `PlayerKilled` subscription that
grants progression — add a reward kind + route instead. The repeat-victim anti-farming weight lives in
that same gate (`ProgressionConstants.RepeatVictim`), so anything that bypasses it is farmable. Bloodline stage-ups and Bounty payouts are the
two known exceptions still to migrate; see
[`docs/architecture/2026-09-28-progression-spine-audit.md`](docs/architecture/2026-09-28-progression-spine-audit.md).

## Before claiming something is "wired" or "done"

Bootstrap tracing (`Main.server.lua`/`Main.client.lua`/`UI/init.lua` call it) proves the app *starts*
it, not that a player can *reach* it. For any new module: `grep -rn "require(.*<Name>)" src/` and
confirm a non-zero inbound-require count from outside its own folder. Zero means dead code no matter
how complete or well-commented the file is (this codebase's header comments describe intended
integration as prose, which reads deceptively like a finished one). For a data/animation path
specifically, follow the SPECIFIC runtime call path a player's action takes end-to-end — two
components independently agreeing with each other is not evidence a third consumer was updated.

## Two build configs — and one asymmetry that will bite you

`default.project.json` ships everything and is what Studio/dev and the test place use.
`live.project.json` is the same tree plus `globIgnorePaths`, omitting two subtrees:
`Client/DevTools/` and `Client/UI/Screens/DevTools/` — 37 files / ~12.5k lines (2026-09-29) of admin-only Luau
that every player's client would otherwise require, parse and closure-build at boot for panels only
a whitelisted admin can open. `Shared/Lazy.lua` already defers the *mount* of those panels and still
does; what it cannot defer is the `require` that produces the Mount function it closes over, which
is what this omission removes. Place file: 6.44 MB → 5.69 MB.

- The two files necessarily carry the same `tree` twice (Rojo has no project inheritance), so
  **run `python scripts/check-live-project.py` after touching either** — it asserts they differ only
  by `globIgnorePaths`.
- **The client seam is two `FindFirstChild` lookups, not a require**: `Main.client.lua` resolves
  `Client/DevTools` and `UI/init.lua` resolves `Screens/DevTools`. `uiHandles.DevTools` is the only
  nil-able field on `UIHandles`, and it is nil in exactly the builds those lookups fail in.
- **A place published from `live.project.json` has no dev tooling for anybody, admins included** —
  F5's Live Console goes too, even though `LiveConsoleSystem`'s own header is explicit that it is
  built to keep working in a live server. That is the trade the split makes *available*; publish
  from `default.project.json` to keep admin tooling in a live place.
- **The server half is NOT the mirror image and must never be omitted.** `MoveEditorSystem.Init`
  (`loadPersistedMoves`/`loadDefaultMoveOverrides`) and `KitEditorSystem.Init` are the only things
  that hydrate `MoveRegistryManager`, `RaceManager` and `BloodlineManager` from DataStore at boot. A
  server without them boots with empty content registries and degrades *quietly* — no error, no
  missing-move warning, just content that was never there. They also cost a player nothing (server
  modules never replicate), which is why they stay in `Server/Systems/`.
- **Moves shipped in source ship in BOTH configs.** `Server/Combat/AuthoredMoves/` (written by the Move
  Editor's Studio-only "Write to source") is ordinary gameplay content under `Server/Combat`, which both
  project files map; `Server/Combat/AuthoredMoveLibrary.lua` loads it from `Main.server.lua`, before
  the combat Inits and independent of any admin System. The helper that writes those files,
  `scripts/move-writer.py`, is dev-only and never part of a build. `MoveEditorSystem` is still required
  in every build for the DataStore content above -- shipped files are an additional layer beneath it
  (a DataStore record/override with the same id wins), not a replacement.
- `Client/Flight/` is the same correction pointing the other way: `FlightController`/`FlightPhysics`
  used to sit under `Client/DevMenu/` and are **not** dev tooling — an admin can grant flight to a
  *non*-admin, whose own client must drive the movement, so they run for every player and stay in
  the live build.

## Toolchain

- **Lint:** `selene src/` — must be 0/0. Needs `selene generate-roblox-std` run once locally first
  (machine-specific, not checked in).
- **Format:** `stylua src/` then `stylua --check src/`. Tree-wide `--check` is **not a reliable gate**
  on this branch — CRLF/LF churn is intermittent (see `stylua.toml`'s `line_endings = "Unix"` vs. the
  Windows CRLF checkout). Prefer `stylua --check` on just the files you touched. If a plain
  `stylua src/` leaves far more files `M` than you edited, diff `git diff --name-only` against your
  edit set and `git checkout --` the rest rather than assuming you broke something.
- **Test:** TestEZ specs under `src/Tests/**/*.spec.lua`. The suite runs on this machine — try it
  before assuming it can't:
  ```
  rojo build test.project.json -o <absolute scratchpad path>.rbxl
  run-in-roblox --place <that path> --script scripts/run-tests.lua
  ```
  Don't pipe the output through `tail` — per-failure assertion detail scrolls off. `test.project.json`
  maps each top-level folder under `Server/` and `Client/` individually (e.g. `Combat`, `Systems`,
  `DevMenu` are each their own `$path` entry) — a new *file* inside one of those already-mapped
  folders (a new System under `Server/Systems`, say) needs no update, but a brand-new top-level
  folder (a new `Server/<Something>` or `Client/<Something>` directory) does, or a broken require only
  surfaces in Studio, not the suite.
- **Strip the BOM on `ParkourConstants.lua` before every build** — something outside Claude Code
  periodically rewrites it with a UTF-8 BOM, which is a hard Luau parse error. ~47 modules require
  `ParkourConstants` directly, so this cascades into most of the combat/parkour require graph failing
  to load and the whole suite silently reporting 0 tests:
  ```
  python -c "p='src/ReplicatedStorage/Shared/Parkour/ParkourConstants.lua'; d=open(p,'rb').read(); open(p,'wb').write(d[3:]) if d.startswith(b'\xef\xbb\xbf') else None"
  ```
- If `run-in-roblox` panics instantly, it's almost always environment/registry skew, not your change
  — see the toolchain notes rather than re-running blind more than once.
