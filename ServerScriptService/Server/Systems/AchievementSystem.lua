--!strict
--[[
	AchievementSystem.lua

	Owns: milestone/achievement definitions and unlock state. See software-architecture.md's
	"MeridianSystem and AchievementSystem" section for the full boundary.

	Does not own: any of the progression values a milestone checks against -- Tier, bloodline
	stage, Meridian XP, and art mastery stay owned by TierSystem, BloodlineSystem, MeridianSystem,
	and ArtSystem respectively. This System reads those through each owner's public API rather
	than duplicating their state. Does not own deciding *when* to check milestones either --
	ProgressionSystem triggers the check as the last step of a completed progression pipeline run;
	this System only evaluates it once triggered.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

local AchievementSystem = {}

function AchievementSystem.Init(): ()
end

return AchievementSystem :: Types.SystemModule
