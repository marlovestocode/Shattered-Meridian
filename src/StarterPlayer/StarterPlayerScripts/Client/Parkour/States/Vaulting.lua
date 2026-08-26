--!strict
--[[
	States/Vaulting.lua

	Owns: getting over an obstacle -- both the quick hop (knee-to-waist) and the full hands-down vault
	(waist-to-chest). One state rather than two because the two differ only in duration, momentum cost
	and which animation plays; the path, the commitment and the exit are identical, and splitting them
	would duplicate the traversal code to express a difference that is entirely data.

	WHY KINEMATIC. A vault has to end on the far side of the thing it claimed it would clear. Driving
	it with velocity and hoping the arc works out fails in exactly the cases players notice -- clipping
	the lip, landing on top instead of past, catching a corner -- so the root is driven by a rigid
	(RigidityEnabled = true) AlignPosition along a quadratic Bezier whose control point sits above the
	obstacle's top edge. The result is an arc that is guaranteed to clear, at the cost of a few hundred
	milliseconds where ordinary collision response does not apply to the ROOT's own position (the rig
	stays unanchored and real physics still applies to everything else, which is what lets this
	traversal replicate to other clients the same way ordinary walking does). ParkourMotor.Apply's own
	header covers the rigid-constraint technique and why it replaced an anchored CFrame write.

	Committed, so nothing can steal the character mid-traversal. The one thing that CAN cut it short is
	the framework itself handing the body to combat (ParkourController checks that before the machine
	runs at all), which is correct: being hit mid-vault should ragdoll you, not finish the vault.

	Exit velocity is the traversal's own direction at the retained fraction of entry momentum, floored
	at ParkourConstants.Obstacle.ExitMinSpeed -- landing a vault into a dead stop reads as a bug rather
	than as a cost, no matter what the retain fraction says.

	The approach gate, the path preamble, the per-frame drive and the hand-off are all shared with
	States/Mantling.lua through StateSupport -- see Mantling's own header. What is left here is the
	arc's geometry and the hop/vault data split, which is the whole of what makes this state itself.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

local EnvironmentProbe = require(script.Parent.Parent.EnvironmentProbe)
local StateSupport = require(script.Parent.StateSupport)

type ParkourContext = ParkourTypes.ParkourContext

local OBSTACLE = ParkourConstants.Obstacle

local path = StateSupport.NewTraversalPath()
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
		-- Travel AND facing both have to agree the obstacle is ahead -- see StateSupport.ApproachGate's
		-- own header. This is what stops a vault firing backward off a shift-locked backpedal.
		local approaching, approachReason = StateSupport.ApproachGate(context)
		if not approaching then
			return false, approachReason
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

		StateSupport.BeginTraversal(context, path)

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
		path.EndPosition = probe.TopPosition
			+ path.TravelDirection * (depth + OBSTACLE.VaultExitForwardStuds)
			+ Vector3.new(0, footOffset, 0)
		-- The arc's apex: above the obstacle's top edge, high enough to clear the lip with room to
		-- spare. Placed relative to the TOP rather than to either endpoint so the arc's height scales
		-- with the obstacle instead of with how fast the character happened to be going.
		path.ControlPoint = probe.TopPosition + path.TravelDirection * 0.2 + Vector3.new(0, footOffset + 1.2, 0)
	end,

	Update = function(context: ParkourContext): ParkourTypes.TransitionResult
		return StateSupport.DriveTraversal(context, path, durationSeconds)
	end,

	Exit = function(context: ParkourContext): ()
		cooldownUntil = context.Now + OBSTACLE.CooldownSeconds
		context.AnimationVariant = nil
		-- A harder settle than a mantle's: this ends still carrying an arc's worth of forward speed past
		-- a lip, so the body has further to come down onto whatever the far side actually is.
		StateSupport.TraversalHandOff(context, path, retainFraction, 6)
	end,
}

return Vaulting
