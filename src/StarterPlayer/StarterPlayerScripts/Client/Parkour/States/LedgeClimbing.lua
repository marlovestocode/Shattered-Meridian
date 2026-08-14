--!strict
--[[
	States/LedgeClimbing.lua

	Owns: pulling up from a hang onto the surface above -- the last step of the ledge chain, and the
	only state in the framework reachable from exactly one other state.

	Reachable only from States/LedgeHanging.lua: CanEnter refuses unless the character is currently
	hanging AND the anchor that hang published is present. That is enforced by reading
	ParkourContext.CurrentStateId rather than by the state machine holding a transition table, which
	is the whole reason StateMachine.lua stays movement-agnostic -- a state that needs a restricted
	entry expresses it itself, and adding one never means editing the machine.

	Path is authored from the anchor States/LedgeHanging.lua published rather than from a fresh probe;
	see ParkourContext.LedgeAnchorPosition's own header for why the probe cannot see the edge the
	character is already holding.

	WHERE THE CLIMB ENDS IS MEASURED, NOT DERIVED. The end position used to be the anchor plus one
	authored step along the climb direction, at the anchor's own height -- which is only correct when the
	top of the ledge is a flat plane continuing back from the lip at exactly the height the lip was found
	at. Real geometry rarely is: a parapet has a lower walkway behind it, a stepped roof rises behind its
	edge, a sloped roof's lip is its lowest point, and a railing has nothing behind it at that height at
	all. In each of those the derived position was somewhere the character could not stand -- floating
	over the walkway, buried in the step, hovering off the slope -- and the kinematic path put them there
	exactly, because that is what kinematic means.

	So Enter now asks EnvironmentProbe.FindStandSurface for the real surface behind the lip and ends
	there. The derived position survives as the fallback for when nothing is measurable back there (a
	railing over open air), which is the honest answer rather than refusing a climb the player has
	already committed to.

	Exit momentum is deliberately low (ParkourConstants.Ledge.ClimbExitSpeed): a climb is the SLOW way
	up. The fast way was to not fall short in the first place -- keeping the two clearly separated in
	value is what makes a well-executed jump feel better than a recovered one.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

local EnvironmentProbe = require(script.Parent.Parent.EnvironmentProbe)
local InputBuffer = require(script.Parent.Parent.InputBuffer)
local StateSupport = require(script.Parent.StateSupport)

type ParkourContext = ParkourTypes.ParkourContext

local LEDGE = ParkourConstants.Ledge

local startCFrame = CFrame.identity
local controlPoint = Vector3.zero
local endPosition = Vector3.zero
local facing = Vector3.new(0, 0, -1)

local LedgeClimbing: ParkourTypes.StateDefinition = {
	Id = "LedgeClimbing",
	Priority = 220,
	Drive = "Kinematic",
	Probes = { Ground = true },
	Reports = "LedgeClimb",
	Committed = true,

	CanEnter = function(context: ParkourContext): (boolean, string?)
		if context.CurrentStateId ~= "LedgeHanging" then
			return false, "NotHanging"
		end
		if context.LedgeAnchorPosition == nil then
			return false, "NoLedgeAnchor"
		end
		-- THE CLIMB IS AN ANSWER TO AN INPUT, AND THIS PREDICATE HAS TO SAY SO.
		--
		-- Without this check the two checks above are the whole condition -- and they are both true on
		-- the very first frame of a hang. This state outranks LedgeHanging (220 > 210), and a hang is
		-- interruptible, so the machine's pre-emption pass promoted every grab straight into a climb one
		-- frame after it started. The hang was unreachable for longer than a single frame: what looked
		-- like "the ledge system automatically pulls you up" was this, not LedgeHanging.Update, which
		-- correctly requires a jump and never got the chance to run twice.
		--
		-- StateSupport.JumpQueued rather than InputBuffer.PeekJump directly: it is the exact predicate
		-- LedgeHanging.Update tests before returning "LedgeClimbing", so the two routes into this state
		-- cannot disagree about what counts as asking to climb (it also honors CombatClient's jump
		-- suppression, which a bare buffer read would miss). Peek, never Consume -- CanEnter is
		-- contractually pure and the debug overlay calls it on a timer (see InputBuffer.lua's own
		-- Peek/Consume header); LedgeClimbing.Enter below does the consuming.
		if not StateSupport.JumpQueued(context) then
			return false, "NoClimbInput"
		end
		return true, nil
	end,

	Enter = function(context: ParkourContext): ()
		InputBuffer.ConsumeJump(context.Now)
		context.AnimationVariant = "Climb"

		local rootPart = context.RootPart
		startCFrame = rootPart.CFrame
		local anchor = context.LedgeAnchorPosition or rootPart.Position
		local normal = context.LedgeAnchorNormal or ParkourMath.Flatten(rootPart.CFrame.LookVector)
		-- The character hangs facing INTO the wall, so the direction they climb toward is the opposite
		-- of the wall's outward normal.
		facing = ParkourMath.SafeUnit(-ParkourMath.Flatten(normal), Vector3.new(0, 0, -1))

		local footOffset = EnvironmentProbe.GetFootOffset()
		-- THE MEASURED SURFACE. Standing on top, a step in from the lip -- same reasoning as
		-- States/Mantling.lua's own end position: ending balanced on the edge itself puts half the
		-- character over the drop. The step is chosen BY the probe (it walks outward until it finds
		-- somewhere standable with headroom) rather than authored, and the height comes from the surface
		-- it actually found rather than from the lip.
		local found, surfacePosition = EnvironmentProbe.FindStandSurface(anchor, facing, context.Now)
		if found then
			endPosition = surfacePosition + Vector3.new(0, footOffset, 0)
		else
			-- Nothing measurable behind the lip. Fall back to the derived position -- see this file's
			-- header for why a climb already committed to is not refused over it.
			endPosition = anchor + facing * LEDGE.ClimbInsetMin + Vector3.new(0, footOffset, 0)
		end

		-- Rise first, then step forward: the control point sits above the START, which is what makes a
		-- climb read as hauling yourself up a face rather than arcing over it like a vault. Its height
		-- clears whichever is higher, the lip or the surface being climbed onto -- a step up behind the
		-- edge would otherwise be arced straight into.
		local clearanceY = math.max(anchor.Y, endPosition.Y - footOffset) + footOffset + 0.6
		controlPoint = Vector3.new(startCFrame.Position.X, clearanceY, startCFrame.Position.Z)
	end,

	Update = function(context: ParkourContext): ParkourTypes.TransitionResult
		local alpha = math.clamp(context.StateElapsed / math.max(LEDGE.ClimbDurationSeconds, 1e-3), 0, 1)
		local eased = ParkourMath.TraversalEase(alpha)
		local position = ParkourMath.TraversalPoint(startCFrame.Position, controlPoint, endPosition, eased)

		local motor = context.Motor
		motor.Mode = "Kinematic"
		motor.TargetCFrame = CFrame.lookAt(position, position + facing)
		motor.DesiredSpeed = 0

		if alpha < 1 then
			return nil
		end
		return if context.Ground.Grounded then StateSupport.ResolveGroundedState(context) else "Falling"
	end,

	Exit = function(context: ParkourContext): ()
		context.AnimationVariant = nil
		context.LedgeAnchorPosition = nil
		context.LedgeAnchorNormal = nil
		context.Momentum = LEDGE.ClimbExitSpeed
		StateSupport.HandOff(context, facing * LEDGE.ClimbExitSpeed - Vector3.new(0, 4, 0))
	end,
}

return LedgeClimbing
