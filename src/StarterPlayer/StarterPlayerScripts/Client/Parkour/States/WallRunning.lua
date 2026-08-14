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
-- For the automatic ledge grab in Update below, which must restate LedgeHanging.CanEnter's gates
-- itself -- see that branch's own comment.

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
	-- Read once here rather than inside `evaluate`, which runs twice per call -- and kept as its own
	-- named value because it is a genuinely different vector from `travel` above the moment shift lock
	-- is engaged. See the facing check in evaluate.
	local facing = context.RootPart.CFrame.LookVector

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
		-- The travel check above cannot catch a BACKWARDS wall-run, and no amount of tightening it
		-- would: ParkourMath.WallTangent orients the tangent to agree with travel, so travel-vs-tangent
		-- is small by construction whichever way along the wall the character is moving. All it can
		-- actually refuse is running INTO the wall. Facing is the independent witness -- and under shift
		-- lock (Client/Camera/ShiftLockCamera.lua) it is a genuinely separate vector, since WASD is
		-- camera-relative with AutoRotate off, so holding S past a wall gives the tangent a perfectly
		-- good backward direction to run along while the character looks the other way down it.
		-- Refuses with 180 rather than the measured angle because the number in that slot is the
		-- SELECTION metric (which side to prefer when both qualify), and it is defined as the approach
		-- angle -- returning a facing angle there would put two different measurements in one slot.
		if ParkourMath.ApproachAngle(facing, probe.Tangent) > WALLRUN.MaxFacingAngleDegrees then
			return false, 180, "NotFacingRunDirection"
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

-- The speed band this run is entered into, raised by how many wall-jumps the character has taken since
-- last touching the ground.
--
-- THE RAMP IS THE REWARD HALF OF THE CHAIN. The falloff on the jump itself keeps a chain from being
-- free altitude; without something pulling the other way, that leaves a long chain strictly worse than
-- a short one and the whole line pointless to attempt. So each link makes the NEXT run faster: a
-- five-wall traversal across a courtyard ends visibly quicker than it started, which is what makes
-- committing to the long route worth more than dropping down and sprinting.
--
-- Both ends of the band move together (ChainSpeedBonus added to Speed and to MaxSpeed alike, capped at
-- ChainMaxSpeed). Raising only the ceiling would do nothing at all for a player entering below it,
-- which is most of them -- entry momentum on a mid-chain link comes from the previous jump's arc, not
-- from a sprint -- so the FLOOR is the half that is actually felt.
local function chainSpeedBand(context: ParkourContext): (number, number)
	local bonus = WALLRUN.ChainSpeedBonus * math.max(context.WallJumpChain, 0)
	local floor = math.min(WALLRUN.Speed + bonus, WALLRUN.ChainMaxSpeed)
	local ceiling = math.min(WALLRUN.MaxSpeed + bonus, WALLRUN.ChainMaxSpeed)
	return floor, math.max(ceiling, floor)
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
		-- Asked FIRST, ahead of every geometric check: a refusal the player cannot do anything about
		-- should be the cheapest one and the one the debug overlay reports, rather than being masked by
		-- whichever probe happens to also be unsatisfied this frame.
		if StateSupport.CombatBlocks(context, "WallRunning") then
			return false, "InCombat"
		end
		if context.Ground.Grounded then
			return false, "Grounded"
		end
		if context.Now < reattachUntil then
			return false, "ReattachCooldown"
		end
		if context.WallRunChain >= WALLRUN.MaxChainWithoutGround then
			return false, "WallRunChainExhausted"
		end
		-- The entry-speed requirement exists so a wall-run is earned by a run-up rather than available
		-- from a standstill against a wall. It is waived MID-CHAIN, because arriving off a wall-jump IS a
		-- run-up -- just one whose speed was spent on the flight rather than carried into the contact. An
		-- assisted jump aimed at a near surface legitimately lands slow (the solve gives just enough to
		-- reach, by design), and testing that against a threshold tuned for a sprint is how the fourth
		-- link of a chain refuses for a reason the player cannot see. The entry clamp lifts momentum to
		-- the band floor immediately, so nothing downstream sees the slow arrival; this only stops the
		-- gate from eating the link.
		if context.WallJumpChain <= 0 and context.Momentum < WALLRUN.MinEntrySpeed then
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
			-- run faster than the band's ceiling, and a marginal one is lifted to its floor so the run
			-- always reads as deliberate rather than as a slow scrape along a wall. The band itself widens
			-- with the chain -- see chainSpeedBand.
			local floor, ceiling = chainSpeedBand(context)
			context.Momentum = math.clamp(context.Momentum, floor, ceiling)
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

		-- A GRABBABLE LEDGE IS CHECKED BEFORE THE WALL-JUMP, and the order is the point. It used to be
		-- the other way round, which meant running along a wall toward its top edge and pressing jump
		-- kicked you off the wall and past the lip instead of catching it -- the same "the kick steals
		-- the grab" problem States/WallJumping.CanEnter now guards against, in the one place that guard
		-- cannot reach (this is a route-1 transition; see below).
		--
		-- Reaching a ledge is also strictly the better outcome: a grab ends the run somewhere, where a
		-- kick taken at the top of a wall throws the player back into open air having gained nothing.
		if StateSupport.LedgeGrabAvailable(context, verticalSpeed) then
			return "LedgeHanging"
		end

		-- A wall-jump is available throughout, and takes priority over everything below -- kicking off
		-- a wall is the whole point of being on one.
		--
		-- THE COMBAT GATE IS RESTATED HERE because this is a route-1 transition: StateMachine.Update
		-- applies it without consulting WallJumping.CanEnter, so the gate that file added would simply
		-- not run. Reachable rather than theoretical -- a run legitimately started out of combat and an
		-- exchange begins mid-run, at which point the kick must stop being available like any other
		-- blocked traversal. (The run itself is already ending on its own timer; it is not force-exited
		-- here, because yanking a player off a wall the instant someone swings at them would be a
		-- worse experience than letting the run finish.)
		if
			StateSupport.JumpQueued(context)
			and StateSupport.JumpIntervalElapsed(context.Now)
			and not StateSupport.CombatBlocks(context, "WallJumping")
		then
			return "WallJumping"
		end
		-- The ledge check that used to sit HERE, below the wall-jump, has moved above it -- see its own
		-- note up there for why catching the lip has to beat kicking off it. Its conditions were a
		-- hand-written restatement (route 1 does not consult LedgeHanging.CanEnter) that tested only
		-- Found and HasStandingSpace, silently skipping Allowed, HasHangSpace, the vertical-speed cap
		-- and the facing gate; all of it now comes from StateSupport.LedgeGrabAvailable, which
		-- additionally honors the regrab lockouts this site could never see. See that function's own
		-- header for what the four independent copies of this cascade had drifted into.
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
