--!strict
--[[
	LockOnController.lua

	Owns: the local player's lock-on target -- acquiring it on the LockOn key (CapsLock / R3), holding the
	camera on it, releasing it, and drawing its marker (Screens/LockOnMarker). combat-philosophy.md lists
	lock-on as an established system; the keybind and the Settings row existed with nothing behind them
	until this (2026-09-29).

	PRESS TO LOCK, PRESS AGAIN TO RELEASE. A press with nothing locked picks the live combatant nearest the
	centre of the screen (LockOnConstants.Targeting: inside the acquire cone and range, scored by angle
	with distance as a tie-break). A lock breaks on its own when the target dies or despawns, leaves
	BreakRangeStuds, stays out of line of sight past OcclusionGraceSeconds, or when the local body dies,
	mounts a vessel or starts flying.

	A SOFT CAMERA LOCK. Every frame, BEFORE the default camera scripts run (RenderPriority.Camera - 1), the
	camera's look is pulled toward the target on a critically damped spring (LockOnConstants.Camera's own
	note on why a spring rather than an ease), softened at close range. The default camera reads its look direction back off
	Camera.CFrame, so it then applies the player's own mouse/stick input, zoom and occlusion on top of the
	eased look: the player can still glance around and is pulled back. Running before rather than after
	the camera scripts is what keeps occlusion correct, and it means ShiftLockCamera (Camera + 1) turns
	the body toward the already-eased camera -- with shift lock on, a locked player faces the target.
	Only a Custom camera is steered. A Scriptable one belongs to a vehicle or flight camera.

	THE TARGET IS AIM AND PRESENTATION, NEVER TRUSTED. It is never sent to the server. Swing tracking
	(SwingTracking.lua) reads GetTarget to turn the body during a windup, and the server's hitbox reads the
	body's real replicated facing like any other swing.

	Does not own: the candidate list (CombatTargets.lua), turning the body during a swing (SwingTracking),
	the marker's look (Screens/LockOnMarker), or any opponent's guard value (DefenseSystem publishes it).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Constants = require(ReplicatedStorage.Shared.Constants)
local FlightMath = require(ReplicatedStorage.Shared.FlightMath)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local LockOnConstants = require(ReplicatedStorage.Shared.Combat.LockOnConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local Trove = require(ReplicatedStorage.Shared.Trove)

local InputRouter = require(script.Parent.Parent.Input.InputRouter)
local LockOnMarkerModule = require(script.Parent.Parent.UI.Screens.LockOnMarker)
local Surface = require(script.Parent.Parent.UI.Shell.Surface)
local CombatTargets = require(script.Parent.CombatTargets)

local logger = Logger.scope("LockOnController")

local RENDER_STEP_NAME = "LockOnCameraUpdate"

local LockOnController = {}

local target: Model? = nil
-- When the target was last in line of sight (os.clock), for OcclusionGraceSeconds.
local lastVisibleAt = 0
-- The camera pull's angular velocities (radians/second), carried frame to frame by the spring. Zeroed on
-- every target change, so a new lock starts from rest rather than inheriting the last one's swing.
local yawVelocity = 0
local pitchVelocity = 0

local character: Model? = nil
local humanoid: Humanoid? = nil
local rootPart: BasePart? = nil

local marker: LockOnMarkerModule.LockOnMarkerHandle? = nil
local viewportScale: Fusion.UsedAs<number> = 1
local started = false

local targetChangedListeners: { (Model?) -> () } = {}

-- One RaycastParams for the per-frame line-of-sight ray, with its exclude list rewritten in place.
local sightParams = RaycastParams.new()
sightParams.FilterType = Enum.RaycastFilterType.Exclude
sightParams.IgnoreWater = true
local sightExclude: { Instance } = {}

local function setTarget(newTarget: Model?): ()
	if target == newTarget then
		return
	end
	target = newTarget
	lastVisibleAt = os.clock()
	yawVelocity = 0
	pitchVelocity = 0
	local handle = marker
	if handle then
		handle.SetVisible(false)
		handle.SetGuard(nil)
	end
	for _, listener in targetChangedListeners do
		local ok, err = pcall(listener, newTarget)
		if not ok then
			logger:error("A LockOnController.OnTargetChanged listener errored", { errorMessage = tostring(err) })
		end
	end
	logger:debug(if newTarget then "Locked on" else "Lock released", {
		target = if newTarget then newTarget.Name else nil,
	})
end

-- Whether the local body is in any state that cannot hold a lock.
local function bodyRefusesLock(): boolean
	local currentHumanoid = humanoid
	if currentHumanoid == nil or currentHumanoid.Health <= 0 or rootPart == nil then
		return true
	end
	return currentHumanoid:GetAttribute(Constants.Attributes.Mounted) == true
		or currentHumanoid:GetAttribute(Constants.Attributes.Flying) == true
end

-- The live combatant nearest the centre of the screen, inside the acquire cone and range, or nil.
local function acquire(): Model?
	local camera = Workspace.CurrentCamera
	local root = rootPart
	if camera == nil or root == nil then
		return nil
	end
	local tuning = LockOnConstants.Targeting
	local cameraCFrame = camera.CFrame
	local best: Model? = nil
	local bestScore = math.huge
	for _, candidate in CombatTargets.All(character) do
		local distance = (candidate.Root.Position - root.Position).Magnitude
		local toCandidate = candidate.Root.Position - cameraCFrame.Position
		if distance <= tuning.AcquireRangeStuds and toCandidate.Magnitude > 1e-3 then
			local dot = math.clamp(toCandidate.Unit:Dot(cameraCFrame.LookVector), -1, 1)
			local angle = math.deg(math.acos(dot))
			if angle <= tuning.AcquireConeDegrees then
				local score = angle + distance * tuning.DistanceWeight
				if score < bestScore then
					best = candidate.Model
					bestScore = score
				end
			end
		end
	end
	return best
end

local function toggle(): ()
	if target ~= nil then
		setTarget(nil)
		return
	end
	if bodyRefusesLock() then
		return
	end
	setTarget(acquire())
end

local function hasLineOfSight(origin: Vector3, aim: Vector3, targetModel: Model): boolean
	table.clear(sightExclude)
	local own = character
	if own then
		table.insert(sightExclude, own)
	end
	table.insert(sightExclude, targetModel)
	sightParams.FilterDescendantsInstances = sightExclude
	return Workspace:Raycast(origin, aim - origin, sightParams) == nil
end

-- Pulls the camera's look toward `aim` by `deltaTime`. See this file's header on why this runs before the
-- default camera scripts and writes only the look, never the position they are about to recompute.
--
-- The spring's VALUE is re-read off the camera every frame rather than kept here, so the player's own
-- mouse or stick input (applied by the camera scripts between two calls) is simply where the spring
-- resumes from; only the velocity is this module's memory.
local function pullCamera(camera: Camera, aim: Vector3, deltaTime: number): ()
	local tuning = LockOnConstants.Camera
	local focus = camera.Focus.Position
	local direction = aim - focus
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < tuning.MinDistanceStuds then
		-- Stood down, so the next frame back in range starts the pull from rest.
		yawVelocity = 0
		pitchVelocity = 0
		return
	end
	local look = camera.CFrame.LookVector
	local currentYaw = CombatTargets.YawOf(look)
	local desiredYaw = CombatTargets.YawOf(flat)
	if currentYaw == nil or desiredYaw == nil then
		return
	end
	local currentPitch = math.asin(math.clamp(look.Y, -1, 1))
	local desiredPitch =
		math.clamp(math.atan2(direction.Y, flat.Magnitude) + tuning.PitchBias, tuning.MinPitch, tuning.MaxPitch)

	-- Softer at arm's length, where small movements are big angles. 1 at CloseRangeStuds and beyond, down to
	-- CloseRangeScale at MinDistanceStuds.
	local closeness = math.clamp(
		(flat.Magnitude - tuning.MinDistanceStuds) / math.max(tuning.CloseRangeStuds - tuning.MinDistanceStuds, 1e-3),
		0,
		1
	)
	local scale = tuning.CloseRangeScale + (1 - tuning.CloseRangeScale) * closeness

	-- The yaw target is unwrapped next to the current yaw, so the spring always turns the short way round.
	local yaw, nextYawVelocity = FlightMath.SpringStep(
		currentYaw,
		yawVelocity,
		currentYaw + CombatTargets.AngleDelta(currentYaw, desiredYaw),
		tuning.YawFrequency * scale,
		tuning.Damping,
		deltaTime
	)
	local pitch, nextPitchVelocity = FlightMath.SpringStep(
		currentPitch,
		pitchVelocity,
		desiredPitch,
		tuning.PitchFrequency * scale,
		tuning.Damping,
		deltaTime
	)
	yawVelocity = nextYawVelocity
	pitchVelocity = nextPitchVelocity
	camera.CFrame = CFrame.new(camera.CFrame.Position) * CFrame.fromOrientation(pitch, yaw, 0)
end

local function updateMarker(camera: Camera, targetModel: Model, targetRoot: BasePart): ()
	local handle = marker
	if handle == nil then
		return
	end
	local scale = Fusion.peek(viewportScale)
	local point = targetRoot.Position + Vector3.new(0, LockOnConstants.Targeting.MarkerHeightStuds, 0)
	local projected, onScreen = camera:WorldToViewportPoint(point)
	if not onScreen or projected.Z <= 0 or scale <= 0 then
		handle.SetVisible(false)
		return
	end
	-- The same two corrections FurnacePromptClient makes: the surface ignores the top-bar inset, and it is
	-- scaled by the one viewport scale.
	handle.SetPosition(Vector2.new(projected.X / scale, (projected.Y + Surface.TopBarInset()) / scale))
	handle.SetVisible(true)

	local targetHumanoid = CharacterUtil.HumanoidOf(targetModel)
	local guard = if targetHumanoid then targetHumanoid:GetAttribute(DefenseConstants.GuardFraction.Attribute) else nil
	handle.SetGuard(if typeof(guard) == "number" then guard else nil)
end

local function onRenderStep(deltaTime: number): ()
	local current = target
	if current == nil then
		return
	end
	if bodyRefusesLock() then
		setTarget(nil)
		return
	end
	local root = rootPart :: BasePart
	local targetRoot = CombatTargets.LiveRoot(current, character)
	if targetRoot == nil then
		setTarget(nil)
		return
	end
	if (targetRoot.Position - root.Position).Magnitude > LockOnConstants.Targeting.BreakRangeStuds then
		setTarget(nil)
		return
	end
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end

	local aim = targetRoot.Position + Vector3.new(0, LockOnConstants.Targeting.AimHeightStuds, 0)
	local now = os.clock()
	if hasLineOfSight(camera.CFrame.Position, aim, current) then
		lastVisibleAt = now
	elseif now - lastVisibleAt > LockOnConstants.Targeting.OcclusionGraceSeconds then
		setTarget(nil)
		return
	end

	if camera.CameraType == Enum.CameraType.Custom then
		pullCamera(camera, aim, deltaTime)
	end
	updateMarker(camera, current, targetRoot)
end

local function onCharacter(newCharacter: Model, newHumanoid: Humanoid, _life: Trove.TroveInstance): ()
	setTarget(nil)
	local root = CharacterUtil.AwaitRoot(newCharacter)
	if root == nil then
		return
	end
	character = newCharacter
	humanoid = newHumanoid
	rootPart = root
end

local function onCharacterRemoving(): ()
	setTarget(nil)
	character = nil
	humanoid = nil
	rootPart = nil
end

-- Public -----------------------------------------------------------------------------------------------

-- The current lock-on target, or nil.
function LockOnController.GetTarget(): Model?
	return target
end

-- Releases any lock. For a caller that knows a lock must not survive what it is about to do.
function LockOnController.Release(): ()
	setTarget(nil)
end

-- Called with the new target (or nil) on every change. Returns a disconnect function.
function LockOnController.OnTargetChanged(listener: (Model?) -> ()): () -> ()
	table.insert(targetChangedListeners, listener)
	return function()
		local index = table.find(targetChangedListeners, listener)
		if index then
			table.remove(targetChangedListeners, index)
		end
	end
end

-- `markerHandle` and `scale` are UIHandles.LockOnMarker and UIHandles.ViewportScale.
function LockOnController.Start(markerHandle: LockOnMarkerModule.LockOnMarkerHandle, scale: Fusion.UsedAs<number>): ()
	if started then
		return
	end
	started = true
	marker = markerHandle
	viewportScale = scale

	InputRouter.Bind("LockOn", {
		Layer = "Gameplay",
		Began = function()
			toggle()
		end,
	})

	PlayerLifecycle.BindLocalCharacter({
		Scope = "LockOnController",
		OnCharacter = onCharacter,
		OnCharacterRemoving = onCharacterRemoving,
	})

	RunService:BindToRenderStep(RENDER_STEP_NAME, Enum.RenderPriority.Camera.Value - 1, onRenderStep)

	logger:info("LockOnController started", { player = Players.LocalPlayer.Name })
end

return LockOnController
