--!strict
--[[
	BloodlineManager.lua

	Owns: the bloodline registry/definitions themselves (software-architecture.md, paired with
	BloodlineSystem) -- the roster of bloodlines, their rarity/awakening-condition/stage data
	(progression-systems.md).
	Does not own: per-player awakening state or stage progress -- that's BloodlineSystem. This
	Manager coordinates what bloodlines exist and their defined stages, not who has awakened one.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

local BloodlineManager = {}

function BloodlineManager.Init(): ()
end

return BloodlineManager :: Types.SystemModule
