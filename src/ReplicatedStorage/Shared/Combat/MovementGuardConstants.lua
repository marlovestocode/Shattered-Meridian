--!strict
--[[
	MovementGuardConstants.lua

	Owns: the tunables of Server/Combat/MovementGuard.lua -- the server's check that an ENGAGED player's body moves
	the way a body that obeys this game's movement could move. Its header has the whole argument; the short form:

	WHY NOW. A player's character is simulated by their own client (Roblox network ownership), so a client can write
	its own position. That was always true. What changed on 2026-10-07 is that lag-compensated hits
	(HitboxEngineConstants.LagCompensation) test swings against positions the server RECORDED, so a teleport or a
	speed hack now also bends whose hits land -- this is the check that keeps that honest while a fight is on.

	EVERY NUMBER HERE ERRS LENIENT, for the reason ParkourConstants.Validation gives: a false positive on an honest
	player mid-fight is far worse than a miss on a cheater, and nothing here punishes -- a pattern of strikes flags
	the player for a human to review (Server/Systems/Support/SuspicionLedger.lua), and a strike suspends only the
	lag-compensation benefit of that player's own swings for a few seconds.
]]

local MovementGuardConstants = {}

MovementGuardConstants.Enabled = true

-- How often each engaged player is sampled. The server sees a client's position only as often as it replicates, so
-- sampling faster than ~10 Hz reads the same position twice and buys nothing.
MovementGuardConstants.SampleSeconds = 0.1

-- SPEED, judged over a window rather than per sample: replication arrives in bursts (two frames of movement in one
-- packet), and a window turns those back into the speed the body actually covered.
MovementGuardConstants.Speed = {
	-- How long a window is judged over.
	WindowSeconds = 0.5,
	-- The body's own legitimate horizontal speed is its server-side WalkSpeed (RunSystem owns it, ladders and
	-- carries included). Allowed = WalkSpeed * Tolerance + SlackStuds / window.
	Tolerance = 1.35,
	SlackStuds = 4,
	-- While a parkour action owns the body's velocity (dash, slide, leap), its speed is bounded by what
	-- ParkourValidation already accepts (ParkourConstants.Validation.MaxTravelSpeed), not by WalkSpeed.
	-- A body may climb no faster than this, on average over a window (a jump's peak is ~50 studs/s, but only
	-- for an instant; parkour climbs are excused above). Falling is never judged.
	MaxRiseSpeed = 40,
	-- A higher allowance granted this recently still applies (MovementGuard.allowanceFor): a dash's speed outlives
	-- the parkour action that granted it while RunSystem ramps WalkSpeed back up from zero.
	CarrySeconds = 1.0,
}

-- TELEPORT: one replicated step that covers more ground than any legitimate body could since the last position the
-- server saw change. Judged against the time since that change, so a client that stalled for a second and then
-- caught up in one packet is judged over the whole second, not one frame.
MovementGuardConstants.Teleport = {
	MinStuds = 20,
	-- The step's implied speed must also exceed the allowed speed by this factor.
	SpeedFactor = 2.5,
	-- A teleport is unambiguous enough to count as this many strikes.
	StrikeWeight = 3,
}

-- The ledger: how many (weighted) strikes inside the window flag a player for review, once per session.
MovementGuardConstants.Flag = {
	Strikes = 12,
	WindowSeconds = 90,
}

-- A strike suspends lag compensation for that player's OWN swings (HitboxEngine.SuspendCompensation) this long:
-- a body whose recent positions cannot be trusted should not be handed the benefit of rewinding its victims.
MovementGuardConstants.SuspendCompensationSeconds = 5

return MovementGuardConstants
