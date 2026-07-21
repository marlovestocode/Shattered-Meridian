--!strict
--[[
	TerritorySystem.lua

	Owns: zone control and contest, part of software-architecture.md's "zone control, region
	state, hazards" pairing with WorldSystem. Feeds and is fed by FactionManager's faction
	standing (world-design.md for territory geography).
	Does not own: broader region state or environmental hazards -- that's WorldSystem. This
	System owns who controls/contests a zone, not what the zone itself is doing.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

local TerritorySystem = {}

function TerritorySystem.Init(): ()
end

return TerritorySystem :: Types.SystemModule
