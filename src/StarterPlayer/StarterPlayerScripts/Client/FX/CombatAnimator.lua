--!strict
--[[
	CombatAnimator.lua

	Owns: the LOCAL player's ordinary locomotion animation -- a Walking loop for ordinary movement
	and a normal Running loop for Sprint, plus an optional tighter armed-running pose, on their current
	character's Animator. A single persistent Heartbeat evaluator
	re-derives "should Walking/Running be playing THIS frame" from live state every tick rather than
	being told when an action started or ended.

	ALSO OWNS the ARMED-IDLE loop -- the per-WEAPON standing pose a player holds while their sword is
	drawn and they are doing nothing else (not moving, not mid-swing, not blocking). Extended into this
	module rather than a new one because it is the exact same problem Walking/Running already solved:
	something has to beat Roblox's own default Animate script for ownership of a stationary character's
	pose, and the DOMINANT_WEIGHT technique below is the one place in this codebase that already does
	that (it plays a tier higher than Walking/Running do, though -- see loadArmedIdleTrack's own header
	on why Core is not enough for a clip that has to survive a drawn weapon).
	SetArmedWeapon(weaponId, drawn) is pushed by this module's own
	Weapon_InventoryChanged listener (see the bottom of this file) -- CombatAnimator reads that remote
	directly rather than through Client/Combat/WeaponInventoryClient.lua, whose own header documents
	itself as "the whole module" for driving the inventory HUD and nothing else. The clip for a given
	weapon comes from Shared/Combat/WeaponIdleAnimations.lua's own Animations/IDLE folder lookup -- see
	that module's header for why it is a separate file from the swing clips in Shared/Attack/
	AttackAnimations.lua. A weapon with no clip authored there plays no override at all, which lets
	Roblox's own default idle show through -- a real, unbroken answer for a weapon nobody has posed yet.

	AND OWNS ONE PIECE OF DEMOLITION ON THE SAME GROUND: silencing Roblox's default Animate script's
	TOOL animation pass for the local character (suppressDefaultToolAnimations, below). A drawn weapon
	IS a real Tool in this game (Server/Combat/Weapon/WeaponVisualSystem.lua), and the default Animate
	script answers a Tool with a static "toolnone" upper-body pose ABOVE Core priority -- which silently
	masked both the armed idle and the Walking/Running loops' arms for as long as a weapon was out.
	Owned here because this is already the one module in the codebase whose job is beating that script
	for ownership of the local character's pose; there is no second front worth a second file.

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
local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)
local FXConstants = require(ReplicatedStorage.Shared.FXConstants)
local RunConstants = require(ReplicatedStorage.Shared.Run.RunConstants)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local CombatConstants = require(ReplicatedStorage.Shared.Combat.CombatConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local AnimatorUtil = require(ReplicatedStorage.Shared.AnimatorUtil)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Trove = require(ReplicatedStorage.Shared.Trove)
local WeaponConstants = require(ReplicatedStorage.Shared.Combat.WeaponConstants)
local WeaponIdleAnimations = require(ReplicatedStorage.Shared.Combat.WeaponIdleAnimations)
local AnimationTrackUtil = require(script.Parent.AnimationTrackUtil)

local logger = Logger.scope("CombatAnimator")

local CombatAnimator = {}

-- CombatConstants.AnimationIds is the single source of truth -- now scoped to just the locomotion
-- clips (Walking/Running plus the tighter armed-running pose) since combat's own clips (swings, finishers,
-- dashes, etc.) were removed from Constants.lua alongside the rest of the combat data. This loop is
-- fully data-driven, so trimming that table is what trimmed this module's actual loaded-track set --
-- no code here needed to change to stop loading combat clips.
local ANIMATION_IDS = CombatConstants.AnimationIds

-- Walking/Running share the same fade constants so the locomotion evaluator's walk<->run crossfade
-- is symmetric on both sides. These two loops play at CORE priority, the same tier Roblox's own
-- baked-in walk/run cycle uses, and win the resulting tie on DOMINANT_WEIGHT alone -- not on priority
-- (Core is the BOTTOM of Enum.AnimationPriority, not the top; see loadArmedIdleTrack's own header for
-- what that costs the moment something ABOVE Core starts playing).
-- FXConstants.Animation.Combat -- see that table's own header in Constants.lua.
-- Shared by Walking and Running: a start/crossfade (Play(), or a Stop() that's really a handoff to
-- the OTHER locomotion loop -- see the evaluator below) uses this softer duration; a genuine
-- interrupt (the character stopping) uses LOCOMOTION_INTERRUPT_FADE_TIME instead, since that one
-- wants a fast cut, not a blend.
local LOCOMOTION_FADE_TIME = FXConstants.Animation.Combat.LocomotionFadeSeconds
local LOCOMOTION_INTERRUPT_FADE_TIME = FXConstants.Animation.Combat.LocomotionInterruptFadeSeconds
-- The normal run's playback rate and the armed-pose crossfade duration.
local RUN_STAGE_CROSSFADE_TIME = RunConstants.Animation.StageCrossfadeSeconds
local RUN_PLAYBACK_SPEEDS = RunConstants.Animation.PlaybackSpeeds

-- The MoveDirection magnitude below which there's no meaningful held movement input -- shared with
-- Client/FX/MovementVFX.lua; see CombatConstants.MovementInputMagnitudeThreshold's own header for the
-- other call sites (the server-side IsMoving it also names went with Server/Combat/Movement.lua).
local LOCOMOTION_THRESHOLD = CombatConstants.MovementInputMagnitudeThreshold

-- Priority alone (Core, set below) isn't enough: Roblox's default character rig ALSO plays its own
-- walk/run cycle at Core priority, so two same-priority tracks blend proportionally by Weight rather
-- than either cleanly winning -- without this, our own tracks read as "fighting" the default cycle.
-- A weight this far above the default's implicit 1 makes ours effectively dominant.
--
-- A single Play()-time weight isn't enough EITHER, for a sustained/held track (Running): Roblox's
-- default Animate script keeps re-evaluating and re-asserting its OWN track's weight on every
-- Humanoid movement-state change, and that re-assertion can win the tie again after ours -- the
-- Walking/Running evaluator below re-calls AdjustWeight every Heartbeat for exactly this reason.
-- FXConstants.Animation.DominantWeight -- shared with Server/Combat/BotAnimator.lua (removed) and
-- Client/FX/FlightAnimator.lua, see that field's own header.
local DOMINANT_WEIGHT = FXConstants.Animation.DominantWeight

local animationTemplates: { [string]: Animation } = {}
for name, id in pairs(ANIMATION_IDS) do
	-- Skip empty-id slots (CombatConstants.AnimationIds lists wired-but-unauthored clips as ""):
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
-- (built above, once, at module load) rather than constructing its own from CombatConstants.
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
-- Bound alongside currentHumanoid -- resolveArmedIdle (below) needs it to load a dynamically-chosen
-- clip, which is the one thing this module loads OUTSIDE the fixed animationTemplates/tracks pair
-- BindCharacter otherwise builds wholesale.
local currentAnimator: Animator? = nil

-- Reset hooks for per-life module state declared further down this file -- none of that state is
-- tied to the `tracks` table BindCharacter already rebuilds below, so left alone it survives a
-- respawn. BindCharacter (below) only actually runs at CALL time -- well after this whole module has
-- finished loading top-to-bottom -- so closing over this table here (declared before BindCharacter)
-- and registering each reset closer to its own state's declaration both work.
local perLifeResetHandlers: { () -> () } = {}
local function registerPerLifeReset(fn: () -> ()): ()
	table.insert(perLifeResetHandlers, fn)
end

-- Which weapon the player currently has DRAWN, and whether it is drawn at all -- the two inputs
-- SetArmedWeapon feeds and resolveArmedIdle reads. Deliberately NOT reset by registerPerLifeReset:
-- these are server-reported facts about the player's inventory, not per-life animation state, and
-- BindCharacter's own call to resolveArmedIdle at the end of this function re-derives the track from
-- whatever they already say the instant the new Animator exists -- regardless of whether the server's
-- own Weapon_InventoryChanged re-push for this life has arrived yet (it always does, on every
-- character bind -- see Client/Combat/WeaponInventoryClient.lua's own header -- but arrival order
-- against this client's own BindCharacter call is not guaranteed, so this function must not depend on
-- it).
local armedWeaponId: string? = nil
local armedWeaponDrawn = false

-- The currently-claimed idle track, and the asset id it was built from -- kept separate from `tracks`
-- (the Walking/Running set built once, wholesale, in BindCharacter) because this one clip is chosen
-- dynamically as the drawn weapon changes rather than fixed at bind time.
local armedIdleTrack: AnimationTrack? = nil
local armedIdleAssetId = ""
-- Loaded tracks for THIS life's Animator, keyed by asset id, so toggling the same weapon's draw state
-- on and off repeatedly -- or swapping between two weapons that share one idle clip -- does not
-- reload the same clip over and over.
local armedIdleTracksByAssetId: { [string]: AnimationTrack } = {}
registerPerLifeReset(function()
	armedIdleTrack = nil
	armedIdleAssetId = ""
	table.clear(armedIdleTracksByAssetId)
end)

-- What shouldArmedIdle resolved to on the PREVIOUS Heartbeat, purely so the evaluator below can log
-- the gate's full boolean breakdown only when it actually CHANGES rather than once a frame --
-- diagnostic-only state, read and written nowhere except that one debug line.
local lastShouldArmedIdle = false
registerPerLifeReset(function()
	lastShouldArmedIdle = false
end)

-- Every AnimationTrack name Roblox's own default Animate script can play from its TOOL animation set
-- -- the folder names it falls back to when a character has no `toolnone`/`toolslash`/`toollunge`
-- config folder, and the Animation instance names inside those folders when it does (a track takes its
-- name from the Animation instance it was loaded from, and the two paths name them differently).
-- Matched by name rather than by asset id because the ids are the default rig's, not ours, and a rig
-- variant is free to author its own.
local DEFAULT_TOOL_TRACK_NAMES: { [string]: boolean } = {
	toolnone = true,
	ToolNoneAnim = true,
	toolslash = true,
	ToolSlashAnim = true,
	toollunge = true,
	ToolLungeAnim = true,
}

-- Per-life connections owned by BindCharacter -- Shared/Trove.lua rather than a bare connection field,
-- per the module table in CLAUDE.md. Cleaned at the TOP of every BindCharacter, so a respawn never
-- leaves the previous life's Animator listener alive.
local characterTrove = Trove.New()

-- Kills Roblox's default Animate script's TOOL animations on this character, for this life.
--
-- WHY THIS EXISTS AT ALL. Server/Combat/Weapon/WeaponVisualSystem.lua draws a weapon by parenting a
-- real Tool (with a Handle) to the character and calling Humanoid:EquipTool -- deliberately, so
-- HitboxEngine's "Weapon" attachment point resolves for free. But the default Animate script polls
-- `Character:FindFirstChildOfClass("Tool")` on its own loop, and the instant it sees one it plays
-- "toolnone" -- a static arms-out pose covering the whole upper body, ABOVE Core priority. That is
-- what took the character over roughly one frame after every draw: the armed-idle stance really was
-- playing, at DOMINANT_WEIGHT, entirely masked. It masks the Walking/Running loops' arms the same way
-- for as long as a weapon is out, which is the same bug wearing different clothes.
--
-- STOPPED AT PLAY TIME, NOT BLANKED AT THE SOURCE. The obvious fix -- setting
-- Animate.toolnone.ToolNoneAnim.AnimationId to "" -- leaves the Animate script calling
-- Animator:LoadAnimation on a blank Animation from inside its own unprotected `while` loop; if that
-- ever throws, the loop dies and takes the character's default jump/fall/climb/swim animations with
-- it, silently. Animator.AnimationPlayed is free (it fires exactly when the Animate script starts the
-- track, no per-frame poll of GetPlayingAnimationTracks) and Stop() on a track cannot throw. The
-- Animate script does not re-play a tool clip it has already started -- it only reloads when the
-- animation INSTANCE changes -- so one Stop per draw is the whole cost.
--
-- Does not touch the default idle/walk/run tracks: those are Core priority and DOMINANT_WEIGHT already
-- beats them, and stopping them would leave an unauthored weapon (no IDLE clip in its own Animations
-- folder -- see WeaponIdleAnimations' own header) standing in a genuine T-pose instead of Roblox's
-- default idle, which is the documented fallback.
local function suppressDefaultToolAnimations(animator: Animator): ()
	local function stopIfToolTrack(track: AnimationTrack): ()
		if DEFAULT_TOOL_TRACK_NAMES[track.Name] then
			track:Stop(0)
		end
	end
	-- Already-playing pass first: BindCharacter can run after the Animate script has started (a
	-- respawn straight back into a drawn weapon), and AnimationPlayed only reports tracks started
	-- AFTER the connection.
	for _, track in animator:GetPlayingAnimationTracks() do
		stopIfToolTrack(track)
	end
	characterTrove:Connect(animator.AnimationPlayed, stopIfToolTrack)
end

-- Loads (and caches, for this life) the track for `assetId` against the current Animator, or nil if
-- there is no Animator yet or the load fails. Mirrors BindCharacter's own pcall'd LoadAnimation below
-- -- a failure here costs one warning and no armed-idle override, never a wedged character.
local function loadArmedIdleTrack(assetId: string): AnimationTrack?
	local existing = armedIdleTracksByAssetId[assetId]
	if existing then
		return existing
	end
	local animator = currentAnimator
	if not animator then
		return nil
	end
	local animation = Instance.new("Animation")
	animation.Name = "ArmedIdle"
	animation.AnimationId = assetId
	local ok, trackOrError = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not ok then
		logger:warn("Failed to load armed-idle animation", {
			assetId = assetId,
			errorMessage = tostring(trackOrError),
		})
		return nil
	end
	local track = trackOrError :: AnimationTrack
	-- MOVEMENT, NOT CORE, AND THAT IS THE WHOLE OF WHY THE ARMED IDLE USED TO BE INVISIBLE.
	-- Enum.AnimationPriority ascends Core(1000) < Idle(2000) < Movement(3000) < Action(4000) < Action2
	-- ...; Core is the BOTTOM of the ladder, not the top. Walking/Running get away with Core because
	-- the thing they fight -- Roblox's own default walk/run cycle -- is ALSO Core, so DOMINANT_WEIGHT
	-- decides the tie. The armed idle fights something else entirely: the moment a weapon is drawn,
	-- Server/Combat/Weapon/WeaponVisualSystem.lua parents a real Tool to the character, and Roblox's
	-- default Animate script's own tool-animation pass then plays "toolnone" over the whole upper body
	-- ABOVE Core priority -- no weight can beat a priority tier, so the stance clip kept playing at
	-- DOMINANT_WEIGHT while being completely masked (the pose visibly flipped to toolnone one frame
	-- after every draw). suppressDefaultToolAnimations below removes that track at the source; this
	-- sits above Idle anyway so a tool clip that slips through (a rig whose Animate script this client
	-- never got to touch) still loses. Stays BELOW Action so swings/blocks keep winning outright --
	-- activeActionSources' own gate is what keeps this from blending under them at all.
	track.Priority = Enum.AnimationPriority.Movement
	track.Looped = true
	armedIdleTracksByAssetId[assetId] = track
	-- Length is the cheapest way to tell "this clip is a moving loop" from "this clip is a single held
	-- pose" apart from actually watching it play -- a length near 0 means there is nothing for Looped
	-- to loop, which reads as "stuck" in play even once everything else here is working correctly.
	logger:debug("Loaded armed-idle animation", { assetId = assetId, lengthSeconds = track.Length })
	return track
end

-- Re-derives which idle clip (if any) should be claimed, from the currently-remembered weapon/drawn
-- state -- called on every SetArmedWeapon push and once more at the end of BindCharacter. Cheap to
-- call redundantly (the id-equality check below makes a repeat call a no-op), so both call sites can
-- call it freely without coordinating who "really" needs to.
--
-- STOPS THE OUTGOING TRACK ITSELF, BEFORE SWAPPING THE REFERENCE OUT FROM UNDER IT, and that is not
-- optional. armedIdleTrack is the one entry in the Heartbeat evaluator's locomotionLoopEntries whose
-- TRACK OBJECT ITSELF changes over a character's life (a different weapon's clip, or nil once
-- sheathed) rather than only its ShouldPlay -- Walking/Running/RunningStage2 each keep
-- the exact same Track for the whole life and only ever toggle whether it should play. Without this,
-- swapping armedIdleTrack here (to a different clip, or to nil on sheathe) leaves the PREVIOUS track
-- with no reference anywhere that still points at it: AnimationTrackUtil.DriveDominantLoop can only
-- Stop() a track it can currently see via entry.Track, and by the very next Heartbeat that field
-- already holds the NEW value. The old track keeps playing, still holding Core priority and
-- DOMINANT_WEIGHT, forever -- which is exactly "the character's pose locks the instant you sheathe"
-- rather than a crash or a warning, because nothing ever errors: the orphaned track simply never
-- stops.
local function resolveArmedIdle(): ()
	local desiredAssetId = if armedWeaponDrawn then WeaponIdleAnimations.Get(armedWeaponId) else ""
	if desiredAssetId == armedIdleAssetId then
		return
	end
	local previousAssetId = armedIdleAssetId
	armedIdleAssetId = desiredAssetId
	local outgoing = armedIdleTrack
	armedIdleTrack = if desiredAssetId ~= "" then loadArmedIdleTrack(desiredAssetId) else nil
	local outgoingStopped = false
	if outgoing and outgoing ~= armedIdleTrack and outgoing.IsPlaying then
		outgoing:Stop(LOCOMOTION_INTERRUPT_FADE_TIME)
		outgoingStopped = true
	end
	logger:debug("Armed-idle resolved", {
		weaponId = armedWeaponId,
		drawn = armedWeaponDrawn,
		fromAssetId = previousAssetId,
		toAssetId = desiredAssetId,
		outgoingWasPlaying = outgoingStopped,
		-- Re-read on EVERY resolve, not just the one load log in loadArmedIdleTrack -- the cached
		-- track is reused across every redraw of the same weapon, so this is what actually tells
		-- apart "the clip is genuinely empty" from "Length just hadn't finished loading yet the
		-- first time" -- Roblox populates Length asynchronously once the animation's real content
		-- arrives, and the very first LoadAnimation call can read 0 before that happens.
		currentTrackLengthSeconds = if armedIdleTrack then armedIdleTrack.Length else nil,
	})
end

-- Pushed by this module's own Weapon_InventoryChanged listener (bottom of this file) on every draw/
-- sheath/select and on every character bind. `drawn` false clears the override outright rather than
-- resolving WeaponIdleAnimations.Get and discarding it -- a sheathed weapon has no stance to hold.
function CombatAnimator.SetArmedWeapon(weaponId: string?, drawn: boolean): ()
	armedWeaponId = weaponId
	armedWeaponDrawn = drawn
	resolveArmedIdle()
end

-- Rebuilds every AnimationTrack against `character`'s own Animator. Safe to call on a character with
-- no Humanoid yet (returns having loaded nothing).
function CombatAnimator.BindCharacter(character: Model): ()
	tracks = {}
	currentHumanoid = nil
	currentAnimator = nil
	characterTrove:Clean()
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
	currentAnimator = animator
	suppressDefaultToolAnimations(animator)

	local humanoid = CharacterUtil.HumanoidOf(character)
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
			-- RunningStage2 is the armed-run loop. A sustained locomotion track whose Looped flag was never set plays through once
			-- and leaves the character in a T-pose-adjacent idle.
			if name == "Running" or name == "RunningStage2" or name == "Walking" then
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

	-- Re-derives the armed-idle track against the Animator just bound above, from whatever
	-- armedWeaponId/armedWeaponDrawn already say -- see those fields' own header for why this cannot
	-- simply wait for the next Weapon_InventoryChanged push.
	resolveArmedIdle()
end

-- Tracks the player's held Sprint INTENT -- whether that intent actually plays/keeps playing the
-- Running track is decided fresh every frame by the eligibility evaluator below, never here. Nothing
-- in this codebase currently pushes this (Sprint's own request/response plumbing lived in the
-- now-removed CombatSystem.lua/CombatClient.lua) -- kept as public API surface, ready to be wired
-- into whatever replaces Sprint's server-side brain rather than deleted and re-invented later.
--
-- Note the sprint LADDER did get rebuilt, in Server/Systems/RunSystem.lua, and this module is not
-- what it drives: Client/Movement/RunController.lua owns the intent and the stage readout. This flag
-- is the animator's own local mirror and nothing pushes it today.
local sprintHeld = false

function CombatAnimator.StartRunning(): ()
	sprintHeld = true
end

function CombatAnimator.StopRunning(): ()
	sprintHeld = false
end

--
-- Kept as the RunController seam, but a single-speed run does not need a per-stage animation choice.
function CombatAnimator.SetRunStage(_stage: number): () end

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

-- Sources currently holding an Action-priority pose on this same character -- the swing claim
-- (Client/Combat/AttackInputClient.lua) and the block/parry hold (Client/Defense/DefenseClient.lua).
-- Both play through their OWN, entirely separate AnimationManager instances at
-- Enum.AnimationPriority.Action; the armed-idle loop below plays at Movement, one tier BELOW that (see
-- loadArmedIdleTrack's own header for why it is not Core). So a swing already wins the joints it
-- animates outright, and this set is not what makes that true -- it is what keeps the stance from
-- bleeding through on the joints a swing clip does NOT key, which reads as the character half-holding
-- its guard through its own attack. The evaluator below refuses to play the armed-idle loop at all
-- while anything is in this set.
--
-- A SET KEYED BY SOURCE, NOT A PLAIN COUNTER, so two independent callers can each clear their own
-- claim without one accidentally clearing the other's, and so a caller that fires two "active" pushes
-- in a row (a swing immediately superseding another) costs one table write rather than needing to be
-- balanced against two clears.
local activeActionSources: { [string]: boolean } = {}

-- Pushed by AttackInputClient/DefenseClient the instant their own Action-priority claim actually
-- becomes the active track on their layer (not merely requested -- a claim that fails to load must
-- never wedge this true forever), and cleared from that same claim's OnFinished, which fires for
-- EVERY way a claim stops owning its layer (Completed/Superseded/Cleared/Expired/Failed alike) --
-- see Shared/Animation/AnimationManager.lua's own FinishReason. That is deliberately the only way this
-- is ever cleared: there is no timer and no per-frame re-derivation, because "is a claim active" is
-- exactly what AnimationManager already tracks and reports.
function CombatAnimator.SetActionAnimationActive(source: string, active: boolean): ()
	if active then
		activeActionSources[source] = true
	else
		activeActionSources[source] = nil
	end
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

-- Reused across every Heartbeat instead of building a fresh `{ {...}, {...}, {...}, {...} }`
-- argument each frame -- AnimationTrackUtil.DriveDominantLoop only reads these synchronously within
-- the call and never retains the table, so it's safe to mutate the four entries' fields in place below
-- rather than allocate all five tables (the array plus its four entries) 60 times a second forever. The
-- fourth entry is the armed-idle loop -- see CombatAnimator's own header on why it belongs in this same
-- mutually-exclusive set rather than a second evaluator.
local locomotionLoopEntries: { AnimationTrackUtil.DominantLoopEntry } = {
	{ Track = nil, ShouldPlay = false, PlayFadeSeconds = 0, StopFadeSeconds = 0 },
	{ Track = nil, ShouldPlay = false, PlayFadeSeconds = 0, StopFadeSeconds = 0 },
	{ Track = nil, ShouldPlay = false, PlayFadeSeconds = 0, StopFadeSeconds = 0 },
	{ Track = nil, ShouldPlay = false, PlayFadeSeconds = 0, StopFadeSeconds = 0 },
}

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
	-- nil whenever the optional armed-running clip is blank -- a supported state that falls through to
	-- the normal running loop rather than going silent.
	local runningStage2Track = tracks.RunningStage2
	local walkingTrack = tracks.Walking
	if runningTrack or runningStage2Track or walkingTrack or armedIdleTrack then
		-- Also silenced while Flying (Client/Flight/FlightController.lua/FlightAnimator.lua own the
		-- character's animation entirely during flight) -- Boost reuses the Sprint keybind and raw
		-- WASD can still register nonzero MoveDirection mid-flight, so without this guard the
		-- ground-locomotion loop could blend in underneath a Hover/Cruise/Boost flight pose.
		local flying = currentHumanoid ~= nil and currentHumanoid:GetAttribute(AttributeConstants.Flying) == true
		local moving = not flying
			and currentHumanoid ~= nil
			and currentHumanoid.MoveDirection.Magnitude > LOCOMOTION_THRESHOLD
		-- locomotionSuppressed is the parkour framework's veto -- see CombatAnimator.
		-- SetLocomotionSuppressed's own header for the conflict it closes. A vault or a wall-run is no
		-- more a WALK than it is a run.
		local canLocomote = moving and not locomotionSuppressed
		local shouldRun = sprintHeld and canLocomote
		local shouldWalk = not sprintHeld and canLocomote
		-- Grounded, not moving, not flying, not mid-traversal, nothing Action-priority claiming the
		-- body (see activeActionSources' own header), and a weapon idle clip actually resolved. The
		-- FloorMaterial check is armed-idle's own addition on top of what Walking/Running already
		-- silence for: a standing pose at the apex of a jump (MoveDirection can read ~0 there with no
		-- WASD held) reads as broken in a way a paused walk cycle does not.
		local grounded = currentHumanoid ~= nil and currentHumanoid.FloorMaterial ~= Enum.Material.Air
		local shouldArmedIdle = armedIdleTrack ~= nil
			and grounded
			and not flying
			and not moving
			and not locomotionSuppressed
			and next(activeActionSources) == nil
		if shouldArmedIdle ~= lastShouldArmedIdle then
			lastShouldArmedIdle = shouldArmedIdle
			logger:debug("Armed-idle gate changed", {
				shouldArmedIdle = shouldArmedIdle,
				hasTrack = armedIdleTrack ~= nil,
				grounded = grounded,
				flying = flying,
				moving = moving,
				locomotionSuppressed = locomotionSuppressed,
				activeActionSource = next(activeActionSources),
			})
		end
		-- A drawn weapon uses the tighter armed-run pose. This is visual only: the one normal sprint
		-- speed still comes from RunConstants.Stages[1]. If its optional clip is unavailable, the
		-- ordinary running loop remains active instead.
		local shouldRunStage2 = shouldRun and runningStage2Track ~= nil and armedWeaponDrawn
		local shouldRunStage1 = shouldRun and not shouldRunStage2

		-- Client/FX/AnimationTrackUtil.lua's shared evaluator -- see that module's own header for why
		-- this per-Heartbeat Play/AdjustWeight/Stop mechanic is extracted (the exact same shape
		-- FlightAnimator.lua's Hover/CruiseLoop/BoostLoop pick uses below it). Only the StopFadeSeconds
		-- per track varies here: an armed-pose change crossfades at RUN_STAGE_CROSSFADE_TIME; a toggle to
		-- the OTHER locomotion track (still moving, Sprint
		-- pressed/released) crossfades symmetrically at LOCOMOTION_FADE_TIME; a genuine interrupt
		-- (stopped moving, or the parkour framework taking the body) cuts fast at
		-- LOCOMOTION_INTERRUPT_FADE_TIME.
		local stage1Entry, stage2Entry, walkEntry, armedIdleEntry =
			locomotionLoopEntries[1], locomotionLoopEntries[2], locomotionLoopEntries[3], locomotionLoopEntries[4]

		stage1Entry.Track = runningTrack
		stage1Entry.ShouldPlay = shouldRunStage1
		stage1Entry.PlayFadeSeconds = LOCOMOTION_FADE_TIME
		stage1Entry.StopFadeSeconds = if shouldRunStage2
			then RUN_STAGE_CROSSFADE_TIME
			elseif shouldWalk then LOCOMOTION_FADE_TIME
			else LOCOMOTION_INTERRUPT_FADE_TIME

		stage2Entry.Track = runningStage2Track
		stage2Entry.ShouldPlay = shouldRunStage2
		stage2Entry.PlayFadeSeconds = RUN_STAGE_CROSSFADE_TIME
		stage2Entry.StopFadeSeconds = if shouldRunStage1
			then RUN_STAGE_CROSSFADE_TIME
			elseif shouldWalk then LOCOMOTION_FADE_TIME
			else LOCOMOTION_INTERRUPT_FADE_TIME

		walkEntry.Track = walkingTrack
		walkEntry.ShouldPlay = shouldWalk
		walkEntry.PlayFadeSeconds = LOCOMOTION_FADE_TIME
		walkEntry.StopFadeSeconds = if shouldRun then LOCOMOTION_FADE_TIME else LOCOMOTION_INTERRUPT_FADE_TIME

		-- Soft fade in either direction between standing still and starting to move (matches Walking's
		-- own toggle fade); a hard cut only for a genuine interrupt of the idle pose itself (an action
		-- claims the body, or the parkour framework does).
		armedIdleEntry.Track = armedIdleTrack
		armedIdleEntry.ShouldPlay = shouldArmedIdle
		armedIdleEntry.PlayFadeSeconds = LOCOMOTION_FADE_TIME
		armedIdleEntry.StopFadeSeconds = if shouldWalk or shouldRun
			then LOCOMOTION_FADE_TIME
			else LOCOMOTION_INTERRUPT_FADE_TIME

		AnimationTrackUtil.DriveDominantLoop(locomotionLoopEntries, DOMINANT_WEIGHT)

		-- The normal run playback rate, written only when the track or rate changes -- see
		-- appliedRunSpeedTrack's own header.
		local activeRunTrack = if shouldRunStage2 then runningStage2Track else runningTrack
		if shouldRun and activeRunTrack then
			local desiredSpeed = RUN_PLAYBACK_SPEEDS[1]
			if activeRunTrack ~= appliedRunSpeedTrack or desiredSpeed ~= appliedRunSpeed then
				activeRunTrack:AdjustSpeed(desiredSpeed)
				appliedRunSpeedTrack = activeRunTrack
				appliedRunSpeed = desiredSpeed
			end
		end
	end
end)

-- Weapon_InventoryChanged -------------------------------------------------------------------------

-- Feeds SetArmedWeapon straight off the server's own inventory push -- connected once, the same
-- "one persistent connection, not a per-life rebind" shape the Heartbeat evaluator above already
-- uses. Read here directly rather than through Client/Combat/WeaponInventoryClient.lua, whose own
-- header documents itself as "the whole module" for driving the inventory HUD and nothing else --
-- adding a second job to it would break that promise, and Roblox remotes support any number of
-- independent listeners for free.
--
-- The server re-pushes the full payload on every pickup/draw/sheath/select AND on every character
-- bind (see WeaponConstants.Network.RemoteNames.InventoryChanged's own header), so this needs no
-- separate PlayerLifecycle hookup of its own the way BindCharacter does -- whatever this last received
-- is re-applied against the freshly bound Animator by BindCharacter's own resolveArmedIdle() call.
local function onInventoryChanged(raw: unknown): ()
	if typeof(raw) ~= "table" then
		return
	end
	local payload = raw :: WeaponConstants.InventoryPayload
	if typeof(payload.Drawn) ~= "boolean" then
		return
	end
	-- What is actually in hand (Fists whenever nothing else is drawn), so the idle stance matches it.
	if typeof(payload.InHand) == "string" then
		CombatAnimator.SetArmedWeapon(payload.InHand, true)
	else
		CombatAnimator.SetArmedWeapon(payload.Selected, payload.Drawn)
	end
end

-- DEFERRED, NOT CONNECTED INLINE AT MODULE LOAD -- NetworkBridge.GetRemoteEvent WaitForChild's up to
-- Constants.Network.WaitForChildTimeoutSeconds the first time a name is resolved (self-heals into a
-- table hit after), and this module is required synchronously from Client/Main.client.lua's own
-- top-level require list alongside RunController/FlightController. A blocking wait here at require
-- time would stall the WHOLE client boot behind this one remote existing, which is exactly the trap
-- every other remote-touching client module in this codebase avoids by resolving inside its own
-- Start() instead of at module load. CombatAnimator has no Start() of its own to hook into (nothing
-- else about it needs one), so task.spawn is the minimal fix: the require returns immediately, and
-- this connects on the very next resumption instead of blocking the caller.
task.spawn(function()
	NetworkBridge.GetRemoteEvent(WeaponConstants.Network.RemoteNames.InventoryChanged).OnClientEvent
		:Connect(onInventoryChanged)
end)

return CombatAnimator
