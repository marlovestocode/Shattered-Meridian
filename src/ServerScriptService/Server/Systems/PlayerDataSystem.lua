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

	3. CONCURRENCY-SAFE WRITES. Transform(player, mutator) is the ONLY way any System (this one
	   included) mutates a loaded profile. It is not a lock in the traditional sense -- Luau/Roblox
	   scripts are cooperatively single-threaded, so as long as a mutator callback never yields
	   (task.wait, a DataStore/HTTP call, etc.), no two Transform calls for the same player can ever
	   interleave, which is the actual guarantee "one serialized entry point" needs. GetProfile
	   deliberately returns a DEEP COPY (CopyProfile), never the live table, so no caller can bypass
	   Transform by mutating a "read" result -- the same "read-only projection, never the live
	   mutable state" contract CombatSystem.GetCombatState already established for CombatSnapshot.

	4. SCHEMA VERSIONING. Every persisted record is a Types.StoredPlayerProfile
	   ({ SchemaVersion, Profile }), not a bare PlayerProfile. MigrateRecord walks a loaded record
	   forward through the (currently empty) Migrations table toward Constants.PlayerData.
	   SchemaVersion before DecodeProfile ever sees it -- see MigrateRecord's own comment for why an
	   empty table today is a real, tested skeleton and not a TODO.

	5. LOAD-FAILURE HANDLING. A GetAsync failure (exhausted retries) or an undecodable stored
	   record NEVER falls back to a fresh/default profile -- doing so would let a subsequent save
	   silently overwrite a real save that merely failed to load this one time. Both cases kick the
	   player with an explicit, distinct message (LoadFailureKickMessage / CorruptDataKickMessage)
	   instead. A missing record (GetAsync succeeds and returns nil) is the ONLY case that
	   legitimately creates CreateDefaultProfile -- that is a confirmed "this player has never
	   played before," not a failure being papered over.

	6. DATASTORE BUDGET. No per-Heartbeat, per-action, or per-request DataStore call anywhere in
	   this module -- every write is either an explicit Transform-triggered dirty flag drained by
	   the autosave loop (Constants.PlayerData.AutosaveIntervalSeconds), or a one-time
	   PlayerRemoving/BindToClose save. See that Constant's own header for the write-budget math.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")

local Types = require(ReplicatedStorage.Shared.Types)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local DataStoreRetry = require(ReplicatedStorage.Shared.DataStoreRetry)
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
		corruption = 0,
		qiDeviationRisk = 0,
		factionStanding = 0,
		hasAscended = false,
	}
end

-- Deep-enough copy of a PlayerProfile -- every field is either a primitive, a flat array of
-- strings (bloodlineIds), or a flat dict of numbers (artMastery), so a one-level table.clone on
-- each nested container is sufficient; there is no third level of nesting anywhere in this shape.
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
		corruption = profile.corruption,
		qiDeviationRisk = profile.qiDeviationRisk,
		factionStanding = profile.factionStanding,
		hasAscended = profile.hasAscended,
	}
end

-- DataStore/JSON-safe encoding of a live PlayerProfile -- explicit field list (never a raw
-- pass-through of the live table) so an accidental extra field on the in-memory shape can never
-- leak into a persisted record unnoticed, same defensive posture BugReportSystem.encodeRecord/
-- ModerationSystem.encodeBanRecord already take. Every field here is already a DataStore-safe
-- primitive/array/dict -- unlike BugReportRecord's Position, PlayerProfile has no Vector3/CFrame
-- needing its own encode step.
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
		corruption = profile.corruption,
		qiDeviationRisk = profile.qiDeviationRisk,
		factionStanding = profile.factionStanding,
		hasAscended = profile.hasAscended,
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

	return {
		userId = if typeof(rawTable.userId) == "number" then rawTable.userId else fallbackUserId,
		faction = if typeof(rawTable.faction) == "string" then rawTable.faction :: Types.Faction else nil,
		raceId = if typeof(rawTable.raceId) == "string" then rawTable.raceId :: Types.RaceId else nil,
		displayName = if typeof(rawTable.displayName) == "string" then rawTable.displayName :: string else nil,
		attributes = attributes,
		tier = if typeof(rawTable.tier) == "number" then rawTable.tier else Config.DefaultTier,
		bloodlineIds = bloodlineIds,
		artMastery = artMastery,
		corruption = if typeof(rawTable.corruption) == "number" then rawTable.corruption else 0,
		qiDeviationRisk = if typeof(rawTable.qiDeviationRisk) == "number" then rawTable.qiDeviationRisk else 0,
		factionStanding = if typeof(rawTable.factionStanding) == "number" then rawTable.factionStanding else 0,
		hasAscended = if typeof(rawTable.hasAscended) == "boolean" then rawTable.hasAscended else false,
	}
