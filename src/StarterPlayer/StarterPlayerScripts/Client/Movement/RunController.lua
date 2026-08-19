--!strict
--[[
	RunController.lua

	Owns: the LOCAL player's run, end to end on the client -- the key, the hold-versus-toggle
	preference, Autorun, the single remote that tells the server what the player intends, and every
	piece of presentation that follows from the stage the server resolves back (which clip, at what
	rate, which footstep, how deep the FOV pull, and the kick at the moment a gear engages).

	WHY THIS MODULE OWNS INPUT NOW. It used to own only presentation, and pointed at
	Client/Combat/CombatClient.lua as "sprint's owner" for the key, the remotes, hold-vs-toggle and
	Autorun. That module was deleted by the combat rewrite and nothing inherited any of it, which took
	the entire run with it: no remote was fired, so the server never knew anyone was running; nothing
	pushed intent into the parkour framework, so States/Sprinting.lua could never be entered and
	wall-running -- reachable only from a sprint -- went with it; and this module's own sprintEngaged
	flag sat false forever, so the footstep loop never fired a step. Running is not a combat mechanic
	and should never have been homed in a combat module; it lives here now, next to the parkour
	framework it has to cooperate with.

	THE DIVISION OF LABOUR, which is the whole design:
	  * The CLIENT owns INTENT. A boolean: is the player asking to run. Keyboard, gamepad, toggle,
	    Autorun -- four routes, one answer, fired to the server only on its edges.
	  * The SERVER owns the STAGE. Server/Systems/RunSystem.lua runs the charge clock against its own
	    view of whether the character is genuinely moving, resolves which gear that earns, publishes it
	    as Constants.Attributes.SprintStage and writes the WalkSpeed to match.
	  * This module then owns everything that stage MEANS to look at and listen to.
	A client that lies about intent gets no speed it did not earn -- the server still has to see the
	character actually moving, tick after tick, on its own clock. A client that lies to itself about
	the stage gets a wrong animation and nothing else.

	IN TANDEM WITH PARKOUR, in both directions. Outward: the parkour framework pushes its live state id
	in through SetParkourState, and everything here goes quiet for a slide, a wall-run, a vault or a
	fall -- before that link existed the run loop asked only "is the key held and is the character
	moving", which is true throughout all four. Inward: Client/Parkour/ParkourController.lua PULLS
	IsSprinting() once per movement frame rather than being pushed to. That direction is not a
	preference -- ParkourController already requires this module (to push its state id out), so a push
	back would be a require cycle. The pull rides the dependency that already exists and removes the
	possibility of the two disagreeing about intent for a frame.

	ONE HEARTBEAT, RE-DERIVED EVERY FRAME. The footstep loop is a single persistent connection made at
	Start() that recomputes "should a step fire right now" from live state, rather than something
	scheduled per key-press. There is no task.delay in this file at all, and every connection it makes
	has exactly one owner and one disconnect path -- see `connections` and releaseConnections below.
	stepWallRun rides the SAME Heartbeat rather than a connection of its own -- a wall-run and an
	ordinary run are mutually exclusive by construction, so there is nothing to gain from separating
	their timers, and RunAudio.PlayWallRunStep reuses the ordinary run's own registered sound
	(ParkourConstants.WallRun.Step's own comment has the reasoning).

	Does not own: the stage (RunSystem resolves it), WalkSpeed (RunSystem writes it), the ladder's
	numbers (Shared/Run/RunConstants.lua), the sound instances (SoundManager via RunAudio), the dust
	trickle (MovementVFX), or any movement behavior (the parkour framework).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local Trove = require(ReplicatedStorage.Shared.Trove)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)
local RunConstants = require(ReplicatedStorage.Shared.Run.RunConstants)
local RunLadder = require(ReplicatedStorage.Shared.Run.RunLadder)
local Types = require(ReplicatedStorage.Shared.Types)

local CombatAnimator = require(script.Parent.Parent.FX.CombatAnimator)
local FOVOffset = require(script.Parent.Parent.FX.FOVOffset)
local MovementVFX = require(script.Parent.Parent.FX.MovementVFX)
local RunAudio = require(script.Parent.Parent.FX.RunAudio)
local KeybindManager = require(script.Parent.Parent.Input.KeybindManager)

local logger = Logger.scope("RunController")

local RunController = {}

local RUN_CONFIG = Constants.Run
local FOOTSTEPS = RUN_CONFIG.Footsteps
local WALL_RUN_STEP = ParkourConstants.WallRun.Step

-- TWO FOV SLOTS, composed rather than fought over. Client/FX/FOVOffset.lua is a named-slot composer
-- precisely so two independent reasons to change the field of view can coexist: the base pull that
-- says "this player is running at all" and the per-gear pull on top of it that says which gear. They
-- stack, and neither has to know the other's current value.
local FOV_SLOT_BASE = "Run"
local FOV_SLOT_STAGE = "RunStage"

-- The parkour states during which the RUN is what the character is doing. Every other state is either
-- a traversal with its own animation and its own surface contact (a slide, a wall-run, a vault, a
-- ledge climb), an airborne state (no ground to step on), or combat owning the body -- and in all of
-- those, a run loop layered on top and a stream of footstep sounds are both wrong.
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

-- EVERY CONNECTION THIS MODULE OWNS, in two scopes with one release path each.
--
-- Split into two lifetimes because they genuinely have two: the SESSION connections (input, the
-- heartbeat, the player's own CharacterRemoving) are made once at Start and live until Stop, while the
-- PER-LIFE connections (the stage attribute watcher) must be torn down and remade for every character.
-- Keeping them in separate scopes is what makes "rebind without leaking" a property of the structure
-- rather than of remembering to nil one specific field -- the leak shape this codebase has already
-- paid for once.
--
-- These were a pair of plain arrays and a local releaseConnections helper, and that helper was the
-- direct ancestor of Shared/Trove.lua -- the right idea, kept private to one module while about
-- twenty-five other sites hand-rolled a worse version of it. They are the shared thing now; this file
-- keeps the shape it always had, just no longer as its own private copy. Two independent Troves rather
-- than one nested inside the other, deliberately: nesting would make Stop tear down the life scope
-- through the session's cleanup rather than through unbind, which is the one place this module wants
-- that decision made.
local sessionTrove = Trove.New()
local lifeTrove = Trove.New()

-- The bound character and its Humanoid. The ROOT PART is deliberately not cached alongside them: it is
-- read live off Humanoid.RootPart in the loop below, because a character binds before its parts have
-- all replicated and a cached-at-bind-time root would be nil for the whole life whenever this module
-- happened to bind a frame early.
local character: Model? = nil
local humanoid: Humanoid? = nil

-- INTENT, from its four routes. Kept as the raw inputs plus one resolved answer rather than as a
-- single mutable boolean, so every route composes through the same resolve() and none of them can
-- leave the others stale -- the failure that made Autorun and the held key fight each other in the
-- implementation this replaces.
local sprintKeyHeld = false
local sprintToggledOn = false
local sprintMode: Types.SprintMode = "Hold"
local autorunEnabled = false
-- Whether there is real movement input right now, for Autorun. Re-derived on the Heartbeat rather than
-- watched, because Humanoid.MoveDirection has no changed signal worth the name and this is one vector
-- read on a loop that is already running.
local autorunMoving = false
-- The last value handed to the server and to every local consumer. The single thing edges are computed
-- against.
local engaged = false

-- The stage the SERVER says we are in, mirrored from the Attribute. 0 until told otherwise, which is
-- the correct default for "no character bound yet."
local stage = 0

-- The parkour framework's live state id, pushed from ParkourController on every transition; nil means
-- the framework is not currently driving this character (disabled by the player's own Settings toggle,
-- or between lives), in which case there is no parkour opinion to honor and the run presentation falls
-- back to its own grounded/moving checks alone.
local parkourStateId: string? = nil

-- os.clock() of the last footstep. Module-level rather than per-life because it is only ever compared
-- against `now` -- a stale value from a previous life can at worst allow one immediate step on the
-- first frame of the next one, and BindCharacter resets it anyway.
local lastStepClock = 0
-- The wall-run cadence's own clock, same reasoning as lastStepClock above -- a separate one because
-- the two cadences are independent (a player can never be both, but the wall-run one has its own
-- interval, ParkourConstants.WallRun.Step.IntervalSeconds, and comparing it against lastStepClock
-- would let a footstep taken moments before an attach suppress the first wall-run step or vice versa).
local lastWallRunStepClock = 0

-- Whether the stock character run sound has been muted for the CURRENT life yet -- see
-- RunAudio.SilenceDefaultRunSound for why this is a retry rather than a single attempt at bind time.
local defaultRunSoundSilenced = false

-- Last frame's answer to "is the run happening", so the loop below can act on the EDGE rather than the
-- level. Only the falling edge does anything (cutting in-flight step sounds); the rising edge needs
-- nothing, since the first step fires off the cadence clock like any other.
local wasRunning = false
-- Same edge-tracking, for the wall-run cadence, and it needs its OWN flag rather than reusing
-- wasRunning's: evaluateRunning() already returns false throughout a wall-run (WallRunning is not in
-- RUN_PRESENTATION_STATES), so wasRunning's own falling edge fires the moment a wall-run STARTS (an
-- ordinary run sound genuinely ending there) and never fires again for the rest of it -- there is no
-- edge left in that flag for stepWallRun's own cadence to end ON when the wall-run itself finishes.
local wasWallRunning = false

-- Held rather than looked up per edge: this is fired on every intent change, and GetRemoteEvent does a
-- FindFirstChild through the Remotes folder each time. Nil until Start, and every fire is guarded --
-- an intent edge that happens before the server's own boot has created the remote is dropped rather
-- than crashing, and the next edge (or the character bind's own resync) carries the correct value.
local setSprintingRemote: RemoteEvent? = nil

-- Whether the parkour framework currently says the character is doing something other than running.
-- False whenever parkour is not driving at all, which is what keeps the pre-parkour fallback path
-- (ParkourController.SetEnabled(false)) behaving exactly as it did before this module existed.
local function parkourSuppressesRun(): boolean
	local id = parkourStateId
	return id ~= nil and not RUN_PRESENTATION_STATES[id]
end

-- Per-stage presentation config, with the fallback every consumer in this system shares: a stage the
-- assets do not cover presents as stage 1 rather than as nothing. A ladder can legitimately grow ahead
-- of its audio, and the failure mode for that must be "the new gear sounds like the old one."
local function footstepConfig(forStage: number)
	return FOOTSTEPS.Stages[forStage] or FOOTSTEPS.Stages[1]
end

--
-- THE STAGE.
--

-- Applies everything that changes when the stage does. Called only on a real transition -- every
-- effect in here is a set-and-forget property (the FOV target, the animator's stage), and
-- re-applying it every frame would fight CombatAnimator's own hit-stop freeze for
-- AnimationTrack.Speed. The stage change is instead sold through RunAudio.PlayStep itself: the same
-- footstep sound just plays faster once Footsteps.Stages[nextStage].PlaybackSpeedMultiplier takes
-- over on the next footfall, so there is nothing one-shot left for this function to fire.
local function applyStage(previousStage: number, nextStage: number): ()
	CombatAnimator.SetRunStage(nextStage)

	local onset = RUN_CONFIG.StageOnset[nextStage]
	if onset then
		FOVOffset.SetContinuous(FOV_SLOT_STAGE, onset.FOVDelta, onset.FOVEaseSpeed)
		logger:debug("Run stage engaged", { from = previousStage, to = nextStage })
	else
		-- Stage 1 and stage 0 have no per-gear pull. Eased back to neutral rather than cleared:
		-- ClearContinuous is teardown (it drops the slot outright), and settling out of a gear should
		-- settle, not cut. The ease speed is borrowed from whichever gear we are LEAVING so the way
		-- down feels like the way up.
		local previousOnset = RUN_CONFIG.StageOnset[previousStage]
		FOVOffset.SetContinuous(FOV_SLOT_STAGE, 0, if previousOnset then previousOnset.FOVEaseSpeed else nil)
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

--
-- INTENT.
--

-- The single place intent is resolved and fanned out, whichever route asked for it. Every consumer is
-- told here and nowhere else, so none of them can end up holding a different answer -- and the early
-- return on an unchanged value is what stops Autorun from re-firing the remote every time
-- MoveDirection wobbles.
local function syncEngaged(): ()
	local nextEngaged: boolean
	if autorunEnabled and autorunMoving then
		-- Autorun engages the run automatically whenever there is real movement input, without the key.
		-- Holding the key still works normally alongside it -- hence the `or` rather than a branch: the
		-- setting adds a route, it does not replace one.
		nextEngaged = true
	elseif sprintMode == "Toggle" then
		nextEngaged = sprintToggledOn
	else
		nextEngaged = sprintKeyHeld
	end

	if nextEngaged == engaged then
		return
	end
	engaged = nextEngaged

	-- The wire. One boolean, on the edge only -- see RunConstants.Network.RemoteNames.SetSprinting.
	local remote = setSprintingRemote
	if remote then
		remote:FireServer(engaged)
	end

	-- The local fan-out. Client/Parkour/ParkourController.lua is deliberately absent: it PULLS
	-- IsSprinting() on its own movement frame rather than being pushed to, because it already requires
	-- this module and a push back would be a require cycle. See this file's header.
	MovementVFX.SetSprinting(engaged)
	if engaged then
		CombatAnimator.StartRunning()
		FOVOffset.SetContinuous(FOV_SLOT_BASE, Constants.Camera.Sprint.FOVDelta, Constants.Camera.Sprint.FOVEaseSpeed)
	else
		CombatAnimator.StopRunning()
		FOVOffset.SetContinuous(FOV_SLOT_BASE, 0, Constants.Camera.Sprint.FOVEaseSpeed)
	end
end

local function onInputBegan(input: InputObject, gameProcessed: boolean): ()
	if gameProcessed then
		return
	end
	if not KeybindManager.Matches("Sprint", input) then
		return
	end
	sprintKeyHeld = true
	-- In toggle mode the PRESS flips the latch; the release below then does nothing. Both are tracked
	-- regardless of the current mode so that switching modes mid-session never reads a stale value --
	-- a player who switches to Hold while the toggle latch is on gets the key's honest answer
	-- immediately, rather than staying stuck on until they press again.
	sprintToggledOn = not sprintToggledOn
	syncEngaged()
end

local function onInputEnded(input: InputObject): ()
	if not KeybindManager.Matches("Sprint", input) then
		return
	end
	sprintKeyHeld = false
	syncEngaged()
end

--
-- PRESENTATION.
--

-- Whether the character is, RIGHT NOW, doing the thing footsteps describe: run engaged, on the ground,
-- actually being steered, and not handed over to a traversal. Returns the root part alongside the
-- answer so the caller does not look it up a second time.
--
-- Split out from the stepping loop below so there is exactly ONE boolean for "the run is happening",
-- rather than a chain of early returns with no single value to compare against last frame's. That
-- comparison is what lets the run be ENDED (below) and not merely stopped being extended -- see
-- RunAudio.StopRunSounds.
local function evaluateRunning(): (boolean, BasePart?)
	if not FOOTSTEPS.Enabled or not engaged then
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
	-- The stock run-sound mute, retried here rather than only at bind time: this is the first moment the
	-- player is actually running, which is well after the default sound script has built its Sounds.
	-- Converges on the first stride and then costs nothing.
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
	if currentHumanoid.MoveDirection.Magnitude < RunConstants.MoveInputThreshold then
		return false, nil
	end
	return true, currentRoot
end

-- The wall-run cadence, evaluated alongside the ordinary footstep one below but entirely independent
-- of it (see lastWallRunStepClock's own comment for why they cannot share a clock). Fixed interval
-- rather than speed-scaled: WallRun.Speed is a single authored value the whole run holds close to
-- (unlike the ground ladder's three gears), so there is no equivalent "measured speed" signal worth
-- deriving a cadence from the way ParkourMath.StepInterval does for ordinary running.
local function stepWallRun(): ()
	local wallRunning = parkourStateId == "WallRunning"

	-- THE FALLING EDGE, the wall-run cadence's own -- see wasWallRunning's own comment for why
	-- wasRunning's falling edge above cannot cover this. RunAudio.StopRunSounds cuts BOTH cadences at
	-- once (they share one registered sound), so this call is a no-op whenever the ordinary falling
	-- edge above already fired on the same frame -- SoundManager.StopAll on an already-stopped pool is
	-- itself a no-op, per that function's own contract.
	if wallRunning ~= wasWallRunning then
		wasWallRunning = wallRunning
		if not wallRunning then
			RunAudio.StopRunSounds()
		end
	end
	if not wallRunning then
		return
	end

	local now = os.clock()
	if (now - lastWallRunStepClock) < WALL_RUN_STEP.IntervalSeconds then
		return
	end
	lastWallRunStepClock = now
	RunAudio.PlayWallRunStep()
end

-- One frame of the run: Autorun's movement check, then footstep evaluation. Every condition is
-- re-derived from live state; nothing here is remembered between frames except the step clock and the
-- running edge.
local function stepRun(): ()
	local currentHumanoid = humanoid

	-- AUTORUN'S MOVEMENT GATE, evaluated on the same loop rather than on its own connection. Only
	-- resynced on a real change, so this costs one vector magnitude per frame and nothing else on the
	-- overwhelming majority of them.
	if autorunEnabled then
		local moving = currentHumanoid ~= nil
			and currentHumanoid.MoveDirection.Magnitude >= RunConstants.MoveInputThreshold
		if moving ~= autorunMoving then
			autorunMoving = moving
			syncEngaged()
		end
	end

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

	-- Independent of the ordinary run's own early return below -- a wall-run and an ordinary run are
	-- mutually exclusive, so this always resolves to "nothing to do" on the branch the early return
	-- below would otherwise skip it on.
	stepWallRun()

	if not running or not currentRoot then
		return
	end

	-- Cadence is driven by MEASURED speed, not by the stage's nominal speed: a top-gear runner slowed by
	-- a steep climb should take slower steps, and a first-gear runner riding a slide's momentum carry
	-- should take faster ones. The stage only decides which authored cadence and which reference speed
	-- that measurement is scaled against.
	-- ParkourMath's own definition of planar speed, not a local flatten-and-measure: the parkour
	-- framework, the server's validator and this loop must all mean the same thing by "how fast is this
	-- character going", and there is already exactly one place that says so.
	local planarSpeed = ParkourMath.PlanarSpeed(currentRoot.AssemblyLinearVelocity)
	local stageConfig = footstepConfig(stage)
	local interval = ParkourMath.StepInterval(
		planarSpeed,
		stageConfig.ReferenceSpeed,
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

--
-- LIFECYCLE.
--

local function unbind(): ()
	lifeTrove:Clean()
	character = nil
	humanoid = nil
	-- The falling edge in the loop above cannot be relied on for teardown: a death that destroys the
	-- character still gets one more Heartbeat to notice, but RunController.Stop disconnects that
	-- Heartbeat outright, so there would be no frame left to notice anything. Cutting here covers every
	-- teardown path (respawn, death, Stop) directly, and is a no-op when nothing is playing.
	wasRunning = false
	wasWallRunning = false
	RunAudio.StopRunSounds()
	-- A life that ended mid-stride must not hand the next one a stage it never earned, a live FOV pull
	-- or a run-stage the animator will apply to a brand-new track set. Routed through setStage rather
	-- than a bare assignment so the teardown is the same code path as any other stage change -- one
	-- place that knows what a stage change entails.
	setStage(0)
end

-- Binds a freshly-spawned character. Called from Main.client.lua's own CharacterAdded handler and,
-- defensively, from this module's own -- see Start.
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
	lastWallRunStepClock = 0
	-- A new life gets a new set of stock character sounds, so the mute has to be earned again.
	defaultRunSoundSilenced = RunAudio.SilenceDefaultRunSound(nextCharacter)

	-- Reactive rather than polled: the stage changes a couple of times a minute, so reading the
	-- Attribute every Heartbeat would be 60 reads a second to observe nothing. Seeded immediately below
	-- the connection, because the server may well have published a stage before this client got around
	-- to binding (a rapid respawn mid-run), and a signal only fires on future changes.
	lifeTrove:Connect(humanoidInstance:GetAttributeChangedSignal(Constants.Attributes.SprintStage), function()
		local value = humanoidInstance:GetAttribute(Constants.Attributes.SprintStage)
		setStage(if typeof(value) == "number" then value else 0)
	end)
	local initialStage = humanoidInstance:GetAttribute(Constants.Attributes.SprintStage)
	setStage(if typeof(initialStage) == "number" then initialStage else 0)

	-- INTENT IS RESTATED FOR THE NEW BODY. The server's per-player intent survives a respawn (a player
	-- who died with the key held should keep running), but its per-character state does not -- and this
	-- client may have changed its mind while dead. Re-firing the current value costs one packet per
	-- life and removes any possibility of the two disagreeing about a fresh character.
	local remote = setSprintingRemote
	if remote then
		remote:FireServer(engaged)
	end
end

-- Sprint intent, for consumers that PULL rather than being pushed to. Client/Parkour/
-- ParkourController.lua is the one that matters: it reads this once per movement frame, which is what
-- makes States/Sprinting.lua reachable at all. See this file's header for why the dependency runs in
-- this direction.
function RunController.IsSprinting(): boolean
	return engaged
end

-- The parkour framework's live state id, pushed by ParkourController on every transition (and nil when
-- the framework stands down, so this module falls back to its own checks alone). This is the link that
-- stops the run loop and the footsteps from playing straight through a slide, a wall-run, a vault or a
-- fall.
function RunController.SetParkourState(stateId: string?): ()
	if stateId == parkourStateId then
		return
	end
	parkourStateId = stateId
	-- Pushed straight through to the animator: the run/walk loops live there (they need the Core
	-- priority and the per-frame dominant-weight re-assert that the whole file is built around), so the
	-- suppression has to be applied where the tracks are, not here.
	CombatAnimator.SetLocomotionSuppressed(parkourSuppressesRun())
end

-- Hold-to-run versus toggle-to-run (Types.ParkourSettings.SprintMode), pushed from
-- Client/Settings/SettingsClient.lua. Re-resolves immediately rather than waiting for the next key
-- event, so switching modes takes effect on the frame the player chose it.
function RunController.SetSprintMode(mode: Types.SprintMode): ()
	if sprintMode == mode then
		return
	end
	sprintMode = mode
	-- Switching INTO toggle mode adopts whatever the key is doing right now rather than inheriting a
	-- latch the player set under different rules. Without this, changing the setting mid-run either
	-- drops the run or leaves it stuck on, both of which read as the setting being broken.
	if mode == "Toggle" then
		sprintToggledOn = sprintKeyHeld
	end
	syncEngaged()
	logger:debug("Run mode changed", { mode = mode })
end

-- The Autorun setting (Types.PlayerSettings.Autorun), pushed from Client/Settings/SettingsClient.lua.
-- With it on, the run engages automatically whenever there is real movement input -- same remote, same
-- stages, same presentation. Holding the key still works normally alongside it.
function RunController.SetAutorun(enabled: boolean): ()
	if autorunEnabled == enabled then
		return
	end
	autorunEnabled = enabled
	if not enabled then
		-- Cleared rather than left stale: with Autorun off nothing updates this again, and a remembered
		-- `true` would make re-enabling the setting engage the run instantly regardless of whether the
		-- player is moving.
		autorunMoving = false
	else
		local currentHumanoid = humanoid
		autorunMoving = currentHumanoid ~= nil
			and currentHumanoid.MoveDirection.Magnitude >= RunConstants.MoveInputThreshold
	end
	syncEngaged()
	logger:debug("Autorun changed", { enabled = enabled })
end

-- The live stage, for any consumer that wants to know without watching the Attribute itself (the debug
-- overlay, a future HUD stride readout). Read-only by design.
function RunController.GetStage(): number
	return stage
end

-- The highest gear the ladder defines, so a HUD can draw the right number of pips without knowing the
-- ladder's shape itself.
function RunController.GetMaxStage(): number
	return RunLadder.MaxStage()
end

function RunController.Start(): ()
	if started then
		return
	end
	started = true

	-- Looked up once. The server creates this in RunSystem.Init; GetRemoteEvent waits for it, which is
	-- the ordinary bounded server-boot delay every other client module's own lookup already tolerates.
	setSprintingRemote = NetworkBridge.GetRemoteEvent(RunConstants.Network.RemoteNames.SetSprinting)

	local localPlayer = Players.LocalPlayer
	-- Main.client.lua drives BindCharacter for the ordinary path (so the whole presentation layer binds
	-- in one place, in a known order). This covers the case where this module starts with a character
	-- already alive -- a Studio play-solo start, or any future boot order that starts this before that
	-- CharacterAdded handler has fired.
	if localPlayer.Character then
		RunController.BindCharacter(localPlayer.Character)
	end

	sessionTrove:Connect(localPlayer.CharacterRemoving, unbind)
	sessionTrove:Connect(UserInputService.InputBegan, onInputBegan)
	sessionTrove:Connect(UserInputService.InputEnded, onInputEnded)
	sessionTrove:Connect(RunService.Heartbeat, stepRun)

	logger:info("RunController started", { stages = RunLadder.MaxStage() })
end

-- Stops the run entirely and releases the character. Symmetric with Start, for a test harness or a
-- future spectator mode -- the same reason ParkourController.Stop exists rather than being left to
-- process teardown.
function RunController.Stop(): ()
	sessionTrove:Clean()
	started = false
	-- Routed through syncEngaged rather than assigned, so every consumer is told the run ended by the
	-- same path that tells them anything else -- including the server, which would otherwise keep a
	-- disconnecting client's intent set forever.
	sprintKeyHeld = false
	sprintToggledOn = false
	autorunMoving = false
	syncEngaged()
	parkourStateId = nil
	CombatAnimator.SetLocomotionSuppressed(false)
	unbind()
	FOVOffset.ClearContinuous(FOV_SLOT_BASE)
	FOVOffset.ClearContinuous(FOV_SLOT_STAGE)
end

return RunController
