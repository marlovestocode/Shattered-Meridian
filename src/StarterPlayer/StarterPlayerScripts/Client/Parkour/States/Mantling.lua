--!strict
--[[
	States/Mantling.lua

	Owns: pulling the character up ONTO a surface too tall to vault over -- the third band in
	ObstacleClassifier's height ladder, above Step and Hop/Vault.

	Mantling and vaulting are separate states rather than variants of one because they end in
	different places (on top of the obstacle versus past it), they cost different amounts of momentum
	(a mantle is the slow option and takes most of it; a vault is the fast one and keeps most), and
	they have different entry requirements (a mantle needs reach and standing room but no speed at
	all; a vault needs speed and landing room).

	What the two DO share is everything around that difference, and it lives in StateSupport rather
	than being written out twice here and in Vaulting.lua: ApproachGate (the travel-and-facing double
	gate), BeginTraversal, DriveTraversal and TraversalHandOff. What is left in this file is the
	geometry -- where the arc ends and where its apex sits -- which is precisely the part that makes a
	mantle a mantle, and which reads as nonsense anywhere but beside the comment describing the shape
	it draws.

	No speed requirement, deliberately: a player standing at a wall should be able to climb it. That is
	what makes this state the answer to the design's "larger reachable surfaces might require a mantle
	or climb," and it is why a mantle is reachable from Idle as well as from a sprint.

	Kinematic and Committed for the same reasons as States/Vaulting.lua -- see that file's header.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

local EnvironmentProbe = require(script.Parent.Parent.EnvironmentProbe)
local StateSupport = require(script.Parent.StateSupport)

type ParkourContext = ParkourTypes.ParkourContext

local OBSTACLE = ParkourConstants.Obstacle

local path = StateSupport.NewTraversalPath()
local cooldownUntil = 0

local Mantling: ParkourTypes.StateDefinition = {
	Id = "Mantling",
	Priority = 145,
	Drive = "Kinematic",
	Probes = { Ground = true, Obstacle = true },
	Reports = "Mantle",
	Committed = true,

	CanEnter = function(context: ParkourContext): (boolean, string?)
		if context.Now < cooldownUntil then
			return false, "MantleCooldown"
		end
		if not StateSupport.WithinTraversalRange(context) then
			return false, "ObstacleOutOfRange"
		end
		-- Travel AND facing both have to agree the obstacle is ahead -- see StateSupport.ApproachGate's
		-- own header for why that is two questions and not one. The refusal reason is forwarded verbatim
		-- because it is what the F6 overlay shows.
		local approaching, approachReason = StateSupport.ApproachGate(context)
		if not approaching then
			return false, approachReason
		end
		local classification = StateSupport.ClassifyObstacle(context)
		if classification.Action ~= "Mantle" then
			return false, classification.Reason
		end
		return true, nil
	end,

	Enter = function(context: ParkourContext): ()
		StateSupport.BeginTraversal(context, path)
		context.AnimationVariant = "Mantle"

		local footOffset = EnvironmentProbe.GetFootOffset()
		local probe = context.Obstacle
		-- Standing ON the top surface, a short step in from the edge so the character is not balanced
		-- on the lip with half a foot over the drop.
		path.EndPosition = probe.TopPosition + path.TravelDirection * 1.1 + Vector3.new(0, footOffset, 0)
		-- The pull-up curve rises first and moves forward second, which is what distinguishes a mantle
		-- from a vault visually: the control point sits almost directly above the START, not above the
		-- obstacle, so the character lifts up the face of the wall and then steps over the top.
		path.ControlPoint = Vector3.new(
			path.StartCFrame.Position.X,
			probe.TopPosition.Y + footOffset + 0.4,
			path.StartCFrame.Position.Z
		) + path.TravelDirection * 0.3
	end,

	Update = function(context: ParkourContext): ParkourTypes.TransitionResult
		return StateSupport.DriveTraversal(context, path, OBSTACLE.MantleDurationSeconds)
	end,

	Exit = function(context: ParkourContext): ()
		cooldownUntil = context.Now + OBSTACLE.CooldownSeconds
		context.AnimationVariant = nil
		-- A mantle ends standing, so the settle is a gentle press down onto the surface it just climbed
		-- rather than the vault's harder correction off the top of a carried arc.
		StateSupport.TraversalHandOff(context, path, OBSTACLE.MantleExitRetainFraction, 4)
	end,
}

return Mantling
