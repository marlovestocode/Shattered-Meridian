--!strict
--[[
	Main.server.lua

	Owns: the server boot sequence. Requires every System/Manager module and initializes them in
	explicit dependency order per software-architecture.md ("boot order matters ... never rely on
	implicit load order from script instancing").

	Every numbered step calls boot(name, module) rather than module.Init() directly, and the last line
	of this file checks what actually happened against Server/Config/BootManifest.lua. That is the
	whole reason for the extra name: a System dropped from this list, or renamed out from under it,
	used to produce a server that booted cleanly and was simply missing a feature -- its remotes were
	never created, so its clients waited out a WaitForChild timeout and asserted, one player at a time,
	in a playtest. Half these Systems own no remote at all, so there is nothing to infer their absence
	from; saying so at the call site is what makes it checkable. See BootManifest.lua's own header for
	the other half of the check, which is a spec rather than a runtime assertion.

	The ordering comments below are still the authority on ORDER. The manifest is deliberately not:
	it lists what must boot, never in what sequence, so nothing about adding a System to it can be
	mistaken for a reason to move it in here.
]]

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerRoot = ServerScriptService.Server

local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local EngineLogCapture = require(ReplicatedStorage.Shared.EngineLogCapture)
local Logger = require(ReplicatedStorage.Shared.Logger)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)
local Types = require(ReplicatedStorage.Shared.Types)
local WeaponDefenseAnimations = require(ReplicatedStorage.Shared.Defense.WeaponDefenseAnimations)

local Systems = ServerRoot.Systems
local Managers = ServerRoot.Managers
local Combat = ServerRoot.Combat
local Config = ServerRoot.Config

local BootManifest = require(Config.BootManifest)

local ServerHopSystem = require(Systems.ServerHopSystem)
local VersionWatchSystem = require(Systems.VersionWatchSystem)
local PlayerDataSystem = require(Systems.PlayerDataSystem)
local SettingsSystem = require(Systems.SettingsSystem)
local ResourceGatheringSystem = require(Systems.ResourceGatheringSystem)
local FactionManager = require(Managers.FactionManager)
local MeridianSystem = require(Systems.MeridianSystem)
local QiSystem = require(Systems.QiSystem)
local EffectSystem = require(Systems.EffectSystem)
local TierSystem = require(Systems.TierSystem)
local BloodlineManager = require(Managers.BloodlineManager)
local DefaultBloodlineRegistry = require(Managers.DefaultBloodlineRegistry)
local BloodlineSystem = require(Systems.BloodlineSystem)
local ArtTreeManager = require(Managers.ArtTreeManager)
local ArtSystem = require(Systems.ArtSystem)
local RaceManager = require(Managers.RaceManager)
local RaceSystem = require(Systems.RaceSystem)
local KitAbilitySystem = require(Systems.KitAbilitySystem)
local KitEditorSystem = require(Systems.KitEditorSystem)
local CharacterSheetSystem = require(Systems.CharacterSheetSystem)
local ProgressionSystem = require(Systems.ProgressionSystem)
local AchievementSystem = require(Systems.AchievementSystem)
local QiDeviationSystem = require(Systems.QiDeviationSystem)
local WeaponRoster = require(ReplicatedStorage.Shared.Combat.WeaponRoster)
local MoveRegistryManager = require(Combat.MoveRegistryManager)
local AuthoredMoveLibrary = require(Combat.AuthoredMoveLibrary)
local MovePresentationSystem = require(Combat.MovePresentationSystem)
local PlayerDeathSystem = require(Systems.PlayerDeathSystem)
local HitboxEngine = require(Combat.HitboxEngine.HitboxEngine)
local DefenseSystem = require(Combat.Defense.DefenseSystem)
local DamageSystem = require(Combat.Damage.DamageSystem)
local AttackRequestSystem = require(Combat.Attack.AttackRequestSystem)
local GrabSystem = require(Combat.Grab.GrabSystem)
local AirComboSystem = require(Combat.AirCombo.AirComboSystem)
local EngagementSystem = require(Combat.Engagement.EngagementSystem)
local KnockbackAudit = require(Combat.Damage.KnockbackAudit)
local MovementGuard = require(Combat.MovementGuard)
local EnvironmentReactionSystem = require(Combat.Environment.EnvironmentReactionSystem)
local CombatTrace = require(Combat.CombatTrace)
local DomainSystem = require(Combat.Domain.DomainSystem)
local WeaponVisualSystem = require(Combat.Weapon.WeaponVisualSystem)
local WeaponInventorySystem = require(Combat.Weapon.WeaponInventorySystem)
local ParkourSystem = require(Systems.ParkourSystem)
local RunSystem = require(Systems.RunSystem)
local BlimpSystem = require(Systems.BlimpSystem)
local BoatSystem = require(Systems.BoatSystem)
local VehicleManager = require(Systems.VehicleManager)
local AbsorbSystem = require(Systems.AbsorbSystem)
local RewardSystem = require(Systems.RewardSystem)
local RespawnSystem = require(Systems.RespawnSystem)
local AwakeningSystem = require(Systems.AwakeningSystem)
local TerritorySystem = require(Systems.TerritorySystem)
local WorldSystem = require(Systems.WorldSystem)
local RivalrySystem = require(Systems.RivalrySystem)
local BountySystem = require(Systems.BountySystem)
local BugReportSystem = require(Systems.BugReportSystem)
local AdminActionSystem = require(Systems.AdminActionSystem)
local DebugDummySystem = require(Systems.DebugDummySystem)
local TrainingBotSystem = require(Combat.TrainingBot.TrainingBotSystem)
local ModerationSystem = require(Systems.ModerationSystem)
local DevMenuSystem = require(Systems.DevMenuSystem)
local MoveEditorSystem = require(Systems.MoveEditorSystem)
local LiveConsoleSystem = require(Systems.LiveConsoleSystem)
local CharacterCreationSystem = require(Systems.CharacterCreationSystem)
local EmoteUnlockService = require(Systems.EmoteUnlockService)
local EmoteSystem = require(Systems.EmoteSystem)

