--!strict
--[[
	States/Dashing.lua

	Owns: the dash -- a short, weighted, facing-relative burst on its own key, AIR-ONLY (CanEnter refuses
	outright while grounded -- see its own comment for why), and the move this framework's chains are
	meant to be reached with. Four directions are resolved off the body's own facing; a fifth, UP, is
	resolved off the CAMERA instead and replaces Front while the player is looking steeply up
	(ParkourMath.DashQuadrant / Dash.UpPitchDegrees) -- see that function's own header for why it is
	Front specifically that this replaces.

	WHY THIS IS NOT A SECOND ROLL. States/Rolling.lua already exists and is already a committed grounded
	burst, so the split of labour has to be real or one of the two is dead weight:
	  * ROLL is the DODGE. Committed = true, so nothing can steal it -- that reliability is most of its
	    defensive value -- and it owns the landing-roll conversion.
	  * DASH is the CHAIN. It works in the air, it is deliberately NOT committed, and being pre-empted
	    is the mechanic rather than a failure of one.
	Read those two sentences together and every decision below follows from them.

	PRIORITY 130, AND WHY THE NUMBER IS LOAD-BEARING. It sits in the gap between Sliding (120) and
	Rolling (140), and both bounds are chosen rather than convenient:
	  * LOWER BOUND -- route-2 pre-emption requires the incoming state to STRICTLY outrank the active
	    one, so 130 has to clear the highest id in Dash.AllowedFromStates: Jumping (70), the highest of
	    the two airborne states Dash may be entered from now that it is AIR-ONLY (grounded states were
	    removed from that roster entirely -- see its own comment). The 120/140 gap is wider than that
	    bound strictly requires; it is kept for the UPPER BOUND below, which is the tight one.
	  * UPPER BOUND -- everything above 130 that could steal a dash is either a chain we WANT or inert:
	    Mantling (145), Vaulting (150), WallRunning (160) and LedgeHanging (210) each pre-empt a running
	    dash the instant their own CanEnter agrees. That is how "dash into a vault", "dash off a ledge
	    into a wall-run" and "air-dash onto a lip" work here -- through the machine's own arbitration,
	    with every one of those states' gates (cooldowns, assists, chain limits, and critically their
	    FACING checks) fully consulted. Rolling (140) is inert because Roll.AllowedFromStates has no
	    Dashing entry; LedgeLeaping (176) refuses unconditionally; AerialCombat (1000) must win.

	WHICH IS WHY UPDATE RETURNS ALMOST NOTHING. There is no route-1 transition to Vaulting, Mantling,
	WallRunning or LedgeHanging in this file, on purpose. A transition returned from Update is applied
	WITHOUT consulting the target's CanEnter (StateMachine.lua -- the caller is asserting, not asking),
	and this codebase has already paid for that once: see StateSupport.LedgeGrabAvailable's header for
	the three-way disagreement that produced. Letting route 2 do the work instead is the entire payoff
	for the priority choice above, and it costs this file nothing.

	The one route-1 chain that IS here -- dash into a slide -- is genuinely route-1, because it is
	triggered by a key still being HELD at the dash's end rather than by geometry appearing. Its two
	skipped gates (grounded, and the combat gate) are re-asked inline, exactly as States/Sliding.lua's
	own hand-off into Rolling re-asks that state's.

	THE WEIGHTED FEEL, in three parts:
	  1. A decaying speed curve (ParkourMath.BurstPeak/BurstSpeed) rather than a flat speed. It opens
	     fast and settles to exactly the speed the body is handed off at, so the burst has a shape and
	     the hand-off has no discontinuity. See that function's own header for why the peak is what it
	     is, and for the silent half-distance failure the spec integrates the curve to catch.
	  2. An AIR HANG. An airborne dash pins vertical velocity at zero for Dash.AirHangSeconds before
	     gravity resumes from zero, so an air dash reads as a horizontal snap and cancels an ongoing
	     fall. One learnable rule instead of a velocity-dependent one.
	  3. FACING IS FROZEN AT ENTRY and commanded every frame, so a back-dash slides backward with the
	     body still pointed forward instead of spinning on the spot. Two consequences worth knowing:
	     the character will not follow the camera for the dash's 0.2-0.26s under shift lock (the
	     Velocity drive raises ParkourFacingOwned regardless of what this file writes -- see
	     ParkourMotor.Apply), and a back-dash into geometry BEHIND the player never vaults or grabs,
	     because Vaulting/Mantling/LedgeGrabAvailable all gate on facing as well as on travel.

	Runs in Velocity drive mode: it commands its own speed on all three axes. Humanoid drive cannot
	express a decaying burst at all (MotorCommand.DesiredSpeed is informational -- see its own header),
	and Kinematic would drive the body THROUGH geometry a dash should be stopped by.
]]

