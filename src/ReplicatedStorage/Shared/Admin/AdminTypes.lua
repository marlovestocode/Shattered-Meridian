--!strict
--[[
	Admin/AdminTypes.lua

	Owns: the wire shapes of the admin panel's READ surface -- the overview it polls (roster + server
	status), the inspection of one player, and the answers to the handful of actions that report
	something back beyond success. Server/Systems/DevMenuSystem.lua builds every one of these;
	Client/DevTools/DevMenu/DevMenuClient.lua is the only reader.

	A LEAF, like Shared/Types.lua: requires nothing but that file (for EngagementPayload), so both
	halves can depend on it without a cycle.

	RAW VALUES, NOT FORMATTED STRINGS. The server sends numbers, booleans and ids; the client decides
	how a ping or an uptime reads (Shared/Admin/AdminFormat.lua). A server that pre-formatted
	"42ms" would be deciding presentation for a screen it cannot see, and the one place a number is
	compared (a critical-health roster row, a stale ping) would have to parse it back.

	Does not own: the action results that are plain success/failure (Types.DevMenuActionResult), or
	anything bug-report shaped (Types.BugReportRecord and its wrappers, BugReportSystem's).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

-- One player in the roster rail. Cheap enough to build for every player every poll: every field is
-- a table read or a replicated Attribute, never a DataStore call.
export type RosterEntry = {
	UserId: number,
	-- Roblox username (unique) and display name.
	Name: string,
	DisplayName: string,
	-- The in-game character name chosen at chargen, nil before it.
	CharacterName: string?,
	-- The admin whose request built this overview. The server marks it rather than the client
	-- comparing UserIds, so the roster's "you" row needs no LocalPlayer read inside the screen.
	IsRequester: boolean,
	Tier: number,
	PingMs: number,
	Alive: boolean,
	-- 0..1, 0 while dead or with no character.
	HealthFraction: number,
	InCombat: boolean,
	-- Active admin overrides (AdminActionSystem's replicated Humanoid Attributes).
	Godmode: boolean,
	Flying: boolean,
	Frozen: boolean,
	Invisible: boolean,
	SpeedMultiplier: number,
	-- Moderation state.
	Muted: boolean,
	Flagged: boolean,
	-- Carries an active bounty (BountySystem.IsMarked).
	Marked: boolean,
}

export type ServerOverview = {
	UptimeSeconds: number,
	PlayerCount: number,
	MaxPlayers: number,
	-- Server/Diagnostics/ServerFrameStats.lua's published numbers; nil when that module is off.
	ServerFps: number?,
	WorstFrameMs: number?,
	-- Stats:GetTotalMemoryUsageMb() on the server.
	MemoryMb: number,
	PlaceVersion: number,
	-- The highest version any server has reported booting with (VersionWatchSystem); nil before its
	-- first DataStore read resolves.
	LatestPlaceVersion: number?,
	JobId: string,
	IsStudio: boolean,
	OpenReports: number,
	FlaggedCount: number,
	-- Players currently combat-tagged (EngagementSystem).
	EngagedCount: number,
	-- The two server-wide debug toggles, so the World tab never shows a guess.
	HitboxVolumes: boolean,
	DummyGuard: boolean,
	DummyCount: number,
	BotCount: number,
}

export type OverviewResult = {
	Success: boolean,
	Reason: string?,
	Server: ServerOverview?,
	Roster: { RosterEntry }?,
}

export type BloodlineLine = {
	Id: string,
	-- BloodlineManager's DisplayName, or the id itself for a bloodline no longer in the registry.
	Name: string,
	Stage: number,
}

-- Everything the inspector rail shows about one player.
export type Inspection = {
	UserId: number,
	Name: string,
	DisplayName: string,
	AccountAgeDays: number,
	IsRequester: boolean,
	PingMs: number,

	-- False while the profile is still loading (or failed to) -- every cultivation field below is
	-- then its default and says nothing about the player.
	ProfileLoaded: boolean,
	CharacterName: string?,
	RaceId: string?,
	Faction: string?,
	Tier: number,
	TierName: string,
	MeridianXP: number,
	TierFloorXP: number,
	-- nil at the top tier.
	TierNextXP: number?,
	Bloodlines: { BloodlineLine },
	BloodlineRerolls: number,
	Corruption: number,
	QiDeviationRisk: number,
	EquippedArtCount: number,

	Alive: boolean,
	Health: number,
	MaxHealth: number,
	Qi: number,
	MaxQi: number,
	-- nil when the character is not a registered combatant (dead, or between lives).
	Guard: number?,
	MaxGuard: number?,
	DefenseState: string?,
	Engagement: Types.EngagementPayload?,
	KillStreak: number,
	Marked: boolean,

	Position: Vector3?,
	Godmode: boolean,
	Flying: boolean,
	FlyCollide: boolean,
	Frozen: boolean,
	Invisible: boolean,
	SpeedMultiplier: number,
	Muted: boolean,
	Flagged: boolean,
}

export type InspectResult = {
	Success: boolean,
	Reason: string?,
	Inspection: Inspection?,
}

-- A ban record as Server tab's offline lookup shows it. BanReason, not Reason: Reason is the
-- failure field on every result shape in this codebase.
export type BanLookup = {
	UserId: number,
	Banned: boolean,
	BanReason: string?,
	BannedAt: number?,
	BannedByUserId: number?,
	-- nil for a permanent ban.
	ExpiresAt: number?,
	-- Whether that UserId is in THIS server right now.
	Online: boolean,
}

export type BanLookupResult = {
	Success: boolean,
	Reason: string?,
	Lookup: BanLookup?,
}

export type GrantXPResult = {
	Success: boolean,
	Reason: string?,
	Granted: number?,
	Total: number?,
	Tier: number?,
}

return {}
