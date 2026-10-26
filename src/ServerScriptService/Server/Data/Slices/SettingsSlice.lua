--!strict
--[[
	SettingsSlice.lua

	Owns: the Settings System's persisted profile field -- `settings` (Types.PlayerSettings: rebound keybind overrides for keyboard and
	gamepad, Autorun, and the Parkour / Comfort / Gamepad / UI preference groups) -- and everything about how it is defaulted, copied,
	encoded, decoded and backfilled, including the keybind <-> string conversion DataStores force (they cannot hold an EnumItem). Moved
	here out of PlayerDataSystem (coworking plan W5, 2026-10-25); the round-trip corpus (Tests/PlayerData/ProfileRoundTrip.spec.lua)
	pins the persisted bytes to what they were.

	It also exports the helpers SettingsSystem and the specs need: CreateDefault{Parkour,Comfort,UI,Gamepad}Settings, EncodeSettings and
	DecodeSettings. They live HERE because they are the settings group's own definition of "default" and "valid", not PlayerDataSystem's.

	ONE BEHAVIOUR DIFFERENCE, deliberate (escalation E3 in the coworking plan). PlayerDataSystem.CopyProfile used to copy only
	Keybinds, GamepadKeybinds, Autorun and Parkour: Comfort, Gamepad and UI were dropped from every snapshot GetProfile handed out, so
	SettingsSystem's GetSettings reply (which returns the snapshot's settings) omitted three of the seven groups and a player's saved
	camera-comfort, controller and UI-scale choices never reached their client on join. Copy here copies every group, and defaults a
	missing one the way Encode does. Persistence is unaffected (Encode always read the live profile).

	Does not own: what a setting DOES (the client systems that read it), how a client writes one (SettingsSystem), or the shipped
	defaults' values (Shared/Parkour/ParkourConstants, Constants.Settings).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local Constants = require(ReplicatedStorage.Shared.Constants)
local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local Schema = require(ReplicatedStorage.Shared.Schema)
local ProfileSlice = require(script.Parent.Parent.ProfileSlice)

local SettingsSlice = {}

-- Settings System encode/decode helpers (Types.PlayerSettings) -- module-local since nothing
-- outside this file's own Encode/Decode/EncodeSettings/DecodeSettings needs the raw
-- per-Keybind shape. DataStores cannot store an EnumItem directly (only nil/boolean/number/string/
-- table survive the round trip), unlike a RemoteEvent argument -- KeybindManager.Rebind/
-- SettingsSystem's own request handlers pass real Enum.KeyCode/Enum.UserInputType values over the
-- network with no conversion needed; only THIS persistence boundary has to stringify them.
local function encodeKeybind(keybind: Types.Keybind): { [string]: string }?
	if keybind.KeyCode then
		return { KeyCode = keybind.KeyCode.Name }
	end
	if keybind.UserInputType then
		return { UserInputType = keybind.UserInputType.Name }
	end
	return nil
end

-- `Enum.KeyCode[name]`/`Enum.UserInputType[name]` throws for an unrecognized name (a hand-edited
-- record, or a name from a future/past engine version this Enum no longer -- or doesn't yet --
-- recognize) rather than returning nil, so this is pcall-guarded the same defensive way every other
-- DecodeProfile field is.
local function decodeKeybind(raw: unknown): Types.Keybind?
	if not Schema.IsTable(raw) then
		return nil
	end
	local rawTable = raw :: { [string]: any }

	if Schema.IsString(rawTable.KeyCode) then
		local ok, keyCode = pcall(function()
			return (Enum.KeyCode :: any)[rawTable.KeyCode]
		end)
		if ok and Schema.IsEnumItem(keyCode) then
			return { KeyCode = keyCode :: Enum.KeyCode }
		end
		return nil
	end

	if Schema.IsString(rawTable.UserInputType) then
		local ok, inputType = pcall(function()
			return (Enum.UserInputType :: any)[rawTable.UserInputType]
		end)
		if ok and Schema.IsEnumItem(inputType) then
			return { UserInputType = inputType :: Enum.UserInputType }
		end
		return nil
	end

	return nil
end

