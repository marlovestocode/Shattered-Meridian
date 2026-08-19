--!strict
--[[
	SlideAudio.lua

	Owns: the slide's continuous loop -- started the frame Sliding is entered, stopped the frame it is
	left, so it runs for exactly the duration the player is sliding and no longer. The same "domain
	module owns WHICH sounds exist and gives them a typed API" shape Client/FX/CombatAudio.lua,
	Client/FX/RunAudio.lua, Client/FX/FlightAudio.lua and Client/FX/DashAudio.lua already establish.
	The definition comes from ParkourConstants.Slide.Sound -- see that field's own comment for why it
	lives there instead of in Shared/Constants.lua alongside the other four *Audio.lua modules' sound
	tables.

	A FLAT LOOP, UNLIKE FlightAudio's WindLoop. That one ramps volume/playback speed continuously off a
	live speed fraction (SetWindIntensity, called every Heartbeat) because flight's wind is meant to
	read as a function of how fast the player is currently going. A slide has no equivalent design ask
	yet -- it is one sound for the whole ride at a fixed steady-state volume -- so this module exposes
	only Start/Stop, the same two-function shape DashAudio's one-shot Play call sits behind. The two
	edges are faded (Slide.Sound.FadeInSeconds/FadeOutSeconds, via SoundManager.PlayLooped/StopLooped's
	own fade argument) so the loop doesn't start or end as a hard edit, but that is a fixed, one-time
	tween on each edge, not a continuously-driven value -- the loop is still flat in between. Growing a
	genuine intensity curve later is a Slide.Sound shape change (MaxVolume/MinPlaybackSpeed/
	MaxPlaybackSpeed, matching Constants.Flight.Sound.WindLoop) plus a per-frame caller, not a
	rewrite of this file.

	NO SUBSCRIPTION OF ITS OWN, unlike Client/FX/CombatAudio.lua's Attack_Started hook. Sliding is a
	MovementStateId this framework's own state machine already tracks, and
	Client/Parkour/ParkourController.lua already calls ParkourAnimator.OnStateChanged/
	ParkourCamera.OnStateChanged/DashAudio.OnStateChanged on every real transition -- this module's
	OnStateChanged is a fourth call in that same list, not a new event source. See
	ParkourController.lua's own onTransition.

	Does not own: WHEN a slide starts or ends (States/Sliding.lua's CanEnter/Update decide that; this
	module only reacts to the transition the controller already detected), or the Sound-instance
	mechanics (SoundManager.lua). Purely local presentation; nothing here crosses the network or
	affects an outcome.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

local SoundManager = require(script.Parent.SoundManager)

type MovementStateId = ParkourTypes.MovementStateId

local SlideAudio = {}

local SLIDE_LOOP_SOUND_NAME = "SlideLoop"
local SOUND_CONFIG = ParkourConstants.Slide.Sound

-- Registered at load -- what puts this in SoundManager.GetPreloadInstances, which
-- Client/Loading/AssetPreloader.lua sweeps at boot so the first slide of a session doesn't pay CDN
-- streaming latency mid-slide. AssetPreloader.lua requires this module directly for exactly that
-- ordering reason -- see its own comment beside the FlightAudio/RunAudio/CombatAudio/DashAudio
-- requires. SOUND_CONFIG carries FadeInSeconds/FadeOutSeconds too, which Register ignores (it only
-- reads the SoundDefinition-shaped fields) and OnStateChanged/Reset below read directly.
SoundManager.Register(SLIDE_LOOP_SOUND_NAME, SOUND_CONFIG)

-- Called from Client/Parkour/ParkourController.lua's onTransition, alongside
-- ParkourAnimator.OnStateChanged/ParkourCamera.OnStateChanged/DashAudio.OnStateChanged -- see this
-- file's own header for why that direct call, rather than a subscription of this module's own, is the
-- right shape here.
function SlideAudio.OnStateChanged(previous: MovementStateId, next: MovementStateId): ()
	if next == "Sliding" then
		SoundManager.PlayLooped(SLIDE_LOOP_SOUND_NAME, SOUND_CONFIG.FadeInSeconds)
	elseif previous == "Sliding" then
		SoundManager.StopLooped(SLIDE_LOOP_SOUND_NAME, SOUND_CONFIG.FadeOutSeconds)
	end
end

-- Called from Client/Parkour/ParkourController.lua's BindCharacter AND unbind, alongside
-- ParkourCamera.Reset -- the same courtesy that module's own header implies: a character that dies or
-- despawns mid-slide never gets the chance to hand OnStateChanged a "leaving Sliding" transition (the
-- machine is force-reset or torn down out from under it), which would otherwise leave this loop
-- playing forever into a respawn or an empty character slot. No fade-out passed here, deliberately --
-- this is an emergency cleanup for a body that no longer exists in the ordinary sense, not the ordinary
-- exit path, and a lingering fade tween outliving the very character it was scoped to would be its own
-- small leak.
function SlideAudio.Reset(): ()
	SoundManager.StopLooped(SLIDE_LOOP_SOUND_NAME)
end

return SlideAudio
