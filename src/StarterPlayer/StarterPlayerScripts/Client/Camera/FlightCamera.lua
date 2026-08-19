--!strict
--[[
	FlightCamera.lua

	Owns: camera feel while the LOCAL player's own Humanoid has "Flying" true -- FOV widening with
	speed, a backward CameraOffset chase pull-back, and an optional camera roll matching the
	character's own bank angle (Constants.Camera.Flight.BankRollFraction, 0 disables it outright).
	A sibling to Client/Camera/ShiftLockCamera.lua, independently watching its own bound character's
	"Flying" Attribute for engage/disengage (same self-contained-watch idiom that module already uses
	for "RootControlLocked") -- Client/DevMenu/FlightController.lua never calls an explicit Stop()
	here, it just flips the Attribute and this module reacts on its own.

	Also owns: LocalPlayer.DevCameraOcclusionMode for the engaged duration. CameraType stays Custom
	throughout (this module only ever nudges CameraOffset/FOV/roll on top of Roblox's own follow-cam,
	same as ShiftLockCamera.lua) -- but the stock camera's default occlusion mode (Zoom) fights Noclip
	flight specifically: Noclip is a raw CFrame write that bypasses collision entirely (Client/DevMenu/
	FlightController.lua's own header), yet the default camera still tries to avoid clipping through
	whatever the character is now flying through, yanking itself toward the character the instant a
	wall is between them -- a live playtest reported this as "colliding with something in the air"
	despite Collide mode being off. Switching to Invisicam (fades the obstructing part transparent
	locally instead of moving the camera) removes that fight entirely while flying, without needing to
	take over CameraType and reimplement the default camera's mouse-orbit/zoom from scratch.

	Binds at the SAME Enum.RenderPriority.Camera.Value + 1 slot ShiftLockCamera.lua uses for its own
	yaw write -- safe specifically because ShiftLockCamera.lua skips its yaw write while Flying is
	true (see that file's own `flying` guard). Client/FX/CameraShake.lua's Camera+2 composition needs
	no change: it already layers on top of whatever Camera+1 produced, so the hard-landing shake
	"just works" regardless of which of the two modules drove that frame's Camera+1 pass.

	The FieldOfView write itself goes through Client/FX/FOVOffset.lua (a named "Flight" continuous
	slot) rather than a direct camera.FieldOfView write -- see that module's header for why: this
	used to capture its own baseFov once at engage time and write baseFov+delta every frame,
	independently of SwingEffect's own direct write, which could fight (and would have fought
	Sprint/Slide's zoom too, once those existed). This module still owns the EASING math
	(currentFovDelta above) -- it just hands the already-eased result to FOVOffset instead of the
	camera. The CameraOffset chase-pullback write goes through Client/FX/CameraOffsetComposer.lua
	the same way (its own "Flight" continuous slot) -- see that module's header for the identical
	reasoning, just for CameraOffset instead of FieldOfView; it's what replaced the old direct
	Humanoid.CameraOffset write and the manual mutual-exclusion this file's header used to describe
	above.

	Does not own: the decision to grant flight (AdminActionSystem.SetFlying), the momentum/banking
	MATH (Shared/FlightMath.lua, Client/DevMenu/FlightController.lua), or any Humanoid property other
	than CameraOffset (WalkSpeed/PlatformStand/etc. stay owned exactly where they already are).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local FlightConstants = require(ReplicatedStorage.Shared.Flight.FlightConstants)
local FlightMath = require(ReplicatedStorage.Shared.FlightMath)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local FOVOffset = require(script.Parent.Parent.FX.FOVOffset)
local CameraOffsetComposer = require(script.Parent.Parent.FX.CameraOffsetComposer)

local logger = Logger.scope("FlightCamera")

local RENDER_STEP_NAME = "FlightCameraUpdate"

local FlightCamera = {}

local humanoid: Humanoid? = nil
local engaged = false

local currentFovDelta = 0
local currentChaseOffset = 0

-- Captured/restored on engage/disengage -- never assumes the default is Zoom, since some other
-- system could have already set Invisicam for its own reasons.
local savedOcclusionMode: Enum.DevCameraOcclusionMode = Enum.DevCameraOcclusionMode.Zoom

-- Pushed every frame by FlightController.lua's stepFlight.
local currentSpeedFraction = 0
local currentBankRadians = 0

local function setEngaged(nowEngaged: boolean, camera: Camera?): ()
	if nowEngaged == engaged then
		return
	end
	engaged = nowEngaged
	local localPlayer = Players.LocalPlayer
	if engaged and camera then
		savedOcclusionMode = localPlayer.DevCameraOcclusionMode
		localPlayer.DevCameraOcclusionMode = Enum.DevCameraOcclusionMode.Invisicam
	end
	if not engaged then
		currentFovDelta = 0
		currentChaseOffset = 0
		CameraOffsetComposer.ClearContinuous("Flight")
		FOVOffset.ClearContinuous("Flight")
		localPlayer.DevCameraOcclusionMode = savedOcclusionMode
	end
	logger:debug("Flight camera engagement changed", { engaged = engaged })
end

local function onRenderStep(deltaTime: number): ()
	local camera = Workspace.CurrentCamera
	local currentHumanoid = humanoid
	local hasLiveCharacter = camera ~= nil and currentHumanoid ~= nil and currentHumanoid.Health > 0
	local wantsEngaged = hasLiveCharacter
		and currentHumanoid ~= nil
		and currentHumanoid:GetAttribute(Constants.Attributes.Flying) == true

	setEngaged(wantsEngaged, camera)
	if not engaged or not camera or not currentHumanoid then
		return
	end

	local cfg = Constants.Camera.Flight
	local alphaFov = FlightMath.EaseAlpha(cfg.FOVEaseSpeed, deltaTime)
	local alphaChase = FlightMath.EaseAlpha(cfg.ChaseEaseSpeed, deltaTime)

	local targetFovDelta = currentSpeedFraction * cfg.FOVMaxDeltaAtBoost
	currentFovDelta += (targetFovDelta - currentFovDelta) * alphaFov
	-- Already eased above -- hand FOVOffset the final value with no easeSpeed of its own (nil means
	-- "snap to this," not "ease toward this," avoiding a double-ease).
	FOVOffset.SetContinuous("Flight", currentFovDelta)

	local targetChaseOffset = currentSpeedFraction * cfg.ChasePullBackMaxStuds
	currentChaseOffset += (targetChaseOffset - currentChaseOffset) * alphaChase
	-- +Z is backward in Humanoid.CameraOffset's local space (matches ShiftLockCamera.lua's own
	-- ShoulderOffset convention, X=right/Y=up/Z=back) -- Studio-verify the sign reads as a pull-back,
	-- not a push-in, once real flight is playtested. Already eased above -- same "hand over the
	-- final value, no easeSpeed of its own" reasoning as FOVOffset.SetContinuous just above.
	CameraOffsetComposer.SetContinuous("Flight", Vector3.new(0, 0, currentChaseOffset))

	if cfg.BankRollFraction ~= 0 then
		camera.CFrame = camera.CFrame * CFrame.Angles(0, 0, currentBankRadians * cfg.BankRollFraction)
	end
end

-- Called every Heartbeat by FlightController.lua's stepFlight. `_pitchAngleRadians` isn't read yet
-- (reserved for a future pitch-based effect, e.g. extra FOV on a steep dive) -- accepted now so the
-- call site's signature doesn't need to change later.
function FlightCamera.SetFlightMotion(
	speed: number,
	bankAngleRadians: number,
	_pitchAngleRadians: number,
	isBoosting: boolean
): ()
	local cfg = FlightConstants
	local maxSpeed = cfg.CruiseSpeed * (if isBoosting then cfg.BoostSpeedMultiplier else 1)
	currentSpeedFraction = math.clamp(speed / math.max(maxSpeed, 1), 0, 1)
	currentBankRadians = bankAngleRadians
end

function FlightCamera.Start(): ()
	-- The Humanoid wait, the already-present-character task.spawn, and the "is this still the current
	-- character after the wait" re-check all moved into Shared/PlayerLifecycle.lua -- this module wrote
	-- all three by hand, correctly, and was one of only two that did. See that module's header.
	PlayerLifecycle.BindLocalCharacter({
		Scope = "FlightCamera",
		OnCharacter = function(_character: Model, boundHumanoid: Humanoid)
			humanoid = boundHumanoid
		end,
		OnCharacterRemoving = function()
			humanoid = nil
			engaged = false
		end,
	})

	RunService:BindToRenderStep(RENDER_STEP_NAME, Enum.RenderPriority.Camera.Value + 1, onRenderStep)
	logger:info("FlightCamera started")
end

return FlightCamera