local logger = Logger.scope("Boot")

-- Initializes one System and records that it did, for the end-of-boot check on the last line of this
-- file. The name is passed explicitly rather than derived, because a module table has no name at
-- runtime -- and a name derived from the variable it happens to be assigned to would silently stop
-- matching the manifest the first time someone renamed the local.
local function boot(name: string, system: Types.SystemModule): ()
	system.Init()
	BootManifest.MarkBooted(name)
end

-- Explicit boot order -- each comment states the dependency this ordering satisfies.

-- 0. EngineLogCapture connects LogService before anything else below gets a chance to log a boot-
--    time error/warning it should have seen -- see that module's own header. Zero dependency on any
--    other System (it only ever touches Shared/Logger.lua's own always-on capture buffer), so
--    nothing below gates it and it gates nothing below.
EngineLogCapture.Init()

-- 1. ModerationSystem boots FIRST, ahead of even PlayerDataSystem below -- Roblox fires
--    Players.PlayerAdded listeners in the order they connected, and a banned player must be kicked
--    (ModerationSystem's own PlayerAdded handler) before any other System's PlayerAdded handler gets
--    a chance to start writing per-player state for them. This is the one System in this boot
--    sequence whose position is a correctness requirement, not just a dependency-ordering
--    convenience -- see ModerationSystem.lua's own header.
boot("ModerationSystem", ModerationSystem)

-- 2. ServerHopSystem has zero dependency on any other System (it only ever calls TeleportService for
--    a requesting player -- no PlayerDataSystem/CombatSystem/etc. state involved), so nothing below
--    gates it. Boots this early so it's ready as soon as possible -- it's the very first remote a
--    freshly-joined client's Start Menu can call, ahead of everything else in this file.
boot("ServerHopSystem", ServerHopSystem)

-- 2b. VersionWatchSystem also has zero dependency on any other System (it only ever writes its own
--     boot-time game.PlaceVersion into its own DataStore key) -- boots early alongside ServerHopSystem
--     so the shared "highest booted version" key starts converging as soon as possible.
--     DevMenuSystem (step 22) is the one caller with a runtime dependency on it, reading it via
--     GetVersionInfo for the Admin tab's version-mismatch banner.
boot("VersionWatchSystem", VersionWatchSystem)

-- 3. Data layer next: every other System reads/writes player state through PlayerDataSystem.
boot("PlayerDataSystem", PlayerDataSystem)

-- 3b. SettingsSystem's only dependency is PlayerDataSystem immediately above (Transform/GetProfile
--     on Types.PlayerProfile.settings) -- boots here, right next to it, rather than later alongside
--     some unrelated cluster, since nothing else in this sequence needs it running sooner or later.
boot("SettingsSystem", SettingsSystem)

-- 3c. ResourceGatheringSystem's only dependency is also PlayerDataSystem (Transform/GetProfile on
--     Types.PlayerProfile.blimpFuel) -- boots here for the same reason SettingsSystem does. It has no
--     dependency on BlimpSystem (step 12 below) despite feeding the same field: gathering only ever
--     writes a player's own carried total, and BlimpSystem's depositFuel is what reads it later, so
--     which one boots first between them is not a correctness requirement.
boot("ResourceGatheringSystem", ResourceGatheringSystem)

-- 5. Meridian XP is the resource TierSystem's tier-up checks read -- the resource has to exist
--    before the system gating on it can meaningfully check it (software-architecture.md).
boot("MeridianSystem", MeridianSystem)

-- 6. Qi's live resource (current/max, regen) reads profile.tier/attributes straight off
--    PlayerDataSystem, so it only needs step 3 -- placed here, ahead of TierSystem, purely to sit
--    next to MeridianSystem as the other "resource that has to exist before something reads it"
--    boot-order pair, and ahead of QiDeviationSystem (step 11) which is expected to read Qi state
--    through QiSystem's public API once it's built out.
boot("QiSystem", QiSystem)

