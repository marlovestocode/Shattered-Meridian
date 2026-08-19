--!strict
--[[
	DashAudio.lua

	Owns: the dash's launch stinger -- one registered sound, played once per dash regardless of which
	of the five quadrants resolved (Front/Back/Left/Right/Up). The same "domain module owns WHICH
	sounds exist and gives them a typed API" shape Client/FX/CombatAudio.lua, Client/FX/RunAudio.lua and
	Client/FX/FlightAudio.lua already establish. The definition comes from
	ParkourConstants.Dash.Sound -- see that field's own comment for why it lives there instead of in
	Shared/Constants.lua alongside the other three *Audio.lua modules' sound tables.

	ONE SOUND FOR ALL FIVE DIRECTIONS, deliberately, unlike ParkourAnimator's per-quadrant clips
	(DashFront/DashBack/DashLeft/DashRight/DashUp): those are genuinely different animations because the
	BODY moves differently in each direction, but a burst is a burst to the ear regardless of which way
	it goes. Splitting this into five registrations with nothing to tell them apart yet would just be
	four placeholders this module cannot justify.

	NO SUBSCRIPTION OF ITS OWN, unlike Client/FX/CombatAudio.lua's Attack_Started hook. Dash is a
	MovementStateId this framework's own state machine already tracks, and
	Client/Parkour/ParkourController.lua already calls ParkourAnimator.OnStateChanged/
	ParkourCamera.OnStateChanged on every real transition -- this module's OnStateChanged is a third
	call in that same list, not a new event source. See ParkourController.lua's own onTransition.

	Does not own: WHEN a dash starts (States/Dashing.lua's CanEnter/Enter decide that; this module only
	reacts to the transition the controller already detected), or the Sound-instance mechanics
	(SoundManager.lua). Purely local presentation; nothing here crosses the network or affects an
	outcome.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

local SoundManager = require(script.Parent.SoundManager)

type MovementStateId = ParkourTypes.MovementStateId

local DashAudio = {}

local DASH_SOUND_NAME = "DashLaunch"

-- Registered at load -- what puts this in SoundManager.GetPreloadInstances, which
-- Client/Loading/AssetPreloader.lua sweeps at boot so the first dash of a session doesn't pay CDN
-- streaming latency mid-jump. AssetPreloader.lua requires this module directly for exactly that
-- ordering reason -- see its own comment beside the FlightAudio/RunAudio/CombatAudio requires.
SoundManager.Register(DASH_SOUND_NAME, ParkourConstants.Dash.Sound)

-- Called from Client/Parkour/ParkourController.lua's onTransition, alongside
-- ParkourAnimator.OnStateChanged and ParkourCamera.OnStateChanged -- see this file's own header for
-- why that direct call, rather than a subscription of this module's own, is the right shape here.
function DashAudio.OnStateChanged(_previous: MovementStateId, next: MovementStateId): ()
	if next == "Dashing" then
		SoundManager.Play(DASH_SOUND_NAME)
	end
end

return DashAudio
