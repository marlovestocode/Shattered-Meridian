--!strict
--[[
	FlightAudio.lua

	Owns: registering the dev-menu flight feature's sound effects with SoundManager.lua and exposing
	verb-named play functions for Client/Flight/FlightController.lua to call -- the same "domain
	module owns WHICH sounds exist and gives them a typed API" shape Client/FX/CombatAudio.lua
	already established. Sound definitions come from FlightConstants.Sound (empty SoundId
	placeholders until real assets are supplied -- SoundManager.Play/PlayLooped already no-op safely
	on those, so registering ahead of having real ids is safe, same convention as CombatAudio.lua's
	own sounds when they were first wired).

	The continuous wind-rush loop is the first user of SoundManager.lua's new PlayLooped/StopLooped/
	SetLoopedVolume/SetLoopedPlaybackSpeed capability -- SetWindIntensity is called every Heartbeat
	while flying (Client/Flight/FlightController.lua's stepFlight) with a [0,1] speed fraction, and
	this module maps that to the configured volume/playback-speed ranges every frame; SoundManager
	itself does no easing of its own (see that module's own header), so the caller is expected to
	already be smoothing whatever fraction it passes in if smoothing is wanted.

	Does not own: deciding WHEN a takeoff/landing/sonic-boom happened (FlightController.lua's own
	detection/classification), or the looped-sound mechanics themselves (SoundManager.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local FlightConstants = require(ReplicatedStorage.Shared.Flight.FlightConstants)

local SoundManager = require(script.Parent.SoundManager)

local FlightAudio = {}

local TAKEOFF_SOUND_NAME = "FlightTakeoff"
local LANDING_SOFT_SOUND_NAME = "FlightLandingSoft"
local LANDING_HARD_SOUND_NAME = "FlightLandingHard"
local SONIC_BOOM_SOUND_NAME = "FlightSonicBoom"
local WIND_LOOP_SOUND_NAME = "FlightWind"

local soundCfg = FlightConstants.Sound

SoundManager.Register(TAKEOFF_SOUND_NAME, { SoundId = soundCfg.Takeoff.SoundId, Volume = soundCfg.Takeoff.Volume })
SoundManager.Register(
	LANDING_SOFT_SOUND_NAME,
	{ SoundId = soundCfg.LandingSoft.SoundId, Volume = soundCfg.LandingSoft.Volume }
)
SoundManager.Register(
	LANDING_HARD_SOUND_NAME,
	{ SoundId = soundCfg.LandingHard.SoundId, Volume = soundCfg.LandingHard.Volume }
)
SoundManager.Register(
	SONIC_BOOM_SOUND_NAME,
	{ SoundId = soundCfg.SonicBoom.SoundId, Volume = soundCfg.SonicBoom.Volume }
)
-- Registered at MaxVolume -- SetWindIntensity ramps the actual live volume down from there every
-- frame via SoundManager.SetLoopedVolume, never by re-registering.
SoundManager.Register(
	WIND_LOOP_SOUND_NAME,
	{ SoundId = soundCfg.WindLoop.SoundId, Volume = soundCfg.WindLoop.MaxVolume }
)

function FlightAudio.PlayTakeoff(): ()
	SoundManager.Play(TAKEOFF_SOUND_NAME)
end

function FlightAudio.PlaySoftLanding(): ()
	SoundManager.Play(LANDING_SOFT_SOUND_NAME)
end

function FlightAudio.PlayHardLanding(): ()
	SoundManager.Play(LANDING_HARD_SOUND_NAME)
end

function FlightAudio.PlaySonicBoom(): ()
	SoundManager.Play(SONIC_BOOM_SOUND_NAME)
end

function FlightAudio.StartWind(): ()
	SoundManager.PlayLooped(WIND_LOOP_SOUND_NAME)
end

function FlightAudio.StopWind(): ()
	SoundManager.StopLooped(WIND_LOOP_SOUND_NAME)
end

-- speedFraction: [0, 1], the same fraction-of-max-speed FlightCamera.SetFlightMotion derives --
-- maps linearly to [0, MaxVolume] and [MinPlaybackSpeed, MaxPlaybackSpeed].
function FlightAudio.SetWindIntensity(speedFraction: number): ()
	local clamped = math.clamp(speedFraction, 0, 1)
	SoundManager.SetLoopedVolume(WIND_LOOP_SOUND_NAME, clamped * soundCfg.WindLoop.MaxVolume)
	SoundManager.SetLoopedPlaybackSpeed(
		WIND_LOOP_SOUND_NAME,
		soundCfg.WindLoop.MinPlaybackSpeed
			+ clamped * (soundCfg.WindLoop.MaxPlaybackSpeed - soundCfg.WindLoop.MinPlaybackSpeed)
	)
end

return FlightAudio
