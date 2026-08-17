--!strict
--[[
	Main.server.lua

	Owns: the server boot sequence. Requires every System/Manager module and initializes them in
	explicit dependency order per software-architecture.md ("boot order matters ... never rely on
	implicit load order from script instancing").
]]

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerRoot = ServerScriptService.Server

local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local EngineLogCapture = require(ReplicatedStorage.Shared.EngineLogCapture)

local Systems = ServerRoot.Systems
local Managers = ServerRoot.Managers
local Combat = ServerRoot.Combat

local ServerHopSystem = require(Systems.ServerHopSystem)
local VersionWatchSystem = require(Systems.VersionWatchSystem)
local PlayerDataSystem = require(Systems.PlayerDataSystem)
local SettingsSystem = require(Systems.SettingsSystem)
local FactionManager = require(Managers.FactionManager)
local MeridianSystem = require(Systems.MeridianSystem)
local QiSystem = require(Systems.QiSystem)
local TierSystem = require(Systems.TierSystem)
local BloodlineManager = require(Managers.BloodlineManager)
local BloodlineSystem = require(Systems.BloodlineSystem)
local ArtTreeManager = require(Managers.ArtTreeManager)
local ArtSystem = require(Systems.ArtSystem)
local CharacterSheetSystem = require(Systems.CharacterSheetSystem)
local ProgressionSystem = require(Systems.ProgressionSystem)
local AchievementSystem = require(Systems.AchievementSystem)
local QiDeviationSystem = require(Systems.QiDeviationSystem)
local MoveRegistryManager = require(Combat.MoveRegistryManager)
local PlayerDeathSystem = require(Systems.PlayerDeathSystem)
local HitboxEngine = require(Combat.HitboxEngine.HitboxEngine)
local DefenseSystem = require(Combat.Defense.DefenseSystem)
local DamageSystem = require(Combat.Damage.DamageSystem)
local AttackRequestSystem = require(Combat.Attack.AttackRequestSystem)
local ParkourSystem = require(Systems.ParkourSystem)
local RunSystem = require(Systems.RunSystem)
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
local ModerationSystem = require(Systems.ModerationSystem)
local DevMenuSystem = require(Systems.DevMenuSystem)
local MoveEditorSystem = require(Systems.MoveEditorSystem)
local LiveConsoleSystem = require(Systems.LiveConsoleSystem)
local CharacterCreationSystem = require(Systems.CharacterCreationSystem)
local EmoteUnlockService = require(Systems.EmoteUnlockService)
local EmoteSystem = require(Systems.EmoteSystem)

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
ModerationSystem.Init()

-- 2. ServerHopSystem has zero dependency on any other System (it only ever calls TeleportService for
--    a requesting player -- no PlayerDataSystem/CombatSystem/etc. state involved), so nothing below
--    gates it. Boots this early so it's ready as soon as possible -- it's the very first remote a
--    freshly-joined client's Start Menu can call, ahead of everything else in this file.
ServerHopSystem.Init()

-- 2b. VersionWatchSystem also has zero dependency on any other System (it only ever writes its own
--     boot-time game.PlaceVersion into its own DataStore key) -- boots early alongside ServerHopSystem
--     so the shared "highest booted version" key starts converging as soon as possible.
--     DevMenuSystem (step 22) is the one caller with a runtime dependency on it, reading it via
--     GetVersionInfo for the Admin tab's version-mismatch banner.
VersionWatchSystem.Init()

-- 3. Data layer next: every other System reads/writes player state through PlayerDataSystem.
PlayerDataSystem.Init()

-- 3b. SettingsSystem's only dependency is PlayerDataSystem immediately above (Transform/GetProfile
--     on Types.PlayerProfile.settings) -- boots here, right next to it, rather than later alongside
--     some unrelated cluster, since nothing else in this sequence needs it running sooner or later.
SettingsSystem.Init()

-- 4. Faction membership before anything faction-gated (standing, territory contest, Qi Conflict).
FactionManager.Init()

-- 5. Meridian XP is the resource TierSystem's tier-up checks read -- the resource has to exist
--    before the system gating on it can meaningfully check it (software-architecture.md).
MeridianSystem.Init()

-- 6. Qi's live resource (current/max, regen) reads profile.tier/attributes straight off
--    PlayerDataSystem, so it only needs step 3 -- placed here, ahead of TierSystem, purely to sit
--    next to MeridianSystem as the other "resource that has to exist before something reads it"
--    boot-order pair, and ahead of QiDeviationSystem (step 11) which is expected to read Qi state
--    through QiSystem's public API once it's built out.
QiSystem.Init()

-- 7. Tier before bloodline/art: awakening and mastery gates read current tier.
TierSystem.Init()

-- 8. Registries (Managers) before the per-player Systems that read them.
BloodlineManager.Init()
BloodlineSystem.Init()
ArtTreeManager.Init()
ArtSystem.Init()

