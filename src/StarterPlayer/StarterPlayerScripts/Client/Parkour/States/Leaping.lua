--!strict
--[[
	States/Leaping.lua

	Owns: the long, committed jump taken on the dedicated Leap key -- the ground-launched charge-up
	before it, the target it aims at, the solved arc that lands on it, and the brief control lock that
	protects that arc.

	A DEDICATED KEY, NOT A DOUBLE TAP OF JUMP. This used to fire on a double-tap of Space, detected by
	InputBuffer's own timestamp-comparison machinery; it now has its own Types.KeybindAction ("Leap",
	Constants.Keybinds.Defaults.E by default) and its own buffered press (InputBuffer.PeekLeap/
	ConsumeLeap), entirely independent of jump. That is a real behavior change worth naming plainly: a
	leap no longer shares any input state with an ordinary jump, a wall-kick, or anything else that
	reads jump -- pressing Leap never consumes a jump press, and pressing jump never consumes a leap.

	GROUND-LAUNCHED, LIKE AN ORDINARY JUMP. CanEnter refuses mid-air (see its own "GROUNDED TO START"
	note): the charge before the flight holds the character in place, and doing that from a position
	that was already airborne would freeze them hovering there rather than reading as a wind-up.

	WHY THIS IS A SEPARATE MOVE RATHER THAN A STRONGER JUMP. The ordinary jump is tuned against the
	combat layer's own numbers (ParkourConstants.Jump.JumpVelocity matches Roblox's default JumpPower so
	a parkour jump and a stock one reach the same apex, deliberately -- players must never be able to
	tell which code path threw their jump). Making it cover real traversal distance would change every
	fight in the game. Traversal genuinely needs a move that crosses a courtyard, so the two are
	separated by a dedicated key rather than by tuning: jump is the hop combat was balanced around, Leap
	is the traversal move, and neither has to compromise for the other.

	THE ARC IS SOLVED, NOT FIXED. EnvironmentProbe.FindLeapTarget walks outward along the player's own
	view direction and returns the FARTHEST surface the launch caps can actually reach; the launch is
	then computed by ParkourMath.SolveLaunchVelocity to land on it. Farthest rather than nearest is the
	character of the move -- the near ledge was reachable with an ordinary jump, so choosing it would
	make pressing a second key pointless -- and the landing point is pulled in from the surface's near
	edge (Leap.LandingInsetStuds) so the arc ends ON the ledge rather than at its lip.

	The surplus over the exact solution is deliberately tiny here (Leap.ReachMargin, 1.025, against the
	assisted wall-jump's 1.09). The two moves want opposite things from their error: overshooting into a
	wall face is free, where overshooting a LANDING means sailing off the far side of the ledge you were
	aiming at.

	A LEAP WITH NOTHING TO AIM AT IS NEVER A DUD. No target within range -- a leap into open air, off a
	cliff, across a canyon with no far side -- launches at Leap.FallbackPlanarSpeed/FallbackUpSpeed
	instead. The player asked for distance; they get distance, just not aimed at anything in particular.

	WHY AN ACTIVE WALL-KICK ALWAYS WINS, checked in CanEnter's own "A WALL-KICK IN PROGRESS ALWAYS WINS"
	note. Less load-bearing than it used to be -- back when Leap fired on a double-tap of jump, a
	chimney climb's own stream of jump presses could accidentally complete the gesture and fling the
	player out of the corridor, which is what this guard was written for. A dedicated key removes that
	specific collision entirely (mashing Space for kicks can never trigger a key named Leap). It is kept
	anyway as a narrower belt-and-braces: the "GROUNDED TO START" gate mostly covers a kick's own brief
	airborne control lock too, but not with certainty (a weak kick can touch ground within it -- see
	updateDeparting's own grounded-exit check in States/WallRunning.lua), and a deliberate Leap press
	timed into that gap should still not be allowed to hijack a kick mid-flight.

	Does not own: detecting the key press (InputBuffer), finding the target (EnvironmentProbe), or the
	ballistic math (ParkourMath).
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

local EnvironmentProbe = require(script.Parent.Parent.EnvironmentProbe)
local InputBuffer = require(script.Parent.Parent.InputBuffer)
local StateSupport = require(script.Parent.StateSupport)

type ParkourContext = ParkourTypes.ParkourContext

local LEAP = ParkourConstants.Leap

-- The velocity being flown this frame, integrated across the control lock -- the same arrangement
-- States/WallJumping uses, and for the same reason: the LinearVelocity constraint commands all three
-- axes, so gravity has to be integrated here or the character holds a constant vertical speed for the
-- whole lock.
local velocity = Vector3.zero
local cooldownUntil = 0
-- os.clock() of the last leap. Compared against ParkourContext.LastGroundedAt to enforce "one leap per
-- trip through the air" without needing a counter on the context -- see CanEnter.
local lastLeapAt = 0

-- THE CHARGE, before the flight. "Charging" holds the character in place and plays the wind-up for
-- Leap.ChargeSeconds; "Flying" is everything this file always did. A phase change, not a state
-- transition -- StateMachine never sees it, and context.StateElapsed keeps counting from the ORIGINAL
-- double-tap, which is why the flight's own timing (MinFlightSeconds/MaxFlightSeconds) needs its own
-- clock (flightBeganAt) rather than reading StateElapsed once the charge has eaten part of it.
local phase: "Charging" | "Flying" = "Charging"
local flightBeganAt = 0

-- Solves and commits the flight, exactly what this state's own Enter used to do directly before the
-- charge existed. Called once, the moment the charge completes, so the aim is whatever the player is
-- looking at THEN rather than whatever they were looking at on the frame they pressed -- a player who
-- keeps adjusting their look direction through the brief wind-up gets the leap they were aiming at
-- when it fires.
local function commitLeap(context: ParkourContext): ()
	-- The aim is the CAMERA's look direction, pitch included, published on the context by
	-- ParkourController -- see ParkourContext.AimDirection for why the state is handed it rather than
	-- reaching for the camera itself. Falls back to the body's own facing if the controller has not
	-- supplied one (a frame during bind), which is wrong-ish but never degenerate.
	local aim = ParkourMath.SafeUnit(context.AimDirection, context.RootPart.CFrame.LookVector)
	-- The ground instance goes with the aim: the scan needs to know what the player is standing on so
	-- it can refuse to send them to a spot on their own floor unless they are looking straight at it.
	-- See Leap.IgnoreNearRadius.
	local target = EnvironmentProbe.FindLeapTarget(context.RootPart, aim, context.Ground.Instance, context.Now)

	local aimed = false
	if target.Found then
		local solved, reachable = ParkourMath.SolveLaunchVelocity(
			context.RootPart.Position,
			target.LandingPosition,
			Workspace.Gravity,
			LEAP.ApexClearance,
			LEAP.ReachMargin,
			LEAP.MinUpSpeed,
			LEAP.MaxUpSpeed,
			LEAP.MaxPlanarSpeed
		)
		-- The probe already asked for reachability with these same numbers, so this cannot normally
		-- fail; it is re-asked because the character has moved between the scan and here, and flying an
		-- arc the solver disowns is worse than the honest fallback below.
		if reachable then
			velocity = solved
			aimed = true
		end
	end

	if not aimed then
		-- Nothing to aim at, or nothing reachable: a plain long jump along the flattened view
		-- direction. The player asked for distance and gets it -- see this file's header on why a leap
		-- is never allowed to be a dud.
		local flat = ParkourMath.SafeUnit(ParkourMath.Flatten(aim), StateSupport.TravelDirection(context))
		velocity = flat * LEAP.FallbackPlanarSpeed + Vector3.new(0, LEAP.FallbackUpSpeed, 0)
	end

	context.Momentum = ParkourMath.PlanarSpeed(velocity)
	phase = "Flying"
	flightBeganAt = context.Now
	-- Cleared rather than set: nil falls through resolveKey to STATE_CLIPS.Leaping's "Leap" flight
	-- clip without a redundant variant entry naming it -- see ParkourAnimator's own header on this.
	context.AnimationVariant = nil
end

-- One frame of the flight -- everything this state's own Update did before the charge existed. Called
-- both on the frame the charge completes (immediately after commitLeap, so the solved velocity is
-- committed to the motor on the SAME frame it was decided, not the one after -- the hold's own motor
-- command would otherwise still be what gets applied this frame) and on every frame after, for as long
-- as `phase` remains "Flying".
local function updateFlying(context: ParkourContext): ParkourTypes.TransitionResult
	velocity -= Vector3.new(0, Workspace.Gravity * context.DeltaTime, 0)
	context.Momentum = ParkourMath.PlanarSpeed(velocity)

	local motor = context.Motor
	motor.Mode = "Velocity"
	motor.Velocity = velocity
	motor.CancelGravity = true
	motor.FaceDirection = ParkourMath.Flatten(velocity)
	motor.DesiredSpeed = context.Momentum

	-- Measured from the FLIGHT's own start, not context.StateElapsed -- which now also includes the
	-- charge, and would make every timing below fire that much later than it means to. See this file's
	-- header on why the charge needs its own clock.
	local flightElapsed = context.Now - flightBeganAt

	-- ARRIVAL, which is how this state normally ends -- not a clock. See Leap.MaxFlightSeconds for why
	-- the leap owns the whole flight rather than handing control back partway through it. The minimum
	-- guard is the same one the wall-kick uses: on the launch frame the character is often still
	-- touching whatever they left.
	if context.Ground.Grounded and flightElapsed > LEAP.MinFlightSeconds then
		return "Falling"
	end

	-- A leap that falls SHORT of the surface it aimed at can still catch its edge, and that is the most
	-- valuable thing this state can do with a near miss: the difference between an exciting recovery
	-- and a long drop. Asked of the same shared predicate the wall-kick's top-out grab uses -- a
	-- transition returned from a state's own Update is route 1 in StateMachine.Update, which does not
	-- consult the target's CanEnter, so the gates that make an automatic grab something the player
	-- asked for have to be asked here.
	--
	-- Handed this state's OWN integrated vertical speed, not the context's measured one, for the same
	-- reason the wall-kick does: the constraint is being commanded from `velocity` here.
	if StateSupport.LedgeGrabAvailable(context, velocity.Y) then
		return "LedgeHanging"
	end

	-- The backstop, not the exit. A leap that has neither landed nor caught anything after this long has
	-- flown into a case nobody designed for, and holding the body past it would be worse than ending in
	-- mid-air.
	if flightElapsed >= LEAP.MaxFlightSeconds then
		return "Falling"
	end
	return nil
end

local Leaping: ParkourTypes.StateDefinition = {
	Id = "Leaping",
	-- Above WallRunning (160), so an ordinary (non-kicking) wall-run may still be preempted by a double
	-- tap. Hijacking a chimney climb specifically is prevented by CanEnter's own explicit refusal during
	-- an active kick, not by this number -- see the file header.
	Priority = 175,
	Drive = "Velocity",
	-- Ledge, so a leap that arrives at a lip rather than on top of it can still catch (see Update).
	-- Walls, so the wall states can pre-empt out of a leap that ends up alongside one.
	Probes = { Ground = true, Ledge = true, Walls = true },
	Reports = "Leap",
	-- Committed for the length of the lock: the arc is a promise, and letting another state steal the
	-- character mid-flight would be the same as not having solved it.
	Committed = true,

	CanEnter = function(context: ParkourContext): (boolean, string?)
		-- Asked first -- see States/WallRunning.CanEnter's own note on why the combat refusal leads.
		if StateSupport.CombatBlocks(context, "Leaping") then
			return false, "InCombat"
		end
		-- GROUNDED TO START, now that there is a charge to start into. Before the charge existed, a
		-- double tap taken mid-air (off a jump, a hop, a fall) launched immediately -- reasonable, since
		-- there was nothing to wait for. Now that entering this state holds the character in place for
		-- Leap.ChargeSeconds (see the Charging phase in Update), doing that from mid-air would freeze
		-- them hovering wherever they happened to be airborne, which reads as a bug, not a wind-up. A
		-- leap is now a GROUND-launched move, the same way an ordinary jump is: you plant, you commit,
		-- you go.
		if not context.Ground.Grounded then
			return false, "NotGrounded"
		end
		-- The dedicated Leap key's own buffered press -- see InputBuffer.PeekLeap and this file's
		-- header on why this is no longer a double-tap of jump (and therefore no longer reads
		-- StateSupport.JumpQueued/JumpIntervalElapsed at all: pressing Leap is not pressing jump).
		if not InputBuffer.PeekLeap(context.Now) then
			return false, "NoLeapInput"
		end
		if context.Now < cooldownUntil then
			return false, "LeapCooldown"
		end
		-- A WALL-KICK IN PROGRESS ALWAYS WINS -- see this file's header ("WHY AN ACTIVE WALL-KICK ALWAYS
		-- WINS") for the full reasoning and why this is narrower belt-and-braces now rather than the
		-- load-bearing guard it used to be. Checked by AnimationVariant, which only ever reads "Kick*"
		-- during a wall-run's own kick phase (see WallRunning's beginKick), rather than by CurrentStateId
		-- alone -- an ORDINARY, non-kicking wall-run is not and never was protected this way; Leap taken
		-- while simply running along a wall may still fire out of it.
		if
			context.AnimationVariant == "KickLeft"
			or context.AnimationVariant == "KickRight"
			or context.AnimationVariant == "KickNeutral"
		then
			return false, "WallKickInProgress"
		end
		-- ONE LEAP PER TRIP THROUGH THE AIR. Expressed as "the ground has been touched since the last
		-- leap" rather than as a counter, which needs no new context field and is exactly the property
		-- worth enforcing: the cooldown alone would still permit a leap every CooldownSeconds forever,
		-- which is a flight system with extra steps.
		if lastLeapAt > 0 and context.LastGroundedAt <= lastLeapAt then
			return false, "LeapNeedsGround"
		end
		return true, nil
	end,

	Enter = function(context: ParkourContext): ()
		InputBuffer.ConsumeLeap(context.Now)
		lastLeapAt = context.Now
		phase = "Charging"
		context.AnimationVariant = "Charge"
		-- Held at zero for the charge's own duration -- see the Charging branch in Update. Set here too
		-- so anything reading Momentum this same frame (the camera speed feed, the run presentation)
		-- sees the hold immediately rather than one frame stale.
		context.Momentum = 0
		velocity = Vector3.zero
	end,

	Update = function(context: ParkourContext): ParkourTypes.TransitionResult
		if phase == "Charging" then
			-- Held in place, not merely un-moved: CancelGravity keeps the wind-up from also being a
			-- brief, unintended hang-time drop, which would read as the charge doing two things at once.
			local motor = context.Motor
			motor.Mode = "Velocity"
			motor.Velocity = Vector3.zero
			motor.CancelGravity = true
			motor.FaceDirection = ParkourMath.Flatten(context.RootPart.CFrame.LookVector)
			motor.DesiredSpeed = 0
			if context.StateElapsed >= LEAP.ChargeSeconds then
				commitLeap(context)
				return updateFlying(context)
			end
			return nil
		end
		return updateFlying(context)
	end,

	Exit = function(context: ParkourContext): ()
		cooldownUntil = context.Now + LEAP.CooldownSeconds
		context.AnimationVariant = nil
		StateSupport.HandOff(context, velocity)
	end,
}

return Leaping
