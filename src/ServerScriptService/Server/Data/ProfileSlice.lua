--!strict
--[[
	ProfileSlice.lua

	Owns: how a player's persisted profile is ASSEMBLED from the domains that own its fields, instead of by one
	1,800-line file that knows every domain's field. A slice is a group of top-level profile keys with the five things
	every persisted field needs -- a default, a copy, an encode, a decode, and the migration steps that backfill it -- written
	once, next to the domain that owns the field. `ProfileSlice.Compose` merges a list of slices into the four functions
	PlayerDataSystem exposes (`CreateDefaultProfile`, `CopyProfile`, `EncodeProfile`, `DecodeProfile`) and one migration table.

	WHY (coworking plan, 2026-10-25, F3). Adding a persisted field meant editing `Types`, `CreateDefaultProfile`,
	`CopyProfile`, `EncodeProfile`, `DecodeProfile` and `Migrations`, all inside PlayerDataSystem, by someone who does not
	own the domain. The five edits drifted: `CopyProfile` silently stopped copying three of the settings groups the day they
	were added, so `GetProfile` returned a profile that `EncodeProfile` would have saved differently. Inventory was the one
	domain that owned its own codec (`InventoryModel.Decode`) and it never drifted. A slice makes every domain do it that way,
	and makes the five edits ONE edit in one file.

	THE CONTRACT. A slice names the keys it `Fields` owns, and each of `Default/Copy/Encode/Decode` returns a table holding
	ONLY those keys (Compose asserts it: a slice that writes a key it does not own fails at boot, loudly, rather than
	overwriting another domain's field). No two slices may own the same key. A nil value is simply an absent key.
	  Default(userId)           -> the keys a brand-new player starts with.
	  Copy(profile)             -> a copy deep enough that the caller cannot mutate the live profile through it.
	  Encode(profile)           -> the DataStore-safe record for those keys. An explicit field list, never the live table.
	  Decode(rawProfile, userId)-> the keys from an UNTRUSTED stored table, each degrading to its default. Never errors.
	  Migrations[n](record)     -> the step that turns a version-n STORED RECORD (`{ SchemaVersion, Profile, ... }`) into
	                               version n+1, touching only its own fields.

	MIGRATIONS STAY ONE ORDERED CHAIN KEYED BY VERSION. A slice contributes steps; it does not own the version number
	(`Constants.PlayerData.SchemaVersion` does) and it cannot re-order history. For a given `n`, the steps of every slice that
	declares `n` run in the order the slices were listed; PlayerDataSystem.MigrateRecord then moves on to `n+1`.

	STORAGE IS FROZEN. This reorganises code, not the persisted shape: every field name, nesting, default and migration is
	exactly what it was. Tests/PlayerData/ProfileRoundTrip.spec.lua pins 1,161 stored records to the byte through it.

	Does not own: what any field MEANS (each domain), when a profile loads or saves, the lock and WriteGeneration (PlayerDataSystem),
	or the composed list itself (Server/Data/ProfileSlices.lua -- adding a slice is one line there, and nothing in PlayerDataSystem).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Schema = require(ReplicatedStorage.Shared.Schema)

local ProfileSlice = {}

export type Profile = { [string]: any }
export type Record = { [string]: any }

export type Slice = {
	Name: string,
	Fields: { string },
	Default: (userId: number) -> Profile,
	Copy: (profile: any) -> Profile,
	Encode: (profile: any) -> Profile,
	Decode: (raw: Profile, userId: number) -> Profile,
	Migrations: { [number]: (record: Record) -> Record }?,
}

export type Composite = {
	Slices: { Slice },
	-- Every key some slice owns.
	Fields: { [string]: string },
	Default: (userId: number) -> Profile,
	Copy: (profile: any) -> Profile,
	Encode: (profile: any) -> Profile,
	Decode: (raw: Profile, userId: number) -> Profile,
	-- version -> the combined step, or absent when no slice has one for that version.
	Migrations: { [number]: (record: Record) -> Record },
}

-- Validates a slice's shape. Returns it unchanged so a slice file can `return ProfileSlice.Define({ ... })`.
function ProfileSlice.Define(slice: Slice): Slice
	assert(Schema.IsString(slice.Name) and slice.Name ~= "", "ProfileSlice.Define: a slice needs a Name")
	assert(#slice.Fields > 0, `ProfileSlice.Define({slice.Name}): a slice owns at least one field`)
	for _, name in { "Default", "Copy", "Encode", "Decode" } do
		assert(
			Schema.IsFunction((slice :: any)[name]),
			`ProfileSlice.Define({slice.Name}): missing the {name} function`
		)
	end
	return slice
end

-- Keeps only what `slice` is allowed to write, failing loudly on anything else.
local function guarded(slice: Slice, owned: { [string]: boolean }, produced: Profile, into: Profile, what: string): ()
	for key, value in produced do
		if not owned[key] then
			error(
				`ProfileSlice: slice "{slice.Name}" produced the key "{tostring(key)}" from {what} but does not own it`
			)
		end
		into[key] = value
	end
end

function ProfileSlice.Compose(slices: { Slice }): Composite
	local fields: { [string]: string } = {}
	local owners: { { [string]: boolean } } = {}
	for index, slice in slices do
		ProfileSlice.Define(slice)
		local owned: { [string]: boolean } = {}
		for _, field in slice.Fields do
			assert(
				fields[field] == nil,
				`ProfileSlice.Compose: "{field}" is owned by both "{fields[field]}" and "{slice.Name}"`
			)
			fields[field] = slice.Name
			owned[field] = true
		end
		owners[index] = owned
	end

	local function run(pick: (slice: Slice) -> Profile, what: string): Profile
		local out: Profile = {}
		for index, slice in slices do
			guarded(slice, owners[index], pick(slice), out, what)
		end
		return out
	end

	-- Chains the steps of every slice that declares version `n`, in slice order.
	local steps: { [number]: { (record: Record) -> Record } } = {}
	for _, slice in slices do
		for version, step in slice.Migrations or {} do
			steps[version] = steps[version] or {}
			table.insert(steps[version], step)
		end
	end
	local migrations: { [number]: (record: Record) -> Record } = {}
	for version, chain in steps do
		migrations[version] = function(record: Record): Record
			local current = record
			for _, step in chain do
				current = step(current)
			end
			return current
		end
	end

	return {
		Slices = slices,
		Fields = fields,
		Default = function(userId: number): Profile
			return run(function(slice)
				return slice.Default(userId)
			end, "Default")
		end,
		Copy = function(profile: any): Profile
			return run(function(slice)
				return slice.Copy(profile)
			end, "Copy")
		end,
		Encode = function(profile: any): Profile
			return run(function(slice)
				return slice.Encode(profile)
			end, "Encode")
		end,
		Decode = function(raw: Profile, userId: number): Profile
			return run(function(slice)
				return slice.Decode(raw, userId)
			end, "Decode")
		end,
		Migrations = migrations,
	}
end

return ProfileSlice
