--!strict
--[[
	RivalrySystem.lua

	Owns: player-vs-player rivalry tracking, part of software-architecture.md's meta-progression
	social/competitive systems pairing with BountySystem.
	Does not own: bounty placement/claim state -- that's BountySystem. This System owns rivalry
	standing between specific players, fed by PvP outcomes from CombatSystem
	(progression-systems.md: "standing changes should primarily come from PvP outcomes ... not
	passive activity").
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

local RivalrySystem = {}

function RivalrySystem.Init(): () end

return RivalrySystem :: Types.SystemModule
