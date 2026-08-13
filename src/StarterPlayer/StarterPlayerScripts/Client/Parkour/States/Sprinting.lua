--!strict
--[[
	States/Sprinting.lua

	Owns: grounded movement with sprint engaged. See Walking.lua's header for why this is its own
	state rather than a flag on that one.

	Sprint ENGAGEMENT is not decided here. Client/Combat/CombatClient.lua remains the owner of sprint
	-- it holds the sprint remotes, the server-side WalkSpeed tier, the hold-vs-toggle preference and
	the Autorun setting -- and pushes the resulting boolean into this framework through
	ParkourController.SetSprinting. This state only reads it. Duplicating the engagement logic here
	would mean two systems deciding whether a player is sprinting, which is precisely the kind of
	split ownership that produces a character sprinting according to one system and walking according
	to the other.

	Requests wall probes on top of Walking's set: wall-running is only reachable from a sprint, so
	this is the state that has to keep the walls fresh for WallRunning.CanEnter to pre-empt off.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

local StateSupport = require(script.Parent.StateSupport)

type ParkourContext = ParkourTypes.ParkourContext

local Sprinting: ParkourTypes.StateDefinition = {
	Id = "Sprinting",
	Priority = 30,
	Drive = "Humanoid",
	Probes = { Ground = true, Obstacle = true, Walls = true },

	CanEnter = function(context: ParkourContext): (boolean, string?)
		if not context.Ground.Grounded then
			return false, "NotGrounded"
		end
		if not context.SprintHeld then
			return false, "SprintNotEngaged"
		end
		if not StateSupport.HasMoveIntent(context) then
			return false, "NoMoveIntent"
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
		if resolved ~= "Sprinting" then
			return resolved
		end
		return nil
	end,
}

return Sprinting
