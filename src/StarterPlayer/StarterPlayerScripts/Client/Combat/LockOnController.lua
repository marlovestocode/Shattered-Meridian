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

	THE CAMERA IS NOT STEERED HERE. Client/Camera/CombatCamera.lua (the combat camera manager) owns the soft pull of the
	look toward the target, and calls Step from its own aim step every frame, BEFORE the default camera scripts
	(its CombatCameraAim slot): Step runs the break rules, draws the marker and hands back the point to aim at. This
	module used to bind that render step itself and write Camera.CFrame from inside it, which put a second camera writer
	in the Combat folder beside shift lock's, ordered against it only by a priority value.

	THE TARGET IS AIM AND PRESENTATION, NEVER TRUSTED. It is never sent to the server. Swing tracking
	(SwingTracking.lua) reads GetTarget to turn the body during a windup, and the server's hitbox reads the
	body's real replicated facing like any other swing.

	Does not own: the camera (CombatCamera), the candidate list (CombatTargets.lua), turning the body during a swing (SwingTracking),
	the marker's look (Screens/LockOnMarker), or any opponent's guard value (DefenseSystem publishes it).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local LockOnConstants = require(ReplicatedStorage.Shared.Combat.LockOnConstants)
local CallbackList = require(ReplicatedStorage.Shared.CallbackList)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local Trove = require(ReplicatedStorage.Shared.Trove)
local BodyRestraint = require(ReplicatedStorage.Shared.Combat.BodyRestraint)

local InputRouter = require(script.Parent.Parent.Input.InputRouter)
local LockOnMarkerModule = require(script.Parent.Parent.UI.Screens.LockOnMarker)
local Surface = require(script.Parent.Parent.UI.Shell.Surface)
local CombatTargets = require(script.Parent.CombatTargets)

local logger = Logger.scope("LockOnController")

local LockOnController = {}

local target: Model? = nil
-- When the target was last in line of sight (os.clock), for OcclusionGraceSeconds.
local lastVisibleAt = 0

local character: Model? = nil
local humanoid: Humanoid? = nil
local rootPart: BasePart? = nil

local marker: LockOnMarkerModule.LockOnMarkerHandle? = nil
local viewportScale: Fusion.UsedAs<number> = 1
local started = false

local targetChangedListeners: CallbackList.CallbackList<Model?> =
	CallbackList.New(logger, "LockOnController.OnTargetChanged")

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
	local handle = marker
	if handle then
		handle.SetVisible(false)
		handle.SetGuard(nil)
	end
	targetChangedListeners:Fire(newTarget)
	logger:debug(if newTarget then "Locked on" else "Lock released", {
		target = if newTarget then newTarget.Name else nil,
	})
end

-- Whether the local body is in any state that cannot hold a lock.
local function bodyRefusesLock(): boolean
	local currentHumanoid = humanoid
	if currentHumanoid == nil or rootPart == nil then
		return true
	end
	-- BodyRestraint's "LockOn" row: dead, mounted or flying.
	return BodyRestraint.Restrained(currentHumanoid, "LockOn")
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

-- One frame of the lock: the break rules, the marker, and the point the camera should aim at -- or nil when nothing is
-- locked, the lock just broke, or there is no camera. Called by CombatCamera's aim step (see this file's header).
local function lockStep(): Vector3?
	local current = target
	if current == nil then
		return nil
	end
	if bodyRefusesLock() then
		setTarget(nil)
		return nil
	end
	local root = rootPart :: BasePart
	local targetRoot = CombatTargets.LiveRoot(current, character)
	if targetRoot == nil then
		setTarget(nil)
		return nil
	end
	if (targetRoot.Position - root.Position).Magnitude > LockOnConstants.Targeting.BreakRangeStuds then
		setTarget(nil)
		return nil
	end
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return nil
	end

	local aim = targetRoot.Position + Vector3.new(0, LockOnConstants.Targeting.AimHeightStuds, 0)
	local now = os.clock()
	if hasLineOfSight(camera.CFrame.Position, aim, current) then
		lastVisibleAt = now
	elseif now - lastVisibleAt > LockOnConstants.Targeting.OcclusionGraceSeconds then
		setTarget(nil)
		return nil
	end

	updateMarker(camera, current, targetRoot)
	return aim
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

-- Runs this frame of the lock (see lockStep) and returns the point to aim the camera at, or nil. Labelled for the
-- MicroProfiler (Ctrl+F6), so a lock-on frame cost shows up as its own bar. CombatCamera is the one caller.
function LockOnController.Step(): Vector3?
	if target == nil then
		return nil
	end
	debug.profilebegin("LockOn")
	local aim = lockStep()
	debug.profileend()
	return aim
end

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
	return targetChangedListeners:Connect(listener)
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

	logger:info("LockOnController started", { player = Players.LocalPlayer.Name })
end

return LockOnController
