--!strict
--[[
	States/Sliding.lua

	Owns: the momentum slide -- entry off real speed, physics-driven decay, slope response, the crouch
	that lets it pass under things, and the four ways out (jump, roll, stand, obstacle).

	THE DESIGN CONSTRAINT THIS FILE EXISTS TO SATISFY, quoted because it is what every decision below
	is measured against: "Make the slide feel like an actual continuation of movement instead of a
	separate animation that simply moves the character forward." Concretely that means:
	  * Entry requires speed you already had, and MULTIPLIES it (EntryBoostMultiplier) rather than
	    setting it. A slide is never slower than the sprint that fed it.
	  * The slide never holds a fixed speed. It integrates: friction bleeds it, downhill adds to it,
	    uphill kills it, and the surface's own authored friction multiplier scales all of that.
	  * Every exit hands its LIVE momentum to the next state. The slide-jump is worth slightly more
	    than the sum of its parts (JumpOutRetainFraction is above 1) because chaining is the skill this
	    system is built to reward.
	  * There is no minimum commitment beyond the anti-flicker MinDurationSeconds, and jumping,
	    rolling or vaulting out bypasses even that.

	The crouch (HipHeightDelta) is what physically lets a slide pass under geometry, and the ceiling
	probe is what stops it ending while still underneath -- standing up inside a low tunnel would eject
	the character through it. That pair is why Ceiling is in this state's probe request and nowhere
	else.

	Runs in Velocity drive mode: a LinearVelocity constraint at the integrated speed, projected onto
	the ground plane so the slide follows terrain instead of launching off the crest of a ramp. Real
	collision still applies, so sliding into a wall stops at the wall rather than through it.
]]

-- Workspace is imported for Gravity ONLY -- the slope-pull term in ParkourMath.IntegrateSlideSpeed,
-- which is real physics (g*sin(theta)) rather than a per-degree approximation. The slide still applies
-- no gravity of its own to the body's VERTICAL motion, unlike the airborne states: a grounded slide's
-- vertical behavior is entirely the small contact bias applied in Update plus Roblox's own collision
-- response, and adding a downward term to a body already resting on a surface would just fight the
-- velocity constraint.
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

local InputBuffer = require(script.Parent.Parent.InputBuffer)
local ObstacleClassifier = require(ReplicatedStorage.Shared.Parkour.ObstacleClassifier)
local StateSupport = require(script.Parent.StateSupport)

type ParkourContext = ParkourTypes.ParkourContext

local SLIDE = ParkourConstants.Slide

-- Per-slide scratch. Module-level rather than context fields because nothing outside this file has
-- any business reading them, and there is exactly one local player -- the same singleton reasoning
-- every other client module in this codebase uses.
local slideDirection = Vector3.zero
local cooldownUntil = 0
-- Set when the slide was entered by force (a slope too steep to stand on) rather than by input. A
-- forced slide ignores the "released the key" exit -- there was never a key -- and ends when the
-- ground flattens out instead.
local forced = false