-- 6b. EffectSystem (Race Traits + Bloodline Abilities plan's generic modifier engine) needs QiSystem
--     immediately above -- its "QiRestore" Instant effect calls QiSystem.Restore -- and nothing else:
--     its own per-player state seeds lazily on first use rather than off PlayerDataSystem, so it has
--     no ordering requirement relative to steps 3-5. Boots here, ahead of TierSystem, so it is already
--     up by the time RaceSystem/RaceManager (a later phase of that plan, not yet built) land in this
--     sequence needing both TierSystem (step 7) and this System already running. Wired but uninvoked
--     this pass -- nothing yet calls Apply/SetBoundModifiers; see EffectSystem.lua's own header.
boot("EffectSystem", EffectSystem)

-- 7. Tier before bloodline/art: awakening and mastery gates read current tier.
boot("TierSystem", TierSystem)

-- 7b. The fight-to-grow spine, now real: PlayerKilled -> RewardSystem (eligibility, immutable manifest)
--     -> ProgressionSystem (legitimacy gate, routing) -> MeridianSystem.AwardKillXP (amount, write,
--     MeridianXPAwarded) -> TierSystem (promotion). Both used to boot as empty Inits in the PLANNED loop
--     at the bottom of this file.
--       * ProgressionSystem AFTER MeridianSystem (step 5): its one route is MeridianSystem's public
--         API, and its Init asserts it. TierSystem needs no ordering against it -- it hears the result
--         through GameplayEvents.MeridianXPAwarded, which has no boot order.
--       * RewardSystem AFTER ProgressionSystem: its Init asserts every reward kind it can compose has a
--         route there. It subscribes to PlayerKilled, which only PlayerDeathSystem (step 12) fires --
--         a runtime relationship through GameplayEvents, so booting before the publisher is correct,
--         and it is up long before any player can land a blow (AttackRequestSystem, step 12).
boot("ProgressionSystem", ProgressionSystem)
boot("RewardSystem", RewardSystem)

-- 8. Registries (Managers) before the per-player Systems that read them.
boot("ArtTreeManager", ArtTreeManager)
boot("ArtSystem", ArtSystem)

-- 8a. RaceManager/RaceSystem (Race Traits + Bloodline Abilities plan) -- same "registry, then the
--     per-player System that reads it" pairing as ArtTreeManager/ArtSystem immediately above, and
--     boots right alongside it for the same reason: nothing else in this sequence needs either
--     running sooner or later. RaceSystem needs TierSystem (step 7) and EffectSystem (step 6b), both
--     already up by here.
boot("RaceManager", RaceManager)
boot("RaceSystem", RaceSystem)

-- 8b. The character sheet's replication layer -- pure projection of PlayerDataSystem's profile out
--     to its owning client, so it needs nothing beyond step 3. Boots here, next to the progression
--     Systems whose own remotes the character menu reads alongside this one, rather than at the
--     bottom with the UI-facing tools: it subscribes to OnProfileLoaded, and a profile that loads
--     before this connects would never push its sheet at all (the Init()-time GetPlayers() sweep in
--     that module is the backstop, not the plan).
boot("CharacterSheetSystem", CharacterSheetSystem)

-- 11. QiDeviationSystem -- promised this slot back at step 6's own comment. Needs QiSystem (step 6)
--     already running so GameplayEvents.OnQiSpent actually fires, and PlayerDataSystem (step 3) +
--     CharacterSheetSystem (step 8b, immediately above) for the Transform/Refresh pair it uses to
--     persist and replicate risk. ArtSystem (step 8) reads THIS System's IsLocked as a third
--     CanUse-shaped gate despite booting first -- safe regardless of relative order, since IsLocked
--     only ever reads a plain module-level table that starts empty at module load, the same
--     pre-Init-safe shape QiSystem.GetQi/GetMaxQi already rely on.
boot("QiDeviationSystem", QiDeviationSystem)

-- 11b. BloodlineManager/BloodlineSystem (Race Traits + Bloodline Abilities plan) -- move out of the
--      "PLANNED SYSTEMS" no-op loop below into a real numbered slot now that both have real Init()
--      bodies. BloodlineSystem is the latest-dependent System this plan has landed so far: it needs
--      QiSystem (step 6) and EffectSystem (step 6b) to spend/apply Qi effects, QiDeviationSystem
--      (immediately above) for its own UseAbility gate, and CharacterSheetSystem (step 8b) to
--      replicate an awakening/stage-advance -- all already up by here. BloodlineManager itself has no
--      dependency (same "registry boots first, needs nothing" shape RaceManager/ArtTreeManager
--      already have) but boots right alongside its one dependent rather than earlier, since nothing
--      else in this sequence needs it running sooner.
boot("BloodlineManager", BloodlineManager)
-- Immediately after, and it must stay that way: this seeds the canon thirteen into the registry
-- BloodlineManager.Init just reset to empty, and BloodlineSystem below reads that registry on its
-- own profile-load pass.
boot("DefaultBloodlineRegistry", DefaultBloodlineRegistry)
boot("BloodlineSystem", BloodlineSystem)

-- 11c. KitAbilitySystem -- the shared Race Trait / Bloodline Stage ability trigger remote. Boots
--      after both RaceSystem and BloodlineSystem immediately above, which is a real ordering
--      requirement here (unlike most "registry, then system" pairs in this file): shipping this
--      remote before either exists would mean a request that always refuses, since Dispatch has
--      nobody real to call into yet.
boot("KitAbilitySystem", KitAbilitySystem)

-- 12. MoveRegistryManager (the Move Creation System's live in-memory move registry --
--     Server/Combat/MoveRegistryManager.lua) boots here -- MoveEditorSystem (step 22b) is what
--     actually populates it from DataStore, and it must already exist (even empty) before that runs.
--
--     HitboxEngine (Server/Combat/HitboxEngine/) is the first piece of the replacement combat layer
--     and boots in the same slot for the same reason. It has no Init()-time dependency on anything --
--     it owns its own Heartbeat, registers combatants on demand, and nothing currently in this
--     sequence reads from it -- so its position here is about where a reader expects combat to start,
--     not about ordering. Init() only registers its phase; a server with nobody registered pays
--     nothing for it.
--
--     ONE COMBAT HEARTBEAT (2026-10-08). The combat Systems from here to DomainSystem no longer connect
--     Heartbeats of their own: each registers its Step as a phase of Server/Combat/CombatTick.lua, which
--     runs them in its PHASES order on one connection, each under its own MicroProfiler label. The FRAME
--     order those Systems need is that list, not the boot order below -- which still matters for the Init-
--     time dependency asserts each one makes. The tick connects when the engine registers, here, so it
--     fires where the first combat Heartbeat always did.
-- 11c. WeaponRoster reads Workspace.Weapons and builds every weapon's stage tables. FIRST of the
--      combat pieces, and that ordering IS a correctness requirement rather than a readability one:
--      DefaultMoveRegistry enumerates this roster to build its MoveId list, and caches that list on
--      first use (see its own enumerateDescriptors header). Boot it after anything that touches the
--      catalogue and the roster is empty at cache time -- every weapon silently has no moves, and
--      every M1 resolves to nothing with no error anywhere.
WeaponRoster.Start()

boot("MoveRegistryManager", MoveRegistryManager)

-- 12-shipped. The moves that ship IN SOURCE (Server/Combat/AuthoredMoves, written by the Move Editor's
--      Studio-only "Write to source") load here: after the registry exists and the roster is built (a
--      shipped retune is laid over a weapon move, so the move has to exist), and before every combat Init
--      below -- AttackRequestSystem's boot warm pass reads the registry and must see them. Gameplay
--      content, so it loads here and never depends on an admin System booting; MoveEditorSystem (22b)
--      still loads the DataStore after it, and a DataStore record with the same id wins.
AuthoredMoveLibrary.Load()

-- 12-presentation. The per-move presentation catalogue (Server/Combat/MovePresentationSystem.lua) -- what a
--      client needs to play a move's authored sounds and effects. Here, beside the registries it reads,
--      but its position is readability only: Init rebuilds from both registries and hears every later
--      write (including MoveEditorSystem's DataStore hydration, step 22b) through their OnChanged seams.
boot("MovePresentationSystem", MovePresentationSystem)

boot("HitboxEngine", HitboxEngine)

--     DefenseSystem is the engine's first consumer -- it turns a contact into a KIND of hit (clean,
--     blocked, parried, traded, guard-broken, backstab) and stops there, applying no damage. Unlike
--     the engine above, ITS POSITION HERE IS A CORRECTNESS REQUIREMENT, not readability: Roblox fires
--     Heartbeat connections in connection order, and DefenseSystem's own Heartbeat resolves the batch
--     of contacts the engine's substeps filled during that same frame. Connected before the engine's,
--     it would resolve every batch a frame late -- invisibly, and only on some boot orders. Its Init
--     asserts the engine is available rather than trusting this comment.
--     SetDefaultParryAnimation is called BEFORE Init() reads defaultParryAnimationId for its own
--     boot-time ParryWindows.ValidateAll warm/warn pass -- see that function's own "spawned rather
--     than awaited" note. The id itself is user-supplied (DefenseConstants.ParryAnimationId's own
--     header); ParryWindows fails closed on it exactly like any other id until it carries authored
--     ParryStart/ParryClose markers.
DefenseSystem.SetDefaultParryAnimation(DefenseConstants.ParryAnimationId)
boot("DefenseSystem", DefenseSystem)

