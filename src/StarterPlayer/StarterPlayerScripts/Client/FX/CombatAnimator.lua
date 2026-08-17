--!strict
--[[
	CombatAnimator.lua

	Owns: the LOCAL player's ordinary locomotion animation -- a Walking loop for ordinary movement
	that crossfades into one of THREE Running loops for Sprint (the run system's stages 1, 2 and 3 --
	see CombatAnimator.SetRunStage, and Client/Movement/RunController.lua for who decides which) on
	their current character's Animator, driven by a single persistent Heartbeat evaluator that
	re-derives "should Walking/Running be playing THIS frame" from live state every tick rather than
	being told when an action started or ended.

	This module used to also own the full combat animation surface -- swing/finisher/block/parry/
	dash/slide/hit-reaction playback, and the Move Creation System's runtime timeline playback -- all
	of which was removed alongside the rest of the combat system (Server/Systems/CombatSystem.lua and
	Client/Combat/CombatClient.lua, its only caller for any of that). What survives here is exactly
	the locomotion half: RunController.lua (a movement file, not a combat file) depends on
	SetRunStage/SetLocomotionSuppressed, and Client/Loading/AssetPreloader.lua depends on
	GetPreloadInstances -- both keep working exactly as before.

	Roblox replicates a played AnimationTrack to every other client automatically once it's loaded
	and played through the OWNING player's own Animator, so triggering these from this client is
	enough for every other player to see it too.

	Character-bind lifecycle: BindCharacter used to be called from CombatClient.lua's own
	CharacterAdded handler, alongside MovementVFX.BindCharacter and RunController.BindCharacter (see
	that file's own header on why all three were bound from one place). With CombatClient.lua gone,
	Client/Main.client.lua's own CharacterAdded hookup calls all three now -- see that file's header
	for why it's the correct new home (it already owns "every client-side module gets required and
	started from here").
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local AnimatorUtil = require(ReplicatedStorage.Shared.AnimatorUtil)
local AnimationTrackUtil = require(script.Parent.AnimationTrackUtil)

local logger = Logger.scope("CombatAnimator")

local CombatAnimator = {}

-- Constants.Combat.AnimationIds is the single source of truth -- now scoped to just the locomotion
-- clips (Walking/Running/RunningStage2/RunningStage3) since combat's own clips (swings, finishers,
-- dashes, etc.) were removed from Constants.lua alongside the rest of the combat data. This loop is
-- fully data-driven, so trimming that table is what trimmed this module's actual loaded-track set --
-- no code here needed to change to stop loading combat clips.
local ANIMATION_IDS = Constants.Combat.AnimationIds

-- Walking/Running share the same fade constants so the locomotion evaluator's walk<->run crossfade
-- is symmetric on both sides. Action priority (above the default Movement-tier walk/run cycle) so
-- these actually visually override Roblox's own baked-in animations instead of fighting them for the
-- same joints. Constants.FX.Animation.Combat -- see that table's own header in Constants.lua.
-- Shared by Walking and Running: a start/crossfade (Play(), or a Stop() that's really a handoff to
-- the OTHER locomotion loop -- see the evaluator below) uses this softer duration; a genuine
-- interrupt (the character stopping) uses LOCOMOTION_INTERRUPT_FADE_TIME instead, since that one
-- wants a fast cut, not a blend.
local LOCOMOTION_FADE_TIME = Constants.FX.Animation.Combat.LocomotionFadeSeconds
local LOCOMOTION_INTERRUPT_FADE_TIME = Constants.FX.Animation.Combat.LocomotionInterruptFadeSeconds
-- The run system's own three numbers (Constants.Run.Animation) -- the crossfade between the two run
-- stages' clips, and each stage's playback rate.
local RUN_STAGE_CROSSFADE_TIME = Constants.Run.Animation.StageCrossfadeSeconds
-- Keyed by stage rather than one local per stage -- see Constants.Run.Animation.PlaybackSpeeds' own
-- header for why the ladder's size must not be baked into its consumers.
local RUN_PLAYBACK_SPEEDS = Constants.Run.Animation.PlaybackSpeeds

-- The MoveDirection magnitude below which there's no meaningful held movement input -- shared with
-- Server/Combat/Movement.lua's own IsMoving and Client/FX/MovementVFX.lua, see
-- Constants.Combat.MovementInputMagnitudeThreshold's own header for the other call sites.
local LOCOMOTION_THRESHOLD = Constants.Combat.MovementInputMagnitudeThreshold

-- Priority alone (Core, set below) isn't enough: Roblox's default character rig ALSO plays its own
-- walk/run cycle at Core priority, so two same-priority tracks blend proportionally by Weight rather
-- than either cleanly winning -- without this, our own tracks read as "fighting" the default cycle.
-- A weight this far above the default's implicit 1 makes ours effectively dominant.
--
-- A single Play()-time weight isn't enough EITHER, for a sustained/held track (Running): Roblox's
-- default Animate script keeps re-evaluating and re-asserting its OWN track's weight on every
-- Humanoid movement-state change, and that re-assertion can win the tie again after ours -- the
-- Walking/Running evaluator below re-calls AdjustWeight every Heartbeat for exactly this reason.
-- Constants.FX.Animation.DominantWeight -- shared with Server/Combat/BotAnimator.lua (removed) and
-- Client/FX/FlightAnimator.lua, see that field's own header.
local DOMINANT_WEIGHT = Constants.FX.Animation.DominantWeight

local animationTemplates: { [string]: Animation } = {}
for name, id in pairs(ANIMATION_IDS) do
	-- Skip empty-id slots (Constants.Combat.AnimationIds lists wired-but-unauthored clips as ""):
	-- no template means no load attempt and tracks[name] stays nil, so every play path degrades to
	-- its documented no-op/fallback.
	if id ~= "" then
		local animation = Instance.new("Animation")
		animation.Name = name
		animation.AnimationId = id
		animationTemplates[name] = animation
	end
end

-- Client/Loading/AssetPreloader.lua's boot-time preload pass reuses these SAME template instances
-- (built above, once, at module load) rather than constructing its own from Constants.Combat.
-- AnimationIds directly -- this module is that data's one owner, and a second construction path
-- would just be a duplicate of it.
function CombatAnimator.GetPreloadInstances(): { Instance }
	local instances: { Instance } = {}
	for _, animation in animationTemplates do
		table.insert(instances, animation)
	end
	return instances
end

local tracks: { [string]: AnimationTrack } = {}

-- Bound in BindCharacter so the Walking/Running eligibility evaluator (below) can read live
-- MoveDirection every frame without a FindFirstChildOfClass lookup on the hot path.
local currentHumanoid: Humanoid? = nil

-- Reset hooks for per-life module state declared further down this file -- none of that state is
-- tied to the `tracks` table BindCharacter already rebuilds below, so left alone it survives a
-- respawn. BindCharacter (below) only actually runs at CALL time -- well after this whole module has
-- finished loading top-to-bottom -- so closing over this table here (declared before BindCharacter)
-- and registering each reset closer to its own state's declaration both work.
local perLifeResetHandlers: { () -> () } = {}
local function registerPerLifeReset(fn: () -> ()): ()
	table.insert(perLifeResetHandlers, fn)
end

-- Rebuilds every AnimationTrack against `character`'s own Animator. Safe to call on a character with
-- no Humanoid yet (returns having loaded nothing).
function CombatAnimator.BindCharacter(character: Model): ()
	tracks = {}
	currentHumanoid = nil
	for _, reset in perLifeResetHandlers do
		reset()
	end

	-- Shared/AnimatorUtil.lua -- the same find-Humanoid/find-or-create-Animator plumbing
	-- Client/FX/FlightAnimator.lua needs too; see that module's own header for why it's safe to
	-- share (pure Instance manipulation, no authoritative state).
	local animator = AnimatorUtil.GetOrCreateAnimator(character)
	if not animator then
		logger:warn("BindCharacter: no Humanoid/Animator available", { character = character.Name })
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	currentHumanoid = humanoid
	local rigType = humanoid and humanoid.RigType

	for name, animation in pairs(animationTemplates) do
		local ok, trackOrError = pcall(function()
			return animator:LoadAnimation(animation)
		end)
		if ok then
			local track = trackOrError :: AnimationTrack
			-- Core, not Action4: current Roblox default character rigs play their own walk/run cycle
			-- at Core priority, which otherwise wins over anything lower whenever the character has
			-- real MoveDirection input. Matching Core is the standard workaround.
			track.Priority = Enum.AnimationPriority.Core
			-- RunningStage2/RunningStage3 join the looped set for the same reason Running does -- each
			-- IS the run loop, at that stage. A sustained locomotion track whose Looped flag was never
			-- set plays through once and leaves the character in a T-pose-adjacent idle.
			if name == "Running" or name == "RunningStage2" or name == "RunningStage3" or name == "Walking" then
				track.Looped = true
			end
			tracks[name] = track
			logger:debug("Animation loaded", {
				name = name,
				length = track.Length,
				rigType = rigType,
			})
		else
			logger:warn("Failed to load animation", { name = name, errorMessage = tostring(trackOrError) })
		end
	end
end

-- Tracks the player's held Sprint INTENT -- whether that intent actually plays/keeps playing the
-- Running track is decided fresh every frame by the eligibility evaluator below, never here. Nothing
-- in this codebase currently pushes this (Sprint's own request/response plumbing lived in the
-- now-removed CombatSystem.lua/CombatClient.lua) -- kept as public API surface, exactly like
-- Server/Combat/Movement.lua, ready to be wired into whatever replaces Sprint's server-side brain
-- rather than deleted and re-invented later.
local sprintHeld = false

function CombatAnimator.StartRunning(): ()
	sprintHeld = true
end

function CombatAnimator.StopRunning(): ()
	sprintHeld = false
end

-- THE RUN SYSTEM'S THREE STAGES, pushed in by Client/Movement/RunController.lua (which mirrors the
-- server's own Constants.Attributes.SprintStage -- the stage is never decided on this side).
--
-- Stage 2 plays its own clip when Constants.Combat.AnimationIds.RunningStage2 is authored, and stage
-- 3 plays its own when RunningStage3 is authored -- each otherwise falls through to the stage below
-- it (3 -> 2 -> 1) played faster instead (Constants.Run.Animation.PlaybackSpeeds).
--
-- An intent value only, exactly like sprintHeld above: whether any clip actually plays this frame is
-- re-derived by the evaluator below, never decided here.
local runStage = 1

function CombatAnimator.SetRunStage(stage: number): ()
	runStage = stage
end

-- Whether something OTHER than ordinary locomotion currently owns this character's movement -- set by
-- RunController from the parkour framework's live state id (a slide, a wall-run, a vault, a ledge
-- climb, an airborne state).
--
-- A pushed boolean rather than this module requiring ParkourController: the parkour layer already
-- pushes its state outward to its own animator/camera/network consumers, and a require in this
-- direction would drag the whole movement framework into the load chain of a file that only wants to
-- know one thing.
local locomotionSuppressed = false

function CombatAnimator.SetLocomotionSuppressed(suppressed: boolean): ()
	locomotionSuppressed = suppressed
end

-- The run track (and speed) the playback-rate write below last applied to, so that write happens on a
-- real change and NOT every frame.
--
-- Reset per life alongside every other piece of per-life state: the tracks themselves are rebuilt
-- against the new character's Animator, so a remembered handle to the previous life's track would
-- never match again and the speed would never be re-applied for the new one.
local appliedRunSpeedTrack: AnimationTrack? = nil
local appliedRunSpeed = 0
registerPerLifeReset(function()
	appliedRunSpeedTrack = nil
	appliedRunSpeed = 0
end)

-- The single, continuously-correct answer to "should Walking/Running be playing THIS frame" --
-- connected once at module load (not per Sprint-press), so it never needs to be told when an action
-- started or ended; it just re-derives the right answer every tick from state that's already being
-- kept current elsewhere (sprintHeld, live MoveDirection).
--
-- Walking and Running are mutually exclusive (two same-priority DOMINANT_WEIGHT tracks BLEND rather
-- than override), but a toggle straight between them (Sprint pressed/released while still moving)
-- uses LOCOMOTION_FADE_TIME on BOTH the outgoing Stop() and the incoming Play() -- a symmetric
-- crossfade -- rather than LOCOMOTION_INTERRUPT_FADE_TIME's fast cut, which is reserved for a genuine
-- interrupt (the character actually stopping).
RunService.Heartbeat:Connect(function()
	local runningTrack = tracks.Running
	-- nil whenever Constants.Combat.AnimationIds.RunningStage2/RunningStage3 is still blank -- which
	-- is the shipped default for RunningStage3, and the case every branch below is written to handle
	-- by falling through to the stage below (3 -> 2 -> 1) rather than by going silent.
	local runningStage2Track = tracks.RunningStage2
	local runningStage3Track = tracks.RunningStage3
	local walkingTrack = tracks.Walking
	if runningTrack or runningStage2Track or runningStage3Track or walkingTrack then
		-- Also silenced while Flying (Client/DevMenu/FlightController.lua/FlightAnimator.lua own the
		-- character's animation entirely during flight) -- Boost reuses the Sprint keybind and raw
		-- WASD can still register nonzero MoveDirection mid-flight, so without this guard the
		-- ground-locomotion loop could blend in underneath a Hover/Cruise/Boost flight pose.
		local flying = currentHumanoid ~= nil and currentHumanoid:GetAttribute(Constants.Attributes.Flying) == true
		local moving = not flying
			and currentHumanoid ~= nil
			and currentHumanoid.MoveDirection.Magnitude > LOCOMOTION_THRESHOLD
		-- locomotionSuppressed is the parkour framework's veto -- see CombatAnimator.
		-- SetLocomotionSuppressed's own header for the conflict it closes. A vault or a wall-run is no
		-- more a WALK than it is a run.
		local canLocomote = moving and not locomotionSuppressed
		local shouldRun = sprintHeld and canLocomote
		local shouldWalk = not sprintHeld and canLocomote
		-- Each run stage above 1 only claims its own track when there IS one, cascading downward:
		-- stage 3 wants its own clip first; failing that (RunningStage3 still blank, the shipped
		-- default), stage 3 falls to stage 2's track (which is what "shouldRunStage2" playing at
		-- runStage 3 means below); failing THAT too, everything lands on stage 1. Playback rate below
		-- is what still makes an unauthored stage read as a different gear either way.
		local shouldRunStage3 = shouldRun and runStage >= 3 and runningStage3Track ~= nil
		local shouldRunStage2 = shouldRun and not shouldRunStage3 and runStage >= 2 and runningStage2Track ~= nil
		local shouldRunStage1 = shouldRun and not shouldRunStage3 and not shouldRunStage2

		-- Client/FX/AnimationTrackUtil.lua's shared evaluator -- see that module's own header for why
		-- this per-Heartbeat Play/AdjustWeight/Stop mechanic is extracted (the exact same shape
		-- FlightAnimator.lua's Hover/CruiseLoop/BoostLoop pick uses below it). Only the StopFadeSeconds
		-- per track varies here: a stage change between any two run clips crossfades at
		-- RUN_STAGE_CROSSFADE_TIME (all three are the same action at different intensities, so it
		-- should read as accelerating); a toggle to the OTHER locomotion track (still moving, Sprint
		-- pressed/released) crossfades symmetrically at LOCOMOTION_FADE_TIME; a genuine interrupt
		-- (stopped moving, or the parkour framework taking the body) cuts fast at
		-- LOCOMOTION_INTERRUPT_FADE_TIME.
		AnimationTrackUtil.DriveDominantLoop({
			{
				Track = runningTrack,
				ShouldPlay = shouldRunStage1,
				PlayFadeSeconds = LOCOMOTION_FADE_TIME,
				StopFadeSeconds = if shouldRunStage2 or shouldRunStage3
					then RUN_STAGE_CROSSFADE_TIME
					elseif shouldWalk then LOCOMOTION_FADE_TIME
					else LOCOMOTION_INTERRUPT_FADE_TIME,
			},
			{
				Track = runningStage2Track,
				ShouldPlay = shouldRunStage2,
				PlayFadeSeconds = RUN_STAGE_CROSSFADE_TIME,
				StopFadeSeconds = if shouldRunStage1 or shouldRunStage3
					then RUN_STAGE_CROSSFADE_TIME
					elseif shouldWalk then LOCOMOTION_FADE_TIME
					else LOCOMOTION_INTERRUPT_FADE_TIME,
			},
			{
				Track = runningStage3Track,
				ShouldPlay = shouldRunStage3,
				PlayFadeSeconds = RUN_STAGE_CROSSFADE_TIME,
				StopFadeSeconds = if shouldRunStage1 or shouldRunStage2
					then RUN_STAGE_CROSSFADE_TIME
					elseif shouldWalk then LOCOMOTION_FADE_TIME
					else LOCOMOTION_INTERRUPT_FADE_TIME,
			},
			{
				Track = walkingTrack,
				ShouldPlay = shouldWalk,
				PlayFadeSeconds = LOCOMOTION_FADE_TIME,
				StopFadeSeconds = if shouldRun then LOCOMOTION_FADE_TIME else LOCOMOTION_INTERRUPT_FADE_TIME,
			},
		}, DOMINANT_WEIGHT)

		-- Per-stage playback rate, written only when the track or the rate actually changes -- see
		-- appliedRunSpeedTrack's own header.
		local activeRunTrack = if shouldRunStage3
			then runningStage3Track
			elseif shouldRunStage2 then runningStage2Track
			else runningTrack
		if shouldRun and activeRunTrack then
			-- Falls back to stage 1's rate for any stage the table does not define, which is the same
			-- direction every other run consumer defaults in: a gear with no authored presentation looks
			-- like the ordinary run rather than freezing the clip at rate zero.
			local desiredSpeed = RUN_PLAYBACK_SPEEDS[runStage] or RUN_PLAYBACK_SPEEDS[1]
			if activeRunTrack ~= appliedRunSpeedTrack or desiredSpeed ~= appliedRunSpeed then
				activeRunTrack:AdjustSpeed(desiredSpeed)
				appliedRunSpeedTrack = activeRunTrack
				appliedRunSpeed = desiredSpeed
			end
		end
	end
end)

return CombatAnimator
