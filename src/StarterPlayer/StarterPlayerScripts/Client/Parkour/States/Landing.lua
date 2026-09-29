--!strict
--[[
	States/Landing.lua

	Owns: the moment of ground contact -- applying the momentum cost of the fall, and holding briefly
	for a hard one.

	Three landings, three behaviors, straight from ParkourConstants.Fall:
	  * Soft   -- full momentum, out within LandingHoldSeconds. The design's "small falls should
	              transition directly into normal movement": the player should not be able to tell a
	              state was entered at all.
	  * Medium -- a small momentum cost and the same brief hold. A visible beat, no loss of control.
	  * Hard   -- a real recovery window (HardLandingRecoverySeconds) and most of the momentum gone.
	              This is the only landing that takes anything from the player.

	CanEnter always refuses. This state is reachable ONLY by States/Falling.lua explicitly handing off
	to it (route 1 in StateMachine.lua, which does not consult CanEnter), because "should I be
	landing" is not a question that can be answered from the context alone -- it depends on having
	just been falling, and on the severity Falling computed. Refusing here is what stops the state
	machine from speculatively entering a landing for a character who merely happens to be standing on
	the ground. The refusal reason is surfaced verbatim by the debug overlay, so this reads as a
	deliberate design decision there rather than as a state that mysteriously never activates.

	Combat interaction: the hard-landing hold does NOT lock out attacks. It costs momentum and plays a
	recovery beat, but CombatSystem's own action gates are untouched by this framework -- a player who
	lands hard can still swing, block or parry immediately. The design asked for landing to "interact
	with combat so attacks, evades, slides, or other actions can potentially be performed immediately
	after landing," and taking the character's actions away would have been the opposite of that.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

local StateSupport = require(script.Parent.StateSupport)

type ParkourContext = ParkourTypes.ParkourContext

local FALL = ParkourConstants.Fall

local Landing: ParkourTypes.StateDefinition = {
	Id = "Landing",
	Priority = 90,
	Drive = "Humanoid",
	Probes = { Ground = true, Obstacle = true },

	CanEnter = function(): (boolean, string?)
		-- See the file header: reachable only via Falling's explicit hand-off.
		return false, "EnteredFromFallOnly"
	end,

	Enter = function(context: ParkourContext): ()
		local severity = context.LandingSeverity or "Soft"
		local retain = if severity == "Hard"
			then FALL.HardLandingRetainFraction
			elseif severity == "Medium" then FALL.MediumLandingRetainFraction
			else FALL.SoftLandingRetainFraction
		context.Momentum *= retain
	end,

	Update = function(context: ParkourContext): ParkourTypes.TransitionResult
		StateSupport.ApplyGroundLocomotion(context)

		-- Bounced back into the air (landed on a slope and slid off, or was launched by something).
		-- Falling re-seeds its own apex, so nothing is lost by leaving early.
		if not context.Ground.Grounded then
			return "Falling"
		end

		local severity = context.LandingSeverity or "Soft"
		local holdSeconds = if severity == "Hard" then FALL.HardLandingRecoverySeconds else FALL.LandingHoldSeconds
		if context.StateElapsed < holdSeconds then
			return nil
		end
		return StateSupport.ResolveGroundedState(context)
	end,

	Exit = function(context: ParkourContext): ()
		-- Consumed. Clearing it here means a later state can never read a stale severity from a
		-- landing several seconds in the past -- the camera and shake layers both key off this field
		-- and would otherwise re-fire on a transition that had nothing to do with a fall.
		context.LandingSeverity = nil
		context.FallHeight = 0
	end,
}

return Landing
