--!strict
--[[
	AwakeningSystem.lua

	Owns: the Human Ascension gate (software-architecture.md; world-bible.md/progression-systems.md
	-- the mechanism by which a Human can awaken power outside their birth race). Must stay rare
	and earned, never a standard unlock (progression-systems.md's Ascension section).
	Does not own: bloodline stage unlocks once awakened -- BloodlineSystem owns those. This System
	owns the gate check itself, not what happens mechanically after it opens.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

local AwakeningSystem = {}

function AwakeningSystem.Init(): ()
end

return AwakeningSystem :: Types.SystemModule
