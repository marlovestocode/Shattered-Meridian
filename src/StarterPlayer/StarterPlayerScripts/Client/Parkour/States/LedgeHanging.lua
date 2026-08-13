--!strict
--[[
	States/LedgeHanging.lua

	Owns: catching and holding a ledge -- the automatic grab while falling past a grabbable edge, the
	held pose, and the three ways out (climb up, drop, time out).

	A ledge is a fundamentally different thing from an obstacle, which is why this is not part of
	States/Mantling.lua: an obstacle is something a GROUNDED character walks into and decides what to
	do about; a ledge is an edge an AIRBORNE character catches. The probe geometry is different (a
	band around head height rather than a height ladder from the feet), the entry condition is
	different (falling, not moving fast), and the outcome is different (a hold you can act from,
	rather than a traversal that completes on its own).

	Hanging is a TRANSITION, not a resting place -- MaxHangSeconds drops the character automatically.
	A ledge you can hang from indefinitely is a ledge players use to park, and parking mid-wall in a
	PvP game is a problem rather than a feature.

	Kinematic: the character is pinned to a computed offset from the edge. Anchoring is what makes a
	hang actually hold, and it is why the pose does not drift or vibrate the way a constraint-held one
	would against the wall it is pressed into.

	The design's "make the system smart enough to determine ... whether there is enough space for the
	character to stand after climbing it" is enforced at the probe level (LedgeProbe.HasStandingSpace)
	and consumed here: an edge with nothing to stand on can still be HUNG from -- that is a legitimate
	thing to do while deciding where to go -- but the climb-up out of it is refused, which is the
	honest behavior rather than pretending the ledge is not there.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

local InputBuffer = require(script.Parent.Parent.InputBuffer)
local StateSupport = require(script.Parent.StateSupport)

type ParkourContext = ParkourTypes.ParkourContext

local LEDGE = ParkourConstants.Ledge

-- The pose held for the duration of the hang, computed once at Enter. Recomputing it per frame from
-- a live probe would let the pose creep as the probe's own hit point shifts by fractions of a stud.
local hangCFrame = CFrame.identity
local edgePosition = Vector3.zero
local wallNormal = Vector3.new(0, 0, -1)
local hasStandingSpace = false
local regrabUntil = 0

local LedgeHanging: ParkourTypes.StateDefinition = {
	Id = "LedgeHanging",
	Priority = 210,
	Drive = "Kinematic",
	Probes = { Ground = true, Ledge = true, Walls = true },
	-- Committed, unlike every other non-traversal state: a hang is a HELD POSE the player acts from,
	-- and this file's header names its three exits (climb, drop, time out) as the complete set. Route 2
	-- pre-emption is not a fourth exit, it is a way for those three to be bypassed -- which is exactly
	-- what happened, since LedgeClimbing sits one priority step above this and used to accept
	-- unconditionally. Belt and braces with LedgeClimbing.CanEnter's own input check: that one makes the
	-- climb require asking, this one makes Update the only thing that can answer -- including the
	-- hasStandingSpace gate, which lives here and which no other state can see.
	--
	-- Does NOT block combat taking the body: ParkourController routes that through
	-- machine:ForceTransition, which bypasses CanEnter and commitment alike.
	Committed = true,

	CanEnter = function(context: ParkourContext): (boolean, string?)
		if not context.Assists.LedgeAssist then
			return false, "LedgeAssistDisabled"
		end
		if context.Ground.Grounded then
			return false, "Grounded"
		end
		if context.Now < regrabUntil then
			return false, "RegrabLockout"
		end
		if context.VerticalVelocity > LEDGE.MaxVerticalSpeedToGrab then
			return false, "RisingTooFast"
		end
		if not context.Ledge.Found then
			return false, "NoLedge"
		end
		if not context.Ledge.Allowed then
			return false, "LedgeNotGrabbable"
		end
		-- An edge can be geometrically inside the grab band and still sit too close to the ground for a
		-- hang to mean anything -- the pose would put the character's feet in the floor. Refusing here is
		-- also what stops a grab from STEALING a mantle: the mantle band (Obstacle.VaultMaxHeight 4.2 to
		-- MantleMaxHeight 7.5, measured from the foot plane) overlaps the bottom of the grab band, and
		-- LedgeHanging outranks Mantling on priority, so jumping at a chest-high wall used to produce a
		-- grounded-looking "hang" instead of the climb the player asked for. A grounded approach to that
		-- same wall still mantles normally -- ObstacleClassifier refuses outright while airborne, which
		-- is the deliberate split between the two systems.
		if not context.Ledge.HasHangSpace then
			return false, "NoHangSpace"
		end
		return true, nil
	end,

	Enter = function(context: ParkourContext): ()
		-- Both intents that can act FROM a hang are consumed on the way in, so neither can be satisfied
		-- by a press made before the grab existed.
		--
		-- This is the difference between a hang and a mantle. Catching a ledge is a DECISION POINT --
		-- climb, drop, or hold -- and a decision made by an input the player aimed at something else is
		-- not a decision. Jumping at a wall means pressing jump within a fraction of a second of contact,
		-- so without this the buffered jump survived the 0.12s grip settle and fired the climb on the
		-- next frame: the player never saw a hang, only a slower mantle they did not ask for. Same for a
		-- slide press carried in from sliding off a roof, which would drop them the instant they caught
		-- the edge they were reaching for.
		--
		-- Every other state in this framework already consumes on Enter (Sliding.Enter, and
		-- LedgeClimbing.Enter below); this one was the outlier. The climb and the drop now require a
		-- FRESH press made while hanging, which is what makes the hold real.
		InputBuffer.ConsumeJump(context.Now)
		InputBuffer.ConsumeSlide(context.Now)

		edgePosition = context.Ledge.EdgePosition
		wallNormal = ParkourMath.SafeUnit(ParkourMath.Flatten(context.Ledge.WallNormal), Vector3.new(0, 0, -1))
		hasStandingSpace = context.Ledge.HasStandingSpace
		context.AnimationVariant = "Hang"
		-- Published for States/LedgeClimbing.lua -- see ParkourContext.LedgeAnchorPosition's own header
		-- for why the climb cannot simply re-probe for the edge it is already holding.
		context.LedgeAnchorPosition = edgePosition
		context.LedgeAnchorNormal = wallNormal

		-- Hanging pose: below the edge by HangVerticalOffset and backed off along the wall's outward
		-- normal by HangHorizontalOffset, facing INTO the wall (hence the negated normal as the look
		-- direction). The position itself comes from ParkourMath.HangPosition because
		-- EnvironmentProbe.probeLedge tests this exact pose for floor clearance before offering the grab
		-- -- if the two computed it separately, that check would be validating a pose nobody uses.
		local position =
			ParkourMath.HangPosition(edgePosition, wallNormal, LEDGE.HangVerticalOffset, LEDGE.HangHorizontalOffset)
		hangCFrame = CFrame.lookAt(position, position - wallNormal)

		-- A caught ledge cancels the fall outright: the drop is over, and letting the severity survive
		-- would apply a hard-landing momentum cost to the eventual climb-up, several seconds later,
		-- for a fall the player successfully arrested.
		context.LandingSeverity = nil
		context.FallHeight = 0
		context.ApexHeight = position.Y
		context.Momentum = 0
		-- Catching a ledge is as good as touching the ground for chain-limit purposes: it is a
		-- deliberate, skilful stop, and refusing to reset the counters would punish the player for
		-- succeeding.
		context.WallRunChain = 0
		context.WallJumpChain = 0
	end,

	Update = function(context: ParkourContext): ParkourTypes.TransitionResult
		local motor = context.Motor
		motor.Mode = "Kinematic"
		motor.TargetCFrame = hangCFrame
		motor.DesiredSpeed = 0

		-- A short settle before inputs are accepted, so a grab reads as a grab rather than as the
		-- character teleporting straight through the hang and onto the ledge.
		if context.StateElapsed < LEDGE.GripSettleSeconds then
			return nil
		end

		-- Jump = climb up, when there is somewhere to climb to.
		if StateSupport.JumpQueued(context) then
			if hasStandingSpace then
				return "LedgeClimbing"
			end
			-- No standing space: the jump becomes a drop instead of doing nothing, so the input is
			-- never silently eaten.
			InputBuffer.ConsumeJump(context.Now)
			return "Falling"
		end

		-- Slide/crouch = let go. The same key that ducks on the ground releases a grip in the air,
		-- which is the convention this genre has settled on.
		if InputBuffer.PeekSlide(context.Now) then
			InputBuffer.ConsumeSlide(context.Now)
			return "Falling"
		end

		if context.StateElapsed >= LEDGE.MaxHangSeconds then
			return "Falling"
		end
		return nil
	end,

	Exit = function(context: ParkourContext, nextState: ParkourTypes.MovementStateId): ()
		context.AnimationVariant = nil
		if nextState == "LedgeClimbing" then
			return
		end
		regrabUntil = context.Now + LEDGE.RegrabLockoutSeconds
		context.LedgeAnchorPosition = nil
		context.LedgeAnchorNormal = nil
		-- Released with a small push away from the wall so the character falls clear of the face
		-- rather than scraping down it (and immediately re-satisfying the grab probe).
		StateSupport.HandOff(context, wallNormal * 4)
	end,
}

return LedgeHanging
