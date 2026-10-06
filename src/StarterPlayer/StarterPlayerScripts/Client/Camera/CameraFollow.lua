--!strict
--[[
	CameraFollow.lua

	Owns: the smoothed follow -- the local camera's focus trailing the character on a critically damped
	spring instead of being welded to its root. The arithmetic is Shared/CameraFollowMath.lua; the
	tuning is CameraConstants.Follow.

	WHY. The stock camera tracks the HumanoidRootPart rigidly, so whatever the body does in one frame the
	view does in the same frame. In a fight that is most visible on a punch: SwingLunge's step-in and a
	Heavy's authored step push the root forward at 10-15 studs/s from a standstill, and the whole view
	lurched with it on every swing. The same was true of a landing, a vault's pop up onto a ledge, a
	dash's burst. Here the camera accelerates into the motion and settles out of it, trailing the body by
	at most about a stud -- enough to take the jerk out, never enough to lose the fight.

	WRITTEN THROUGH Humanoid.CameraOffset, NOT onto Camera.CFrame. The trail becomes a "Follow" slot on
	Client/FX/CameraOffsetComposer.lua, so the default camera applies it to its focus BEFORE its own zoom
	and occlusion (Popper) run: the camera can never be pushed into a wall by the trail, because the
	camera scripts place it after the trail is already in. A translation composed onto Camera.CFrame
	afterwards (the way CameraShake composes rotation) would skip that and could clip. CameraOffset is in
	the root's own object space, so the world-space trail is converted with the root's current rotation
	every frame -- which also keeps a body turning in place (a swing tracking its target) from moving the
	camera at all.

	TIMING. Bound at RenderPriority.Camera - 3: after the frame's physics has moved the root, before the
	composer writes CameraOffset (Camera - 1) and before the camera scripts read it (Camera). So the
	trail describes THIS frame's body, not last frame's.

	STANDS DOWN, AND RELEASES SMOOTHLY, whenever the default follow camera is not the one framing this
	body: flight (FlightCamera owns the chase) and a vessel mount (BlimpCamera/BoatCamera) by their
	Humanoid Attributes, a Scriptable camera or another subject (the intro, a spectate), first person
	(an offset focus would push the view out of the head), and death. The slot eases to zero over
	CameraConstants.Follow.ReleaseEaseSpeed rather than being cleared, so a hand-off never snaps the view
	by the last trail's worth.

	Does not own: the camera's rotation (the camera scripts, LockOnController, ShiftLockCamera), its
	shake (CameraShake), FOV (FOVOffset), or any other CameraOffset slot (ShiftLockCamera's shoulder,
	FlightCamera's chase, ParkourCamera's dips all sum with this one in the composer).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local CameraConstants = require(ReplicatedStorage.Shared.CameraConstants)
local CameraFollowMath = require(ReplicatedStorage.Shared.CameraFollowMath)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local Trove = require(ReplicatedStorage.Shared.Trove)

local CameraOffsetComposer = require(script.Parent.Parent.FX.CameraOffsetComposer)

local logger = Logger.scope("CameraFollow")

local RENDER_STEP_NAME = "CameraFollowUpdate"
local SLOT = "Follow"

local CameraFollow = {}

local started = false
local state = CameraFollowMath.NewState()
-- Whether the slot currently holds a live trail, so standing down releases it once rather than every frame.
local engaged = false

local humanoid: Humanoid? = nil
local rootPart: BasePart? = nil
-- Cached off the Humanoid's Attributes, the same watch shape ShiftLockCamera keeps for the same two: a
-- GetAttribute call every rendered frame would not be free.
local flying = false
local mounted = false

-- Forgets the trail and eases whatever the slot still holds back to zero.
local function standDown(): ()
	CameraFollowMath.Reset(state)
	if engaged then
		engaged = false
		CameraOffsetComposer.SetContinuous(SLOT, Vector3.zero, CameraConstants.Follow.ReleaseEaseSpeed)
	end
end

local function onRenderStep(deltaTime: number): ()
	local tuning = CameraConstants.Follow
	local camera = Workspace.CurrentCamera
	local currentHumanoid = humanoid
	local root = rootPart
	if
		not tuning.Enabled
		or camera == nil
		or currentHumanoid == nil
		or root == nil
		or root.Parent == nil
		or currentHumanoid.Health <= 0
		or flying
		or mounted
		or camera.CameraType ~= Enum.CameraType.Custom
		or camera.CameraSubject ~= currentHumanoid
	then
		standDown()
		return
	end
	-- Last frame's camera, which is exactly as good a read of the zoom as this frame's would be.
	if (camera.CFrame.Position - camera.Focus.Position).Magnitude < tuning.FirstPersonDistanceThreshold then
		standDown()
		return
	end

	local lag = CameraFollowMath.Step(state, root.Position, deltaTime, tuning)
	engaged = true
	-- Already smoothed here, so the composer is told not to ease it again (its nil-easeSpeed contract).
	CameraOffsetComposer.SetContinuous(SLOT, root.CFrame:VectorToObjectSpace(lag), nil)
end

local function onCharacter(character: Model, boundHumanoid: Humanoid, life: Trove.TroveInstance): ()
	standDown()
	local root = CharacterUtil.AwaitRoot(character)
	if root == nil then
		return
	end
	humanoid = boundHumanoid
	rootPart = root

	local attributes = AttributeConstants
	flying = boundHumanoid:GetAttribute(attributes.Flying) == true
	life:Connect(boundHumanoid:GetAttributeChangedSignal(attributes.Flying), function()
		flying = boundHumanoid:GetAttribute(attributes.Flying) == true
	end)
	mounted = boundHumanoid:GetAttribute(attributes.Mounted) == true
	life:Connect(boundHumanoid:GetAttributeChangedSignal(attributes.Mounted), function()
		mounted = boundHumanoid:GetAttribute(attributes.Mounted) == true
	end)
end

local function onCharacterRemoving(): ()
	humanoid = nil
	rootPart = nil
	flying = false
	mounted = false
	standDown()
end

-- Called once from Main.client.lua, after CameraOffsetComposer.Start. Idempotent.
function CameraFollow.Start(): ()
	if started then
		return
	end
	started = true

	PlayerLifecycle.BindLocalCharacter({
		Scope = "CameraFollow",
		OnCharacter = onCharacter,
		OnCharacterRemoving = onCharacterRemoving,
	})

	RunService:BindToRenderStep(RENDER_STEP_NAME, Enum.RenderPriority.Camera.Value - 3, onRenderStep)
	logger:info("CameraFollow started")
end

return CameraFollow
