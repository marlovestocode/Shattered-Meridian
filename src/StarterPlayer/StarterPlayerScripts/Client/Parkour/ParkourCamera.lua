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

-- THE MANTLE'S CONTINUOUS CAMERA FEED. Pushed every frame the state is active (ParkourController's
-- own frame, alongside SetSpeed/SetWallSide), with `alpha` the climb's own 0..1 progress -- the exact
-- same fraction States/Mantling.lua's Update already computes for the traversal curve, so the camera
-- and the character's actual motion are reading off the same clock rather than two independently
-- authored timings that can drift out of sync.
--
-- Shaped with a sine bump (0 at the start, peak at the climb's midpoint, back to 0 at the top) rather
-- than eased toward a held target: a pull-up has an effort in the MIDDLE, not at either end -- the
-- reach and the final step up are the calm parts, the moment the character's weight is fully hanging
-- off their arms is not. Ending exactly at 0 as alpha reaches 1 is what lets the climb hand off to
-- ordinary locomotion with nothing left to clear.
function ParkourCamera.SetMantleProgress(alpha: number): ()
	if not effectsEnabled then
		return
	end
	local clamped = math.clamp(alpha, 0, 1)
	local shape = math.sin(math.pi * clamped)
	FOVOffset.SetContinuous(CAMERA.MantleFOVSlot, CAMERA.MantleClimbFOVDelta * shape, CAMERA.MantleClimbFOVEaseSpeed)
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

	-- Vault only. See ParkourConstants.Camera's "MANTLE GETS ITS OWN TREATMENT" note for why Mantling
	-- was pulled out of this branch -- its camera feed is continuous (SetMantleProgress below), pushed
	-- every frame for the climb's whole duration, not a one-shot here.
	if next == "Vaulting" then
		FOVOffset.Punch(
			CAMERA.VaultFOVSlot,
			CAMERA.VaultFOVPunchDelta,
			CAMERA.VaultFOVPunchOutSeconds,
			CAMERA.VaultFOVPunchBackSeconds
		)
		CameraShake.Shake(SHAKE.Vault)
	end
	-- The dash, on the same one-shot Punch path as the vault above and for the same structural
	-- reason: it is a discrete event whose whole effect belongs at the start. The DIRECTION of the
	-- punch is the opposite one, and deliberately so -- see Camera.DashFOVPunchDelta for why a dash
	-- widens where a vault narrows.
	--
	-- No CameraShake to go with it, unlike the vault. Shake is this framework's impact vocabulary
	-- (Vault, WallJump, hard landing, slide-start -- every preset is a collision with something), and
	-- a dash does not hit anything; it is a launch into open air. Shaking it would say the player ran
	-- into their own dash. If the launch later wants a physical cue beyond the FOV, the honest place
	-- for it is the spring's own overshoot, which is already doing that job in the velocity.
	if next == "Dashing" then
		FOVOffset.Punch(
			CAMERA.DashFOVSlot,
			CAMERA.DashFOVPunchDelta,
			CAMERA.DashFOVPunchOutSeconds,
			CAMERA.DashFOVPunchBackSeconds
		)
	end
	-- The climb's continuous feed cannot be relied on to reach 0 on its own: a mantle can end early
	-- (falling off a narrow ledge mid-climb -- see that state's own Update) or be interrupted (combat
	-- taking the body), and SetMantleProgress is only ever pushed while the state is actually current.
	-- Cleared here, on every exit, the same way Sliding's own slideDrop is.
	if previous == "Mantling" then
		FOVOffset.SetContinuous(CAMERA.MantleFOVSlot, 0, CAMERA.MantleClimbFOVEaseSpeed)
	end

	-- No "next == WallJumping" branch here any more -- the kick is a phase of WallRunning now, not a
	-- transition OnStateChanged ever sees (see States/WallRunning.lua's header). Its camera punch is
	-- ParkourCamera.PlayWallKick below, called directly by ParkourController on the frame it detects the
	-- SAME-state variant change into a kick, the same way it already calls PlayLanding directly rather
	-- than keying it off a transition string here.

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

-- One-shot punch for the kick phase of States/WallRunning.lua. Called directly by ParkourController on
-- the frame it sees AnimationVariant change into a "Kick*" value -- there is no state TRANSITION to key
-- this off any more (the kick used to be its own state, WallJumping, and this used to fire from
-- OnStateChanged's "next == WallJumping" branch; see that branch's own note for why it moved). A plain
-- function rather than something OnStateChanged dispatches is the honest shape for an event with no
-- state id to name it by.
function ParkourCamera.PlayWallKick(): ()
	if not effectsEnabled then
		return
	end
	CameraShake.Shake(SHAKE.WallJump)
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
	FOVOffset.SetContinuous(CAMERA.MantleFOVSlot, 0, CAMERA.MantleClimbFOVEaseSpeed)
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
	FOVOffset.ClearContinuous(CAMERA.MantleFOVSlot)
	FOVOffset.ClearContinuous(CAMERA.DashFOVSlot)
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
