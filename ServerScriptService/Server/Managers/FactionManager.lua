--!strict
--[[
	FactionManager.lua

	Owns: faction membership, standing, faction-gated content (software-architecture.md).
	Does not own: territory contest resolution -- TerritorySystem owns that, reading faction
	standing from here. This Manager coordinates faction-level state that other Systems key off
	of, rather than owning a single player-facing mechanic itself.

	Boots early (right after PlayerDataSystem) -- faction identity gates content across many
	other Systems (Qi Conflict, territory contest, faction-gated arts).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

local FactionManager = {}

function FactionManager.Init(): ()
end

return FactionManager :: Types.SystemModule