local Sliding: ParkourTypes.StateDefinition = {
	Id = "Sliding",
	Priority = 120,
	Drive = "Velocity",
	Probes = { Ground = true, Obstacle = true, Ceiling = true, Walls = true },
	Reports = "Slide",

	CanEnter = function(context: ParkourContext): (boolean, string?)
		if not context.Ground.Grounded then
			return false, "NotGrounded"
		end
		if context.Now < cooldownUntil then
			return false, "SlideCooldown"
		end
		-- The forced case: too steep to stand on. Checked before the input gate because it is not a
		-- request, it is physics -- see States/Idle.lua's own note on routing this through the slide
		-- rather than inventing a separate cliff-slide behavior.
		if context.Ground.SlopeAngle >= ParkourConstants.Slope.ForcedSlideAngleDegrees then
			return true, nil
		end
		if not InputBuffer.PeekSlide(context.Now) then
			return false, "NoSlideInput"
		end
		-- The entry speed requirement is waived on a genuine downhill. It exists so a slide is a
		-- CONTINUATION of speed you already earned rather than a free move from a standstill -- but on a
		-- slope gravity supplies that speed within a few frames, so demanding a sprint first just meant
		-- standing on a hill and pressing slide did nothing, with no way for the player to tell why.
		-- Same threshold that suspends the duration cap, so "the terrain is carrying this slide" means
		-- one thing throughout this file.
		local downhill = ParkourMath.SignedSlopeAlong(context.Ground.Normal, StateSupport.TravelDirection(context))
		if downhill < SLIDE.SustainSlopeDegrees and context.Momentum < SLIDE.EntryMinSpeed then
			return false, "TooSlowToSlide"
		end
		return true, nil
	end,

	Enter = function(context: ParkourContext): ()
		InputBuffer.ConsumeSlide(context.Now)
		forced = context.Ground.SlopeAngle >= ParkourConstants.Slope.ForcedSlideAngleDegrees

		slideDirection = StateSupport.TravelDirection(context)
		-- A FORCED slide starts down the fall line, not along whatever direction the character happened
		-- to be travelling. "Too steep to stand on" means gravity owns you, and gravity does not care
		-- which way you were facing when it took over. Without this, running UP a steep ramp force-slides
		-- you still pointing uphill: the uphill term (SlopeGravityFraction * UphillFrictionScale) crushes
		-- momentum to zero within a few frames, and since the forced branch below deliberately ignores
		-- MinExitSpeed, the character then sits pinned to the ramp face at zero speed -- unable to climb,
		-- unable to exit -- until they manually steer around. The player keeps full steering authority
		-- from the next frame on (SteerRateDegreesPerSecond), so this sets the opening direction only.
		if forced then
			local fallLine = ParkourMath.DownhillDirection(context.Ground.Normal)
			if fallLine.Magnitude > 0 then
				slideDirection = fallLine
			end
		end
		-- A forced slide starts from whatever speed the character had; a committed one is rewarded
		-- with the entry boost. Clamped to MaxSpeed here as well as during integration so an entry off
		-- an already-overspeed state can't start above the ceiling.
		if not forced then
			context.Momentum = math.min(context.Momentum * SLIDE.EntryBoostMultiplier, SLIDE.MaxSpeed)
		end
		-- ...but a multiplier cannot start a slide that began from a standstill, and this state drives
		-- the body through a velocity constraint: entering at ~0 commands ~0, which PINS the character
		-- to the spot while the integrator slowly builds speed, so pressing slide on a hill looks like
		-- it did nothing. On a slope steep enough to sustain a slide, floor the entry at the speed the
		-- terrain is about to produce anyway. Same threshold as the waived entry-speed check above --
		-- the slope granted the entry, so the slope grants the speed to go with it.
		if ParkourMath.SignedSlopeAlong(context.Ground.Normal, slideDirection) >= SLIDE.SustainSlopeDegrees then
			context.Momentum = math.max(context.Momentum, SLIDE.DownhillEntrySpeed)
		end
	end,

	Update = function(context: ParkourContext): ParkourTypes.TransitionResult
		-- Airborne mid-slide (slid off an edge). Hand the live momentum to the fall rather than
		-- dropping it -- sliding off a roof should carry.
		if not context.Ground.Grounded then
			return "Falling"
		end

		local signedSlope = ParkourMath.SignedSlopeAlong(context.Ground.Normal, slideDirection)
		context.Momentum = ParkourMath.IntegrateSlideSpeed(
			context.Momentum,
			signedSlope,
			SLIDE.FrictionPerSecond,
			SLIDE.SlopeGravityFraction,
			SLIDE.UphillFrictionScale,
			context.Ground.FrictionScale,
			-- Read live rather than captured: Workspace.Gravity is a place-level setting a designer can
			-- change, and a slide should respond to the world it is actually in.
			Workspace.Gravity,
			SLIDE.MaxSpeed,
			context.DeltaTime
		)

		-- Limited steering: enough that a slide can be aimed, far short of enough that it stops
		-- reading as committed.
		slideDirection = ParkourMath.SteerDirection(
			slideDirection,
			context.MoveIntent,
			SLIDE.SteerRateDegreesPerSecond,
			context.DeltaTime
		)

		-- Project along the ground so the slide follows terrain. Without this a slide down a ramp
		-- travels horizontally and repeatedly leaves the surface, reading as a stutter.
		local travel =
			ParkourMath.SafeUnit(ParkourMath.ProjectOnPlane(slideDirection, context.Ground.Normal), slideDirection)

		local motor = context.Motor
		motor.Mode = "Velocity"
		-- A small constant downward bias keeps the body in contact with the surface across small
		-- bumps; without it a slide over uneven ground repeatedly goes briefly airborne and the
		-- grounded check flickers.
		motor.Velocity = travel * context.Momentum - Vector3.new(0, 8, 0)
		motor.CancelGravity = false
		motor.FaceDirection = travel
		motor.HipHeightDelta = SLIDE.HipHeightDelta
		motor.DesiredSpeed = context.Momentum

		-- EXIT 1: jump out. Highest-priority exit and bypasses MinDurationSeconds entirely -- the
		-- slide-jump is the chain this system is built around, and gating it behind a minimum duration
		-- would make the most skilful input in the game the one most likely to be eaten.
		if StateSupport.JumpQueued(context) and StateSupport.JumpIntervalElapsed(context.Now) then
			InputBuffer.ConsumeJump(context.Now)
			StateSupport.NoteJump(context.Now)
			local launchSpeed = context.Momentum * SLIDE.JumpOutRetainFraction
			context.Momentum = launchSpeed
			StateSupport.TryJump(
				context,
				StateSupport.LaunchPlanarVelocity(travel, launchSpeed),
				ParkourConstants.Jump.JumpVelocity
			)
			return "Jumping"
		end

		-- EXIT 2: roll out. Rolling's own CanEnter re-checks its cooldown and allowed-from list, so
		-- this only has to notice the input.
		if InputBuffer.PeekRoll(context.Now) then
			context.Momentum *= SLIDE.RollOutRetainFraction
			return "Rolling"
		end

		-- EXIT 3: something to traverse. A slide into a vaultable obstacle becomes the vault, carrying
		-- the slide's speed -- one of the chains the design calls out by name.
		if StateSupport.WithinTraversalRange(context) then
			local classification = StateSupport.ClassifyObstacle(context)
			if ObstacleClassifier.IsTraversal(classification) then
				return if classification.Action == "Mantle" then "Mantling" else "Vaulting"
			end
		end

		-- EXIT 4: the slide is over on its own terms. Four conditions, any of which ends it -- but
		-- none of them may fire while there is something overhead, or the character stands up inside
		-- it.
		if not context.CeilingClear then
			return nil
		end
		if context.StateElapsed < SLIDE.MinDurationSeconds then
			return nil
		end
		if forced then
			-- A forced slide ends when the ground is standable again, not on a key release.
			if context.Ground.SlopeAngle < ParkourConstants.Slope.ForcedSlideAngleDegrees then
				return StateSupport.ResolveGroundedState(context)
			end
			return nil
		end
		-- BOTH automatic exits are suspended while terrain is genuinely carrying the slide -- see
		-- SustainSlopeDegrees' own header. A long hill should last as long as the hill does; cutting a
		-- descent off mid-slope reads as the system giving up on the player. Releasing the slide key
		-- still ends it, so this suspends the AUTOMATIC exits and never the player's own control.
		--
		-- The speed floor has to be suspended alongside the timer, not just the timer, because on a
		-- slope low momentum means the OPPOSITE of what it means on the flat. Flat: friction has
		-- finished the slide. Downhill: the slide has not spun up yet -- gravity is still winning
		-- against friction and the next second is the fast part. Testing MinExitSpeed there killed
		-- every slide begun below it the instant MinDurationSeconds elapsed, which on a moderate ramp
		-- is long before the slope has had time to push past 15: the player got a 0.18s stub, a 0.45s
		-- cooldown, and no way to tell why the hill would not carry them. Descending onto the flat
		-- drops signedSlope below the threshold and re-arms both exits on that same frame.
		local sustainedByTerrain = signedSlope >= SLIDE.SustainSlopeDegrees
		if
			(not sustainedByTerrain and context.Momentum <= SLIDE.MinExitSpeed)
			or (not sustainedByTerrain and context.StateElapsed >= SLIDE.MaxDurationSeconds)
			or not InputBuffer.IsSlideHeld()
		then
			return StateSupport.ResolveGroundedState(context)
		end
		return nil
	end,

	Exit = function(context: ParkourContext, nextState: ParkourTypes.MovementStateId): ()
		cooldownUntil = context.Now + SLIDE.CooldownSeconds
		forced = false

		-- Traversal and jump exits keep driving the body themselves (kinematic path, or an impulse
		-- already applied above), so handing off to physics here would fight them. Every other exit
		-- releases the body with the slide's live momentum.
		if nextState == "Vaulting" or nextState == "Mantling" or nextState == "Jumping" or nextState == "Rolling" then
			return
		end
		local travel = ParkourMath.SafeUnit(ParkourMath.Flatten(slideDirection), Vector3.zero)
		StateSupport.HandOff(
			context,
			travel * context.Momentum + Vector3.new(0, context.RootPart.AssemblyLinearVelocity.Y, 0)
		)
	end,
}

return Sliding
