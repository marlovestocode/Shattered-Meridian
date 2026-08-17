--!strict
--[[
	States/Sprinting.lua

	Owns: grounded movement with sprint engaged. See Walking.lua's header for why this is its own
	state rather than a flag on that one.

	Run ENGAGEMENT is not decided here. Client/Movement/RunController.lua owns it -- the key, the
	hold-versus-toggle preference, the Autorun setting and the one remote that tells the server -- and
	ParkourController reads the resulting boolean back out through RunController.IsSprinting() once per
	movement frame, publishing it as ParkourContext.SprintHeld. This state only reads that. Duplicating
	the engagement logic here would mean two systems deciding whether a player is running, which is
	precisely the kind of split ownership that produces a character running according to one system and
	walking according to the other.

	The STAGE (ParkourContext.SprintStage) is a separate question with a separate owner again:
	Server/Systems/RunSystem.lua resolves which of the three gears the player has earned and publishes
	it on the Humanoid. This state does not read it -- States/StateSupport.GroundTargetSpeed does, for
	its target-speed reporting -- but everything downstream of running fast (the slide's entry speed,
	the wall-run's minimum) becomes easier to reach at the upper gears, which is the intent.

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
