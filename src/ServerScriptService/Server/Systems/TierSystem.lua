--!strict
--[[
	TierSystem.lua

	Owns: tier thresholds, tier-up validation and effects (software-architecture.md).
	Does not own: combat resolution or absorb mechanics -- CombatSystem and AbsorbSystem read tier
	state from here; tier-up itself is decided only by this System.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

local TierSystem = {}

function TierSystem.Init(): () end

return TierSystem :: Types.SystemModule