-- 8b. The character sheet's replication layer -- pure projection of PlayerDataSystem's profile out
--     to its owning client, so it needs nothing beyond step 3. Boots here, next to the progression
--     Systems whose own remotes the character menu reads alongside this one, rather than at the
--     bottom with the UI-facing tools: it subscribes to OnProfileLoaded, and a profile that loads
--     before this connects would never push its sheet at all (the Init()-time GetPlayers() sweep in
--     that module is the backstop, not the plan).
CharacterSheetSystem.Init()

-- 9. ProgressionSystem is an orchestration layer (see software-architecture.md), not a data
--    owner -- its Init() doesn't need TierSystem/BloodlineSystem/ArtSystem/MeridianSystem
--    already running, it just needs to exist before any real gameplay event can be routed
--    through it, which this boot order already guarantees.
ProgressionSystem.Init()

-- 10. AchievementSystem has no Init()-time dependency on the systems it later reads from either --
--     same orchestration-layer reasoning as ProgressionSystem, clustered here since
--     ProgressionSystem is what triggers its milestone checks.
AchievementSystem.Init()

-- 11. Qi Deviation reads qi/art/bloodline state, so it boots after those exist.
QiDeviationSystem.Init()

-- 12. MoveRegistryManager (the Move Creation System's live in-memory move registry --
--     Server/Combat/MoveRegistryManager.lua) boots here -- MoveEditorSystem (step 22b) is what
--     actually populates it from DataStore, and it must already exist (even empty) before that runs.
--
--     PlayerDeathSystem replaces what used to be Server/Systems/CombatSystem.lua's own incidental
--     death-detection (Humanoid.Died -> GameplayEvents.FirePlayerKilled) -- see that module's own
--     header for why detecting a death was never actually combat logic, just something CombatSystem
--     happened to also do. Boots here, in the combat system's old boot slot, since RespawnSystem
--     (step 15)/RivalrySystem/BountySystem (step 18) below are its subscribers.
--
--     HitboxEngine (Server/Combat/HitboxEngine/) is the first piece of the replacement combat layer
--     and boots in the same slot for the same reason. It has no Init()-time dependency on anything --
--     it owns its own Heartbeat, registers combatants on demand, and nothing currently in this
--     sequence reads from it -- so its position here is about where a reader expects combat to start,
--     not about ordering. Init() only connects the Heartbeat; a server with nobody registered pays
--     nothing for it.
MoveRegistryManager.Init()
PlayerDeathSystem.Init()
HitboxEngine.Init()

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
DefenseSystem.Init()

--     DamageSystem is the defence layer's first consumer, and the third and last layer of the combat
--     stack -- it turns a KIND of hit into health lost, guard spent, and a swing interrupted. ITS
--     POSITION HERE IS THE SAME CORRECTNESS REQUIREMENT DefenseSystem's is, one layer further up: its
--     Heartbeat reclaims state stamped by outcomes that DefenseSystem's own Heartbeat produced earlier
--     in the same frame, so it must connect after. Its Init asserts both layers below are available
--     rather than trusting this comment.
--     Note it needs no character binding of its own and has no registry -- see its header on why
--     everything it needs is derivable from the Model an outcome already carries, which is what lets a
--     player, a bot and a dummy share one path with nobody registering any of them.
DamageSystem.Init()

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
AttackRequestSystem.Init()

-- 12a. Parkour System -- the server authority for the client-side movement framework. Its one
--      integration point is the pair of Humanoid Attributes it stamps (ParkourVelocityOwned, and the
--      ParkourSpeedFloor/Expiry momentum carry), which the WalkSpeed owner in step 12b reads every
--      tick. That is a RUNTIME relationship, not an Init()-time one -- neither System calls the other,
--      so the two may boot in either order -- but they are listed adjacently because reading one
--      without the other makes neither make sense. The one real requirement is ModerationSystem
--      (step 1), since a sustained stream of implausible movement reports routes into its
--      suspected-cheater flag.
ParkourSystem.Init()

-- 12b. Run System -- the WalkSpeed owner, and the authority for the three-stage run. Takes over the
--      per-Heartbeat WalkSpeed resolver that CombatSystem.onHeartbeat used to drive through
--      Server/Combat/Movement.ComputeDesiredWalkSpeed; with CombatSystem deleted by the combat
--      rewrite, nothing drove that resolver, so nothing wrote WalkSpeed at all and no run stage was
--      ever published. See this System's own header for the full ownership argument.
--
--      Boots after ParkourSystem purely so the pair reads in dependency order (the run's resolver
--      reads Attributes the parkour System stamps). It requires no System's API at Init() time and
--      would boot correctly anywhere in this sequence; its only genuine ordering constraint is that
--      it must run before any System that expects a seeded BonusWalkSpeed Attribute, and nothing
--      currently does.
RunSystem.Init()

