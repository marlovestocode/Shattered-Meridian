--!strict
--[[
	PlayerDataSystem.lua

	Owns: canonical player data read/write and DataStore integration (software-architecture.md).
	Does not own: tier/bloodline/art business logic -- those Systems read and write player state
	through this System's API; they never touch DataStores directly (engineering-standards.md's
	data-integrity rule: one serialized entry point per player's data).

	Boots first in Main.server.lua -- every other System that reads player data depends on this
	one being initialized already.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

local PlayerDataSystem = {}

function PlayerDataSystem.Init(): ()
end

return PlayerDataSystem :: Types.SystemModule
