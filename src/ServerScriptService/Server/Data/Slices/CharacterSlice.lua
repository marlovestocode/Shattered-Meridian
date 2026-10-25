--!strict
--[[
	CharacterSlice.lua

	Owns: the character-creation fields of a profile -- `raceId`, `displayName` and `attributes` (the six-field AttributeBlock) --
	and how they are defaulted, copied, encoded and decoded. Moved here out of PlayerDataSystem (coworking plan W5, 2026-10-25)
	unchanged; the round-trip corpus (Tests/PlayerData/ProfileRoundTrip.spec.lua) pins it to the byte. Types.PlayerProfile's
	own contract: displayName and attributes are both nil exactly when raceId is nil (a player who has not been through
	chargen), so every default here is nil and Copy is nil-safe.

	DECODE. A malformed string field degrades to nil, never to a fabricated value. `attributes` is a fixed six-field RECORD, not
	an open dict: there is no safe "partial" default for a stat block (a record missing Fleetness is not a meaningfully degraded
	but usable profile), so every field is type-checked and a single missing or wrong-typed one discards the WHOLE block back to
	nil rather than inventing a value for the missing one.

	No migrations: these fields predate the schema versions.

	Does not own: race/attribute rules or the chargen flow (CharacterCreationSystem).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Schema = require(ReplicatedStorage.Shared.Schema)
local ProfileSlice = require(script.Parent.Parent.ProfileSlice)

local ATTRIBUTE_KEYS = { "Vitality", "Fortitude", "MeridianFlow", "Might", "Pressure", "Fleetness" }

return ProfileSlice.Define({
	Name = "Character",
	Fields = { "raceId", "displayName", "attributes" },

	Default = function(_userId: number)
		return {}
	end,

	Copy = function(profile: any)
		return {
			raceId = profile.raceId,
			displayName = profile.displayName,
			-- table.clone is nil-safe to call conditionally, not unconditionally: attributes stays nil for any player who
			-- has not been through chargen, and table.clone(nil) would throw.
			attributes = if profile.attributes then table.clone(profile.attributes) else nil,
		}
	end,

	Encode = function(profile: any)
		return {
			raceId = profile.raceId,
			displayName = profile.displayName,
			attributes = profile.attributes,
		}
	end,

	Decode = function(raw: { [string]: any }, _userId: number)
		local attributes: { [string]: number }? = nil
		if Schema.IsTable(raw.attributes) then
			local rawAttributes = raw.attributes :: { [string]: any }
			local block: { [string]: number } = {}
			local complete = true
			for _, key in ATTRIBUTE_KEYS do
				local value = rawAttributes[key]
				if Schema.IsNumber(value) then
					block[key] = value
				else
					complete = false
				end
			end
			if complete then
				attributes = block
			end
		end

		return {
			raceId = if Schema.IsString(raw.raceId) then raw.raceId else nil,
			displayName = if Schema.IsString(raw.displayName) then raw.displayName else nil,
			attributes = attributes,
		}
	end,
})
