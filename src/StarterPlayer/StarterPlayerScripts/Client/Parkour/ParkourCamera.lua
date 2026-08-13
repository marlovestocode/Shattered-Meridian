--!strict
--[[
	ParkourCamera.lua

	Owns: the camera's reaction to movement -- speed-scaled FOV, the slide's low framing, wall-run
	tilt, landing dips and traversal punches.

	COMPOSES, NEVER WRITES. Every effect here goes through the existing named-slot primitives:
	Client/FX/FOVOffset.lua for FieldOfView, Client/FX/CameraOffsetComposer.lua for CameraOffset,
	Client/FX/CameraShake.lua for rotation. This module owns no camera property directly, which is
	what lets sprint's combat FOV zoom, flight's zoom, a swing punch and a parkour speed-widening all
	be live at once and simply sum, instead of the last writer each frame winning. Those two composer
	modules' own headers describe exactly the fight this avoids; adding a fourth uncoordinated writer
	would have recreated it.

	RESTRAINT IS A REQUIREMENT, NOT A PREFERENCE. The design's constraint was "do not make the camera
	effects so aggressive that they interfere with combat," and docs/ui-ux-philosophy.md's Critical
	States rule says the same thing about emphasis generally. So: the wall-run tilt is 9 degrees, not
	25; the landing dip is measured in fractions of a stud; and the speed FOV widening tops out at 7
	degrees, reached only at a speed a player has to work for. Every one of those numbers lives in
	ParkourConstants.Camera and every one of these effects can be switched off wholesale by the player
	(SetEffectsEnabled), which is the design's "allowing players to customize or disable these effects
	through the settings."

	Does not own: deciding when the player is sliding/landing/wall-running (ParkourController pushes
	state transitions in), or any camera framing/lock behavior (Client/Camera/ShiftLockCamera.lua and
	FlightCamera.lua keep that).
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

local CameraOffsetComposer = require(script.Parent.Parent.FX.CameraOffsetComposer)
local CameraShake = require(script.Parent.Parent.FX.CameraShake)
local FOVOffset = require(script.Parent.Parent.FX.FOVOffset)

type MovementStateId = ParkourTypes.MovementStateId

local CAMERA = ParkourConstants.Camera
local SHAKE = ParkourConstants.Shake

local ParkourCamera = {}

local RENDER_STEP_NAME = "ParkourCameraTilt"

local started = false
local effectsEnabled = true

-- Live tilt (degrees) and the target it eases toward. Tilt is applied as a camera ROLL, composed on
-- top of whatever the camera already is -- the same post-multiply approach CameraShake.lua uses, and
-- at a later render priority than the camera scripts for the same reason: the default camera rewrites
-- its base CFrame every frame, which is exactly what lets an additive roll read as a lean that
-- settles rather than a permanent tilt.
local currentTilt = 0
local targetTilt = 0

-- Vertical camera drop currently requested, in studs. Fed to CameraOffsetComposer as a single slot,
-- so the slide's sustained crouch framing and a landing's one-shot dip share one channel and cannot
-- fight -- the larger of the two simply wins for as long as it is asking.
local slideDrop = 0
local landingDip = 0

local function refreshOffset(): ()
	if not effectsEnabled then
		CameraOffsetComposer.SetContinuous(CAMERA.OffsetSlot, Vector3.zero, CAMERA.LandingDipRecoverSpeed)
		return
	end
	local drop = math.max(slideDrop, landingDip)
	CameraOffsetComposer.SetContinuous(CAMERA.OffsetSlot, Vector3.new(0, -drop, 0), CAMERA.LandingDipRecoverSpeed)
end

-- Continuous per-frame feed: how fast the character is actually moving. Drives the speed FOV, which
-- is the one effect that is a function of a number rather than of an event.
function ParkourCamera.SetSpeed(planarSpeed: number): ()
	if not effectsEnabled then
		return
	end
	local reference = math.max(CAMERA.SpeedFOVFullAtSpeed - ParkourConstants.Locomotion.SprintSpeed, 1e-3)
	-- Only speed ABOVE sprint counts. Ordinary sprinting already has its own FOV treatment
	-- (Constants.Camera.Sprint, driven from CombatClient) and stacking a second one on top of it would
	-- double the effect for the most common movement state in the game.
	local excess = math.clamp((planarSpeed - ParkourConstants.Locomotion.SprintSpeed) / reference, 0, 1)
	FOVOffset.SetContinuous(CAMERA.SpeedFOVSlot, CAMERA.SpeedFOVMaxDelta * excess, CAMERA.SpeedFOVEaseSpeed)
end

-- Called on every state transition. One entry point rather than a function per effect, so the
-- "which effects belong to which state" mapping is visible in one place and a new state cannot
-- accidentally inherit the previous one's camera treatment.
function ParkourCamera.OnStateChanged(previous: MovementStateId, next: MovementStateId): ()
	if not effectsEnabled then
		return
	end

	if previous == "Sliding" then
		FOVOffset.SetContinuous(CAMERA.SlideFOVSlot, 0, CAMERA.SlideFOVEaseSpeed)
		slideDrop = 0
		refreshOffset()
	end
	if next == "Sliding" then
		FOVOffset.SetContinuous(CAMERA.SlideFOVSlot, CAMERA.SlideFOVDelta, CAMERA.SlideFOVEaseSpeed)
		slideDrop = CAMERA.SlideCameraDropStuds
		refreshOffset()
		CameraShake.Shake(SHAKE.SlideStart)
	end

	if next == "Vaulting" or next == "Mantling" then
		FOVOffset.Punch(
			CAMERA.VaultFOVSlot,
			CAMERA.VaultFOVPunchDelta,
			CAMERA.VaultFOVPunchOutSeconds,
			CAMERA.VaultFOVPunchBackSeconds
		)
		CameraShake.Shake(SHAKE.Vault)
	end

	if next == "WallJumping" then
		CameraShake.Shake(SHAKE.WallJump)
	end

	-- Tilt belongs to wall-running only. Cleared on every transition INTO anything else rather than
	-- only on transition out of WallRunning, so a tilt can never survive a state the framework forced
	-- (a respawn, combat taking the body) that skipped the ordinary exit.
	if next ~= "WallRunning" then
		targetTilt = 0
	end
end

-- Wall-run tilt direction: -1 for a wall on the left, 1 for the right, 0 for none. Pushed per frame
-- by the controller rather than derived here, because the controller already has the resolved side
-- from the state's own animation variant and re-deriving it would mean this module needing the wall
-- probes too.
function ParkourCamera.SetWallSide(side: number): ()
	if not effectsEnabled then
		targetTilt = 0
		return
	end
	targetTilt = -side * CAMERA.WallRunTiltDegrees
end

-- One-shot landing dip, scaled by severity. The dip decays on its own through the offset composer's
-- ease, so there is nothing to schedule and nothing to cancel if the player is interrupted mid-dip.
function ParkourCamera.PlayLanding(severity: "Soft" | "Medium" | "Hard"): ()
	if not effectsEnabled then
		return
	end
	if severity == "Soft" then
		landingDip = CAMERA.LandingDipSoftStuds
	elseif severity == "Medium" then
		landingDip = (CAMERA.LandingDipSoftStuds + CAMERA.LandingDipHardStuds) * 0.5
	else
		landingDip = CAMERA.LandingDipHardStuds
		CameraShake.Shake(SHAKE.HardLanding)
	end
	refreshOffset()
	-- Release the dip on the next frame; the composer's own ease is what makes it a smooth dip-and-
	-- recover rather than a snap. Scheduled rather than decayed here because this module has no
	-- per-frame ownership of the offset value -- the composer does.
	task.defer(function()
		landingDip = 0
		refreshOffset()
	end)
end

-- Player-facing master switch for every effect in this module (Settings -> Gameplay). Clears
-- everything currently applied on the way off, rather than merely refusing new effects -- a player
-- disabling camera effects mid-slide should see the slide's framing released immediately, not held
-- until the slide happens to end.
function ParkourCamera.SetEffectsEnabled(enabled: boolean): ()
	effectsEnabled = enabled
	if enabled then
		return
	end
	FOVOffset.SetContinuous(CAMERA.SpeedFOVSlot, 0, CAMERA.SpeedFOVEaseSpeed)
	FOVOffset.SetContinuous(CAMERA.SlideFOVSlot, 0, CAMERA.SlideFOVEaseSpeed)
	slideDrop = 0
	landingDip = 0
	targetTilt = 0
	refreshOffset()
end

-- Full teardown, for character removal. Hard-clears the FOV slots (rather than easing them to zero)
-- because there is no longer anything on screen for the ease to look right against.
function ParkourCamera.Reset(): ()
	FOVOffset.ClearContinuous(CAMERA.SpeedFOVSlot)
	FOVOffset.ClearContinuous(CAMERA.SlideFOVSlot)
	FOVOffset.ClearContinuous(CAMERA.VaultFOVSlot)
	CameraOffsetComposer.ClearContinuous(CAMERA.OffsetSlot)
	slideDrop = 0
	landingDip = 0
	targetTilt = 0
	currentTilt = 0
end

local function onRenderStep(deltaTime: number): ()
	if currentTilt == 0 and targetTilt == 0 then
		return
	end
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	currentTilt += (targetTilt - currentTilt) * ParkourMath.EaseAlpha(CAMERA.WallRunTiltEaseSpeed, deltaTime)
	if math.abs(currentTilt) < 0.01 then
		currentTilt = 0
		return
	end
	camera.CFrame *= CFrame.Angles(0, 0, math.rad(currentTilt))
end

-- Binds the tilt compositor. Camera + 3 puts it after the default camera scripts (Camera),
-- ShiftLockCamera/FlightCamera's CameraOffset writes (Camera + 1) and CameraShake's rotation
-- (Camera + 2) -- so the tilt lands on the frame's final pose and layers with the shake rather than
-- one overwriting the other.
function ParkourCamera.Start(): ()
	if started then
		return
	end
	started = true
	RunService:BindToRenderStep(RENDER_STEP_NAME, Enum.RenderPriority.Camera.Value + 3, onRenderStep)
end

return ParkourCamera
