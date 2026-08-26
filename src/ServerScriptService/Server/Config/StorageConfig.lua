--!strict
--[[
	StorageConfig.lua

	Owns: every DataStore/OrderedDataStore NAME this game persists to, in one place.

	Lives under ServerScriptService/Server/Config/ rather than ReplicatedStorage/Shared/Constants.lua
	for the same reason AdminConfig.lua does: these names were replicated to every client, where they
	are useless to legitimate code (DataStoreService is server-only -- a client cannot open a store
	even knowing its exact name) and are pure reconnaissance for anyone else. Moving them out costs
	nothing and removes the disclosure. See AdminConfig.lua's header for the fuller reasoning.

	Naming convention, established by BugReport (the first DataStoreService usage in this codebase)
	and followed by every store since: a version suffix on every name, bumped on any schema change
	that isn't backward-compatible, so a migration can read the old store and write the new one
	rather than corrupting live records in place.

	Does not own: retry/backoff policy, autosave cadence, page sizes, or any other persistence
	TUNING -- those stay in Constants.lua alongside the rest of each System's tunables, because they
	are ordinary numbers a designer or engineer may want to adjust and they disclose nothing. Only the
	store IDENTIFIERS moved here. Also does not own the DataStore calls themselves; each owning System
	(PlayerDataSystem, BugReportSystem, ModerationSystem) still opens and uses its own store.
]]

local StorageConfig = {}

-- Canonical player-progression persistence (Server/Systems/PlayerDataSystem.lua) -- the single
-- DataStore-backed owner every other System's player-state reads/writes eventually route through.
-- Bumped v5 -> v6 as a deliberate full-population wipe (every player gets a fresh
-- CreateDefaultProfile on next join), not a schema-incompatible change -- see PlayerDataSystem.
-- MigrateRecord for the separate mechanism that actually exists for THAT case.
StorageConfig.PlayerDataStoreName = "PlayerProfiles_v6"

-- Bug reports (Server/Systems/BugReportSystem.lua). The ordered store exists purely to index reports
-- by submission time for the dev menu's Reports tab; the main store holds the records themselves.
StorageConfig.BugReportDataStoreName = "BugReports_v1"
StorageConfig.BugReportOrderedDataStoreName = "BugReportsByTime_v1"

-- Moderation (Server/Systems/ModerationSystem.lua). Two separate stores, deliberately: a ban record
-- and a suspected-cheater flag share no schema, and a flag is reversible (RemoveAsync on Unflag)
-- where a ban is permanent by default. Both are also separate from BugReport's store above -- a ban
-- and a bug report have no reason to share a key namespace.
StorageConfig.BanDataStoreName = "PlayerBans_v1"
StorageConfig.SuspectedCheaterDataStoreName = "SuspectedCheaters_v1"

-- Move Creation System (Server/Systems/MoveEditorSystem.lua) -- one key per authored move
-- ("Move_<MoveId>") plus a small fixed-key index record ("MoveIndex") listing every MoveId, since
-- DataStore has no native "list all keys" and the authored-move count is small (tens, not
-- thousands) -- see MoveEditorSystem.lua's own header for the full persistence shape.
StorageConfig.CustomMoveDataStoreName = "CustomMoves_v1"

-- Race Traits + Bloodline Abilities plan (Server/Systems/KitEditorSystem.lua) -- same "one key per
-- record plus a small fixed-key index" shape CustomMoveDataStoreName's own header describes, one
-- store per content type since a race trait and a bloodline stage share no schema. Index keys are
-- "RaceTraitIndex"/"BloodlineIndex"; record keys are "RaceTrait_<TraitId>"/"Bloodline_<BloodlineId>".
StorageConfig.RaceTraitDataStoreName = "RaceTraits_v1"
StorageConfig.BloodlineDataStoreName = "Bloodlines_v1"

-- Server publish-version watchdog (Server/Systems/VersionWatchSystem.lua) -- a single small store
-- holding one fixed key, the highest game.PlaceVersion any server has ever reported booting with.
-- See that module's own header for why this is enough to detect a publish with no external tooling.
StorageConfig.ServerVersionDataStoreName = "ServerVersionWatch_v1"

return StorageConfig
