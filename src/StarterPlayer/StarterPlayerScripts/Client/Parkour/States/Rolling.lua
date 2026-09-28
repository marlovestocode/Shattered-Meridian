--!strict
--[[
	States/Rolling.lua

	Owns: the roll -- a short, committed burst that is both the traversal roll (out of a sprint, out of a
	slide, out of a landing) and the grounded DODGE in a fight. One state for both, because the thing
	that makes a roll a good dodge (a fixed, predictable distance, committed once started) is the same
	thing that makes it a readable traversal move.

	THE LANDING ROLL is the reason this state earns its place rather than being a second slide. A roll
	pressed within ParkourConstants.Roll.LandingWindowSeconds of ground contact converts what would have
	been a hard landing -- most of the player's momentum gone, a recovery window they can't move through
	-- into a full-speed continuation. Two halves, and neither is decided here:
	  * EARLY (pressed before contact) is decided on the contact frame by States/Falling.Update, which
	    returns "Rolling" instead of "Landing" -- so Landing's momentum cut, camera dip and shake never
	    happen at all.
	  * LATE (pressed after contact) enters from Landing by ordinary pre-emption, and Enter below refunds
	    the momentum Landing took (ParkourContext.PreLandingMomentum). The dip already played; that is the
	    accepted cost of not delaying every landing's dip on the chance a roll follows.

	EVERY ROUTE IN IS GATED BY ONE PREDICATE, StateSupport.CanRoll -- this CanEnter, Sliding's roll-out
	and Falling's contact frame all ask it. See its own header for the cooldown bypass that used to exist
	when the two route-1 sites could not see this file's private cooldown.

	IN COMBAT THE ROLL IS A DODGE, and the server decides whether it was one: an accepted Roll report opens
	evade frames on DefenseSystem (DefenseConstants.Evade), and a swing landing inside them resolves
	"Evaded". Nothing here knows that -- this state reports "Roll" exactly as it always did. What it does
	know is FACING: in combat or under shift lock the body keeps looking where it was looking and rolls
	sideways or backwards relative to it, publishing a Forward/Back/Left/Right variant the animator plays
	directionally. Out of combat with the camera free, the body turns into the roll as before.

	Runs in Velocity drive mode with a fixed speed rather than a decaying one: a roll is short enough
	that decay within it would be imperceptible, and a constant speed is what makes its distance
	predictable, which is what makes it usable as a dodge. Steering is OFF for the same reason -- direction
	is chosen once, at Enter, from held input.

	KNOCKBACK WINS. A launch or a hit-stop freeze lands through ParkourMotor.ApplyExternalImpulse, which
	records it as an interrupt while this state owns the body; Update reads it and hands off carrying the
	impulse instead of re-commanding the roll's own velocity over it on the next physics step.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

local InputBuffer = require(script.Parent.Parent.InputBuffer)
local ParkourMotor = require(script.Parent.Parent.ParkourMotor)
local StateSupport = require(script.Parent.StateSupport)

type ParkourContext = ParkourTypes.ParkourContext

local ROLL = ParkourConstants.Roll

-- Per-roll scratch, module-level for the same singleton reason every state here uses (see
-- States/Sliding.lua's own note).
local rollDirection = Vector3.zero
-- The direction the body was last driven in -- the roll's own direction for the roll proper, the held
-- input's while crawling out from under a ceiling. Exit hands off along this, so a crawl that turned
-- does not snap back to the roll's original heading on the way out.
local lastTravel = Vector3.zero
-- Momentum the roll was entered with. Exit returns this (ROLL.ExitRetainFraction's own header), never
-- the roll's burst speed.
local entryMomentum = 0
-- The facing a directional roll holds, or nil when the body turns into the roll.
local heldFacing: Vector3? = nil
-- The impulse an external mover landed mid-roll, captured by Update for Exit to hand off with.
local interruptVelocity: Vector3? = nil

-- Which way the roll goes: HELD INPUT first, then actual motion, then facing.
--
-- The reverse of StateSupport.TravelDirection's order, deliberately, and the reason is the dodge. That
-- helper prefers the direction the body is already MOVING, which is right for a traversal that
-- continues motion -- and wrong for a roll pressed while sprinting forward with the stick already
-- pulled sideways, which used to roll straight ahead into the swing the player was trying to leave.
-- Input is what the player is asking for on the frame they ask; velocity is only what they were doing.
-- Humanoid.MoveDirection is already camera-relative (see ParkourContext.MoveIntent), so "hold left and
-- roll" rolls left of the camera, which is the only left a player can mean.
local function rollDirectionFor(context: ParkourContext): Vector3
	if StateSupport.HasMoveIntent(context) then
		return ParkourMath.SafeUnit(ParkourMath.Flatten(context.MoveIntent), StateSupport.TravelDirection(context))
	end
	return StateSupport.TravelDirection(context)
end

-- Which of the four directional clips a roll along `travel` reads as, for a body looking along `facing`.
-- The dominant axis wins; an exact diagonal resolves to Forward/Back, which is the more readable clip of
-- the two for a move that is mostly about getting out of the way.
local function directionalVariant(travel: Vector3, facing: Vector3): string
	local forward = ParkourMath.SafeUnit(ParkourMath.Flatten(facing), Vector3.new(0, 0, -1))
	-- Right of a look vector (x, 0, z) is (-z, 0, x): for the default -Z facing, +X.
	local right = Vector3.new(-forward.Z, 0, forward.X)
	local flatTravel = ParkourMath.SafeUnit(ParkourMath.Flatten(travel), forward)
	local along = flatTravel:Dot(forward)
	local across = flatTravel:Dot(right)
	if math.abs(along) >= math.abs(across) then
		return if along >= 0 then "Forward" else "Back"
	end
	return if across > 0 then "Right" else "Left"
end

-- One frame of drive along `direction` at `speed`.
--
-- Grounded: projected onto the surface and pressed into it by ROLL.SurfaceStickSpeed, so the roll
-- follows terrain instead of launching off a crest. Airborne (rolled off an edge): the horizontal
-- plane only, so gravity owns the fall -- a Vector-mode drive here held the body at whatever vertical
-- speed it last commanded, which is what made a roll off a ledge float.
local function drive(context: ParkourContext, direction: Vector3, speed: number): ()
	local motor = context.Motor
	local flat = ParkourMath.SafeUnit(ParkourMath.Flatten(direction), lastTravel)
	motor.Mode = "Velocity"
	motor.CancelGravity = false
	if context.Ground.Grounded then
		local travel = ParkourMath.SafeUnit(ParkourMath.ProjectOnPlane(flat, context.Ground.Normal), flat)
		motor.Velocity = travel * speed - Vector3.new(0, ROLL.SurfaceStickSpeed, 0)
		motor.PlanarOnly = false
	else
		motor.Velocity = flat * speed
		motor.PlanarOnly = true
	end
	motor.FaceDirection = heldFacing or flat
	-- Rolls duck under the same geometry slides do -- see ROLL.HipHeightDelta's own comment for why it
	-- may never stand taller than the slide it can hand off to.
	motor.HipHeightDelta = ROLL.HipHeightDelta
	motor.DesiredSpeed = speed
	lastTravel = flat
end

local Rolling: ParkourTypes.StateDefinition = {
	Id = "Rolling",
	Priority = 140,
	Drive = "Velocity",
	-- No Obstacle probe: a Committed state is never pre-empted, so nothing could ever act on an obstacle
	-- this state saw, and paying for the cast every frame bought nothing.
	Probes = { Ground = true, Ceiling = true },
	Reports = "Roll",
	-- Committed: a roll is short and must complete. Without this a roll started at speed would be
	-- immediately pre-empted by whatever the character rolled toward, and the dodge would not exist as
	-- a reliable defensive option -- which is most of its value.
	Committed = true,

	CanEnter = function(context: ParkourContext): (boolean, string?)
		return StateSupport.CanRoll(context)
	end,

	Enter = function(context: ParkourContext, previous: ParkourTypes.MovementStateId): ()
		-- Spent under the WIDER of the two windows a roll can be admitted with (see InputBuffer.ConsumeRoll)
		-- -- a press the contact frame admitted under the landing window must not survive to be spent
		-- again by the next ask.
		InputBuffer.ConsumeRoll(
			context.Now,
			math.max(ROLL.LandingWindowSeconds, ParkourConstants.Assists.ActionBufferSeconds)
		)
		StateSupport.NoteRollStarted(context.Now)
		-- Nothing can have been recorded against THIS roll yet; anything pending belongs to a previous
		-- owner the hand-off already ended.
		ParkourMotor.ConsumeInterrupt()
		interruptVelocity = nil

		-- THE LATE LANDING ROLL: refund what Landing charged, inside the window. Read and cleared here,
		-- since this is its only reader -- see ParkourContext.PreLandingMomentum.
		local landedAt = context.LandedAt
		local preLanding = context.PreLandingMomentum
		if
			previous == "Landing"
			and landedAt ~= nil
			and preLanding ~= nil
			and (context.Now - landedAt) <= ROLL.LandingWindowSeconds
		then
			context.Momentum = math.max(context.Momentum, preLanding)
		end
		context.PreLandingMomentum = nil
		context.LandedAt = nil

		rollDirection = rollDirectionFor(context)
		lastTravel = rollDirection
		entryMomentum = context.Momentum
		-- A landing roll cancels the fall's momentum cost outright: the severity is cleared before
		-- States/Landing.lua can ever apply it, which is exactly what "rolling out of a fall" means.
		-- Clearing FallHeight alongside it keeps the camera dip and shake from firing for a landing the
		-- player successfully avoided.
		context.LandingSeverity = nil
		context.FallHeight = 0
		context.Momentum = math.max(entryMomentum, ROLL.Speed)

		-- THE COMBAT ROLL KEEPS ITS FACING. In a fight the player is looking at somebody, and a dodge
		-- that turned their back on them for half a second would hand every opponent a backstab bearing
		-- (OutcomeResolver) the instant the evade frames closed. Under shift lock the camera owns facing
		-- already, and turning the body into the roll would fight it for the roll's whole length.
		local facing =
			ParkourMath.SafeUnit(ParkourMath.Flatten(context.RootPart.CFrame.LookVector), Vector3.new(0, 0, -1))
		if context.InCombat or ParkourMotor.IsFacingHeldElsewhere() then
			heldFacing = facing
			context.AnimationVariant = directionalVariant(rollDirection, facing)
		else
			heldFacing = nil
			-- The body turns into the roll, so every free roll is a forward one.
			context.AnimationVariant = "Forward"
		end
	end,

	Update = function(context: ParkourContext): ParkourTypes.TransitionResult
		-- KNOCKBACK WINS -- asked before anything is driven, so a hit that landed since the last frame is
		-- never overwritten by one more frame of roll. See this file's header.
		local interrupt = ParkourMotor.ConsumeInterrupt()
		if interrupt then
			interruptVelocity = interrupt
			if interrupt.Y > 1e-3 or not context.Ground.Grounded then
				return "Falling"
			end
			return StateSupport.ResolveGroundedState(context)
		end

		local grounded = context.Ground.Grounded
		local elapsed = context.StateElapsed

		if elapsed < ROLL.DurationSeconds then
			drive(context, rollDirection, context.Momentum)
			return nil
		end

		-- The roll proper is over. Standing up into a ceiling is the one thing that extends it -- same rule
		-- and same reason as the slide's.
		if context.CeilingClear then
			drive(context, lastTravel, context.Momentum)
			return if grounded then StateSupport.ResolveGroundedState(context) else "Falling"
		end
		-- Something overhead of a body in the air is not a crawlspace; there is nothing to stand up into.
		if not grounded then
			drive(context, lastTravel, context.Momentum)
			return "Falling"
		end

		-- THE CEILING HOLD -- see ROLL.CrawlSpeed/MaxCeilingHoldSeconds. Crawl where the player is
		-- steering (and nowhere, if they are not), and after the cap hand the posture to the slide, which
		-- has no cap of its own. A route-1 hand-off, and the slide's own gates (its cooldown, its entry
		-- speed, the combat gate) are deliberately NOT asked: this is the ceiling taking the character, not
		-- the player asking to slide -- the same reasoning the forced-slope entries into Sliding give for
		-- not asking them either. Refusing would leave a crouched body with no state that owns crouching.
		local steering = StateSupport.HasMoveIntent(context)
		local crawlDirection = if steering
			then ParkourMath.SafeUnit(ParkourMath.Flatten(context.MoveIntent), lastTravel)
			else lastTravel
		context.Momentum = if steering then ROLL.CrawlSpeed else 0
		drive(context, crawlDirection, context.Momentum)
		if (elapsed - ROLL.DurationSeconds) >= ROLL.MaxCeilingHoldSeconds then
			return "Sliding"
		end
		return nil
	end,

	Exit = function(context: ParkourContext, nextState: ParkourTypes.MovementStateId): ()
		context.AnimationVariant = nil
		heldFacing = nil

		-- Interrupted: the impulse is what the body is doing now, so it is what gets handed off.
		local interrupt = interruptVelocity
		if interrupt then
			interruptVelocity = nil
			context.Momentum = ParkourMath.PlanarSpeed(interrupt)
			StateSupport.HandOff(context, interrupt)
			return
		end

		-- Into the slide from a ceiling hold: NO hand-off, deliberately, and the opposite of every other
		-- exit here. HandOff zeroes HipHeightDelta, and the hand-off frame is committed through the
		-- Humanoid branch -- which restores the full HipHeight -- before Sliding's first Update crouches
		-- the body again. That is one frame of standing up under the very ceiling that caused the hand-off.
		-- Leaving this frame's crawl command committed instead is a Velocity-to-Velocity continuation at
		-- the same crouch, which is exactly what the slide is about to command anyway.
		if nextState == "Sliding" then
			return
		end

		-- Return what the roll was entered with (see ROLL.ExitRetainFraction), floored at walking pace
		-- while a direction is held so a roll from rest does not stop dead at its end.
		local floor = if StateSupport.HasMoveIntent(context) then ParkourConstants.Locomotion.WalkSpeed else 0
		context.Momentum = ParkourMath.ExitMomentum(entryMomentum, ROLL.ExitRetainFraction, floor)
		StateSupport.HandOff(
			context,
			lastTravel * context.Momentum + Vector3.new(0, context.RootPart.AssemblyLinearVelocity.Y, 0)
		)
	end,
}

return Rolling