-- A key is only ever kept in a decoded Keybinds/GamepadKeybinds override map if it's both a real,
-- currently-known KeybindAction (Constants.Keybinds.Defaults is a complete map of every action, per
-- KeybindManager.lua's own header) AND not a hotbar slot (SettingsSystem's request handler already
-- rejects a HotbarSlot* rebind at the network boundary -- see that module's own header -- this is
-- the second, independent line of defense against a hand-edited/stale record smuggling one back in
-- through storage instead). This is exactly why Types.PlayerSettings' own header calls these SPARSE
-- override maps rather than a full snapshot: an action that's since been renamed or retired just
-- silently drops out of a loaded record instead of corrupting it.
local function isRebindableKeybindAction(action: string): boolean
	return (Constants.Keybinds.Defaults :: { [string]: any })[action] ~= nil and not string.match(action, "^HotbarSlot")
end

local function encodeKeybindOverrides(overrides: { [Types.KeybindAction]: Types.Keybind }): { [string]: any }
	local encoded: { [string]: any } = {}
	for action, keybind in overrides do
		local encodedKeybind = encodeKeybind(keybind)
		if encodedKeybind then
			encoded[action] = encodedKeybind
		end
	end
	return encoded
end

-- KeybindActions renamed since a record may have saved a binding under the old name, old -> new. The
-- rename has to happen HERE, not on the client: isRebindableKeybindAction drops any action no longer in
-- Defaults, so a binding saved under a retired name never reaches the client to be migrated there. A
-- binding under the old name is applied to the new one -- unless the record ALSO holds one under the new
-- name, which can only have been saved later and so wins. The next save re-encodes it under the new name.
-- Roll became Evade when the roll was replaced by the combat evade (docs/design/air-combat-and-evade.md).
local RENAMED_KEYBIND_ACTIONS: { [string]: string } = {
	Roll = "Evade",
}

local function decodeKeybindOverrides(raw: unknown): { [Types.KeybindAction]: Types.Keybind }
	local overrides: { [Types.KeybindAction]: Types.Keybind } = {}
	if not Schema.IsTable(raw) then
		return overrides
	end
	local rawTable = raw :: { [string]: any }
	for storedAction, rawKeybind in rawTable do
		local action = storedAction
		local renamed = if Schema.IsString(storedAction) then RENAMED_KEYBIND_ACTIONS[storedAction] else nil
		if renamed ~= nil then
			action = if rawTable[renamed] == nil then renamed else nil
		end
		if Schema.IsString(action) and isRebindableKeybindAction(action) then
			local keybind = decodeKeybind(rawKeybind)
			if keybind then
				overrides[action :: Types.KeybindAction] = keybind
			end
		end
	end
	return overrides
end

-- The Parkour System's own preference block, freshly built from whatever Shared/Parkour/
-- ParkourConstants.lua currently ships as the default. Read from that module rather than duplicated
-- as literals here, so "what does the game do out of the box" stays a one-file answer -- the same
-- single-source-of-truth rule the rest of that constants table is held to. Exported because
-- Migrations[4] below and DecodeSettings both need it, and because a spec should be able to assert
-- that a decoded record matches the shipped defaults without re-listing them.
function SettingsSlice.CreateDefaultParkourSettings(): Types.ParkourSettings
	local assists = ParkourConstants.Assists
	return {
		Enabled = ParkourConstants.Enabled,
		CameraEffects = true,
		CoyoteTime = assists.CoyoteTime,
		JumpBuffer = assists.JumpBuffer,
		AutoVault = assists.AutoVault,
		LedgeAssist = assists.LedgeAssist,
		StepAssist = assists.StepAssist,
		SprintMode = "Hold" :: Types.SprintMode,
	}
end

