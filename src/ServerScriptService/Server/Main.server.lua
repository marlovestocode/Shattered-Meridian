--!strict
--[[
	Main.server.lua

	Owns: the server boot sequence. Requires every System/Manager module and initializes them in
	explicit dependency order per software-architecture.md ("boot order matters ... never rely on
	implicit load order from script instancing").
]]

local ServerScriptService = game:GetService("ServerScriptService")
local ServerRoot = ServerScriptService.Server

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
local ProgressionSystem = require(Systems.ProgressionSystem)
local AchievementSystem = require(Systems.AchievementSystem)
local QiDeviationSystem = require(Systems.QiDeviationSystem)
local MoveRegistryManager = require(Combat.MoveRegistryManager)
local CombatSystem = require(Systems.CombatSystem)
local AbsorbSystem = require(Systems.AbsorbSystem)
local RewardSystem = require(Systems.RewardSystem)
local RespawnSystem = require(Systems.RespawnSystem)
local AwakeningSystem = require(Systems.AwakeningSystem)
local TerritorySystem = require(Systems.TerritorySystem)
local WorldSystem = require(Systems.WorldSystem)
local RivalrySystem = require(Systems.RivalrySystem)
local BountySystem = require(Systems.BountySystem)
local TrainingBotSystem = require(Systems.TrainingBotSystem)
local BugReportSystem = require(Systems.BugReportSystem)
local AdminActionSystem = require(Systems.AdminActionSystem)
local ModerationSystem = require(Systems.ModerationSystem)
local DevMenuSystem = require(Systems.DevMenuSystem)
local MoveEditorSystem = require(Systems.MoveEditorSystem)
local CharacterCreationSystem = require(Systems.CharacterCreationSystem)
local EmoteUnlockService = require(Systems.EmoteUnlockService)
local EmoteSystem = require(Systems.EmoteSystem)

-- Explicit boot order -- each comment states the dependency this ordering satisfies.

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

-- 12. Combat depends on tier/bloodline/art for kit resolution. MoveRegistryManager (the Move
--     Creation System's live in-memory move registry -- Server/Combat/MoveRegistryManager.lua)
--     boots immediately before it, the same "Manager before the System that reads it" pairing
--     BloodlineManager/ArtTreeManager already establish at step 8: CombatSystem.ThrowCustomMove
--     reads this registry directly, so it must already exist (even empty -- MoveEditorSystem below
--     is what actually populates it from DataStore) before CombatSystem.Init() runs.
MoveRegistryManager.Init()
CombatSystem.Init()

-- 12b. Emote System -- EmoteUnlockService only needs PlayerDataSystem (step 3), but boots here,
--      immediately alongside its one dependent, rather than earlier: nothing else in this sequence
--      needs it running sooner. EmoteSystem needs all three of PlayerDataSystem (persistence),
--      EmoteUnlockService (HasUnlocked/GetUnlockedIds gates on RequestPlay/RequestSetLoadoutSlot),
--      and CombatSystem (GetCombatState -- the restricted-state/interruption checks), so it boots
--      last of the two and only after CombatSystem.Init() immediately above.
EmoteUnlockService.Init()
EmoteSystem.Init()

-- 13. Absorb computes/applies essence absorption -- boots before RewardSystem, which is the one
--     with the runtime dependency on it (not the reverse).
AbsorbSystem.Init()

-- 14. RewardSystem composes reward manifests from CombatSystem's outcomes, calling into
--     AbsorbSystem for the absorb component, before handing off to ProgressionSystem.
RewardSystem.Init()

-- 15. RespawnSystem subscribes to CombatSystem.OnPlayerKilled, so it needs CombatSystem already
--     running (step 12). Placed after the reward/progression consumers above rather than before
--     them only for readability -- it's a pure subscriber, so nothing in this sequence depends on
--     it and it depends on nothing but CombatSystem. It owns every Player:LoadCharacter() call
--     EXCEPT the session-first one CharacterCreationSystem makes at step 23 -- see its own header
--     for why Players.CharacterAutoLoads = false makes that ownership split load-bearing.
RespawnSystem.Init()

-- 16. Ascension reads tier/race/bloodline state to gate the awakening check.
AwakeningSystem.Init()

-- 17. World/territory state depends on FactionManager for faction-contested zones.
TerritorySystem.Init()
WorldSystem.Init()

-- 18. Meta/social systems read PvP outcomes from CombatSystem and player state from
--     PlayerDataSystem.
RivalrySystem.Init()
BountySystem.Init()

-- 19. TrainingBotSystem's AI decision loop subscribes to CombatSystem.OnHeartbeatTick and drives
--     bots through CombatSystem's RequestBot*/SpawnTrainingBot primitives, so it needs CombatSystem
--     already running. Boots before DevMenuSystem, which is the one with the runtime dependency on
--     it (its SpawnTrainingBot handler calls TrainingBotSystem.ValidatePresetRequest/RegisterBot).
TrainingBotSystem.Init()

-- 20. Bug reports are independent of every gameplay System above (own DataStore, own public
--     remote) but boot before the whitelist-gated dev tooling that triages them --
--     DevMenuSystem's ListBugReports/UpdateBugReportStatus handlers call straight into
--     BugReportSystem's public API, the same "boots before its one dependent" reasoning
--     TrainingBotSystem gets above.
BugReportSystem.Init()

-- 21. AdminActionSystem owns its own independent Players.PlayerAdded/CharacterAdded wiring (no
--     runtime dependency on CombatSystem or any other System above) -- boots before DevMenuSystem,
--     which is the one with the runtime dependency on it (its SetTargetGodmode/SetTargetFlight/
--     SetTargetFlightCollide/SetTargetFrozen/SetTargetInvisible/SetTargetSpeedMultiplier/
--     TeleportToTarget/BringTarget/TeleportToCoordinates handlers call straight into it).
AdminActionSystem.Init()

-- 22. Whitelist-gated dev tooling boots last -- its SpawnDummy/SpawnTrainingBot handlers call
--     CombatSystem.SpawnTrainingDummy/SpawnTrainingBot (the latter via TrainingBotSystem), its
--     ListBugReports/UpdateBugReportStatus handlers call BugReportSystem, its
--     SetTargetGodmode/SetTargetFlight/SetTargetFlightCollide/etc. handlers call AdminActionSystem,
--     its ResetTargetCombatState handler calls CombatSystem directly, its
--     KickPlayer/BanPlayer/MutePlayer handlers call ModerationSystem (already booted first, step 1),
--     and its RollEmote handler calls EmoteUnlockService (already booted at step 12b) -- so it needs
--     all of them already running, and nothing else in the boot sequence depends on DevMenuSystem
--     existing first.
DevMenuSystem.Init()

-- 22b. MoveEditorSystem (the Move Creation System's admin-gated authoring UI backend) boots right
--      after DevMenuSystem, the same whitelist-gated dev-tooling cluster -- its TestFireMove/
--      SpawnPreviewDummy handlers call CombatSystem.ThrowCustomMove/SpawnTrainingDummy directly
--      (step 12 above), and it populates MoveRegistryManager (also step 12) from its own DataStore
--      on boot. Nothing else in this sequence depends on it existing first.
MoveEditorSystem.Init()

-- 23. First-time-player onboarding boots last -- it depends on PlayerDataSystem (WaitForProfile to
--     read raceId, Transform to write the finalized profile) and AdminActionSystem (SetFrozen while
--     the intro cinematic/creator plays) already being initialized, and its own
--     CharacterCreation_GetOnboardingState handler is also this session's first
--     Player:LoadCharacter() call for every player (Players.CharacterAutoLoads = false (default.project.json)) --
--     nothing above depends on characters existing yet, so there's no ordering risk in placing this
--     last.
CharacterCreationSystem.Init()
