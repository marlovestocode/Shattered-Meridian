--!strict
--[[
	CoreSlice.lua

	Owns: the profile fields no other domain has claimed yet -- `userId`, `faction`, `tier`, `corruption`, `qiDeviationRisk`,
	`factionStanding`, `hasAscended` and `meridianXp` -- and how they are defaulted, copied, encoded and decoded. Moved here out of
	PlayerDataSystem (coworking plan W5, 2026-10-25) unchanged; the round-trip corpus (Tests/PlayerData/ProfileRoundTrip.spec.lua)
	pins the persisted bytes to what they were.

	WHY THESE ARE ONE SLICE AND NOT SIX. Each belongs to a progression System (tier -> TierSystem, meridianXp -> MeridianSystem,
	corruption/qiDeviationRisk -> QiDeviationSystem, faction/factionStanding -> the faction stub, hasAscended -> AwakeningSystem), but
	those Systems are mostly stubs and none owns a codec yet. Splitting a one-line default and a one-line decode per field into
	six files would be ceremony; when a System becomes real and wants more than a number here, its field moves out of this slice
	into its own, and this file shrinks. `userId` stays: the DataStore KEY is always the trustworthy source for it.

	DECODE. Every field is individually type-checked and falls back to a safe default rather than trusting the shape; `userId` falls
	back to `fallbackUserId` (the real UserId the record was loaded under) when the stored one is missing or wrong. A malformed
	`faction` is nil, never a fabricated faction.

	No migrations: these fields predate the schema versions.

	Does not own: what a tier or corruption MEANS (their Systems), or the DataStore key (PlayerDataSystem).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local Schema = require(ReplicatedStorage.Shared.Schema)
local ProfileSlice = require(script.Parent.Parent.ProfileSlice)

local Config = Constants.PlayerData

return ProfileSlice.Define({
	Name = "Core",
	Fields = {
		"userId",
		"faction",
		"tier",
		"corruption",
		"qiDeviationRisk",
		"factionStanding",
		"hasAscended",
		"meridianXp",
	},

	Default = function(userId: number)
		return {
			userId = userId,
			tier = Config.DefaultTier,
			corruption = 0,
			qiDeviationRisk = 0,
			factionStanding = 0,
			hasAscended = false,
			meridianXp = 0,
		}
	end,

	Copy = function(profile: any)
		return {
			userId = profile.userId,
			faction = profile.faction,
			tier = profile.tier,
			corruption = profile.corruption,
			qiDeviationRisk = profile.qiDeviationRisk,
			factionStanding = profile.factionStanding,
			hasAscended = profile.hasAscended,
			meridianXp = profile.meridianXp,
		}
	end,

	Encode = function(profile: any)
		return {
			userId = profile.userId,
			faction = profile.faction,
			tier = profile.tier,
			corruption = profile.corruption,
			qiDeviationRisk = profile.qiDeviationRisk,
			factionStanding = profile.factionStanding,
			hasAscended = profile.hasAscended,
			meridianXp = profile.meridianXp,
		}
	end,

	Decode = function(raw: { [string]: any }, fallbackUserId: number)
		return {
			userId = Schema.NumberOr(raw.userId, fallbackUserId),
			faction = if Schema.IsString(raw.faction) then raw.faction else nil,
			tier = Schema.NumberOr(raw.tier, Config.DefaultTier),
			corruption = Schema.NumberOr(raw.corruption, 0),
			qiDeviationRisk = Schema.NumberOr(raw.qiDeviationRisk, 0),
			factionStanding = Schema.NumberOr(raw.factionStanding, 0),
			hasAscended = if Schema.IsBoolean(raw.hasAscended) then raw.hasAscended else false,
			meridianXp = Schema.NumberOr(raw.meridianXp, 0),
		}
	end,
})
