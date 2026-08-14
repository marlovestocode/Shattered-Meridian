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

	THE COST OF ANCHORING, and what this file does about it: an anchored root goes exactly where its
	CFrame is written, instantly. So the naive grab -- write the hang pose on the first frame -- is a
	teleport of up to several studs plus a rotation snap, and no amount of tuning the thresholds around
	it will stop that from reading as clunky, because the problem is that nothing MOVES. The grab
	instead runs in two beats: Enter stops the fall dead at the point of contact (on the detection
	frame, not the one after it), and Update eases the body from there into the pose over a window
	scaled to how far it actually has to travel. That window doubles as the grip settle -- inputs open
	when the pull lands -- so the time the player cannot act is time they can see being used.

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
local grabbedInstance: BasePart? = nil

-- THE PULL INTO THE POSE. Where the body was on the frame the grab landed, when that frame was, and
-- how long the pull it starts should take. See Enter for why all three are captured there and
-- Ledge.AttachSpeed for why the duration is derived from a distance rather than authored flat.
local attachFrom = CFrame.identity
local attachBeganAt = 0
local attachSeconds = 0

-- The edge the last voluntary drop let go of, and the two windows that keep it from being caught
-- again on the way down: a short blanket one that covers every edge while the release push is still
-- moving the body clear of the face, and a long one scoped to THIS edge. See isBlockedLedge below.
local regrabAnyUntil = 0
local regrabSameUntil = 0
local regrabInstance: BasePart? = nil
local regrabEdge = Vector3.zero

-- Whether a candidate edge is the one the player just chose to let go of. Identity is tested two ways
-- because neither is sufficient alone: the Instance catches a re-grab of the same part, and the
-- radius catches the same physical lip built out of a DIFFERENT part -- which is most lips, since a
-- wall face of any size is several blocks -- where an instance test alone lets the drop re-grab the
-- neighbour half a stud sideways and strand the player exactly where they asked to leave.
local function isBlockedLedge(probe: ParkourTypes.LedgeProbe): boolean
	if regrabInstance ~= nil and probe.Instance == regrabInstance then
		return true
	end
	return (probe.EdgePosition - regrabEdge).Magnitude <= LEDGE.RegrabIgnoreRadius
