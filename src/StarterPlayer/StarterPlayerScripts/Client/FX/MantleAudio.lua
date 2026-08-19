--!strict
--[[
	MantleAudio.lua

	Owns: the one-shot played the instant a mantle is committed to -- the moment States/Mantling.lua's
	kinematic climb begins, not the moment it finishes. The same "domain module owns WHICH sounds
	exist and gives them a typed API" shape Client/FX/CombatAudio.lua, Client/FX/RunAudio.lua,
	Client/FX/FlightAudio.lua, Client/FX/DashAudio.lua and Client/FX/SlideAudio.lua already establish.
	The definition comes from ParkourConstants.Obstacle.MantleSound -- see that field's own comment for
	why it lives there instead of in Shared/Constants.lua alongside the other five *Audio.lua modules'
	sound tables.

	A ONE-SHOT, LIKE DashAudio, NOT A LOOP LIKE SlideAudio. A mantle is a single committed beat -- the
	hands catch the ledge and the body pulls up over a fixed, short kinematic window
	(Obstacle.MantleDurationSeconds) -- not a sustained condition the way sliding or wall-running are,
	so there is no "for the duration of" to loop across and no fade to reach for.

	NO SUBSCRIPTION OF ITS OWN, unlike Client/FX/CombatAudio.lua's Attack_Started hook. Mantling is a
	MovementStateId this framework's own state machine already tracks, and
	Client/Parkour/ParkourController.lua already calls ParkourAnimator.OnStateChanged/
	ParkourCamera.OnStateChanged/DashAudio.OnStateChanged/SlideAudio.OnStateChanged on every real
	transition -- this module's OnStateChanged is one more call in that same list, not a new event
	source. See ParkourController.lua's own onTransition.

	Does not own: WHEN a mantle starts (States/Mantling.lua's CanEnter/Enter decide that; this module
	only reacts to the transition the controller already detected), or the Sound-instance mechanics
	(SoundManager.lua). Purely local presentation; nothing here crosses the network or affects an
	outcome.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

local SoundManager = require(script.Parent.SoundManager)

type MovementStateId = ParkourTypes.MovementStateId

local MantleAudio = {}

local MANTLE_SOUND_NAME = "Mantle"

-- Registered at load -- what puts this in SoundManager.GetPreloadInstances, which
-- Client/Loading/AssetPreloader.lua sweeps at boot so the first mantle of a session doesn't pay CDN
-- streaming latency mid-climb. AssetPreloader.lua requires this module directly for exactly that
-- ordering reason -- see its own comment beside the FlightAudio/RunAudio/CombatAudio/DashAudio/
-- SlideAudio requires.
SoundManager.Register(MANTLE_SOUND_NAME, ParkourConstants.Obstacle.MantleSound)

-- Called from Client/Parkour/ParkourController.lua's onTransition, alongside
-- ParkourAnimator.OnStateChanged/ParkourCamera.OnStateChanged/DashAudio.OnStateChanged/
-- SlideAudio.OnStateChanged -- see this file's own header for why that direct call, rather than a
-- subscription of this module's own, is the right shape here.
function MantleAudio.OnStateChanged(_previous: MovementStateId, next: MovementStateId): ()
	if next == "Mantling" then
		SoundManager.Play(MANTLE_SOUND_NAME)
	end
end

return MantleAudio
