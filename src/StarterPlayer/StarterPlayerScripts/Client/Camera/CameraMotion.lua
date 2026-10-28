--!strict
--[[
	CameraMotion.lua

	Owns: the movement-responsive camera -- the local view taking on the weight of the body it follows. A lean into
	lateral acceleration, a pull-back and a FOV that grow with speed, and a compression-and-rebound when the body lands,
	every one a function of the velocity the root actually has. The arithmetic is Shared/CameraMotionMath.lua; the tuning
	is CameraConstants.Motion.

	COMPOSES, NEVER WRITES. Each channel goes through the shared owner of its property, in a named slot of its own:
	  * pull-back and landing dip -> Client/FX/CameraOffsetComposer ("Motion"), so the default camera applies them to its
	    focus before its own zoom and occlusion run, as CameraFollow's trail does;
	  * speed FOV                 -> Client/FX/FOVOffset ("MotionSpeed"), which eases it and sums it with the sprint zoom,
	    the swing punches and the rest;
	  * lean                      -> Client/FX/CameraRotationComposer ("MotionLean"), the continuous-rotation owner this module
	    and the wall-run tilt share;
	  * a hard landing's shake    -> Client/FX/CameraShake, the transient-rotation owner.
	No camera property is assigned here, and the player's own orbit, zoom, and pitch and yaw are untouched.

	THE CAMERA IS PRESENTATION. Nothing here reads or writes gameplay state; it reads the root's velocity and the same
	Humanoid Attributes the other camera modules do, and the server never hears of it.

	WHAT IT SITS BESIDE, AND DOES NOT REPEAT. Client/Camera/CameraFollow already makes the view LAG a body that accelerates
	(a spring on the camera's focus), which is the acceleration-aware trail; this module adds what a trail cannot say --
	which way the body is turning, how fast it is going, and that it just hit the ground. CombatCamera's shoulder,
	FlightCamera's chase and BlimpCamera's pose are other slots in the same composers and sum with these.

	STANDS DOWN, AND RELEASES SMOOTHLY, when the default follow camera is not the one framing this body: a Scriptable
	camera or another subject (the intro, a spectate), first person (an offset focus would push the view out of the head),
	death, or the Camera effects setting switched off. Every slot then eases to zero over Motion.ReleaseEaseSpeed rather
	than snapping.

	SUSPENDS (as opposed to standing down) while another system is moving the body -- BodyRestraint's "CameraMotion" row:
	a vessel, flight, a root lock (a ragdoll or an air-combo hold), a grab, a freeze. Its Attributes are mirrored by
	change, so the frame pays for no Attribute reads. The math then lets every channel ease out, re-seeds its velocity
	filter, and reports no landing: the camera does not lean to a tumbling body, and does not mistake the end of a hold for
	an impact. A knockback launch is NOT suspended -- it is the body's real motion -- but its lean is bounded like any
	other, and a launch that ends on the ground lands like any fall.

	THE SETTING. Settings -> Gameplay -> Camera effects (Parkour.CameraEffects) switches the whole module off, as it did
	the speed zoom, landing dip and wall tilt that moved here from ParkourCamera; Comfort.CameraShake still gates the
	landing shake (CameraShake.Shake refuses while it is off). CameraConstants.Motion.Scale holds the per-channel
	multipliers for tuning or a future intensity slider. A dedicated persisted intensity needs a Comfort field and so a
	profile-corpus update; it was left out of this pass on purpose.

	Does not own: any of the composers, the camera's rotation, or the settings screen.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BodyRestraint = require(ReplicatedStorage.Shared.Combat.BodyRestraint)
local CameraConstants = require(ReplicatedStorage.Shared.CameraConstants)
local CameraMotionMath = require(ReplicatedStorage.Shared.CameraMotionMath)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local Trove = require(ReplicatedStorage.Shared.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local CameraOffsetComposer = require(script.Parent.Parent.FX.CameraOffsetComposer)
local CameraRotationComposer = require(script.Parent.Parent.FX.CameraRotationComposer)
local CameraShake = require(script.Parent.Parent.FX.CameraShake)
local FOVOffset = require(script.Parent.Parent.FX.FOVOffset)
local FrameOrder = require(script.Parent.Parent.Config.FrameOrder)
local SettingsStore = require(script.Parent.Parent.Settings.SettingsStore)

local logger = Logger.scope("CameraMotion")

local RENDER_STEP_NAME = "CameraMotionUpdate"

local MOTION = CameraConstants.Motion
local SLOTS = MOTION.Slots
local CAMERA_VERB = "CameraMotion"

local CameraMotion = {}

local started = false
-- The Camera effects setting (Parkour.CameraEffects). Defaults on, like every comfort preference.
local effectsEnabled = true
local state = CameraMotionMath.NewState()
-- Whether the slots currently hold live values, so standing down releases them once rather than every frame.
local engaged = false

local humanoid: Humanoid? = nil
local rootPart: BasePart? = nil
-- BodyRestraint's CameraMotion row, mirrored off the Attributes it reads (see the header).
local suspended = false
-- The last usable flat direction the camera looked, for the frame it points straight up or down.
local lastBack = Vector3.new(0, 0, 1)
local lastRight = Vector3.new(1, 0, 0)

-- Forgets the motion and eases whatever the slots still hold back to neutral.
local function standDown(): ()
	CameraMotionMath.Reset(state)
	if not engaged then
		return
	end
	engaged = false
	local ease = MOTION.ReleaseEaseSpeed
	CameraOffsetComposer.SetContinuous(SLOTS.Offset, Vector3.zero, ease)
	FOVOffset.SetContinuous(SLOTS.Fov, 0, ease)
	CameraRotationComposer.SetContinuous(SLOTS.Roll, Vector3.zero, ease)
end

-- The hard version, for the character going away: there is no longer a view for an ease to look right against.
local function clearSlots(): ()
	CameraMotionMath.Reset(state)
	engaged = false
	CameraOffsetComposer.ClearContinuous(SLOTS.Offset)
	FOVOffset.ClearContinuous(SLOTS.Fov)
	CameraRotationComposer.ClearContinuous(SLOTS.Roll)
end

local function onRenderStep(deltaTime: number): ()
	local camera = Workspace.CurrentCamera
	local currentHumanoid = humanoid
	local root = rootPart
	if
		not MOTION.Enabled
		or not effectsEnabled
		or camera == nil
		or currentHumanoid == nil
		or root == nil
		or root.Parent == nil
		or currentHumanoid.Health <= 0
		or camera.CameraType ~= Enum.CameraType.Custom
		or camera.CameraSubject ~= currentHumanoid
	then
		standDown()
		return
	end
	-- Last frame's camera, which is exactly as good a read of the zoom as this frame's would be.
	if (camera.CFrame.Position - camera.Focus.Position).Magnitude < MOTION.FirstPersonDistanceThreshold then
		standDown()
		return
	end

	local look = camera.CFrame.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z)
	if flatLook.Magnitude > 1e-3 then
		lastBack = -flatLook.Unit
	end
	local right = camera.CFrame.RightVector
	local flatRight = Vector3.new(right.X, 0, right.Z)
	if flatRight.Magnitude > 1e-3 then
		lastRight = flatRight.Unit
	end

	local roll, pull, dip, fov, severity =
		CameraMotionMath.Step(state, root.AssemblyLinearVelocity, lastRight, suspended, deltaTime, MOTION)
	engaged = true

	-- Already smoothed by the math (a spring, an ease), so the composers are told not to ease them again -- their
	-- nil-easeSpeed contract. The FOV is a target and is eased by FOVOffset, which has no per-frame owner of its own.
	CameraOffsetComposer.SetContinuous(
		SLOTS.Offset,
		root.CFrame:VectorToObjectSpace(lastBack * pull + Vector3.yAxis * -dip),
		nil
	)
	CameraRotationComposer.SetContinuous(SLOTS.Roll, Vector3.new(0, 0, roll), nil)
	FOVOffset.SetContinuous(SLOTS.Fov, fov, MOTION.Fov.EaseSpeed)

	if severity ~= nil and severity >= MOTION.Landing.ShakeSeverity then
		local shake = MOTION.Landing.Shake
		CameraShake.Shake({
			Amplitude = shake.Amplitude * severity,
			Frequency = shake.Frequency,
			DurationSeconds = shake.DurationSeconds,
		})
	end
end

local function readSuspended(boundHumanoid: Humanoid): boolean
	return BodyRestraint.Restrained(boundHumanoid, CAMERA_VERB)
end

local function onCharacter(character: Model, boundHumanoid: Humanoid, life: Trove.TroveInstance): ()
	clearSlots()
	local root = CharacterUtil.AwaitRoot(character)
	if root == nil then
		return
	end
	humanoid = boundHumanoid
	rootPart = root

	-- Seeded rather than assumed false, and kept current by change: a fast respawn can land this bind after the server
	-- has already written the new body's Attributes.
	suspended = readSuspended(boundHumanoid)
	for _, attribute in BodyRestraint.AttributesOf(CAMERA_VERB) do
		life:Connect(boundHumanoid:GetAttributeChangedSignal(attribute), function()
			suspended = readSuspended(boundHumanoid)
		end)
	end
end

local function onCharacterRemoving(): ()
	humanoid = nil
	rootPart = nil
	suspended = false
	clearSlots()
end

-- Whether the module is on. The Camera effects setting drives it through SettingsStore; exposed so a spec or a tool can too.
function CameraMotion.SetEnabled(enabled: boolean): ()
	effectsEnabled = enabled
end

-- Called once from Main.client.lua, after CameraOffsetComposer, FOVOffset, CameraShake and CameraRotationComposer have started.
-- Idempotent.
function CameraMotion.Start(): ()
	if started then
		return
	end
	started = true

	SettingsStore.Observe("Parkour", function(parkour: Types.ParkourSettings)
		CameraMotion.SetEnabled(parkour.CameraEffects)
	end)

	PlayerLifecycle.BindLocalCharacter({
		Scope = "CameraMotion",
		OnCharacter = onCharacter,
		OnCharacterRemoving = onCharacterRemoving,
	})

	RunService:BindToRenderStep(RENDER_STEP_NAME, FrameOrder.Priority("CameraMotion"), onRenderStep)
	logger:info("CameraMotion started")
end

return CameraMotion
