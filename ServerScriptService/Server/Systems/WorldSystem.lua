--!strict
--[[
	WorldSystem.lua

	Owns: region state and environmental hazards, part of software-architecture.md's "zone
	control, region state, hazards" pairing with TerritorySystem (world-design.md for hazard
	specs per region -- the Void's Corruption-stack terrain, the Demonic Disastrous Landscape's
	geysers/corruption creep, etc.).
	Does not own: zone control/contest resolution -- that's TerritorySystem. This System owns what
	a region is doing environmentally, not who holds it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

local WorldSystem = {}

function WorldSystem.Init(): ()
end

return WorldSystem :: Types.SystemModule
