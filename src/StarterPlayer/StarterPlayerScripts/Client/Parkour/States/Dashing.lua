--!strict
--[[
	States/Dashing.lua

	Owns: the dash -- an AIR-ONLY, camera-aimed, steerable launch on its own key, and the move this
	framework's chains are meant to be reached with. ONE RULE: it sends you exactly where you are
	looking, at full power, and you fly it with the mouse for as long as it lasts.

	WHAT THIS REPLACED, because all three of the old decisions were structural rather than tuning, and
	each was a separate reason the dash read as rigid:
	  1. It QUANTIZED to five directions off the BODY's facing (a four-way move-intent quadrant plus a
	     camera-aimed "Up" that only unlocked above a 55-degree pitch gate). Whatever angle the player
	     was actually looking at was thrown away. Now context.AimDirection IS the launch vector, at
	     every angle, with no gate and no quadrant -- under shift lock, literally the crosshair.
	  2. NOTHING ABOUT IT WAS STEERABLE. Travel and facing were both frozen at Enter and commanded
	     unchanged for the whole burst, so there was no input path into a running dash at all.
	  3. DIRECTION CHANGED THE POWER -- five distances, five durations, five cooldowns, five momentum
	     penalties -- so three of the five directions were deliberately weak. There is one power
	     budget now, and the extra reach comes from Dash.CruiseSeconds rather than a bigger speed.

	WHY THIS IS NOT A SECOND ROLL. States/Rolling.lua already exists and is already a committed
	grounded burst, so the split of labour has to be real or one of the two is dead weight:
	  * ROLL is the DODGE. Committed = true, so nothing can steal it -- that reliability is most of its
	    defensive value -- and it owns the landing-roll conversion.
	  * DASH is the CHAIN. It works in the air, it is deliberately NOT committed, and being pre-empted
	    is the mechanic rather than a failure of one.
	Read those two sentences together and every decision below follows from them.

	PRIORITY 130, AND WHY THE NUMBER IS LOAD-BEARING. It sits in the gap between Sliding (120) and
	Rolling (140), and both bounds are chosen rather than convenient:
	  * LOWER BOUND -- route-2 pre-emption requires the incoming state to STRICTLY outrank the active
	    one, so 130 has to clear the highest id in Dash.AllowedFromStates: Jumping (70), the highest of
	    the airborne states Dash may be entered from now that it is AIR-ONLY (grounded states were
	    removed from that roster entirely -- see its own comment). The 120/140 gap is wider than that
	    bound strictly requires; it is kept for the UPPER BOUND below, which is the tight one.
	  * UPPER BOUND -- everything above 130 that could steal a dash is either a chain we WANT or inert:
	    Mantling (145), Vaulting (150), WallRunning (160) and LedgeHanging (210) each pre-empt a running
	    dash the instant their own CanEnter agrees. That is how "dash into a vault", "dash off a ledge
	    into a wall-run" and "air-dash onto a lip" work here -- through the machine's own arbitration,
	    with every one of those states' gates (cooldowns, assists, chain limits, and critically their
	    FACING checks) fully consulted. Rolling (140) is inert because Roll.AllowedFromStates has no
	    Dashing entry; LedgeLeaping (176) refuses unconditionally; AerialCombat (1000) must win.

	    Those facing checks are why LIVE facing (below) is a strict improvement for this list rather
	    than a cosmetic change: the body now points wherever the dash is actually going, so a dash
	    steered into a vaultable lip presents that lip the facing it is gated on.

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
	  1. A SPRING, not a curve. Commanded speed is driven toward Dash.LaunchSpeed by
	     FlightMath.SpringStep with a damping ratio below 1, so it winds up over a few frames and
	     overshoots slightly before settling -- and per that function's own header, THE OVERSHOOT IS
	     THE MASS. The old dash stamped its peak on frame one and decayed linearly from it; a stamp
	     has no mass, which is most of why it read as a nudge rather than a launch. There is no phase
	     enum here because there does not need to be: past Dash.CruiseSeconds the same spring's target
	     drops to the exit speed and the same spring bleeds it off. One mechanism, two targets.
	  2. A CAPPED TURN RATE, which is the whole of "drivable". Travel rotates toward the LIVE aim by
	     at most Dash.TurnDegreesPerSecond each frame (ParkourMath.SteerToward), so the player BANKS a
	     dash rather than pivoting it. Authority tapers linearly to zero over the final
	     Dash.SteerReleaseSeconds so the exit heading is committed and predictable -- see that
	     constant for why the last frame is the worst possible one to inherit an exit vector from.
	  3. An AIR HANG. Vertical velocity is pinned at zero for Dash.AirHangSeconds before gravity
	     resumes FROM zero, so a dash reads as a clean launch and CANCELS an ongoing fall. One
	     learnable rule instead of a velocity-dependent one.

	FACING FOLLOWS TRAVEL, and this is the one behaviour that inverts outright. It used to be frozen
	at entry so a back-dash slid backward with the chest still forward -- which only made sense while
	there WAS a back-dash. There is no such thing now: the dash goes where you look, so the body
	pointing where it is going is both the honest read and, under shift lock, the one that keeps body
	and camera from decoupling for the flight's duration. Commanded from the FLATTENED live travel
	vector; ParkourMotor.applyFacing flattens again and early-returns below 1e-3, which is what makes
	a straight-up or straight-down dash hold its last real yaw instead of snapping to an arbitrary one.

	Runs in Velocity drive mode: it commands its own speed on all three axes. Humanoid drive cannot
	express a spring-driven burst at all (MotorCommand.DesiredSpeed is informational -- see its own
	header), and Kinematic would drive the body THROUGH geometry a dash should be stopped by.
]]

