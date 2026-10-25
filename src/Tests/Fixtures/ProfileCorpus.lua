--!strict
--[[
	ProfileCorpus.lua

	A frozen corpus of stored player records, REAL-SHAPED: what PlayerDataSystem wrote to the DataStore at each schema
	version, v1 to v11, and the v11 record with every field corrupted one at a time. Written BEFORE any profile field was
	moved out of PlayerDataSystem (coworking plan W5, 2026-10-25) so the move could be proved byte-identical:
	Tests/Fixtures/ProfileCorpusExpected.lua holds, for each case, the digest of what the code of that day made of it, and
	Tests/PlayerData/ProfileRoundTrip.spec.lua asserts the code of today still makes the same thing.

	WHAT A CASE PROVES. Each case is a stored record `{ SchemaVersion, Profile, WriteGeneration, Lock }` (or junk). The spec
	runs MigrateRecord -> DecodeProfile -> EncodeProfile on a deep copy and digests (a) the migrated record and (b) the
	re-encoded profile. (a) catches a migration that stopped running or changed; (b) catches a decoder, a default or an
	encoder that changed. A corruption case is the same record with ONE field replaced by something a hand-edited or
	rolled-back record could hold.

	DO NOT EDIT THE EXISTING CASES. Adding a case means adding an Expected entry generated from the code at the commit that
	added it. Changing one makes the proof meaningless.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local PlayerDataSystem = require(ServerScriptService.Server.Systems.PlayerDataSystem)
local Canonical = require(ServerScriptService.Tests.TestHelpers.Canonical)

local NAN = 0 / 0

-- The id a record is decoded under when its own userId is missing or wrong (the DataStore key, in the live path).
local FALLBACK_USER_ID = 999

local ProfileCorpus = {}

export type Case = { Name: string, Record: any }

-- The current (v11) record, as a long-lived player's would look: every optional block populated.
local function current(): { [string]: any }
	return {
		SchemaVersion = 11,
		WriteGeneration = 7,
		Lock = { JobId = "job-abc", ExpiresAt = 1700000000 },
		Profile = {
			userId = 1234,
			faction = "Wardens",
			raceId = "Human",
			displayName = "Ryu",
			attributes = { Vitality = 3, Fortitude = 2, MeridianFlow = 4, Might = 5, Pressure = 1, Fleetness = 2 },
			tier = 3,
			bloodlineIds = { "b-one", "b-two" },
			bloodlineStageProgress = { ["b-one"] = 2 },
			bloodlineRerolls = 2,
			artMastery = { common_foundation = 12, second_art = 3.5 },
			-- A DataStore round trip stringifies integer keys; both forms are real.
			equippedArts = { ["1"] = "common_foundation", ["4"] = "second_art", [2] = "third_art" },
			corruption = 5.5,
			qiDeviationRisk = 0.25,
			factionStanding = 40,
			hasAscended = false,
			meridianXp = 1200,
			unlockedEmoteIds = { wave = true, dance = true, bow = true },
			emoteLoadout = { "wave", "dance", "bow" },
			inventory = {
				Items = { Coal = 5, Water = 2, ["Weapon/TestBlade"] = 1 },
				Order = { "Coal", "Water", "Weapon/TestBlade" },
			},
			settings = {
				Keybinds = {
					Evade = { KeyCode = "Q" },
					Roll = { KeyCode = "R" },
					NotAnAction = { KeyCode = "Z" },
					HotbarSlot1 = { KeyCode = "One" },
				},
				GamepadKeybinds = { Evade = { KeyCode = "ButtonB" }, Attack = { UserInputType = "MouseButton1" } },
				Autorun = true,
				Parkour = {
					Enabled = true,
					CameraEffects = false,
					CoyoteTime = true,
					JumpBuffer = false,
					AutoVault = true,
					LedgeAssist = true,
					StepAssist = false,
					SprintMode = "Toggle",
				},
				Comfort = { CameraShake = false, FieldOfViewEffects = true, VehicleCameraMotion = false },
				Gamepad = {
					LookSensitivity = 1.75,
					MoveDeadzone = 0.2,
					LookDeadzone = 0.15,
					InvertLookY = true,
					Vibration = false,
				},
				UI = { Scale = 1.25 },
			},
		},
	}
end

-- The shape each earlier version stored: `current` minus what did not exist yet.
local function atVersion(version: number): { [string]: any }
	local record = current()
	local profile = record.Profile
	record.SchemaVersion = version

	if version < 11 then
		profile.inventory = nil
		profile.blimpFuel = { Coal = 4, Water = 1.5 }
	end
	if version < 10 then
		profile.settings.UI = nil
	end
	if version < 9 then
		profile.blimpFuel = nil
	end
	if version < 8 then
		profile.bloodlineRerolls = nil
	end
	if version < 7 then
		profile.bloodlineStageProgress = nil
	end
	if version < 6 then
		profile.settings.Comfort = nil
	end
	if version < 5 then
		profile.settings.Parkour = nil
	end
	if version < 4 then
		profile.equippedArts = nil
	end
	if version < 3 then
		profile.settings = nil
	end
	if version < 2 then
		profile.unlockedEmoteIds = nil
		profile.emoteLoadout = nil
	end
	-- The Gamepad group never had a migration: it is simply absent from every record before it shipped.
	if version < 11 and profile.settings then
		profile.settings.Gamepad = nil
	end
	return record
end

local HOSTILE: { any } = {
	NAN,
	math.huge,
	-math.huge,
	-1,
	0,
	"",
	"x",
	string.rep("z", 300),
	true,
	{},
	{ 1, 2 },
	{ a = 1 },
}

-- Every single-field corruption of `record.Profile`, at every depth of plain tables, plus the field removed.
local function corruptions(record: { [string]: any }): { Case }
	local cases: { Case } = {}

	local function describe(path: { any }): string
		local parts = {}
		for _, key in path do
			table.insert(parts, tostring(key))
		end
		return table.concat(parts, ".")
	end

	local function rebuilt(path: { any }, replacement: any, removeIt: boolean): any
		local copy = table.clone(record)
		copy.Profile = table.clone(record.Profile)
		local cursor: any = copy.Profile
		for index, key in path do
			if index == #path then
				cursor[key] = if removeIt then nil else replacement
			else
				cursor[key] = table.clone(cursor[key])
				cursor = cursor[key]
			end
		end
		return copy
	end

	local function walk(path: { any })
		local label = describe(path)
		for index, bad in HOSTILE do
			table.insert(cases, { Name = `corrupt/{label}/{index}`, Record = rebuilt(path, bad, false) })
		end
		table.insert(cases, { Name = `corrupt/{label}/removed`, Record = rebuilt(path, nil, true) })

		local node: any = record.Profile
		for _, key in path do
			node = node[key]
		end
		if typeof(node) == "table" then
			local keys = {}
			for key in node do
				table.insert(keys, key)
			end
			table.sort(keys, function(a: any, b: any)
				return tostring(a) < tostring(b)
			end)
			for _, key in keys do
				local deeper = table.clone(path)
				table.insert(deeper, key)
				walk(deeper)
			end
		end
	end

	local top = {}
	for key in record.Profile do
		table.insert(top, key)
	end
	table.sort(top)
	for _, key in top do
		walk({ key })
	end
	return cases
end

-- Every case, in a fixed order.
function ProfileCorpus.Cases(): { Case }
	local cases: { Case } = {}
	for version = 1, 11 do
		table.insert(cases, { Name = `version/{version}`, Record = atVersion(version) })
	end
	-- A record with no SchemaVersion at all is read as v1.
	local unversioned = atVersion(1)
	unversioned.SchemaVersion = nil
	table.insert(cases, { Name = "version/missing", Record = unversioned })
	-- A record from a FUTURE version is not migrated and not rejected.
	local future = atVersion(11)
	future.SchemaVersion = 99
	table.insert(cases, { Name = "version/future", Record = future })

	for _, case in corruptions(atVersion(11)) do
		table.insert(cases, case)
	end

	-- Old records with one corrupted migration-relevant field.
	for _, version in { 1, 5, 9, 10 } do
		for index, bad in HOSTILE do
			local record = atVersion(version)
			record.Profile.blimpFuel = bad
			table.insert(cases, { Name = `old/{version}/blimpFuel/{index}`, Record = record })
		end
	end

	-- Junk where a record should be.
	for index, junk in { 5, "record", true, NAN } do
		table.insert(cases, { Name = `junk/{index}`, Record = junk })
	end
	table.insert(cases, { Name = "junk/emptyTable", Record = {} })
	table.insert(cases, { Name = "junk/noProfile", Record = { SchemaVersion = 11 } })
	table.insert(cases, { Name = "junk/profileNotTable", Record = { SchemaVersion = 3, Profile = "x" } })
	return cases
end

-- What PlayerDataSystem makes of one stored record, as two digests: the migrated record, and the profile decoded from it
-- and re-encoded. Exactly the load path's order (loadProfile): MigrateRecord, then DecodeProfile on `.Profile`. A record
-- that is not a table never reaches MigrateRecord in the live path (ComputeLoadClaim hands it a table), so it is decoded
-- as an absent profile.
function ProfileCorpus.Fingerprint(record: any): (string, string)
	local copy = Canonical.DeepCopy(record)
	local migratedDigest = "not-a-table"
	local rawProfile: any = nil
	if typeof(copy) == "table" then
		local migrated = PlayerDataSystem.MigrateRecord(copy)
		migratedDigest = Canonical.Digest(migrated)
		rawProfile = migrated.Profile
	end
	local decoded = PlayerDataSystem.DecodeProfile(FALLBACK_USER_ID, rawProfile)
	local encodedDigest = if decoded then Canonical.Digest(PlayerDataSystem.EncodeProfile(decoded)) else "nil"
	return migratedDigest, encodedDigest
end

-- The defaults a brand-new player gets, encoded.
function ProfileCorpus.DefaultDigest(): string
	return Canonical.Digest(PlayerDataSystem.EncodeProfile(PlayerDataSystem.CreateDefaultProfile(FALLBACK_USER_ID)))
end

return ProfileCorpus
