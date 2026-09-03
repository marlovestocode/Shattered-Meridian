--!strict
--[[
	TierConstants.lua

	Owns: every tier-ladder tunable -- the nine tiers' names, their cumulative Meridian XP
	thresholds, and the Progression_TierUpdated remote name. Its own dedicated Shared module rather
	than a Constants.Tier sub-table, for exactly the reason QiConstants.lua documents for itself:
	tuning progression should never grow the already-flagged "Constants.lua holds content, not
	tunables" problem (docs/architecture/2026-08-audit.md section 5) any further.

	THE DYNAMIC-TUNING CONTRACT (same contract QiConstants.lua established): this file is the ENTIRE
	tuning surface for the tier ladder. TierSystem.lua reads every value here fresh on every call --
	nothing is cached into a module-level local at Init time. Editing a threshold below and
	re-syncing (Rojo) IS the full tuning loop; no TierSystem.lua code change is ever required to
	retune the ladder's pace, rename a tier, or add/remove one.

	RemoteNames lives here, not in Constants.lua's per-feature RemoteNames tables, on the rule that
	a dedicated module owning its feature's tuning should own its feature's wire names too -- so
	adding a tier-related remote never means editing Constants.lua. This file and
	EmoteConstants.RemoteNames set that precedent against the older one, a wire name kept in
	Constants.lua; QiConstants.RemoteNames has since followed it too, so the two disagreeing
	conventions this header used to have to choose between are now one.

	Does not own: any per-player tier state or the promotion decision itself (TierSystem.lua), the
	Meridian XP that feeds the thresholds below (MeridianSystem.lua owns awarding it,
	PlayerDataSystem owns persisting it), or what a tier is worth mechanically -- QiConstants.
	MaxQiByTier already prices tier into Max Qi, and it owns that curve independently of this file.
]]

local TierConstants = {}

TierConstants.RemoteNames = {
	TierUpdated = "Progression_TierUpdated",
}

-- The nine power tiers (progression-systems.md: "Nine power tiers form the backbone all other
-- systems hook into"). Types.Tier stayed a bare `number` with a comment deferring names/thresholds
-- to "a technical-design decision owned by TierSystem, not yet finalized" -- this table is that
-- decision landing. Types.Tier stays numeric: the number is the canonical identity (it indexes
-- QiConstants.MaxQiByTier, it persists in PlayerProfile.tier), and the name below is presentation.
--
-- MeridianXP is the CUMULATIVE lifetime total required to hold the tier, not a per-tier cost that
-- resets on promotion -- Meridian XP is never spent or lost (MeridianSystem.AwardMeridianXP's own
-- header: there is deliberately no SubtractMeridianXP), so a running total compared against a fixed
-- ladder is the only shape consistent with that. Tier 1's threshold is 0 by construction: it's
-- Constants.PlayerData.DefaultTier, what a brand-new profile already holds before earning anything.
--
-- Pacing, stated in kills so the curve is reviewable rather than a wall of numbers -- at
-- Constants.Meridian.BaseXPPerKill (25) a confirmed PvP kill is 25 XP, so the cumulative kill counts
-- are 0 / 6 / 18 / 40 / 80 / 144 / 248 / 400 / 620. Deliberately a long tail: the early tiers land
-- inside a first session (Tier 2 in six kills) so a new player feels the ladder move, while Tier 9
-- is a genuine commitment rather than a weekend. Retune freely -- nothing in TierSystem.lua assumes
-- any particular spacing, only that thresholds ascend (see TierConstants.Validate below).
--
-- Names run one arc: meridians sealed, opening, circulating, then breaking and reforming. Tier 8
-- ("Shattered Vessel") is the game's own title as the ladder's crisis point -- the break that
-- precedes the last step, not a failure state. Tier 9 is deliberately NOT called "Ascendant":
-- Ascension is AwakeningSystem's own separate, rare Human-Awakening gate (world-bible.md /
-- progression-systems.md), and reusing the word here would make two unrelated systems sound like
-- one progression track.
TierConstants.Tiers = {
	{ Name = "Sealed Vein", MeridianXP = 0 },
	{ Name = "First Thread", MeridianXP = 150 },
	{ Name = "Opened Meridian", MeridianXP = 450 },
	{ Name = "Flowing Channel", MeridianXP = 1000 },
	{ Name = "Tempered Core", MeridianXP = 2000 },
	{ Name = "Radiant Circuit", MeridianXP = 3600 },
	{ Name = "Sovereign Flow", MeridianXP = 6200 },
	{ Name = "Shattered Vessel", MeridianXP = 10000 },
	{ Name = "Immortal Meridian", MeridianXP = 15500 },
} :: { { Name: string, MeridianXP: number } }

-- Highest tier this ladder defines. Derived from the table above rather than hand-written as `9`,
-- so adding or removing a tier entry is a one-line edit that can't leave a stale count behind --
-- the specific failure QiConstants.MaxTierDefined's own hand-written 9 is exposed to, and worth
-- diverging from that precedent for.
TierConstants.MaxTier = #TierConstants.Tiers

-- Name shown for a tier number outside the ladder. Reachable only through a corrupted/hand-edited
-- profile or a ladder that shrank under a save written against a longer one -- TierSystem.GetTierName
-- returns this rather than erroring, so a bad tier number degrades to a visibly wrong label instead
-- of breaking the HUD mount for that player.
TierConstants.UnknownTierName = "Unknown"

-- Structural invariant TierSystem.ComputeTierForXP depends on: thresholds must ascend strictly, or
-- "the highest tier whose threshold is met" stops being well-defined and a retune could silently
-- make a tier unreachable. Exported as a function (not asserted at require time) so the regression
-- suite can exercise it headlessly without a mis-edit taking the whole server down at boot -- a
-- broken ladder should fail a test run, not a live game's require chain.
function TierConstants.Validate(): (boolean, string?)
	if #TierConstants.Tiers == 0 then
		return false, "Tiers is empty"
	end
	if TierConstants.Tiers[1].MeridianXP ~= 0 then
		return false, "Tier 1 threshold must be 0"
	end
	for index = 2, #TierConstants.Tiers do
		local previous = TierConstants.Tiers[index - 1].MeridianXP
		local current = TierConstants.Tiers[index].MeridianXP
		if current <= previous then
			return false, `Tier {index} threshold ({current}) does not exceed tier {index - 1} ({previous})`
		end
	end
	return true, nil
end

return TierConstants
