--!strict
--[[
	QiDeviationSystem.lua

	Owns: Qi Deviation risk/trigger/consequence (software-architecture.md; progression-systems.md
	-- "the primary 'power has a cost' mechanic outside of pure Corruption", scaling with how far
	a player overreaches their current tier/mastery).
	Does not own: Corruption's Demonic-power cost model -- that's a separate, related cost model
	(progression-systems.md's Corruption section) this System doesn't own but should stay legible
	alongside.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

local QiDeviationSystem = {}

function QiDeviationSystem.Init(): () end

return QiDeviationSystem :: Types.SystemModule
