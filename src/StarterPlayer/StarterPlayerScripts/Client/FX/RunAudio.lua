--!strict
--[[
	RunAudio.lua

	Owns: the run system's sound registrations and the verb-named play functions
	Client/Movement/RunController.lua calls -- the same "domain module owns WHICH sounds exist and
	gives them a typed API" shape Client/FX/CombatAudio.lua and Client/FX/FlightAudio.lua already
	establish. Definitions come from Constants.Run (empty SoundId placeholders until real assets are
	supplied -- SoundManager.Play already no-ops safely on those).

	Three sounds, and the split between them is the point:
	  * RunStepStage1 / RunStepStage2 -- one shot per footfall, at whichever stage is engaged.
	  * RunStage2Onset -- one shot at the INSTANT the second stage engages, never repeated.

	That split is what solves the "my stage-2 file opens with a speed whoosh and then continues into
	footsteps" problem. Registered as two independent names pointing at the same asset with different
	SoundDefinition.PlaybackRegion slices, the whoosh plays once as the gear change and the step slice
	plays per footfall -- with the engine doing the trimming (Sound.PlaybackRegion), not a stop timer.
	Point them at two separate assets instead and nothing here changes; the region is optional.

	Pitch jitter (Constants.Run.Footsteps.Stage1/Stage2.PitchJitter) is applied per play rather than
	baked into the registration, because a fixed-interval step system replaying one identical sample
	is instantly recognizable as a metronome. It's a few percent -- enough to break the pattern, not
	enough to read as a different surface.

	Does not own: WHEN a step happens or which stage is engaged (RunController.lua re-derives both
	every frame from live speed and the server's Constants.Attributes.SprintStage), the Sound-instance
	mechanics (SoundManager.lua), or any gameplay decision -- nothing here crosses the network and
	nothing here can affect an outcome.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)

local SoundManager = require(script.Parent.SoundManager)

local logger = Logger.scope("RunAudio")

local RunAudio = {}

local RUN_CONFIG = Constants.Run

local STEP_SOUND_NAMES = { [1] = "RunStepStage1", [2] = "RunStepStage2" }
local STAGE2_ONSET_SOUND_NAME = "RunStage2Onset"

-- Registered at load, exactly like FlightAudio's own set -- registration is what puts these in
-- SoundManager.GetPreloadInstances, which Client/Loading/AssetPreloader.lua sweeps at boot so the
-- first footstep of a session doesn't pay CDN streaming latency mid-stride.
SoundManager.Register(STEP_SOUND_NAMES[1], RUN_CONFIG.Footsteps.Stage1.Sound)
SoundManager.Register(STEP_SOUND_NAMES[2], RUN_CONFIG.Footsteps.Stage2.Sound)
SoundManager.Register(STAGE2_ONSET_SOUND_NAME, RUN_CONFIG.Stage2Onset.Sound)

-- Per-stage jitter fraction, read once rather than per step -- these are static config.
local STEP_PITCH_JITTER = {
	[1] = RUN_CONFIG.Footsteps.Stage1.PitchJitter,
	[2] = RUN_CONFIG.Footsteps.Stage2.PitchJitter,
}

-- One shared generator rather than math.random's global state, so footstep jitter can never perturb
-- an unrelated caller's random sequence (or be perturbed by one) -- the same isolation reason
-- anything with a per-frame draw should use its own stream.
local random = Random.new()

-- Plays one footfall for `stage`. Falls back to the stage-1 sound for any unexpected stage value
-- rather than going silent: a missing step sound is a bug the player experiences as the run losing
-- its feel, and there is always a correct-enough answer available.
function RunAudio.PlayStep(stage: number): ()
	if not RUN_CONFIG.Footsteps.Enabled then
		return
	end
	local name = STEP_SOUND_NAMES[stage] or STEP_SOUND_NAMES[1]
	local jitter = STEP_PITCH_JITTER[stage] or 0
	local playbackSpeed = if jitter > 0 then 1 + random:NextNumber(-jitter, jitter) else 1
	SoundManager.Play(name, playbackSpeed)
end

-- The gear-change kick. Called exactly once per stage-1 -> stage-2 transition by RunController; this
-- module does no transition detection of its own.
function RunAudio.PlayStage2Onset(): ()
	SoundManager.Play(STAGE2_ONSET_SOUND_NAME)
end

-- Cuts every run sound currently playing -- called by RunController the moment the run genuinely ends
-- (the player stops, sprint is released, a traversal takes over, the character dies).
--
-- A footstep is triggered while a condition HOLDS, so a copy still playing after that condition ends
-- is describing a stride that is not happening. For a properly-trimmed step sample this is
-- imperceptible -- the sample is shorter than the gap between steps, so there is usually nothing to
-- cut. It matters enormously for an UNTRIMMED asset: a multi-second file retriggered every 0.25s
-- across a three-slot pool leaves three overlapping copies still running when the player stops, which
-- is heard as footsteps continuing for several seconds after standing still. Trimming the asset
-- (SoundDefinition.PlaybackRegion) is the real fix for that; this is the guarantee that holds
-- regardless of what asset someone points these names at.
function RunAudio.StopRunSounds(): ()
	SoundManager.StopAll(STEP_SOUND_NAMES[1])
	SoundManager.StopAll(STEP_SOUND_NAMES[2])
	-- The onset whoosh too: it announces entering full stride, so it has nothing to say once the run
	-- is over.
	SoundManager.StopAll(STAGE2_ONSET_SOUND_NAME)
end

-- Runtime swap for either stage's step sound, so step audio can be changed without an edit-and-
-- rejoin cycle (Constants.Run.Footsteps.Stage1/Stage2.Sound remains the shipped default and the
-- thing to edit for a permanent change). Routed through SoundManager.Reconfigure rather than
-- Register so the existing pooled instances are repointed instead of orphaned -- see that function's
-- own header.
function RunAudio.SetStepSound(stage: number, definition: Constants.SoundDefinition): ()
	local name = STEP_SOUND_NAMES[stage]
	if not name then
		logger:warn("SetStepSound called with an unknown run stage", { stage = stage })
		return
	end
	SoundManager.Reconfigure(name, definition)
	logger:info("Run step sound changed", { stage = stage, soundId = definition.SoundId })
end

-- Same, for the stage-2 onset whoosh.
function RunAudio.SetStage2OnsetSound(definition: Constants.SoundDefinition): ()
	SoundManager.Reconfigure(STAGE2_ONSET_SOUND_NAME, definition)
	logger:info("Run stage-2 onset sound changed", { soundId = definition.SoundId })
end

-- Silences Roblox's own stock "Running" Sound on a freshly-bound character.
--
-- The default RbxCharacterSounds script parents a looped scuff to HumanoidRootPart and drives it off
-- the Humanoid's own state; left alone it plays underneath these footsteps as a second, unrelated
-- surface. Muted (Volume = 0) rather than destroyed or disconnected on purpose: that Instance belongs
-- to a script this codebase doesn't own and re-parents/recreates on its own schedule, and deleting
-- something another script expects to exist is how you earn a stream of errors from code you can't
-- edit. A muted Sound costs nothing.
--
-- Returns whether the sound was actually found and muted, so the caller can retry cheaply rather
-- than either yielding here or holding a ChildAdded connection open for a one-time fixup: the default
-- sounds are created by a script that has usually not run yet at the instant a character binds, so a
-- single attempt at bind time would miss most of the time. RunController retries from its own
-- footstep loop until this returns true, which converges within the first stride of the first run and
-- costs one FindFirstChild until then.
--
-- Also returns true when the feature is switched off -- "nothing left to do" is the honest answer to
-- the caller's real question, and returning false would have it retry forever for a mute it has been
-- told not to perform.
function RunAudio.SilenceDefaultRunSound(character: Model): boolean
	if not RUN_CONFIG.Footsteps.SilenceDefaultRunSound then
		return true
	end
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return false
	end
	local running = rootPart:FindFirstChild("Running")
	if not running or not running:IsA("Sound") then
		return false
	end
	running.Volume = 0
	return true
end

return RunAudio
