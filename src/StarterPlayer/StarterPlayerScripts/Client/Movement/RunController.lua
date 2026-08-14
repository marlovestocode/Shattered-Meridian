--!strict
--[[
	RunController.lua

	Owns: the LOCAL player's run presentation -- which run stage is engaged, which animation that
	means, when a footstep fires, and the camera/audio punctuation at the moment the second stage
	takes hold.

	WHY THIS MODULE EXISTS. Before it, "the run" was four modules each holding a private opinion:
	CombatClient owned the sprint remotes and the FOV, CombatAnimator owned the run loop and decided
	on its own whether it should be playing, MovementVFX owned the dust, and the parkour framework's
	Sprinting state owned the movement -- with nothing connecting the last one to the first three. The
	run animation kept playing over a slide, a wall-run and a vault, because the only thing it asked
	was "is the sprint key held and is MoveDirection non-zero," which is true throughout all three.
	This module is the single place that answers "what is the run doing right now," and it answers it
	from the two sources that actually know: the SERVER's resolved stage, and the parkour state
	machine's live state id.

	WHAT IT DOES NOT DECIDE. Not the stage -- Server/Combat/Movement.UpdateSprintStage resolves that
	and publishes it as Constants.Attributes.SprintStage; this module reads it. Not sprint engagement
	-- Client/Combat/CombatClient.lua remains sprint's owner (its remotes, hold-vs-toggle, Autorun) and
	pushes the resulting boolean in, exactly as it already does for ParkourController and MovementVFX.
	Not the movement itself -- the server owns WalkSpeed and the parkour framework owns everything
	else. Every input here is pushed in by whoever legitimately owns it, so there is no second opinion
	anywhere in this file that could drift out of sync with a first one.

	ONE HEARTBEAT, RE-DERIVED EVERY FRAME. The footstep loop is a single persistent connection made at
	Start() that re-computes "should a step fire right now" from live state, rather than something
	scheduled per sprint-press -- the same idiom CombatAnimator's locomotion evaluator and
	MovementVFX's dust trickle already use, and for the same reason: nothing can be left scheduled
	against a character that no longer exists. There is no task.delay in this file at all, and every
	connection it makes (the Heartbeat, and one attribute watcher per life) has exactly one owner and
	one disconnect path.

	Does not own: the dust trickle (MovementVFX.lua), the sprint FOV base offset (CombatClient.lua's
	own "Sprint" slot -- this module composes a SECOND named slot on top rather than fighting it for
	the property), the sound instances (SoundManager.lua via RunAudio.lua), or any network traffic --
	nothing here crosses the wire.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)

local CombatAnimator = require(script.Parent.Parent.FX.CombatAnimator)
local FOVOffset = require(script.Parent.Parent.FX.FOVOffset)
local RunAudio = require(script.Parent.Parent.FX.RunAudio)

local logger = Logger.scope("RunController")

local RunController = {}

local RUN_CONFIG = Constants.Run
local FOOTSTEPS = RUN_CONFIG.Footsteps
local ONSET = RUN_CONFIG.Stage2Onset

-- The FOVOffset slot this module composes into. Distinct from CombatClient's own "Sprint" slot on
-- purpose: the two stack (stage 2 pulls further in than stage 1) and neither has to know the other's
-- current value, which is the entire reason FOVOffset is a named-slot composer rather than a
-- FieldOfView writer.
local FOV_SLOT = "SprintStage2"

-- The parkour states during which the RUN is what the character is doing. Every other state is
-- either a traversal with its own animation and its own surface contact (a slide, a wall-run, a
-- vault, a ledge climb), an airborne state (no ground to step on), or combat owning the body -- and
-- in all of those, a run loop layered on top and a stream of footstep sounds are both wrong.
--
-- An allowlist rather than a denylist of the traversals, so a state added later is silent-by-default
-- rather than silently claiming to be a run. Landing is included: it is the frame or two of ground
-- contact that hands straight back to running, and dropping the run presentation for it would make
-- every landing at speed flicker.
local RUN_PRESENTATION_STATES: { [string]: boolean } = {
	Idle = true,
	Walking = true,
	Sprinting = true,
	Landing = true,
}

local started = false
local heartbeatConnection: RBXScriptConnection? = nil

-- The bound character and its Humanoid. The ROOT PART is deliberately not cached alongside them: it
-- is read live off Humanoid.RootPart in the loop below, because a character binds before its parts
-- have all replicated and a cached-at-bind-time root would be nil for the whole life whenever this
-- module happened to bind a frame early.
local character: Model? = nil
local humanoid: Humanoid? = nil
-- The per-life watcher on the server's published stage. One per character, disconnected before the
-- next one is made and on unbind -- see bindCharacter/unbind.
local stageConnection: RBXScriptConnection? = nil

-- Sprint intent, pushed in by CombatClient (see the header). Not read from any key here.
local sprintEngaged = false
-- The stage the SERVER says we are in, mirrored from the Attribute. 0 until told otherwise, which is
-- the correct default for "no character bound yet."
local stage = 0
-- The parkour framework's live state id, pushed from ParkourController on every transition; nil
-- means the framework is not currently driving this character (disabled by the player's own Settings
-- toggle, or between lives), in which case there is no parkour opinion to honor and the run
-- presentation falls back to its own grounded/moving checks alone.
local parkourStateId: string? = nil

-- os.clock() of the last footstep. Module-level rather than per-life because it is only ever
-- compared against `now` -- a stale value from a previous life can at worst allow one immediate step
-- on the first frame of the next one, and BindCharacter resets it anyway.
local lastStepClock = 0

-- Whether the stock character run sound has been muted for the CURRENT life yet -- see
-- RunAudio.SilenceDefaultRunSound for why this is a retry rather than a single attempt at bind time.
local defaultRunSoundSilenced = false

-- Last frame's answer to "is the run happening", so the loop below can act on the EDGE rather than
-- the level. Only the falling edge does anything (cutting in-flight step sounds); the rising edge
-- needs nothing, since the first step fires off the cadence clock like any other.
local wasRunning = false

-- Whether the parkour framework currently says the character is doing something other than running.
-- False whenever parkour is not driving at all, which is what keeps the pre-parkour fallback path
-- (ParkourController.SetEnabled(false)) behaving exactly as it did before this module existed.
local function parkourSuppressesRun(): boolean
	local id = parkourStateId
	return id ~= nil and not RUN_PRESENTATION_STATES[id]
end

-- Applies everything that changes when the stage does. Called only on a real transition -- every
-- effect in here is either a one-shot (the onset whoosh) or a set-and-forget property (the FOV
-- target, the animator's stage), and re-applying them every frame would either machine-gun the
-- whoosh or fight CombatAnimator's own hit-stop freeze for AnimationTrack.Speed.
local function applyStage(previousStage: number, nextStage: number): ()
	CombatAnimator.SetRunStage(nextStage)
	if nextStage >= 2 then
		-- The gear change. Fired on the 1 -> 2 edge only; a 0 -> 2 edge is not reachable (the server
		-- resolves stage 0 whenever sprint is not held, and the charge required for stage 2 can only be
		-- accrued while it is), but it is treated as one anyway rather than asserted against -- the cost
		-- of being wrong about that is a missing sound, and the cost of the assert is a crash in a
		-- presentation module.
		RunAudio.PlayStage2Onset()
		FOVOffset.SetContinuous(FOV_SLOT, ONSET.FOVDelta, ONSET.FOVEaseSpeed)
		logger:debug("Run stage 2 engaged", { previousStage = previousStage })
	else
		-- Eased back to neutral rather than cleared: ClearContinuous is teardown (it drops the slot
		-- outright), and dropping out of full stride should settle, not cut. Same distinction
		-- CombatClient's own Sprint slot already makes between a stop and a teardown.
		FOVOffset.SetContinuous(FOV_SLOT, 0, ONSET.FOVEaseSpeed)
	end
end

local function setStage(nextStage: number): ()
	if nextStage == stage then
		return
	end
	local previousStage = stage
	stage = nextStage
	applyStage(previousStage, nextStage)
end

-- Whether the character is, RIGHT NOW, doing the thing footsteps describe: sprint engaged, on the
-- ground, actually being steered, and not handed over to a traversal. Returns the root part alongside
-- the answer so the caller does not look it up a second time.
--
-- Split out from the stepping loop below so there is exactly ONE boolean for "the run is happening",
-- rather than a chain of early returns with no single value to compare against last frame's. That
-- comparison is what lets the run be ENDED (below) and not merely stopped being extended -- see
-- RunAudio.StopRunSounds.
local function evaluateRunning(): (boolean, BasePart?)
	if not FOOTSTEPS.Enabled or not sprintEngaged then
		return false, nil
	end
	local currentHumanoid = humanoid
	local currentCharacter = character
	if not currentHumanoid or not currentCharacter then
		return false, nil
	end
	-- Live, not cached -- see the `character`/`humanoid` declarations above. Nil while the character is
	-- mid-replication or being torn down, which is also exactly when there is nothing to step on.
	local currentRoot = currentHumanoid.RootPart
	if not currentRoot then
		return false, nil
	end
	-- The stock run-sound mute, retried here rather than only at bind time: this is the first moment
	-- the player is actually running, which is well after the default sound script has built its
	-- Sounds. Converges on the first stride and then costs nothing.
	if not defaultRunSoundSilenced then
		defaultRunSoundSilenced = RunAudio.SilenceDefaultRunSound(currentCharacter)
	end
	-- A traversal, an airborne state, or combat owning the body -- all of which have their own
	-- presentation and none of which is a footfall.
	if parkourSuppressesRun() then
		return false, nil
	end
	-- Airborne (including flight, which sets FloorMaterial to Air the moment PlatformStand lifts the
	-- character) -- the same single check MovementVFX's dust trickle uses for the identical question.
	if currentHumanoid.FloorMaterial == Enum.Material.Air then
		return false, nil
	end
	if currentHumanoid.MoveDirection.Magnitude < Constants.Combat.MovementInputMagnitudeThreshold then
		return false, nil
	end
	return true, currentRoot
end

-- One frame of footstep evaluation. Every condition is re-derived from live state; nothing here is
-- remembered between frames except the step clock and the running edge.
local function stepFootsteps(): ()
	local running, currentRoot = evaluateRunning()

	-- THE FALLING EDGE. Triggering steps stops on its own the moment `running` goes false -- but a
	-- one-shot already in flight keeps playing to the end of its sample, and a footstep that outlives
	-- the run is describing a stride that is not happening. Cut them here, at the single point where
	-- the run is known to have ENDED rather than merely not been extended.
	if running ~= wasRunning then
		wasRunning = running
		if not running then
			RunAudio.StopRunSounds()
		end
	end
	if not running or not currentRoot then
		return
	end

	-- Cadence is driven by MEASURED speed, not by the stage's nominal speed: a stage-2 runner slowed
	-- by hit-slow or a steep climb should take slower steps, and a stage-1 runner riding a slide's
	-- momentum carry should take faster ones. The stage only decides which authored cadence and which
	-- reference speed that measurement is scaled against.
	-- ParkourMath's own definition of planar speed, not a local flatten-and-measure: the parkour
	-- framework, the server's validator and this loop must all mean the same thing by "how fast is
	-- this character going", and there is already exactly one place that says so.
	local planarSpeed = ParkourMath.PlanarSpeed(currentRoot.AssemblyLinearVelocity)
	local stageConfig = if stage >= 2 then FOOTSTEPS.Stage2 else FOOTSTEPS.Stage1
	local referenceSpeed = if stage >= 2 then FOOTSTEPS.Stage2ReferenceSpeed else FOOTSTEPS.Stage1ReferenceSpeed
	local interval = ParkourMath.StepInterval(
		planarSpeed,
		referenceSpeed,
		stageConfig.StepIntervalSeconds,
		FOOTSTEPS.MinIntervalSeconds,
		FOOTSTEPS.MaxIntervalSeconds
	)

	local now = os.clock()
	if (now - lastStepClock) < interval then
		return
	end
	lastStepClock = now
	RunAudio.PlayStep(stage)
end

local function unbind(): ()
	if stageConnection then
		stageConnection:Disconnect()
		stageConnection = nil
	end
	character = nil
	humanoid = nil
	-- The falling edge in the loop above cannot be relied on for teardown: a death that destroys the
	-- character still gets one more Heartbeat to notice, but RunController.Stop disconnects that
	-- Heartbeat outright, so there would be no frame left to notice anything. Cutting here covers
	-- every teardown path (respawn, death, Stop) directly, and is a no-op when nothing is playing.
	wasRunning = false
	RunAudio.StopRunSounds()
	-- A life that ended mid-stride must not hand the next one a stage it never earned, a live FOV pull
	-- or a run-stage the animator will apply to a brand-new track set. Routed through setStage rather
	-- than a bare assignment so the teardown is the same code path as any other stage change -- one
	-- place that knows what a stage change entails.
	setStage(0)
end

-- Binds a freshly-spawned character. Called from CombatClient's own character-bind path, alongside
-- CombatAnimator.BindCharacter/MovementVFX.BindCharacter -- the same lifecycle, so there is one place
-- a new life is announced to the presentation layer rather than three competing ones.
function RunController.BindCharacter(nextCharacter: Model): ()
	-- Any previous life's watcher goes first: rebinding without this is the exact leak shape
	-- CombatAnimator's own perLifeResetHandlers header documents (a stale non-nil connection that is
	-- never replaced and never fires usefully again).
	unbind()

	-- The Humanoid is the ONLY thing required here (its RootPart is read live in the loop -- see that
	-- field's own note): every caller already waits for it, and requiring anything else would make this
	-- bind fail for a whole life over a part that was one frame late.
	local humanoidInstance = nextCharacter:FindFirstChildOfClass("Humanoid")
	if not humanoidInstance then
		logger:warn("BindCharacter: character has no Humanoid", { character = nextCharacter.Name })
		return
	end

	character = nextCharacter
	humanoid = humanoidInstance
	lastStepClock = 0
	-- A new life gets a new set of stock character sounds, so the mute has to be earned again.
	defaultRunSoundSilenced = RunAudio.SilenceDefaultRunSound(nextCharacter)

	-- Reactive rather than polled: the stage changes a couple of times a minute, so reading the
	-- Attribute every Heartbeat would be 60 reads a second to observe nothing. Seeded immediately
	-- below the connection, because the server may well have published a stage before this client got
	-- around to binding (a rapid respawn mid-sprint), and a signal only fires on future changes.
	stageConnection = humanoidInstance:GetAttributeChangedSignal(Constants.Attributes.SprintStage):Connect(function()
		local value = humanoidInstance:GetAttribute(Constants.Attributes.SprintStage)
		setStage(if typeof(value) == "number" then value else 0)
	end)
	local initialStage = humanoidInstance:GetAttribute(Constants.Attributes.SprintStage)
	setStage(if typeof(initialStage) == "number" then initialStage else 0)
end

-- Sprint intent, pushed by CombatClient's syncSprint -- see the header for why this is a push.
function RunController.SetSprinting(sprinting: boolean): ()
	sprintEngaged = sprinting
end

-- The parkour framework's live state id, pushed by ParkourController on every transition (and nil
-- when the framework stands down, so this module falls back to its own checks alone). This is the
-- link that stops the run loop and the footsteps from playing straight through a slide, a wall-run,
-- a vault or a fall.
function RunController.SetParkourState(stateId: string?): ()
	if stateId == parkourStateId then
		return
	end
	parkourStateId = stateId
	-- Pushed straight through to the animator: the run/walk loops live there (they need the Core
	-- priority and the per-frame dominant-weight re-assert that the whole file is built around), so
	-- the suppression has to be applied where the tracks are, not here.
	CombatAnimator.SetLocomotionSuppressed(parkourSuppressesRun())
end

-- The live stage, for any consumer that wants to know without watching the Attribute itself (the
-- debug overlay, a future HUD stamina/stride readout). Read-only by design.
function RunController.GetStage(): number
	return stage
end

function RunController.Start(): ()
	if started then
		return
	end
	started = true

	local localPlayer = Players.LocalPlayer
	-- CombatClient drives BindCharacter for the ordinary path (so the whole presentation layer binds
	-- in one place, in a known order). This covers the case where this module starts with a character
	-- already alive -- a Studio play-solo start, or any future boot order that starts this before
	-- CombatClient's own CharacterAdded handler has fired.
	if localPlayer.Character then
		RunController.BindCharacter(localPlayer.Character)
	end
	localPlayer.CharacterRemoving:Connect(unbind)

	heartbeatConnection = RunService.Heartbeat:Connect(stepFootsteps)
	logger:info("RunController started")
end

-- Stops the footstep loop and releases the character. Symmetric with Start, for a test harness or a
-- future spectator mode -- the same reason ParkourController.Stop exists rather than being left to
-- process teardown.
function RunController.Stop(): ()
	if heartbeatConnection then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end
	started = false
	sprintEngaged = false
	parkourStateId = nil
	CombatAnimator.SetLocomotionSuppressed(false)
	unbind()
	FOVOffset.ClearContinuous(FOV_SLOT)
end

return RunController
