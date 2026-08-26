--!strict
--[[
	RunAudio.lua

	Owns: the run system's sound registrations and the verb-named play functions
	Client/Movement/RunController.lua calls -- the same "domain module owns WHICH sounds exist and
	gives them a typed API" shape Client/FX/CombatAudio.lua and Client/FX/FlightAudio.lua already
	establish. Definitions come from Constants.Run (an empty SoundId placeholder until a real asset is
	supplied -- SoundManager.Play already no-ops safely on that).

	ONE registered sound, not one per gear. Only Constants.Run.Footsteps.Stages[1] carries a Sound; every
	stage above it reuses that same registration and just plays it faster
	(Footsteps.Stages[n].PlaybackSpeedMultiplier), rather than each stage owning its own asset. There
	used to also be a separate one-shot "gear change" whoosh (RunStage<n>Onset, keyed off
	Constants.Run.StageOnset) that fired once on the instant a faster stage engaged -- removed, because
	a faster gear pitching the SAME step sound up already sells "this is quicker now" through the
	footsteps themselves, and a second competing audio event on top of that read as clutter rather than
	clarity. StageOnset still exists in Constants.Run for its FOVDelta pull (RunController reads that
	directly); this module no longer has anything to do with it.

	Pitch jitter (Constants.Run.Footsteps.Stages[n].PitchJitter) is applied per play on top of the
	stage's PlaybackSpeedMultiplier, because a fixed-interval step system replaying one identical
	sample is instantly recognizable as a metronome. It's a few percent -- enough to break the pattern,
	not enough to read as a different surface.

	PlayWallRunStep REUSES THE SAME REGISTRATION, played slower and jittered by
	ParkourConstants.WallRun.Step -- a wall-run gets a lighter, heavier-sounding cadence through the
	same asset rather than a whole second one, the literal "a slower version of run sound" ask. The
	cadence TIMER lives in Client/Movement/RunController.lua (stepWallRun), the same "controller owns
	WHEN, this module owns WHICH sound and how it is played" split PlayStep's own caller already
	uses -- this module has no per-frame loop of its own for either.

	Does not own: WHEN a step happens or which stage is engaged (RunController.lua re-derives both
	every frame from live speed and the server's Constants.Attributes.SprintStage), the Sound-instance
	mechanics (SoundManager.lua), or any gameplay decision -- nothing here crosses the network and
	nothing here can affect an outcome.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)

local SoundManager = require(script.Parent.SoundManager)

local logger = Logger.scope("RunAudio")

local RunAudio = {}

local RUN_CONFIG = Constants.Run
local WALL_RUN_STEP = ParkourConstants.WallRun.Step

-- The one registered name every stage plays through -- see this file's header for why the gears above
-- stage 1 no longer get their own registration. Named for what it is regardless of which stage fired it,
-- the same reason CombatAudio's ImpactClean covers three OutcomeKinds under one name.
local STEP_SOUND_NAME = "RunStep"

-- DERIVED FROM THE CONFIG, not hand-listed alongside it. Resizing the ladder is an edit to
-- Constants.Run.Footsteps.Stages alone; iterating it here rather than naming stage numbers is what
-- keeps that true.
local STEP_PITCH_JITTER: { [number]: number } = {}
local STEP_SPEED_MULTIPLIER: { [number]: number } = {}

-- Registered at load, exactly like FlightAudio's own set -- registration is what puts this in
-- SoundManager.GetPreloadInstances, which Client/Loading/AssetPreloader.lua sweeps at boot so the
-- first footstep of a session doesn't pay CDN streaming latency mid-stride.
SoundManager.Register(STEP_SOUND_NAME, RUN_CONFIG.Footsteps.Stages[1].Sound)

for stage, config in RUN_CONFIG.Footsteps.Stages do
	STEP_PITCH_JITTER[stage] = config.PitchJitter
	STEP_SPEED_MULTIPLIER[stage] = config.PlaybackSpeedMultiplier or 1
end

-- One shared generator rather than math.random's global state, so footstep jitter can never perturb
-- an unrelated caller's random sequence (or be perturbed by one) -- the same isolation reason
-- anything with a per-frame draw should use its own stream.
local random = Random.new()

-- Plays one footfall for `stage`, pitched by that stage's PlaybackSpeedMultiplier (the "speed it up
-- per stage" that now does the job the removed onset whoosh used to). Falls back to stage 1's
-- multiplier/jitter for any unexpected stage value rather than going silent: a missing step sound is
-- a bug the player experiences as the run losing its feel, and there is always a correct-enough
-- answer available.
function RunAudio.PlayStep(stage: number): ()
	if not RUN_CONFIG.Footsteps.Enabled then
		return
	end
	local jitter = STEP_PITCH_JITTER[stage] or STEP_PITCH_JITTER[1] or 0
	local speedMultiplier = STEP_SPEED_MULTIPLIER[stage] or STEP_SPEED_MULTIPLIER[1] or 1
	local jitterFactor = if jitter > 0 then 1 + random:NextNumber(-jitter, jitter) else 1
	SoundManager.Play(STEP_SOUND_NAME, speedMultiplier * jitterFactor)
end

-- The wall-run cadence's own play call -- see this file's header for why it reuses STEP_SOUND_NAME
-- rather than a second registration, and why the interval/multiplier/jitter live in
-- ParkourConstants.WallRun.Step instead of being hand-typed here. Sharing the pool with PlayStep is
-- deliberate too: RunAudio.StopRunSounds already cuts every instance of this name, so a wall-run step
-- still ringing out gets silenced by the exact same falling-edge call its ordinary counterpart does --
-- see Client/Movement/RunController.lua's own stepWallRun for that edge.
function RunAudio.PlayWallRunStep(): ()
	if not RUN_CONFIG.Footsteps.Enabled then
		return
	end
	local jitter = WALL_RUN_STEP.PitchJitter
	local jitterFactor = if jitter > 0 then 1 + random:NextNumber(-jitter, jitter) else 1
	SoundManager.Play(STEP_SOUND_NAME, WALL_RUN_STEP.PlaybackSpeedMultiplier * jitterFactor)
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
	SoundManager.StopAll(STEP_SOUND_NAME)
end

-- Runtime swap for the step sound, so step audio can be changed without an edit-and-rejoin cycle
-- (Constants.Run.Footsteps.Stages[1].Sound remains the shipped default and the thing to edit for a
-- permanent change). Routed through SoundManager.Reconfigure rather than Register so the existing
-- pooled instances are repointed instead of orphaned -- see that function's own header. No stage
-- parameter anymore: every stage plays through the one registration this swaps.
function RunAudio.SetStepSound(definition: Constants.SoundDefinition): ()
	SoundManager.Reconfigure(STEP_SOUND_NAME, definition)
	logger:info("Run step sound changed", { soundId = definition.SoundId })
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
