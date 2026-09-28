--!strict
--[[
	PlayerDataConstants.lua

	Owns: PlayerDataSystem's own storage surface -- the on-disk schema version and the migration
	ladder's documented history, the autosave cadence, the cross-server session lock, and the
	WriteGeneration backstop.

	THE SCHEMA-VERSION COMMENTS ARE THE VALUABLE PART, not the integer. Each bump records which
	feature added which profile field and which Migrations entry backfills it; that running history is
	what makes the next bump safe to write, and it is why this moved as one block rather than being
	reduced to a number.

	Does not own: the DataStore NAMES (Server/Config/StorageConfig.lua, never here), the retry policy
	shape every writer shares (Constants.Storage.RetryPolicy, which stays in Constants.lua because
	DataStoreRetry's callers span far more than this system), or the profile TYPE itself
	(Types.PlayerProfile / StoredPlayerProfile).

	Lifted out of Constants.lua. Constants.PlayerData re-exports this module, so every existing
	Constants.PlayerData.X call site keeps working unchanged; new code should require this module
	directly.
]]

-- Canonical player-progression persistence (Server/Systems/PlayerDataSystem.lua) -- the single
-- DataStore-backed owner every other System's player-state reads/writes eventually route through
-- (engineering-standards.md's "one serialized entry point per player's data"). Mirrors
-- Constants.BugReport's own shape/naming below (retry/backoff pair, tuning surface) -- this table
-- existing separately from Constants.BugReport, despite both being DataStore config, is
-- deliberate: BugReportSystem is a fire-and-forget public feature with its own unrelated tuning
-- (cooldowns, page size), where PlayerDataSystem is the load-bearing progression spine every
-- other gameplay System depends on, with its own distinct tuning surface (autosave cadence,
-- schema version, load-failure messaging) that has nothing to do with bug reports.
--
-- Does NOT own the DataStore name itself -- that identifier lives solely in the server-only
-- Server/Config/StorageConfig.lua (StorageConfig.PlayerDataStoreName), never here, so it can
-- never replicate to clients (pure reconnaissance otherwise -- see StorageConfig.lua's own
-- header). This table used to carry its own DataStoreName field alongside StorageConfig's; that
-- was a leftover twin from the move to StorageConfig.lua that nothing ever read, and it was
-- deleted rather than kept "just in case" -- a dead field with a header comment that reads as
-- authoritative is a trap, not a convenience.
local PlayerDataConstants = {
	-- Current on-disk schema version (Types.StoredPlayerProfile.SchemaVersion) -- PlayerDataSystem.
	-- MigrateRecord walks a stored record forward from whatever version it was saved at toward this
	-- number. Bumped 1 -> 2 for the Emote System's unlockedEmoteIds/emoteLoadout fields
	-- (Types.PlayerProfile) -- PlayerDataSystem.lua's Migrations[1] is the first real entry that
	-- table has ever needed, backfilling both fields onto any record saved before this pass. Bumped
	-- 2 -> 3 for the Settings System's `settings` field (Types.PlayerProfile) --
	-- PlayerDataSystem.lua's Migrations[2] backfills it onto any record saved before this pass.
	-- Bumped 3 -> 4 for the Art System's `equippedArts` field (Types.PlayerProfile), which is what
	-- makes an unlocked art reachable from the hotbar across sessions -- PlayerDataSystem.lua's
	-- Migrations[3] backfills an empty slot map onto any record saved before this pass. Bumped 4 -> 5
	-- for the Parkour System's `settings.Parkour` sub-table (Types.ParkourSettings) --
	-- PlayerDataSystem.lua's Migrations[4] backfills the shipped defaults onto any record saved before
	-- this pass, so an existing player's first login after the update has parkour on with every assist
	-- enabled rather than a half-populated settings table. Bumped 5 -> 6 for the camera-comfort
	-- accessibility block (`settings.Comfort`, Types.ComfortSettings) -- PlayerDataSystem.lua's
	-- Migrations[5] backfills it with both effects ENABLED, matching what every player already
	-- experiences today, so the migration changes nobody's game and only gives them a switch. Bumped
	-- 6 -> 7 for the Race Traits + Bloodline Abilities plan's `bloodlineStageProgress` field
	-- (Types.PlayerProfile) -- PlayerDataSystem.lua's Migrations[6] backfills an empty table onto any
	-- record saved before this pass, the same "empty is honest" shape Migrations[3] already used for
	-- equippedArts. Bumped 7 -> 8 for the bloodline spin's `bloodlineRerolls` field, and 8 -> 9 for the
	-- Blimp Fuel System's `blimpFuel` field (Types.PlayerProfile) -- PlayerDataSystem.lua's
	-- Migrations[8] backfills { Coal = 0, Water = 0 } onto any record saved before this pass, the same
	-- "empty is honest" shape as every migration before it. Bumped 9 -> 10 for the UI System's
	-- `settings.UI` sub-table (Types.UISettings) -- the same "new settings group" shape Migrations[5]
	-- used for Comfort -- PlayerDataSystem.lua's Migrations[9] backfills Scale = 1 (100%, today's only
	-- size, unchanged for every existing player) onto any record saved before this pass.
	SchemaVersion = 10,

	-- A brand-new profile's starting Tier -- Tier 1 is the bottom of TierSystem's nine-tier ladder
	-- (progression-systems.md), the correct starting point for a player who has never played before.
	DefaultTier = 1,

	-- Periodic autosave interval, seconds -- a crash/server-death safety net on top of the
	-- PlayerRemoving/BindToClose save paths (PlayerDataSystem.lua), which only fire on a clean
	-- leave/shutdown. Only DIRTY profiles (mutated since their last save, see PlayerDataSystem.
	-- Transform) are actually written each pass, not every loaded profile -- so this budget is
	-- "at most (population / this interval) writes per second," not a flat per-player-per-interval
	-- cost. Roblox's DataStore write budget scales with player count (roughly
	-- 60 + 10/player/minute per key) -- 180s means even a server where every single player mutates
	-- their profile every single autosave window writes at (population / 3) calls/min, comfortably
	-- inside that scaling budget for any population size this uses; a much shorter interval would
	-- start eating into budget headroom other DataStore-backed Systems (BugReportSystem,
	-- ModerationSystem) also draw from.
	AutosaveIntervalSeconds = 180,

	-- Default timeout for PlayerDataSystem.WaitForProfile when a caller doesn't pass its own --
	-- long enough to absorb a slow DataStore GetAsync + full retry/backoff exhaustion
	-- (worst case: BaseBackoffSeconds * (1+2+4) = 7s for 3 attempts) with real margin, short enough
	-- that a caller gating a gameplay action on a player's data isn't left hanging indefinitely.
	WaitForProfileDefaultTimeoutSeconds = 15,

	-- Upper bound (seconds) PlayerDataSystem's game:BindToClose handler waits for in-flight saves
	-- to finish before returning -- Roblox's own outer BindToClose budget varies by server
	-- population and isn't a fixed constant this codebase can rely on, so this is deliberately
	-- generous while still finite: better to return promptly once every save has actually
	-- completed than to hold the callback open needlessly, and a hard ceiling here still protects
	-- against a single stuck retry loop hanging the whole shutdown indefinitely.
	ShutdownSaveTimeoutSeconds = 25,

	-- Cross-server session lock (Types.PlayerDataLock, PlayerDataSystem.lua's loadProfile/saveProfile)
	-- -- see that type's own header for the race it closes. A foreign lock older than this is treated
	-- as abandoned (its holding server crashed/died without ever running PlayerRemoving/BindToClose,
	-- so it will never release it itself) rather than blocking a rejoin forever. Sized for the
	-- crash-recovery case specifically, not routine dirty-mutation frequency: the lock is claimed
	-- once at load and released once at the final save, never refreshed mid-session (see
	-- loadProfile's own header for why periodic refresh isn't needed -- Roblox never routes a second
	-- PlayerAdded for an already-connected player to a different server, so a live server's lock is
	-- never actually contended; only a genuine crash leaves one dangling). 300s is generous enough to
	-- absorb the ordinary "hop lands before the leaving server's save completes" race (which the
	-- retry loop below resolves in low single-digit seconds) while not punishing a post-crash rejoin
	-- with an excessive wait.
	LockStaleAfterSeconds = 300,

	-- How many times loadProfile retries a REFUSED lock claim (a live foreign lock, not a DataStore
	-- call failure -- DataStoreRetry's own retry already covers that separately, inside each attempt
	-- here) before giving up and kicking with LockHeldKickMessage, backed off by
	-- LockClaimRetryBackoffSeconds between attempts. Sized to comfortably outlast the ordinary "hop
	-- lands before the leaving server's own PlayerRemoving save completes" race -- a leave-triggered
	-- save is one DataStore round trip, typically well under either backoff window.
	LockClaimMaxAttempts = 3,
	LockClaimRetryBackoffSeconds = 2,

	-- Player-facing kick messages for the load-failure modes PlayerDataSystem.lua distinguishes
	-- (engineering-standards.md: DataStore failures are "expected-but-rare... not edge cases to
	-- ignore," and the safe fallback for any of them is "never fabricate a profile that could
	-- overwrite real save data on next write," not a generic message that hides which one happened).
	LoadFailureKickMessage = "Failed to load your character data. Please rejoin in a moment.",
	CorruptDataKickMessage = "Your save data could not be read. Please contact support if this persists.",
	-- Every retry in the claim loop above still found a live foreign lock -- almost always means the
	-- OTHER server hasn't finished this player's own leave-save yet (a slow hop), rarely a genuinely
	-- stuck lock; either way the correct move is asking the player to wait a moment and rejoin, not
	-- risking two servers writing the same profile at once.
	LockHeldKickMessage = "Your character data is still finishing up on another server. Please wait a moment and rejoin.",
	-- The WriteGeneration backstop (Types.StoredPlayerProfile's own header) tripped during a session
	-- that had already passed the lock claim -- this server's copy of the profile can no longer be
	-- trusted to save safely, so it kicks rather than let further play accumulate on data that will
	-- never reach disk.
	StaleSessionKickMessage = "Your data was saved from another server session. Please rejoin.",
}

return PlayerDataConstants
