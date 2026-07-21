--!strict
--[[
	BountySystem.lua

	Owns: bounty placement/claim state, part of software-architecture.md's meta-progression
	social/competitive systems pairing with RivalrySystem.
	Does not own: general rivalry tracking between players -- that's RivalrySystem. This System
	owns the bounty lifecycle specifically (placed, active, claimed).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

local BountySystem = {}

function BountySystem.Init(): ()
end

return BountySystem :: Types.SystemModule
