--!strict
--[[
	BlimpAudio.lua

	Owns: the two continuous loops a player hears while aboard a blimp -- the engine note and the wind
	rush -- registered with Client/FX/SoundManager.lua and driven off the hull's own measured motion.

	THE SAME SHAPE AS Client/FX/FlightAudio.lua, deliberately, down to the placeholder SoundIds: both
	are a domain module that registers its names with SoundManager at load time and then exposes a
	handful of verbs. SoundManager.PlayLooped/SetLoopedVolume already no-op safely on an unset id, so
	this ships silent and becomes audible the day somebody uploads two files and fills in
	BlimpConstants.Audio -- with no code change and no risk of a half-wired path erroring in the
	meantime.

	IT ANSWERS THE HULL, NOT THE TELEGRAPH, and that is the one interesting decision here. The exhaust
	PARTICLES answer the pilot's key press (BlimpConstants.Exhaust says why: a player pressed a key and
	the visible thruster should agree on that press, not five seconds later when the mass does). Audio
	is the opposite case. A ship still making way after the engines cut should still be making wind
	noise, and one straining toward a rung it has not reached yet should still be roaring -- so both
	loops are driven from the same filtered physics sample the camera reads, handed in rather than
	measured a third time.

	TWO LOOPS RATHER THAN ONE, because they answer to different things and a single blended loop could
	not. The engine note follows SPEED FRACTION and pitches up with it -- it is the ship working. The
	wind follows ABSOLUTE speed regardless of direction and does not care whether an engine is running
	at all -- it is the air going past. A hull coasting to a stop with a dead furnace has one and not
	the other, which is exactly the moment the distinction is audible.

	AND THREE STAGES ON TOP OF THE TWO LOOPS -- Slow, Cruise, Running (BlimpConstants.Audio.Stages,
	resolved by Shared/Blimp/BlimpSpeedStage.lua). Crossing between them plays a one-shot AND settles
	the engine loop into that stage's own volume and pitch band.

	The stages exist because the continuous loops alone are, paradoxically, inaudible. A value that
	varies smoothly with speed has no edges, so there is no moment for a player to notice it -- they
	simply stop hearing it, the way you stop hearing a fridge. Three coarse bands put the edges back:
	the pilot gets a distinct event for "this ship is now really moving" that no amount of smooth
	scaling can deliver. It is the same reason a car with a continuously variable transmission feels
	slower than one that shifts.

	Does not own: the looped-sound mechanics (SoundManager.lua), the measurement
	(Client/Camera/BlimpCamera.GetMotion, via Shared/Blimp/BlimpCameraMath.lua), when a mount begins or
	ends (Client/Blimp/BlimpController.lua), or the exhaust particles -- which are a SERVER-side
	replicated property write and could not live here even if it were tidier (see
	Server/Systems/BlimpSystem.setThrusting).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BlimpConstants = require(ReplicatedStorage.Shared.Blimp.BlimpConstants)
local BlimpSpeedStage = require(ReplicatedStorage.Shared.Blimp.BlimpSpeedStage)

local SoundManager = require(script.Parent.SoundManager)

local BlimpAudio = {}

local ENGINE_LOOP = "BlimpEngineLoop"
local WIND_LOOP = "BlimpWindLoop"
local STAGE_CHANGE = "BlimpStageChange"

local engineCfg = BlimpConstants.Audio.EngineLoop
local windCfg = BlimpConstants.Audio.WindLoop
local stageCfg = BlimpConstants.Audio.StageChangeSound

-- Registered at module load, the same as FlightAudio's. Volume is seeded to each loop's MaxVolume and
-- then driven every frame through SetLoopedVolume -- never by re-registering, which would rebuild the
-- pooled instances underneath a playing loop.
SoundManager.Register(ENGINE_LOOP, { SoundId = engineCfg.SoundId, Volume = engineCfg.MaxVolume })
SoundManager.Register(WIND_LOOP, { SoundId = windCfg.SoundId, Volume = windCfg.MaxVolume })
-- ONE registration for all three stages -- each play pitches it differently (see
-- BlimpConstants.Audio.Stages on why that beats three uploads). Pooled three deep so a fast walk up
-- the telegraph that crosses two boundaries in quick succession does not cut its own first ping off.
SoundManager.Register(STAGE_CHANGE, { SoundId = stageCfg.SoundId, Volume = stageCfg.Volume, PoolSize = 3 })

local playing = false
-- Which of BlimpConstants.Audio.Stages the ship is currently in. Seeded to the slowest rather than to
-- nil, and deliberately NOT re-announced on mount: boarding a ship should not ping at you, and a
-- player stepping onto one already at speed hears the stage change on the first real crossing after
-- they arrive. See Start, which resets this without playing anything.
local stageIndex = 1

-- Maps a 0..1 intensity onto a definition's own volume ceiling and playback-speed range -- the same
-- shape FlightAudio.SetWindIntensity uses against its own LoopSoundDefinition, factored out here only
-- because this module has two loops rather than one.
local function driveLoop(name: string, intensity: number, maxVolume: number, minSpeed: number, maxSpeed: number): ()
	local clamped = math.clamp(intensity, 0, 1)
	SoundManager.SetLoopedVolume(name, clamped * maxVolume)
	SoundManager.SetLoopedPlaybackSpeed(name, minSpeed + (maxSpeed - minSpeed) * clamped)
end

-- Starts both loops silent and lets Update bring them in -- rather than fading in at full volume,
-- which would announce a stationary moored blimp with a roar the instant somebody stepped aboard it.
function BlimpAudio.Start(): ()
	if playing then
		return
	end
	playing = true
	stageIndex = 1
	driveLoop(ENGINE_LOOP, 0, engineCfg.MaxVolume, engineCfg.MinPlaybackSpeed, engineCfg.MaxPlaybackSpeed)
	driveLoop(WIND_LOOP, 0, windCfg.MaxVolume, windCfg.MinPlaybackSpeed, windCfg.MaxPlaybackSpeed)
	SoundManager.PlayLooped(ENGINE_LOOP, BlimpConstants.Audio.FadeSeconds)
	SoundManager.PlayLooped(WIND_LOOP, BlimpConstants.Audio.FadeSeconds)
end

function BlimpAudio.Stop(): ()
	if not playing then
		return
	end
	playing = false
	SoundManager.StopLooped(ENGINE_LOOP, BlimpConstants.Audio.FadeSeconds)
	SoundManager.StopLooped(WIND_LOOP, BlimpConstants.Audio.FadeSeconds)
end

-- One frame. `speedFraction` is the hull's forward speed over its own cruise speed (0..1) and
-- `absoluteSpeed` its speed in studs/second regardless of direction -- both straight off the camera's
-- motion sample, so the two loops and the view can never disagree about how fast the ship is going.
--
-- Silently ignored while stopped, so a caller does not need its own "am I aboard" check around this.
function BlimpAudio.Update(speedFraction: number, absoluteSpeed: number): ()
	if not playing then
		return
	end

	-- The stage first, because the engine loop below is scaled by it. Resolve is given the CURRENT
	-- stage as well as the speed -- that is what lets it apply hysteresis, and without hysteresis a
	-- hull sitting on a boundary would fire this sound several times a second forever. See
	-- Shared/Blimp/BlimpSpeedStage.lua.
	local nextStage = BlimpSpeedStage.Resolve(stageIndex, speedFraction)
	if nextStage ~= stageIndex then
		stageIndex = nextStage
		SoundManager.Play(STAGE_CHANGE, BlimpSpeedStage.At(nextStage).PlaybackSpeed)
	end
	local stage = BlimpSpeedStage.At(stageIndex)

	-- The stage's band multiplies the continuous scaling rather than replacing it, so the loop still
	-- answers to speed WITHIN a stage -- the stage is a shelf the note sits on, not a fixed note.
	driveLoop(
		ENGINE_LOOP,
		speedFraction * stage.LoopVolumeScale,
		engineCfg.MaxVolume,
		engineCfg.MinPlaybackSpeed * stage.LoopSpeedScale,
		engineCfg.MaxPlaybackSpeed * stage.LoopSpeedScale
	)
	-- Against the CRUISE speed rather than the max the hull can ever reach, so the wind is already at
	-- full voice at ordinary speed and flank simply pitches it up. Scaled off the absolute value, so
	-- backing out of a mooring still moves air.
	driveLoop(
		WIND_LOOP,
		absoluteSpeed / math.max(BlimpConstants.Drive.CruiseSpeed, 1),
		windCfg.MaxVolume,
		windCfg.MinPlaybackSpeed,
		windCfg.MaxPlaybackSpeed
	)
end

return BlimpAudio