-- Workspace is imported for Gravity ONLY -- the airborne phase integrates its own vertical velocity
-- (see Update), the same arrangement States/Leaping.lua's flight uses and for the same reason: the
-- velocity constraint commands all three axes at full force, so real gravity would simply fight it.
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

local InputBuffer = require(script.Parent.Parent.InputBuffer)
local StateSupport = require(script.Parent.StateSupport)

type ParkourContext = ParkourTypes.ParkourContext

local DASH = ParkourConstants.Dash

-- Per-dash scratch. Module-level rather than context fields for the same reason Rolling's and
-- Sliding's are: nothing outside this file has any business reading them, and there is exactly one
-- local player.
local quadrant: ParkourMath.DashQuadrant = "Front"
local travelDirection = Vector3.zero
-- The facing frozen at Enter, commanded every frame. NEVER travelDirection -- see the header.
local entryFacing = Vector3.zero
-- The curve, solved once at Enter and sampled per frame. Re-solving against a live momentum this very
-- curve is driving would be a feedback loop.
local peakSpeed = 0
local endSpeed = 0
-- Integrated vertical velocity for the airborne phase, the moment the hang gives way to gravity, the
-- value gravity resumes FROM when it does, and whether that release has already happened. Four locals
-- rather than two because the hang overwrites the live velocity with zero by definition, so the value
-- to resume from cannot also live in it.
local verticalVelocity = 0
local hangUntil = 0
local resumeVerticalVelocity = 0
local hangReleased = false
local cooldownUntil = 0

-- The direction's own tuning row. A function rather than a field read at each site so the union-typed
-- index happens in exactly one place under --!strict.
local function tuningFor(direction: ParkourMath.DashQuadrant)
	return DASH.Directions[direction]
end

