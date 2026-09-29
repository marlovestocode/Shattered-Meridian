--!strict
--[[
	LockOnConstants.lua

	Owns: the tunables of lock-on targeting (Client/Combat/LockOnController.lua) and of the swing
	tracking that turns a thrower toward their target during a windup (Client/Combat/SwingTracking.lua).
	One file for both, because tracking reads the lock-on target first and only falls back to its own
	soft assist when there is none.

	WHAT LOCK-ON IS HERE. A soft camera lock: the camera is eased toward the target every frame, and the
	player's own mouse or stick input still moves it on top, so a locked player can glance away and is
	pulled back. With shift lock on, the body follows the camera and so faces the target. Without it the
	body still runs freely, and turns toward the target only during a swing's windup (tracking).

	TRACKING IS CAPPED, deliberately. The body turns toward the target at most TurnDegreesPerSecond during
	a windup, so a defender who side-steps late enough still beats the swing. An uncapped snap would make
	every swing a homing swing and delete spacing as a defence.

	Everything here is client presentation and aim. The server's hitbox still reads the body's real
	replicated facing, so none of this is trusted for a hit.
]]

local LockOnConstants = {}

-- Targeting --------------------------------------------------------------------------------------------

LockOnConstants.Targeting = {
	-- How far a lock can be acquired, and how far it holds before breaking on its own. The gap between
	-- them keeps a lock from flickering off and on at the edge of range.
	AcquireRangeStuds = 60,
	BreakRangeStuds = 80,
	-- Acquisition prefers the combatant nearest the centre of the screen. Candidates further than this
	-- from the camera's look direction are not considered at all.
	AcquireConeDegrees = 55,
	-- Score = angle off centre (degrees) + distance (studs) * this. Low weight: the screen centre decides,
	-- distance only breaks near-ties.
	DistanceWeight = 0.35,
	-- Seconds the target may stay out of line of sight before the lock breaks. Brief occlusion (a pillar
	-- between you mid-fight) must not drop it.
	OcclusionGraceSeconds = 1.25,
	-- The point on the target the camera aims at and the marker sits over, above the root.
	AimHeightStuds = 1.5,
	MarkerHeightStuds = 3.4,
}

-- Camera -----------------------------------------------------------------------------------------------

LockOnConstants.Camera = {
	-- How hard the camera is pulled toward the target: the natural frequency (rad/s) of a spring on the
	-- camera's yaw and pitch, and its damping ratio (1 = critical, no overshoot). High enough to hold the
	-- target on screen through a strafe, low enough that the player's own input still visibly moves the
	-- camera on top of it.
	--
	-- A SPRING, NOT AN EASE (2026-09-29). This was an exponential ease (rates 9 and 5), which turns at full
	-- speed the instant the target's bearing jumps -- and in a fight it jumps constantly: every step-in,
	-- every lunge, every sidestep at arm's length. The camera snapped at the start of each of those. A
	-- spring carries its own angular velocity, so it accelerates into a turn and eases out of it.
	YawFrequency = 14,
	PitchFrequency = 9,
	Damping = 1,
	-- CLOSE RANGE, THE PULL SOFTENS. At arm's length a half-stud sidestep swings the bearing by 10 degrees
	-- or more, so a full-strength pull there whips the camera on every exchange. Inside CloseRangeStuds the
	-- frequencies are scaled down linearly, to CloseRangeScale at MinDistanceStuds, so a brawl reads as
	-- steady and the camera still tracks a target that is really moving away.
	CloseRangeStuds = 8,
	CloseRangeScale = 0.4,
	-- The camera looks slightly DOWN on the target rather than straight at it, so the ground between you
	-- stays in view. Radians added to the pitch that would aim exactly at the target point.
	PitchBias = math.rad(-8),
	-- The pitch the lock will pull to, clamped, so a target on a ledge above does not tip the camera
	-- into the sky.
	MinPitch = math.rad(-45),
	MaxPitch = math.rad(20),
	-- Inside this distance the camera stops chasing the target's direction. Two bodies overlapping would
	-- otherwise spin the camera as the direction between them flips.
	MinDistanceStuds = 2.5,
}

-- Tracking ---------------------------------------------------------------------------------------------

LockOnConstants.Tracking = {
	Enabled = true,
	-- The cap on how fast a windup turns the body toward its target -- with a lock, and without one.
	LockedTurnDegreesPerSecond = 540,
	AssistTurnDegreesPerSecond = 300,
	-- The soft assist, used when nothing is locked: the nearest combatant in front of the body within
	-- this range and half-angle. Narrow and short on purpose -- it corrects aim, it does not pick fights.
	AssistRangeStuds = 11,
	AssistConeDegrees = 60,
	-- Tracking stops when the hit window opens, plus this much. Turning through the active window would
	-- sweep the server's hitbox sideways, which is a bigger hitbox, not a better aim.
	StopAfterWindupSeconds = 0,
}

-- Step-in ----------------------------------------------------------------------------------------------

-- The target-aware step a swing takes toward its target (Client/Combat/SwingLunge.lua), on top of the
-- per-kind step AttackConstants.Presentation.SwingLunge authors. It only ever CLOSES a gap to StandoffStuds:
-- a target already in range gets no step at all, and nothing is stepped toward without a target. That is
-- what keeps it from being the gap-closer the Basic step was removed for.
LockOnConstants.StepIn = {
	Enabled = true,
	-- The root-to-root distance a step closes to. Just inside the body box's reach.
	StandoffStuds = 3.4,
	-- The furthest a step will ever carry, whatever the gap. A target further than StandoffStuds plus this
	-- is simply out of range, and the swing whiffs where the player threw it.
	MaxStepStuds = 2.4,
	-- Anything smaller is not worth a step.
	MinStepStuds = 0.4,
	DurationSeconds = 0.16,
	-- For a kind with no authored step (Basic), the step STARTS this long before the windup ends, so the
	-- body arrives as the hit window opens rather than stepping into it afterwards. A kind with its own
	-- authored step keeps that step's DelaySeconds.
	LeadSeconds = 0.16,
	-- Which kinds take the target-aware step. A kind with its own authored step (Heavy) uses the smaller
	-- of the two, so a Heavy never runs through a target standing close.
	ByKind = {
		Basic = true,
		Heavy = true,
	} :: { [string]: boolean },
}

-- Marker -----------------------------------------------------------------------------------------------

LockOnConstants.Marker = {
	-- The guard bar under the marker (DefenseConstants.GuardFraction). Pixel size before the UI scale.
	GuardBarWidth = 46,
	GuardBarHeight = 3,
}

return LockOnConstants
