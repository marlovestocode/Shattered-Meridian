--!strict
--[[
	BloodlineSystem.lua

	Owns: bloodline awakening, stage unlocks, passive/active application (software-architecture.md).
	Does not own: the bloodline registry/definitions themselves -- that's BloodlineManager. This
	System owns a given player's awakening state and progress through the stages, not the roster
	of bloodlines that exist.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

local BloodlineSystem = {}

function BloodlineSystem.Init(): ()
end

return BloodlineSystem :: Types.SystemModule
