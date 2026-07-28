--!strict
--[[
	AbsorbSystem.lua

	Owns: post-kill absorb mechanics -- computes and applies essence absorption from a confirmed
	PvP kill (progression-systems.md's Absorb system: "must always require an actual PvP kill,
	never a non-combat substitute"). See software-architecture.md's "RewardSystem and
	AbsorbSystem" section for the full resolved boundary.
	Does not own: hit/kill validation itself -- CombatSystem owns and confirms the kill. Does not
	own reward composition either -- RewardSystem is the one that recognizes a kill happened and
	calls into this System for the absorb component; CombatSystem does not call this System
	directly.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

local AbsorbSystem = {}

function AbsorbSystem.Init(): () end

return AbsorbSystem :: Types.SystemModule
