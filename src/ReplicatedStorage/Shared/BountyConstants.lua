--!strict
--[[
	BountyConstants.lua

	Owns: every Notoriety-bounty tunable -- the kill streak that marks a player, the Meridian XP a
	claim pays out, and this feature's remote names. Its own dedicated Shared module rather than a
	Constants.Bounty sub-table, following Shared/QiConstants.lua and Shared/TierConstants.lua for the
	same reason both of those document: tuning a progression system should not keep growing the
	"Constants.lua holds content, not tunables" problem docs/architecture/2026-08-audit.md section 5
	flagged. RemoteNames lives here too, matching EmoteConstants/TierConstants (a module that owns a
	feature's tuning owns its wire names), not Constants.Rivalry's older split.

	THE DYNAMIC-TUNING CONTRACT: this file is the ENTIRE tuning surface for bounty balance.
	BountySystem.lua reads every value here fresh on every call and caches none of it at Init time --
	editing a number below and re-syncing (Rojo) IS the full tuning loop.

	WHY NOTORIETY, AND NOT PLAYER-PLACED BOUNTIES. Bounties here are placed by the SERVER on players
	who are dominating, never bought by another player. That is a deliberate design decision, not an
	unfinished halfway point:

	  * It serves the actual stated purpose. docs/architecture/2026-08-audit.md section 7.2: the
	    system exists as "a visible counter to a snowballing player, so a server doesn't calcify
	    around one untouchable name," and notes that player-initiated placement "will always
	    undersample exactly the players most in need of a check" -- the dominant player is the one
	    nobody wants to spend on.
	  * It has no collusion vector. A free-to-place bounty that pays progression is farmable by two
	    players trading kills. Since nothing here is placed by a player, there is no placement to
	    collude on -- the only way a bounty exists is for the server to decide someone is winning too
	    much, and the only way it pays is a server-confirmed kill of that specific player.
	  * It needs no currency. PlayerProfile has no currency field and nothing grants one; the older
	    BountyReward shape's `currency`/`xp` members were never backed by anything real. Meridian XP
	    is the one progression resource that exists, persists, and (since TierSystem landed) actually
	    drives something.

	Player-placed bounties are not ruled out -- they need an economy first. When one exists, the seam
	is BountySystem.PlaceNotorietyBounty's `Source` field, not a rewrite.

	Does not own: any live bounty or streak state (BountySystem.lua), the Meridian XP grant itself
	(MeridianSystem.AwardMeridianXP), or the tier a reward scales against (TierSystem).
]]

local BountyConstants = {}

BountyConstants.RemoteNames = {
	-- Server -> all clients, fired only when the board actually changes (a bounty placed or claimed),
	-- never on a timer and never per-kill. See BountySystem.lua's own note on why this broadcast is
	-- not the unfiltered-FireAllClients shape the audit's Tier 2.1 flagged.
	BoardUpdated = "Bounty_BoardUpdated",
	-- Client -> server, the pull used when the bounty board menu opens, so a freshly-opened menu
	-- doesn't sit empty until the next change happens to be broadcast.
	GetActiveBounties = "Bounty_GetActiveBounties",
	-- Server -> the marked player ONLY. Being hunted is information the target must have -- see
	-- BountySystem.lua's header on why this is a separate targeted remote rather than something the
	-- client infers by scanning the broadcast board for its own name.
	MarkedChanged = "Bounty_MarkedChanged",
}

-- Consecutive kills without dying before the server marks a player. Three, not a bigger number:
-- this has to fire often enough that players actually see the mechanic exist, and a 3-kill streak in
-- an open-world PvP game is "doing well right now" rather than "unstoppable." The streak resets on
-- any death (BountySystem's own kill handler), so this is a measure of a CURRENT run, not a
-- lifetime total -- a strong player who trades kills evenly never gets marked, which is correct:
-- the system is a counter to snowballing, not a tax on skill.
BountyConstants.NotorietyStreakThreshold = 3

-- Meridian XP paid to whoever ends a marked player's run. Composed rather than flat so the reward
-- tracks how much of a problem the target actually is:
--
--   reward = Base + (PerStreakKill * kills beyond the threshold) + (PerTargetTier * target's tier)
--
-- Calibrated against Constants.Meridian.BaseXPPerKill (25, an ordinary kill). At the moment a player
-- is first marked (streak 3, tier 1) a claim pays 50 + 0 + 10 = 60, already ~2.4 ordinary kills. A
-- tier-5 player on a 10-kill run pays 50 + 105 + 50 = 205, ~8 ordinary kills -- enough that hunting
-- them is plainly the best XP on the server, which is the entire mechanism.
BountyConstants.BaseReward = 50
BountyConstants.PerStreakKillReward = 15
BountyConstants.PerTargetTierReward = 10

-- Hard ceiling on a single claim. A streak has no natural upper bound, and without this a player who
-- somehow ran up 200 kills would be worth a tier's worth of XP in one hit -- turning the counter to
-- snowballing into its own snowball for whoever lands the last blow.
BountyConstants.MaxReward = 400

-- Seconds before a placed bounty expires on its own. A marked player who logs off mid-streak (or
-- simply stops fighting) shouldn't leave a permanent entry on the board that no one can ever collect
-- -- the mark is meant to describe a run in progress. Cleared immediately rather than waiting on
-- this whenever the target dies or leaves; this is only the backstop for "still online, stopped
-- being a threat."
BountyConstants.ExpirySeconds = 900

-- How often BountySystem sweeps for expired bounties, seconds. Deliberately coarse: expiry is a
-- 15-minute concept, so checking it four times a minute is already far finer than the thing it
-- measures, and this rides GameplayEvents.OnHeartbeatTick (the one shared server tick) rather than
-- opening a second connection -- same discipline QiSystem's passive regen follows.
BountyConstants.ExpirySweepIntervalSeconds = 15

-- How long a claim RegisterKill resolved stays owed to its death, waiting for the progression spine to pay
-- it (BountySystem.PayClaim), seconds. Both halves hear the same death within a frame or two; this only
-- bounds the entry for a kill the spine refused (weighted to zero), which never comes back for it. Swept on
-- the expiry sweep above, so an entry may live up to this plus one interval.
BountyConstants.OwedClaimSeconds = 10

-- Read-only query remote, still rate limited -- same reasoning and same value as
-- Constants.Rivalry.QueryMaxCallsPerSecond: a modified client looping it gains nothing but costs
-- server time for free otherwise.
BountyConstants.QueryMaxCallsPerSecond = 4

-- Page size cap for the board query, so one invoke can never ask the server to serialize an
-- unbounded list. Bounties are bounded by player count in practice (at most one per player), so this
-- is a backstop against a pathological case, not an expected limit.
BountyConstants.MaxBoardEntries = 24

return BountyConstants
