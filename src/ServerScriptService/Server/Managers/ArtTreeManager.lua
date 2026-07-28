--!strict
--[[
	ArtTreeManager.lua

	Owns: the art tree structure/registry itself (software-architecture.md, paired with
	ArtSystem).
	Does not own: per-player mastery progression through those trees -- that's ArtSystem. This
	Manager coordinates the shape of the trees (what arts exist, how they connect), not any one
	player's progress through them.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

local ArtTreeManager = {}

function ArtTreeManager.Init(): () end

return ArtTreeManager :: Types.SystemModule
