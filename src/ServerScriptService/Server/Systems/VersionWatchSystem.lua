--!strict
--[[
	VersionWatchSystem.lua

	Owns: detecting "a newer version of this place has been published since this server booted,"
	purely from in-game signals -- no CI/publish-pipeline change, no Open Cloud key required.
	game.PlaceVersion is fixed for a server's entire lifetime (the version it happened to boot on);
	it never updates live when a new version is published. What DOES change is which version
	brand-new servers boot on -- Roblox always spins up a fresh server on the newest published place
	version the moment one is needed. So every server "votes" its own game.PlaceVersion into one
	small shared DataStore key that only ever ratchets upward (UpdateAsync keeps the max), and any
	server -- even one that has been running for days on an old version -- can compare its own boot
	version against that shared key to learn "servers newer than me exist," which is exactly the
	signal an admin deciding whether to restart wants. Refreshed on an interval (Constants.Debug.
	VersionWatch.RefreshIntervalSeconds), not just once at boot, so a long-lived server actually
	learns about a publish that happened after it started, without needing a restart of its own to
	find out.

	Follows ModerationSystem.lua's DataStore precedent: lazy store acquisition in Init() (this
	module stays side-effect-free at require() time beyond capturing game.PlaceVersion itself, which
	is a plain property read, not an API call), and Shared/DataStoreRetry.lua for the retry/backoff
	shape every DataStore call in this codebase uses.

	Does not own: actually restarting anything -- DevMenuSystem.handleInstantRestartServer/
	handleShutdownServer are the only things that ever kick a player, and only in response to an
	admin's own button press. This module is read-only/advisory: it never kicks anyone and never
	announces anything, it purely answers "is a newer version out there" for the Admin tab's passive
	banner (DevMenuSystem.handleGetServerVersionInfo).
]]

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local DataStoreRetry = require(ReplicatedStorage.Shared.DataStoreRetry)
local StorageConfig = require(script.Parent.Parent.Config.StorageConfig)

local logger = Logger.scope("VersionWatchSystem")

local VersionWatchSystem = {}

local Config = Constants.Debug.VersionWatch

local RETRY_CONFIG: DataStoreRetry.RetryConfig = { MaxAttempts = 3, BaseBackoffSeconds = 1 }

-- Single fixed key -- there is exactly one thing this store ever tracks, the same "one small store,
-- one fixed key" shape MoveEditorSystem's own "MoveIndex" key uses (see StorageConfig.lua's own
-- comment on CustomMoveDataStoreName).
local VERSION_KEY = "LatestBootedPlaceVersion"

-- Captured once, at module load -- game.PlaceVersion never changes for the lifetime of a running
-- server (see this module's own header), so there is no reason to re-read it later.
local bootPlaceVersion: number = game.PlaceVersion

-- nil until the first successful DataStore round trip (boot or a later refresh) completes --
-- GetVersionInfo reports "no newer version known" while nil rather than guessing, the same "don't
-- claim a fact you haven't actually observed yet" contract every other lazily-populated cache in
-- this codebase follows.
local latestKnownPlaceVersion: number? = nil

-- Obtained lazily inside Init(), never at module load time -- see this module's own header.
local versionStore: DataStore? = nil

-- Bumps the shared key to max(current stored value, bootPlaceVersion) and caches the resulting
-- value. UpdateAsync's callback computing the max itself (not a read-then-write) is what makes this
-- safe against two servers racing to bump at once -- neither can ever stomp the other down to a
-- lower number.
local function bumpAndRefresh(): ()
	local store = versionStore
	if not store then
		return
	end

	local ok, result = DataStoreRetry.Attempt(logger, "VersionWatch UpdateAsync", RETRY_CONFIG, function()
		return (store :: DataStore):UpdateAsync(VERSION_KEY, function(old: number?): number
			if typeof(old) ~= "number" or bootPlaceVersion > old then
				return bootPlaceVersion
			end
			return old
		end)
	end)

	if ok and typeof(result) == "number" then
		latestKnownPlaceVersion = result
		logger:debug("VersionWatch refreshed", {
			bootPlaceVersion = bootPlaceVersion,
			latestKnownPlaceVersion = result,
		})
	end
end

-- Returns (this server's own boot-time PlaceVersion, the highest PlaceVersion known across all
-- servers so far). The second value is nil until the first DataStore round trip resolves -- callers
-- must treat nil as "unknown," never as "no newer version," the same contract this module's own
-- latestKnownPlaceVersion local documents above.
function VersionWatchSystem.GetVersionInfo(): (number, number?)
	return bootPlaceVersion, latestKnownPlaceVersion
end

function VersionWatchSystem.Init(): ()
	versionStore = DataStoreService:GetDataStore(StorageConfig.ServerVersionDataStoreName)

	task.spawn(function()
		bumpAndRefresh()
		while true do
			task.wait(Config.RefreshIntervalSeconds)
			bumpAndRefresh()
		end
	end)

	logger:info("VersionWatchSystem.Init() complete", { bootPlaceVersion = bootPlaceVersion })
end

return VersionWatchSystem
