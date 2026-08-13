--!strict
--[[
	States/Idle.lua

	Owns: standing still on the ground. The framework's resting state and the one it starts in.

	Does nothing at all beyond handing the body to Roblox's own character controller and watching for
	a reason to leave -- which is exactly right: a movement system that runs machinery while the
	player is standing still is a movement system that costs frame time for nothing. The probe
	scheduler leans on this too (EnvironmentProbe skips obstacle/wall/ledge casts entirely while
	stationary), so Idle is also the cheapest frame the whole feature ever produces.

	Leaves for: Falling (walked off something), Walking/Sprinting (input), Sliding (a steep enough
	slope forces one). Everything else -- vault, mantle, wall-run -- pre-empts on its own priority
	without Idle needing to know those exist.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

local StateSupport = require(script.Parent.StateSupport)

type ParkourContext = ParkourTypes.ParkourContext

local Idle: ParkourTypes.StateDefinition = {
	Id = "Idle",
	Priority = 10,
	Drive = "Humanoid",
	-- Ground only. Nothing else is knowable or relevant from a standstill, and asking for more would
	-- defeat the scheduler saving described in the header.
	Probes = { Ground = true },

	CanEnter = function(context: ParkourContext): (boolean, string?)
		if not context.Ground.Grounded then
			return false, "NotGrounded"
		end
		if StateSupport.HasMoveIntent(context) then
			return false, "HasMoveIntent"
		end
		if context.PlanarSpeed >= ParkourConstants.Locomotion.IdleSpeedThreshold then
			return false, "StillMoving"
		end
		return true, nil
	end,

	Update = function(context: ParkourContext): ParkourTypes.TransitionResult
		StateSupport.ApplyGroundLocomotion(context)

		if not context.Ground.Grounded then
			return "Falling"
		end
		-- A slope too steep to stand on takes the character whether they asked or not -- the design's
		-- "prevent players from ... climbing surfaces that are too steep" applied to standing as well
		-- as climbing. Routed through Sliding rather than a bespoke "sliding down a cliff" behavior so
		-- the player still has the slide's steering and can still jump or roll out of it.
		if context.Ground.SlopeAngle >= ParkourConstants.Slope.ForcedSlideAngleDegrees then
			return "Sliding"
		end
		if StateSupport.HasMoveIntent(context) then
			return StateSupport.ResolveGroundedState(context)
		end
		return nil
	end,
}

return Idle
