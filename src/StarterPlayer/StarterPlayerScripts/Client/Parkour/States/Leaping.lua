--!strict
--[[
	States/Leaping.lua

	Owns: the long, committed jump taken on a DOUBLE TAP of jump -- the target it aims at, the solved
	arc that lands on it, and the brief control lock that protects that arc.

	WHY THIS IS A SEPARATE MOVE RATHER THAN A STRONGER JUMP. The ordinary jump is tuned against the
	combat layer's own numbers (ParkourConstants.Jump.JumpVelocity matches Roblox's default JumpPower so
	a parkour jump and a stock one reach the same apex, deliberately -- players must never be able to
	tell which code path threw their jump). Making it cover real traversal distance would change every
	fight in the game. Traversal genuinely needs a move that crosses a courtyard, so the two are
	separated by INPUT instead of by tuning: one tap is the jump combat was balanced around, two taps is
	the traversal move, and neither has to compromise for the other.

	THE ARC IS SOLVED, NOT FIXED. EnvironmentProbe.FindLeapTarget walks outward along the player's own
	view direction and returns the FARTHEST surface the launch caps can actually reach; the launch is
	then computed by ParkourMath.SolveLaunchVelocity to land on it. Farthest rather than nearest is the
	character of the move -- the near ledge was reachable with an ordinary jump, so choosing it would
	make the double tap pointless -- and the landing point is pulled in from the surface's near edge
	(Leap.LandingInsetStuds) so the arc ends ON the ledge rather than at its lip.

	The surplus over the exact solution is deliberately tiny here (Leap.ReachMargin, 1.025, against the
	assisted wall-jump's 1.09). The two moves want opposite things from their error: overshooting into a
	wall face is free, where overshooting a LANDING means sailing off the far side of the ledge you were
	aiming at.

	A LEAP WITH NOTHING TO AIM AT IS NEVER A DUD. No target within range -- a leap into open air, off a
	cliff, across a canyon with no far side -- launches at Leap.FallbackPlanarSpeed/FallbackUpSpeed
	instead. The player asked for distance; they get distance, just not aimed at anything in particular.

	WHY IT SITS BELOW WallJumping ON PRIORITY (175 against 180), which is the one arbitration decision in
	this file that matters: climbing a shaft is a stream of jump presses, and every one of them lands
	inside the double-tap window. If a leap outranked a wall-jump, the chimney climb would fling the
	player out of the corridor on the second press. A wall to kick therefore always wins, and the leap
	fires when there is nothing to kick -- which is exactly when a player asking for distance means it.
	(InputBuffer.ConsumeJump spending the double tap alongside the press is the other half of that same
	protection; see its own header.)

	Does not own: detecting the double tap (InputBuffer), finding the target (EnvironmentProbe), or the
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

local Leaping: ParkourTypes.StateDefinition = {
	Id = "Leaping",
	-- Below WallJumping (180) and above WallRunning (160). See the file header -- this single number is
	-- what keeps a double tap from hijacking a chimney climb.
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
		-- JumpQueued rather than a bare buffer read, so the leap honors CombatClient's jump suppression
		-- exactly like every other launch in this framework -- a player whose jump has been disabled
		-- through an M1 combo must not be able to double-tap their way out of it.
		if not StateSupport.JumpQueued(context) then
			return false, "NoJumpInput"
		end
		if not InputBuffer.PeekDoubleJump(context.Now) then
			return false, "NoDoubleTap"
		end
		if not StateSupport.JumpIntervalElapsed(context.Now) then
			return false, "JumpCooldown"
		end
		if context.Now < cooldownUntil then
			return false, "LeapCooldown"
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
		InputBuffer.ConsumeDoubleJump(context.Now)
		StateSupport.NoteJump(context.Now)
		lastLeapAt = context.Now
		context.AnimationVariant = nil

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
	end,

	Update = function(context: ParkourContext): ParkourTypes.TransitionResult
		velocity -= Vector3.new(0, Workspace.Gravity * context.DeltaTime, 0)
		context.Momentum = ParkourMath.PlanarSpeed(velocity)

		local motor = context.Motor
		motor.Mode = "Velocity"
		motor.Velocity = velocity
		motor.CancelGravity = true
		motor.FaceDirection = ParkourMath.Flatten(velocity)
		motor.DesiredSpeed = context.Momentum

		-- ARRIVAL, which is how this state normally ends -- not a clock. See Leap.MaxFlightSeconds for why
		-- the leap owns the whole flight rather than handing control back partway through it. The minimum
		-- guard is the same one States/WallJumping uses: on the launch frame the character is often still
		-- touching whatever they left.
		if context.Ground.Grounded and context.StateElapsed > LEAP.MinFlightSeconds then
			return "Falling"
		end

		-- A leap that falls SHORT of the surface it aimed at can still catch its edge, and that is the
		-- most valuable thing this state can do with a near miss: the difference between an exciting
		-- recovery and a long drop. Asked of the same shared predicate States/WallJumping.Update's
		-- top-out grab uses -- a transition returned from a state's own Update is route 1 in
		-- StateMachine.Update, which does not consult the target's CanEnter, so the gates that make an
		-- automatic grab something the player asked for have to be asked here. This used to be a
		-- hand-written restatement that matched neither LedgeHanging.CanEnter nor WallJumping's own
		-- copy; see StateSupport.LedgeGrabAvailable's header for what the three had drifted into.
		--
		-- Handed this state's OWN integrated vertical speed, not the context's measured one, for the
		-- same reason WallJumping does: the constraint is being commanded from `velocity` here.
		if StateSupport.LedgeGrabAvailable(context, velocity.Y) then
			return "LedgeHanging"
		end

		-- The backstop, not the exit. A leap that has neither landed nor caught anything after this long
		-- has flown into a case nobody designed for, and holding the body past it would be worse than
		-- ending in mid-air.
		if context.StateElapsed >= LEAP.MaxFlightSeconds then
			return "Falling"
		end
		return nil
	end,

	Exit = function(context: ParkourContext): ()
		cooldownUntil = context.Now + LEAP.CooldownSeconds
		context.AnimationVariant = nil
		StateSupport.HandOff(context, velocity)
	end,
}

return Leaping
