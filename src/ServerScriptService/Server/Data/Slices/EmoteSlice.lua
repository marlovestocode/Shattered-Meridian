--!strict
--[[
	EmoteSlice.lua

	Owns: the Emote System's persisted profile fields -- `unlockedEmoteIds` (a SET: { [EmoteId]: true }) and `emoteLoadout`
	(an ORDERED array of EmoteIds, the wheel's slots) -- and everything about how they are defaulted, copied, encoded,
	decoded and backfilled. Moved here out of PlayerDataSystem (coworking plan W5, 2026-10-25) unchanged; the round-trip
	corpus (Tests/PlayerData/ProfileRoundTrip.spec.lua) pins it to the byte.

	DEFAULTS. A brand-new profile starts with every Default-unlock emote already granted and the 8-emote starter loadout in
	place, so a first-time player never sees an empty wheel while waiting on EmoteUnlockService's own join-time backfill (that
	backfill exists for OLDER saves, not this path).

	DECODE. Every key of the set must be a string and every value literally `true` (never just truthy), the per-entry
	filtering every open dict here gets. A missing, wrong-shaped or emptied set falls back to
	EmoteRegistry.GetDefaultUnlockedIds() rather than an empty table -- the same "a new/legacy record still gets every Default
	emote" contract CreateDefault and Migrations[1] both guarantee; Decode is a second, independent line of defence for the
	same invariant, not a place that should ever hand back a player with zero emotes over a merely-corrupt field. The loadout is
	filtered the same way bloodlineIds is (drop any non-string entry rather than the whole array) and falls back to the starter
	loadout when nothing survives.

	MIGRATION v1 -> v2 backfills both fields onto any record saved before the Emote System shipped.

	Does not own: which emotes exist (Shared/Emotes/EmoteRegistry), or who may unlock one (EmoteUnlockService).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EmoteConstants = require(ReplicatedStorage.Shared.EmoteConstants)
local EmoteRegistry = require(ReplicatedStorage.Shared.Emotes.EmoteRegistry)
local Schema = require(ReplicatedStorage.Shared.Schema)
local ProfileSlice = require(script.Parent.Parent.ProfileSlice)

return ProfileSlice.Define({
	Name = "Emotes",
	Fields = { "unlockedEmoteIds", "emoteLoadout" },

	Default = function(_userId: number)
		return {
			unlockedEmoteIds = EmoteRegistry.GetDefaultUnlockedIds(),
			emoteLoadout = table.clone(EmoteConstants.DefaultLoadout),
		}
	end,

	Copy = function(profile: any)
		return {
			unlockedEmoteIds = table.clone(profile.unlockedEmoteIds),
			emoteLoadout = table.clone(profile.emoteLoadout),
		}
	end,

	Encode = function(profile: any)
		return {
			unlockedEmoteIds = profile.unlockedEmoteIds,
			emoteLoadout = profile.emoteLoadout,
		}
	end,

	Decode = function(raw: { [string]: any }, _userId: number)
		local unlockedEmoteIds: { [string]: true } = {}
		if Schema.IsTable(raw.unlockedEmoteIds) then
			for id, value in pairs(raw.unlockedEmoteIds :: { [string]: any }) do
				if Schema.IsString(id) and value == true then
					unlockedEmoteIds[id] = true
				end
			end
		end
		if next(unlockedEmoteIds) == nil then
			unlockedEmoteIds = EmoteRegistry.GetDefaultUnlockedIds()
		end

		local emoteLoadout: { string } = {}
		if Schema.IsTable(raw.emoteLoadout) then
			for _, id in ipairs(raw.emoteLoadout :: { any }) do
				if Schema.IsString(id) then
					table.insert(emoteLoadout, id)
				end
			end
		end
		if #emoteLoadout == 0 then
			emoteLoadout = table.clone(EmoteConstants.DefaultLoadout)
		end

		return { unlockedEmoteIds = unlockedEmoteIds, emoteLoadout = emoteLoadout }
	end,

	Migrations = {
		-- v1 -> v2: backfills the Emote System's persisted fields onto any record saved before it existed. Mutates and
		-- returns the record in place; only touches `Profile` when it is a table -- an already-malformed Profile is Decode's
		-- problem to degrade safely, not this function's to fix up.
		[1] = function(record: { [string]: any }): { [string]: any }
			local profile = record.Profile
			if Schema.IsTable(profile) then
				local profileTable = profile :: { [string]: any }
				if profileTable.unlockedEmoteIds == nil then
					profileTable.unlockedEmoteIds = EmoteRegistry.GetDefaultUnlockedIds()
				end
				if profileTable.emoteLoadout == nil then
					profileTable.emoteLoadout = table.clone(EmoteConstants.DefaultLoadout)
				end
			end
			return record
		end,
	},
})
