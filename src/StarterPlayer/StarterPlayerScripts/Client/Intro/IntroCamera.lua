--!strict
--[[
	IntroCamera.lua

	Owns: the one Scriptable-camera lifecycle for the entire cinematic intro -- ground-level lying POV
	(BeginCinematic) -> cinematic pan up into a held overhead composition, driven by the SAME
	elapsed/duration fraction Client/Onboarding/OnboardingClient.RunCinematicStage already computes for
	its own text-reveal timing (UpdateCinematicProgress -- no second timing loop) -> held overhead
	through character creation (HoldOverheadComposition) -> first-person lying anchor once the client
	is teleported into the arrival world (EnterFirstPersonAnchor) -> a following ease from that anchor
	up to a standing, level view while the get-up animation plays (BeginGetUpFollow) -> released back to
	Custom (Release) once the awakening beat is fully over.

	Replaces Client/Onboarding/OnboardingClient.lua's old pointCameraAtSky (deleted from that module --
	see its own header). Unlike pointCameraAtSky, this module does NOT revert CameraType to Custom the
	instant the cinematic ends -- the camera stays Scriptable across the black-screen/teleport boundary,
	since first-person control is still needed on the far side of it. Client/Intro/IntroClient.lua is
	the only caller, and owns sequencing every stage below in order; this module only knows how to BE
	each stage, not when to move to the next one.

	CameraOffsetComposer.lua/FOVOffset.lua (the game's other camera-property composers) are
	deliberately NOT involved here: those exist to let ShiftLockCamera/FlightCamera/CameraShake
	compose non-conflicting offsets onto ONE live Custom-mode camera during normal gameplay. This
	module runs entirely BEFORE any of those three ever start (Main.client.lua calls
	Client/Intro/IntroClient.Run() before ShiftLockCamera.Start()/FlightCamera.Start()/CameraShake.
	Start()), driving a fully Scriptable camera with no other writer to coordinate with -- there is
	nothing to compose.

	Does not own: deciding WHEN to advance between stages (IntroClient.lua's job), the black
	screen or vision-effect FX layered on top of what this camera frames (BlackScreen.lua/
	VisionEffects.lua), or loading/playing the lying-down/get-up AnimationTracks (IntroClient.lua,
	via Shared/AnimatorUtil.lua).
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local FlightMath = require(ReplicatedStorage.Shared.FlightMath)
local Logger = require(ReplicatedStorage.Shared.Logger)

local logger = Logger.scope("IntroCamera")

local Config = Constants.Intro.Camera

local IntroCamera = {}

local groundOrigin: Vector3 = Vector3.zero
local cinematicStartClock: number = 0
local overheadHoldConnection: RBXScriptConnection? = nil
local getUpFollowConnection: RBXScriptConnection? = nil

local function getCamera(): Camera?
	return Workspace.CurrentCamera
end

local function characterRootPosition(player: Player): Vector3?
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if rootPart and rootPart:IsA("BasePart") then
		return (rootPart :: BasePart).Position
	end
	return nil
end

-- Symmetric ease-in-out: a plain power curve mirrored around the midpoint (Config.PanEasingPower --
-- 2 is a standard smoothstep-shaped ease). Used for every position/pitch lerp below; yaw drift is
-- linear time, handled separately by yawDrift.
local function easeInOut(fraction: number, power: number): number
	local clamped = math.clamp(fraction, 0, 1)
	if clamped < 0.5 then
		return 0.5 * (2 * clamped) ^ power
	end
	return 1 - 0.5 * (2 * (1 - clamped)) ^ power
end

-- Slow ambient yaw, measured from `sinceClock` -- see Config.OverheadYawDriftDegreesPerSecond's own
-- comment for why a static shot is deliberately avoided here.
local function yawDrift(sinceClock: number): number
	return math.rad((os.clock() - sinceClock) * Config.OverheadYawDriftDegreesPerSecond)
end

local function disconnectOverheadHold(): ()
	if overheadHoldConnection then
		overheadHoldConnection:Disconnect()
		overheadHoldConnection = nil
	end
end

local function disconnectGetUpFollow(): ()
	if getUpFollowConnection then
		getUpFollowConnection:Disconnect()
		getUpFollowConnection = nil
	end
end

-- Begins the cinematic: camera goes Scriptable, and the ground-level origin is captured ONCE from
-- the (frozen, so stationary) player's own HumanoidRootPart -- every subsequent stage's math is
-- relative to this single captured point, not re-read from a live character every frame, since the
-- character never actually moves until the arrival-world teleport (EnterFirstPersonAnchor
-- re-captures a fresh origin for that).
function IntroCamera.BeginCinematic(player: Player): ()
	local camera = getCamera()
	if not camera then
		logger:warn("BeginCinematic: no CurrentCamera")
		return
	end
	camera.CameraType = Enum.CameraType.Scriptable
	groundOrigin = characterRootPosition(player) or Vector3.zero
	cinematicStartClock = os.clock()
	IntroCamera.UpdateCinematicProgress(0)
	logger:debug("Cinematic camera begun", { groundOrigin = groundOrigin })
end

-- Called every Heartbeat from OnboardingClient.RunCinematicStage's own onProgress callback, with
-- elapsedFraction in [0, 1] against Constants.CharacterCreation.CinematicDurationSeconds -- the SAME
-- fraction that timer already computes for its text-reveal pacing, per this file's own header on why
-- there's no second timing loop here.
function IntroCamera.UpdateCinematicProgress(elapsedFraction: number): ()
	local camera = getCamera()
	if not camera then
		return
	end

	local eased = easeInOut(elapsedFraction, Config.PanEasingPower)
	local height = groundOrigin.Y
		+ Config.GroundHeightOffset
		+ (Config.OverheadHeightOffset - Config.GroundHeightOffset) * eased
	local pitchDegrees = Config.GroundLookAngleDegrees
		+ (Config.OverheadLookAngleDegrees - Config.GroundLookAngleDegrees) * eased
	local position = Vector3.new(groundOrigin.X, height, groundOrigin.Z)

	camera.CFrame = CFrame.new(position)
		* CFrame.Angles(0, yawDrift(cinematicStartClock), 0)
		* CFrame.Angles(math.rad(pitchDegrees), 0, 0)
end

-- Snaps to (and then holds) the fully-overhead end of the pan -- called once the cinematic stage
-- ends (whether it played out fully or was skipped), and kept driving every frame through character
-- creation so the slow yaw drift never stops. Safe to call more than once (e.g. re-entrant guard
-- against a caller mistake) -- a second call is a same-state no-op.
function IntroCamera.HoldOverheadComposition(): ()
	IntroCamera.UpdateCinematicProgress(1)
	if overheadHoldConnection then
		return
	end
	overheadHoldConnection = RunService.RenderStepped:Connect(function()
		IntroCamera.UpdateCinematicProgress(1)
	end)
	logger:debug("Overhead composition held")
end

-- Anchors the camera first-person, at eye height above the (now teleported) character's root,
-- looking up -- the same GroundLookAngleDegrees pitch the cinematic opened on, so the awakening
-- reveal continues the same "on your back, looking up" framing rather than starting from a fresh
-- angle. Called while BlackScreen is still opaque, so this snap itself is never seen. Stops the
-- overhead hold from HoldOverheadComposition above.
function IntroCamera.EnterFirstPersonAnchor(player: Player): ()
	disconnectOverheadHold()

	local camera = getCamera()
	if not camera then
		logger:warn("EnterFirstPersonAnchor: no CurrentCamera")
		return
	end

	local origin = characterRootPosition(player) or groundOrigin
	local eyePosition = origin + Vector3.new(0, Config.FirstPersonEyeHeightOffset, 0)
	camera.CFrame = CFrame.new(eyePosition) * CFrame.Angles(math.rad(Config.GroundLookAngleDegrees), 0, 0)
	logger:debug("First-person anchor entered", { origin = origin })
end

-- Begins (non-blocking) the get-up camera follow: eases from wherever the camera currently is (the
-- first-person lying anchor) to a level, standing-eye-height view over `durationSeconds`, tracking
-- the character's LIVE root position every frame (rather than a second captured-once origin) since
-- the get-up animation/Humanoid GettingUp state may nudge it as the character rises. Yaw is held
-- fixed at whatever flat direction the camera was already facing when this began (FlightMath.
-- YawFromFlatDirection) -- deliberately NOT tracking character facing, which isn't reliable while
-- Frozen/mid-animation; holding the intro's own existing look direction avoids an unmotivated spin.
-- Does not release the camera itself once durationSeconds elapses -- IntroClient.lua calls Release()
-- once the get-up AnimationTrack itself is confirmed done, which may land slightly before or after
-- this follow's own timer.
function IntroCamera.BeginGetUpFollow(player: Player, durationSeconds: number): ()
	disconnectGetUpFollow()

	local camera = getCamera()
	if not camera then
		logger:warn("BeginGetUpFollow: no CurrentCamera")
		return
	end

	local startClock = os.clock()
	local startYaw = FlightMath.YawFromFlatDirection(camera.CFrame.LookVector) or 0

	getUpFollowConnection = RunService.RenderStepped:Connect(function()
		local origin = characterRootPosition(player)
		if not origin then
			return
		end

		local fraction = math.clamp((os.clock() - startClock) / durationSeconds, 0, 1)
		local eased = easeInOut(fraction, Config.PanEasingPower)

		local height = Config.FirstPersonEyeHeightOffset
			+ (Config.GetUpFollowStandingHeightOffset - Config.FirstPersonEyeHeightOffset) * eased
		local pitchDegrees = Config.GroundLookAngleDegrees + (0 - Config.GroundLookAngleDegrees) * eased
		local position = origin + Vector3.new(0, height, 0)

		camera.CFrame = CFrame.new(position)
			* CFrame.Angles(0, startYaw, 0)
			* CFrame.Angles(math.rad(pitchDegrees), 0, 0)
	end)
	logger:debug("Get-up camera follow begun", { durationSeconds = durationSeconds })
end

-- Hands the camera back to Custom -- the terminal call, once the whole awakening beat (including the
-- get-up follow above) is over. Client/Camera/ShiftLockCamera.lua/Client/Camera/FlightCamera.lua only
-- start (Main.client.lua's boot order) after Client/Intro/IntroClient.Run() returns, which is only
-- after this has already run, so there's no window where they'd fight this module for CameraType.
function IntroCamera.Release(): ()
	disconnectOverheadHold()
	disconnectGetUpFollow()
	local camera = getCamera()
	if camera then
		camera.CameraType = Enum.CameraType.Custom
	end
	logger:debug("Camera released to Custom")
end

return IntroCamera