end

-- Schema migration skeleton (this file's header, design decision 4). Keyed by the version a
-- migration function migrates FROM (Migrations[1] turns a v1 record into a v2 record, and so on) --
-- empty today because schema version 1 is the only version that has ever existed, but MigrateRecord
-- itself already walks this table forward, so registering Migrations[2] = function(raw) ... end is
-- the ONLY change a real future schema bump needs; nothing about the load path itself has to
-- change. A version with no registered migration function stops the walk where it is (rather than
-- guessing) and logs loudly -- an under-migrated record is handed to DecodeProfile as-is, which
-- degrades missing/wrong-shaped fields to safe defaults per DecodeProfile's own contract, instead
-- of this function crashing or fabricating data it has no real migration for.
local Migrations: { [number]: (raw: { [string]: any }) -> { [string]: any } } = {}

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

-- Writes `stored` for `player` if a DataStore handle exists, clearing its dirty flag on success.
-- Called from three places (PlayerRemoving, the autosave loop, BindToClose) -- see this file's
-- header, design decision 2. Deliberately unconditional (never checks dirtyPlayers itself) -- the
-- CALLER decides whether dirtiness gates this save (the autosave loop does; PlayerRemoving/
-- BindToClose don't, since a clean-leave/shutdown save is the last real chance to persist and
-- should never be skipped just because some bookkeeping flag says "nothing changed" when that
-- flag's only cost of being wrong is one extra small write, versus the alternative of silently
-- dropping a real change).
local function saveProfile(player: Player, stored: Types.StoredPlayerProfile): boolean
	if not dataStore then
		return false
	end

	local key = tostring(player.UserId)
	local encoded = {
		SchemaVersion = stored.SchemaVersion,
		Profile = PlayerDataSystem.EncodeProfile(stored.Profile),
	}

	local ok = withRetry("PlayerData SetAsync", function()
		(dataStore :: DataStore):SetAsync(key, encoded)
	end)

	if ok then
		dirtyPlayers[player] = nil
	else
		logger:error("saveProfile: SetAsync failed after retries -- data NOT persisted this pass", {
			userId = player.UserId,
		})
	end
	return ok
end

-- Loads (or creates) `player`'s profile -- see this file's header, design decisions 1 and 5.
-- Never yields the caller past this function's own return (Init()'s PlayerAdded connection calls
-- this via task.spawn, not inline -- see Init() below), so a slow DataStore round trip for one
-- player can never delay another player's own join handling.
local function loadProfile(player: Player): ()
	local userId = player.UserId
	local key = tostring(userId)

	if not dataStore then
		logger:error("loadProfile: DataStore unavailable -- kicking rather than fabricate a profile", {
			userId = userId,
		})
		failedLoads[player] = true
		PlayerDataSystem.OnProfileLoadFailed:Fire(player)
		player:Kick(Config.LoadFailureKickMessage)
		return
	end

	local ok, raw, failReason = withRetry("PlayerData GetAsync", function()
		return (dataStore :: DataStore):GetAsync(key)
	end)

	if not ok then
		logger:error("loadProfile: GetAsync failed after retries -- kicking to protect any real save data", {
			userId = userId,
			reason = failReason,
		})
		failedLoads[player] = true
		PlayerDataSystem.OnProfileLoadFailed:Fire(player)
		player:Kick(Config.LoadFailureKickMessage)
		return
	end

	local profile: Types.PlayerProfile
	local isNewProfile = raw == nil
	if isNewProfile then
		profile = PlayerDataSystem.CreateDefaultProfile(userId)
	else
		local migrated = PlayerDataSystem.MigrateRecord(raw :: { [string]: any })
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

	if not player.Parent then
		-- Left while their own load was still in flight -- PlayerRemoving already ran and found
		-- nothing to clean up, so don't register state for someone who's already gone (that would
		-- leak a loadedProfiles entry no PlayerRemoving will ever fire again to clear).
		return
	end

	loadedProfiles[player] = { SchemaVersion = Config.SchemaVersion, Profile = profile }
	logger:info("Profile loaded", { userId = userId, isNew = isNewProfile })
	PlayerDataSystem.OnProfileLoaded:Fire(player)
end

local function onPlayerAdded(player: Player): ()
	task.spawn(loadProfile, player)
end

local function onPlayerRemoving(player: Player): ()
	local stored = loadedProfiles[player]
	if stored then
		saveProfile(player, stored)
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
		for player, stored in pairs(loadedProfiles) do
			if dirtyPlayers[player] then
				saveProfile(player, stored)
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
		local pending = 0
		for player, stored in pairs(loadedProfiles) do
			pending += 1
			task.spawn(function()
				saveProfile(player, stored)
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
