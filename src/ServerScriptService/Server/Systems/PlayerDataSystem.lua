--!strict
--[[
	PlayerDataSystem.lua

	Owns: canonical player data read/write and DataStore integration (software-architecture.md).
	Every other System (TierSystem, BloodlineSystem, ArtSystem, FactionManager, MeridianSystem,
	QiDeviationSystem, AbsorbSystem, RewardSystem, AwakeningSystem, ...) reads and mutates a
	player's PlayerProfile exclusively through this module's public API -- never a direct
	DataStore call of their own. This is engineering-standards.md's data-integrity rule made
	concrete: "one serialized entry point per player's data."

	Does not own: any tier/bloodline/art/faction/qi BUSINESS LOGIC (what a mutation should be, when
	it should happen, whether a value crossed a threshold) -- those Systems decide WHAT to write via
	Transform's mutator callback; this module only owns WHETHER/WHEN/HOW that write reaches disk
	safely. Boots first in Main.server.lua (immediately after ModerationSystem, which must be even
	earlier for its own ban-kick-ordering reasons -- see that module's header) -- every other System
	that reads player data depends on this one being initialized already.

	Design decisions (shattered-meridian-studio's "design before you build" process):

	1. LOAD TIMING. A profile loads on Players.PlayerAdded (plus a defensive GetPlayers() loop at
	   Init() for anyone already connected when this boots -- the same pattern CombatSystem.lua/
	   AdminActionSystem.lua already use for their own PlayerAdded wiring, covering Studio Team
	   Create / a slow server boot). Nothing else in this codebase should assume a profile exists
	   the instant a player joins: IsLoaded/GetProfile/WaitForProfile below are how a caller finds
	   out, and Transform below refuses to mutate an unloaded profile rather than silently creating
	   one out of thin air. A player must never be able to act on a gameplay System before their
	   data exists -- every future System's own request handler is expected to gate on IsLoaded (or
	   block on WaitForProfile) before touching a player's profile, the same way CombatSystem
	   already gates every request on its own per-player state existing.

	2. SAVE TIMING. Three layers, each covering a failure mode the others don't:
	     - PlayerRemoving: saves unconditionally (not gated on the dirty flag -- see saveProfile's
	       own comment) the instant a player leaves normally. The common case.
	     - Periodic autosave (Constants.PlayerData.AutosaveIntervalSeconds): a crash/server-death
	       safety net for players who never trigger PlayerRemoving (server crash, region failover).
	       Only saves DIRTY profiles, respecting the DataStore write budget -- see that Constant's
	       own header for the budget math.
	     - game:BindToClose: a server-initiated shutdown (DevMenu's Shutdown Server tool, a
	       deploy) doesn't fire PlayerRemoving for players still connected at the moment Roblox
	       starts tearing the server down -- this saves every still-loaded profile in parallel,
	       bounded by Constants.PlayerData.ShutdownSaveTimeoutSeconds.

	3. CONCURRENCY-SAFE WRITES, WITHIN ONE SERVER. Transform(player, mutator) is the ONLY way any
	   System (this one included) mutates a loaded profile. It is not a lock in the traditional sense
	   -- Luau/Roblox scripts are cooperatively single-threaded, so as long as a mutator callback
	   never yields (task.wait, a DataStore/HTTP call, etc.), no two Transform calls for the same
	   player can ever interleave, which is the actual guarantee "one serialized entry point" needs
	   WITHIN a single server process. GetProfile deliberately returns a DEEP COPY (CopyProfile),
	   never the live table, so no caller can bypass Transform by mutating a "read" result -- the
	   same "read-only projection, never the live mutable state" contract CombatSystem.GetCombatState
	   already established for CombatSnapshot. This decision says nothing about two DIFFERENT
	   servers writing the same player's record -- see decision 7 below for that.

	4. SCHEMA VERSIONING. Every persisted record is a Types.StoredPlayerProfile
	   ({ SchemaVersion, Profile, WriteGeneration, Lock }), not a bare PlayerProfile. MigrateRecord
	   walks a loaded record forward through the (currently empty) Migrations table toward
	   Constants.PlayerData.SchemaVersion before DecodeProfile ever sees it -- see MigrateRecord's
	   own comment for why an empty table today is a real, tested skeleton and not a TODO.
	   WriteGeneration/Lock are deliberately NOT part of this versioned Profile payload or the
	   Migrations table -- see Types.StoredPlayerProfile's own header for why.

	5. LOAD-FAILURE HANDLING. A load-claim UpdateAsync failure (exhausted retries) or an undecodable
	   stored record NEVER falls back to a fresh/default profile -- doing so would let a subsequent
	   save silently overwrite a real save that merely failed to load this one time. Every such case
	   kicks the player with an explicit, distinct message (LoadFailureKickMessage /
	   CorruptDataKickMessage / LockHeldKickMessage / StaleSessionKickMessage -- see decision 7) instead
	   of guessing. A missing record (the claim UpdateAsync succeeds against a key that never held one)
	   is the ONLY case that legitimately creates CreateDefaultProfile -- that is a confirmed "this
	   player has never played before," not a failure being papered over.

	6. DATASTORE BUDGET. No per-Heartbeat, per-action, or per-request DataStore call anywhere in
	   this module -- every write is either an explicit Transform-triggered dirty flag drained by
	   the autosave loop (Constants.PlayerData.AutosaveIntervalSeconds), or a one-time
	   PlayerRemoving/BindToClose save. See that Constant's own header for the write-budget math.

	7. CROSS-SERVER CONCURRENCY (session lock + WriteGeneration). Decision 3 only protects against
	   two WRITES within one server racing each other; it says nothing about two DIFFERENT servers
	   both believing they own the same player's record, which a server hop (ServerHopSystem.lua's
	   TeleportAsync to another server of this same place) makes a real, everyday occurrence: server
	   A's PlayerRemoving-triggered save and server B's load for the SAME player can genuinely overlap
	   in wall-clock time. Two independent layers close this, in order:
	     - A Types.PlayerDataLock claimed via UpdateAsync at load time (loadProfile), retried with
	       backoff against a live foreign lock (Constants.PlayerData.LockClaimMaxAttempts/
	       LockClaimRetryBackoffSeconds) before giving up and kicking with LockHeldKickMessage.
	       Released (not refreshed) at the FINAL save only (PlayerRemoving/BindToClose,
	       saveProfile's `releaseLock` argument) -- never refreshed mid-session, since Roblox never
	       routes a second PlayerAdded for an already-connected player to a different server, so a
	       live server's own lock is never actually contended; only a server that crashed without
	       ever reaching PlayerRemoving/BindToClose leaves one dangling, handled by treating a lock
	       older than LockStaleAfterSeconds as abandoned (IsLockHeldByOther).
	     - A monotonic WriteGeneration bumped by every successful saveProfile, checked by
	       ComputeSaveWrite against whatever generation is CURRENTLY stored at save time -- refuses
	       (rather than overwrites) if a newer generation already exists. The lock above should make
	       this rare in practice, not impossible (a lock gone stale while its holder was still
	       legitimately alive, say); when it trips mid-session, runAutosaveLoop kicks the player with
	       StaleSessionKickMessage rather than let further play accumulate on data that can no longer
	       reach disk safely.
	   Both are pure decision functions (IsLockHeldByOther/ComputeLoadClaim/ComputeLockRelease/
	   ComputeSaveWrite) that the actual UpdateAsync callbacks are one-line calls into -- see each
	   one's own header, and this file's "Cross-server session lock + WriteGeneration" section.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")

local Types = require(ReplicatedStorage.Shared.Types)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local DataStoreRetry = require(ReplicatedStorage.Shared.DataStoreRetry)
local EmoteConstants = require(ReplicatedStorage.Shared.EmoteConstants)
local EmoteRegistry = require(ReplicatedStorage.Shared.Emotes.EmoteRegistry)
-- Only for EquipSlotCount, the bound DecodeProfile validates a persisted art slot index against --
-- this module owns no art rules of its own beyond "a slot outside the real hotbar isn't a slot."
local ArtConstants = require(ReplicatedStorage.Shared.ArtConstants)
-- Read for exactly one purpose: CreateDefaultParkourSettings below, so the shipped defaults for the
-- Parkour System's persisted preferences come from that feature's own constants table rather than
-- being duplicated as literals in this file.
local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local StorageConfig = require(script.Parent.Parent.Config.StorageConfig)

local PlayerDataSystem = {}

local logger = Logger.scope("PlayerDataSystem")

local Config = Constants.PlayerData

-- Obtained lazily inside Init(), never at module load time -- same "require() stays
-- side-effect-free, safe for the headless test harness's load-check" contract BugReportSystem.lua/
-- ModerationSystem.lua already establish for their own DataStore handles.
local dataStore: DataStore? = nil

-- The one live table of loaded profiles -- every OTHER per-player table below (dirtyPlayers,
-- failedLoads) is auxiliary bookkeeping about entries in this one. Never exposed directly; see
-- GetProfile/CopyProfile for why every read is a deep copy instead of this table's own reference.
local loadedProfiles: { [Player]: Types.StoredPlayerProfile } = {}

-- Profiles mutated (via Transform) since their last successful save -- the autosave loop below
-- only ever writes entries present here, and clears an entry the moment its save succeeds. Kept
-- separate from loadedProfiles itself (rather than a per-profile field) so "is this profile
-- dirty" stays a plain O(1) table lookup the autosave loop can iterate without touching profile
-- internals.
local dirtyPlayers: { [Player]: boolean } = {}

-- Players whose load genuinely failed (storage error or undecodable record) -- consulted only by
-- WaitForProfile, so a caller waiting on a player who is mid-kick doesn't block the full timeout
-- for a load that will never succeed. Never populated for the legitimate "no record yet" path.
local failedLoads: { [Player]: boolean } = {}

-- One save in flight per player at a time -- see saveProfile's own header for the race this closes.
-- Four independent callers (autosave, PlayerRemoving, BindToClose, ResetProfile) can each decide to
-- save the SAME player around the same moment, and saveProfile itself yields for the whole
-- UpdateAsync round trip -- without this, two overlapping calls both capture the SAME
-- stored.WriteGeneration before either commits, and whichever's UpdateAsync lands second gets
-- rejected by ComputeSaveWrite's own generation backstop. That's not just a wasted write: when the
-- rejected one was the FINAL save (releaseLock = true), the Lock this server wrote on ITS OWN
-- earlier, accepted save survives untouched in the DataStore, so the next server to load this
-- profile waits out the full LockStaleAfterSeconds for a lock nothing is still holding.
local saveInFlight: { [Player]: boolean } = {}

-- Fired (player: Player) the instant that player's profile finishes loading successfully -- per
-- this file's own "no live mutable state leaves this module" rule, listeners are expected to call
-- GetProfile(player) themselves rather than have a snapshot threaded through the event payload,
-- the same "BindableEvent signals identity, callers read state via the public API" shape
-- CombatSystem.OnPlayerKilled already establishes in this codebase.
PlayerDataSystem.OnProfileLoaded = Instance.new("BindableEvent")

-- Fired (player: Player) when a load genuinely fails (after this module has already kicked them --
-- see loadProfile). Exists mainly so WaitForProfile can stop waiting immediately instead of
-- blocking out its full timeout for a player who is already being disconnected.
PlayerDataSystem.OnProfileLoadFailed = Instance.new("BindableEvent")

-- Local, non-exported retry/backoff wrapper -- delegates to Shared/DataStoreRetry.lua (see that
-- module's header for why PlayerDataSystem is the third caller that earned its extraction).
-- Every call site below keeps the exact same withRetry(operationName, attempt) shape
-- BugReportSystem.lua/ModerationSystem.lua's own local withRetry already established, so nothing
-- about this module's DataStore call sites looks different from that precedent.
local function withRetry<T>(operationName: string, attempt: () -> T): (boolean, T?, string?)
	return DataStoreRetry.Attempt(logger, operationName, {
		MaxAttempts = Config.StorageRetryMaxAttempts,
		BaseBackoffSeconds = Config.StorageRetryBaseBackoffSeconds,
	}, attempt)
end

--
-- Pure logic -- default construction, encode/decode, migration, mutation application. Every
-- function in this section is exported specifically so TestEZ can exercise it without a live
-- Player or a real DataStore, the same "pure logic gets its own export" precedent
-- BugReportSystem.ValidateCategory/ComputeOpenCountDelta and ModerationSystem.IsRecordActive/
-- ComputeSuspicionCountDelta already established.
--

-- A brand-new player's starting profile -- the ONLY place a default profile is legitimately
-- constructed (see this file's header, design decision 5: a FAILED load must never reach here).
function PlayerDataSystem.CreateDefaultProfile(userId: number): Types.PlayerProfile
	return {
		userId = userId,
		faction = nil,
		raceId = nil,
		displayName = nil,
		attributes = nil,
		tier = Config.DefaultTier,
		bloodlineIds = {},
		artMastery = {},
		-- Art System (Types.PlayerProfile's own header) -- empty, not a seeded starter slot, for the
		-- same reason ArtConstants.StartingArtIds is empty: an art is earned, and there is nothing to
		-- equip until the player unlocks one.
		equippedArts = {},
		corruption = 0,
		qiDeviationRisk = 0,
		factionStanding = 0,
		hasAscended = false,
		meridianXp = 0,
		-- Emote System (Types.PlayerProfile's own header) -- a brand-new profile starts with every
		-- Default-unlock emote already granted and the 8-emote starter loadout in place, so a
		-- first-time player never sees an empty wheel while waiting on EmoteUnlockService's own
		-- join-time backfill (that backfill exists for OLDER saves, not this path).
		unlockedEmoteIds = EmoteRegistry.GetDefaultUnlockedIds(),
		emoteLoadout = table.clone(EmoteConstants.DefaultLoadout),
		-- Settings System (Types.PlayerSettings' own header) -- a brand-new profile starts with no
		-- overrides at all (every action still resolves through Constants.Keybinds.Defaults/
		-- GamepadDefaults), Autorun off, and the Parkour System's own preferences at whatever
		-- Shared/Parkour/ParkourConstants.lua currently ships as the defaults.
		settings = {
			Keybinds = {},
			GamepadKeybinds = {},
			Autorun = false,
			Parkour = PlayerDataSystem.CreateDefaultParkourSettings(),
		},
	}
end

-- Deep-enough copy of a PlayerProfile -- every field is either a primitive, a flat array of
-- strings (bloodlineIds), or a flat dict (artMastery's id -> number, equippedArts' slot -> id), so a
-- one-level table.clone on each nested container is sufficient; there is no third level of nesting
-- anywhere in this shape.
-- This is what GetProfile/WaitForProfile hand back instead of the live table -- see this file's
-- header, design decision 3, for why that's load-bearing for Transform being the only mutation
-- path.
function PlayerDataSystem.CopyProfile(profile: Types.PlayerProfile): Types.PlayerProfile
	return {
		userId = profile.userId,
		faction = profile.faction,
		raceId = profile.raceId,
		displayName = profile.displayName,
		-- table.clone is nil-safe to call conditionally, not unconditionally -- attributes stays nil
		-- for any player who hasn't been through chargen yet (Types.PlayerProfile's own contract:
		-- displayName/attributes are both nil exactly when raceId is nil), and table.clone(nil) would
		-- throw.
		attributes = if profile.attributes then table.clone(profile.attributes) else nil,
		tier = profile.tier,
		bloodlineIds = table.clone(profile.bloodlineIds),
		artMastery = table.clone(profile.artMastery),
		equippedArts = table.clone(profile.equippedArts),
		corruption = profile.corruption,
		qiDeviationRisk = profile.qiDeviationRisk,
		factionStanding = profile.factionStanding,
		hasAscended = profile.hasAscended,
		meridianXp = profile.meridianXp,
		unlockedEmoteIds = table.clone(profile.unlockedEmoteIds),
		emoteLoadout = table.clone(profile.emoteLoadout),
		settings = {
			Keybinds = table.clone(profile.settings.Keybinds),
			GamepadKeybinds = table.clone(profile.settings.GamepadKeybinds),
			Autorun = profile.settings.Autorun,
			-- One more level of nesting than this function's own header describes -- the Parkour block
			-- is a flat table of primitives inside `settings`, so a table.clone of it is still a
			-- sufficient copy, and Transform remains the only path that can mutate the live profile.
			Parkour = table.clone(profile.settings.Parkour),
		},
	}
end

-- Settings System encode/decode helpers (Types.PlayerSettings) -- module-local since nothing
-- outside this file's own EncodeProfile/DecodeProfile/EncodeSettings/DecodeSettings needs the raw
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
	if typeof(raw) ~= "table" then
		return nil
	end
	local rawTable = raw :: { [string]: any }

	if typeof(rawTable.KeyCode) == "string" then
		local ok, keyCode = pcall(function()
			return (Enum.KeyCode :: any)[rawTable.KeyCode]
		end)
		if ok and typeof(keyCode) == "EnumItem" then
			return { KeyCode = keyCode :: Enum.KeyCode }
		end
		return nil
	end

	if typeof(rawTable.UserInputType) == "string" then
		local ok, inputType = pcall(function()
			return (Enum.UserInputType :: any)[rawTable.UserInputType]
		end)
		if ok and typeof(inputType) == "EnumItem" then
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

local function decodeKeybindOverrides(raw: unknown): { [Types.KeybindAction]: Types.Keybind }
	local overrides: { [Types.KeybindAction]: Types.Keybind } = {}
	if typeof(raw) ~= "table" then
		return overrides
	end
	for action, rawKeybind in raw :: { [string]: any } do
		if typeof(action) == "string" and isRebindableKeybindAction(action) then
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
function PlayerDataSystem.CreateDefaultParkourSettings(): Types.ParkourSettings
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
	local defaults = PlayerDataSystem.CreateDefaultParkourSettings()
	if typeof(raw) ~= "table" then
		return defaults
	end
	local rawTable = raw :: { [string]: any }
	local function boolean(key: string, fallback: boolean): boolean
		local value = rawTable[key]
		return if typeof(value) == "boolean" then value else fallback
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

-- Exported for the same reason every other pure encode/decode function in this file is (TestEZ
-- coverage with no live Player/DataStore) -- see file header.
function PlayerDataSystem.EncodeSettings(settings: Types.PlayerSettings): { [string]: any }
	local parkour = settings.Parkour
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
	}
end

function PlayerDataSystem.DecodeSettings(raw: unknown): Types.PlayerSettings
	if typeof(raw) ~= "table" then
		return {
			Keybinds = {},
			GamepadKeybinds = {},
			Autorun = false,
			Parkour = PlayerDataSystem.CreateDefaultParkourSettings(),
		}
	end
	local rawTable = raw :: { [string]: any }
	return {
		Keybinds = decodeKeybindOverrides(rawTable.Keybinds),
		GamepadKeybinds = decodeKeybindOverrides(rawTable.GamepadKeybinds),
		Autorun = if typeof(rawTable.Autorun) == "boolean" then rawTable.Autorun else false,
		Parkour = decodeParkourSettings(rawTable.Parkour),
	}
end

-- DataStore/JSON-safe encoding of a live PlayerProfile -- explicit field list (never a raw
-- pass-through of the live table) so an accidental extra field on the in-memory shape can never
-- leak into a persisted record unnoticed, same defensive posture BugReportSystem.encodeRecord/
-- ModerationSystem.encodeBanRecord already take. Every field here is already a DataStore-safe
-- primitive/array/dict -- unlike BugReportRecord's Position, PlayerProfile has no Vector3/CFrame
-- needing its own encode step; settings goes through EncodeSettings above for its own EnumItem ->
-- string conversion.
function PlayerDataSystem.EncodeProfile(profile: Types.PlayerProfile): { [string]: any }
	return {
		userId = profile.userId,
		faction = profile.faction,
		raceId = profile.raceId,
		displayName = profile.displayName,
		attributes = profile.attributes,
		tier = profile.tier,
		bloodlineIds = profile.bloodlineIds,
		artMastery = profile.artMastery,
		equippedArts = profile.equippedArts,
		corruption = profile.corruption,
		qiDeviationRisk = profile.qiDeviationRisk,
		factionStanding = profile.factionStanding,
		hasAscended = profile.hasAscended,
		meridianXp = profile.meridianXp,
		unlockedEmoteIds = profile.unlockedEmoteIds,
		emoteLoadout = profile.emoteLoadout,
		settings = PlayerDataSystem.EncodeSettings(profile.settings),
	}
end

-- Defensive decode -- `raw` is untrusted the instant it comes back from a DataStore (engineering-
-- standards.md's "validate at every external boundary" applies to storage reads, not just client
-- input: a hand-edited record, a future schema drift, or a DataStore-side corruption should never
-- crash or silently produce nonsense). Every field is individually type-checked and falls back to
-- a safe default rather than trusting the shape wholesale; `fallbackUserId` covers the pathological
-- case where the stored userId field itself is missing/wrong -- the DataStore KEY (this player's
-- real UserId) is always the trustworthy source for that one field. Returns nil only when `raw`
-- isn't even a table -- every other malformed field degrades to a default instead of failing the
-- whole decode, since a single bad field (e.g. a hand-edited corruption value) shouldn't cost a
-- player their entire tier/bloodline/art progress.
function PlayerDataSystem.DecodeProfile(fallbackUserId: number, raw: unknown): Types.PlayerProfile?
	if typeof(raw) ~= "table" then
		return nil
	end
	local rawTable = raw :: { [string]: any }

	local bloodlineIds: { Types.BloodlineId } = {}
	if typeof(rawTable.bloodlineIds) == "table" then
		for _, id in ipairs(rawTable.bloodlineIds) do
			if typeof(id) == "string" then
				table.insert(bloodlineIds, id)
			end
		end
	end

	local artMastery: { [Types.ArtId]: number } = {}
	if typeof(rawTable.artMastery) == "table" then
		for artId, rank in pairs(rawTable.artMastery) do
			if typeof(artId) == "string" and typeof(rank) == "number" then
				artMastery[artId] = rank
			end
		end
	end

	-- equippedArts is a dict keyed by SLOT INDEX (Types.PlayerProfile's own header), and this decode
	-- carries the one genuinely non-obvious step in this whole function: a DataStore round trip is a
	-- JSON round trip, and JSON has no integer keys -- `{ [4] = "art" }` comes back as
	-- `{ ["4"] = "art" }`. So both forms are accepted and normalized back to a number here, rather
	-- than trusting typeof(slot) == "number" (which would silently drop every slot on the first
	-- reload and hand the player an empty hotbar with no error anywhere). Out-of-range and
	-- non-integer slots are dropped per-entry, the same way bloodlineIds/artMastery above drop a
	-- single bad entry instead of discarding the whole field.
	local equippedArts: { [number]: Types.ArtId } = {}
	if typeof(rawTable.equippedArts) == "table" then
		for slot, artId in pairs(rawTable.equippedArts :: { [any]: any }) do
			local slotNumber = if typeof(slot) == "number" then slot else tonumber(slot)
			if
				typeof(artId) == "string"
				and slotNumber ~= nil
				and slotNumber == math.floor(slotNumber)
				and slotNumber >= 1
				and slotNumber <= ArtConstants.EquipSlotCount
			then
				equippedArts[slotNumber] = artId
			end
		end
	end

	-- AttributeBlock is a fixed six-field RECORD, not an open dict like bloodlineIds/artMastery above
	-- -- there is no safe "partial" default for a stat block (a record missing e.g. Fleetness isn't a
	-- meaningfully degraded-but-usable profile the way a bloodlineIds entry with one bad id is). Every
	-- field is individually type-checked, but a single missing/wrong-typed field discards the WHOLE
	-- unit back to nil rather than inventing a value for the missing one -- the same reasoning this
	-- file's header already applies to raceId/displayName themselves (a malformed field degrades to a
	-- safe default, it never fabricates plausible-looking data).
	local attributes: Types.AttributeBlock? = nil
	if typeof(rawTable.attributes) == "table" then
		local rawAttributes = rawTable.attributes :: { [string]: any }
		local vitality = rawAttributes.Vitality
		local fortitude = rawAttributes.Fortitude
		local meridianFlow = rawAttributes.MeridianFlow
		local might = rawAttributes.Might
		local pressure = rawAttributes.Pressure
		local fleetness = rawAttributes.Fleetness
		if
			typeof(vitality) == "number"
			and typeof(fortitude) == "number"
			and typeof(meridianFlow) == "number"
			and typeof(might) == "number"
			and typeof(pressure) == "number"
			and typeof(fleetness) == "number"
		then
			attributes = {
				Vitality = vitality,
				Fortitude = fortitude,
				MeridianFlow = meridianFlow,
				Might = might,
				Pressure = pressure,
				Fleetness = fleetness,
			}
		end
	end

	-- unlockedEmoteIds is a SET ({ [EmoteId]: true }, Types.PlayerProfile's own header) -- every key
	-- must be a string and every value must literally be `true` (never just truthy) before it's kept,
	-- the same per-entry defensive filtering bloodlineIds/artMastery above already apply to their own
	-- shapes. A missing/wrong-shaped field falls back to EmoteRegistry.GetDefaultUnlockedIds() rather
	-- than an empty table -- the same "a new/legacy record still gets every Default emote" contract
	-- CreateDefaultProfile and Migrations[1] below both already guarantee; DecodeProfile is a second,
	-- independent line of defense for the same invariant, not a place that should ever hand back a
	-- player with zero emotes over a merely-corrupt field.
	local unlockedEmoteIds: { [Types.EmoteId]: true } = {}
	if typeof(rawTable.unlockedEmoteIds) == "table" then
		for id, value in pairs(rawTable.unlockedEmoteIds :: { [string]: any }) do
			if typeof(id) == "string" and value == true then
				unlockedEmoteIds[id] = true
			end
		end
	end
	if next(unlockedEmoteIds) == nil then
		unlockedEmoteIds = EmoteRegistry.GetDefaultUnlockedIds()
	end

	-- emoteLoadout is an ORDERED array (Types.PlayerProfile's own header) -- filtered the same way
	-- bloodlineIds is above (drop any non-string entry rather than discarding the whole array), and
	-- falls back to the same starter loadout CreateDefaultProfile grants a brand-new profile when
	-- missing/wrong-shaped entirely.
	local emoteLoadout: { Types.EmoteId } = {}
	if typeof(rawTable.emoteLoadout) == "table" then
		for _, id in ipairs(rawTable.emoteLoadout :: { any }) do
			if typeof(id) == "string" then
				table.insert(emoteLoadout, id)
			end
		end
	end
	if #emoteLoadout == 0 then
		emoteLoadout = table.clone(EmoteConstants.DefaultLoadout)
	end

	return {
		userId = if typeof(rawTable.userId) == "number" then rawTable.userId else fallbackUserId,
		faction = if typeof(rawTable.faction) == "string" then rawTable.faction :: Types.Faction else nil,
		raceId = if typeof(rawTable.raceId) == "string" then rawTable.raceId :: Types.RaceId else nil,
		displayName = if typeof(rawTable.displayName) == "string" then rawTable.displayName :: string else nil,
		attributes = attributes,
		tier = if typeof(rawTable.tier) == "number" then rawTable.tier else Config.DefaultTier,
		bloodlineIds = bloodlineIds,
		artMastery = artMastery,
		equippedArts = equippedArts,
		corruption = if typeof(rawTable.corruption) == "number" then rawTable.corruption else 0,
		qiDeviationRisk = if typeof(rawTable.qiDeviationRisk) == "number" then rawTable.qiDeviationRisk else 0,
		factionStanding = if typeof(rawTable.factionStanding) == "number" then rawTable.factionStanding else 0,
		hasAscended = if typeof(rawTable.hasAscended) == "boolean" then rawTable.hasAscended else false,
		meridianXp = if typeof(rawTable.meridianXp) == "number" then rawTable.meridianXp else 0,
		unlockedEmoteIds = unlockedEmoteIds,
		emoteLoadout = emoteLoadout,
		settings = PlayerDataSystem.DecodeSettings(rawTable.settings),
	}
end

-- Schema migration skeleton (this file's header, design decision 4). Keyed by the version a
-- migration function migrates FROM (Migrations[1] turns a v1 record into a v2 record, and so on) --
-- MigrateRecord itself already walks this table forward, so registering Migrations[N] = function(raw)
-- ... end is the ONLY change a real schema bump needs; nothing about the load path itself has to
-- change. A version with no registered migration function stops the walk where it is (rather than
-- guessing) and logs loudly -- an under-migrated record is handed to DecodeProfile as-is, which
-- degrades missing/wrong-shaped fields to safe defaults per DecodeProfile's own contract, instead
-- of this function crashing or fabricating data it has no real migration for.
local Migrations: { [number]: (raw: { [string]: any }) -> { [string]: any } } = {}

-- v1 -> v2: backfills Types.PlayerProfile's unlockedEmoteIds/emoteLoadout (the Emote System's
-- persisted fields) onto any record saved before this pass -- the first real entry this table has
-- ever needed (schema version 1 was the only version that existed until this bump). Mutates and
-- returns `raw` in place -- MigrateRecord's own loop only ever forwards whatever a migration
-- function returns, so there's nothing else this needs to do. Only touches raw.Profile when it's
-- actually a table -- an already-malformed Profile is DecodeProfile's problem to degrade safely, not
-- this function's to fix up.
Migrations[1] = function(raw: { [string]: any }): { [string]: any }
	local profile = raw.Profile
	if typeof(profile) == "table" then
		local profileTable = profile :: { [string]: any }
		if profileTable.unlockedEmoteIds == nil then
			profileTable.unlockedEmoteIds = EmoteRegistry.GetDefaultUnlockedIds()
		end
		if profileTable.emoteLoadout == nil then
			profileTable.emoteLoadout = table.clone(EmoteConstants.DefaultLoadout)
		end
	end
	return raw
end

-- v2 -> v3: backfills Types.PlayerProfile's `settings` field (the Settings System's persisted
-- keybind overrides + Autorun) onto any record saved before this pass -- same "only touch an
-- already-table Profile, only fill in a genuinely missing field" shape as Migrations[1] above.
-- DecodeSettings' own defensive decode handles anything short of a fully-missing field regardless
-- (a partially-populated settings table from a future rollback, say), so this only needs to cover
-- the "field doesn't exist at all yet" case.
Migrations[2] = function(raw: { [string]: any }): { [string]: any }
	local profile = raw.Profile
	if typeof(profile) == "table" then
		local profileTable = profile :: { [string]: any }
		if profileTable.settings == nil then
			profileTable.settings = { Keybinds = {}, GamepadKeybinds = {}, Autorun = false }
		end
	end
	return raw
end

-- v3 -> v4: backfills Types.PlayerProfile's `equippedArts` (which art sits in each hotbar slot) onto
-- any record saved before this pass -- same "only touch an already-table Profile, only fill in a
-- genuinely missing field" shape as Migrations[1]/[2] above. An empty table is the honest backfill
-- rather than an auto-equip of whatever the player already has unlocked: which art goes in which
-- slot is a player decision this System has no basis to make for them.
Migrations[3] = function(raw: { [string]: any }): { [string]: any }
	local profile = raw.Profile
	if typeof(profile) == "table" then
		local profileTable = profile :: { [string]: any }
		if profileTable.equippedArts == nil then
			profileTable.equippedArts = {}
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
Migrations[4] = function(raw: { [string]: any }): { [string]: any }
	local profile = raw.Profile
	if typeof(profile) == "table" then
		local profileTable = profile :: { [string]: any }
		local settings = profileTable.settings
		if typeof(settings) == "table" and (settings :: { [string]: any }).Parkour == nil then
			(settings :: { [string]: any }).Parkour = PlayerDataSystem.CreateDefaultParkourSettings()
		end
	end
	return raw
end

function PlayerDataSystem.MigrateRecord(raw: { [string]: any }): { [string]: any }
	local version = if typeof(raw.SchemaVersion) == "number" then raw.SchemaVersion :: number else 1
	local migrated = raw

	while version < Config.SchemaVersion do
		local migrate = Migrations[version]
		if not migrate then
			logger:warn("MigrateRecord: no migration registered, stopping short of current version", {
				fromVersion = version,
				currentVersion = Config.SchemaVersion,
			})
			break
		end
		migrated = migrate(migrated)
		version += 1
	end

	-- Stamped unconditionally, not just inside the loop above -- a record that arrives already at
	-- (or above) Config.SchemaVersion never enters the loop body at all, and its own on-disk
	-- SchemaVersion field could still be missing/stale (e.g. a record saved before this field
	-- existed) even though `version` itself was computed correctly. Every caller downstream should
	-- be able to trust `migrated.SchemaVersion` reflects the version actually reached here, whether
	-- that took zero, one, or several migration steps.
	migrated.SchemaVersion = version
	return migrated
end

-- The pure core of Transform below -- applies `mutator` to `stored.Profile` in place, inside a
-- pcall (a throwing mutator must never corrupt the stored profile or crash the caller -- one
-- buggy future System's Transform callback shouldn't be able to bring down PlayerDataSystem for
-- every player). Exported so TestEZ can exercise mutation/error-handling against a plain
-- StoredPlayerProfile literal, without a live Player or a loaded-profile table -- the same
-- "extract the Player-keyed wrapper's pure core" pattern AdminActionSystem.CreateOverrideState/
-- ApplyGodmode already established for its own per-player state.
function PlayerDataSystem.ApplyMutation(
	stored: Types.StoredPlayerProfile,
	mutator: (profile: Types.PlayerProfile) -> ()
): boolean
	local ok, err = pcall(mutator, stored.Profile)
	if not ok then
		logger:error("Transform mutator errored -- profile left at its last known-good state", {
			errorMessage = tostring(err),
		})
		return false
	end
	return true
end

--
-- Cross-server session lock + WriteGeneration -- the pure decision logic behind loadProfile's claim
-- step and saveProfile's UpdateAsync merge (see Types.PlayerDataLock/StoredPlayerProfile's own
-- headers for the race this closes). Exported for the same "pure logic gets its own export, TestEZ
-- coverage with no live DataStore" reason as every other function in this section -- these three are
-- exactly what a real UpdateAsync callback needs, written so the callback itself is a one-line call
-- into one of them.
--

-- True when `rawLock` is a live lock held by a DIFFERENT server than `thisJobId` -- false for no
-- lock, a lock already held by us (re-claiming our own lock, e.g. a retry, is always fine), or a
-- foreign lock old enough (>= staleAfterSeconds since LockedAt) to treat as abandoned. A malformed
-- lock shape (missing/wrong-typed JobId or LockedAt -- shouldn't happen since nothing but
-- ComputeLoadClaim below ever writes this field, but DataStore content is never fully trusted) is
-- treated as absent rather than as a lock that can never expire.
function PlayerDataSystem.IsLockHeldByOther(
	rawLock: unknown,
	thisJobId: string,
	now: number,
	staleAfterSeconds: number
): boolean
	if typeof(rawLock) ~= "table" then
		return false
	end
	local lock = rawLock :: { [string]: any }
	if typeof(lock.JobId) ~= "string" or lock.JobId == thisJobId then
		return false
	end
	if typeof(lock.LockedAt) ~= "number" then
		return false
	end
	return now - lock.LockedAt < staleAfterSeconds
end

-- The UpdateAsync merge function loadProfile's claim step passes straight into DataStore:UpdateAsync
-- -- given whatever is currently stored (`old`, exactly what UpdateAsync hands its callback: nil for
-- a never-written key, or the last-written value), either claims the lock for `thisJobId` or refuses
-- and returns `old` completely untouched. Three cases:
--   1. `old == nil` (genuinely new player): returns a lock-only stub ({ Lock = ... }, no Profile/
--      SchemaVersion) -- the caller distinguishes THIS from an existing record by Profile/
--      SchemaVersion both being absent post-claim, then calls CreateDefaultProfile itself (this
--      function never fabricates a default profile -- that stays PlayerDataSystem.CreateDefaultProfile's
--      sole job, per this file's header design decision 5).
--   2. `old` is a table (an existing record) and its lock (if any) is NOT held by another live server:
--      claims it (or re-claims/refreshes our own) in place, Profile/SchemaVersion/WriteGeneration
--      untouched, and returns the same table.
--   3. `old` is a table and IS held by another live server: refuses, returns `old` completely
--      unchanged -- the caller's own retry-with-backoff loop (loadProfile) is what decides what
--      happens next, not this function.
-- A non-nil, non-table `old` (external corruption/tamper -- never produced by this module's own
-- write path) is returned completely untouched rather than coerced into a fresh table, so whatever
-- diagnostic value the corrupt payload has survives for DecodeProfile's own downstream corrupt-data
-- handling instead of being silently erased here.
function PlayerDataSystem.ComputeLoadClaim(
	old: unknown,
	thisJobId: string,
	now: number,
	staleAfterSeconds: number
): unknown
	if old == nil then
		return { Lock = { JobId = thisJobId, LockedAt = now } }
	end
	if typeof(old) ~= "table" then
		return old
	end
	local record = old :: { [string]: any }
	if PlayerDataSystem.IsLockHeldByOther(record.Lock, thisJobId, now, staleAfterSeconds) then
		return record
	end
	record.Lock = { JobId = thisJobId, LockedAt = now }
	return record
end

-- The UpdateAsync merge function for the narrow "won the claim, then discovered the player already
-- left before their load finished" case in loadProfile below -- clears Lock ONLY if it's still ours,
-- touching nothing else (unlike ComputeSaveWrite, this never writes Profile/SchemaVersion/
-- WriteGeneration, since that path never actually starts a real session for this player). Leaving
-- the lock unreleased here would still self-heal after Constants.PlayerData.LockStaleAfterSeconds
-- (the same staleness handling every abandoned lock gets), so this is a best-effort UX improvement
-- for a quick rejoin, not a correctness requirement.
function PlayerDataSystem.ComputeLockRelease(old: unknown, thisJobId: string): unknown
	if typeof(old) ~= "table" then
		return old
	end
	local record = old :: { [string]: any }
	local lock = record.Lock
	if typeof(lock) == "table" and (lock :: { [string]: any }).JobId == thisJobId then
		record.Lock = nil
	end
	return record
end

-- The UpdateAsync merge function saveProfile passes into DataStore:UpdateAsync -- given whatever is
-- currently stored (`old`) and the WriteGeneration THIS server loaded (`loadedGeneration`), either
-- commits the write (bumping the generation and writing `encodedProfile`/`schemaVersion`) or refuses
-- it. Refuses when the CURRENTLY stored generation is already ahead of what this server loaded --
-- meaning some other server has saved this profile since we last touched it (the WriteGeneration
-- backstop Types.StoredPlayerProfile's own header describes; the Lock above should make this rare in
-- practice, not impossible). `releaseLock` clears the Lock field entirely (the final save on a clean
-- leave/shutdown -- see loadProfile's own header for why no OTHER server was ever blocked by it in
-- the meantime) or refreshes it under `thisJobId`/`now` (every other save -- keeps this server's own
-- ownership current for as long as it's still the one calling this).
function PlayerDataSystem.ComputeSaveWrite(
	old: unknown,
	loadedGeneration: number,
	thisJobId: string,
	now: number,
	encodedProfile: { [string]: any },
	schemaVersion: number,
	releaseLock: boolean
): ({ [string]: any }, string)
	local record: { [string]: any } = if typeof(old) == "table" then old :: { [string]: any } else {}
	local currentGeneration = if typeof(record.WriteGeneration) == "number" then record.WriteGeneration else 0
	if currentGeneration > loadedGeneration then
		return record, "Rejected"
	end
	record.SchemaVersion = schemaVersion
	record.Profile = encodedProfile
	record.WriteGeneration = loadedGeneration + 1
	record.Lock = if releaseLock then nil else { JobId = thisJobId, LockedAt = now }
	return record, "Saved"
end

--
-- Per-player wiring -- Player-keyed, so (per AdminActionSystem.spec.lua/ModerationSystem.spec.lua's
-- own already-accepted precedent) this section is Studio/live-server verification only; the pure
-- logic it's built on is fully covered above.
--

-- True once `player`'s profile has finished loading successfully. Every future System's own
-- request handler is expected to gate gameplay actions on this (or block on WaitForProfile) before
-- touching a player's profile -- see this file's header, design decision 1.
function PlayerDataSystem.IsLoaded(player: Player): boolean
	return loadedProfiles[player] ~= nil
end

-- Read-only snapshot of `player`'s current profile, or nil if it hasn't loaded (yet, or ever --
-- see IsLoaded). Always a deep copy (CopyProfile) -- see this file's header, design decision 3, for
-- why nothing outside this module ever holds a reference to the live profile table.
function PlayerDataSystem.GetProfile(player: Player): Types.PlayerProfile?
	local stored = loadedProfiles[player]
	if not stored then
		return nil
	end
	return PlayerDataSystem.CopyProfile(stored.Profile)
end

-- Blocks the calling thread (event-driven, not a poll -- see below) until `player`'s profile has
-- loaded, a load failure is observed for them, or `timeoutSeconds` elapses (defaults to
-- Config.WaitForProfileDefaultTimeoutSeconds). Returns the same deep-copy snapshot GetProfile
-- would, or nil on failure/timeout/the player having already left. For a System whose own request
-- handler fires in the narrow window right after PlayerAdded but before this module's own load has
-- resolved -- gating on IsLoaded alone would just reject that request; WaitForProfile lets a caller
-- that's willing to block briefly succeed instead.
function PlayerDataSystem.WaitForProfile(player: Player, timeoutSeconds: number?): Types.PlayerProfile?
	local existing = loadedProfiles[player]
	if existing then
		return PlayerDataSystem.CopyProfile(existing.Profile)
	end
	if failedLoads[player] then
		return nil
	end

	local timeout = timeoutSeconds or Config.WaitForProfileDefaultTimeoutSeconds
	local wakeSignal = Instance.new("BindableEvent")
	local finished = false
	local timedOut = false

	local loadedConnection: RBXScriptConnection
	loadedConnection = PlayerDataSystem.OnProfileLoaded.Event:Connect(function(loadedPlayer: Player)
		if loadedPlayer == player and not finished then
			wakeSignal:Fire()
		end
	end)
	local failedConnection: RBXScriptConnection
	failedConnection = PlayerDataSystem.OnProfileLoadFailed.Event:Connect(function(failedPlayer: Player)
		if failedPlayer == player and not finished then
			wakeSignal:Fire()
		end
	end)

	-- Guarded by `finished` (set synchronously the instant Wait() below returns, before this
	-- function yields again) rather than left unconditional -- without the guard, an early wake via
	-- loadedConnection/failedConnection would still leave this scheduled callback pending, firing
	-- Fire() on an already-:Destroy()'d wakeSignal once `timeout` seconds later for no reason.
	task.delay(timeout, function()
		if not finished then
			timedOut = true
			wakeSignal:Fire()
		end
	end)

	wakeSignal.Event:Wait()
	finished = true
	loadedConnection:Disconnect()
	failedConnection:Disconnect()
	wakeSignal:Destroy()

	local resolved = loadedProfiles[player]
	if resolved then
		return PlayerDataSystem.CopyProfile(resolved.Profile)
	end
	if timedOut then
		logger:warn("WaitForProfile timed out", { player = player.Name, timeoutSeconds = timeout })
	end
	return nil
end

-- THE single mutation entry point every System uses to change a player's profile -- see this
-- file's header, design decision 3. `mutator` receives the LIVE profile table and mutates it in
-- place; it must never yield (no task.wait, no DataStore/HTTP call, no WaitForChild) -- Transform's
-- "no two mutations interleave" guarantee depends entirely on the whole call running to completion
-- within one uninterrupted resumption of the calling thread, the same assumption every other
-- synchronous per-player state mutation in this codebase already relies on (e.g. CombatSystem's
-- own CombatState field writes). Returns false (and applies nothing) if the profile isn't loaded
-- yet, or if `mutator` itself throws -- callers MUST check the return value and treat false as
-- "this write did not happen," the same server-authoritative validation discipline every gameplay
-- request handler already applies to its own preconditions.
function PlayerDataSystem.Transform(player: Player, mutator: (profile: Types.PlayerProfile) -> ()): boolean
	local stored = loadedProfiles[player]
	if not stored then
		logger:warn("Transform called before profile loaded (or after it failed to load)", { player = player.Name })
		return false
	end

	local applied = PlayerDataSystem.ApplyMutation(stored, mutator)
	if applied then
		dirtyPlayers[player] = true
	end
	return applied
end

-- Writes `stored` for `player` if a DataStore handle exists, clearing its dirty flag and bumping
-- stored.WriteGeneration on success. Called from four places (PlayerRemoving, the autosave loop,
-- BindToClose, ResetProfile below) -- see this file's header, design decision 2. Deliberately
-- unconditional on dirtiness (never checks dirtyPlayers itself) -- the CALLER decides whether
-- dirtiness gates this save (the autosave loop does; PlayerRemoving/BindToClose don't, since a
-- clean-leave/shutdown save is the last real chance to persist and should never be skipped just
-- because some bookkeeping flag says "nothing changed" when that flag's only cost of being wrong is
-- one extra small write, versus the alternative of silently dropping a real change).
--
-- UpdateAsync, not SetAsync -- see PlayerDataSystem.ComputeSaveWrite's own header for the merge
-- logic this delegates to. `releaseLock` is true for the FINAL save on a clean leave/shutdown
-- (PlayerRemoving, BindToClose) so the next server to load this profile (a hop) never has to wait
-- out Constants.PlayerData.LockStaleAfterSeconds for a lock this server no longer needs; false for
-- every other save (the autosave loop, ResetProfile's immediate save), which refreshes the lock
-- under this server's own JobId instead of clearing it -- this server is still the one playing.
--
-- Returns "Rejected" (distinct from "Failed") when ComputeSaveWrite's WriteGeneration backstop
-- refuses the write -- see that function's own header for when this can happen. Callers that can
-- meaningfully react (runAutosaveLoop kicks the player; see that loop's own comment for why) check
-- for it specifically rather than treating every non-"Saved" outcome identically.
type SaveOutcome = "Saved" | "Failed" | "Rejected"
local function saveProfile(player: Player, stored: Types.StoredPlayerProfile, releaseLock: boolean): SaveOutcome
	if not dataStore then
		return "Failed"
	end

	-- Wait out any save already in flight for THIS player rather than racing it -- see saveInFlight's
	-- own header. Never bounded by a timeout: the in-flight save this is waiting on is itself already
	-- bounded by withRetry's own retry ceiling, so it always eventually clears this. `stored` is the
	-- SAME live table every caller shares (loadedProfiles' own value for this player), so once the
	-- in-flight save commits and bumps stored.WriteGeneration below, THIS call reads that fresh
	-- generation the instant it acquires the slot -- which is what actually closes the race, not the
	-- waiting by itself.
	while saveInFlight[player] do
		task.wait()
	end
	saveInFlight[player] = true

	-- The whole body runs inside one pcall so saveInFlight[player] is guaranteed to clear on the way
	-- out even on a genuinely unexpected throw (a bad encode, a bug) -- Luau has no finally, and a
	-- lock that never releases would silently wedge every future save for this player for the rest of
	-- the server's life, which is a strictly worse failure than the one this mutex exists to prevent.
	local completed, result = pcall(function(): SaveOutcome
		local key = tostring(player.UserId)
		local encodedProfile = PlayerDataSystem.EncodeProfile(stored.Profile)
		local schemaVersion = stored.SchemaVersion
		local loadedGeneration = stored.WriteGeneration
		local thisJobId = game.JobId
		local now = os.time()

		local rejected = false
		local ok = withRetry("PlayerData save UpdateAsync", function()
			(dataStore :: DataStore):UpdateAsync(key, function(old: unknown)
				local record, outcome = PlayerDataSystem.ComputeSaveWrite(
					old,
					loadedGeneration,
					thisJobId,
					now,
					encodedProfile,
					schemaVersion,
					releaseLock
				)
				rejected = outcome == "Rejected"
				return record
			end)
		end)

		if not ok then
			logger:error("saveProfile: UpdateAsync failed after retries -- data NOT persisted this pass", {
				userId = player.UserId,
			})
			return "Failed"
		end

		if rejected then
			logger:error(
				"saveProfile: rejected -- a newer WriteGeneration already exists for this player (another server saved since this one last loaded/saved); this server's copy was NOT written to avoid overwriting the newer data",
				{ userId = player.UserId, loadedGeneration = loadedGeneration }
			)
			return "Rejected"
		end

		stored.WriteGeneration = loadedGeneration + 1
		dirtyPlayers[player] = nil
		return "Saved"
	end)

	saveInFlight[player] = nil

	if not completed then
		logger:error("saveProfile: threw unexpectedly -- data NOT persisted this pass", {
			userId = player.UserId,
			errorMessage = tostring(result),
		})
		return "Failed"
	end
	return result :: SaveOutcome
end

-- Wipes `player`'s ALREADY-LOADED profile back to a fresh CreateDefaultProfile and saves it
-- immediately, rather than only marking it dirty for the next autosave pass -- see this file's
-- header, design decision 2: this is a deliberate one-off admin action (DevMenuSystem.
-- handleResetTargetPlayerData), not a routine mutation, so it earns the same immediacy guarantee
-- the PlayerRemoving/BindToClose save paths already give a clean leave/shutdown. Unlike Transform,
-- this REPLACES the whole stored.Profile table rather than mutating fields via a callback -- a
-- reset has no meaningful "which fields to touch," so there's no mutator to write. Same
-- load-must-already-exist precondition Transform enforces (returns false, touches nothing, if
-- `player` isn't in loadedProfiles) -- this must never fabricate a profile for someone who was
-- never loaded, for the same reason CreateDefaultProfile's own header restricts legitimate
-- construction to the "confirmed no prior save" GetAsync-returned-nil path in loadProfile.
--
-- Returns true once the in-memory reset is applied, REGARDLESS of whether the immediate save below
-- actually succeeded -- same contract Transform's own return value has (did the mutation happen,
-- not did it reach disk yet). A failed immediate save leaves dirtyPlayers[player] set exactly like
-- any other saveProfile failure, so the normal autosave loop/PlayerRemoving/BindToClose safety nets
-- still guarantee it reaches disk eventually; this function's own immediate save is a durability
-- IMPROVEMENT over waiting for those, not the only mechanism guaranteeing persistence.
function PlayerDataSystem.ResetProfile(player: Player): boolean
	local stored = loadedProfiles[player]
	if not stored then
		logger:warn("ResetProfile called before profile loaded (or after it failed to load)", { player = player.Name })
		return false
	end

	stored.Profile = PlayerDataSystem.CreateDefaultProfile(player.UserId)
	dirtyPlayers[player] = true

	-- Not the final save (releaseLock = false) -- the player is still connected and playing after an
	-- admin reset, exactly like an autosave mid-session.
	local outcome = saveProfile(player, stored, false)
	local saved = outcome == "Saved"
	if not saved then
		logger:error(
			"ResetProfile: immediate save did not persist -- reset applied in memory; the autosave loop/next leave will retry"
				.. (
					if outcome == "Rejected"
						then " (though a WriteGeneration conflict will keep failing until this server's copy is refreshed)"
						else ""
				),
			{ userId = player.UserId, outcome = outcome }
		)
	end

	logger:warn("ResetProfile accepted -- profile wiped to defaults", { userId = player.UserId, saved = saved })
	return true
end

-- Loads (or creates) `player`'s profile -- see this file's header, design decisions 1 and 5, and
-- Types.PlayerDataLock's own header for the cross-server race this claim step closes. Never yields
-- the caller past this function's own return (Init()'s PlayerAdded connection calls this via
-- task.spawn, not inline -- see Init() below), so a slow DataStore round trip for one player can
-- never delay another player's own join handling.
--
-- Note for Studio testing: game.JobId is an empty string outside a published, actually-running
-- server (Team Create, a local test-place run), so IsLockHeldByOther can never see a MISMATCHED
-- JobId there -- every Studio "server" claims under the same empty-string identity, so the lock
-- itself is inert (always claimable) in that environment. This does not affect production -- every
-- real Roblox server has a genuinely unique JobId -- but a Studio multi-server hop test will not
-- exercise the actual blocking/retry path, only the WriteGeneration backstop.
local function loadProfile(player: Player): ()
	local userId = player.UserId
	local key = tostring(userId)
	local thisJobId = game.JobId

	if not dataStore then
		logger:error("loadProfile: DataStore unavailable -- kicking rather than fabricate a profile", {
			userId = userId,
		})
		failedLoads[player] = true
		PlayerDataSystem.OnProfileLoadFailed:Fire(player)
		player:Kick(Config.LoadFailureKickMessage)
		return
	end

	-- Claim step: up to LockClaimMaxAttempts UpdateAsync attempts, each retried internally by
	-- withRetry for genuine DataStore-call failures, backed off by LockClaimRetryBackoffSeconds
	-- between attempts that succeed as a DataStore call but find a live foreign lock (the ordinary
	-- "hop lands before the leaving server's own PlayerRemoving save completes" race -- see
	-- Constants.PlayerData.LockClaimMaxAttempts' own header).
	local claimedRecord: { [string]: any }? = nil
	for attempt = 1, Config.LockClaimMaxAttempts do
		local now = os.time()
		local ok, raw, failReason = withRetry("PlayerData load-claim UpdateAsync", function()
			return (dataStore :: DataStore):UpdateAsync(key, function(old: unknown)
				return PlayerDataSystem.ComputeLoadClaim(old, thisJobId, now, Config.LockStaleAfterSeconds)
			end)
		end)

		if not ok then
			logger:error(
				"loadProfile: load-claim UpdateAsync failed after retries -- kicking to protect any real save data",
				{
					userId = userId,
					reason = failReason,
				}
			)
			failedLoads[player] = true
			PlayerDataSystem.OnProfileLoadFailed:Fire(player)
			player:Kick(Config.LoadFailureKickMessage)
			return
		end

		local record = raw :: { [string]: any }
		local lock = record.Lock
		local wonClaim = typeof(lock) == "table" and (lock :: { [string]: any }).JobId == thisJobId
		if wonClaim then
			claimedRecord = record
			break
		end

		logger:warn("loadProfile: data lock held by another server", {
			userId = userId,
			attempt = attempt,
			heldByJobId = if typeof(lock) == "table" then (lock :: { [string]: any }).JobId else nil,
		})
		if attempt < Config.LockClaimMaxAttempts then
			task.wait(Config.LockClaimRetryBackoffSeconds)
		end
	end

	if not claimedRecord then
		logger:error(
			"loadProfile: could not claim the data lock after retries -- kicking so the player can rejoin once it clears",
			{
				userId = userId,
			}
		)
		failedLoads[player] = true
		PlayerDataSystem.OnProfileLoadFailed:Fire(player)
		player:Kick(Config.LockHeldKickMessage)
		return
	end

	-- A freshly-claimed brand-new record has neither field (ComputeLoadClaim's own header) -- an
	-- existing record always has both, since saveProfile's own ComputeSaveWrite always writes them
	-- together.
	local isNewProfile = claimedRecord.SchemaVersion == nil and claimedRecord.Profile == nil

	local profile: Types.PlayerProfile
	if isNewProfile then
		profile = PlayerDataSystem.CreateDefaultProfile(userId)
	else
		local migrated = PlayerDataSystem.MigrateRecord(claimedRecord)
		local decoded = PlayerDataSystem.DecodeProfile(userId, migrated.Profile)
		if not decoded then
			logger:error(
				"loadProfile: stored record failed to decode -- kicking rather than risk overwriting real save data",
				{ userId = userId }
			)
			failedLoads[player] = true
			PlayerDataSystem.OnProfileLoadFailed:Fire(player)
			player:Kick(Config.CorruptDataKickMessage)
			return
		end
		profile = decoded
	end

	local writeGeneration = if typeof(claimedRecord.WriteGeneration) == "number"
		then claimedRecord.WriteGeneration
		else 0

	if not player.Parent then
		-- Left while their own load was still in flight -- PlayerRemoving already ran and found
		-- nothing to clean up, so don't register state for someone who's already gone (that would
		-- leak a loadedProfiles entry no PlayerRemoving will ever fire again to clear). This leaves
		-- loadedProfiles[player] unset, so PlayerRemoving's own saveProfile(..., releaseLock = true)
		-- never runs for them either -- but the lock we just claimed above is still live in the
		-- DataStore, so best-effort release it directly here (one attempt, not the claim retry loop --
		-- nothing is contending for it) rather than leaving it to self-heal after
		-- LockStaleAfterSeconds. Not correctness-critical either way (ComputeLockRelease's own
		-- header), just a UX improvement for a quick rejoin right after this exact race.
		withRetry("PlayerData load-claim release UpdateAsync (player left mid-load)", function()
			return (dataStore :: DataStore):UpdateAsync(key, function(old: unknown)
				return PlayerDataSystem.ComputeLockRelease(old, thisJobId)
			end)
		end)
		return
	end

	loadedProfiles[player] = {
		SchemaVersion = Config.SchemaVersion,
		Profile = profile,
		WriteGeneration = writeGeneration,
		Lock = { JobId = thisJobId, LockedAt = os.time() },
	}
	logger:info("Profile loaded", { userId = userId, isNew = isNewProfile })
	PlayerDataSystem.OnProfileLoaded:Fire(player)
end

local function onPlayerAdded(player: Player): ()
	task.spawn(loadProfile, player)
end

local function onPlayerRemoving(player: Player): ()
	local stored = loadedProfiles[player]
	if stored then
		-- Final save on a clean leave -- releases the lock (see saveProfile's own header) so a
		-- server hop's destination server never has to wait out LockStaleAfterSeconds for a lock
		-- this server no longer needs. The outcome is worth inspecting even though there is nothing
		-- left to retry from here (this player's own loadedProfiles entry is about to be dropped
		-- either way) -- a "Rejected" final save specifically means a DIFFERENT server has already
		-- saved newer data for this player, which is exactly the situation an operator investigating
		-- a data report needs surfaced in the logs rather than silently swallowed.
		local outcome = saveProfile(player, stored, true)
		if outcome ~= "Saved" then
			logger:error("onPlayerRemoving: final save did not persist", { userId = player.UserId, outcome = outcome })
		end
	end
	loadedProfiles[player] = nil
	dirtyPlayers[player] = nil
	failedLoads[player] = nil
end

-- Backgrounded periodic autosave -- see this file's header, design decision 2/6. Runs for the life
-- of the server; there is no unsubscribe path, matching every other permanent background loop in
-- this codebase (e.g. BugReportSystem's task.spawn(seedOpenReportCount) has no cancellation either,
-- though that one is one-shot -- this is the closer analogue to a permanent Heartbeat-driven loop,
-- just on a much coarser interval since it is DataStore-bound, not per-frame).
local function runAutosaveLoop(): ()
	while true do
		task.wait(Config.AutosaveIntervalSeconds)

		-- Snapshot the key set before iterating: saveProfile below yields (a SetAsync round trip
		-- plus up to DataStoreRetry's full backoff), and the task.wait() a few lines down yields
		-- again between saves, so this traversal stays open across real wall-clock seconds while
		-- loadProfile/onPlayerRemoving insert into and delete from loadedProfiles from other
		-- threads. Walking pairs(loadedProfiles) directly while it's being mutated risks "invalid
		-- key to 'next'" if a delete-then-insert lands on the just-visited key (a rehash can drop
		-- it), or a dirty profile being silently skipped by the same rehash. A plain array of
		-- Players is stable across all of that -- nothing under it can resize mid-walk.
		local players: { Player } = {}
		for player in loadedProfiles do
			table.insert(players, player)
		end

		for _, player in players do
			-- Re-check after the snapshot: the player may have left (onPlayerRemoving already saved
			-- and cleared their entry) or their dirty flag may have changed since it was taken.
			local stored = loadedProfiles[player]
			if stored and dirtyPlayers[player] then
				-- Whole-iteration pcall: saveProfile's own DataStore call is already retry+pcall-
				-- guarded via withRetry, so this is a last-resort net for a genuinely unexpected
				-- throw (a bad encode, a bug), not the expected path -- but without it, one such
				-- throw would propagate out of this bare task.spawn(runAutosaveLoop) and permanently
				-- end autosaving for the rest of the server's life with no restart and no log beyond
				-- Roblox's own uncaught-error line. Not the final save (releaseLock = false) -- this
				-- player is still connected and playing.
				local ok, outcome = pcall(saveProfile, player, stored, false)
				if not ok then
					logger:error("runAutosaveLoop: saveProfile threw -- skipping this player this cycle", {
						userId = player.UserId,
						error = tostring(outcome),
					})
				elseif outcome == "Rejected" then
					-- The WriteGeneration backstop tripped (Types.StoredPlayerProfile's own header) --
					-- this server's copy of this player's data can no longer be trusted to save
					-- safely (another server has written a newer generation), so further play would
					-- just accumulate on data that will never reach disk. Kick now rather than let
					-- that silently continue; saveProfile already logged the specifics.
					logger:error("runAutosaveLoop: kicking -- this server's copy of this player's data is stale", {
						userId = player.UserId,
					})
					player:Kick(Config.StaleSessionKickMessage)
				end
				-- Yield a beat between individual saves so a large dirty batch spreads its writes
				-- across the autosave window instead of bursting every SetAsync back-to-back in the
				-- same frame -- performance-optimization.md's DataStore/network budget discipline.
				task.wait()
			end
		end
	end
end

function PlayerDataSystem.Init(): ()
	dataStore = DataStoreService:GetDataStore(StorageConfig.PlayerDataStoreName)

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	-- Defensive: anyone already connected when this System boots (Studio Team Create, or a slow
	-- server start) still needs a load -- same pattern CombatSystem.lua/AdminActionSystem.lua
	-- already use for their own PlayerAdded wiring.
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end

	task.spawn(runAutosaveLoop)

	-- Server-initiated shutdown safety net -- see this file's header, design decision 2. Saves
	-- every still-loaded profile in parallel (one task.spawn per player, not sequential -- a
	-- shutdown with many connected players shouldn't serialize N DataStore round trips end to end
	-- when Roblox's own BindToClose budget is finite), bounded by ShutdownSaveTimeoutSeconds so a
	-- single stuck retry loop can't hang the whole shutdown indefinitely.
	game:BindToClose(function()
		-- Snapshot the key set before spawning any saves -- same reasoning as runAutosaveLoop's own
		-- identical snapshot (see that loop's own comment for the full mechanism): saveProfile below
		-- yields for a real DataStore round trip, and PlayerRemoving keeps firing for every other
		-- still-connected player during a server-initiated shutdown, each one calling
		-- onPlayerRemoving -> saveProfile -> loadedProfiles[player] = nil concurrently with this walk.
		-- Only removal happens against loadedProfiles during a shutdown (nothing re-adds a player
		-- once the server is closing), which is well-defined against a live `pairs` traversal in
		-- Luau -- but task.spawn below itself runs synchronously up to saveProfile's own first yield
		-- before control returns to this loop, so this traversal genuinely spans real wall-clock time
		-- across those PlayerRemoving-driven removals, and a plain array of Players is stable across
		-- all of that the same way runAutosaveLoop's own copy is.
		local players: { Player } = {}
		for player in loadedProfiles do
			table.insert(players, player)
		end

		local pending = 0
		for _, player in players do
			-- Re-check after the snapshot: PlayerRemoving may have already saved and cleared this
			-- player's entry between the snapshot above and this iteration.
			local stored = loadedProfiles[player]
			if not stored then
				continue
			end
			pending += 1
			task.spawn(function()
				-- Final save -- the server is going away, so release the lock (same as
				-- onPlayerRemoving) rather than leave it for LockStaleAfterSeconds to clear.
				local outcome = saveProfile(player, stored, true)
				if outcome ~= "Saved" then
					logger:error(
						"BindToClose: final save did not persist",
						{ userId = player.UserId, outcome = outcome }
					)
				end
				pending -= 1
			end)
		end

		local deadline = os.clock() + Config.ShutdownSaveTimeoutSeconds
		while pending > 0 and os.clock() < deadline do
			task.wait()
		end
		if pending > 0 then
			logger:error("BindToClose: timed out waiting for in-flight saves", { stillPending = pending })
		end
	end)

	logger:info("PlayerDataSystem.Init() complete")
end

-- Not cast to Types.SystemModule -- same reasoning as BugReportSystem.lua's/ModerationSystem.lua's
-- own return: every future System calls IsLoaded/GetProfile/WaitForProfile/Transform directly, so
-- this module's full type (not just Init) needs to stay visible to those callers.
return PlayerDataSystem