--     DamageSystem is the defence layer's first consumer, and the third and last layer of the combat
--     stack -- it turns a KIND of hit into health lost, guard spent, and a swing interrupted. ITS
--     POSITION HERE IS THE SAME CORRECTNESS REQUIREMENT DefenseSystem's is, one layer further up: its
--     Heartbeat reclaims state stamped by outcomes that DefenseSystem's own Heartbeat produced earlier
--     in the same frame, so it must connect after. Its Init asserts both layers below are available
--     rather than trusting this comment.
--     Note it needs no character binding of its own and has no registry -- see its header on why
--     everything it needs is derivable from the Model an outcome already carries, which is what lets a
--     player, a bot and a dummy share one path with nobody registering any of them.
boot("DamageSystem", DamageSystem)

--     PlayerDeathSystem -- the sole confirmer of player deaths and the sole publisher of
--     GameplayEvents.PlayerKilled, which RespawnSystem (step 15), RewardSystem (step 7b) and
--     RivalrySystem/BountySystem (step 18) all consume. It is NOT a combat layer; it sits here because
--     both edges of its position are real dependencies:
--       * AFTER DamageSystem: it attributes kills by subscribing to DamageSystem.OnApplied, and its Init
--         asserts that layer exists. Booted before it (its old slot, next to MoveRegistryManager), every
--         death would publish killer = nil and the whole fight-to-grow loop would be unreachable.
--       * BEFORE AttackRequestSystem: that is the first System that lets a player land a blow, so the
--         credit subscription must already be listening when it opens. It owns no Heartbeat, so this
--         slot changes nothing about the combat layers' connection-order requirement around it.
boot("PlayerDeathSystem", PlayerDeathSystem)

--     AttackRequestSystem is the fourth and topmost layer -- the one that lets anybody actually throw
--     anything. It owns the Attack_Request remote, resolves which move a press means (SwingSequencer),
--     gates it through BOTH DefenseSystem.CanAttack and DamageSystem.CanAttack, enforces each move's
--     authored Cooldown, buffers a press refused for a reason that clears on its own, and calls
--     HitboxEngine.RequestAttack. It also inherits engine registration from the deleted
--     TestAttackHarness -- HitboxEngine and DefenseSystem keep separate registries by design, and this
--     is now the engine's registrar.
--     ITS POSITION IS THE SAME CORRECTNESS REQUIREMENT as the two layers below, one further up: its
--     Heartbeat flushes buffered presses, which must run after DamageSystem's has reclaimed expired
--     hitstun -- otherwise a press buffered against hitstun is retested against hitstun that has
--     already lapsed, for one extra frame, every time. Its Init asserts all three layers below are
--     available rather than trusting this comment.
--     TestAttackHarness (and its client half) are DELETED as of this System existing, exactly as that
--     module's own header always said they would be.
boot("AttackRequestSystem", AttackRequestSystem)

