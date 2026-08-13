--!strict
--[[
	States/Jumping.lua

	Owns: the rising half of a jump, and the two forgiveness windows that make jumping feel fair --
	coyote time (jump still legal briefly after walking off an edge) and jump buffering (a jump
	pressed just before landing fires on the landing frame).

	Both assists are honored HERE and nowhere else. InputBuffer.lua owns the windows themselves and
	whether the player has each assist switched on; this state owns the single place they are
	consumed, which is what keeps "the player pressed jump" from being answered differently in three
	places.

	Deliberately hands the actual jump to Roblox's Humanoid whenever the character is genuinely
	grounded -- see StateSupport.TryJump's own header for why that matters beyond tidiness (the
	engine's Jumping transition is what credits Server/Combat/Movement.ComputeGenuineJumpAirborne's
	genuine-jump flag, which gates AirSlam; a jump that bypassed it would silently break that combat
	interaction). The direct-velocity path is used only for the coyote case, where the Humanoid
	refuses to jump because it already believes it is falling.

	Momentum is fully preserved through a jump (ParkourConstants.Jump.MomentumRetainFraction, 1 by
	default): a jump must never be a speed penalty in a momentum system, or the optimal play becomes
	never jumping.

	The minimum-interval guard against a single press producing two launches lives in
	StateSupport.NoteJump/JumpIntervalElapsed rather than here -- see that pair's own header for why
	it has to be shared with the slide-jump and wall-jump launch sites.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

local InputBuffer = require(script.Parent.Parent.InputBuffer)
local StateSupport = require(script.Parent.StateSupport)

type ParkourContext = ParkourTypes.ParkourContext

local JUMP = ParkourConstants.Jump

local Jumping: ParkourTypes.StateDefinition = {
	Id = "Jumping",
	Priority = 70,
	Drive = "Humanoid",
	-- Walls and ledges matter the instant a jump starts rising: a jump into a wall should be able to
	-- become a wall-run, and a jump that falls short should be able to become a ledge grab. Requesting
	-- them here is what lets those states pre-empt during the ascent rather than only after the apex.
	Probes = { Ground = true, Walls = true, Ledge = true, Obstacle = true },

	CanEnter = function(context: ParkourContext): (boolean, string?)
		if not StateSupport.JumpQueued(context) then
			return false, "NoJumpInput"
		end
		if not StateSupport.JumpIntervalElapsed(context.Now) then
			return false, "JumpCooldown"
		end
		if context.Ground.Grounded then
			return true, nil
		end
		if InputBuffer.CoyoteAvailable(context.Now, context.LeftGroundAt) then
			return true, nil
		end
		return false, "AirborneNoCoyote"
	end,

	Enter = function(context: ParkourContext): ()
		-- Consume here, not in CanEnter -- CanEnter is a pure predicate the debug overlay calls on a
		-- timer (InputBuffer.lua's Peek/Consume contract). Enter is the one place a press is spent.
		InputBuffer.ConsumeJump(context.Now)
		StateSupport.NoteJump(context.Now)

		local direction = StateSupport.TravelDirection(context)
		local carried = context.Momentum * JUMP.MomentumRetainFraction
		context.Momentum = carried
		StateSupport.TryJump(context, StateSupport.LaunchPlanarVelocity(direction, carried), JUMP.JumpVelocity)
	end,

	Update = function(context: ParkourContext): ParkourTypes.TransitionResult
		StateSupport.ApplyAirLocomotion(context)

		-- Landed again already (a jump into a low ceiling, or off a one-stud lip). Falling owns the
		-- landing classification, so hand off rather than duplicating it here.
		if context.Ground.Grounded and context.StateElapsed > 0.1 then
			return "Falling"
		end
		-- Past the apex: Falling owns everything downward, including apex tracking for the landing
		-- severity. The small negative threshold rather than <= 0 avoids flickering between the two
		-- states for the frame or two the vertical velocity hovers around zero at the top of an arc.
		if context.VerticalVelocity < -1 then
			return "Falling"
		end
		return nil
	end,
}

return Jumping
