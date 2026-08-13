--!strict
--[[
	States/WallRunning.lua

	Owns: running along a vertical surface -- entry conditions, following the wall's actual tangent,
	the rise-then-sink vertical profile, and every rule that stops it from becoming free vertical
	flight.

	FOLLOWING THE SURFACE, not moving sideways. The design called this out specifically ("should
	properly follow the surface of the wall rather than feeling like the player is simply moving
	sideways"), and the mechanism is ParkourMath.WallTangent: each frame the commanded velocity is the
	wall's own horizontal tangent, re-derived from the live surface normal and oriented to agree with
	the direction the character is already travelling. A curved wall therefore curves the run, and a
	corner ends it (the tangent swings past the approach-angle limit) rather than pushing the character
	through the corner.

	THE THREE ANTI-INFINITE-CLIMB RULES, which together are why this cannot be used to ascend
	arbitrarily and why none of them needed to be a blunt "no vertical gain" ban:
	  1. SameWallLockoutSeconds -- the specific part just left cannot be re-attached to for a moment.
	     Kills the "run, jump, re-attach to the same wall" ladder.
	  2. MaxChainWithoutGround -- a hard count of wall-runs since the last ground contact. Kills the
	     "three walls in a triangle" version rule 1 alone does not cover.
	  3. The vertical profile itself -- a short rise (RiseSeconds) then a decaying sink under a
	     fraction of gravity. The run visibly runs out of lift, which makes the limit legible without
	     any UI.

	Runs in Velocity drive mode with gravity cancelled, integrating its own vertical speed so the rise
	and sink are authored rather than emergent. The inward stick component is what keeps the character
	against the surface instead of drifting off it.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

local StateSupport = require(script.Parent.StateSupport)

type ParkourContext = ParkourTypes.ParkourContext
type WallProbe = ParkourTypes.WallProbe

local WALLRUN = ParkourConstants.WallRun

-- Which side the active run is on, and everything derived from the wall it is on. Captured at Enter
-- and refreshed each frame from whichever probe is still finding the same surface.
local side = 0
local verticalSpeed = 0
local reattachUntil = 0

-- Picks the wall to run on: whichever side has a usable surface, preferring the one the character is
-- travelling more nearly parallel to when both qualify. Returns the probe and the side (-1 left,
-- 1 right), or nil when neither side qualifies -- with the reason, so CanEnter can report it.
local function selectWall(context: ParkourContext): (WallProbe?, number, string?)
	local travel = StateSupport.TravelDirection(context)

	local function evaluate(probe: WallProbe): (boolean, number, string?)
		if not probe.Found then
			return false, 180, "NoWall"
		end
		if not probe.WallRunAllowed then
			return false, 180, "WallNotRunnable"
		end
		if probe.TiltAngle > WALLRUN.MaxSurfaceTiltDegrees then
			return false, 180, "SurfaceTooTilted"
		end
		local approach = ParkourMath.ApproachAngle(travel, probe.Tangent)
		if approach > WALLRUN.MaxApproachAngleDegrees then
			return false, approach, "ApproachAngleTooSteep"
		end
		return true, approach, nil
	end

	local leftOk, leftAngle, leftReason = evaluate(context.WallLeft)
	local rightOk, rightAngle, rightReason = evaluate(context.WallRight)

	if leftOk and rightOk then
		return if leftAngle <= rightAngle then context.WallLeft else context.WallRight,
			if leftAngle <= rightAngle then -1 else 1,
			nil
	end
	if leftOk then
		return context.WallLeft, -1, nil
	end
	if rightOk then
		return context.WallRight, 1, nil
	end
	return nil, 0, leftReason or rightReason or "NoWall"
end

-- The probe currently describing the wall being run on, or nil if it has been lost.
local function activeWall(context: ParkourContext): WallProbe?
	local probe = if side < 0 then context.WallLeft else context.WallRight
	if probe.Found and probe.WallRunAllowed then
		return probe
	end
	return nil
end

local WallRunning: ParkourTypes.StateDefinition = {
	Id = "WallRunning",
	Priority = 160,
	Drive = "Velocity",
	Probes = { Ground = true, Walls = true, Ledge = true },
	Reports = "WallRun",

	CanEnter = function(context: ParkourContext): (boolean, string?)
		if context.Ground.Grounded then
			return false, "Grounded"
		end
		if context.Now < reattachUntil then
			return false, "ReattachCooldown"
		end
		if context.WallRunChain >= WALLRUN.MaxChainWithoutGround then
			return false, "WallRunChainExhausted"
		end
		if context.Momentum < WALLRUN.MinEntrySpeed then
			return false, "TooSlowToWallRun"
		end
		if context.Ground.NearGround and context.Ground.Distance < WALLRUN.MinGroundClearance then
			return false, "TooCloseToGround"
		end
		local probe, _selected, reason = selectWall(context)
		if not probe then
			return false, reason
		end
		-- Rule 1: the wall just left is off-limits for a moment. Compared by Instance so a DIFFERENT
		-- wall is available immediately -- which is exactly the chained wall-run the design asks for,
		-- and is why this is a per-wall lockout rather than a global cooldown.
		if
			context.LastWallInstance ~= nil
			and probe.Instance == context.LastWallInstance
			and (context.Now - context.LastWallLeftAt) < WALLRUN.SameWallLockoutSeconds
		then
			return false, "SameWallLockout"
		end
		return true, nil
	end,

	Enter = function(context: ParkourContext): ()
		local probe, selectedSide = selectWall(context)
		side = selectedSide
		verticalSpeed = 0
		context.WallRunChain += 1
		context.AnimationVariant = if side < 0 then "Left" else "Right"
		if probe then
			-- Entry speed is clamped into the wall-run's own band: a very fast entry does not make the
			-- run faster than MaxSpeed, and a marginal one is lifted to the run's baseline so the run
			-- always reads as deliberate rather than as a slow scrape along a wall.
			context.Momentum = math.clamp(context.Momentum, WALLRUN.Speed, WALLRUN.MaxSpeed)
		end
	end,

	Update = function(context: ParkourContext): ParkourTypes.TransitionResult
		local probe = activeWall(context)
		if not probe then
			return "Falling"
		end
		if context.Ground.Grounded then
			return StateSupport.ResolveGroundedState(context)
		end
		if context.StateElapsed >= WALLRUN.MaxDurationSeconds then
			return "Falling"
		end

		-- Re-derived every frame from the live normal: this is what makes the run follow a curved
		-- surface and end at a corner rather than clipping through it.
		local tangent = ParkourMath.WallTangent(probe.Normal, StateSupport.TravelDirection(context))
		if tangent.Magnitude < 1e-3 then
			return "Falling"
		end

		verticalSpeed = ParkourMath.WallRunVerticalSpeed(
			context.StateElapsed,
			verticalSpeed,
			WALLRUN.RiseSeconds,
			WALLRUN.RiseSpeed,
			WALLRUN.GravityFraction,
			Workspace.Gravity,
			context.DeltaTime
		)

		-- Inward stick: a small velocity component INTO the wall (opposite its outward normal), which
		-- is what holds the character against the surface. Without it the run drifts off within a few
		-- frames as collision response pushes the body away.
		local stick = -ParkourMath.SafeUnit(ParkourMath.Flatten(probe.Normal), Vector3.zero) * WALLRUN.StickSpeed

		local motor = context.Motor
		motor.Mode = "Velocity"
		motor.Velocity = tangent * context.Momentum + stick + Vector3.new(0, verticalSpeed, 0)
		motor.CancelGravity = true
		motor.FaceDirection = tangent
		motor.DesiredSpeed = context.Momentum

		-- A wall-jump is available throughout, and takes priority over everything below -- kicking off
		-- a wall is the whole point of being on one.
		if StateSupport.JumpQueued(context) and StateSupport.JumpIntervalElapsed(context.Now) then
			return "WallJumping"
		end
		-- A ledge appearing during the run is a better outcome than the run expiring: running along a
		-- wall and catching its top edge is one of the chains this system exists to make possible.
		if context.Assists.LedgeAssist and context.Ledge.Found and context.Ledge.HasStandingSpace then
			return "LedgeHanging"
		end
		return nil
	end,

	Exit = function(context: ParkourContext, nextState: ParkourTypes.MovementStateId): ()
		local probe = activeWall(context)
		-- Record the wall and the moment it was left, for rule 1. Recorded on EVERY exit, including
		-- the wall-jump exit, because a wall-jump straight back onto the same surface is the most
		-- common way players attempt the infinite ladder.
		if probe and probe.Instance then
			context.LastWallInstance = probe.Instance
			context.LastWallLeftAt = context.Now
		end
		reattachUntil = context.Now + WALLRUN.ReattachCooldownSeconds
		context.AnimationVariant = nil

		-- WallJumping composes its own departure velocity from the wall normal and needs the state
		-- intact to do it; LedgeHanging takes the body kinematically. Neither wants a hand-off.
		if nextState == "WallJumping" or nextState == "LedgeHanging" then
			return
		end
		local tangent = if probe
			then ParkourMath.WallTangent(probe.Normal, StateSupport.TravelDirection(context))
			else Vector3.zero
		StateSupport.HandOff(context, tangent * context.Momentum + Vector3.new(0, verticalSpeed, 0))
	end,
}

return WallRunning
