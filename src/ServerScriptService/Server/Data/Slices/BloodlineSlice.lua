--!strict
--[[
	BloodlineSlice.lua

	Owns: the bloodline fields of a profile -- `bloodlineIds` (the ids the player holds, an array), `bloodlineStageProgress`
	({ [BloodlineId]: number }, the awakened stage of each) and `bloodlineRerolls` (spins left) -- and how they are defaulted,
	copied, encoded, decoded and backfilled. Moved here out of PlayerDataSystem (coworking plan W5, 2026-10-25) unchanged; the
	round-trip corpus (Tests/PlayerData/ProfileRoundTrip.spec.lua) pins it to the byte.

	DEFAULTS. Ids and stage progress are empty: a brand-new profile has awakened nothing. Rerolls are the one field that is NOT
	empty/zero on a fresh profile -- a new player is meant to arrive holding their rerolls, so the onboarding spin has something
	to offer past the first free roll (BloodlineConstants.StartingRerolls).

	DECODE. Ids and stage progress keep a per-entry filter, dropping a bad entry rather than the field. Rerolls are floored and
	CLAMPED AT 0 rather than trusted: a negative count from a corrupted or rolled-back record would make the spin button look
	available forever while every press refused.

	MIGRATIONS. v6 -> v7 backfills `bloodlineStageProgress` EMPTY (an existing player has awakened no bloodline any differently
	than a new one). v7 -> v8 backfills `bloodlineRerolls` to the FULL StartingRerolls, unlike the empty backfills: an existing
	player was never offered a spin, so they have spent nothing, and 0 would punish them for having played before the feature.

	Does not own: bloodline content (BloodlineManager), awakening rules or per-player stage state (BloodlineSystem).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BloodlineConstants = require(ReplicatedStorage.Shared.Bloodline.BloodlineConstants)
local Schema = require(ReplicatedStorage.Shared.Schema)
local ProfileSlice = require(script.Parent.Parent.ProfileSlice)

return ProfileSlice.Define({
	Name = "Bloodlines",
	Fields = { "bloodlineIds", "bloodlineStageProgress", "bloodlineRerolls" },

	Default = function(_userId: number)
		return {
			bloodlineIds = {},
			bloodlineStageProgress = {},
			bloodlineRerolls = BloodlineConstants.StartingRerolls,
		}
	end,

	Copy = function(profile: any)
		return {
			bloodlineIds = table.clone(profile.bloodlineIds),
			bloodlineStageProgress = table.clone(profile.bloodlineStageProgress),
			bloodlineRerolls = profile.bloodlineRerolls,
		}
	end,

	Encode = function(profile: any)
		return {
			bloodlineIds = profile.bloodlineIds,
			bloodlineStageProgress = profile.bloodlineStageProgress,
			bloodlineRerolls = profile.bloodlineRerolls,
		}
	end,

	Decode = function(raw: { [string]: any }, _userId: number)
		local bloodlineIds: { string } = {}
		if Schema.IsTable(raw.bloodlineIds) then
			for _, id in ipairs(raw.bloodlineIds) do
				if Schema.IsString(id) then
					table.insert(bloodlineIds, id)
				end
			end
		end

		local bloodlineStageProgress: { [string]: number } = {}
		if Schema.IsTable(raw.bloodlineStageProgress) then
			for bloodlineId, stage in pairs(raw.bloodlineStageProgress) do
				if Schema.IsString(bloodlineId) and Schema.IsNumber(stage) then
					bloodlineStageProgress[bloodlineId] = stage
				end
			end
		end

		return {
			bloodlineIds = bloodlineIds,
			bloodlineStageProgress = bloodlineStageProgress,
			bloodlineRerolls = if Schema.IsNumber(raw.bloodlineRerolls)
				then math.max(0, math.floor(raw.bloodlineRerolls :: number))
				else BloodlineConstants.StartingRerolls,
		}
	end,

	Migrations = {
		-- v6 -> v7: backfills `bloodlineStageProgress` (empty is honest).
		[6] = function(record: { [string]: any }): { [string]: any }
			local profile = record.Profile
			if Schema.IsTable(profile) then
				local profileTable = profile :: { [string]: any }
				if profileTable.bloodlineStageProgress == nil then
					profileTable.bloodlineStageProgress = {}
				end
			end
			return record
		end,

		-- v7 -> v8: backfills `bloodlineRerolls` to the full starting count.
		[7] = function(record: { [string]: any }): { [string]: any }
			local profile = record.Profile
			if Schema.IsTable(profile) then
				local profileTable = profile :: { [string]: any }
				if profileTable.bloodlineRerolls == nil then
					profileTable.bloodlineRerolls = BloodlineConstants.StartingRerolls
				end
			end
			return record
		end,
	},
})
