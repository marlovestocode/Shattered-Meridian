--!strict
--[[
	GuardStrainPose.lua

	Owns: the strained guard -- a procedural brace-and-tremble layered over the block pose of every body
	whose guard is CRACKING (DefenseConstants.GuardCrack), on every client, so both fighters and every
	spectator can see a guard break coming.

	WHY PER-CLIENT, WHY TRANSFORM. The pose has to be seen by everyone, and the cheapest thing every client
	already has is the GuardCrack TAG DefenseSystem puts on the Humanoid (replicated for free). Each client
	then writes Motor6D.Transform for the bodies it can see -- the same technique Shared/Vessel/
	VesselArmPose.lua documents at length: Transform is what an AnimationTrack writes, so a write AFTER the
	animation step rides on top of the authored clip instead of fighting it, and Transform does not
	replicate, which is exactly why every client does its own. An authored "strained guard" clip would
	replicate from the owner alone, but it would REPLACE the weapon's own block clip rather than strain it,
	and there is no such asset; the day one exists this module is still the tremble on top of it.

	COMPOSES, NEVER ACCUMULATES -- through Client/FX/TransformLayer.lua, which owns the base-and-write
	bookkeeping for every pose layer. This module used to hand-roll it with an exact CFrame comparison that a
	Transform read-back never satisfies, so on an undriven joint the strain compounded every frame; too small
	to notice here, it was HitFlinchPose's copy of the same code that made a hit body spin (2026-09-30).

	ZERO IDLE COST. The RenderStep binding exists only while at least one body is tagged or still blending
	out; with no cracking guard anywhere this module costs one tag subscription and nothing per frame.

	Does not own: whether a guard is cracking (DefenseSystem, on the server), the block pose itself
	(DefenseClient + the weapon's clips), or the sparks and sound of a cracking block (ImpactSparks /
	CombatAudio via CombatFeedbackClient).
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)
local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local FXConstants = require(ReplicatedStorage.Shared.FXConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local Trove = require(ReplicatedStorage.Shared.Trove)

local TransformLayer = require(script.Parent.TransformLayer)

local logger = Logger.scope("GuardStrainPose")

local GuardStrainPose = {}

local CONFIG = FXConstants.GuardStrain
local TAG = DefenseConstants.GuardCrack.Tag
local RENDER_STEP_NAME = "GuardStrainPose"
-- Above Character, so the animation step has already written this frame's Transforms -- see
-- VesselArmPose's own TIMING IS NOT NEGOTIABLE note.
local RENDER_PRIORITY = Enum.RenderPriority.Character.Value + 2

-- R6 joint name -> the Part that holds it. THIS IS AN R6 GAME (memory: the game is R6-locked).
local JOINTS: { { Name: string, Holder: string } } = {
	{ Name = "RootJoint", Holder = "HumanoidRootPart" },
	{ Name = "Neck", Holder = "Torso" },
	{ Name = "Right Shoulder", Holder = "Torso" },
	{ Name = "Left Shoulder", Holder = "Torso" },
}

-- Per-joint noise offsets so the four joints do not tremble in lockstep (one diagonal jerk).
local NOISE_SEEDS: { [string]: number } = {
	RootJoint = 3.1,
	Neck = 17.9,
	["Right Shoulder"] = 41.3,
	["Left Shoulder"] = 66.7,
}

type Entry = {
	Humanoid: Humanoid,
	Tagged: boolean,
	Weight: number,
	Seed: number,
	Joints: { Motor6D }?,
}

local entries: { [Humanoid]: Entry } = {}
local started = false
local bound = false
local trove = Trove.New()

-- Pure pieces ----------------------------------------------------------------------------------------

-- Whether a body in `defenseState` has its guard up -- the only time a cracking guard is shown straining.
function GuardStrainPose.IsGuarding(defenseState: unknown): boolean
	return typeof(defenseState) == "string" and CONFIG.GuardStates[defenseState :: string] == true
end

-- The offset for one joint at time `t`, scaled by `weight` (0..1). Joint-space rotation, composed AFTER
-- the animated Transform. The axis conventions are R6's own C0 frames:
--   RootJoint / Neck -- X points to the character's left, so +X tips the part FORWARD.
--   Right Shoulder   -- Z points right; +Z swings the arm forward (up).
--   Left Shoulder    -- Z points left;  +Z swings the arm backward (down).
-- So the sag is: torso leaning back (-X), head dipping (+X), both arms pressed down into the body
-- (right -Z, left +Z), plus a small decorrelated tremble on every axis.
function GuardStrainPose.JointOffset(jointName: string, t: number, weight: number, seed: number): CFrame
	if weight <= 0 then
		return CFrame.identity
	end
	local noiseSeed = (NOISE_SEEDS[jointName] or 0) + seed
	local phase = t * CONFIG.TrembleFrequency
	local tremble = math.rad(CONFIG.TrembleDegrees)
	local nx = math.noise(phase, noiseSeed, 0) * tremble
	local ny = math.noise(phase, noiseSeed, 11.7) * tremble
	local nz = math.noise(phase, noiseSeed, 23.3) * tremble

	local sx, sz = 0, 0
	if jointName == "RootJoint" then
		sx = -math.rad(CONFIG.TorsoLeanDegrees)
	elseif jointName == "Neck" then
		sx = math.rad(CONFIG.HeadDipDegrees)
	elseif jointName == "Right Shoulder" then
		sz = -math.rad(CONFIG.ArmPressDegrees)
	elseif jointName == "Left Shoulder" then
		sz = math.rad(CONFIG.ArmPressDegrees)
	end

	return CFrame.Angles((sx + nx) * weight, ny * weight, (sz + nz) * weight)
end

-- Joints ---------------------------------------------------------------------------------------------

local function resolveJoints(humanoid: Humanoid): { Motor6D }?
	local model = humanoid.Parent
	if model == nil then
		return nil
	end
	local joints: { Motor6D } = {}
	for _, spec in JOINTS do
		local holder = model:FindFirstChild(spec.Holder)
		local motor = if holder then holder:FindFirstChild(spec.Name) else nil
		if motor and motor:IsA("Motor6D") then
			table.insert(joints, motor)
		end
	end
	return if #joints > 0 then joints else nil
end

-- Takes this layer off every joint -- see TransformLayer.Restore.
local function restore(entry: Entry): ()
	local joints = entry.Joints
	if not joints then
		return
	end
	for _, motor in joints do
		TransformLayer.Restore(motor)
	end
	entry.Joints = nil
end

local function applyPose(entry: Entry, t: number): ()
	local joints = entry.Joints
	if not joints then
		joints = resolveJoints(entry.Humanoid)
		entry.Joints = joints
		if not joints then
			return
		end
	end
	for _, motor in joints do
		TransformLayer.Compose(motor, GuardStrainPose.JointOffset(motor.Name, t, entry.Weight, entry.Seed))
	end
end

-- The loop -------------------------------------------------------------------------------------------

local function unbindIfIdle(): ()
	if bound and next(entries) == nil then
		RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
		bound = false
	end
end

local function step(deltaTime: number): ()
	local camera = Workspace.CurrentCamera
	local cameraPosition = if camera then camera.CFrame.Position else nil
	local t = os.clock()
	for humanoid, entry in entries do
		local model = humanoid.Parent
		local root = if model then model:FindFirstChild("HumanoidRootPart") else nil
		if model == nil or humanoid.Health <= 0 or root == nil or not root:IsA("BasePart") then
			restore(entry)
			entries[humanoid] = nil
			continue
		end

		local wants = entry.Tagged
			and GuardStrainPose.IsGuarding(humanoid:GetAttribute(AttributeConstants.DefenseState))
			and (cameraPosition == nil or (root.Position - cameraPosition).Magnitude <= CONFIG.MaxDistanceStuds)
		local rate = if wants then deltaTime / CONFIG.BlendInSeconds else -deltaTime / CONFIG.BlendOutSeconds
		entry.Weight = math.clamp(entry.Weight + rate, 0, 1)

		if entry.Weight <= 0 then
			restore(entry)
			if not entry.Tagged then
				entries[humanoid] = nil
			end
		else
			applyPose(entry, t)
		end
	end
	unbindIfIdle()
end

local function bindIfNeeded(): ()
	if bound or next(entries) == nil then
		return
	end
	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, step)
	bound = true
end

local function onTagged(instance: Instance): ()
	if not instance:IsA("Humanoid") then
		return
	end
	local entry = entries[instance]
	if entry then
		entry.Tagged = true
	else
		entries[instance] = {
			Humanoid = instance,
			Tagged = true,
			Weight = 0,
			Seed = math.random() * 100,
			Joints = nil,
		}
	end
	bindIfNeeded()
end

local function onUntagged(instance: Instance): ()
	local entry = entries[instance :: any]
	if entry then
		-- Kept until it has blended out; step drops it at weight 0.
		entry.Tagged = false
	end
end

-- Lifecycle ------------------------------------------------------------------------------------------

function GuardStrainPose.Start(): ()
	if started then
		return
	end
	started = true
	trove:Connect(CollectionService:GetInstanceAddedSignal(TAG), onTagged)
	trove:Connect(CollectionService:GetInstanceRemovedSignal(TAG), onUntagged)
	for _, instance in CollectionService:GetTagged(TAG) do
		onTagged(instance)
	end
	logger:info("GuardStrainPose started")
end

function GuardStrainPose.Stop(): ()
	trove:Clean()
	for _, entry in entries do
		restore(entry)
	end
	table.clear(entries)
	if bound then
		RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
		bound = false
	end
	started = false
end

return GuardStrainPose