-- Field-by-field rather than a pass-through of the stored table, for the same reason EncodeProfile
-- below is: a stale or hand-edited record must not be able to introduce a key this build doesn't
-- know about, and a missing key must resolve to the shipped default rather than to nil (which would
-- read as "off" for every boolean and silently disable a player's assists on load).
local function decodeParkourSettings(raw: unknown): Types.ParkourSettings
	local defaults = SettingsSlice.CreateDefaultParkourSettings()
	if not Schema.IsTable(raw) then
		return defaults
	end
	local rawTable = raw :: { [string]: any }
	local function boolean(key: string, fallback: boolean): boolean
		local value = rawTable[key]
		return if Schema.IsBoolean(value) then value else fallback
	end
	return {
		Enabled = boolean("Enabled", defaults.Enabled),
		CameraEffects = boolean("CameraEffects", defaults.CameraEffects),
		CoyoteTime = boolean("CoyoteTime", defaults.CoyoteTime),
		JumpBuffer = boolean("JumpBuffer", defaults.JumpBuffer),
		AutoVault = boolean("AutoVault", defaults.AutoVault),
		LedgeAssist = boolean("LedgeAssist", defaults.LedgeAssist),
		StepAssist = boolean("StepAssist", defaults.StepAssist),
		SprintMode = if rawTable.SprintMode == "Toggle" then "Toggle" :: Types.SprintMode else defaults.SprintMode,
	}
end

-- The camera-comfort block's shipped defaults. Both true: the game's effects are ON out of the box
-- and this group is an opt-OUT, so a fresh profile, a migrated profile and a profile whose Comfort
-- table failed to decode all land on exactly the behavior every player has today. Exported for the
-- same reasons CreateDefaultParkourSettings above is -- Migrations[5] and decodeComfortSettings both
-- need it, and a spec should be able to assert a decoded record matches the shipped defaults without
-- re-listing them.
function SettingsSlice.CreateDefaultComfortSettings(): Types.ComfortSettings
	return {
		CameraShake = true,
		FieldOfViewEffects = true,
		VehicleCameraMotion = true,
	}
end

-- Field-by-field, same defensive posture and same reasoning as decodeParkourSettings above: a missing
-- key must resolve to the shipped default rather than to nil. That matters more here than it does for
-- the parkour assists, because nil reads as `false` for a boolean and `false` in THIS block means "an
-- effect the player never asked to disable is now silently off" -- a decode bug would look exactly
-- like a working accessibility setting, which is the hardest kind to notice is broken.
local function decodeComfortSettings(raw: unknown): Types.ComfortSettings
	local defaults = SettingsSlice.CreateDefaultComfortSettings()
	if not Schema.IsTable(raw) then
		return defaults
	end
	local rawTable = raw :: { [string]: any }
	local function boolean(key: string, fallback: boolean): boolean
		local value = rawTable[key]
		return if Schema.IsBoolean(value) then value else fallback
	end
	return {
		CameraShake = boolean("CameraShake", defaults.CameraShake),
		FieldOfViewEffects = boolean("FieldOfViewEffects", defaults.FieldOfViewEffects),
		-- A record written before this field existed decodes to the shipped default (on), which is what
		-- makes this an additive change with no migration of its own -- see this function's own header
		-- on why a missing key MUST NOT fall through to nil in this block specifically.
		VehicleCameraMotion = boolean("VehicleCameraMotion", defaults.VehicleCameraMotion),
	}
end

-- The interface block's shipped defaults, read straight off Constants.Settings.UI.Defaults rather
-- than restated here -- the same "one source of truth SettingsSystem's write validation also reads"
-- rule Gamepad's own defaults follow below. Exported for the same reasons CreateDefaultComfortSettings
-- above is.
function SettingsSlice.CreateDefaultUISettings(): Types.UISettings
	return {
		Scale = Constants.Settings.UI.Defaults.Scale,
	}
end

-- Field-by-field, same NaN-safe clamp-on-the-way-out posture as decodeGamepadSettings below -- a
-- stored Scale of 0 (or NaN) would not merely look wrong, it would make the whole UI unusable with
-- nothing on screen left to fix it from, so this can never trust a stored value further than the
-- bounds SettingsSystem already enforces on the way in.
local function decodeUISettings(raw: unknown): Types.UISettings
	local defaults = SettingsSlice.CreateDefaultUISettings()
	if not Schema.IsTable(raw) then
		return defaults
	end
	local rawTable = raw :: { [string]: any }
	local bounds = Constants.Settings.UI.Bounds
	local scale = Schema.Decode(Schema.Number(bounds.Scale.Min, bounds.Scale.Max), rawTable.Scale)
	if scale == nil then
		return defaults
	end
	return {
		Scale = scale,
	}
end

-- The gamepad stick block's shipped defaults, read straight off Constants.Settings.Gamepad.Defaults
-- rather than restated here -- that table is shared with Client/Input/Analog.lua (which builds its own
-- DEFAULT_CONFIG from it) and with SettingsSystem's write validation, so all three agree by
-- construction instead of by three people remembering the same five numbers.
function SettingsSlice.CreateDefaultGamepadSettings(): Types.GamepadSettings
	local defaults = Constants.Settings.Gamepad.Defaults
	return {
		LookSensitivity = defaults.LookSensitivity,
		MoveDeadzone = defaults.MoveDeadzone,
		LookDeadzone = defaults.LookDeadzone,
		InvertLookY = defaults.InvertLookY,
		Vibration = defaults.Vibration,
	}
end

-- Field-by-field, same defensive posture as decodeParkourSettings/decodeComfortSettings above, plus
-- one thing neither of those needs: the three NUMERIC fields are clamped, not just type-checked.
--
-- CLAMPING ON THE WAY OUT OF THE DATASTORE, not only on the way in. SettingsSystem already clamps
-- what a client may write, so a stored out-of-range value should be impossible -- but "should be
-- impossible" is exactly the class of thing a record written by an older build, a hand-edited test
-- profile, or a future bug can violate, and the failure is bad: a stored MoveDeadzone of 1 makes the
-- left stick dead, which reads to the player as a broken controller with nothing in the menu able to
-- explain it. NaN is caught by the same clamp -- math.clamp returns NaN for a NaN input, so it is
-- rejected explicitly first, since a NaN deadzone would fail every comparison in Analog.ApplyStick.
local function decodeGamepadSettings(raw: unknown): Types.GamepadSettings
	local defaults = SettingsSlice.CreateDefaultGamepadSettings()
	if not Schema.IsTable(raw) then
		return defaults
	end
	local rawTable = raw :: { [string]: any }
	local bounds = Constants.Settings.Gamepad.Bounds

	local function boolean(key: string, fallback: boolean): boolean
		local value = rawTable[key]
		return if Schema.IsBoolean(value) then value else fallback
	end
	local function number(key: string, fallback: number, min: number, max: number): number
		return Schema.Decode(Schema.Number(min, max), rawTable[key]) or fallback
	end

	return {
		LookSensitivity = number(
			"LookSensitivity",
			defaults.LookSensitivity,
			bounds.LookSensitivity.Min,
			bounds.LookSensitivity.Max
		),
		MoveDeadzone = number("MoveDeadzone", defaults.MoveDeadzone, bounds.Deadzone.Min, bounds.Deadzone.Max),
		LookDeadzone = number("LookDeadzone", defaults.LookDeadzone, bounds.Deadzone.Min, bounds.Deadzone.Max),
		InvertLookY = boolean("InvertLookY", defaults.InvertLookY),
		Vibration = boolean("Vibration", defaults.Vibration),
	}
end

-- Exported for the same reason every other pure encode/decode function in this file is (TestEZ
-- coverage with no live Player/DataStore) -- see file header.
--
-- EVERY SUB-TABLE IS DEFAULTED BEFORE IT IS READ, and that is a save-path safety requirement rather
-- than type-checker appeasement. Types.PlayerSettings says both blocks are non-optional, but this
-- function runs on the AUTOSAVE path against a live in-memory profile, and a live profile can reach
-- here with a block missing in ways the type system never sees: a record written by a build that
-- predates the block and rolled forward by a migration that was skipped, a rollback to an older
-- server, or any Transform caller that replaced `settings` wholesale. Indexing a nil sub-table there
-- does not degrade -- it throws inside the save, so the player's entire session fails to persist, and
-- it fails silently from their seat. Falling back to the shipped defaults costs one table construction
-- on a path that runs at autosave cadence and turns a data-loss bug into a no-op.
function SettingsSlice.EncodeSettings(settings: Types.PlayerSettings): { [string]: any }
	local parkour = settings.Parkour or SettingsSlice.CreateDefaultParkourSettings()
	local comfort = settings.Comfort or SettingsSlice.CreateDefaultComfortSettings()
	local gamepad = settings.Gamepad or SettingsSlice.CreateDefaultGamepadSettings()
	local ui = settings.UI or SettingsSlice.CreateDefaultUISettings()
	return {
		Keybinds = encodeKeybindOverrides(settings.Keybinds),
		GamepadKeybinds = encodeKeybindOverrides(settings.GamepadKeybinds),
		Autorun = settings.Autorun,
		-- Explicit field list, never the live table itself -- same defensive posture as EncodeProfile.
		-- Every field is already a DataStore-safe primitive, so there is nothing to convert.
		Parkour = {
			Enabled = parkour.Enabled,
			CameraEffects = parkour.CameraEffects,
			CoyoteTime = parkour.CoyoteTime,
			JumpBuffer = parkour.JumpBuffer,
			AutoVault = parkour.AutoVault,
			LedgeAssist = parkour.LedgeAssist,
			StepAssist = parkour.StepAssist,
			SprintMode = parkour.SprintMode,
		},
		Comfort = {
			CameraShake = comfort.CameraShake,
			FieldOfViewEffects = comfort.FieldOfViewEffects,
			VehicleCameraMotion = comfort.VehicleCameraMotion,
		},
		Gamepad = {
			LookSensitivity = gamepad.LookSensitivity,
			MoveDeadzone = gamepad.MoveDeadzone,
			LookDeadzone = gamepad.LookDeadzone,
			InvertLookY = gamepad.InvertLookY,
			Vibration = gamepad.Vibration,
		},
		UI = {
			Scale = ui.Scale,
		},
	}
end

function SettingsSlice.DecodeSettings(raw: unknown): Types.PlayerSettings
	if not Schema.IsTable(raw) then
		return {
			Keybinds = {},
			GamepadKeybinds = {},
			Autorun = false,
			Parkour = SettingsSlice.CreateDefaultParkourSettings(),
			Comfort = SettingsSlice.CreateDefaultComfortSettings(),
			Gamepad = SettingsSlice.CreateDefaultGamepadSettings(),
			UI = SettingsSlice.CreateDefaultUISettings(),
		}
	end
	local rawTable = raw :: { [string]: any }
	return {
		Keybinds = decodeKeybindOverrides(rawTable.Keybinds),
		GamepadKeybinds = decodeKeybindOverrides(rawTable.GamepadKeybinds),
		Autorun = if Schema.IsBoolean(rawTable.Autorun) then rawTable.Autorun else false,
		Parkour = decodeParkourSettings(rawTable.Parkour),
		Comfort = decodeComfortSettings(rawTable.Comfort),
		-- NO MIGRATION AND NO SchemaVersion BUMP FOR THIS GROUP, unlike Comfort's own Migrations[5].
		-- A record written before Gamepad existed has no such key, decodeGamepadSettings returns the
		-- shipped defaults for a nil table, and those defaults are exactly the behaviour every existing
		-- player already has -- so a migration would rewrite stored records to contain values they
		-- already decode to. That is the same additive argument decodeComfortSettings' own
		-- VehicleCameraMotion note makes for a new FIELD, applied to a new GROUP: what makes it safe is
		-- that this decoder defaults the whole table, not just its members.
		Gamepad = decodeGamepadSettings(rawTable.Gamepad),
		UI = decodeUISettings(rawTable.UI),
	}
end

-- The settings group as the profile sees it ------------------------------------------------------------------

SettingsSlice.Name = "Settings"
SettingsSlice.Fields = { "settings" }

function SettingsSlice.Default(_userId: number)
	return {
		settings = {
			Keybinds = {},
			GamepadKeybinds = {},
			Autorun = false,
			Parkour = SettingsSlice.CreateDefaultParkourSettings(),
			Comfort = SettingsSlice.CreateDefaultComfortSettings(),
			Gamepad = SettingsSlice.CreateDefaultGamepadSettings(),
			UI = SettingsSlice.CreateDefaultUISettings(),
		},
	}
end

-- A group missing from a live profile is defaulted rather than indexed (see EncodeSettings' note on how a live profile can reach
-- a copy or a save with a block missing); every present group is cloned one level, which is as deep as a settings group goes.
function SettingsSlice.Copy(profile: any)
	local settings = profile.settings
	local function group(value: any, default: () -> any): any
		return if Schema.IsTable(value) then table.clone(value) else default()
	end
	return {
		settings = {
			Keybinds = table.clone(settings.Keybinds),
			GamepadKeybinds = table.clone(settings.GamepadKeybinds),
			Autorun = settings.Autorun,
			Parkour = group(settings.Parkour, SettingsSlice.CreateDefaultParkourSettings),
			Comfort = group(settings.Comfort, SettingsSlice.CreateDefaultComfortSettings),
			Gamepad = group(settings.Gamepad, SettingsSlice.CreateDefaultGamepadSettings),
			UI = group(settings.UI, SettingsSlice.CreateDefaultUISettings),
		},
	}
end

function SettingsSlice.Encode(profile: any)
	return { settings = SettingsSlice.EncodeSettings(profile.settings) }
end

function SettingsSlice.Decode(raw: { [string]: any }, _userId: number)
	return { settings = SettingsSlice.DecodeSettings(raw.settings) }
end

-- The steps that backfilled the settings groups onto older records (v2 -> v3 the field itself, v4 -> v5 Parkour, v5 -> v6 Comfort,
-- v9 -> v10 UI). The Gamepad group never had one: see DecodeSettings.
SettingsSlice.Migrations = {} :: { [number]: (record: { [string]: any }) -> { [string]: any } }

-- v2 -> v3: backfills Types.PlayerProfile's `settings` field (the Settings System's persisted
-- keybind overrides + Autorun) onto any record saved before this pass -- same "only touch an
-- already-table Profile, only fill in a genuinely missing field" shape as Migrations[1] above.
-- DecodeSettings' own defensive decode handles anything short of a fully-missing field regardless
-- (a partially-populated settings table from a future rollback, say), so this only needs to cover
-- the "field doesn't exist at all yet" case.
SettingsSlice.Migrations[2] = function(raw: { [string]: any }): { [string]: any }
	local profile = raw.Profile
	if Schema.IsTable(profile) then
		local profileTable = profile :: { [string]: any }
		if profileTable.settings == nil then
			profileTable.settings = { Keybinds = {}, GamepadKeybinds = {}, Autorun = false }
		end
	end
	return raw
