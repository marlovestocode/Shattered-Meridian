--!strict
--[[
	States/Mantling.lua

	Owns: pulling the character up ONTO a surface too tall to vault over -- the third band in
	ObstacleClassifier's height ladder, above Step and Hop/Vault.

	Mantling and vaulting are separate states rather than variants of one because they end in
	different places (on top of the obstacle versus past it), they cost different amounts of momentum
	(a mantle is the slow option and takes most of it; a vault is the fast one and keeps most), and
	they have different entry requirements (a mantle needs reach and standing room but no speed at
	all; a vault needs speed and landing room). Almost nothing about the two is actually shared beyond
	"drive the root along a curve," which ParkourMath.TraversalPoint already owns for both.

	No speed requirement, deliberately: a player standing at a wall should be able to climb it. That is
	what makes this state the answer to the design's "larger reachable surfaces might require a mantle
	or climb," and it is why a mantle is reachable from Idle as well as from a sprint.

	Kinematic and Committed for the same reasons as States/Vaulting.lua -- see that file's header.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

local EnvironmentProbe = require(script.Parent.Parent.EnvironmentProbe)
local StateSupport = require(script.Parent.StateSupport)

type ParkourContext = ParkourTypes.ParkourContext

local OBSTACLE = ParkourConstants.Obstacle

local startCFrame = CFrame.identity
local controlPoint = Vector3.zero
local endPosition = Vector3.zero
local travelDirection = Vector3.zero
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
		local classification = StateSupport.ClassifyObstacle(context)
		if classification.Action ~= "Mantle" then
			return false, classification.Reason
		end
		return true, nil
	end,

	Enter = function(context: ParkourContext): ()
		local rootPart = context.RootPart
		startCFrame = rootPart.CFrame
		travelDirection = StateSupport.TravelDirection(context)
		context.AnimationVariant = "Mantle"

		local footOffset = EnvironmentProbe.GetFootOffset()
		local probe = context.Obstacle
		-- Standing ON the top surface, a short step in from the edge so the character is not balanced
		-- on the lip with half a foot over the drop.
		endPosition = probe.TopPosition + travelDirection * 1.1 + Vector3.new(0, footOffset, 0)
		-- The pull-up curve rises first and moves forward second, which is what distinguishes a mantle
		-- from a vault visually: the control point sits almost directly above the START, not above the
		-- obstacle, so the character lifts up the face of the wall and then steps over the top.
		controlPoint = Vector3.new(
			startCFrame.Position.X,
			probe.TopPosition.Y + footOffset + 0.4,
			startCFrame.Position.Z
		) + travelDirection * 0.3
	end,

	Update = function(context: ParkourContext): ParkourTypes.TransitionResult
		local alpha = math.clamp(context.StateElapsed / math.max(OBSTACLE.MantleDurationSeconds, 1e-3), 0, 1)
		local eased = ParkourMath.TraversalEase(alpha)
		local position = ParkourMath.TraversalPoint(startCFrame.Position, controlPoint, endPosition, eased)

		local motor = context.Motor
		motor.Mode = "Kinematic"
		motor.TargetCFrame = CFrame.lookAt(position, position + travelDirection)
		motor.DesiredSpeed = context.Momentum

		if alpha < 1 then
			return nil
		end
		-- Grounded is checked rather than assumed: a mantle onto a narrow ledge can legitimately end
		-- with the character already stepping off it.
		return if context.Ground.Grounded then StateSupport.ResolveGroundedState(context) else "Falling"
	end,

	Exit = function(context: ParkourContext): ()
		cooldownUntil = context.Now + OBSTACLE.CooldownSeconds
		context.AnimationVariant = nil
		context.Momentum =
			ParkourMath.ExitMomentum(context.Momentum, OBSTACLE.MantleExitRetainFraction, OBSTACLE.ExitMinSpeed)
		-- A mantle ends standing, so the hand-off is a gentle forward step rather than the vault's
		-- carried arc -- and a small downward component so the body settles onto the surface it just
		-- climbed rather than hovering a fraction above it.
		StateSupport.HandOff(
			context,
			ParkourMath.SafeUnit(ParkourMath.Flatten(travelDirection), Vector3.zero) * context.Momentum
				- Vector3.new(0, 4, 0)
		)
	end,
}

return Mantling
