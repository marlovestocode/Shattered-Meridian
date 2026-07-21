--!strict
--[[
	ArtSystem.lua

	Owns: per-player art mastery progression (software-architecture.md; progression-systems.md's
	"each rank changes a decision, not just a number" standard).
	Does not own: the art tree structure/definitions themselves -- that's ArtTreeManager. This
	System owns how a player's mastery moves through those trees, not the trees' shape.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

local ArtSystem = {}

function ArtSystem.Init(): ()
end

return ArtSystem :: Types.SystemModule
