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

local PlayerDataSystem = require(Systems.PlayerDataSystem)
local FactionManager = require(Managers.FactionManager)
local MeridianSystem = require(Systems.MeridianSystem)
local TierSystem = require(Systems.TierSystem)
local BloodlineManager = require(Managers.BloodlineManager)
local BloodlineSystem = require(Systems.BloodlineSystem)
local ArtTreeManager = require(Managers.ArtTreeManager)
local ArtSystem = require(Systems.ArtSystem)
local ProgressionSystem = require(Systems.ProgressionSystem)
local AchievementSystem = require(Systems.AchievementSystem)
local QiDeviationSystem = require(Systems.QiDeviationSystem)
local CombatSystem = require(Systems.CombatSystem)
local AbsorbSystem = require(Systems.AbsorbSystem)
local RewardSystem = require(Systems.RewardSystem)
local AwakeningSystem = require(Systems.AwakeningSystem)
local TerritorySystem = require(Systems.TerritorySystem)
local WorldSystem = require(Systems.WorldSystem)
local RivalrySystem = require(Systems.RivalrySystem)
local BountySystem = require(Systems.BountySystem)
local TrainingBotSystem = require(Systems.TrainingBotSystem)
local BugReportSystem = require(Systems.BugReportSystem)
local DevMenuSystem = require(Systems.DevMenuSystem)

-- Explicit boot order -- each comment states the dependency this ordering satisfies.

-- 1. Data layer first: every other System reads/writes player state through PlayerDataSystem.
PlayerDataSystem.Init()

-- 2. Faction membership before anything faction-gated (standing, territory contest, Qi Conflict).
FactionManager.Init()

-- 3. Meridian XP is the resource TierSystem's tier-up checks read -- the resource has to exist
--    before the system gating on it can meaningfully check it (software-architecture.md).
MeridianSystem.Init()

-- 4. Tier before bloodline/art: awakening and mastery gates read current tier.
TierSystem.Init()

-- 5. Registries (Managers) before the per-player Systems that read them.
BloodlineManager.Init()
BloodlineSystem.Init()
ArtTreeManager.Init()
ArtSystem.Init()

-- 6. ProgressionSystem is an orchestration layer (see software-architecture.md), not a data
--    owner -- its Init() doesn't need TierSystem/BloodlineSystem/ArtSystem/MeridianSystem
--    already running, it just needs to exist before any real gameplay event can be routed
--    through it, which this boot order already guarantees.
ProgressionSystem.Init()

-- 7. AchievementSystem has no Init()-time dependency on the systems it later reads from either --
--    same orchestration-layer reasoning as ProgressionSystem, clustered here since
--    ProgressionSystem is what triggers its milestone checks.
AchievementSystem.Init()

-- 8. Qi Deviation reads qi/art/bloodline state, so it boots after those exist.
QiDeviationSystem.Init()

-- 9. Combat depends on tier/bloodline/art for kit resolution.
CombatSystem.Init()

-- 10. Absorb computes/applies essence absorption -- boots before RewardSystem, which is the one
--     with the runtime dependency on it (not the reverse).
AbsorbSystem.Init()

-- 11. RewardSystem composes reward manifests from CombatSystem's outcomes, calling into
--     AbsorbSystem for the absorb component, before handing off to ProgressionSystem.
RewardSystem.Init()

-- 12. Ascension reads tier/race/bloodline state to gate the awakening check.
AwakeningSystem.Init()

-- 13. World/territory state depends on FactionManager for faction-contested zones.
TerritorySystem.Init()
WorldSystem.Init()

-- 14. Meta/social systems read PvP outcomes from CombatSystem and player state from
--     PlayerDataSystem.
RivalrySystem.Init()
BountySystem.Init()

-- 15. TrainingBotSystem's AI decision loop subscribes to CombatSystem.OnHeartbeatTick and drives
--     bots through CombatSystem's RequestBot*/SpawnTrainingBot primitives, so it needs CombatSystem
--     already running. Boots before DevMenuSystem, which is the one with the runtime dependency on
--     it (its SpawnTrainingBot handler calls TrainingBotSystem.ValidatePresetRequest/RegisterBot).
TrainingBotSystem.Init()

-- 16. Bug reports are independent of every gameplay System above (own DataStore, own public
--     remote) but boot before the whitelist-gated dev tooling that triages them --
--     DevMenuSystem's ListBugReports/UpdateBugReportStatus handlers call straight into
--     BugReportSystem's public API, the same "boots before its one dependent" reasoning
--     TrainingBotSystem gets above.
BugReportSystem.Init()

-- 17. Whitelist-gated dev tooling boots last -- its SpawnDummy/SpawnTrainingBot handlers call
--     CombatSystem.SpawnTrainingDummy/SpawnTrainingBot (the latter via TrainingBotSystem), and its
--     ListBugReports/UpdateBugReportStatus handlers call BugReportSystem (both above), so it needs
--     all three already running, and nothing else in the boot sequence depends on DevMenuSystem
--     existing first.
DevMenuSystem.Init()