end

-- v4 -> v5: backfills Types.PlayerSettings' `Parkour` sub-table (the Parkour System's own
-- preferences) onto any record saved before this pass -- same "only touch an already-table Profile,
-- only fill in a genuinely missing field" shape as Migrations[1]/[2]/[3] above, one level deeper
-- because the field lives inside `settings` rather than on the profile itself.
--
-- Backfilled with the SHIPPED DEFAULTS (via createDefaultParkourSettings, which reads
-- ParkourConstants) rather than with an empty table or with everything switched off: an existing
-- player's first login after the update should give them the same movement every new player gets,
-- not a silently degraded version of it. DecodeSettings' own defensive decode already handles
-- anything short of a fully-missing field (a partially-populated table from a future rollback), so
-- this only has to cover the genuinely-absent case.
SettingsSlice.Migrations[4] = function(raw: { [string]: any }): { [string]: any }
	local profile = raw.Profile
	if Schema.IsTable(profile) then
		local profileTable = profile :: { [string]: any }
		local settings = profileTable.settings
		if Schema.IsTable(settings) and (settings :: { [string]: any }).Parkour == nil then
			(settings :: { [string]: any }).Parkour = SettingsSlice.CreateDefaultParkourSettings()
		end
	end
	return raw
end

-- v5 -> v6: backfills Types.PlayerSettings' `Comfort` sub-table (the camera-comfort accessibility
-- block) onto any record saved before this pass -- byte-for-byte the shape of Migrations[4] above,
-- one field over.
--
-- Backfilled with both effects ENABLED, which is the shipped default and therefore exactly what every
-- existing player already experiences. That is the whole point of the choice: a migration that lands
-- on the defaults changes nobody's game on their next login, it only means the switch now exists in
-- their menu. Backfilling with everything OFF would silently strip camera shake from the entire
-- existing player base, and backfilling with an empty table would leave decodeComfortSettings to fill
-- it in anyway -- correct, but it would make this migration a no-op that looks like it does something.
SettingsSlice.Migrations[5] = function(raw: { [string]: any }): { [string]: any }
	local profile = raw.Profile
	if Schema.IsTable(profile) then
		local profileTable = profile :: { [string]: any }
		local settings = profileTable.settings
		if Schema.IsTable(settings) and (settings :: { [string]: any }).Comfort == nil then
			(settings :: { [string]: any }).Comfort = SettingsSlice.CreateDefaultComfortSettings()
		end
	end
	return raw
end

-- v9 -> v10: backfills Types.PlayerSettings' `UI` sub-table (the interface-scale block) onto any
-- record saved before this pass -- byte-for-byte the shape Migrations[5] used for Comfort, one group
-- over. Backfilled at Scale = 1 (CreateDefaultUISettings' own shipped default), which is today's only
-- size and therefore exactly what every existing player's UI already looks like -- this migration
-- changes nobody's screen, it only means the slider now exists in their Settings tab.
SettingsSlice.Migrations[9] = function(raw: { [string]: any }): { [string]: any }
	local profile = raw.Profile
	if Schema.IsTable(profile) then
		local profileTable = profile :: { [string]: any }
		local settings = profileTable.settings
		if Schema.IsTable(settings) and (settings :: { [string]: any }).UI == nil then
			(settings :: { [string]: any }).UI = SettingsSlice.CreateDefaultUISettings()
		end
	end
	return raw
end

ProfileSlice.Define(SettingsSlice :: any)
return SettingsSlice
