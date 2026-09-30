--!strict
--[[
	GrabHoldPose.lua

	Owns: the two per-client halves of what a held grab LOOKS like, for every hold in view --
	  * the HOLDER'S gripping arm kept exactly where the server posed it, and
	  * the VICTIM'S two hands up on the holder's wrist, clawing at the grip.

	THE VICTIM IS WELDED TO THE HOLDER'S HAND (Shared/Grab/GrabRig.lua), and the server poses that arm
	through its shoulder C0. What C0 cannot do is stop an animation: every AnimationTrack writes
	Motor6D.Transform on top of C0, so the idle clip, a walk or run cycle, or an authored AttackerAnimation
	would swing the arm -- and the victim welded to its hand -- around with it. So this module writes the
	whole chain from the holder's root to that hand (GrabRig.HoldJoints: the torso joints as well as the
	arm's, since a stride moves the torso the arm hangs from) back to identity, twice a frame -- see
	unbind's comment -- on every client. The legs keep animating; the hand does not move relative to the
	root. Transform does not replicate, which is Shared/Vessel/VesselArmPose.lua's header's whole argument
	for why a per-client pose runs on every client rather than once. GrabSystem pins the same chain on
	the server.

	The victim's hands are the other half: IK (VesselArmPose.ApplyHand) onto either side of the holder's
	hand part, which this module finds through the hold's own Weld (its Part0 is that hand). Relative to
	the real hand, so it is right in every hold mode and on any rig. A move that authors a VictimAnimation
	gets the clip instead (GrabSystem plays it; this module stands down on that body).

	NO REMOTE. GrabSystem tags the two Models for exactly the length of a hold (GrabConstants.Hold.
	HolderTag/HeldTag) and says which arm is holding in an Attribute. Tags and Attributes replicate for
	free, so this learns about every hold on the server -- a bot's included -- the way GuardStrainPose
	learns about a cracking guard. A tag coming off is the whole release; the server puts the C0 back.

	ZERO IDLE COST, GuardStrainPose's rule: the RenderStep binding exists only while something is tagged.

	Does not own: the hold, the weld or the arm's pose (GrabSystem / GrabRig, on the server), or the IK
	solve (VesselArmPose).
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GrabConstants = require(ReplicatedStorage.Shared.Grab.GrabConstants)
local GrabRig = require(ReplicatedStorage.Shared.Grab.GrabRig)
local Logger = require(ReplicatedStorage.Shared.Logger)
local Trove = require(ReplicatedStorage.Shared.Trove)
local VesselArmPose = require(ReplicatedStorage.Shared.Vessel.VesselArmPose)

local logger = Logger.scope("GrabHoldPose")

local GrabHoldPose = {}

local HOLD = GrabConstants.Hold
local POSE = GrabConstants.Pose
local RENDER_STEP_NAME = "GrabHoldPose"
-- Above Character (the animation step) for VesselArmPose's reason, and above GuardStrainPose's +2: a
-- holding attacker whose guard is also cracking keeps the arm the victim hangs from where it is.
local RENDER_PRIORITY = Enum.RenderPriority.Character.Value + 3

-- Only ApplyHand is used, so the station-grip half of the config is inert -- there is no station.
local poser = VesselArmPose.New({
	LeftGrip = "",
	RightGrip = "",
	FallbackGripHalfWidth = 0,
	FallbackGripMaxHalfWidth = 0,
	ElbowPoleSign = POSE.ElbowPoleSign,
	MaxReachFraction = POSE.MaxReachFraction,
})

-- Per tagged body, the lookups resolved once rather than every frame. nil = not resolved yet (the
-- Attribute or the weld may replicate a frame after the tag).
type HolderEntry = { Joints: { Motor6D }? }
type HeldEntry = { Weld: Weld? }

local holders: { [Model]: HolderEntry } = {}
local held: { [Model]: HeldEntry } = {}

local started = false
local bound = false
local preSimulation: RBXScriptConnection? = nil
local trove = Trove.New()

-- Holder: pin the posed arm AND the torso chain it hangs from (GrabRig.HoldJoints -- the run and walk
-- cycles move the torso too, and the hand rides it). False drops the entry (no such arm on this rig --
-- the server fell back to root-to-root and set no ArmAttribute, or the rig is going away).
local function poseHolder(model: Model, entry: HolderEntry): boolean
	local joints = entry.Joints
	if not joints then
		local side = model:GetAttribute(HOLD.ArmAttribute)
		if side ~= "Right" and side ~= "Left" then
			-- Not replicated yet, or a fallback hold: keep the entry, try again next frame.
			return model.Parent ~= nil
		end
		local root = model.PrimaryPart
		local holdJoints = if root
			then GrabRig.HoldJoints(model, root, if side == "Left" then "Left" else "Right")
			else nil
		if not holdJoints then
			return false
		end
		joints = holdJoints
		entry.Joints = joints
	end
	for _, joint in joints :: { Motor6D } do
		if joint.Parent == nil then
			return false
		end
		joint.Transform = CFrame.identity
	end
	return true
end

local function findWeld(model: Model): Weld?
	for _, descendant in model:GetDescendants() do
		if descendant.Name == HOLD.WeldName and descendant:IsA("Weld") then
			return descendant
		end
	end
	return nil
end

-- Victim: both hands onto either side of the holder's hand part, a little way up from its grip end.
local function poseHeld(model: Model, entry: HeldEntry): boolean
	if model.Parent == nil then
		return false
	end
	if model:GetAttribute(HOLD.VictimAnimatedAttribute) == true then
		-- The authored clip owns these arms. Kept tracked (the Attribute is read live), never posed.
		return true
	end
	local weld = entry.Weld
	if not weld or weld.Parent == nil then
		weld = findWeld(model)
		entry.Weld = weld
	end
	if not weld then
		-- Not replicated yet: keep the entry, look again next frame.
		return true
	end
	local hand = weld.Part0
	if not hand or hand.Parent == nil then
		return true
	end
	local half = hand.Size * 0.5
	local up = -half.Y + hand.Size.Y * POSE.VictimHandAlongArm
	local out = half.X + POSE.VictimHandClearance
	local handCFrame = hand.CFrame
	local posedLeft = poser.ApplyHand(model, "Left", handCFrame * Vector3.new(-out, up, 0))
	local posedRight = poser.ApplyHand(model, "Right", handCFrame * Vector3.new(out, up, 0))
	return posedLeft or posedRight
end

-- TWO PINS PER FRAME. The render-step pin (RENDER_PRIORITY, after the character step) decides what is
-- DRAWN. The PreSimulation pin fires after the frame's animation update and before the physics step:
-- the holder's own client simulates the held body (it is part of the holder's assembly), and without
-- this second pin it stepped that body off the arm and torso the run cycle had just swung, even though
-- the arm it drew was still.
local function unbind(): ()
	if bound then
		RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
		bound = false
	end
	local connection = preSimulation
	if connection then
		connection:Disconnect()
		preSimulation = nil
	end
end

local function pinHolders(): ()
	for model, entry in holders do
		if not poseHolder(model, entry) then
			holders[model] = nil
		end
	end
end

local function step(_deltaTime: number): ()
	pinHolders()
	for model, entry in held do
		if not poseHeld(model, entry) then
			held[model] = nil
		end
	end
	if bound and next(holders) == nil and next(held) == nil then
		unbind()
	end
end

local function bindIfNeeded(): ()
	if bound then
		return
	end
	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, step)
	preSimulation = RunService.PreSimulation:Connect(pinHolders)
	bound = true
