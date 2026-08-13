--!strict
--[[
	States/Walking.lua

	Owns: grounded movement below sprint speed. Structurally identical to Sprinting.lua -- the two are
	separate states rather than one "Grounded" state with a boolean because every consumer downstream
	(the animator's clip selection, the camera's speed FOV, the debug readout, and any future system
	that wants to know whether a player is running) reads the state id, and collapsing them would push
	that distinction into a flag those consumers would each have to remember to check.

	Deliberately thin. All the interesting grounded behavior -- vaulting, sliding, wall-running --
	lives in higher-priority states that pre-empt this one, which is what keeps this file from growing
	into the "basic collection of if-statements" the design rules out.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

local StateSupport = require(script.Parent.StateSupport)

type ParkourContext = ParkourTypes.ParkourContext

local Walking: ParkourTypes.StateDefinition = {
	Id = "Walking",
	Priority = 20,
	Drive = "Humanoid",
	-- Obstacles are requested even at walking pace: the classifier will refuse a vault below
	-- ParkourConstants.Obstacle.VaultMinSpeed anyway, but a walking player still needs mantles to be
	-- detected, and a mantle has no speed requirement at all.
	Probes = { Ground = true, Obstacle = true },

	CanEnter = function(context: ParkourContext): (boolean, string?)
		if not context.Ground.Grounded then
			return false, "NotGrounded"
		end
		if
			not StateSupport.HasMoveIntent(context)
			and context.PlanarSpeed < ParkourConstants.Locomotion.IdleSpeedThreshold
		then
			return false, "NoMovement"
		end
		return true, nil
	end,

	Update = function(context: ParkourContext): ParkourTypes.TransitionResult
		StateSupport.ApplyGroundLocomotion(context)

		if not context.Ground.Grounded then
			return "Falling"
		end
		if context.Ground.SlopeAngle >= ParkourConstants.Slope.ForcedSlideAngleDegrees then
			return "Sliding"
		end
		local resolved = StateSupport.ResolveGroundedState(context)
		if resolved ~= "Walking" then
			return resolved
		end
		return nil
	end,
}

return Walking