-- Workspace is imported for Gravity ONLY -- the airborne phase integrates its own vertical velocity
-- (see Update), the same arrangement States/Leaping.lua's flight uses and for the same reason: the
-- velocity constraint commands all three axes at full force, so real gravity would simply fight it.
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FlightMath = require(ReplicatedStorage.Shared.FlightMath)
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
--
-- THE LIVE travel direction -- rewritten every frame by the steer, not frozen at Enter. Full 3D: the
-- launch aim is used unflattened, so pitch is carried into the velocity rather than discarded.
local travelDirection = Vector3.zero
-- The spring's state. `speed` starts at the momentum the player ARRIVED with rather than at zero, so
-- a dash out of a fast fall winds up shorter than one from a standstill -- that is a feature, not an
-- oversight: the dash adds to what you were already doing. `speedVelocity` is the spring's own rate,
-- which SpringStep both consumes and returns; it must persist across frames or the spring is just an
-- ease with extra arithmetic and never overshoots at all.
local speed = 0
local speedVelocity = 0
-- Solved once at Enter, commanded as the spring's target past CruiseSeconds, and handed to the next
-- state in Exit. Solved BEFORE Momentum is overwritten, because it reads the entry momentum.
local exitSpeed = 0
-- Integrated vertical velocity for the airborne phase, the moment the hang gives way to gravity, the
-- value gravity resumes FROM when it does, and whether that release has already happened. Four locals
-- rather than two because the hang overwrites the live velocity with zero by definition, so the value
-- to resume from cannot also live in it.
local verticalVelocity = 0
local hangUntil = 0
local resumeVerticalVelocity = 0
local hangReleased = false
local cooldownUntil = 0

