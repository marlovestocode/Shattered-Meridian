--!strict
--[[
	GrabHoldPose.lua

	Owns: what a grab LOOKS like while it is held -- the attacker's right hand on the victim's collar, and
	the victim's two hands up on that arm -- for every hold in view, on every client.

	MODES. Where the hand goes and where the victim's hands go are per hold mode (collar, head, drag...),
	all of it data in GrabConstants.Modes; the holder's grip arrives already resolved to their own root
	space, and the victim's mode arrives by name. A move that authors a VictimAnimation gets the clip
	instead of the victim-hand pose (GrabSystem plays it; this module simply stands down on that body).

	WHY THE HAND GOES TO THE BODY. Server/Combat/Grab/GrabSystem.lua welds the victim to the attacker's
	ROOT at GrabConstants.Defaults.AttachOffset, so the victim is always in the same place and never
	jitters with an animation. Without this module the attacker's arm simply keeps playing its idle clip at
	their side while a body floats in front of them. This solves the arm onto the body instead, every frame,
	with Shared/Vessel/VesselArmPose.lua's IK (ApplyHand) -- the solver that already puts a pilot's hands on
	a wheel, and every word of its header applies here: Motor6D.Transform is the only channel that beats a
	playing clip, it does not replicate, so every client poses every hold it can see, and it must run
	AFTER the animation step (see RENDER_PRIORITY).

	NO REMOTE. GrabSystem tags the two Models for exactly the length of a hold (GrabConstants.Hold.
	HolderTag/HeldTag) and puts the grip point on the attacker's Model as a Vector3 Attribute in the
	attacker's root space (Hold.GripAttribute). Tags and Attributes replicate for free, so this module
	learns about every hold on the server -- a bot's included -- the same way GuardStrainPose learns about
	a cracking guard. Nothing here decides anything about a hold; a tag coming off is the whole release.

	ZERO IDLE COST, GuardStrainPose's rule: the RenderStep binding exists only while something is tagged.

	Does not own: the hold itself or where the victim is (GrabSystem), the grip placement numbers
	(GrabConstants), or the IK solve (VesselArmPose).
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GrabConstants = require(ReplicatedStorage.Shared.Grab.GrabConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local Trove = require(ReplicatedStorage.Shared.Trove)
local VesselArmPose = require(ReplicatedStorage.Shared.Vessel.VesselArmPose)

local logger = Logger.scope("GrabHoldPose")

local GrabHoldPose = {}

local HOLD = GrabConstants.Hold
local POSE = GrabConstants.Pose
local RENDER_STEP_NAME = "GrabHoldPose"
-- Above Character (the animation step) for VesselArmPose's reason, and above GuardStrainPose's +2: a
-- holding attacker whose guard is also cracking keeps their hand on the victim, since a hold is the
-- bigger commitment of the two and the strain composes onto whatever it finds anyway.
local RENDER_PRIORITY = Enum.RenderPriority.Character.Value + 3

type Role = "Holder" | "Held"

-- Only ApplyHand is used, so the station-grip half of the config is inert -- there is no station.
local poser = VesselArmPose.New({
	LeftGrip = "",
	RightGrip = "",
	FallbackGripHalfWidth = 0,
	FallbackGripMaxHalfWidth = 0,
	ElbowPoleSign = POSE.ElbowPoleSign,
	MaxReachFraction = POSE.MaxReachFraction,
})

-- A Model can in principle be both (a victim who was holding someone is released first, server-side,
-- so not in practice) -- keyed per role so one tag coming off never drops the other's pose.
local holders: { [Model]: true } = {}
local held: { [Model]: true } = {}

local started = false
local bound = false
local trove = Trove.New()

-- Hands an arm back to its animation. A clip that drives the joint rewrites Transform next frame anyway;
-- this is for a rig nothing animates (a dummy with no Animate script), whose arm would otherwise stay
-- raised forever at the last pose written.
local function releaseArm(model: Model, side: VesselArmPose.Side): ()
	local torso = model:FindFirstChild("Torso")
	local r6Shoulder = if torso then torso:FindFirstChild(side .. " Shoulder") else nil
	if r6Shoulder and r6Shoulder:IsA("Motor6D") then
		r6Shoulder.Transform = CFrame.identity
		return
	end
	for _, name in { side .. "UpperArm", side .. "LowerArm", side .. "Hand" } do
		local part = model:FindFirstChild(name)
		if part then
			for _, child in part:GetChildren() do
				if child:IsA("Motor6D") then
					child.Transform = CFrame.identity
				end
			end
		end
	end
end

local function rootOf(model: Model): BasePart?
	local root = model.PrimaryPart
	if root and root.Parent ~= nil then
		return root
	end
	return nil
end

-- One holder for this frame. False when there is nothing to pose (no grip yet, no root, a rig
-- VesselArmPose cannot solve), which drops the entry rather than retrying the lookups every frame.
local function poseHolder(model: Model): boolean
	local grip = model:GetAttribute(HOLD.GripAttribute)
	local root = rootOf(model)
	if typeof(grip) ~= "Vector3" or not root then
		return false
	end
	return poser.ApplyHand(model, "Right", root.CFrame * grip)
end

-- The victim's hands go where their mode says (GrabConstants.Modes[...].VictimHands) -- unless the
-- move authored a VictimAnimation, which is the author's say over those arms. That case answers true
-- WITHOUT posing, so the entry stays tracked (the Attribute is read live) and the clip plays untouched.
local function poseHeld(model: Model): boolean
	local root = rootOf(model)
	if not root then
		return false
	end
	if model:GetAttribute(HOLD.VictimAnimatedAttribute) == true then
		return true
	end
	local modeName = model:GetAttribute(HOLD.ModeAttribute)
	local hands = GrabConstants.ModeOf(if typeof(modeName) == "string" then modeName else nil).VictimHands
	local rootCFrame = root.CFrame
	local posedLeft = poser.ApplyHand(model, "Left", rootCFrame * hands.Left)
	local posedRight = poser.ApplyHand(model, "Right", rootCFrame * hands.Right)
	return posedLeft or posedRight
end

local function step(_deltaTime: number): ()
	for model in holders do
		if not poseHolder(model) then
			holders[model] = nil
		end
	end
	for model in held do
		if not poseHeld(model) then
			held[model] = nil
		end
	end
	if bound and next(holders) == nil and next(held) == nil then
		RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
		bound = false
	end
end

local function bindIfNeeded(): ()
	if bound then
		return
	end
	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, step)
	bound = true
end

local function track(set: { [Model]: true }, instance: Instance): ()
	if instance:IsA("Model") then
		set[instance] = true
		bindIfNeeded()
	end
end

local function untrack(set: { [Model]: true }, instance: Instance, role: Role): ()
	if not instance:IsA("Model") or set[instance] == nil then
		return
	end
	set[instance] = nil
	if role == "Holder" then
		releaseArm(instance, "Right")
	elseif instance:GetAttribute(HOLD.VictimAnimatedAttribute) ~= true then
		-- A victim whose arms a clip was driving was never posed here -- leave the clip's fade alone.
		releaseArm(instance, "Left")
		releaseArm(instance, "Right")
	end
end

-- Lifecycle ------------------------------------------------------------------------------------------

function GrabHoldPose.Start(): ()
	if started then
		return
	end
	started = true
	trove:Connect(CollectionService:GetInstanceAddedSignal(HOLD.HolderTag), function(instance: Instance)
		track(holders, instance)
	end)
	trove:Connect(CollectionService:GetInstanceRemovedSignal(HOLD.HolderTag), function(instance: Instance)
		untrack(holders, instance, "Holder")
	end)
	trove:Connect(CollectionService:GetInstanceAddedSignal(HOLD.HeldTag), function(instance: Instance)
		track(held, instance)
	end)
	trove:Connect(CollectionService:GetInstanceRemovedSignal(HOLD.HeldTag), function(instance: Instance)
		untrack(held, instance, "Held")
	end)
	for _, instance in CollectionService:GetTagged(HOLD.HolderTag) do
		track(holders, instance)
	end
	for _, instance in CollectionService:GetTagged(HOLD.HeldTag) do
		track(held, instance)
	end
	logger:info("GrabHoldPose started")
end

function GrabHoldPose.Stop(): ()
	trove:Clean()
	table.clear(holders)
	table.clear(held)
	if bound then
		RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
		bound = false
	end
	started = false
end

return GrabHoldPose
