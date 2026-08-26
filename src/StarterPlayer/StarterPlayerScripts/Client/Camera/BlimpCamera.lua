--!strict
--[[
	BlimpCamera.lua

	Owns: the local player's camera for as long as they are standing on a blimp -- reading the hull's
	real motion off the physics engine every frame and turning it into roll into the turn, sway behind
	it, pitch with the climb, a positional surge under acceleration and braking, a pull-back with
	speed, an idle hover bob at rest, and an FOV that opens up as the ship gets going. Also owns
	DevCameraOcclusionMode for the duration.

	A SIBLING OF Client/Camera/FlightCamera.lua, not a replacement, and the two can never be engaged at
	once (a flying admin is not welded to a helm). The composition posture is identical and deliberately
	so: CameraType stays Custom throughout, so Roblox's own follow-cam keeps doing the mouse orbit, the
	zoom and the collision, and this module only nudges what is already there. It writes rotation onto
	camera.CFrame at Enum.RenderPriority.Camera + 1, its positional offset through Client/FX/
	CameraOffsetComposer.lua's named "Blimp" slot, and its FOV through Client/FX/FOVOffset.lua's -- never
	Humanoid.CameraOffset or camera.FieldOfView directly. Those two composers exist precisely so a third
	writer can be added without the manual mutual-exclusion flags their headers describe; this is that
	third writer, and it needed no changes to either.

	IT READS THE HULL, NOT THE SERVER, AND THAT IS THE WHOLE ARCHITECTURE. The obvious alternative is
	to stream BlimpDrive's own integrator state (Speed/YawRate/ClimbRate) down to the pilot and drive
	the camera off it. That is worse on both axes at once. It costs a per-frame packet per passenger
	for information already on the client -- the hull is a physically simulated, server-owned assembly,
	so Roblox is ALREADY replicating its CFrame and its velocities, for free, to everyone who can see
	it. And it is less accurate: the server's Target is the pose the hull is being ASKED to reach, and
	the gap between that target and where the hull actually is IS the floatiness this whole system is
	built around (see Server/Blimp/BlimpDrive.lua's header). A camera driven by the target would show
	the ship the drive wishes it had. This one shows the ship that is there.

	station.AssemblyRootPart IS the hull root, with no lookup at all -- every part of a blimp is welded
	into one assembly by Server/Blimp/BlimpAssembly.lua, so the station the player is standing at and
	the hull's own root are members of the same rigid body by construction. That is why engaging costs
	one property read rather than an ancestor walk plus a tag query.

	IT IS RE-READ EVERY FRAME, NOT CACHED AT MOUNT, and that is a bug fix rather than a style choice.
	AssemblyRootPart is not a constant: the engine re-elects it whenever the assembly's shape changes,
	which on a blimp is every single time anybody mounts or dismounts (each mount welds a character in,
	and Server/Systems/BlimpSystem then re-runs RefreshForceLimits/ClaimOwnership). Worse, a client that
	has not yet received the hull's own welds resolves the STATION ITSELF as its own one-part assembly
	-- and that part reports zero velocity, so a camera that cached it at mount time would spend the
	entire flight being told the ship was standing still. Every effect downstream of this reference --
	the camera, the wind, the audio -- would silently do nothing, which is exactly what that failure
	looked like from the deck.

	IT BINDS ON MOUNT AND UNBINDS ON RELEASE, unlike FlightCamera/ShiftLockCamera, which stay bound for
	the session and early-out. Those two are watching for a state that can begin at any moment with no
	external signal; this one is told, by Client/Blimp/BlimpController.lua, which already knows. Most
	players never board a blimp, and a permanently bound render step that only ever checks a nil is a
	cost paid by every client in the server for a feature almost none of them are using this minute.

	THE RELEASE IS NOT A CUT. On dismount the measured motion is zeroed but the springs keep running,
	so every channel settles back to level over its own rate and the step unbinds itself once they have
	-- see releasing/onRenderStep. Snapping a roll of eight degrees back to zero in one frame is the
	single most jarring thing this module could do, and it would happen every single time a player let
	go of the wheel.

	Does not own: the maths (Shared/Blimp/BlimpCameraMath.lua -- every number in this file's behaviour
	is decided there, so that it can be tested without a place file), the tuning
	(Shared/Blimp/BlimpConstants.Camera), who is mounted (Server/Systems/BlimpSystem.lua, relayed by
	BlimpController), the mounted BODY's lean (Shared/Blimp/BlimpPilotPose.lua -- a different pose on a
	different channel), or any camera property other than CFrame rotation and the two composed slots.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local BlimpCameraMath = require(ReplicatedStorage.Shared.Blimp.BlimpCameraMath)
local BlimpConstants = require(ReplicatedStorage.Shared.Blimp.BlimpConstants)
local BlimpTagging = require(ReplicatedStorage.Shared.Blimp.BlimpTagging)
local Logger = require(ReplicatedStorage.Shared.Logger)

local CameraOffsetComposer = require(script.Parent.Parent.FX.CameraOffsetComposer)
local FOVOffset = require(script.Parent.Parent.FX.FOVOffset)

local logger = Logger.scope("BlimpCamera")

local RENDER_STEP_NAME = "BlimpCameraUpdate"
local COMPOSER_SLOT = "Blimp"
-- A DIFFERENT name from COMPOSER_SLOT above, and that is not cosmetic: Client/FX/FOVOffset.lua
-- keys Continuous and Punch slots into ONE flat table, so reusing "Blimp" for the telegraph punch
-- would replace this camera's own speed-zoom slot with a one-shot that deletes itself half a
-- second later -- and the zoom would simply stop existing for the rest of the flight.
local FOV_PUNCH_SLOT = "BlimpTelegraph"

local BlimpCamera = {}

local state = BlimpCameraMath.NewState()

-- The STATION the local player is welded to while mounted, nil the rest of the time -- which is also
-- the flag for "is there anything to measure". The hull root is derived from it per frame rather than
-- stored beside it; see this file's header for why caching that reference is a bug.
local station: BasePart? = nil

-- The hull assembly's root, or nil if there is nothing mounted or the station has stopped existing.
-- One property read, called once per frame from three places.
local function resolveHull(): BasePart?
	local currentStation = station
	if not currentStation or currentStation.Parent == nil then
		return nil
	end
	return currentStation.AssemblyRootPart
end
-- This hull's OWN resolved cruise speed, not the shipped default: a hull tuned to half speed should
-- reach full pull-back at ITS full speed. Resolved once on mount rather than per frame.
local cruiseSpeed = BlimpConstants.Drive.CruiseSpeed

local bound = false
-- True between a release and the springs having settled -- the window in which this module is still
-- driving the camera with no hull to read. See this file's header on why the release is not a cut.
local releasing = false

-- Types.ComfortSettings.VehicleCameraMotion, pushed by Client/Settings/SettingsClient.lua. Gates the
-- ROTATIONAL channels only -- BlimpCameraMath.Step's own parameter documents why the positional ones
-- deliberately keep running for a player who needed the toggle.
local motionEnabled = true

-- Captured on engage and restored on release -- never assumed to be Zoom, since another system could
-- have already set Invisicam for its own reasons. Exactly what FlightCamera.lua does, and for a
-- closely related reason: there, the default camera fights noclip flight; here, the player is standing
-- INSIDE a large model, so the stock Zoom occlusion mode spends the entire ride yanking the camera
-- toward their head every time a spar, a rail or the balloon itself passes between them and it.
local savedOcclusionMode: Enum.DevCameraOcclusionMode = Enum.DevCameraOcclusionMode.Zoom

-- Below this the springs are close enough to level that the remaining offset is invisible, and the
-- release can finish. A threshold rather than an equality test because a spring approaches zero
-- asymptotically and never actually arrives.
local SETTLED_EPSILON = 1e-3

local function isSettled(): boolean
	local pose = state.Pose
	return math.abs(pose.RollRadians) < SETTLED_EPSILON
		and math.abs(pose.YawRadians) < SETTLED_EPSILON
		and math.abs(pose.PitchRadians) < SETTLED_EPSILON
		and pose.Offset.Magnitude < SETTLED_EPSILON
		and math.abs(pose.FovDelta) < SETTLED_EPSILON
end

local function unbind(): ()
	if not bound then
		return
	end
	bound = false
	releasing = false
	RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	-- Hard removal rather than a settled-at-zero slot left in place: this module is done writing for
	-- now, and a stale slot would keep summing a (tiny, but real) offset into the composer's total for
	-- the rest of the session. The smooth part of the release already happened -- that is what the
	-- releasing window was for.
	CameraOffsetComposer.ClearContinuous(COMPOSER_SLOT)
	FOVOffset.ClearContinuous(COMPOSER_SLOT)
	Players.LocalPlayer.DevCameraOcclusionMode = savedOcclusionMode
end

local function onRenderStep(deltaTime: number): ()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end

	local currentHull = resolveHull()
	-- A hull that stopped existing mid-flight (the model destroyed, the blimp untagged, the station
	-- streamed out) is treated exactly like a dismount rather than as an error: the release path is
	-- already the right behaviour, and it is the only one that leaves the camera somewhere sensible.
	if station and not currentHull then
		station = nil
		releasing = true
	end

	if currentHull then
		BlimpCameraMath.Observe(
			state,
			currentHull.CFrame,
			currentHull.AssemblyLinearVelocity,
			currentHull.AssemblyAngularVelocity,
			cruiseSpeed,
			deltaTime
		)
	end

	BlimpCameraMath.Step(state, deltaTime, motionEnabled)

	local pose = state.Pose
	-- Already sprung upstream, so both composers are handed the FINAL value with no ease rate of their
	-- own -- the same "do not double-ease" contract FlightCamera's own two SetContinuous calls follow.
	CameraOffsetComposer.SetContinuous(COMPOSER_SLOT, pose.Offset)
	FOVOffset.SetContinuous(COMPOSER_SLOT, pose.FovDelta)

	-- Composed onto whatever the stock follow-cam produced this frame rather than replacing it, which
	-- is what keeps mouse orbit, zoom and collision working untouched. Same technique, same
	-- RenderPriority tier and same reasoning as FlightCamera's own bank roll.
	if pose.RollRadians ~= 0 or pose.YawRadians ~= 0 or pose.PitchRadians ~= 0 then
		camera.CFrame = camera.CFrame * CFrame.Angles(pose.PitchRadians, pose.YawRadians, pose.RollRadians)
	end

	if releasing and isSettled() then
		unbind()
	end
end

-- Told by Client/Blimp/BlimpController.lua on every mount and dismount -- station nil means released.
-- Safe to call repeatedly with the same value, and safe to call with a new station while already
-- engaged (a Helm -> Handhold move on the same ship, or a hop between two ships): the springs are
-- deliberately NOT reset in that case, so a player who changes seats mid-turn keeps the lean they
-- were already wearing instead of being snapped level and then leaned again.
function BlimpCamera.SetMount(mountedStation: BasePart?): ()
	if not mountedStation then
		if not bound or releasing then
			return
		end
		-- Zeroed rather than left latched: with no hull to read, the last measured motion would
		-- otherwise hold every spring at its current target forever and the release would never settle.
		BlimpCameraMath.ZeroMotion(state)
		station = nil
		releasing = true
		return
	end

	station = mountedStation
	releasing = false

	local model = BlimpTagging.ModelOf(mountedStation)
	-- Falls back to the shipped default rather than refusing to engage: a station whose model cannot
	-- be resolved is a tagging problem worth a log line, not a reason for the player's camera to stop
	-- responding to the ship they are visibly standing on.
	cruiseSpeed = if model then BlimpTagging.ResolveTuning(model).CruiseSpeed else BlimpConstants.Drive.CruiseSpeed

	if bound then
		return
	end
	bound = true
	savedOcclusionMode = Players.LocalPlayer.DevCameraOcclusionMode
	Players.LocalPlayer.DevCameraOcclusionMode = Enum.DevCameraOcclusionMode.Invisicam
	RunService:BindToRenderStep(RENDER_STEP_NAME, Enum.RenderPriority.Camera.Value + 1, onRenderStep)
	logger:debug("Blimp camera engaged", { cruiseSpeed = cruiseSpeed })
end

-- Types.ComfortSettings.VehicleCameraMotion. Takes effect on the next frame through the springs rather
-- than snapping, so a player toggling it mid-flight sees the roll unwind rather than vanish.
function BlimpCamera.SetMotionEnabled(enabled: boolean): ()
	motionEnabled = enabled
end

-- The engine telegraph moved. `rungDelta` is signed -- positive is a rung toward flank.
--
-- WHY THIS EXISTS AT ALL, since the camera already answers to acceleration: a blimp takes about two
-- and a half seconds to actually answer a rung, so a pilot who rings one down gets no evidence for
-- the better part of a second that the key did anything. That is long enough that players press it
-- again, and a control that appears dead is a worse problem than a control that feels light. The kick
-- is the receipt -- the engines take up the load NOW, and the ship's own slow answer arrives behind it
-- through the ordinary acceleration channel.
--
-- FIRED ON THE SERVER'S CONFIRMATION, not on the keypress. Predicting it locally would be snappier by
-- one round trip and would lie in the one case that matters: pressing W at Flank moves nothing, and a
-- camera that kicks anyway teaches the pilot the ladder has a rung it does not have.
--
-- The two halves go to different owners on purpose. The positional/rotational impulse is a
-- BlimpCameraMath velocity injection, so it rides the vehicle-motion comfort toggle with the rest of
-- this camera; the FOV punch goes through Client/FX/FOVOffset.lua's own Punch slot, so it rides the
-- FieldOfViewEffects toggle alongside every other impact punch in the game. A player who turned off
-- one and not the other gets exactly what they asked for.
function BlimpCamera.Kick(rungDelta: number): ()
	if rungDelta == 0 or not bound then
		return
	end
	if motionEnabled then
		BlimpCameraMath.Kick(state, rungDelta)
	end

	local kick = BlimpConstants.Camera.Kick
	-- Signed by the delta like the impulse above, so ringing DOWN widens rather than narrows -- the
	-- opposite gesture should not produce the identical picture.
	FOVOffset.Punch(
		FOV_PUNCH_SLOT,
		kick.FovPunchDegrees * math.sign(rungDelta),
		kick.FovPunchOutSeconds,
		kick.FovPunchBackSeconds
	)
end

-- The live motion sample, or nil while nothing is mounted. Exposed so the two other per-frame
-- consumers of THE LOCAL PLAYER'S OWN hull -- the helm panel's speed readout and Client/FX/
-- BlimpAudio's two loops -- read the ALREADY FILTERED sample instead of each taking its own raw
-- velocity read and running its own filter. Three independent filters over one signal is three
-- chances to disagree about how fast the ship is going, and two of them would be paying for a
-- smoothing pass that has already been done.
--
-- The mounted BODY's lean is deliberately NOT one of them: that runs for every mounted character on
-- screen, most of whom are on other ships, so it samples each body's own hull rather than borrowing
-- this one -- see Client/Blimp/BlimpController.lua's header.
--
-- Returns the live table, not a copy, deliberately: this is called once per frame per consumer and
-- copying it would reintroduce exactly the per-frame allocation BlimpCameraMath goes out of its way
-- to avoid. Callers read it and do not keep it.
function BlimpCamera.GetMotion(): BlimpCameraMath.Motion?
	if not station then
		return nil
	end
	return state.Motion
end

-- This hull's own resolved cruise speed (BlimpTagging.ResolveTuning), or the shipped default when
-- nothing is mounted. Exposed for the same reason GetMotion is: Client/FX/BlimpWindVFX.lua scales its
-- weather by how fast the ship is going relative to what THIS hull can do, and re-resolving a model's
-- tuning attributes per frame to learn a number already sitting in this module would be waste.
function BlimpCamera.GetCruiseSpeed(): number
	return cruiseSpeed
end

-- The hull the local player is currently aboard, or nil -- for a consumer that needs the assembly
-- itself rather than its motion (the helm panel's altitude readout, which is a position, not a
-- velocity, and so is not part of the Motion sample; and the wind, which needs the raw velocity
-- vector). Re-resolved on each call rather than handing back a stored reference -- see this file's
-- header on why that reference goes stale.
function BlimpCamera.GetHull(): BasePart?
	return resolveHull()
end

return BlimpCamera