local Dashing: ParkourTypes.StateDefinition = {
	Id = "Dashing",
	Priority = 130,
	Drive = "Velocity",
	-- The same probe set States/Falling.lua requests, and for the same reason: this is the state with
	-- the most possible exits, and every one of the pre-emptions listed in the header reads a probe
	-- that has to be fresh on the frame the opportunity appears. Ceiling is deliberately absent -- a
	-- dash does not crouch (HipHeightDelta stays 0), so there is no stand-up-into-geometry case.
	Probes = { Ground = true, Obstacle = true, Walls = true, Ledge = true },
	Reports = "Dash",
	-- NOT Committed, unlike Rolling -- the one structural difference between the two states, and the
	-- thing that makes the chains in the header possible at all. See that discussion; the residual
	-- risk (being stolen on frame one) is only reachable when the geometry was already in traversal
	-- range at the moment of the press, where converting to the traversal is the correct outcome.

	CanEnter = function(context: ParkourContext): (boolean, string?)
		-- Asked first, the house rule States/WallRunning.CanEnter documents. "Dashing" is deliberately
		-- NOT in ParkourConstants.CombatGate.BlockedStates today -- Rolling already is, and blocking
		-- both would leave a fighting player with no evasive movement at all -- but the question is
		-- asked anyway so that roster stays a pure data change.
		if StateSupport.CombatBlocks(context, "Dashing") then
			return false, "InCombat"
		end
		if context.Now < cooldownUntil then
			return false, "DashCooldown"
		end
		-- PEEK, never Consume. ParkourDebug calls CanEnter on every registered state on a timer, so a
		-- consuming predicate would silently eat the player's inputs the whole time the overlay is
		-- open -- see InputBuffer.lua's own Peek/Consume contract.
		if not InputBuffer.PeekDash(context.Now) then
			return false, "NoDashInput"
		end
		local allowed = (DASH.AllowedFromStates :: { [string]: boolean })[context.CurrentStateId]
		if not allowed then
			return false, "NotAllowedFromThisState"
		end
		-- AIR-ONLY. A grounded player has a floor under them; a burst that shoves them along it fights
		-- the surface the whole way (the SurfaceStickSpeed bias in Update exists for a dash that LANDS
		-- mid-flight, not for one that starts already standing on something) and reads as being dragged
		-- rather than dashed. Dash is the framework's AIRBORNE chaining move -- Rolling already owns the
		-- grounded dodge/reposition job (see the file header) -- so this refuses unconditionally rather
		-- than trying to make the grounded case feel good.
		if context.Ground.Grounded then
			return false, "MustBeAirborne"
		end
		-- The air budget: capped per trip through the air, refunded on ground contact (see
		-- ParkourTypes.ParkourContext.AirDashChain).
		if context.AirDashChain >= DASH.AirCharges then
			return false, "AirDashesExhausted"
		end
		return true, nil
	end,

	Enter = function(context: ParkourContext): ()
		InputBuffer.ConsumeDash(context.Now)

		local rootCFrame = context.RootPart.CFrame
		entryFacing = ParkourMath.SafeUnit(ParkourMath.Flatten(rootCFrame.LookVector), Vector3.new(0, 0, -1))
		local entryRight = ParkourMath.SafeUnit(ParkourMath.Flatten(rootCFrame.RightVector), Vector3.new(1, 0, 0))

		-- context.AimDirection is used unconditionally: CanEnter already refused this call entirely if
		-- the player was grounded (see its own comment), so by the time Enter runs there is no "was
		-- looking up while standing on something" case left to guard against here.
		quadrant = ParkourMath.DashQuadrant(
			context.MoveIntent,
			entryFacing,
			entryRight,
			context.AimDirection,
			DASH.UpPitchDegrees
		)
		travelDirection = ParkourMath.QuadrantDirection(quadrant, entryFacing, entryRight, context.AimDirection)
		local tuning = tuningFor(quadrant)

		cooldownUntil = context.Now + tuning.CooldownSeconds
		context.AirDashChain += 1

		-- Solved before Momentum is overwritten below: the exit speed is a fraction of what the player
		-- ARRIVED with, floored so a dash from a standstill still leaves them moving. A front dash
		-- retains all of it (fraction 1) -- a chaining move that costs speed would make never dashing
		-- the optimal play.
		endSpeed = math.max(context.Momentum * tuning.ExitRetainFraction, DASH.MinExitSpeed)
		peakSpeed = ParkourMath.BurstPeak(tuning.DistanceStuds, tuning.DurationSeconds, endSpeed, DASH.MaxSpeed)
		-- Published before the controller's Start report reads it, so the speed claimed to the server
		-- is the speed actually about to be commanded rather than the one being left behind.
		context.Momentum = peakSpeed

		verticalVelocity = 0
		hangReleased = false
		-- What gravity picks up from once the hang releases. Zero by default, which is the rule that
		-- makes an air dash CANCEL a fall -- see Dash.AirVerticalResetsFall for why restoring the entry
		-- value snaps visibly in both directions.
		resumeVerticalVelocity = if DASH.AirVerticalResetsFall then 0 else context.VerticalVelocity
		-- UP gets its OWN, longer hang (Dash.UpAirHangSeconds) rather than sharing AirHangSeconds: a
		-- launch that starts falling again the instant the burst ends reads as weak no matter how fast
		-- the burst was, and widening the shared constant would soften every OTHER direction's air dash
		-- along with it.
		local hangSeconds = if quadrant == "Up" then DASH.UpAirHangSeconds else DASH.AirHangSeconds
		-- THE WALL-LAUNCH CHAIN BOOST. context.WallLaunchDashBoostUntil is a deadline
		-- States/WallLaunching.lua's own Enter sets and this reads (never writes) -- see that file's
		-- header for the whole combo. Extra HANG rather than extra speed: a dash chained this soon
		-- off a wall launch carries very little entry momentum, so BurstPeak's own distance-driven
		-- peak is nowhere near Dash.MaxSpeed's ceiling here -- more time at the peak is the lever that
		-- cannot be silently absorbed by a clamp elsewhere.
		if quadrant == "Up" and context.Now < context.WallLaunchDashBoostUntil then
			hangSeconds += DASH.WallLaunchChainExtraHangSeconds
		end
		hangUntil = context.Now + hangSeconds

		-- The quadrant IS the animation variant -- ParkourAnimator's VARIANT_CLIPS keys on exactly
		-- these five strings.
		context.AnimationVariant = quadrant
		-- Same landing rescue States/Rolling.lua performs on entry, for the same reason: a dash taken
		-- at the moment of contact should not also pay the fall's momentum cost, and clearing
		-- FallHeight alongside it keeps the camera dip from firing for a landing that was cancelled.
		context.LandingSeverity = nil
		context.FallHeight = 0
	end,

	Update = function(context: ParkourContext): ParkourTypes.TransitionResult
		local tuning = tuningFor(quadrant)
		context.Momentum = ParkourMath.BurstSpeed(peakSpeed, endSpeed, tuning.DurationSeconds, context.StateElapsed)

		local motor = context.Motor
		motor.Mode = "Velocity"
		-- Frozen entry facing, every frame and in every direction -- see the header on the back-dash.
		motor.FaceDirection = entryFacing
		motor.HipHeightDelta = 0
		motor.DesiredSpeed = context.Momentum

		if context.Ground.Grounded and quadrant ~= "Up" then
			-- Every dash STARTS airborne (CanEnter's gate), but a short one can easily LAND before its
			-- own duration elapses -- this is that case, not the grounded-entry one. Projected onto the
			-- surface so the tail of the dash follows terrain rather than launching off the crest of a
			-- ramp -- the same line, and the same reason, as Rolling's and Sliding's.
			local travel = ParkourMath.SafeUnit(
				ParkourMath.ProjectOnPlane(travelDirection, context.Ground.Normal),
				travelDirection
			)
			motor.Velocity = travel * context.Momentum - Vector3.new(0, DASH.SurfaceStickSpeed, 0)
			motor.CancelGravity = false
		else
			-- UP always lands here even on a frame the ground probe reports Grounded again mid-burst
			-- (landing back on a rooftop at the end of a short vertical hop, say): projecting a mostly-
			-- vertical travelDirection onto the ground plane would flatten it to nearly nothing, so it
			-- keeps the vertical integration for its whole duration rather than switching branches
			-- mid-flight.
			if context.Now < hangUntil then
				verticalVelocity = 0
			else
				if not hangReleased then
					hangReleased = true
					verticalVelocity = resumeVerticalVelocity
				end
				verticalVelocity -= Workspace.Gravity * context.DeltaTime
			end
			motor.Velocity = travelDirection * context.Momentum + Vector3.new(0, verticalVelocity, 0)
			motor.CancelGravity = true
		end

		if context.StateElapsed < tuning.DurationSeconds then
			return nil
		end
		if not context.Ground.Grounded then
			return "Falling"
		end
		-- THE ONE ROUTE-1 CHAIN, and the two gates Sliding.CanEnter would have asked that this cannot
		-- skip: grounded (established immediately above) and the combat gate. See the file header.
		if InputBuffer.IsSlideHeld() and not StateSupport.CombatBlocks(context, "Sliding") then
			return "Sliding"
		end
		return StateSupport.ResolveGroundedState(context)
	end,

	Exit = function(context: ParkourContext, nextState: ParkourTypes.MovementStateId): ()
		-- The curve's own terminal value, which the last commanded frame already drove the body to.
		context.Momentum = endSpeed
		context.AnimationVariant = nil
		verticalVelocity = 0

		-- Any state that will own the body itself gets the LIVE assembly velocity, so this frame's
		-- committed command is near-neutral rather than a dash velocity stamped over the first frame
		-- of a traversal. See States/Sliding.lua's own Exit for the full account of that bug class --
		-- the field that actually matters is Mode, and HandOff is the only thing that resets it.
		if
			nextState == "Vaulting"
			or nextState == "Mantling"
			or nextState == "Sliding"
			or nextState == "WallRunning"
			or nextState == "LedgeHanging"
			or nextState == "Leaping"
		then
			StateSupport.HandOff(context, context.RootPart.AssemblyLinearVelocity)
			return
		end
		local travel = ParkourMath.SafeUnit(ParkourMath.Flatten(travelDirection), Vector3.zero)
		StateSupport.HandOff(
			context,
			travel * context.Momentum + Vector3.new(0, context.RootPart.AssemblyLinearVelocity.Y, 0)
		)
	end,
}

return Dashing