--     PER-WEAPON PARRY CLIPS ARE WIRED HERE, IN THE BOOT SCRIPT, AND NOWHERE ELSE -- and that is the
--     whole reason this is four lines in Main rather than a require inside DefenseSystem.
--
--     A parry's live window is the ParryStart/ParryClose markers on the parry CLIP
--     (Shared/Defense/ParryWindows.lua -- there is deliberately no window length in DefenseConstants),
--     so a weapon that authors its own Animations/PARRY clip has its own parry TIMING. Which weapon a
--     combatant holds is the ATTACK layer's fact, published on AttackRequestSystem.OnWeaponChanged --
--     the same public extension-point shape WeaponVisualSystem and GrabSystem already subscribe
--     through. But DefenseSystem is the SECOND layer of the combat stack and AttackRequestSystem is
--     the fourth, so DefenseSystem requiring it to ask "what am I holding?" would invert the stack --
--     exactly the widened seam CLAUDE.md's combat-layering rule refuses.
--
--     So the composition root, which legitimately knows every layer, joins the two: Attack publishes,
--     Shared/Defense/WeaponDefenseAnimations resolves, Defense is told. Neither layer gains a require
--     on the other, and the resolver is the SAME one Client/Defense/DefenseClient.lua calls to pick
--     which clip to play -- two callers of one function rather than the server trusting a client-sent
--     id, so what the player SEES and what the server TIMES cannot drift apart.
--
--     The signal fires on every real weapon change -- swap, draw, sheathe -- AND once per character bind
--     (see AttackRequestSystem.OnWeaponChanged), so a fresh life's weapon is covered without a separate
--     spawn hookup here. A nil
--     weaponId (sheathed) resolves to the shared baseline, which is what an unarmed player parries
--     with. SetParryAnimation ignores an unregistered model, so a bind that beats DefenseSystem's own
--     PlayerLifecycle registration costs nothing -- RegisterCombatant seeds the default for the new
--     life regardless, and the next push corrects it.
AttackRequestSystem.OnWeaponChanged(function(character: Model, weaponId: Types.WeaponId?)
	DefenseSystem.SetParryAnimation(character, WeaponDefenseAnimations.GetParry(weaponId))
end)

--     GrabSystem is a SIBLING of AttackRequestSystem, not a fifth layer stacked on top of it -- it
--     subscribes to DamageSystem.OnApplied (the same public extension point that module's own header
--     names as its intended use) and is READ by AttackRequestSystem.Throw as a third CanAttack-shaped
--     gate. Boots immediately after AttackRequestSystem for the same "the layer that actually throws
--     things is booted, so the thing reading its result can be too" readability reasoning, not a
--     correctness requirement -- GrabSystem's own Step only ever reclaims ITS OWN state (holds/
--     flights), so an out-of-order boot costs at most one stale frame rather than a wrong outcome. See
--     that module's own Init() for the one assertion it does make (DamageSystem must be available).
boot("GrabSystem", GrabSystem)

--     AirComboSystem is the next sibling of the same shape (docs/design/air-combat-and-evade.md, Part B):
--     it subscribes to DamageSystem.OnApplied, holds DamageSystem's one air-combo hook slot for the air
--     string's damage scaling, and is READ by AttackRequestSystem.Throw as a fourth CanAttack-shaped gate
--     (and ResolvePress, for what an air attacker's press means). Boots after GrabSystem; its Init asserts
--     the two layers below it are available.
boot("AirComboSystem", AirComboSystem)

--     EngagementSystem is another sibling of the same shape -- it subscribes to DamageSystem.OnApplied
--     exactly as GrabSystem does, and is read by nobody through a require at all: it publishes the
--     AttributeConstants.InCombat seam and its own Engagement_Changed remote, and every consumer
--     (Client/Parkour's combat gate, EmoteSystem's CombatAllowed refusal, the HUD engagement panel)
--     reads one of those two. Boots after GrabSystem for readability, not correctness -- its Step
--     reclaims only its own expired rows.
--
--     WORTH KNOWING WHEN READING A BUG REPORT ABOUT MOVEMENT: this is what re-arms
--     ParkourConstants.CombatGate. Nothing has written the InCombat Attribute since the combat
--     teardown, so Dash/Slide/Roll/Leap/WallRun have effectively been ungated for the whole life of
--     the rebuilt stack. From this boot onward they are refused for
--     EngagementConstants.TagDurationSeconds after every real exchange, which is the documented design
--     intent but is a live change in feel, not just plumbing.
boot("EngagementSystem", EngagementSystem)

--     KnockbackAudit -- a third sibling on DamageSystem.OnApplied, reading the launch DamageSystem
--     resolved onto DamageResult.Launch and watching that a PLAYER's client actually honoured it (a
--     server write cannot move a client-owned body, so the launch is applied client-side and audited
--     here). Readability order, not correctness: it samples on GameplayEvents' shared tick rather than
--     a Heartbeat of its own, so it has no place in the combat layers' connection-order requirement.
boot("KnockbackAudit", KnockbackAudit)

--     MovementGuard -- the speed and teleport check on ENGAGED players (MovementGuardConstants' header: lag-
--     compensated hits test swings against recorded positions, so a client moving itself impossibly would bend
--     hit registration). After EngagementSystem, whose InCombat tag is what it watches, and after HitboxEngine,
--     whose compensation a strike suspends. Samples on GameplayEvents' shared tick, so it has no place in the
--     combat layers' connection-order requirement.
boot("MovementGuard", MovementGuard)