end

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
		if context.Now < regrabAnyUntil then
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
		-- THE FACING GATE. Every check above this line is about the EDGE -- whether one exists, whether
		-- it is grabbable, whether there is room to hang from it. This is the only one about the
		-- CHARACTER's relationship to it, and it is what stops a grab the player never asked for.
		--
		-- It matters more here than anywhere else in the framework because a hang is automatic and
		-- Committed (see that flag's own note above): no button is pressed, and the instant this
		-- function returns true the fall is over. The only thing that used to stand between a
		-- shift-locked player and an edge behind their back was EnvironmentProbe.probeLedge's choice of
		-- SEARCH DIRECTION -- and a heuristic about where to cast is not a decision about whether to
		-- commit, because whichever direction found the edge, nothing re-checked it against the
		-- character afterward. Under shift lock (Client/Camera/ShiftLockCamera.lua) travel is
		-- camera-relative with AutoRotate off, so a strafe or a backpedal points travel into walls the
		-- player is not looking at -- and travel is exactly what that primary cast searches.
		--
		-- Asked against the WallNormal the probe actually recorded, so it holds no matter which of the
		-- two casts found the edge, and asked as "is that face in front of me" because facing the wall
		-- is the pose this state commits to (see Enter, which points the character INTO it). The
		-- legitimate strafe-past-a-ledge-while-staring-at-it grab passes untouched: that case has facing
		-- pointed straight at the face, which is the whole reason it reads as a reach.
		if
			not StateSupport.IsMovingToward(
				context.RootPart.CFrame.LookVector,
				context.Ledge.WallNormal,
				LEDGE.MaxGrabFacingAngleDegrees
			)
		then
			return false, "NotFacingLedge"
		end
		-- Tested LAST because it is the only refusal that needs the probe's own fields to be meaningful
		-- (an unfound ledge has a stale EdgePosition), and because it is the narrowest: everything above
		-- refuses a class of situations, this refuses exactly one edge for a fraction of a second.
		if context.Now < regrabSameUntil and isBlockedLedge(context.Ledge) then
			return false, "SameLedgeLockout"
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
		-- so without this the buffered jump outlived the pull into the pose and fired the climb on the
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
		grabbedInstance = context.Ledge.Instance
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

		-- THE GRAB BITES ON THE FRAME IT IS DETECTED, not the frame after.
		--
		-- StateMachine.Update applies at most one transition and returns, so this state's Update does not
		-- run until the NEXT frame -- meaning without this block the frame that decided to grab still
		-- commits the outgoing Falling state's command, and the character falls for one more frame under
		-- ordinary gravity before the anchor engages. At a fast fall that is a stud or two of visible
		-- overshoot past the lip followed by a correction back up to it, which is precisely the "it
		-- doesn't catch when I press it" the grab is accused of. Writing the motor here is the same
		-- technique StateSupport.HandOff uses for the opposite edge of a transition, and for the same
		-- ordering reason -- see that function's own header.
		--
		-- Target is the CURRENT pose, not the hang pose: this frame's job is to stop the fall dead where
		-- contact happened. Update takes over next frame and eases from here to hangCFrame.
		attachFrom = context.RootPart.CFrame
		attachBeganAt = context.Now
		attachSeconds = math.clamp(
			(position - attachFrom.Position).Magnitude / math.max(LEDGE.AttachSpeed, 1e-3),
			LEDGE.AttachMinSeconds,
			LEDGE.AttachMaxSeconds
		)
		context.Motor.Mode = "Kinematic"
		context.Motor.TargetCFrame = attachFrom
		context.Motor.DesiredSpeed = 0

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
		motor.DesiredSpeed = 0

		-- The root is ANCHORED for the whole hang, so whatever goes in TargetCFrame is where the body
		-- instantaneously is. Writing hangCFrame directly -- which this used to do -- therefore teleports
		-- the character up to several studs and spins them to face the wall inside a single frame. That
		-- discontinuity IS the clunk: there is no motion for the eye to follow, so the grab reads as the
		-- character being relocated rather than as them catching something.
		--
		-- Interpolating the whole CFrame rather than just the position matters as much: CFrame:Lerp
		-- slerps the rotation, so the turn to face the wall happens over the same window as the reach
		-- instead of snapping on frame one.
		local attachAlpha = math.clamp((context.Now - attachBeganAt) / math.max(attachSeconds, 1e-3), 0, 1)
		motor.TargetCFrame = attachFrom:Lerp(hangCFrame, ParkourMath.EaseOutCubic(attachAlpha))

		-- Inputs open the moment the pull lands. This replaces a flat grip-settle window, and the
		-- difference is not the duration -- they are within a few hundredths of each other -- it is that
		-- the window is now spent on something visible. A fixed delay in front of a teleport is dead
		-- time the player experiences as lag; the same delay spent watching the body swing into the pose
		-- is the grab itself. It also means a near-instant grab (hands already at the lip) is actionable
		-- in a frame or two rather than always costing the far case's settle.
		if attachAlpha < 1 then
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
		regrabAnyUntil = context.Now + LEDGE.RegrabAnyLedgeSeconds
		regrabSameUntil = context.Now + LEDGE.RegrabLockoutSeconds
		regrabInstance = grabbedInstance
		regrabEdge = edgePosition
		context.LedgeAnchorPosition = nil
		context.LedgeAnchorNormal = nil
		-- Released with a small push away from the wall so the character falls clear of the face
		-- rather than scraping down it (and immediately re-satisfying the grab probe).
		StateSupport.HandOff(context, wallNormal * 4)
	end,
}

return LedgeHanging
