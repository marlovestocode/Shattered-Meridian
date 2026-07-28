--!strict
--[[
	MeridianSystem.lua

	Owns: Meridian XP calculation and balance -- the core progression currency (project-vision.md,
	progression-systems.md: "Tier gates are earned through Meridian XP from PvP wins"). See
	software-architecture.md's "MeridianSystem and AchievementSystem" section for the full
	boundary.

	Does not own: tier-up validation and effects (TierSystem, which reads the balance this System
	owns to decide whether a threshold has been crossed), canonical persistence (PlayerDataSystem
	-- this System updates balances through PlayerDataSystem's API, never a DataStore write of its
	own), or deciding whether an event is progression-eligible (ProgressionSystem, which is what
	routes Meridian-XP-eligible reward components here in the first place).

	Boots before TierSystem -- the resource has to exist before the system gating on it can
	meaningfully check it, mirroring PlayerDataSystem's "data layer first" boot position.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

local MeridianSystem = {}

function MeridianSystem.Init(): () end

return MeridianSystem :: Types.SystemModule