--     EnvironmentReactionSystem -- the wall splat and the swing scuff. A sibling on TWO extension points,
--     DamageSystem.OnApplied (the resolved launch, like KnockbackAudit) and AttackRequestSystem.
--     OnSwingAccepted (a committed swing), reaching down only through DamageSystem.ExtendHitstun. After
--     both, so both subscriptions have something to attach to; its Heartbeat only watches its own rows,
--     so it has no place in the combat layers' connection-order requirement.
boot("EnvironmentReactionSystem", EnvironmentReactionSystem)

--     CombatTrace -- the "why did that attack do that" log (Live Console, scope CombatTrace). A read-only sibling on
--     OnPressRefused, OnSwingAccepted, OnResolved and OnApplied; after all three layers so every one exists. It
--     decides nothing, so its place in the order is for readability only.
boot("CombatTrace", CombatTrace)

--     DomainSystem -- realms (Shared/Domain/DomainTypes.lua's header). A sibling of the attack layer on the
--     same extension point EnvironmentReactionSystem uses (AttackRequestSystem.OnSwingAccepted: a domain
--     move's swing committing is what opens a realm), delivering its effects only through public entry
--     points of the four layers (HitboxEngine.LaunchVolley, DamageSystem.ExtendHitstun, DefenseSystem.
--     DrainGuard, AttackRequestSystem.ThrowMove) and laying down its law as Humanoid Attributes every layer
--     reads for itself (Shared/Domain/DomainRules.lua). AFTER every combat layer and QiSystem (its upkeep),
--     all of which it requires. Its Heartbeat connects after the four layers', which is the order it wants:
--     a strike launched this frame first flies in the engine's next Step, the same as a swing's volley.
boot("DomainSystem", DomainSystem)

--     WeaponVisualSystem is a further sibling, purely cosmetic -- it subscribes to
--     AttackRequestSystem.OnWeaponChanged (the same public extension-point shape GrabSystem's own
--     subscription to DamageSystem.OnApplied established) to keep a Tool matching the combatant's
--     current CombatConstants.Weapons entry (Longsword today) attached to their right hand. Boots
--     immediately after AttackRequestSystem for the same readability reasoning as GrabSystem above --
--     not a correctness requirement, since it owns no per-frame Step and reads no state but the
--     signal it is handed. See its own Init() for the one assertion it makes (AttackRequestSystem must
--     be available).
boot("WeaponVisualSystem", WeaponVisualSystem)

--     WeaponInventorySystem owns the pickup prompts and the draw/sheath toggle. AFTER
--     WeaponVisualSystem, and that ordering is a correctness requirement rather than a readability
--     one: a draw reaches the player's hand THROUGH that System's OnWeaponChanged subscription, so
--     booting this first would leave the first draw of a session mutating the record and drawing
--     nothing visible.
boot("WeaponInventorySystem", WeaponInventorySystem)

-- 12a. Parkour System -- the server authority for the client-side movement framework. Its one
--      integration point is the pair of Humanoid Attributes it stamps (ParkourVelocityOwned, and the
--      ParkourSpeedFloor/Expiry momentum carry), which the WalkSpeed owner in step 12b reads every
--      tick. That is a RUNTIME relationship, not an Init()-time one -- neither System calls the other,
--      so the two may boot in either order -- but they are listed adjacently because reading one
--      without the other makes neither make sense. The one real requirement is ModerationSystem
--      (step 1), since a sustained stream of implausible movement reports routes into its
--      suspected-cheater flag.
boot("ParkourSystem", ParkourSystem)

--      THE EVADE'S FRAMES ARE WIRED HERE, for the reason the per-weapon parry clips above are: the
--      boot script is the one place that legitimately knows both sides. ParkourSystem publishes an
--      ACCEPTED action (its OnActionStarted runs after the plausibility gate), DefenseSystem owns what a
--      contact means, and neither requires the other -- DefenseSystem is the second layer of the combat
--      stack and has no business knowing parkour exists, and ParkourSystem has none knowing combat
--      does. The accepted Evade report IS the trigger, so evasion costs no new remote (the N1 remote
--      budget in docs/architecture). BeginEvade applies its own body gates and may refuse; a refused
--      evade leaves the glide a glide that simply gets hit.
ParkourSystem.OnActionStarted(function(player: Player, kind: ParkourTypes.ActionKind, now: number)
	if kind ~= "Evade" then
		return
	end
	-- Combat only: an evade reported outside an engagement opens no frames (States/Evading.CanEnter's
	-- own rule, re-checked against the server's tag rather than trusted from the client).
	if not EngagementSystem.IsInCombat(player) then
		return
	end
	local character = player.Character
	if character then
		-- A LANDED swing's recovery may be cut into the evade (AttackConstants.HitConfirm). Cut first, so
		-- BeginEvade's own "not mid-swing" gate sees a free body. A no-op for anything else.
		AttackRequestSystem.CancelRecoveryForEvade(character, now)
		DefenseSystem.BeginEvade(character, now)
	end
end)

-- 12b. Run System -- the WalkSpeed owner, and the authority for the three-stage run. Takes over the
--      per-Heartbeat WalkSpeed resolver that CombatSystem.onHeartbeat used to drive through
--      Server/Combat/Movement.ComputeDesiredWalkSpeed; with CombatSystem deleted by the combat
--      rewrite, nothing drove that resolver, so nothing wrote WalkSpeed at all and no run stage was
--      ever published. (That resolver has since been deleted along with its CombatTypes.lua -- this
--      System is now the only WalkSpeed writer in the tree, not merely the live one.) See this System's own header for the full ownership argument.
--
--      Boots after ParkourSystem purely so the pair reads in dependency order (the run's resolver
--      reads Attributes the parkour System stamps). It requires no System's API at Init() time and
--      would boot correctly anywhere in this sequence; its only genuine ordering constraint is that
--      it must run before any System that expects a seeded BonusWalkSpeed Attribute, and nothing
--      currently does.
boot("RunSystem", RunSystem)

-- 12c. Blimp System -- world vehicles. Boots after RunSystem because the mount's WalkSpeed lock is one
--      more Attribute tier in RunSystem.isMovementLocked, and a mount that landed before that resolver
--      existed would pin a player at speed 0 with nothing running to let them go again. Owns its own
--      per-Heartbeat drive via GameplayEvents.OnHeartbeatTick, and discovers its models from
--      CollectionService tags at Init -- so a blimp added to the place after this line still registers,
--      and a place with no blimps in it boots this System to an empty registry at no cost.
boot("BlimpSystem", BlimpSystem)

-- 12d. Boat System -- the same class of thing as the Blimp System immediately above, sharing its whole
--      mount/assembly/telegraph layer through Shared/Vessel + Server/Vessel and differing only in the
--      drive (sail and wind rather than throttle) and the mode machine. Boots after RunSystem for the
--      identical reason BlimpSystem does -- the mount's WalkSpeed lock is one more Attribute tier in
--      RunSystem.isMovementLocked -- and after BlimpSystem purely so the two vehicle Systems read in
--      one block; neither requires the other and the order between them is free.
--
--      Its Init also starts Server/Boat/BoatWater.lua's tag watch, which is what gives every boat in
--      the place a surface to float on. A world with no tagged water still boots; the first boat
--      registered into it says so once in the log.
boot("BoatSystem", BoatSystem)

-- 12e. Vehicle Manager -- the vehicle CATALOG (which vehicles exist, spawning and despawning them),
--      not any vehicle's behaviour. Boots immediately after BlimpSystem because that ordering is the
--      one real constraint it has: a spawn parents a clone whose builder-authored tags fire
--      BlimpSystem's (or BoatSystem's) own GetInstanceAddedSignal, so the System that answers that
--      signal has to already be listening. Nothing in this file's Init() calls into either -- they
--      share no require in any direction, only the tag (see VehicleManager.lua's own header).
boot("VehicleManager", VehicleManager)

-- 12b. Emote System -- EmoteUnlockService only needs PlayerDataSystem (step 3), but boots here,
--      immediately alongside its one dependent, rather than earlier: nothing else in this sequence
--      needs it running sooner. EmoteSystem needs both PlayerDataSystem (persistence) and
--      EmoteUnlockService (HasUnlocked/GetUnlockedIds gates on RequestPlay/RequestSetLoadoutSlot),
--      so it boots last of the two.
boot("EmoteUnlockService", EmoteUnlockService)
boot("EmoteSystem", EmoteSystem)

-- 15. RespawnSystem subscribes to GameplayEvents.OnPlayerKilled, which only PlayerDeathSystem (step 12,
--     after DamageSystem) ever fires. GameplayEvents itself has no boot order, so this is a statement
--     of where the publisher is, not an ordering requirement. It owns every Player:LoadCharacter() call
--     EXCEPT the session-first one CharacterCreationSystem makes at step 23 -- see its own header
--     for why Players.CharacterAutoLoads = false makes that ownership split load-bearing.
boot("RespawnSystem", RespawnSystem)

-- 18. Meta/social systems read PvP kill outcomes off GameplayEvents.OnPlayerKilled (PlayerDeathSystem,
--     step 12, fires it with an attributed killer -- see that module's header) and player state from
--     PlayerDataSystem. They are consumers of the confirmed fact ALONGSIDE RewardSystem (step 7b), not
--     part of its progression spine: standings and streaks are theirs to keep.
boot("RivalrySystem", RivalrySystem)
boot("BountySystem", BountySystem)

-- 20. Bug reports are independent of every gameplay System above (own DataStore, own public
--     remote) but boot before the whitelist-gated dev tooling that triages them --
--     DevMenuSystem's ListBugReports/UpdateBugReportStatus handlers call straight into
--     BugReportSystem's public API -- "boots before its one dependent."
boot("BugReportSystem", BugReportSystem)

-- 21. AdminActionSystem owns its own independent Players.PlayerAdded/CharacterAdded wiring (no
--     runtime dependency on any other System above) -- boots before DevMenuSystem,
--     which is the one with the runtime dependency on it (its SetTargetGodmode/SetTargetFlight/
--     SetTargetFlightCollide/SetTargetFrozen/SetTargetInvisible/SetTargetSpeedMultiplier/
--     TeleportToTarget/BringTarget/TeleportToCoordinates handlers call straight into it).
boot("AdminActionSystem", AdminActionSystem)

-- 21b. DebugDummySystem -- a real, fully-registered HitboxEngine/DefenseSystem combatant, spawnable
--      only through the whitelist-gated Spawn tab (DevMenuSystem.handleSpawnDebugDummy below), so it
--      boots alongside AdminActionSystem rather than earlier: nothing above needs it running sooner,
--      and its own Init() asserts DamageSystem (step 12) is already available regardless of exactly
--      where in this back half of the sequence it lands. See that module's own header for why it owns
--      no Heartbeat and therefore has no connection-order requirement the way the four layers below it
--      do.
boot("DebugDummySystem", DebugDummySystem)

-- 21c. TrainingBotSystem -- the AI sparring partner (Server/Combat/TrainingBot). A SIBLING of the attack
--      layer that plays by its rules: it acts only through AttackRequestSystem.Throw/Feint and
--      DefenseSystem.SetBlocking/BeginEvade, and learns through DamageSystem.OnApplied. Unlike
--      DebugDummySystem it DOES own a Heartbeat, and ITS POSITION IS A CORRECTNESS REQUIREMENT: that
--      Heartbeat reads attack/defence state all four combat layers wrote earlier in the same frame, so it
--      must connect after every one of them (step 12's block) -- anywhere down here satisfies that, and
--      its Init asserts the layers exist. Spawnable only through the whitelist-gated Spawn tab
--      (DevMenuSystem, step 22), so a server nobody spawns one on pays one empty loop per frame.
boot("TrainingBotSystem", TrainingBotSystem)

-- The server's own frame numbers for the client's F3 overlay (Constants.Debug.FpsCounter.ServerStats).
-- Not a System and not in BootManifest: no remote, no gameplay state, nothing reads it but that overlay.
require(script.Parent.Diagnostics.ServerFrameStats).Start()

-- 22. Whitelist-gated dev tooling boots last -- its
--     ListBugReports/UpdateBugReportStatus handlers call BugReportSystem, its
--     SetTargetGodmode/SetTargetFlight/SetTargetFlightCollide/etc. handlers call AdminActionSystem,
--     its SpawnDebugDummy/DespawnAllDebugDummies/SetDummyGuard/GetDebugDummyState handlers call
--     DebugDummySystem (step 21b above), its SpawnTrainingBot/DespawnTrainingBots handlers call
--     TrainingBotSystem (step 21c above), its KickPlayer/BanPlayer/MutePlayer handlers call
--     ModerationSystem (already booted first, step 1), and its RollEmote handler calls
--     EmoteUnlockService (already booted at step 12b) -- so it needs all of them already running, and
--     nothing else in the boot sequence depends on DevMenuSystem existing first.
boot("DevMenuSystem", DevMenuSystem)

-- 22b. MoveEditorSystem (the Move Creation System's admin-gated authoring UI backend) boots right
--      after DevMenuSystem, the same whitelist-gated dev-tooling cluster -- it populates
--      MoveRegistryManager (step 12 above) from its own DataStore on boot. Nothing else in this
--      sequence depends on it existing first.
boot("MoveEditorSystem", MoveEditorSystem)

-- 22b2. KitEditorSystem (Race Traits + Bloodline Abilities plan's admin authoring tool) boots right
--       after MoveEditorSystem, the same whitelist-gated dev-tooling cluster -- it populates
--       RaceManager/BloodlineManager (steps 8a/11b above) from its own DataStores on boot, which is
--       the one real ordering requirement here. Nothing else in this sequence depends on it existing
--       first.
boot("KitEditorSystem", KitEditorSystem)

-- 22c. LiveConsoleSystem (the Live Admin Console's server half) boots right after MoveEditorSystem,
--      the same whitelist-gated dev-tooling cluster -- its own Logger.OnEntry registration only
--      needs Shared/Logger.lua (already required, not a System with an Init order of its own) and
--      Server/Config/AdminConfig.lua, so nothing else in this sequence depends on it existing first,
--      and it depends on nothing above.
boot("LiveConsoleSystem", LiveConsoleSystem)

-- 23. First-time-player onboarding boots last -- it depends on PlayerDataSystem (WaitForProfile to
--     read raceId, Transform to write the finalized profile) and AdminActionSystem (SetFrozen while
--     the intro cinematic/creator plays) already being initialized, and its own
--     CharacterCreation_GetOnboardingState handler is also this session's first
--     Player:LoadCharacter() call for every player (Players.CharacterAutoLoads = false (default.project.json)) --
--     nothing above depends on characters existing yet, so there's no ordering risk in placing this
--     last.
boot("CharacterCreationSystem", CharacterCreationSystem)

-- PLANNED SYSTEMS -- every Init() below is currently empty (re-confirmed 2026-09-28, when
-- ProgressionSystem and RewardSystem left this loop for step 7b). They boot here,
-- outside the numbered sequence above, so the boot list stays a complete inventory of every System
-- without pretending any ordering argument for them is real: none of them reads or writes anything
-- yet, so none of them participates in the dependency ordering the numbered steps above document.
-- Design intent for each one lives in its own module header, not here. Move a System's Init() call
-- out of this loop and into its own numbered step, with a real ordering comment, the day its body
-- stops being empty -- that migration is then a visible diff instead of a silent behavior change.
--
-- Named alongside their modules for the same reason the numbered steps above pass a name: these boot
-- through a loop, but they are checked against BootManifest.lua exactly like everything else.
for _, planned in
	{
		{ Name = "FactionManager", Module = FactionManager },
		{ Name = "AchievementSystem", Module = AchievementSystem },
		{ Name = "AbsorbSystem", Module = AbsorbSystem },
		{ Name = "AwakeningSystem", Module = AwakeningSystem },
		{ Name = "TerritorySystem", Module = TerritorySystem },
		{ Name = "WorldSystem", Module = WorldSystem },
	}
do
	boot(planned.Name, planned.Module)
end

-- LAST, and deliberately after every Init above including the planned loop: compares what actually
-- booted, and the network surface it actually produced, against Server/Config/BootManifest.lua. Hard
-- failure in Studio, an error-level log on a live server -- see AssertBootComplete's own comment for
-- why those are different.
BootManifest.AssertBootComplete(logger)