-- 12b. Emote System -- EmoteUnlockService only needs PlayerDataSystem (step 3), but boots here,
--      immediately alongside its one dependent, rather than earlier: nothing else in this sequence
--      needs it running sooner. EmoteSystem needs both PlayerDataSystem (persistence) and
--      EmoteUnlockService (HasUnlocked/GetUnlockedIds gates on RequestPlay/RequestSetLoadoutSlot),
--      so it boots last of the two.
EmoteUnlockService.Init()
EmoteSystem.Init()

-- 13. Absorb computes/applies essence absorption -- boots before RewardSystem, which is the one
--     with the runtime dependency on it (not the reverse).
AbsorbSystem.Init()

-- 14. RewardSystem composes reward manifests from CombatSystem's outcomes, calling into
--     AbsorbSystem for the absorb component, before handing off to ProgressionSystem.
RewardSystem.Init()

-- 15. RespawnSystem subscribes to GameplayEvents.OnPlayerKilled, so it needs PlayerDeathSystem
--     already running (step 12) to ever fire that signal. Placed after the reward/progression
--     consumers above rather than before them only for readability -- it's a pure subscriber, so
--     nothing in this sequence depends on it. It owns every Player:LoadCharacter() call
--     EXCEPT the session-first one CharacterCreationSystem makes at step 23 -- see its own header
--     for why Players.CharacterAutoLoads = false makes that ownership split load-bearing.
RespawnSystem.Init()

-- 16. Ascension reads tier/race/bloodline state to gate the awakening check.
AwakeningSystem.Init()

-- 17. World/territory state depends on FactionManager for faction-contested zones.
TerritorySystem.Init()
WorldSystem.Init()

-- 18. Meta/social systems read PvP kill outcomes off GameplayEvents.OnPlayerKilled (PlayerDeathSystem,
--     step 12, is what actually fires it now -- see that module's header) and player state from
--     PlayerDataSystem.
RivalrySystem.Init()
BountySystem.Init()

-- 20. Bug reports are independent of every gameplay System above (own DataStore, own public
--     remote) but boot before the whitelist-gated dev tooling that triages them --
--     DevMenuSystem's ListBugReports/UpdateBugReportStatus handlers call straight into
--     BugReportSystem's public API -- "boots before its one dependent."
BugReportSystem.Init()

-- 21. AdminActionSystem owns its own independent Players.PlayerAdded/CharacterAdded wiring (no
--     runtime dependency on any other System above) -- boots before DevMenuSystem,
--     which is the one with the runtime dependency on it (its SetTargetGodmode/SetTargetFlight/
--     SetTargetFlightCollide/SetTargetFrozen/SetTargetInvisible/SetTargetSpeedMultiplier/
--     TeleportToTarget/BringTarget/TeleportToCoordinates handlers call straight into it).
AdminActionSystem.Init()

-- 22. Whitelist-gated dev tooling boots last -- its
--     ListBugReports/UpdateBugReportStatus handlers call BugReportSystem, its
--     SetTargetGodmode/SetTargetFlight/SetTargetFlightCollide/etc. handlers call AdminActionSystem,
--     its KickPlayer/BanPlayer/MutePlayer handlers call ModerationSystem (already booted first,
--     step 1), and its RollEmote handler calls EmoteUnlockService (already booted at step 12b) -- so
--     it needs all of them already running, and nothing else in the boot sequence depends on
--     DevMenuSystem existing first.
DevMenuSystem.Init()

-- 22b. MoveEditorSystem (the Move Creation System's admin-gated authoring UI backend) boots right
--      after DevMenuSystem, the same whitelist-gated dev-tooling cluster -- it populates
--      MoveRegistryManager (step 12 above) from its own DataStore on boot. Nothing else in this
--      sequence depends on it existing first.
MoveEditorSystem.Init()

-- 22c. LiveConsoleSystem (the Live Admin Console's server half) boots right after MoveEditorSystem,
--      the same whitelist-gated dev-tooling cluster -- its own Logger.OnEntry registration only
--      needs Shared/Logger.lua (already required, not a System with an Init order of its own) and
--      Server/Config/AdminConfig.lua, so nothing else in this sequence depends on it existing first,
--      and it depends on nothing above.
LiveConsoleSystem.Init()

-- 23. First-time-player onboarding boots last -- it depends on PlayerDataSystem (WaitForProfile to
--     read raceId, Transform to write the finalized profile) and AdminActionSystem (SetFrozen while
--     the intro cinematic/creator plays) already being initialized, and its own
--     CharacterCreation_GetOnboardingState handler is also this session's first
--     Player:LoadCharacter() call for every player (Players.CharacterAutoLoads = false (default.project.json)) --
--     nothing above depends on characters existing yet, so there's no ordering risk in placing this
--     last.
CharacterCreationSystem.Init()
