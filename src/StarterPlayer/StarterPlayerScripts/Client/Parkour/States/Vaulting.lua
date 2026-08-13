--!strict
--[[
	States/Vaulting.lua

	Owns: getting over an obstacle -- both the quick hop (knee-to-waist) and the full hands-down vault
	(waist-to-chest). One state rather than two because the two differ only in duration, momentum cost
	and which animation plays; the path, the commitment and the exit are identical, and splitting them
	would duplicate the traversal code to express a difference that is entirely data.

	WHY KINEMATIC. A vault has to end on the far side of the thing it claimed it would clear. Driving
	it with velocity and hoping the arc works out fails in exactly the cases players notice -- clipping
	the lip, landing on top instead of past, catching a corner -- so the root is anchored and CFrame-
	driven along a quadratic Bezier whose control point sits above the obstacle's top edge. The result
	is an arc that is guaranteed to clear, at the cost of a few hundred milliseconds where physics does
	not apply. ParkourMotor.Apply's own header covers the anchoring technique and its precedent in this
	codebase.

	Committed, so nothing can steal the character mid-traversal. The one thing that CAN cut it short is
	the framework itself handing the body to combat (ParkourController checks that before the machine
	runs at all), which is correct: being hit mid-vault should ragdoll you, not finish the vault.

	Exit velocity is the traversal's own direction at the retained fraction of entry momentum, floored
	at ParkourConstants.Obstacle.ExitMinSpeed -- landing a vault into a dead stop reads as a bug rather
	than as a cost, no matter what the retain fraction says.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

local EnvironmentProbe = require(script.Parent.Parent.EnvironmentProbe)
local StateSupport = require(script.Parent.StateSupport)

type ParkourContext = ParkourTypes.ParkourContext

local OBSTACLE = ParkourConstants.Obstacle

-- The authored path for the traversal in progress, captured once at Enter. Captured rather than
-- re-derived per frame on purpose: the probe results keep updating underneath (the character is
-- moving), and a path that re-derived itself every frame would chase its own tail and never converge
-- on a landing point.
local startCFrame = CFrame.identity
local controlPoint = Vector3.zero
local endPosition = Vector3.zero
local travelDirection = Vector3.zero
local durationSeconds = OBSTACLE.VaultDurationSeconds
local retainFraction = OBSTACLE.VaultExitRetainFraction
local cooldownUntil = 0
local variant = "Vault"

local Vaulting: ParkourTypes.StateDefinition = {
	Id = "Vaulting",
	Priority = 150,
	Drive = "Kinematic",
	Probes = { Ground = true, Obstacle = true },
	Reports = "Vault",
	Committed = true,

	CanEnter = function(context: ParkourContext): (boolean, string?)
		if context.Now < cooldownUntil then
			return false, "VaultCooldown"
		end
		if not context.Assists.AutoVault then
			return false, "AutoVaultDisabled"
		end
		if not StateSupport.WithinTraversalRange(context) then
			return false, "ObstacleOutOfRange"
		end
		-- LIVE check, not the frozen ObstacleProbe.TravelDirection -- see Mantling.CanEnter's identical
		-- gate and StateSupport.IsMovingToward's own header for why this has to read current input
		-- rather than trust that the obstacle's cached geometry still describes where the player is
		-- headed.
		if
			not StateSupport.IsMovingToward(
				StateSupport.TravelDirection(context),
				context.Obstacle.Normal,
				OBSTACLE.MaxApproachAngleDegrees
			)
		then
			return false, "NotFacingObstacle"
		end
		local classification = StateSupport.ClassifyObstacle(context)
		if classification.Action ~= "Vault" and classification.Action ~= "Hop" then
			-- Surface the classifier's own reason verbatim rather than a generic refusal -- this is the
			-- string the debug overlay shows, and "TooTall" or "NoLandingSpace" is the whole answer to
			-- "why didn't it vault," where "CannotVault" would be no answer at all.
			return false, classification.Reason
		end
		return true, nil
	end,

	Enter = function(context: ParkourContext): ()
		local classification = StateSupport.ClassifyObstacle(context)
		local isHop = classification.Action == "Hop"
		variant = if isHop then "Hop" else "Vault"
		durationSeconds = if isHop then OBSTACLE.HopDurationSeconds else OBSTACLE.VaultDurationSeconds
		retainFraction = if isHop then OBSTACLE.HopExitRetainFraction else OBSTACLE.VaultExitRetainFraction
		context.AnimationVariant = variant

		local rootPart = context.RootPart
		startCFrame = rootPart.CFrame
		-- The FROZEN direction the probe actually cast along to find this obstacle -- see
		-- Mantling.Enter's identical read and ObstacleProbe.TravelDirection's own header. Falls back to
		-- a live read only in the defensive case where the probe field is somehow still zero.
		travelDirection = ParkourMath.SafeUnit(context.Obstacle.TravelDirection, StateSupport.TravelDirection(context))

		local probe = context.Obstacle
		-- Distance from the root's centre down to the soles, so the path can be authored in terms of
		-- where the FEET need to be and converted once. EnvironmentProbe already computes this from the
		-- live rig (half the root's height plus hip height), so it is correct for any avatar scale
		-- rather than calibrated to one.
		local footOffset = EnvironmentProbe.GetFootOffset()
		local depth = if probe.Depth == math.huge then OBSTACLE.VaultMaxDepth else probe.Depth

		-- Where the character ends up: past the far edge, with the feet level with the obstacle's top
		-- surface. Landing slightly high is deliberate and self-correcting -- the hand-off in Exit adds
		-- a downward component, so the body settles onto whatever is actually below, whether that is
		-- ground level, a step, or a drop the character now falls down.
		endPosition = probe.TopPosition
			+ travelDirection * (depth + OBSTACLE.VaultExitForwardStuds)
			+ Vector3.new(0, footOffset, 0)
		-- The arc's apex: above the obstacle's top edge, high enough to clear the lip with room to
		-- spare. Placed relative to the TOP rather than to either endpoint so the arc's height scales
		-- with the obstacle instead of with how fast the character happened to be going.
		controlPoint = probe.TopPosition + travelDirection * 0.2 + Vector3.new(0, footOffset + 1.2, 0)
	end,

	Update = function(context: ParkourContext): ParkourTypes.TransitionResult
		local alpha = math.clamp(context.StateElapsed / math.max(durationSeconds, 1e-3), 0, 1)
		local eased = ParkourMath.TraversalEase(alpha)
		local position = ParkourMath.TraversalPoint(startCFrame.Position, controlPoint, endPosition, eased)

		local motor = context.Motor
		motor.Mode = "Kinematic"
		motor.TargetCFrame = CFrame.lookAt(position, position + travelDirection)
		motor.DesiredSpeed = context.Momentum

		if alpha < 1 then
			return nil
		end
		return if context.Ground.Grounded then StateSupport.ResolveGroundedState(context) else "Falling"
	end,

	Exit = function(context: ParkourContext): ()
		cooldownUntil = context.Now + OBSTACLE.CooldownSeconds
		context.AnimationVariant = nil
		context.Momentum = ParkourMath.ExitMomentum(context.Momentum, retainFraction, OBSTACLE.ExitMinSpeed)
		-- Hand back with the vault's own direction and speed, plus a small downward component so the
		-- character settles onto the far side rather than floating off the top of the arc.
		StateSupport.HandOff(
			context,
			ParkourMath.SafeUnit(ParkourMath.Flatten(travelDirection), Vector3.zero) * context.Momentum
				- Vector3.new(0, 6, 0)
		)
	end,
}

return Vaulting
