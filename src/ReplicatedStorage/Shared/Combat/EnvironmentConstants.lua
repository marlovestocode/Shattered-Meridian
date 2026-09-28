--!strict
--[[
	EnvironmentConstants.lua

	Owns: the tunables of the environment's reactions to a fight -- the wall splat (a knockback that
	drives a body into a wall stuns it there) and the swing scuff (a swing that passes close to a wall
	kicks dust and chips off it). Read by Server/Combat/Environment/EnvironmentReactionSystem.lua, which
	decides both, by Shared/Combat/EnvironmentProbe.lua, which both sides cast with, and by
	Client/FX/EnvironmentFX.lua, which draws them.

	Standalone for the reason every combat subsystem's constants are (DefenseConstants' header): a module
	that can be added or removed without editing a central table. Presentation numbers (how much dust, what
	the chips look like) are NOT here -- they are FXConstants.EnvironmentImpact, client-only, per the
	FXConstants rule that nothing presentational may reach an outcome. The wall splat's stun IS here,
	because it is an outcome.

	Does not own: the knockback itself (DamageSystem / Shared/Damage/Knockback.lua), the hitstun it grants
	(DamageSystem.ExtendHitstun is the one path into hitstun), or what dust looks like (FXConstants).
]]

local EnvironmentConstants = {}

-- A surface counts as a WALL when its normal is within this of horizontal: |normal.Y| at or under it. 0.45
-- is about 63 degrees off vertical -- steep ramps and rock faces splat, a floor or a gentle slope does not.
-- Shared by the splat and the scuff so "is that a wall" has one answer.
EnvironmentConstants.MaxWallNormalY = 0.45

-- A part at or above this Transparency is not a surface anyone can see, so neither splat nor scuff reacts
-- to it: dust bursting off an invisible barrier reads as a bug, and a splat against one as a cheat.
EnvironmentConstants.MaxSurfaceTransparency = 0.95

-- THE WALL SPLAT. A landed hit whose launch is strong enough, aimed at a wall close enough to reach, stuns
-- the victim for StunSeconds from the moment they actually hit it -- a positional reward for the attacker
-- (pin them against the arena) and a positional threat for the defender (don't fight with your back to
-- stone). Combat-philosophy's terrain rule: it changes where you want to stand, not just a damage total.
--
-- JUDGED ON THE SERVER, WATCHED RATHER THAN PREDICTED. At the hit, the server casts along the launch and
-- remembers the wall if one is in reach; then it WATCHES the victim's own replicated position for up to
-- WatchSeconds (+ a ping allowance) and splats the first frame the body is actually at the wall. A player's
-- launch is applied by their own client after the hit-stop (Client/Combat/KnockbackClient.lua), so the
-- server cannot know when it lands -- but it can see where the body goes, and a client that refused the
-- launch never reaches the wall and so never earns the stun it would have taken. Nothing here trusts a
-- client report.
EnvironmentConstants.WallSplat = {
	Enabled = true,
	-- Below this horizontal launch speed (studs/s) a knock never splats. KnockbackAudit's own "strong
	-- enough to tell apart from running" line, plus margin: a nudge into a wall is a nudge, not a slam.
	MinHorizontalVelocity = 35,
	-- Stun from the moment of impact, through DamageSystem.ExtendHitstun (so it gates attack, guard and
	-- roll exactly like any other hitstun, and never shortens one already running). Sized so the attacker
	-- who drove them there has time to close and land one committed follow-up -- the same "reliably eats
	-- one more committed attack" promise DamageConstants.Hitstun makes -- without it becoming a free combo.
	StunSeconds = 0.85,
	-- How far the body can plausibly travel under the launch. A player's client decays the horizontal
	-- launch linearly to zero over DamageConstants.Knockback.HoldSeconds, so the distance is speed * hold / 2;
	-- this is added to that, for a server-owned body that keeps its momentum a little longer and for the
	-- body's own half-width.
	ExtraReachStuds = 3,
	-- The body counts as AT the wall when its root is within this of the wall's plane (R6 torso half-depth
	-- is 0.5; half-width 1 -- a glancing arrival reads the wider number).
	ContactDistanceStuds = 1.9,
	-- And no further than this from the point the launch was aimed at, measured along the wall: a body that
	-- slid sideways along the wall and out of the corner has left the splat behind.
	MaxLateralDriftStuds = 6,
	-- How long the server watches for the arrival, from the hit. Covers the hit-stop freeze the client
	-- holds before launching (FXConstants.HitStop, at most ~0.2s), the flight itself, and replication.
	WatchSeconds = 0.8,
	-- Plus up to this much of the victim's measured round trip, so a laggy victim's launch still counts --
	-- capped because ping is client-influenced (the same cap reasoning as Parry.PingCompensationMaxSeconds).
	PingAllowanceMaxSeconds = 0.35,
}

-- THE SWING SCUFF. When a swing reaches its strike (the end of its windup) close enough to a wall, dust
-- and chips come off the wall where the blade would have met it. Cosmetic only -- no damage, no stun, no
-- effect on the swing -- so it may be decided twice: the attacker's own client predicts it at its own
-- strike (no round trip on your own swing), and the server casts the same probe to tell everyone else.
EnvironmentConstants.SwingScuff = {
	Enabled = true,
	-- How far in front of the swinger the probe reaches -- about a weapon's reach past the body.
	ReachStuds = 6.5,
	-- The fan of horizontal rays, in degrees off the swinger's facing. A swing sweeps an arc; one ray
	-- straight ahead would miss the wall a diagonal cut glances off.
	FanDegrees = { 0, -25, 25, -50, 50 } :: { number },
	-- Height of the fan above the root: roughly where the blade travels.
	HeightOffsetStuds = 0.6,
	-- The server tells only players this close to the swing. Dust further away than this is not worth
	-- a remote.
	BroadcastRadiusStuds = 160,
}

EnvironmentConstants.Network = {
	RemoteNames = {
		-- Server -> nearby clients: a splat or a scuff happened here. EnvironmentTypes-shaped payload.
		Fx = "Combat_EnvironmentFX",
	},
}

return EnvironmentConstants
