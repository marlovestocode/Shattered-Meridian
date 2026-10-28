--!strict
--[[
	HitFlinchPose.lua

	Owns: the flinch -- a short procedural recoil (torso rocked back, head snapped, arms thrown) on every
	body that takes a stunning hit, on every client, so a landed hit visibly lands on the body it hit.

	WHY THIS EXISTS (2026-09-30). The victim's hit reaction (the Hit1-3/HitGeneric clips and
	CombatAnimator.PlayHitReaction) was deleted with the old combat system and never rebuilt. A landed hit
	had a flash, a number and a small push, but the body it hit did nothing: the victim kept its idle or
	walk pose through its own stun, and an exchange read as two people swinging near each other rather
	than trading blows. There are no authored reaction clips, so this is procedural; the day one exists,
	this is still the jolt on top of it.

	THE TRIGGER IS THE STUN ITSELF: every stunning hit extends the victim's HitstunUntil Humanoid Attribute
	(DamageSystem.ExtendHitstun), which replicates to every client for free. A rise in it IS a hit
	landing, for players, training bots and dummies alike, with no remote and no special case. A block, a
	parry or an evade applies no stun, so none of them flinch -- correctly.

	TECHNIQUE: GuardStrainPose's -- Motor6D.Transform composed AFTER the animation step, one RenderStep
	binding that exists only while a body is flinching -- with the composing itself in TransformLayer, which
	both share so an undriven joint never ratchets (it did, at first: the body spun and flipped over).

	Does not own: whether a hit stuns or for how long (DamageSystem), the hit-stop freeze (HitStop), the
	flash, sparks or sound of the hit (CombatFeedbackClient and friends).
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local AttackConstants = require(ReplicatedStorage.Shared.Attack.AttackConstants)
local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)
local FXConstants = require(ReplicatedStorage.Shared.FXConstants)
local HitboxEngineConstants = require(ReplicatedStorage.Shared.HitboxEngine.HitboxEngineConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local Trove = require(ReplicatedStorage.Shared.Trove)

local TransformLayer = require(script.Parent.TransformLayer)
local FrameOrder = require(script.Parent.Parent.Config.FrameOrder)

local logger = Logger.scope("HitFlinchPose")

local HitFlinchPose = {}

local CONFIG = FXConstants.HitFlinch
local TAG = HitboxEngineConstants.CombatantTag
local STUN_ATTRIBUTE = AttributeConstants.HitstunUntil
local RENDER_STEP_NAME = "HitFlinchPose"
-- Above Character (the animation step has written this frame's Transforms), and BELOW GuardStrainPose's +2
-- so a guard that strains in the same frame a hit lands composes on top of the flinch, not under it.
local RENDER_PRIORITY = FrameOrder.Priority("HitFlinchPose")

-- R6 joint name -> the Part that holds it (the game is R6-locked).
type Flinch = {
	Humanoid: Humanoid,
	-- Seconds into the current flinch's envelope.
	Elapsed: number,
	-- +1 or -1: which way this hit twists the torso, so consecutive hits do not all rock the same way.
	TwistSign: number,
	Joints: { Motor6D }?,
	-- Set when the hit that started this flinch was reversed: the strength it had then, and how long it has been
	-- easing out. The envelope no longer drives the weight while it is set.
	Cancel: { Start: number, Elapsed: number }?,
}

local flinching: { [Humanoid]: Flinch } = {}
-- The last HitstunUntil seen per watched Humanoid, so only a RISE counts as a hit.
local lastStun: { [Humanoid]: number } = {}
local watchers: { [Model]: Trove.TroveInstance } = {}
-- When this client last flinched a body AHEAD of the server (Predict), so the stun that confirms it a
-- round trip later does not flinch it a second time.
local predictedAt: { [Humanoid]: number } = {}
local PREDICTION_MATCH_SECONDS = AttackConstants.Presentation.HitPrediction.MatchSeconds
local started = false
local bound = false
local trove = Trove.New()

-- Pure pieces ----------------------------------------------------------------------------------------

-- The flinch's strength, 0..1, `elapsed` seconds in: a near-instant rise (the hit) then an eased settle.
function HitFlinchPose.Envelope(elapsed: number): number
	local rise = CONFIG.RiseSeconds
	if elapsed <= 0 then
		return 0
	elseif elapsed < rise then
		return elapsed / rise
	end
	local settle = (elapsed - rise) / CONFIG.SettleSeconds
	if settle >= 1 then
		return 0
	end
	-- Smoothstep down: the body eases back rather than snapping upright.
	return 1 - settle * settle * (3 - 2 * settle)
end

-- The offset for one joint at strength `weight`. R6 joint frames (GuardStrainPose.JointOffset's header):
-- RootJoint/Neck -- +X tips forward, Z is up (a twist); Right Shoulder -- -Z swings the arm back; Left
-- Shoulder -- +Z swings the arm back.
function HitFlinchPose.JointOffset(jointName: string, weight: number, twistSign: number): CFrame
	if weight <= 0 then
		return CFrame.identity
	end
	if jointName == "RootJoint" then
		return CFrame.Angles(
			-math.rad(CONFIG.TorsoLeanDegrees) * weight,
			0,
			math.rad(CONFIG.TorsoTwistDegrees) * twistSign * weight
		)
	elseif jointName == "Neck" then
		return CFrame.Angles(
			-math.rad(CONFIG.HeadSnapDegrees) * weight,
			0,
			-math.rad(CONFIG.TorsoTwistDegrees) * 0.5 * twistSign * weight
		)
	elseif jointName == "Right Shoulder" then
		return CFrame.Angles(0, 0, -math.rad(CONFIG.ArmThrowDegrees) * weight)
	elseif jointName == "Left Shoulder" then
		return CFrame.Angles(0, 0, math.rad(CONFIG.ArmThrowDegrees) * weight)
	end
	return CFrame.identity
end

-- Where a flinch retriggered mid-flight picks up: at the point of the rise matching its current strength,
-- so a second hit drives the body further from where it already is instead of popping it back upright.
function HitFlinchPose.RetriggerElapsed(currentElapsed: number): number
	return CONFIG.RiseSeconds * HitFlinchPose.Envelope(currentElapsed)
end

-- The strength a flinch has right now: its envelope, or the linear ease-out of a cancelled one.
local function weightOf(flinch: Flinch): number
	local cancel = flinch.Cancel
	if cancel then
		return cancel.Start * (1 - math.min(cancel.Elapsed / CONFIG.CancelBlendSeconds, 1))
	end
	return HitFlinchPose.Envelope(flinch.Elapsed)
end

-- Joints ---------------------------------------------------------------------------------------------

-- Takes this layer off every joint -- see TransformLayer.Restore.
local function restore(flinch: Flinch): ()
	local joints = flinch.Joints
	if not joints then
		return
	end
	for _, motor in joints do
		TransformLayer.Restore(motor)
	end
	flinch.Joints = nil
end

-- Composed through TransformLayer, never written directly: see that module's header for the spinning,
-- flipping body a hand-rolled compose with an exact CFrame comparison produced here.
local function applyPose(flinch: Flinch, weight: number): ()
	local joints = flinch.Joints
	if not joints then
		joints = TransformLayer.ResolveBodyJoints(flinch.Humanoid)
		flinch.Joints = joints
		if not joints then
			return
		end
	end
	for _, motor in joints do
		TransformLayer.Compose(motor, HitFlinchPose.JointOffset(motor.Name, weight, flinch.TwistSign))
	end
end

-- The loop -------------------------------------------------------------------------------------------

local function step(deltaTime: number): ()
	local camera = Workspace.CurrentCamera
	local cameraPosition = if camera then camera.CFrame.Position else nil
	for humanoid, flinch in flinching do
		flinch.Elapsed += deltaTime
		local cancel = flinch.Cancel
		if cancel then
			cancel.Elapsed += deltaTime
		end
		local weight = weightOf(flinch)
		local model = humanoid.Parent
		local root = if model then model:FindFirstChild("HumanoidRootPart") else nil
		local visible = root ~= nil
			and root:IsA("BasePart")
			and (cameraPosition == nil or (root.Position - cameraPosition).Magnitude <= CONFIG.MaxDistanceStuds)
		if weight <= 0 or model == nil or humanoid.Health <= 0 or not visible then
			restore(flinch)
			flinching[humanoid] = nil
			continue
		end
		applyPose(flinch, weight)
	end
	if bound and next(flinching) == nil then
		RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
		bound = false
	end
end

local function flinch(humanoid: Humanoid): ()
	local existing = flinching[humanoid]
	if existing then
		-- From wherever the body is now (an easing-out one included), so the new hit drives it further.
		existing.Elapsed = CONFIG.RiseSeconds * weightOf(existing)
		existing.Cancel = nil
		existing.TwistSign = -existing.TwistSign
	else
		flinching[humanoid] = {
			Humanoid = humanoid,
			Elapsed = 0,
			TwistSign = if math.random() < 0.5 then -1 else 1,
			Joints = nil,
		}
	end
	if not bound then
		RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, step)
		bound = true
	end
end

-- Watching -------------------------------------------------------------------------------------------

local function numberOf(value: unknown): number
	return if typeof(value) == "number" then value else 0
end

local function watchHumanoid(humanoid: Humanoid, scope: Trove.TroveInstance): ()
	lastStun[humanoid] = numberOf(humanoid:GetAttribute(STUN_ATTRIBUTE))
	scope:Connect(humanoid:GetAttributeChangedSignal(STUN_ATTRIBUTE), function()
		local value = numberOf(humanoid:GetAttribute(STUN_ATTRIBUTE))
		local previous = lastStun[humanoid] or 0
		lastStun[humanoid] = value
		-- A rise is a new stunning hit. The server's clock is not this client's, so the value is only ever
		-- compared with itself, never with os.clock().
		if value > previous + 1e-3 then
			local predicted = predictedAt[humanoid]
			predictedAt[humanoid] = nil
			if predicted and os.clock() - predicted <= PREDICTION_MATCH_SECONDS then
				return
			end
			flinch(humanoid)
		end
	end)
	scope:Add(function()
		lastStun[humanoid] = nil
		predictedAt[humanoid] = nil
		local active = flinching[humanoid]
		if active then
			restore(active)
			flinching[humanoid] = nil
		end
	end)
end

local function onTagged(instance: Instance): ()
	if not instance:IsA("Model") or watchers[instance] then
		return
	end
	local scope = trove:Extend()
	watchers[instance] = scope
	local humanoid = instance:FindFirstChildOfClass("Humanoid")
	if humanoid then
		watchHumanoid(humanoid, scope)
	else
		-- Tagged before its Humanoid replicated: pick it up when it arrives.
		scope:Connect(instance.ChildAdded, function(child: Instance)
			if child:IsA("Humanoid") and lastStun[child] == nil then
				watchHumanoid(child, scope)
			end
		end)
	end
end

local function onUntagged(instance: Instance): ()
	local scope = watchers[instance :: any]
	if scope then
		watchers[instance :: any] = nil
		-- Remove releases it too, and stops the parent Trove holding a dead scope for the whole session.
		trove:Remove(scope)
	end
end

-- Flinches `humanoid` now, ahead of the server's stun -- for the attacker's predicted hit
-- (Client/Combat/HitPrediction.lua). The stun that confirms it is then not flinched again.
function HitFlinchPose.Predict(humanoid: Humanoid): ()
	predictedAt[humanoid] = os.clock()
	flinch(humanoid)
end

-- Ends the flinch `humanoid` is in -- or only its prediction record -- because the hit that started it did not
-- happen: the server answered a predicted hit with a block, a parry or an evade, or never answered it. Eases out
-- over CancelBlendSeconds rather than snapping upright. A no-op for a body that is not flinching.
function HitFlinchPose.Cancel(humanoid: Humanoid): ()
	predictedAt[humanoid] = nil
	local active = flinching[humanoid]
	if active == nil or active.Cancel ~= nil then
		return
	end
	active.Cancel = { Start = HitFlinchPose.Envelope(active.Elapsed), Elapsed = 0 }
end

-- Lifecycle ------------------------------------------------------------------------------------------

function HitFlinchPose.Start(): ()
	if started then
		return
	end
	started = true
	trove:Connect(CollectionService:GetInstanceAddedSignal(TAG), onTagged)
	trove:Connect(CollectionService:GetInstanceRemovedSignal(TAG), onUntagged)
	for _, instance in CollectionService:GetTagged(TAG) do
		onTagged(instance)
	end
	logger:info("HitFlinchPose started")
end

function HitFlinchPose.Stop(): ()
	trove:Clean()
	table.clear(watchers)
	for _, active in flinching do
		restore(active)
	end
	table.clear(flinching)
	table.clear(lastStun)
	table.clear(predictedAt)
	if bound then
		RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
		bound = false
	end
	started = false
end

return HitFlinchPose