-- Sorts the launch angle into the three animation bands. ANIMATION ONLY -- nothing about where the
-- dash actually goes is gated on pitch any more (see Dash.AnimationPitchDegrees), which is exactly
-- the gate this rewrite removed. Called once, in Enter, off the LAUNCH aim: steering deliberately
-- does not re-trigger the clip mid-flight.
local function pitchBand(direction: Vector3): string
	local pitchDegrees = math.deg(math.asin(math.clamp(direction.Y, -1, 1)))
	if pitchDegrees >= DASH.AnimationPitchDegrees then
		return "Up"
	end
	if pitchDegrees <= -DASH.AnimationPitchDegrees then
		return "Down"
	end
	return "Level"
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
		-- One cooldown now, where this used to index a per-direction tuning row. The direction is not
		-- even resolved until Enter, and could not be: it depends on where the camera is pointed at
		-- the moment of the press, not on which of five buckets the movement keys fell into.
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

		-- THE WHOLE DIRECTION RULE, in one line. The camera's own look vector, pitch included and
		-- deliberately UNFLATTENED -- looking up 40 degrees and slightly left launches you up 40
		-- degrees and slightly left. context.MoveIntent is not read at all any more, and the body's
		-- facing enters only as the fallback for a frame with no camera vector to read (during bind),
		-- where holding the current heading is the least surprising thing to do.
		--
		-- Used unconditionally: CanEnter already refused this call entirely if the player was grounded
		-- (see its own comment), so there is no "was looking up while standing on something" case left
		-- to guard against here.
		travelDirection = ParkourMath.SafeUnit(context.AimDirection, context.RootPart.CFrame.LookVector)

		cooldownUntil = context.Now + DASH.CooldownSeconds
		context.AirDashChain += 1

		-- Solved before Momentum is overwritten below, because the first term reads the entry value.
		-- The GREATER of three floors, never a fraction of what the player arrived with: the old dash
		-- charged three of its five directions a momentum penalty on exit, which made them strictly
		-- worse ways to travel. A chaining move that costs speed makes never dashing the optimal play,
		-- so this can only ever hold or raise it.
		exitSpeed = math.max(context.Momentum, DASH.LaunchSpeed * DASH.ExitRetainFraction, DASH.MinExitSpeed)

		-- The spring opens from what the player arrived with and winds up from there -- see the
		-- declaration above for why that is deliberate rather than a missing reset.
		speed = context.Momentum
		speedVelocity = 0
		-- Published before the controller's Start report reads it, so the speed claimed to the server
		-- is the PEAK this dash is about to command rather than the one being left behind. The exit
		-- speed is not what is claimed here; the launch is, because that is what the validator will
		-- see mid-flight.
		context.Momentum = DASH.LaunchSpeed

		verticalVelocity = 0
		hangReleased = false
		-- What gravity picks up from once the hang releases. Zero by default, which is the rule that
		-- makes an air dash CANCEL a fall -- see Dash.AirVerticalResetsFall for why restoring the entry
		-- value snaps visibly in both directions.
		resumeVerticalVelocity = if DASH.AirVerticalResetsFall then 0 else context.VerticalVelocity
		local hangSeconds = DASH.AirHangSeconds
		-- THE WALL-LAUNCH CHAIN BOOST. context.WallLaunchDashBoostUntil is a deadline
		-- States/WallLaunching.lua's own Enter sets and this reads (never writes) -- see that file's
		-- header for the whole combo. Extra HANG rather than extra speed: a chained dash commands
		-- LaunchSpeed like any other, so more speed would be silently absorbed by the MaxSpeed clamp;
		-- more TIME before gravity returns cannot be.
		--
		-- Granted to ANY dash chained inside the window now, not only an upward one. The old code
		-- restricted it to the "Up" quadrant because that quadrant was the only way to aim a dash
		-- skyward at all; with the aim itself deciding, keeping the restriction would just be an
		-- invisible pitch gate on a reward the player already earned by launching off the wall.
		if context.Now < context.WallLaunchDashBoostUntil then
			hangSeconds += DASH.WallLaunchChainExtraHangSeconds
		end
		hangUntil = context.Now + hangSeconds

		-- Resolved once, off the LAUNCH angle, before any frame can reach ParkourAnimator's resolver.
		-- Steering does not re-publish it: one clip per dash, not a cut mid-flight.
		context.AnimationVariant = pitchBand(travelDirection)
		-- Same landing rescue States/Rolling.lua performs on entry, for the same reason: a dash taken
		-- at the moment of contact should not also pay the fall's momentum cost, and clearing
		-- FallHeight alongside it keeps the camera dip from firing for a landing that was cancelled.
		context.LandingSeverity = nil
		context.FallHeight = 0
	end,

	Update = function(context: ParkourContext): ParkourTypes.TransitionResult
		-- 1. THE STEER. Authority is full for most of the flight and tapers linearly to exactly zero
		-- across the last Dash.SteerReleaseSeconds, so the dash commits to a heading before it hands
		-- off. SteerToward answers a non-positive budget by holding the current direction, so the
		-- taper is allowed to reach zero with no special case here.
		local remaining = DASH.DurationSeconds - context.StateElapsed
		local steerAuthority = math.clamp(remaining / DASH.SteerReleaseSeconds, 0, 1)
		travelDirection = ParkourMath.SteerToward(
			travelDirection,
			-- Falls back to the CURRENT travel rather than to facing: a frame with no camera vector
			-- should hold the angle the dash is already flying, not bend it toward the body.
			ParkourMath.SafeUnit(context.AimDirection, travelDirection),
			math.rad(DASH.TurnDegreesPerSecond) * steerAuthority * context.DeltaTime
		)

		-- 2. THE SPRING. One mechanism for both halves of the flight -- the target is the only thing
		-- that changes at CruiseSeconds, so the launch and the settle share an integrator and there
		-- is no discontinuity between them to hide.
		local target = if context.StateElapsed < DASH.CruiseSeconds then DASH.LaunchSpeed else exitSpeed
		speed, speedVelocity = FlightMath.SpringStep(
			speed,
			speedVelocity,
			target,
			DASH.LaunchFrequency,
			DASH.LaunchDamping,
			context.DeltaTime
		)
		-- Clamped on the way into Momentum, not into `speed` itself: clamping the spring's own state
		-- would feed the ceiling back into the integrator and quietly change the curve's shape. This
		-- way the overshoot stays real in the arithmetic and only the COMMANDED value is bounded --
		-- which is what keeps the claim this state reports under Validation.MaxReportedSpeed.
		context.Momentum = math.clamp(speed, 0, DASH.MaxSpeed)

		local motor = context.Motor
		motor.Mode = "Velocity"
		-- LIVE travel, flattened -- the body points where it is flying. See the header for why this
		-- inverted, and why ParkourMotor.applyFacing's own near-zero early-return is what makes a
		-- straight-up or straight-down dash hold its yaw rather than snap.
		motor.FaceDirection = ParkourMath.Flatten(travelDirection)
		motor.HipHeightDelta = 0
		motor.DesiredSpeed = context.Momentum

		if context.Ground.Grounded and travelDirection.Y <= 0 then
			-- Every dash STARTS airborne (CanEnter's gate), but one aimed level or downward can easily
			-- LAND before its own duration elapses -- this is that case, not the grounded-entry one.
			-- Projected onto the surface so the tail of the dash follows terrain rather than launching
			-- off the crest of a ramp -- the same line, and the same reason, as Rolling's and Sliding's.
			--
			-- The Y test is what generalizes the old `quadrant ~= "Up"` guard to a continuous aim. A
			-- RISING dash keeps the 3D integration below for its whole duration even on a frame the
			-- ground probe still reports contact, because projecting a mostly-vertical travel vector
			-- onto the ground plane would flatten it to nearly nothing and kill the launch outright.
			local travel = ParkourMath.SafeUnit(
				ParkourMath.ProjectOnPlane(travelDirection, context.Ground.Normal),
				travelDirection
			)
			motor.Velocity = travel * context.Momentum - Vector3.new(0, DASH.SurfaceStickSpeed, 0)
			motor.CancelGravity = false
		else
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

		if context.StateElapsed < DASH.DurationSeconds then
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
		-- The spring's own terminal target, which the tail of the flight has already driven the body
		-- to -- so the hand-off has no discontinuity in it. Read rather than recomputed: it was solved
		-- against the ENTRY momentum, which Enter overwrote seconds ago.
		context.Momentum = exitSpeed
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
