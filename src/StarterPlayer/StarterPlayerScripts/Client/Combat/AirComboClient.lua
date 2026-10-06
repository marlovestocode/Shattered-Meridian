--!strict
--[[
	AirComboClient.lua

	Owns: the local player's FOLLOW as an air combo's attacker -- springing their own body to the slot beside
	the victim's hover, the WASD drift inside it, the assisted facing, and the push-back when the victim
	parries them out. docs/design/air-combat-and-evade.md B2/B5.

	WHY THE ATTACKER'S CLIENT DOES THIS, NOT THE SERVER. A player's body is simulated by their own client; a
	server write to it is silently overwritten (see Server/Combat/AirCombo/AirComboSystem.lua's header). And
	it is the part of Hakuda this design changes on purpose: there, you jump after the victim yourself, which
	makes the follow a timing input that drops under ping. Here the follow is automatic, driven from the
	server-published anchor the moment it arrives, and the victim is pinned server-side -- so the attacker's
	latency barely matters, because the target does not move. The first beat's longer budget
	(AirComboConstants.Timing.FirstContinueSeconds) absorbs the one-RTT late start.

	SPACING STILL EXISTS, and ping cannot cause it: WASD drifts the body inside a DriftRadius disc around the
	slot, and facing is ASSISTED (turned toward the victim at a capped rate), not locked -- so looking or
	drifting away mid-string can whiff. The server audits the distance (SpacingFail) and nothing else.

	STARTS AND STOPS OFF THE ATTRIBUTES, with no remote: AirComboAttackerUntil (on this player's own Humanoid)
	says "you are following", AirComboAnchor says where to. The parkour controller parks itself off the same
	Attribute (ParkourController.resolveCombatOwned), so this never fights its motor.

	Does not own: the combo (AirComboSystem), the victim's hover (the server's), the air presses themselves
	(Client/Combat/AttackInputClient.lua), or any effect (Client/FX/AirComboFX.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local AirComboAttributes = require(ReplicatedStorage.Shared.AirCombo.AirComboAttributes)
local AirComboConstants = require(ReplicatedStorage.Shared.AirCombo.AirComboConstants)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)
local FlightMath = require(ReplicatedStorage.Shared.FlightMath)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local Trove = require(ReplicatedStorage.Shared.Trove)

local ATTRIBUTES = AttributeConstants
local FOLLOW = AirComboConstants.Follow

local logger = Logger.scope("AirComboClient")

local AirComboClient = {}

type Follow = {
	Trove: Trove.TroveInstance,
	Velocity: LinearVelocity,
	Orient: AlignOrientation,
	SpringPosition: Vector3,
	SpringVelocity: Vector3,
	Drift: Vector3,
	Yaw: number,
}

local started = false
local boundHumanoid: Humanoid? = nil
local boundRoot: BasePart? = nil
local follow: Follow? = nil

local function flat(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

local function flatUnit(vector: Vector3, fallback: Vector3): Vector3
	local flattened = flat(vector)
	if flattened.Magnitude < 1e-3 then
		return fallback
	end
	return flattened.Unit
end

local function yawOf(direction: Vector3): number
	return math.atan2(-direction.X, -direction.Z)
end

-- The slot: the same arithmetic AirComboSystem audits against (its slotFor).
local function slotFor(anchor: Vector3, position: Vector3): Vector3
	local toVictim = flatUnit(anchor - position, Vector3.new(0, 0, -1))
	return anchor - toVictim * FOLLOW.StandoffStuds - Vector3.new(0, FOLLOW.BelowStuds, 0)
end

local function beginFollow(humanoid: Humanoid, root: BasePart): Follow
	local trove = Trove.New()

	-- A free body the constraints below drive: the Humanoid's own ground handling would fight a hover.
	humanoid.PlatformStand = true
	-- Shift lock rewrites the root's facing every frame unless something has claimed it (the same truce the
	-- parkour motor uses); the follow's facing assist needs it.
	humanoid:SetAttribute(ATTRIBUTES.ParkourFacingOwned, true)
	trove:Add(function()
		if humanoid.Parent ~= nil then
			humanoid.PlatformStand = false
			humanoid:SetAttribute(ATTRIBUTES.ParkourFacingOwned, false)
		end
	end)

	local attachment = trove:Add(Instance.new("Attachment"))
	attachment.Name = "AirComboFollowAttachment"
	attachment.Parent = root

	local velocity = trove:Add(Instance.new("LinearVelocity"))
	velocity.Name = "AirComboFollowVelocity"
	velocity.Attachment0 = attachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	velocity.ForceLimitMode = Enum.ForceLimitMode.Magnitude
	velocity.MaxForce = FOLLOW.MaxForce
	velocity.VectorVelocity = root.AssemblyLinearVelocity
	velocity.Parent = root

	local orient = trove:Add(Instance.new("AlignOrientation"))
	orient.Name = "AirComboFollowOrientation"
	orient.Mode = Enum.OrientationAlignmentMode.OneAttachment
	orient.Attachment0 = attachment
	orient.MaxTorque = AirComboConstants.Hover.MaxTorque
	orient.Responsiveness = AirComboConstants.Hover.OrientationResponsiveness
	orient.RigidityEnabled = false
	orient.CFrame = root.CFrame.Rotation
	orient.Parent = root

	return {
		Trove = trove,
		Velocity = velocity,
		Orient = orient,
		SpringPosition = root.Position,
		SpringVelocity = root.AssemblyLinearVelocity,
		Drift = Vector3.zero,
		Yaw = yawOf(flatUnit(root.CFrame.LookVector, Vector3.new(0, 0, -1))),
	}
end

local function endFollow(humanoid: Humanoid?, root: BasePart?): ()
	local current = follow
	if not current then
		return
	end
	follow = nil
	current.Trove:Clean()
	-- PARRIED OUT: pushed up and back on the clash, so the victim -- released at the same instant -- lands
	-- first and gets the punish (docs B4). Any other ending just lets the body fall.
	if humanoid and root and root.Parent ~= nil and humanoid:GetAttribute(ATTRIBUTES.AirComboPhase) == "Parried" then
		local back = -flatUnit(root.CFrame.LookVector, Vector3.new(0, 0, -1))
		root.AssemblyLinearVelocity = (back + Vector3.yAxis) * FOLLOW.ClashPushSpeed
	end
end

local function stepFollow(current: Follow, humanoid: Humanoid, root: BasePart, deltaTime: number): ()
	local anchor = humanoid:GetAttribute(ATTRIBUTES.AirComboAnchor)
	if typeof(anchor) ~= "Vector3" then
		return
	end

	-- DRIFT: held movement input moves the body inside the disc around its slot.
	local move = flat(humanoid.MoveDirection)
	local drift = current.Drift + move * FOLLOW.DriftSpeed * deltaTime
	if drift.Magnitude > FOLLOW.DriftRadiusStuds then
		drift = drift.Unit * FOLLOW.DriftRadiusStuds
	end
	current.Drift = drift

	-- THE SPRING toward the slot (FlightMath.SpringStep, unconditionally stable at any frame time), and a
	-- proportional correction from where the spring is to where the body actually is.
	local target = slotFor(anchor, root.Position) + drift
	local position, velocity = current.SpringPosition, current.SpringVelocity
	local x, vx = FlightMath.SpringStep(position.X, velocity.X, target.X, FOLLOW.Frequency, FOLLOW.Damping, deltaTime)
	local y, vy = FlightMath.SpringStep(position.Y, velocity.Y, target.Y, FOLLOW.Frequency, FOLLOW.Damping, deltaTime)
	local z, vz = FlightMath.SpringStep(position.Z, velocity.Z, target.Z, FOLLOW.Frequency, FOLLOW.Damping, deltaTime)
	current.SpringPosition = Vector3.new(x, y, z)
	current.SpringVelocity = Vector3.new(vx, vy, vz)
	current.Velocity.VectorVelocity = current.SpringVelocity
		+ (current.SpringPosition - root.Position) * FOLLOW.CorrectionGain

	-- ASSISTED FACING: turned toward the victim at a capped rate, never snapped.
	local toVictim = flat(anchor - root.Position)
	if toVictim.Magnitude > 1e-3 then
		local desired = yawOf(toVictim.Unit)
		local delta = (desired - current.Yaw + math.pi) % (2 * math.pi) - math.pi
		local maxStep = math.rad(FOLLOW.TurnDegreesPerSecond) * deltaTime
		current.Yaw += math.clamp(delta, -maxStep, maxStep)
	end
	current.Orient.CFrame = CFrame.Angles(0, current.Yaw, 0)
end

local function onHeartbeat(deltaTime: number): ()
	local humanoid = boundHumanoid
	local root = boundRoot
	if not humanoid or not root or root.Parent == nil then
		endFollow(humanoid, root)
		return
	end
	local active = humanoid.Health > 0 and AirComboAttributes.IsAttacker(humanoid)
	local current = follow
	if active and not current then
		current = beginFollow(humanoid, root)
		follow = current
		logger:debug("Air combo follow started")
	elseif not active and current then
		endFollow(humanoid, root)
		return
	end
	if current then
		stepFollow(current, humanoid, root, deltaTime)
	end
end

function AirComboClient.Start(): ()
	if started then
		return
	end
	started = true
	PlayerLifecycle.BindLocalCharacter({
		Scope = "AirComboClient",
		OnCharacter = function(character: Model, humanoid: Humanoid)
			endFollow(boundHumanoid, boundRoot)
			boundHumanoid = humanoid
			-- The bind path, where the root may not have replicated yet: AwaitRoot yields for it (this
			-- callback runs on its own thread -- PlayerLifecycle's contract).
			boundRoot = CharacterUtil.AwaitRoot(character)
		end,
		OnCharacterRemoving = function()
			endFollow(boundHumanoid, boundRoot)
			boundHumanoid = nil
			boundRoot = nil
		end,
	})
	RunService.Heartbeat:Connect(onHeartbeat)
	logger:debug("AirComboClient started")
end

return AirComboClient
