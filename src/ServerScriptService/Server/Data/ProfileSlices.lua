--!strict
--[[
	ProfileSlices.lua

	Owns: the list of profile slices PlayerDataSystem composes its persisted profile from, in the order they are composed.
	Adding a persisted profile field is one slice file next to its domain and ONE LINE here -- nothing in PlayerDataSystem
	changes (see ProfileSlice.lua for the contract, and why).

	ORDER MATTERS in exactly one place: when two slices declare a migration step for the same schema version they run in
	this order. Today no version has two.
]]

local ProfileSlice = require(script.Parent.ProfileSlice)
local ArtSlice = require(script.Parent.Slices.ArtSlice)
local BloodlineSlice = require(script.Parent.Slices.BloodlineSlice)
local EmoteSlice = require(script.Parent.Slices.EmoteSlice)

return ProfileSlice.Compose({
	EmoteSlice,
	ArtSlice,
	BloodlineSlice,
})
