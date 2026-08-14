--!strict
--[[
	CombatAnimator.lua

	Owns: loading and playing the LOCAL player's own combat animations (the three M1 swing stages,
	the Uppercut/Downslam/Normal finisher variants, the standalone AirSlam attack (jump + M1, always
	the Downslam clip -- see PlayPredictedAirSlam), a Walking loop for ordinary movement that
	crossfades into one of TWO Running loops for Sprint (the run system's stage 1 and stage 2 -- see
	CombatAnimator.SetRunStage, and Client/Movement/RunController.lua for who decides which), a held
	BlockHold stance + one-shot ParryFlash for
	Block/Parry, four directional one-shot Dash clips plus the distinct DashPunch clip for a
	double-tap-W throw specifically, one non-directional Slide clip (chained off
	Sprint -- see PlayPredictedSlide), three Hit1/2/3 reaction clips played on the DEFENDER when
	an opponent's Basic1/2/3 lands, Feint's own swing-cancel (CancelActiveSwing -- stops whatever
	swing/finisher/AirSlam clip is currently playing, optionally crossfading into a dedicated Feint
	recoil clip), and a Move Creation System move's full authored animation TIMELINE
	(PlayCustomMoveTimeline -- an ordered, independently-timed multi-clip schedule resolved by
	Shared/AnimationTimeline.lua, distinct from the single-clip PlayExplicitAnimation below it) on
	their current character's Animator.
	Roblox replicates a played AnimationTrack to every other client automatically once it's loaded
	and played through the OWNING player's own Animator, so triggering these from this client
	(CombatClient.lua, reacting to server-confirmed Combat_AttackStarted / held Sprint input) is
	enough for every other player to see the swing too -- no server involvement needed for the
	animation itself, only for deciding whether the swing/sprint was legal in the first place, which
	CombatSystem.lua already owns and this module never touches.

	Real animation ids, supplied for this pass (not guessed -- see e.g. CombatAudio.lua/VitalIcon.lua's
	headers for why this codebase never fabricates an asset id). Basic and Secondary-weapon (Dagger)
	stages share the same three swing animations -- no weapon-specific set exists yet; Heavy attacks
	have no dedicated animation yet either and are a silent no-op here (still get SwingEffect's
	camera punch, just no character animation) until one is supplied.

	Dash direction (Front/Back/Left/Right) is resolved client-side from the dashing character's own
	Humanoid.MoveDirection against its HumanoidRootPart facing at the moment PlayPredictedDash/
	ConfirmDash is called -- the server never sends a direction (Movement.lua's ApplyDash is a pure
	WalkSpeed burst; the player's own already-held movement input carries them, per that module's
	own header), so this is the only place a direction exists to pick from.

	Hit1/2/3 map 1:1 onto the attacker's Basic1/2/3 DebugName via the same trailing-digit extraction
	PlaySwing already uses for its own stage lookup (Shared/CombatDebugNames.lua's
	SwingStageFromDebugName -- shared with Client/Combat/PredictionMirror.lua and
	ServerScriptService/Server/Combat/BotAnimator.lua, see that module's own header) -- reused, not
	duplicated. Only fires for an unmitigated "Hit" (never "Blocked": a blocking defender is already
	showing BlockHold and shouldn't flinch out of it), and only on the DEFENDER's own client -- see
	CombatClient.lua's Combat_FeedbackEvent handler.

	Reloads every AnimationTrack on each CharacterAdded (CombatClient.lua calls BindCharacter), since
	a Track is tied to the specific Animator instance it was loaded from -- a respawned character has
	a brand new one.

	Does not own: deciding WHEN to play one of these, or whether a swing/sprint is actually legal --
	CombatClient.lua is the only caller, translating a server-confirmed swing start or a held Sprint
	input into a call here.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local Logger = require(ReplicatedStorage.Shared.Logger)
local AnimatorUtil = require(ReplicatedStorage.Shared.AnimatorUtil)
local CombatDebugNames = require(ReplicatedStorage.Shared.CombatDebugNames)
local AnimationTimeline = require(ReplicatedStorage.Shared.AnimationTimeline)
local AnimationTrackUtil = require(script.Parent.AnimationTrackUtil)

local logger = Logger.scope("CombatAnimator")

local CombatAnimator = {}

-- Constants.Combat.AnimationIds is the single source of truth, shared with
-- ServerScriptService/.../Combat/BotAnimator.lua's identical bot-facing player -- see that
-- constant's own header.
local ANIMATION_IDS = Constants.Combat.AnimationIds

-- One-shot swings play snappy (a fast fade-in reads as responsive, matching this pass's broader
-- "combat should feel immediate" work); Walking/Running fade a little more smoothly since they're
-- continuous locomotion loops, not a discrete hit -- and share the SAME fade constants (below) so
-- the locomotion evaluator's walk<->run crossfade is symmetric on both sides. Action priority
-- (above the default Movement-tier walk/run cycle) so these actually visually override Roblox's
-- own baked-in animations instead of fighting them for the same joints.
-- All of these (except ROLLBACK_FADE_TIME below) now read from the single shared
-- Constants.FX.Animation.Combat table -- see that table's own header in Constants.lua for why these
-- used to be independently hand-typed here AND in Server/Combat/BotAnimator.lua/Client/FX/
-- FlightAnimator.lua.
local SWING_FADE_TIME = Constants.FX.Animation.Combat.SwingFadeSeconds
-- Shared by Walking and Running: a start/crossfade (Play(), or a Stop() that's really a handoff to
-- the OTHER locomotion loop -- see the evaluator below) uses this softer duration; a genuine
-- interrupt (a combat action starting, or the character stopping) uses LOCOMOTION_INTERRUPT_FADE_TIME
-- instead, since that one wants a fast cut, not a blend.
local LOCOMOTION_FADE_TIME = Constants.FX.Animation.Combat.LocomotionFadeSeconds
local BLOCK_HOLD_FADE_TIME = Constants.FX.Animation.Combat.BlockHoldFadeSeconds
local PARRY_FLASH_FADE_TIME = Constants.FX.Animation.Combat.ParryFlashFadeSeconds
local DASH_FADE_TIME = Constants.FX.Animation.Combat.DashFadeSeconds
local SLIDE_FADE_TIME = Constants.FX.Animation.Combat.SlideFadeSeconds
local HIT_REACTION_FADE_TIME = Constants.FX.Animation.Combat.HitReactionFadeSeconds
local LOCOMOTION_INTERRUPT_FADE_TIME = Constants.FX.Animation.Combat.LocomotionInterruptFadeSeconds
-- The run system's own three numbers (Constants.Run.Animation) -- the crossfade between the two run
-- stages' clips, and each stage's playback rate. Kept as their own tunables rather than borrowing
-- LOCOMOTION_FADE_TIME above even though the crossfade currently happens to equal it: they answer
-- different questions (walk<->run vs. run<->full stride) and retuning one should never silently move
-- the other, the same "each context keeps its own copy even where values start equal" convention
-- Constants.lua's own comments already document.
local RUN_STAGE_CROSSFADE_TIME = Constants.Run.Animation.StageCrossfadeSeconds
local RUN_STAGE1_PLAYBACK_SPEED = Constants.Run.Animation.Stage1PlaybackSpeed
local RUN_STAGE2_PLAYBACK_SPEED = Constants.Run.Animation.Stage2PlaybackSpeed
-- Fade for rolling back a MISPREDICTED track (the server rejected, or confirmed a different
-- stage/mode than the client predicted) -- slightly softer than the snappy play-side fades so a
-- rolled-back swing melts toward idle instead of popping. Already single-sourced from
-- Constants.Combat.Prediction (not Constants.FX.Animation.Combat above) -- nothing to centralize
-- further here, see Constants.FX.Animation's own header note on this field.
local ROLLBACK_FADE_TIME = Constants.Combat.Prediction.RollbackFadeSeconds

-- The MoveDirection magnitude below which there's no meaningful held movement input -- shared by
-- resolveDashDirection's own "no direction to resolve" nil branch and the Walking/Running
-- eligibility evaluator below, since both are asking the identical question ("is this character
-- actually being steered right now"). Now Constants.Combat.MovementInputMagnitudeThreshold -- see
-- that field's own header for the other three call sites (Server/Combat/Movement.lua x2, Client/FX/
-- MovementVFX.lua) that used to hand-type this same 0.1 independently.
local LOCOMOTION_THRESHOLD = Constants.Combat.MovementInputMagnitudeThreshold

-- Priority alone (Core, set below) isn't enough: Roblox's default character rig ALSO plays its own
-- walk/run cycle at Core, so two same-priority tracks blend proportionally by Weight rather than
-- either cleanly winning -- without this, our own tracks read as "fighting" the default cycle
-- (weird leg motion, a dash/swing that never visibly finishes because the default keeps pulling
-- weight back toward itself). A weight this far above the default's implicit 1 makes ours
-- effectively dominant without needing to reach into and stop Roblox's own Animate script tracks
-- directly (unsupported/fragile across rig setups this codebase can't fully control).
--
-- A single Play()-time weight isn't enough EITHER, for a sustained/held track (Running) or one
-- whose dominance needs to hold for its whole (short but nonzero) window (Dash): Roblox's default
-- Animate script keeps re-evaluating and re-asserting its OWN track's weight on every Humanoid
-- movement-state change (which a WalkSpeed burst triggers repeatedly), and that re-assertion can
-- win the tie again after ours -- observed as the custom animation playing correctly for the local
-- (dashing/sprinting) player but not for remote viewers, who render the same weighted blend from
-- replicated track state and can catch it after the default script re-asserted. The Walking/Running
-- evaluator below and startDashClip both re-call AdjustWeight every Heartbeat for their own
-- duration instead of trusting a single Play()-time value to stick. Constants.FX.Animation.
-- DominantWeight -- shared with Server/Combat/BotAnimator.lua and Client/FX/FlightAnimator.lua, see
-- that field's own header.
local DOMINANT_WEIGHT = Constants.FX.Animation.DominantWeight

local animationTemplates: { [string]: Animation } = {}
for name, id in pairs(ANIMATION_IDS) do
	-- Skip empty-id slots (Constants.Combat.AnimationIds lists wired-but-unauthored clips as ""):
	-- no template means no load attempt and tracks[name] stays nil, so every play path degrades to
	-- its documented no-op/fallback. Building a template for "" would only invite a load warning
	-- for a clip we already know isn't supplied.
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

-- Bound in BindCharacter, read only by resolveDashDirection -- the one place this module needs to
-- inspect the character's own MoveDirection/facing rather than just play a server/input-triggered
-- track by name.
local currentCharacter: Model? = nil
-- Cached alongside currentCharacter so the Walking/Running eligibility evaluator (below) can read
-- live MoveDirection every frame without a FindFirstChildOfClass lookup on the hot path.
local currentHumanoid: Humanoid? = nil

-- Reset hooks for per-life module state declared further down this file (combatActionTrackCount,
-- predictedSwing/currentSwingTrack, blockHoldWeightConnection, predictedSlide, predictedDash) --
-- none of that state is tied to the `tracks` table BindCharacter already rebuilds below, so left
-- alone it survives a respawn. Concretely: PlayBlockHold only creates its per-Heartbeat AdjustWeight
-- loop `if not blockHoldWeightConnection` -- die while holding Block (death is never an InputEnded,
-- so StopBlockHold never runs) and that stale-but-still-non-nil connection silently skips creating a
-- fresh loop for the NEXT life's BlockHold track, which is exactly the "plays for the local player,
-- not for remote viewers" symptom DOMINANT_WEIGHT's own header describes. combatActionTrackCount has
-- the same exposure via a different mechanism: it's only decremented by a track's own .Stopped, which
-- isn't guaranteed to fire when the character/Animator is destroyed out from under a still-playing
-- track (a mid-swing/mid-dash death), so a stuck-nonzero count would permanently block Walking/
-- Running from ever playing again. BindCharacter (below) only actually runs at CALL time -- well
-- after this whole module has finished loading top-to-bottom -- so closing over this table here
-- (declared before BindCharacter) and registering each reset closer to its own state's declaration
-- (preserving this file's existing declare-near-use style) both work: every handler is registered
-- long before BindCharacter is ever invoked for a real respawn.
local perLifeResetHandlers: { () -> () } = {}
local function registerPerLifeReset(fn: () -> ()): ()
	table.insert(perLifeResetHandlers, fn)
end

-- Rebuilds every AnimationTrack against `character`'s own Animator. Safe to call on a character
-- with no Humanoid yet (returns having loaded nothing; CombatClient.lua's own WaitForChild already
-- guards the common case, this is just defense in depth).
function CombatAnimator.BindCharacter(character: Model): ()
	tracks = {}
	currentCharacter = character
	currentHumanoid = nil
	-- Every OTHER piece of per-life state this file owns (see perLifeResetHandlers' own header
	-- above) -- a fresh character has no in-flight prediction, no held exclusive-action count, and
	-- no leftover weight-reassert connection from whatever the previous life was doing when it died.
	for _, reset in perLifeResetHandlers do
		reset()
	end

	-- Shared/AnimatorUtil.lua -- the same find-Humanoid/find-or-create-Animator plumbing
	-- ServerScriptService/Server/Combat/BotAnimator.lua and this file's own sibling
	-- Client/FX/FlightAnimator.lua need too; see that module's own header for why it's safe to
	-- share across the client/server boundary (pure Instance manipulation, no authoritative state).
	local animator = AnimatorUtil.GetOrCreateAnimator(character)
	if not animator then
		logger:warn("BindCharacter: no Humanoid/Animator available", { character = character.Name })
		return
	end

	-- Diagnostic only, not consumed for any decision: RigType matters because an animation
	-- authored for the wrong rig (R15 vs R6) can load without error and Play() without error, and
	-- still produce zero visible motion -- Length == 0 (or a suspiciously tiny number) on a track
	-- that loaded cleanly is the tell that the asset itself has no real keyframe data for this rig,
	-- which is a Roblox-asset problem, not something fixable from this module's code.
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	currentHumanoid = humanoid
	local rigType = humanoid and humanoid.RigType

	for name, animation in pairs(animationTemplates) do
		local ok, trackOrError = pcall(function()
			return animator:LoadAnimation(animation)
		end)
		if ok then
			local track = trackOrError :: AnimationTrack
			-- Core, not Action4: current Roblox default character rigs play their own walk/run
			-- cycle at Core priority (a platform change made after this Action-tier convention was
			-- established elsewhere in this codebase's comments), which otherwise wins over
			-- anything lower whenever the character has real MoveDirection input -- exactly the
			-- symptom reported for Dash (a sustained WalkSpeed burst fighting the default cycle for
			-- the whole dash). Matching Core is the standard workaround; since every track here is
			-- one of OUR OWN combat animations and never plays two-at-once by design, they don't
			-- fight each other for it.
			track.Priority = Enum.AnimationPriority.Core
			-- RunningStage2 joins the looped set for the same reason Running does -- it IS the run
			-- loop, at the second stage. Missing it here was the exact bug that made wall-runs play
			-- their clip once and stop (see ParkourAnimator's VARIANT_CLIPS header): a sustained
			-- locomotion track whose Looped flag was never set plays through once and leaves the
			-- character in a T-pose-adjacent idle for the rest of the run.
			if name == "Running" or name == "RunningStage2" or name == "Walking" or name == "BlockHold" then
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

-- Picks the dominant axis of the dashing character's current input relative to its own facing --
-- forward/back vs. left/right decided by whichever component of MoveDirection is larger in
-- magnitude. Returns nil when there's no meaningful held movement input (no direction to show a
-- dash traveling in) -- the same "stationary Dash press" case Movement.ResolveDashDirection
-- returns nil for server-side, mirrored here so a Q-dash with no movement key held plays no
-- animation at all rather than defaulting to a "Front" clip that isn't actually happening. Reads
-- currentCharacter (bound in BindCharacter) rather than taking a parameter since both callers
-- (ConfirmDash, and PlayPredictedDash for its non-double-tap case) have nothing else to pass -- the
-- server's MovementPerformed payload carries no direction (see this file's header).
local function resolveDashDirection(): ("Front" | "Back" | "Left" | "Right")?
	local character = currentCharacter
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not (rootPart and rootPart:IsA("BasePart")) then
		return nil
	end

	local moveDirection = humanoid.MoveDirection
	if moveDirection.Magnitude < LOCOMOTION_THRESHOLD then
		return nil
	end

	local rootCFrame = (rootPart :: BasePart).CFrame
	local forwardComponent = moveDirection:Dot(rootCFrame.LookVector)
	local rightComponent = moveDirection:Dot(rootCFrame.RightVector)

	if math.abs(forwardComponent) >= math.abs(rightComponent) then
		return if forwardComponent >= 0 then "Front" else "Back"
	end
	return if rightComponent >= 0 then "Right" else "Left"
end

-- Resolves the swing animation track NAME for an attack, shared by every play path below so a
-- predicted swing and its later server-confirmed echo agree on which clip to show.
--   * ANY finisher (Uppercut/Downslam/Normal) -> its own clip if one is loaded, else "Uppercut" as
--     the stand-in (the only finisher clip guaranteed to exist so far -- every variant is still the
--     same dramatic 4th-hit commitment, so using it beats showing nothing until Downslam/
--     FinisherNormal ids are supplied; a predicted "Uppercut" that the server resolves to a Downslam
--     crossfades on confirm once that clip exists -- see ConfirmSwing).
--   * Otherwise "Swing1/2/3" for whichever Basic-string stage the trailing digit names.
--   * A Heavy stage now maps to "Heavy1/2" if that clip is loaded; a Heavy with no matching clip
--     (or any name with no trailing digit) returns nil -- a silent no-op, logged by callers.
local function finisherTrackName(finisherVariant: Types.FinisherVariant): string
	local specific = if finisherVariant == "Downslam"
		then "Downslam"
		elseif finisherVariant == "Normal" then "FinisherNormal"
		else "Uppercut"
	if tracks[specific] then
		return specific
	end
	return "Uppercut"
end

local function resolveSwingTrackName(
	debugName: string,
	isHeavy: boolean,
	finisherVariant: Types.FinisherVariant?
): string?
	if finisherVariant then
		return finisherTrackName(finisherVariant)
	end
	-- Shared/CombatDebugNames.lua -- the same trailing-digit extraction Client/Combat/
	-- PredictionMirror.lua and ServerScriptService/Server/Combat/BotAnimator.lua both need too; see
	-- that module's own header for why this is one shared function, not three copies.
	local stage = CombatDebugNames.SwingStageFromDebugName(debugName)
	if not stage then
		return nil
	end
	if isHeavy then
		local heavyName = "Heavy" .. tostring(stage)
		return if tracks[heavyName] then heavyName else nil
	end
	return "Swing" .. tostring(stage)
end

-- Animation/hitbox sync. Every swing clip always plays at its own authored (native) speed --
-- deliberately NOT stretched/compressed to span the real windup+active+recovery seconds
-- Constants.Combat.Weapons' per-stage table schedules the hitbox against (an earlier revision did
-- exactly that, but stretching the clip to fill a wider/narrower commitment window changes how the
-- swing *looks* every time a WindupSeconds/ActiveSeconds/RecoverySeconds tunable changes, which is
-- exactly what the Hitbox Timing dev-menu tab is for -- see DevMenu/init.lua -- and that tool is
-- explicitly for retiming the HITBOX, not the animation). The two are intentionally independent now:
-- WindupSeconds/ActiveSeconds/RecoverySeconds only ever gate the server's real hitbox-active window
-- (HitboxResolver.lua) and the attacker's commitment lock (state.attackEndsAt) -- they have zero
-- effect on this module's playback rate. If a clip's authored swing pose doesn't visually line up
-- with the real hitbox-active window, that's a clip-timing mismatch to fix by re-authoring the clip
-- or retiming WindupSeconds to match where the clip's own swing motion actually lands -- never by
-- speed-stretching the animation to paper over it.

-- Counts currently-playing swing/dash/BlockHold tracks -- i.e. every DOMINANT_WEIGHT track in
-- this file EXCEPT Walking/Running themselves. Walking/Running are only eligible to play while
-- this is zero (see the locomotion eligibility evaluator below) -- two of THIS FILE'S OWN tracks at
-- equal DOMINANT_WEIGHT don't cleanly override each other, they BLEND (see DOMINANT_WEIGHT's own
-- header), which is exactly what "run and punch at the same time" looked like before this existed:
-- the Running loop kept playing, unaware a swing/dash/block had also started.
--
-- Incremented right after Play(), decremented once via the track's own .Stopped signal -- which
-- fires on natural completion, an explicit Stop() (including a rollback), or a crossfade-out
-- alike, so this can never drift the way a scheduled task.delay resume could (the exact bug class
-- CombatSystem.lua's own onHeartbeat header already argues against server-side: "never
-- task.delay, so they never race... and lose data"). This is that same principle applied
-- client-side to the Running/action conflict, replacing what used to be a bespoke
-- interrupt-then-remember-to-resume dance duplicated per action (Dash had one; Attack and Block
-- never got their own copies, which is how bugs #3/#4 happened).
local combatActionTrackCount = 0
-- Which tracks are currently counted, so a track can never be counted twice -- see
-- trackExclusiveAction below for why counting a re-Play()ed track again permanently strands the
-- count above zero.
local countedActionTracks: { [AnimationTrack]: true } = {}
registerPerLifeReset(function()
	combatActionTrackCount = 0
	table.clear(countedActionTracks)
end)

local function trackExclusiveAction(track: AnimationTrack): ()
	-- Play() on an ALREADY-playing track restarts it without firing .Stopped, so a second
	-- trackExclusiveAction for the same still-playing track would add a second increment that only
	-- ever gets one decrement back (the single Stopped that eventually fires). The count would sit
	-- permanently at >= 1 and the locomotion evaluator below, which only plays Walking/Running while
	-- it's exactly 0, would never play either again for the rest of this life. Reachable wherever a
	-- play path lacks its own IsPlaying guard: playSwingByName (a re-thrown stage whose previous clip
	-- is still running) and playDominantOneShot (the same dash direction twice inside one clip
	-- length) both call through here unguarded. Counting per-track rather than per-Play() makes the
	-- helper idempotent, which is the invariant the count actually wants -- "how many exclusive
	-- tracks are playing," not "how many times Play was called."
	if countedActionTracks[track] then
		return
	end
	countedActionTracks[track] = true
	combatActionTrackCount += 1
	local connection: RBXScriptConnection? = nil
	connection = track.Stopped:Connect(function()
		countedActionTracks[track] = nil
		combatActionTrackCount = math.max(0, combatActionTrackCount - 1)
		if connection then
			connection:Disconnect()
		end
	end)
end

-- The one predicted swing track currently awaiting server confirmation, or nil. Set by
-- PlayPredictedSwing, cleared by ConfirmSwing/CancelPredictedSwing. Only ever one pending at a time
-- -- CombatClient's PredictionMirror.OnPredictionPending holds the shared commitment gate closed
-- for the round-trip, so a second predictable attack can't start before this one resolves. Cancelled
-- is set by CancelActiveSwing (Feint) when a feint lands BEFORE this swing's own AttackStarted echo
-- has arrived -- see that function's own header for why ConfirmSwing needs to know, rather than just
-- nil-ing this out early, to avoid resurrecting a swing the player already watched get cut short.
local predictedSwing: { Track: AnimationTrack, Name: string, Cancelled: boolean? }? = nil

-- The current swing/finisher/AirSlam track, predicted or confirmed, or nil -- lets
-- CancelActiveSwing (Feint) stop whichever one is actually playing right now regardless of whether
-- its confirm echo has arrived yet. Set on every swing play (both PlayPredictedSwing/
-- PlayPredictedAirSlam and ConfirmSwing route through playSwingByName below), cleared on the
-- track's own .Stopped so a stale reference can never linger past natural completion, a rollback,
-- or a feint.
local currentSwingTrack: AnimationTrack? = nil
registerPerLifeReset(function()
	predictedSwing = nil
	currentSwingTrack = nil
end)

-- The current Dash/Slide dominant one-shot track (playDominantOneShot below), if any -- defense-
-- in-depth alongside CombatSystem.lua's activeActionKind structural fix (setActiveAction): that
-- server-side change is the real gate against two commitment-consuming actions ever being legal at
-- once, but this file had NO independent mutual exclusion of its own before this (playDominantOneShot
-- just played whatever it was told to, on top of whatever was already playing -- two DOMINANT_WEIGHT
-- tracks blend rather than override, see DOMINANT_WEIGHT's own header). If a desync ever did let two
-- windows read open at once (a tuning slip, a mispredicted client), this is what stops it from being
-- VISIBLE as two blended clips instead of just a data-layer bug nobody sees.
local currentDominantOneShotTrack: AnimationTrack? = nil
registerPerLifeReset(function()
	currentDominantOneShotTrack = nil
end)

local function trackCurrentSwing(track: AnimationTrack): ()
	currentSwingTrack = track
	local connection: RBXScriptConnection? = nil
	connection = track.Stopped:Connect(function()
		if currentSwingTrack == track then
			currentSwingTrack = nil
		end
		if connection then
			connection:Disconnect()
		end
	end)
end

local function playSwingByName(
	trackName: string?,
	debugName: string,
	finisherVariant: Types.FinisherVariant?
): AnimationTrack?
	local track = if trackName then tracks[trackName] else nil
	if track then
		-- Stop a still-playing Dash/Slide clip before starting a swing -- see
		-- currentDominantOneShotTrack's own header for why this cross-stop exists.
		if
			currentDominantOneShotTrack
			and currentDominantOneShotTrack ~= track
			and currentDominantOneShotTrack.IsPlaying
		then
			currentDominantOneShotTrack:Stop(ROLLBACK_FADE_TIME)
		end
		track:Play(SWING_FADE_TIME, DOMINANT_WEIGHT)
		trackExclusiveAction(track)
		trackCurrentSwing(track)
	else
		logger:warn("PlaySwing: no track to play (never loaded, or no animation for this attack yet)", {
			debugName = debugName,
			finisherVariant = finisherVariant,
			trackName = trackName,
		})
	end
	return track
end

-- Plays a swing immediately at press time, BEFORE the server confirms it, off the client's local
-- prediction (Client/Combat/PredictionMirror.lua said the press is legal). stageIndex/isFinisher
-- come straight from PredictionMirror.PredictedSwing. The variant isn't known yet (the server picks
-- Uppercut/Downslam/Normal at throw time), so a predicted finisher shows the Uppercut stand-in and
-- ConfirmSwing crossfades if the real variant differs. Records the track so ConfirmSwing can no-op
-- on a match and CancelPredictedSwing can roll it back.
function CombatAnimator.PlayPredictedSwing(stageIndex: number, isFinisher: boolean): ()
	local trackName = if isFinisher then finisherTrackName("Uppercut") else "Swing" .. tostring(stageIndex)
	logger:debug("PlayPredictedSwing", {
		stageIndex = stageIndex,
		isFinisher = isFinisher,
		trackName = trackName,
	})
	local track = playSwingByName(trackName, if isFinisher then "Finisher" else "Basic" .. tostring(stageIndex), nil)
	predictedSwing = if track then { Track = track, Name = trackName } else nil
end

-- Plays the standalone AirSlam attack's predicted animation (jump + M1) -- CombatClient calls this
-- instead of PlayPredictedSwing when the LOCAL character is airborne at press time. Always the
-- Downslam clip (or its Uppercut stand-in until one is loaded) -- AirSlam never has a stage/combo
-- concept, it always resolves with FinisherVariant = "Downslam" server-side (see
-- Constants.Combat.AirSlam's own header), so there's nothing to guess here the way a grounded
-- finisher's Uppercut/Downslam/Normal split needs to. Shares predictedSwing/ConfirmSwing/
-- CancelPredictedSwing's own bookkeeping -- the server confirms an air slam through the SAME
-- Combat_AttackStarted event (DebugName = "AirSlam", FinisherVariant = "Downslam"), so
-- ConfirmSwing's existing name-match reconciliation already handles it correctly.
function CombatAnimator.PlayPredictedAirSlam(): ()
	local trackName = finisherTrackName("Downslam")
	logger:debug("PlayPredictedAirSlam", { trackName = trackName })
	local track = playSwingByName(trackName, "AirSlam", "Downslam")
	predictedSwing = if track then { Track = track, Name = trackName } else nil
end

-- Dynamically loads (and caches by trackName, into the SAME `tracks` table every static-id clip
-- lives in -- see BindCharacter's own loop above) a SINGLE Animation whose id isn't known until
-- runtime, authored well after BindCharacter's own animationTemplates loop already ran. Caching into
-- `tracks` means it participates in trackExclusiveAction/currentDominantOneShotTrack/DOMINANT_WEIGHT
-- exactly like any static-id swing -- no parallel bookkeeping needed. Two remaining callers, both a
-- single legacy clip rather than a multi-clip timeline (see PlayCustomMoveTimeline above for that
-- case -- the Move Creation System's own swing no longer reaches this function): CombatClient's
-- Combat_AttackStarted handler for the Object Stun follow-up throw's own AnimationId/
-- AnimationTrackName pair (INSTEAD OF ConfirmSwing, for the same DebugName-trailing-digit reason
-- PlayCustomMoveTimeline's own header explains), and its ObjectStun feedback handler for the
-- Attacker/VictimAnimationId a wall-slam impact authors.
function CombatAnimator.PlayExplicitAnimation(animationId: string, trackName: string): AnimationTrack?
	if tracks[trackName] then
		return playSwingByName(trackName, trackName, nil)
	end

	local character = currentCharacter
	local animator = if character then AnimatorUtil.GetOrCreateAnimator(character) else nil
	if not animator or animationId == "" then
		return nil
	end

	local animation = Instance.new("Animation")
	animation.AnimationId = animationId
	local ok, trackOrError = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not ok then
		logger:warn(
			"PlayExplicitAnimation: load failed",
			{ animationId = animationId, errorMessage = tostring(trackOrError) }
		)
		return nil
	end

	local track = trackOrError :: AnimationTrack
	-- Core, not the default -- see BindCharacter's own identical Priority comment for why every
	-- combat clip in this module matches the default character rig's own walk/run priority.
	track.Priority = Enum.AnimationPriority.Core
	tracks[trackName] = track
	return playSwingByName(trackName, trackName, nil)
end

-- The `tracks` cache key for one custom-move timeline clip -- folds a Move Creation System move's
-- dynamically-loaded clips into the SAME table every static-id clip and PlayExplicitAnimation's own
-- dynamic id already live in (see BindCharacter's own loop and PlayExplicitAnimation's own header),
-- so a timeline clip participates in trackExclusiveAction/DOMINANT_WEIGHT/FreezeActiveCombatTrack
-- exactly like any other combat track, and BindCharacter's `tracks = {}` on every respawn tears it
-- down for free -- no parallel cache, no parallel cleanup. Keyed by ClipId AND AnimationId together,
-- mirroring PreviewViewport's own loadedTracks cache exactly (see that module's header for why BOTH
-- halves matter: two clips sharing one asset still need independent tracks, and re-pointing a clip at
-- a different asset loads a fresh one instead of replaying the old one). Prefixed with "CustomMove|"
-- so this can never collide with a static animationTemplates name (none of which contain "|").
local function customMoveTrackKey(clip: AnimationTimeline.Clip): string
	return `CustomMove|{clip.ClipId}|{clip.AnimationId}`
end

-- The custom-move timeline currently in flight, if any -- CombatAnimator.PlayCustomMoveTimeline
-- (below) sets this; the persistent Heartbeat evaluator's own custom-move block (see that
-- evaluator's header) starts/stops each ScheduledClip as `elapsed` crosses its window, the same
-- syncTimeline idea PreviewViewport's own Play button drives, just against the single shared
-- evaluator instead of a private per-play connection -- see that evaluator's own comment on why
-- every other timed/held combat track in this file already works this way instead of spawning its
-- own coroutine. Reset (dropped, never Stop()ped -- the Animator it belonged to is already gone by
-- the time a per-life reset runs) on every respawn, same convention as predictedSwing/currentSwingTrack
-- above.
local activeCustomMoveTimeline: {
	Scheduled: { AnimationTimeline.ScheduledClip },
	Playing: { [string]: AnimationTrack },
	StartClock: number,
}? =
	nil
registerPerLifeReset(function()
	activeCustomMoveTimeline = nil
end)

-- Loads (or returns the cached track for) one custom-move timeline clip -- see customMoveTrackKey's
-- own header for the cache it shares with every other combat track. pcall because an admin can
-- author any string into a clip's AnimationId and LoadAnimation throws on a malformed or
-- inaccessible asset; one bad clip must not take the rest of the timeline down with it, the same
-- reasoning PreviewViewport's own loadClipTrack gives for its identical pcall.
local function loadCustomMoveClipTrack(clip: AnimationTimeline.Clip): AnimationTrack?
	local key = customMoveTrackKey(clip)
	local existing = tracks[key]
	if existing then
		return existing
	end
	local character = currentCharacter
	local animator = if character then AnimatorUtil.GetOrCreateAnimator(character) else nil
	if not animator then
		return nil
	end
	local animation = Instance.new("Animation")
	animation.AnimationId = clip.AnimationId
	local ok, trackOrError = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not ok then
		logger:warn(
			"PlayCustomMoveTimeline: clip load failed",
			{ clipId = clip.ClipId, animationId = clip.AnimationId, errorMessage = tostring(trackOrError) }
		)
		return nil
	end
	local track = trackOrError :: AnimationTrack
	-- Core, not the default -- see BindCharacter's own identical Priority comment.
	track.Priority = Enum.AnimationPriority.Core
	tracks[key] = track
	return track
end

-- Plays a Move Creation System move's full authored animation TIMELINE against the REAL character's
-- Animator -- the runtime counterpart of PreviewViewport's own Play button, driven by the SAME pure
-- AnimationTimeline.Resolve scheduler so the editor's preview and a real swing can never disagree
-- about what plays when (see AnimationTimeline.lua's own header). Called from CombatClient's
-- Combat_AttackStarted handler whenever the payload carries a non-nil Animations list (Types.
-- AttackStartedPayload.Animations' own header) -- REPLACES ConfirmSwing entirely for that throw, not
-- layered alongside it: a custom move's DebugName is always its MoveId (MoveTypes.
-- ToHitboxAttackDefinition), an admin-authored slug+suffix with no relationship to the M1 combo stage
-- numbering ConfirmSwing's DebugName-trailing-digit inference exists for.
--
-- `clips` is the raw authored list straight off the wire -- move.Animations, or that move's legacy
-- single AnimationId already projected onto a one-clip list server-side by
-- AnimationTimeline.FromLegacyAnimationId (see CombatSystem.ThrowCustomMove's own header) -- and
-- `timings` is that same payload's own WindupSeconds/ActiveSeconds/RecoverySeconds, so Resolve here
-- runs against the EXACT window the server actually scheduled, never a locally-guessed one. An empty
-- schedule (nothing authored, or every clip disabled/blank) is a legal, silent no-op: still supersedes
-- whatever the PREVIOUS custom move left playing, but starts nothing new -- see this function's own
-- caller for why that must never fall back to guessing an animation instead.
function CombatAnimator.PlayCustomMoveTimeline(
	clips: { AnimationTimeline.Clip },
	timings: AnimationTimeline.PhaseTimings,
	moveId: string
): ()
	if activeCustomMoveTimeline then
		-- A second custom move thrown before the first one's timeline finished -- stop every clip
		-- STILL genuinely playing rather than let it silently blend into the new move's own clips.
		-- The per-life reset above instead drops the reference with no Stop() call, since on a
		-- respawn the Animator it belonged to is already gone; this branch is specifically the
		-- still-alive-Animator case.
		for _, track in pairs(activeCustomMoveTimeline.Playing) do
			if track.IsPlaying then
				track:Stop(ROLLBACK_FADE_TIME)
			end
		end
		activeCustomMoveTimeline = nil
	end

	-- A custom move committing to a swing is itself an exclusive combat action -- stop whatever
	-- dominant one-shot (Dash/Slide) or M1/finisher swing is still running, the same cross-stop
	-- playSwingByName/playDominantOneShot already give each other.
	if currentDominantOneShotTrack and currentDominantOneShotTrack.IsPlaying then
		currentDominantOneShotTrack:Stop(ROLLBACK_FADE_TIME)
	end
	if currentSwingTrack and currentSwingTrack.IsPlaying then
		currentSwingTrack:Stop(ROLLBACK_FADE_TIME)
	end

	local scheduled = AnimationTimeline.Resolve(clips, timings)
	logger:debug("PlayCustomMoveTimeline", { moveId = moveId, clipCount = #scheduled })
	if #scheduled == 0 then
		return
	end

	activeCustomMoveTimeline = {
		Scheduled = scheduled,
		Playing = {},
		StartClock = os.clock(),
	}
end

-- Starts every scheduled custom-move clip that just became live and releases every one that just
-- ended -- called from the persistent Heartbeat evaluator below. The exact same idempotent-per-frame
-- idea as PreviewViewport's own syncTimeline (a clip already in Playing is never re-Played), just
-- against activeCustomMoveTimeline's real-Animator tracks instead of the preview dummy's. A
-- "Natural"/LetPlayOut clip (AnimationTimeline.ScheduledClip.LetPlayOut's own header) is deliberately
-- never Stopped here -- left BOTH running and registered in Playing so PlayCustomMoveTimeline's own
-- supersede cross-stop (or a respawn) can still release it later, without this per-frame pass ever
-- cutting it short on its own.
local function syncCustomMoveTimeline(): ()
	local timeline = activeCustomMoveTimeline
	if not timeline then
		return
	end
	local elapsed = os.clock() - timeline.StartClock
	for _, entry in ipairs(timeline.Scheduled) do
		local clip = entry.Clip
		local isLive = elapsed >= entry.StartSeconds and elapsed < entry.StopSeconds
		local track = timeline.Playing[clip.ClipId]
		if isLive and not track then
			local loaded = loadCustomMoveClipTrack(clip)
			if loaded then
				loaded.Looped = clip.Looped
				loaded:Play(clip.FadeInSeconds, clip.Weight, clip.Speed)
				trackExclusiveAction(loaded)
				timeline.Playing[clip.ClipId] = loaded
			end
		elseif not isLive and track and not entry.LetPlayOut then
			track:Stop(clip.FadeOutSeconds)
			timeline.Playing[clip.ClipId] = nil
		end
	end
	if elapsed >= AnimationTimeline.ScheduleEnd(timeline.Scheduled) then
		-- Every clip has either already stopped itself above or is a LetPlayOut clip left to finish
		-- on its own -- nothing left for this evaluator to drive. Only the bookkeeping is released;
		-- see this function's own header for why a LetPlayOut track is never Stopped here.
		activeCustomMoveTimeline = nil
	end
end

-- Confirms (or corrects) a swing from the server's Combat_AttackStarted echo. Two cases:
--   * a prediction is pending and the confirmed clip MATCHES it -> the predicted track is already
--     playing at native speed; nothing to do (no visual pop -- this is the common case).
--   * a prediction is pending and the confirmed clip DIFFERS (mispredicted variant, or the server
--     threw a different stage than the mirror guessed) -> crossfade: fade the predicted track out
--     and play the real one.
--   * no prediction is pending (a Buffered/NoPredict press whose echo arrived, or a swing this
--     client didn't originate) -> just play it, exactly as the old PlaySwing did.
function CombatAnimator.ConfirmSwing(debugName: string, isHeavy: boolean, finisherVariant: Types.FinisherVariant?): ()
	local trackName = resolveSwingTrackName(debugName, isHeavy, finisherVariant)
	local pending = predictedSwing
	predictedSwing = nil

	logger:debug("ConfirmSwing", {
		debugName = debugName,
		isHeavy = isHeavy,
		finisherVariant = finisherVariant,
		trackName = trackName,
		hadPrediction = pending ~= nil,
		matched = pending ~= nil and pending.Name == trackName,
		cancelled = pending ~= nil and pending.Cancelled == true,
	})

	if pending and pending.Cancelled then
		-- Feinted before this echo arrived (CancelActiveSwing raced the round trip) -- the player
		-- already watched this swing get cut short locally; don't resurrect it just because the
		-- (now-moot) confirm landed after. The server-side outcome is unaffected either way -- this
		-- is purely "don't play the animation again," never a hit/damage decision.
		return
	end
	if pending and pending.Name == trackName then
		return
	end
	if pending and pending.Name ~= trackName then
		pending.Track:Stop(ROLLBACK_FADE_TIME)
	end
	playSwingByName(trackName, debugName, finisherVariant)
end

-- Rolls back a predicted swing the server rejected (Combat_ActionRejected) or never confirmed
-- (prediction timeout) -- fades the predicted track out instead of leaving a stuck pose. No-op if
-- nothing is pending (the confirm already consumed it, or this press was never predicted).
function CombatAnimator.CancelPredictedSwing(): ()
	local pending = predictedSwing
	predictedSwing = nil
	if pending then
		logger:debug("CancelPredictedSwing", { trackName = pending.Name })
		pending.Track:Stop(ROLLBACK_FADE_TIME)
	end
end

-- Feint: stops whichever swing/finisher/AirSlam track is CURRENTLY playing (predicted or already
-- confirmed -- see currentSwingTrack's own header), crossfading into the dedicated "Feint" clip if
-- one has been authored (Constants.Combat.AnimationIds.Feint), or just fading to idle if not (the
-- same safe wired-but-unauthored degrade every other optional slot in this file uses). Called
-- UNCONDITIONALLY by CombatClient.lua's Feint input branch the instant right-click is pressed --
-- deliberately NOT gated behind a predict/rollback round trip like every other action in this file:
-- stopping your OWN swing animation early has no gameplay outcome to get wrong (hit resolution is
-- server-side and reads none of this), so there is nothing here that could need rolling back. If the
-- server ends up rejecting the underlying Feint request (the swing was already past its windup), the
-- swing still resolves for real -- this just means the attacker's own screen stops showing it a beat
-- early, a harmless, self-correcting cosmetic gap, not a desync.
--
-- If a prediction is still awaiting its OWN confirm echo when this fires (a feint pressed before the
-- original swing's AttackStarted has round-tripped back), marking it Cancelled instead of nil-ing it
-- out is what stops ConfirmSwing from replaying the very swing this just cut short once that echo
-- does arrive -- see ConfirmSwing's own Cancelled branch.
function CombatAnimator.CancelActiveSwing(): ()
	if predictedSwing then
		predictedSwing.Cancelled = true
	end

	local track = currentSwingTrack
	if not track or not track.IsPlaying then
		return
	end

	logger:debug("CancelActiveSwing")
	track:Stop(ROLLBACK_FADE_TIME)

	local feintTrack = tracks.Feint
	if feintTrack then
		feintTrack:Play(SWING_FADE_TIME, DOMINANT_WEIGHT)
		trackExclusiveAction(feintTrack)
	end
end

-- Tracks the player's held Sprint INTENT (set true/false by StartRunning/StopRunning below) --
-- whether that intent actually plays/keeps playing the Running track is decided fresh every frame
-- by the eligibility evaluator below, never by StartRunning/StopRunning themselves.
local sprintHeld = false

-- Held-Sprint INTENT only -- see CombatClient.lua's InputBegan/InputEnded Sprint handling for when
-- these are called. Whether Running actually plays this frame is computed by the persistent
-- evaluator below (sprintHeld AND no exclusive action AND real movement input), not decided here --
-- this function used to also Play()/manage a weight-reassert connection itself, which is exactly
-- what made every OTHER action that should silence Running (a swing, a block) need its own bespoke
-- "remember to interrupt, remember to resume" copy of the same dance. One evaluator, reacting to
-- sprintHeld/combatActionTrackCount/MoveDirection every frame, replaces all of that.
function CombatAnimator.StartRunning(): ()
	sprintHeld = true
end

function CombatAnimator.StopRunning(): ()
	sprintHeld = false
end

-- THE RUN SYSTEM'S TWO STAGES, pushed in by Client/Movement/RunController.lua (which mirrors the
-- server's own Constants.Attributes.SprintStage -- the stage is never decided on this side).
--
-- Stage 2 plays its own clip when Constants.Combat.AnimationIds.RunningStage2 is authored, and
-- otherwise falls through to the stage-1 Running loop played faster
-- (Constants.Run.Animation.Stage2PlaybackSpeed) -- the same blank-id fallthrough ParkourAnimator uses
-- for its own half-authored variant pairs, so this ships correctly whether or not a second run clip
-- exists yet.
--
-- An intent value only, exactly like sprintHeld above: whether either clip actually plays this frame
-- is re-derived by the evaluator below, never decided here.
local runStage = 1

function CombatAnimator.SetRunStage(stage: number): ()
	runStage = stage
end

-- Whether something OTHER than ordinary locomotion currently owns this character's movement -- set by
-- RunController from the parkour framework's live state id (a slide, a wall-run, a vault, a ledge
-- climb, an airborne state).
--
-- This is the fix for a real, long-standing conflict rather than a new feature. The eligibility test
-- below used to be "sprint held AND no combat action AND MoveDirection non-zero", every part of which
-- stays true throughout a parkour slide, wall-run or vault -- so the Running loop kept playing at
-- Core priority and DOMINANT_WEIGHT straight over the top of ParkourAnimator's own Movement-priority
-- slide/wall-run clip, which is why those traversals looked like a character running sideways along a
-- wall. Combat actions already had a channel for this (combatActionTrackCount); parkour had none,
-- because at the time this evaluator was written the parkour framework did not exist.
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
-- real change and NOT every frame. Per-frame AdjustSpeed on a locomotion track would silently defeat
-- CombatAnimator.FreezeActiveCombatTrack: a hit-stop freezes every track's Speed to 0 and restores it
-- on a timer, and a per-frame writer would undo the freeze on the very next Heartbeat, so a hit
-- landing on a running player would visibly not freeze.
--
-- Reset per life alongside every other piece of per-life state (see perLifeResetHandlers' own
-- header): the tracks themselves are rebuilt against the new character's Animator, so a remembered
-- handle to the previous life's track would never match again and the speed would never be
-- re-applied for the new one.
local appliedRunSpeedTrack: AnimationTrack? = nil
local appliedRunSpeed = 0
registerPerLifeReset(function()
	appliedRunSpeedTrack = nil
	appliedRunSpeed = 0
end)

-- The single, continuously-correct answer to "should Walking/Running be playing THIS frame" --
-- connected once at module load (not per Sprint-press), so it never needs to be told when an
-- action started or ended; it just re-derives the right answer every tick from state that's
-- already being kept current elsewhere (sprintHeld, combatActionTrackCount, live MoveDirection).
-- Same "never task.delay, so nothing can race a stale restore" principle
-- Movement.ComputeDesiredWalkSpeed already uses server-side for the identical class of problem
-- (multiple effects that can each want to claim one property), applied here to the Walking/
-- Running/swing/dash/block conflict instead of WalkSpeed.
--
-- Walking and Running are mutually exclusive (same reasoning as combatActionTrackCount above --
-- two same-priority DOMINANT_WEIGHT tracks BLEND rather than override), but a toggle straight
-- between them (Sprint pressed/released while still moving) uses LOCOMOTION_FADE_TIME on BOTH the
-- outgoing Stop() and the incoming Play() -- a symmetric crossfade -- rather than
-- LOCOMOTION_INTERRUPT_FADE_TIME's fast cut, which is reserved for a genuine interrupt (a combat
-- action starting, or the character actually stopping).
RunService.Heartbeat:Connect(function()
	local runningTrack = tracks.Running
	-- nil whenever Constants.Combat.AnimationIds.RunningStage2 is still blank -- which is the shipped
	-- default, and the case every branch below is written to handle by falling through to the stage-1
	-- track rather than by going silent.
	local runningStage2Track = tracks.RunningStage2
	local walkingTrack = tracks.Walking
	-- Guards only the Running/Walking half below, NOT the Dash/DashPunch/Slide re-assert further
	-- down -- Running/Walking/Dash/Slide are independently gated per-slot on whether
	-- Constants.Combat.AnimationIds supplied a non-empty id for that name (see animationTemplates'
	-- own comment above: an empty id means no template, so tracks[name] stays nil forever). A
	-- content set that ships Dash/Slide without Running/Walking authored yet is exactly the case
	-- this file's existing "every play path degrades to its documented no-op/fallback" contract is
	-- meant to support, so the dash reassert below must not be skipped just because this half has
	-- nothing to do.
	if runningTrack or runningStage2Track or walkingTrack then
		-- Also silenced while Flying (Client/DevMenu/FlightController.lua/FlightAnimator.lua own the
		-- character's animation entirely during flight) -- Boost reuses the Sprint keybind and raw
		-- WASD can still register nonzero MoveDirection mid-flight (PlatformStand suspends
		-- WalkSpeed-driven movement, not the Humanoid's MoveDirection reporting itself), so without
		-- this guard the ground-locomotion loop could blend in underneath a Hover/Cruise/Boost
		-- flight pose.
		local flying = currentHumanoid ~= nil and currentHumanoid:GetAttribute(Constants.Attributes.Flying) == true
		local moving = not flying
			and currentHumanoid ~= nil
			and currentHumanoid.MoveDirection.Magnitude > LOCOMOTION_THRESHOLD
		local noAction = combatActionTrackCount == 0
		-- locomotionSuppressed is the parkour framework's veto -- see CombatAnimator.
		-- SetLocomotionSuppressed's own header for the conflict it closes. Folded into the shared
		-- `canLocomote` rather than into shouldRun alone because a vault or a wall-run is no more a
		-- WALK than it is a run.
		local canLocomote = noAction and moving and not locomotionSuppressed
		local shouldRun = sprintHeld and canLocomote
		local shouldWalk = not sprintHeld and canLocomote
		-- The second run stage only claims its own track when there IS one. With RunningStage2 still
		-- blank (the shipped default), stage 2 keeps the stage-1 track and is carried entirely by the
		-- faster playback rate below, plus RunController's own audio/FOV -- so a half-authored content
		-- set degrades to "the same run, harder" rather than to no run animation at all.
		local shouldRunStage2 = shouldRun and runStage >= 2 and runningStage2Track ~= nil
		local shouldRunStage1 = shouldRun and not shouldRunStage2

		-- Client/FX/AnimationTrackUtil.lua's shared evaluator -- see that module's own header for
		-- why this per-Heartbeat Play/AdjustWeight/Stop mechanic is extracted (the exact same shape
		-- FlightAnimator.lua's Hover/CruiseLoop/BoostLoop pick uses below it). Only the
		-- StopFadeSeconds per track varies here, and now across three cases rather than two: a stage
		-- change between the two run clips crossfades at RUN_STAGE_CROSSFADE_TIME (the two are the
		-- same action at different intensities, so it should read as accelerating); a toggle to the
		-- OTHER locomotion track (still moving, Sprint pressed/released) crossfades symmetrically at
		-- LOCOMOTION_FADE_TIME; a genuine interrupt (stopped moving, a combat action starting, or the
		-- parkour framework taking the body) cuts fast at LOCOMOTION_INTERRUPT_FADE_TIME.
		AnimationTrackUtil.DriveDominantLoop({
			{
				Track = runningTrack,
				ShouldPlay = shouldRunStage1,
				PlayFadeSeconds = LOCOMOTION_FADE_TIME,
				StopFadeSeconds = if shouldRunStage2
					then RUN_STAGE_CROSSFADE_TIME
					elseif shouldWalk then LOCOMOTION_FADE_TIME
					else LOCOMOTION_INTERRUPT_FADE_TIME,
			},
			{
				Track = runningStage2Track,
				ShouldPlay = shouldRunStage2,
				PlayFadeSeconds = RUN_STAGE_CROSSFADE_TIME,
				StopFadeSeconds = if shouldRunStage1
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
		-- appliedRunSpeedTrack's own header for why a per-frame write here would break hit-stop.
		local activeRunTrack = if shouldRunStage2 then runningStage2Track else runningTrack
		if shouldRun and activeRunTrack then
			local desiredSpeed = if runStage >= 2 then RUN_STAGE2_PLAYBACK_SPEED else RUN_STAGE1_PLAYBACK_SPEED
			if activeRunTrack ~= appliedRunSpeedTrack or desiredSpeed ~= appliedRunSpeed then
				activeRunTrack:AdjustSpeed(desiredSpeed)
				appliedRunSpeedTrack = activeRunTrack
				appliedRunSpeed = desiredSpeed
			end
		end
	end

	-- Dash/DashPunch/Slide one-shot re-assert (see playDominantOneShot below) folded into this same
	-- persistent evaluator rather than each Play() spawning its own private
	-- "while track.IsPlaying do Heartbeat:Wait()" coroutine. That per-swing coroutine had no handle
	-- anything could hold, so BindCharacter's perLifeResetHandlers (see currentDominantOneShotTrack's
	-- own declaration/header further up this file) couldn't stop it on a mid-swing death -- and its
	-- only exit condition, track.IsPlaying, is exactly the value this file's own comments already
	-- document as unreliable on a destroyed character (".Stopped isn't guaranteed to fire when the
	-- character/Animator is destroyed out from under a still-playing track"). Die mid-dash/mid-
	-- DashPunch/mid-Slide and the old loop could run forever, resumed every Heartbeat, closing over
	-- (and so keeping alive) the destroyed character Model for the rest of the session.
	-- currentDominantOneShotTrack already has a per-life reset (nils to nil on respawn), so
	-- re-asserting it here inherits that teardown for free -- no separate handle to leak.
	if currentDominantOneShotTrack and currentDominantOneShotTrack.IsPlaying then
		currentDominantOneShotTrack:AdjustWeight(DOMINANT_WEIGHT)
	end

	-- Move Creation System custom-move timeline sync -- see syncCustomMoveTimeline's own header for
	-- why this lives inside the SAME persistent connection as the re-asserts above rather than a
	-- private per-throw Heartbeat:Connect (the exact class of leak-on-death bug this evaluator was
	-- already consolidated to avoid -- see this function's own opening comment).
	syncCustomMoveTimeline()
end)

-- Held-Block stance -- see CombatClient.lua's Block InputBegan/InputEnded handling for when these
-- are called. Client-predicted off raw input, same reasoning as StartRunning above: the server
-- accepts a BlockStart press into at least a plain block regardless of parry-cooldown state (see
-- CombatSystem.lua's handleBlockStart), so there's no legality wait worth the input lag here --
-- only the parry-specific flash below waits on server confirmation. Joins combatActionTrackCount
-- (see that helper's own header) so the Running loop goes quiet the instant guard comes up, the
-- same "one stance at a time" rule CombatSystem.lua's commitAndThrowAttack now enforces
-- server-side for blocking-vs-attacking.
local blockHoldWeightConnection: RBXScriptConnection? = nil
registerPerLifeReset(function()
	if blockHoldWeightConnection then
		blockHoldWeightConnection:Disconnect()
		blockHoldWeightConnection = nil
	end
end)

function CombatAnimator.PlayBlockHold(): ()
	local track = tracks.BlockHold
	if not track then
		logger:debug("PlayBlockHold: no track loaded yet (BlockHold has no asset id supplied)")
		return
	end
	if not track.IsPlaying then
		track:Play(BLOCK_HOLD_FADE_TIME, DOMINANT_WEIGHT)
		trackExclusiveAction(track)
	end
	if not blockHoldWeightConnection then
		blockHoldWeightConnection = RunService.Heartbeat:Connect(function()
			if track.IsPlaying then
				track:AdjustWeight(DOMINANT_WEIGHT)
			end
		end)
	end
end

function CombatAnimator.StopBlockHold(): ()
	if blockHoldWeightConnection then
		blockHoldWeightConnection:Disconnect()
		blockHoldWeightConnection = nil
	end
	local track = tracks.BlockHold
	if track and track.IsPlaying then
		track:Stop(BLOCK_HOLD_FADE_TIME)
	end
end

-- One-shot parry-deflect flash -- called from CombatClient.lua's Combat_BlockStarted handler only
-- when payload.ParryWindowOpened is true, i.e. only for presses the SERVER actually armed a parry
-- window for (Types.BlockStartedPayload). Deliberately never client-predicted from raw input like
-- PlayBlockHold is -- parry availability is cooldown-gated server-side state
-- (CombatSystem.lua's parryCooldownExpiry) the client has no other way to know in advance, so
-- guessing here would desync from the server's real parryWindowExpiry on any press still on
-- cooldown.
function CombatAnimator.PlayParryFlash(): ()
	local track = tracks.ParryFlash
	if not track then
		logger:debug("PlayParryFlash: no track loaded yet (ParryFlash has no asset id supplied)")
		return
	end
	track:Play(PARRY_FLASH_FADE_TIME, DOMINANT_WEIGHT)
end

-- Plays ANY one-shot dominant track by exact track name (a directional "DashFront/Back/Left/
-- Right", the distinct "DashPunch", or "Slide" -- see each id's own header in Constants.lua) with
-- a per-Heartbeat weight re-assert for as long as it keeps playing -- see DOMINANT_WEIGHT's
-- comment for why a single Play()-time weight isn't reliable for remote viewers. Joins
-- combatActionTrackCount (see that helper's own header) so the Running/Walking eligibility
-- evaluator silences the locomotion loop for the clip's whole duration and picks it back up on its
-- own the instant the clip's .Stopped fires -- no explicit interrupt/resume bookkeeping needed here
-- anymore. Merged from what used to be two byte-identical loop bodies (startDirectionalClip and
-- startSlideClip) differing only in which track/fade-time they played -- startDashClip and
-- startSlideClip below are now both thin wrappers over this one.
local function playDominantOneShot(trackName: string, fadeSeconds: number): AnimationTrack?
	local track = tracks[trackName]
	if not track then
		logger:debug("playDominantOneShot: no track loaded yet", { trackName = trackName })
		return nil
	end
	-- Stop whatever ELSE is currently playing before starting this one -- see
	-- currentDominantOneShotTrack's own header for why this cross-stop exists.
	if
		currentDominantOneShotTrack
		and currentDominantOneShotTrack ~= track
		and currentDominantOneShotTrack.IsPlaying
	then
		currentDominantOneShotTrack:Stop(ROLLBACK_FADE_TIME)
	end
	if currentSwingTrack and currentSwingTrack.IsPlaying then
		currentSwingTrack:Stop(ROLLBACK_FADE_TIME)
	end
	track:Play(fadeSeconds, DOMINANT_WEIGHT)
	currentDominantOneShotTrack = track
	trackExclusiveAction(track)
	-- Per-Heartbeat weight re-assert happens in the persistent Running/Walking evaluator above
	-- (see its own comment on currentDominantOneShotTrack), not a private coroutine spawned here --
	-- assigning currentDominantOneShotTrack just above is what that evaluator picks up.
	return track
end

-- Thin wrapper over playDominantOneShot for the four plain directional clips -- kept as its own
-- name since every non-DashPunch call site already thinks in terms of a direction, not a raw
-- track name.
local function startDashClip(direction: "Front" | "Back" | "Left" | "Right"): AnimationTrack?
	return playDominantOneShot("Dash" .. direction, DASH_FADE_TIME)
end

-- Plays the single "Slide" clip. Unlike startDashClip, no direction lookup -- Slide never steers
-- (see Movement.lua's own header on why), it always plays this one clip in whatever direction the
-- player was already sprinting.
local function startSlideClip(): AnimationTrack?
	local track = playDominantOneShot("Slide", SLIDE_FADE_TIME)
	if not track then
		return nil
	end
	-- Unlike Dash's four short directional steps (which happen to be about as long as the WalkSpeed
	-- burst they accompany), a real slide clip is very likely authored longer than
	-- SlideCommitmentSeconds -- there's nothing else here to bound its play length to the actual
	-- gameplay window, so left alone it just keeps playing (and keeps combatActionTrackCount
	-- elevated, silencing Walking/Running) for its own full authored Length long after the server-
	-- side slide has ended -- reads as "stuck sliding forever." Explicitly stop it once the real
	-- action window elapses, same "visual conforms to the authoritative real-time schedule" rule
	-- animation-systems.md's Core Principle already applies to swing/hitbox timing. Harmless no-op
	-- if the track already stopped on its own (a short-authored clip) or was already rolled back.
	task.delay(Constants.Combat.SlideCommitmentSeconds, function()
		if track.IsPlaying then
			track:Stop(SLIDE_FADE_TIME)
		end
	end)
	return track
end

-- The one predicted Slide awaiting server confirmation, or nil -- same one-pending-at-a-time
-- reasoning as predictedDash above (Slide also locks the shared attackEndsAt commitment, so a
-- second press can't land while one is already in flight).
local predictedSlide: { Track: AnimationTrack? }? = nil
registerPerLifeReset(function()
	predictedSlide = nil
end)

-- Plays the Slide clip immediately at press time off the client's prediction (PredictionMirror said
-- the press is legal -- which already required CombatClient's own local sprintKeyHeld to be true).
function CombatAnimator.PlayPredictedSlide(): ()
	predictedSlide = { Track = startSlideClip() }
end

-- Confirms a Slide from the server's Combat_SlidePerformed echo. Slide has no direction to
-- reconcile (unlike Dash) -- if a prediction is already playing, it's already correct and this is a
-- no-op; if the press wasn't predicted (e.g. gameProcessed swallowed the input), play it fresh.
function CombatAnimator.ConfirmSlide(): ()
	local pending = predictedSlide
	predictedSlide = nil
	if pending then
		return
	end
	startSlideClip()
end

-- Rolls back a predicted Slide the server rejected (Combat_ActionRejected) or never confirmed
-- (timeout).
function CombatAnimator.CancelPredictedSlide(): ()
	local pending = predictedSlide
	predictedSlide = nil
	if not pending or not pending.Track then
		return
	end
	pending.Track:Stop(ROLLBACK_FADE_TIME)
end

-- The one predicted Dash awaiting server confirmation, or nil. Only ever one pending -- same
-- commitment-gate reasoning as predictedSwing above. Direction is nil for a stationary press (no
-- clip playing) -- kept alongside Track (rather than just checking Track ~= nil) so ConfirmDash can
-- tell "predicted no clip" apart from "predicted a clip that failed to load." IsDashPunch tracks
-- WHICH clip a "Front" prediction actually played (the distinct DashPunch clip vs. the plain
-- DashFront one -- see PlayPredictedDash's own header) so ConfirmDash's reconciliation can tell
-- them apart too, not just their shared direction.
local predictedDash: {
	Track: AnimationTrack?,
	Direction: ("Front" | "Back" | "Left" | "Right")?,
	IsDashPunch: boolean,
}? =
	nil
registerPerLifeReset(function()
	predictedDash = nil
end)

-- Plays a Dash clip immediately at press time off the client's prediction (PredictionMirror said
-- the press is legal). viaDoubleTapForward is CombatClient's own record of whether THIS press came
-- from the double-tap-W trigger rather than the plain Dash keybind -- when true, this unconditionally
-- plays the distinct "DashPunch" clip (Constants.Combat.AnimationIds.DashPunch) at direction "Front",
-- instead of calling resolveDashDirection() and playing DashFront: double-tapping the FORWARD key is
-- itself unambiguous forward intent, and reading live Humanoid.MoveDirection synchronously inside
-- the very InputBegan handler that just detected the second W press races Roblox's own character
-- controller, which hasn't updated MoveDirection for that fresh key-down yet -- the controller's
-- per-frame poll runs after this handler, not before it. That race is what made the predicted (and
-- often the confirmed, on a fast/local connection) animation silently skip: this function would ask
-- resolveDashDirection() at the worst possible instant and get a stale/zero reading. Trusting the
-- gesture itself sidesteps the race instead of tolerating it. A non-punch Dash with no direction to
-- resolve (Q keybind, no movement key held) plays no clip at all: still records the pending
-- prediction (Track/Direction = nil) so ConfirmDash/CancelPredictedDash's own bookkeeping stays
-- correct.
function CombatAnimator.PlayPredictedDash(viaDoubleTapForward: boolean): ()
	if viaDoubleTapForward then
		logger:debug("PlayPredictedDash", { direction = "Front", isDashPunch = true })
		predictedDash =
			{ Track = playDominantOneShot("DashPunch", DASH_FADE_TIME), Direction = "Front", IsDashPunch = true }
		return
	end
	local direction = resolveDashDirection()
	if not direction then
		logger:debug("PlayPredictedDash: no movement held, skipping Dash animation")
		predictedDash = { Track = nil, Direction = nil, IsDashPunch = false }
		return
	end
	logger:debug("PlayPredictedDash", { direction = direction, isDashPunch = false })
	predictedDash = { Track = startDashClip(direction), Direction = direction, IsDashPunch = false }
end

-- Confirms (or corrects) a Dash from the server's Combat_MovementPerformed echo. durationSeconds
-- (Types.MovementPerformedPayload.DurationSeconds) is actually the COMMITMENT duration
-- (handleDashRequest sends commitmentSeconds, not the movement/WalkSpeed-burst duration, into this
-- field -- see that payload type's own header: "the attackEndsAt lock this action set"), and it
-- doubles as this event's own "was this specifically a DashPunch" signal: DashFrontCommitmentSeconds
-- (~0.77, derived from DashPunch's own windup+active+recovery) is the ONE commitment
-- handleDashRequest reports for a landed-or-not DashPunch throw, distinct from a plain dash's
-- DashCommitmentSeconds (0.28) and DashHit's DashHitCommitmentSeconds (0.32) -- see
-- PredictionMirror.OnMovementPerformed's identical use of this same signal. So this plays the
-- distinct "DashPunch" clip at direction "Front" in that case -- no live MoveDirection read, no
-- race, exactly like PlayPredictedDash's own double-tap-forward shortcut. Comparing against
-- DashFrontDurationSeconds instead (0.28) -- an earlier version of this check -- was a bug: that
-- constant coincidentally equals DashCommitmentSeconds (both 0.28), so it misfired "Front" on EVERY
-- plain dash (left/right/back, or a non-punch forward dash) instead of only a genuine DashPunch
-- throw, which is why every direction was playing the DashFront clip. Every other commitment value
-- (a plain dash, or a non-double-tap forward DashHit) falls back to resolveDashDirection() and the
-- plain DashFront/Back/Left/Right clip, which by confirm time (a full round trip after the press)
-- is no longer racing a just-pressed key the way a predict-time read would.
--
-- Reconciles against any pending prediction by DIRECTION *and* IsDashPunch, not just "was something
-- predicted":
--   * predicted the SAME direction and the SAME clip choice (including both nil) -> the clip (or
--     the deliberate lack of one) already matches; nothing to do.
--   * predicted a DIFFERENT direction, or the same "Front" direction but the wrong clip (e.g. a
--     mispredicted read, or DashPunch's own cooldown rejected between predict and confirm, falling
--     back to a plain forward dash) -> roll the wrong clip back and play the right one.
--   * no prediction pending (a not-predicted press, e.g. gameProcessed swallowed the input) -> play
--     it fresh.
function CombatAnimator.ConfirmDash(durationSeconds: number): ()
	local pending = predictedDash
	predictedDash = nil

	local isDashPunch = durationSeconds == Constants.Combat.DashFrontCommitmentSeconds
	local direction = if isDashPunch then "Front" else resolveDashDirection()

	if pending and pending.Direction == direction and pending.IsDashPunch == isDashPunch then
		-- Matched (including both nil): don't replay (would restart the clip mid-motion).
		return
	end

	if pending and pending.Track then
		-- Mispredicted direction/clip: fade the wrong one out and fall through to play the right one.
		pending.Track:Stop(ROLLBACK_FADE_TIME)
	end

	if not direction then
		logger:debug("ConfirmDash: no movement held, skipping Dash animation")
		return
	end

	logger:debug("ConfirmDash", { direction = direction, isDashPunch = isDashPunch, hadPrediction = pending ~= nil })
	if isDashPunch then
		playDominantOneShot("DashPunch", DASH_FADE_TIME)
	else
		startDashClip(direction)
	end
end

-- Rolls back a predicted Dash the server rejected (Combat_ActionRejected) or never confirmed
-- (timeout). Fades the clip -- the Running/Walking eligibility evaluator resumes on its own next
-- tick if the player is still moving, no explicit resume needed.
function CombatAnimator.CancelPredictedDash(): ()
	local pending = predictedDash
	predictedDash = nil
	if not pending or not pending.Track then
		return
	end
	logger:debug("CancelPredictedDash", { direction = pending.Direction })
	pending.Track:Stop(ROLLBACK_FADE_TIME)
end

-- Plays the DEFENDER's own hit-reaction for an unmitigated attack that just landed on them,
-- called from CombatClient.lua's Combat_FeedbackEvent handler with the attacker's
-- Types.CombatFeedbackPayload.AttackDebugName -- reuses Shared/CombatDebugNames.lua so Hit1/2/3
-- map onto the same Basic1/2/3 stage numbering PlaySwing already keys off of. An attack with no
-- Basic stage digit (a Finisher, DashPunch, or Heavy landing) falls back to the generic
-- "HitGeneric" flinch rather than the old silent no-op -- which is what fixed DashPunch victims
-- not reacting at all. HitGeneric is an empty-id slot until supplied (Constants.Combat.
-- AnimationIds), so the fallback is itself a safe no-op until then, but the PATH is wired.
function CombatAnimator.PlayHitReaction(debugName: string?): ()
	local trackName: string
	local stage = if debugName then CombatDebugNames.SwingStageFromDebugName(debugName) else nil
	if stage then
		trackName = "Hit" .. tostring(stage)
	else
		trackName = "HitGeneric"
	end

	local track = tracks[trackName]
	if not track then
		logger:debug("PlayHitReaction: no track loaded yet", { debugName = debugName, trackName = trackName })
		return
	end
	track:Play(HIT_REACTION_FADE_TIME, DOMINANT_WEIGHT)
end

-- Own generation counter for THIS file's own combat-track freezes (Client/FX/AnimationTrackUtil.
-- lua's FreezeGuard) -- deliberately a separate instance from FlightAnimator.lua's own guard, so an
-- unrelated flight-landing freeze can never supersede (or be superseded by) a combat hit-stop's
-- restore timing. See FreezeGuard's own header for why sharing one counter across unrelated track
-- families would be wrong.
local combatFreezeGuard = AnimationTrackUtil.NewFreezeGuard()

-- Momentarily freezes whichever of THIS client's combat tracks are playing right now (AdjustSpeed
-- to 0, restored after `seconds`) -- the animation half of HitStop's freeze-frame (HitStop.lua owns
-- duration selection + throttling; this owns the tracks). Purely local presentation: the frozen
-- pose replicates to other clients for free (the "impact hitch" remote viewers should see) and NO
-- server timing is touched -- see HitStop.lua / plan decision (d). AdjustSpeed (not Stop) holds the
-- current pose and cleanly resumes; the weight-reassert loops (Running/BlockHold/Dash) use
-- AdjustWeight, not Speed, so they don't fight this. Generation-guarding (a second freeze landing
-- before the first restored must extend the hold, not let the first's timer un-freeze
-- mid-second-freeze) now lives in FreezeGuard itself -- see that module's header for the mechanism.
function CombatAnimator.FreezeActiveCombatTrack(seconds: number): ()
	local allTracks: { AnimationTrack } = {}
	for _, track in pairs(tracks) do
		table.insert(allTracks, track)
	end
	combatFreezeGuard:FreezeTracks(allTracks, seconds)
end

return CombatAnimator