end

-- Hands a victim's arms back to their animation. A clip that drives the joint rewrites Transform next
-- frame anyway; this is for a rig nothing animates (a debug dummy), whose arms would otherwise stay up.
-- The holder's arm needs no such thing: the server restores its C0, and the Transform we pinned is
-- identity, which is exactly an unanimated joint's own.
local function releaseArm(model: Model, side: GrabRig.Side): ()
	local chain = GrabRig.ArmChain(model, side)
	if chain then
		for _, joint in chain.Joints do
			joint.Transform = CFrame.identity
		end
	end
end

local function releaseVictimArms(model: Model): ()
	releaseArm(model, "Left")
	releaseArm(model, "Right")
end

local function onHolderTagged(instance: Instance): ()
	if instance:IsA("Model") then
		holders[instance] = { Joints = nil }
		bindIfNeeded()
	end
end

local function onHeldTagged(instance: Instance): ()
	if instance:IsA("Model") then
		held[instance] = { Weld = nil }
		bindIfNeeded()
	end
end

local function onHolderUntagged(instance: Instance): ()
	holders[instance :: any] = nil
end

local function onHeldUntagged(instance: Instance): ()
	if not instance:IsA("Model") or held[instance] == nil then
		return
	end
	held[instance] = nil
	if instance:GetAttribute(HOLD.VictimAnimatedAttribute) ~= true then
		releaseVictimArms(instance)
	end
end

-- Lifecycle ------------------------------------------------------------------------------------------

function GrabHoldPose.Start(): ()
	if started then
		return
	end
	started = true
	trove:Connect(CollectionService:GetInstanceAddedSignal(HOLD.HolderTag), onHolderTagged)
	trove:Connect(CollectionService:GetInstanceRemovedSignal(HOLD.HolderTag), onHolderUntagged)
	trove:Connect(CollectionService:GetInstanceAddedSignal(HOLD.HeldTag), onHeldTagged)
	trove:Connect(CollectionService:GetInstanceRemovedSignal(HOLD.HeldTag), onHeldUntagged)
	for _, instance in CollectionService:GetTagged(HOLD.HolderTag) do
		onHolderTagged(instance)
	end
	for _, instance in CollectionService:GetTagged(HOLD.HeldTag) do
		onHeldTagged(instance)
	end
	logger:info("GrabHoldPose started")
end

function GrabHoldPose.Stop(): ()
	trove:Clean()
	table.clear(holders)
	table.clear(held)
	unbind()
	started = false
end

return GrabHoldPose
