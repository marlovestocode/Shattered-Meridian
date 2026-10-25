--!strict
--[[
	ArtSlice.lua

	Owns: the Art System's persisted profile fields -- `artMastery` ({ [ArtId]: number }, mastery earned per unlocked art) and
	`equippedArts` ({ [slot]: ArtId }, which art sits in each hotbar slot) -- and how they are defaulted, copied, encoded,
	decoded and backfilled. Moved here out of PlayerDataSystem (coworking plan W5, 2026-10-25) unchanged; the round-trip corpus
	(Tests/PlayerData/ProfileRoundTrip.spec.lua) pins it to the byte.

	DEFAULTS are empty, not a seeded starter slot, for the same reason ArtConstants.StartingArtIds is empty: an art is earned,
	and there is nothing to equip until the player unlocks one.

	DECODE. `artMastery` keeps a per-entry filter (string key, number value) and drops a bad entry rather than the field.
	`equippedArts` carries the one genuinely non-obvious step: a DataStore round trip is a JSON round trip, and JSON has no
	integer keys -- `{ [4] = "art" }` comes back as `{ ["4"] = "art" }`. Both forms are accepted and normalised back to a
	number, rather than trusting a numeric key (which would silently drop every slot on the first reload and hand the player an
	empty hotbar with no error anywhere). Out-of-range and non-integer slots are dropped per entry.

	MIGRATION v3 -> v4 backfills `equippedArts` with an EMPTY table: which art goes in which slot is a player decision this
	System has no basis to make for them.

	Does not own: which arts exist or their prerequisites (Shared/ArtConstants, ArtTreeManager), or unlock/equip rules (ArtSystem).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ArtConstants = require(ReplicatedStorage.Shared.ArtConstants)
local Schema = require(ReplicatedStorage.Shared.Schema)
local ProfileSlice = require(script.Parent.Parent.ProfileSlice)

return ProfileSlice.Define({
	Name = "Arts",
	Fields = { "artMastery", "equippedArts" },

	Default = function(_userId: number)
		return { artMastery = {}, equippedArts = {} }
	end,

	Copy = function(profile: any)
		return {
			artMastery = table.clone(profile.artMastery),
			equippedArts = table.clone(profile.equippedArts),
		}
	end,

	Encode = function(profile: any)
		return {
			artMastery = profile.artMastery,
			equippedArts = profile.equippedArts,
		}
	end,

	Decode = function(raw: { [string]: any }, _userId: number)
		local artMastery: { [string]: number } = {}
		if Schema.IsTable(raw.artMastery) then
			for artId, rank in pairs(raw.artMastery) do
				if Schema.IsString(artId) and Schema.IsNumber(rank) then
					artMastery[artId] = rank
				end
			end
		end

		local equippedArts: { [number]: string } = {}
		if Schema.IsTable(raw.equippedArts) then
			for slot, artId in pairs(raw.equippedArts :: { [any]: any }) do
				local slotNumber = if Schema.IsNumber(slot) then slot else tonumber(slot)
				if
					Schema.IsString(artId)
					and slotNumber ~= nil
					and slotNumber == math.floor(slotNumber)
					and slotNumber >= 1
					and slotNumber <= ArtConstants.EquipSlotCount
				then
					equippedArts[slotNumber] = artId
				end
			end
		end

		return { artMastery = artMastery, equippedArts = equippedArts }
	end,

	Migrations = {
		-- v3 -> v4: backfills `equippedArts` onto any record saved before it existed.
		[3] = function(record: { [string]: any }): { [string]: any }
			local profile = record.Profile
			if Schema.IsTable(profile) then
				local profileTable = profile :: { [string]: any }
				if profileTable.equippedArts == nil then
					profileTable.equippedArts = {}
				end
			end
			return record
		end,
	},
})
