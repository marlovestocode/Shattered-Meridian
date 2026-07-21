--!strict
--[[
	CombatSystem.lua

	Owns: combat state machine, request validation, lock-on/parry/posture resolution, and neutral-game
	movement (Sprint/Dash) (software-architecture.md; combat-philosophy.md for feel/balance intent).
	Health authority is Roblox's own `Humanoid.Health`/`Humanoid:TakeDamage` (so Humanoid.Died,
	ragdoll, and every other engine-level death behavior keep working) with `Humanoid.MaxHealth`
	pinned to Constants.Combat.MaxHealth on spawn; Posture has no Roblox-native equivalent, so this
	System tracks it as its own authoritative number per player. (Health and Posture are the game's
	only two vitals -- Stamina was removed; actions are gated by cooldowns + the attackEndsAt
	commitment lock + posture, not a stamina budget. See Constants.Combat's Vitals header.) Every
	request a client can send is intent only -- this module is the only place that ever mutates
	health, posture, or combat state, per engineering-standards.md's server-authoritative rule.

	Hit detection specifically is delegated to Server/Combat/HitboxResolver.lua: an accepted attack
	request (handleAttackRequest) selects a Types.HitboxAttackDefinition (Constants.Combat.Hitboxes,
	wrapped by comboIndex) and hands it to HitboxResolver.StartSwing, which owns the swept
	oriented-box sampling over the attack's windup/active/recovery timeline. This module never
	geometry-queries directly -- it only supplies HitboxResolver's callbacks (candidate roster via
	getSwingCandidates, per-overlap validation+resolution via onSwingHitCandidate) and drives its
	Update() from this System's own Heartbeat (onHeartbeat), so hit detection stays deterministic
	overlap queries end to end, never `.Touched`.

	Server/Combat/ siblings this module owns and drives (required only here, per
	software-architecture.md -- see each module's own header): HitboxResolver.lua (swing geometry),
	RagdollController.lua (finisher physics), HitResolution.lua (the pure classify/damage-math/
	finisher-variant/arc-LOS logic that used to be duplicated across the player/dummy/bot hit-
	resolution paths below), Movement.lua (Dash/Sprint resolution + the unified WalkSpeed
	priority resolver), and CombatTypes.lua (the CombatState/BotState/DummyState type declarations,
	shared among this file and the siblings above). ReplicatedStorage/Shared/RateLimiter.lua is a
	general per-player-per-second budget utility (also used by DevMenuSystem.lua) this module
	constructs three category instances of (attackRateLimiter/defensiveRateLimiter/
	utilityRateLimiter, declared just above combatStates below).

	Does not own: post-kill rewards -- AbsorbSystem/RewardSystem own what a confirmed kill grants
	(CombatSystem.OnPlayerKilled is the hook they listen to, not a call this module makes outward).
	Does not own Qi -- no System owns that resource yet (see ClientState.lua), so this System
	neither tracks nor sends it. Does not own art/ability behavior, bloodline power, or any combat
	balance beyond first-pass technical tunables -- see Constants.Combat.Hitboxes' header comment.

	Kill-confirmation double-fire guard: ApplyServerDamage/PvP hit resolution never confirms a kill
	directly. Both paths only ever call `humanoid:TakeDamage(...)`, and the ONLY place a kill is
	confirmed is the `Humanoid.Died` handler bound once per character in onCharacterAdded, gated by
	`state.deathConfirmed`. This means an environmental/non-combat death (fall, void) also runs
	confirmDeath (with no killer attribution) -- that's intentional: CombatSystem needs to know about
	every death to keep its own state (alive flag, lock-on references) consistent regardless of
	cause, per this file's "clean up state, don't leave stale references" mandate.

	Known integration gap: this repo's Rojo tree now syncs StarterPlayer.StarterCharacterScripts
	(default.project.json) with a deliberately empty `Health` script that suppresses Roblox's
	default health-regen insertion (see that file) -- if a place file predates this change and still
	has a legacy StarterCharacterScripts.Health baked in from Studio, the synced empty one replaces
	it on next Rojo sync, but this hasn't been runtime-verified in Studio in this environment.

	Logging (Logger.scope("CombatSystem"), Studio-only per Logger.lua): every request handler logs
	exactly one "received", then one "rejected: <reason>" or "accepted" line (logReceived/
	logRejected/logAccepted helpers) -- Studio Output shows a complete accept/reject trail for every
	combat remote without stepping through a debugger. Hit resolution logs target selection, block/
	parry detection, damage/posture numbers, posture breaks, and death confirmation at info level;
	sendVitals/sendFeedback log at trace level specifically because they're called from many sites
	including the passive-regen Heartbeat path, where debug/info would be too noisy even with the
	Logger's own rate limiting. None of this is gameplay logic -- removing every log call in this
	file would not change a single validation, damage number, or state transition.

	Training dummies (DummyState, dummyStates, CombatSystem.SpawnTrainingDummy): a second, much
	simpler kind of combat participant, additive to everything above -- combatStates/CombatState
	stay exactly Player-keyed and untouched. A dummy is a real hittable target (swings resolve
	against it through the same getSwingCandidates/onSwingHitCandidate path as a player, including
	arc/LOS/dedup, posture break, and death), not a static prop, but it never attacks, blocks, or
	parries, and "respawn" after death means destroy-and-recreate at the same spawn point (a dead
	Humanoid can't be revived in place -- see confirmDummyDeath). This System owns what a dummy IS
	once one exists; it does not decide who's allowed to create one -- see
	CombatSystem.SpawnTrainingDummy's own comment and DevMenuSystem.lua for the whitelist check
	that gates every call to it.

	Training bots (BotState, botStates, CombatSystem.SpawnTrainingBot/RequestBot*): a third kind of
	combat participant, also additive -- combatStates/CombatState stays untouched. Unlike a dummy, a
	bot actually fights: it has (almost) the full CombatState feature set (blocking, parry
	window/cooldown, combo, attack timing, stun, posture-break) mirrored into its own Model-keyed
	BotState, reusing the exact same Constants.Combat numbers and the same HitboxResolver engine a
	player's own attacks use, so combat against a bot times identically to combat against a real
	player. This System owns bot MECHANICS only (spawning, hit resolution either direction via
	resolveHitAgainstBot/resolveHitFromBotAgainstPlayer, vitals, facing) -- it has zero knowledge of
	presets, weights, or decision-making; that's entirely TrainingBotSystem.lua's job, which drives a
	bot purely through this System's public RequestBot*/GetBotState surface, the same "server owns
	truth" boundary every client already respects. A bot is a private sparring partner: owned by the
	player who spawned it (botsByOwner), it only ever targets that one player and vice versa. Bots do
	NOT auto-respawn here the way dummies do -- death fires CombatSystem.OnTrainingBotKilled and
	TrainingBotSystem.lua (which owns the preset/weight data needed to recreate one) decides
	whether/how to respawn.

	Neutral-game movement. Two verbs:

	* Dash (handleDashRequest -- the RequestDash remote / Dash key): a proactive positioning burst,
	  no i-frames, a low-stakes cooldown meant to be used often. A forward-resolved Dash reported as
	  a double-tap (CombatClient.lua's double-tap-W trigger) also throws its own DashPunch/DashHit
	  hitbox -- see handleDashRequest for the full split.
	* Sprint (handleSprintStart/handleSprintStop + state.sprinting): a held sustained-speed state,
	  bounded by combat state -- onHeartbeat only applies the sprint multiplier when the player isn't
	  blocking, mid-swing/commitment, stunned, or posture-broken.

	Neither costs a resource (Stamina is gone). All movement speeds are pure Humanoid.WalkSpeed
	multipliers resolved in onHeartbeat's single unified computation (Movement.ComputeDesiredWalkSpeed) --
	exactly like the hit-slow clip, which is the whole reason that computation is centralized rather
	than each effect scheduling its own restore: dash > hit-slow > sprint > base, one writer, no
	races. Nothing sends a direction to the server (the player's own movement input carries them),
	and each accepted Dash fires Combat_MovementPerformed for the animation/FX layer, the movement
	counterpart of Combat_AttackStarted.

	Jump + M1 (AirSlam, handleAirSlamRequest/throwAirSlam, Constants.Combat.AirSlam): a Basic-attack
	press made while airborne, at any time -- no M1 combo prerequisite -- throws this standalone slam
	instead of continuing the grounded M1 string, modeled on DashPunch/DashHit above (its own real
	cooldown, thrown via onSwingHitCandidate directly so it never touches basicComboLanded/
	basicAttackReadyAt). A clean hit always resolves with FinisherVariant = "Downslam"
	(HitResolution.ApplyFinisherPhysics), the same knockback/animation-resolution the M1 finisher's own
	airborne variant used to produce before this attack existed -- see HitResolution.
	SelectFinisherVariant's own header for why that path no longer produces Downslam itself.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local Logger = require(ReplicatedStorage.Shared.Logger)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local CombatTypes = require(script.Parent.Parent.Combat.CombatTypes)
local Movement = require(script.Parent.Parent.Combat.Movement)
local HitResolution = require(script.Parent.Parent.Combat.HitResolution)
local HitboxResolver = require(script.Parent.Parent.Combat.HitboxResolver)
local RagdollController = require(script.Parent.Parent.Combat.RagdollController)
local BotAnimator = require(script.Parent.Parent.Combat.BotAnimator)

local RemoteNames = Constants.Combat.RemoteNames

local logger = Logger.scope("CombatSystem")

local CombatSystem = {}

-- Fired (victim: Player, killer: Player?) once per confirmed death, after this System's own state
-- is already updated -- see the header's kill-confirmation section. `killer` is nil for a death
-- this System didn't attribute to a specific attacker (environmental, or ApplyServerDamage callers
-- that don't pass one).
CombatSystem.OnPlayerKilled = Instance.new("BindableEvent")

-- Fired (botModel: Model, ownerPlayer: Player, killerPlayer: Player?) once per confirmed training
-- bot death -- same shape/reasoning as OnPlayerKilled above. CombatSystem does not auto-respawn a
-- bot the way it does a training dummy; TrainingBotSystem.lua (which owns the preset/weight
-- bookkeeping this System doesn't have) decides whether/how to respawn.
CombatSystem.OnTrainingBotKilled = Instance.new("BindableEvent")

-- Fired (botModel: Model) from despawnBot, unconditionally, for every path a bot's model stops
-- being tracked -- cap eviction (SpawnTrainingBot), the explicit DespawnTrainingBot API, all of it.
-- Separate from OnTrainingBotKilled: that event means "this bot died" and TrainingBotSystem.lua
-- reacts to it by scheduling a RESPAWN, which is exactly wrong for a silent cap-eviction (it would
-- respawn the just-evicted bot, which would then immediately re-evict whatever took its slot).
-- TrainingBotSystem.lua subscribes to this one purely to drop its own botAIStates bookkeeping for
-- the despawned model -- without it, an evicted bot's AI-state entry is never cleaned up and is
-- iterated forever by the Heartbeat-driven decision loop.
CombatSystem.OnTrainingBotDespawned = Instance.new("BindableEvent")

-- Fired (deltaTime: number) at the end of every onHeartbeat tick below -- lets other server-internal
-- Systems (TrainingBotSystem's AI decision loop) piggyback on this System's single Heartbeat
-- connection instead of opening a second one, matching the reasoning HitboxResolver's own header
-- documents for why it doesn't open its own.
CombatSystem.OnHeartbeatTick = Instance.new("BindableEvent")

-- CombatState/DummyState/BotState live in Server/Combat/CombatTypes.lua, shared only among
-- CombatSystem.lua and its own Server/Combat/ siblings -- see that file's header. Aliased locally
-- so every existing signature in this file keeps reading as CombatState/DummyState/BotState.
-- Never returned directly to a caller -- GetCombatState below returns a read-only
-- Types.CombatSnapshot projection instead, per software-architecture.md's "no system reaches into
-- another system's internals directly."
type CombatState = CombatTypes.CombatState
type DummyState = CombatTypes.DummyState
type BotState = CombatTypes.BotState
type CombatActionKind = CombatTypes.CombatActionKind

local combatStates: { [Player]: CombatState } = {}

-- Three independent budgets (RateLimiter.lua) so a burst on one can never starve another, per
-- performance-optimization.md's "combat-critical remotes... take priority... over cosmetic/
-- UI-sync remotes." Attack (Basic + Heavy) gets its own, more generous budget
-- (Constants.NetworkBudget.MaxAttackCallsPerSecondPerPlayer -- see that field's own comment):
-- mashing/eager-double-clicking Attack must never be able to silently eat a defensive Dash/Block
-- press sharing the same bucket, which is exactly what one shared "combat-critical" budget used to
-- risk. Defensive: Dash, BlockStart (which also gates parry timing) -- reactive
-- actions that must stay reliably available regardless of how much the player is attacking.
-- Utility: LockOn, SprintStart, SwapWeapon -- positioning/loadout convenience, never
-- combat-decisive on their own. "Stop" actions (BlockStop, SprintStop) are deliberately never
-- passed through any instance -- see handleBlockStop's own comment for why a rate-limited release
-- action is a stuck-state bug, not a safe drop.
local attackRateLimiter = RateLimiter.New(Constants.NetworkBudget.MaxAttackCallsPerSecondPerPlayer)
local defensiveRateLimiter = RateLimiter.New(Constants.NetworkBudget.MaxRemoteCallsPerSecondPerPlayer)
local utilityRateLimiter = RateLimiter.New(Constants.NetworkBudget.MaxRemoteCallsPerSecondPerPlayer)

-- Reverse lookup for HitboxResolver's OnHit callback, which only ever hands back the overlapped
-- Model -- O(1) instead of scanning combatStates for whichever CombatState owns this character.
-- Kept in sync with combatStates[player].character in onCharacterAdded/onCharacterRemoving/
-- onPlayerRemoving; never read from anywhere the character reference could be stale.
local characterToPlayer: { [Model]: Player } = {}

-- A training dummy is a real hittable combat participant (swings resolve against it exactly like
-- a player -- arc/LOS/dedup all apply, posture break and death both work), just not a Player, so
-- it gets its own much simpler parallel state -- no parry/lock-on/combo, since it never
-- attacks, blocks, or parries. Deliberately NOT folded into combatStates/CombatState: that type
-- and every function keyed off `Player` stays exactly as-is (respawn-safe, rate-limited, etc.);
-- dummies are purely additive. Only DevMenuSystem.lua can create one, via SpawnTrainingDummy below.
-- Shape lives in CombatTypes.lua -- see the DummyState alias above.
local dummyStates: { [Model]: DummyState } = {}
-- Spawn order, oldest first -- lets SpawnTrainingDummy evict the oldest dummy once
-- Constants.Debug.TrainingDummy.MaxActive is reached, without needing a separate despawn action.
local dummySpawnOrder: { Model } = {}
local dummiesFolder: Folder? = nil

-- A training bot is a real combat participant that actually fights (see the file header) -- unlike
-- DummyState, it carries almost the full CombatState feature set, mirrored here rather than reusing
-- CombatState itself since that type and every function keyed off it stays exactly as-is (see the
-- header's "additive" reasoning). Deliberately no `lockOnTarget` field -- a bot only ever fights its
-- one owner, there's nothing to lock onto. `ownerPlayer` is who spawned it and the only Player it
-- will ever target or be targeted for. Shape lives in CombatTypes.lua -- see the BotState alias
-- above.
local botStates: { [Model]: BotState } = {}
-- Every bot a given player currently owns, in spawn order -- lets SpawnTrainingBot evict the
-- oldest once Constants.Debug.TrainingBot.MaxActivePerOwner is reached, and lets
-- getSwingCandidates/onHeartbeat find "this attacker's own bot(s)" in O(1) instead of scanning
-- every bot in the server.
local botsByOwner: { [Player]: { Model } } = {}
local botsFolder: Folder? = nil
-- Pending-spawn count per owner, incremented before the yielding
-- Players:CreateHumanoidModelFromDescription call in createTrainingBot and decremented after --
-- closes a TOCTOU race where two near-simultaneous SpawnTrainingBot calls for the same owner could
-- both read botsByOwner's pre-creation count and both pass the MaxActivePerOwner cap check before
-- either has appended its new model (engineering-standards.md: "never perform two conflicting
-- mutations... without going through a single serialized entry point"). See SpawnTrainingBot.
local pendingBotSpawns: { [Player]: number } = {}

-- Remotes, created once in Init() (NetworkBridge.CreateRemoteEvent), then reused by every handler
-- below. Never instanced anywhere else -- luau-coding-standards.md's networking convention.
local requestBasicAttackRemote: RemoteEvent
local requestHeavyAttackRemote: RemoteEvent
local requestBlockStartRemote: RemoteEvent
local requestBlockStopRemote: RemoteEvent
local requestDashRemote: RemoteEvent
local requestSlideRemote: RemoteEvent
local requestSprintStartRemote: RemoteEvent
local requestSprintStopRemote: RemoteEvent
local requestLockOnRemote: RemoteEvent
local requestSwapWeaponRemote: RemoteEvent
local requestFeintRemote: RemoteEvent
local requestAirTechRemote: RemoteEvent
local vitalsUpdatedRemote: RemoteEvent
local inCombatChangedRemote: RemoteEvent
local feedbackEventRemote: RemoteEvent
local lockOnChangedRemote: RemoteEvent
local attackStartedRemote: RemoteEvent
local blockStartedRemote: RemoteEvent
local movementPerformedRemote: RemoteEvent
local slidePerformedRemote: RemoteEvent
local comboStateChangedRemote: RemoteEvent
local weaponChangedRemote: RemoteEvent
local actionRejectedRemote: RemoteEvent
local parryWindowOpenedRemote: RemoteEvent
local feintPerformedRemote: RemoteEvent

--
-- Request logging helpers -- every handleX function below logs exactly one "received" line, then
-- exactly one "rejected: <reason>" or "accepted" line per request, so Studio Output shows a
-- complete accept/reject trail for every combat remote firing without hunting through each
-- handler's control flow.
--

local function logReceived(action: string, player: Player, extra: { [string]: unknown }?): ()
	local fields: { [string]: unknown } = { player = player.Name, userId = player.UserId, action = action }
	if extra then
		for key, value in pairs(extra) do
			fields[key] = value
		end
	end
	logger:debug("Request received", fields)
end

local function logRejected(action: string, player: Player, reason: string, extra: { [string]: unknown }?): ()
	local fields: { [string]: unknown } =
		{ player = player.Name, userId = player.UserId, action = action, reason = reason }
	if extra then
		for key, value in pairs(extra) do
			fields[key] = value
		end
	end
	logger:debug("Request rejected", fields)
end

local function logAccepted(action: string, player: Player, extra: { [string]: unknown }?): ()
	local fields: { [string]: unknown } = { player = player.Name, userId = player.UserId, action = action }
	if extra then
		for key, value in pairs(extra) do
			fields[key] = value
		end
	end
	logger:debug("Request accepted", fields)
end

-- logRejected + the Combat_ActionRejected rollback echo, fused: for the four actions the client
-- predicts action-start feedback for (Basic/Heavy/Dash/BlockStart -- Constants.Combat.Prediction),
-- a genuine reject must also tell the acting client to roll that feedback back immediately instead
-- of waiting out the prediction timeout. Only handleAttackRequest/handleBlockStart/
-- handleDashRequest use this; every other handler keeps plain logRejected (the client never
-- predicts those actions). Two deliberate exclusions, both still plain logRejected:
--   * the too-early-but-BUFFERED attack pseudo-reject -- that press is still going to throw (and
--     confirm via AttackStarted) when the buffer flushes, so a rollback signal for it would be a lie;
--   * reason == "RateLimited" -- the limiter drops requests ABOVE budget, so echoing those would let
--     a spamming client generate unbounded server->client traffic; every other reason only fires
--     for requests that already passed the limiter, keeping this remote's rate bounded by the
--     client->server budgets (NetworkBudget). A legit press eaten by this exclusion still rolls
--     back via the prediction timeout.
local function rejectAndNotify(
	action: string,
	rejectedKind: Types.RejectedActionKind,
	player: Player,
	reason: string,
	extra: { [string]: unknown }?
): ()
	logRejected(action, player, reason, extra)
	if reason == "RateLimited" then
		return
	end
	local payload: Types.ActionRejectedPayload = { Action = rejectedKind, Reason = reason }
	actionRejectedRemote:FireClient(player, payload)
end

--
-- Vitals / feedback senders
--

local function buildVitalsPayload(state: CombatState): Types.CombatVitalsPayload
	local health = if state.humanoid then state.humanoid.Health else 0
	return {
		Health = health,
		MaxHealth = state.maxHealth,
		Posture = state.posture,
		MaxPosture = state.maxPosture,
	}
end

local function sendVitals(player: Player, state: CombatState): ()
	state.lastVitalsSyncTime = os.clock()
	local payload = buildVitalsPayload(state)
	vitalsUpdatedRemote:FireClient(player, payload)
	-- Trace, not debug: this fires on every regen tick that changes a value, not just on hits --
	-- see this file's header note on why sendVitals/sendFeedback log at trace level.
	logger:trace("Vitals sent", {
		player = player.Name,
		health = payload.Health,
		posture = payload.Posture,
	})
end

local function sendFeedback(player: Player, payload: Types.CombatFeedbackPayload): ()
	feedbackEventRemote:FireClient(player, payload)
	logger:trace("Feedback sent", { player = player.Name, kind = payload.Kind })
end

local function buildFeedbackPayload(
	kind: Types.CombatFeedbackKind,
	attackerPlayer: Player?,
	targetPlayer: Player?,
	damageAmount: number?,
	postureAmount: number?,
	isHeavy: boolean?,
	targetPosition: Vector3?,
	attackDebugName: string?
): Types.CombatFeedbackPayload
	return {
		Kind = kind,
		AttackerUserId = if attackerPlayer then attackerPlayer.UserId else nil,
		TargetUserId = if targetPlayer then targetPlayer.UserId else nil,
		TargetPosition = targetPosition,
		DamageAmount = damageAmount,
		PostureAmount = postureAmount,
		IsHeavy = isHeavy,
		AttackDebugName = attackDebugName,
	}
end

local function sendLockOnChanged(player: Player, targetUserId: number?): ()
	lockOnChangedRemote:FireClient(player, targetUserId)
end

-- Fired only after handleAttackRequest has fully accepted a throw (validated, cooldown/attackEndsAt
-- committed) -- see Types.AttackStartedPayload's header for why this exists and what it isn't for.
local function sendAttackStarted(
	player: Player,
	definition: Types.HitboxAttackDefinition,
	isHeavy: boolean,
	weaponId: Types.WeaponId,
	finisherVariant: Types.FinisherVariant?
): ()
	local payload: Types.AttackStartedPayload = {
		IsHeavy = isHeavy,
		DebugName = definition.DebugName,
		WindupSeconds = definition.WindupSeconds,
		ActiveSeconds = definition.ActiveSeconds,
		RecoverySeconds = definition.RecoverySeconds,
		CooldownSeconds = definition.Cooldown,
		WeaponId = weaponId,
		FinisherVariant = finisherVariant,
	}
	attackStartedRemote:FireClient(player, payload)
end

-- Fired only after handleBlockStart has fully accepted a BlockStart request -- the block
-- counterpart of sendAttackStarted -- see Types.BlockStartedPayload's header for why this exists
-- and what it isn't for (no gameplay/hit decision, purely an animation/FX timing hook).
local function sendBlockStarted(player: Player, parryWindowOpened: boolean): ()
	local payload: Types.BlockStartedPayload = {
		ParryWindowOpened = parryWindowOpened,
		ParryWindowSeconds = Constants.Combat.ParryWindowSeconds,
	}
	blockStartedRemote:FireClient(player, payload)
end

-- BROADCAST (to every client, not just the blocker) that `character`'s parry window just opened, so
-- each client can show the parry-window tell (a bright highlight) on that combatant -- the "obvious,
-- synced-for-all" tell. Works for a player OR a bot (both are replicated Workspace Models); the
-- highlight is client-adorned so it doesn't depend on the actor's own Animator weight winning on
-- remote viewers the way the block STANCE animation does. Not consumed for any gameplay decision --
-- a purely presentational broadcast, same "presentation, not outcome" contract as the FX layer.
local function broadcastParryWindowOpened(character: Model): ()
	parryWindowOpenedRemote:FireAllClients(character)
	logger:trace("Parry window broadcast", { character = character.Name })
end

-- Fired only after a Dash has been fully accepted (validated, cooldown/commitment committed). The
-- movement counterpart of sendAttackStarted -- see Types.MovementPerformedPayload's header for why
-- it exists and what it isn't for (no gameplay decision, no direction; the animation/FX layer's
-- timing hook only).
local function sendMovementPerformed(player: Player, durationSeconds: number, cooldownSeconds: number?): ()
	local payload: Types.MovementPerformedPayload = {
		DurationSeconds = durationSeconds,
		CooldownSeconds = cooldownSeconds,
	}
	movementPerformedRemote:FireClient(player, payload)
end

-- Fired only after a Slide has been fully accepted -- the Slide counterpart of
-- sendMovementPerformed, kept as its own payload/remote rather than a third overload of
-- MovementPerformedPayload; see Types.SlidePerformedPayload's own header for why.
local function sendSlidePerformed(player: Player, durationSeconds: number): ()
	local payload: Types.SlidePerformedPayload = {
		DurationSeconds = durationSeconds,
	}
	slidePerformedRemote:FireClient(player, payload)
end

-- Fired only after a weapon swap has been fully accepted (validated, cooldown/commitment committed,
-- equippedWeaponId toggled) -- the weapon-switching counterpart of sendMovementPerformed, same
-- "fire on transition" shape as syncFinisherReady below.
local function sendWeaponChanged(player: Player, weaponId: Types.WeaponId): ()
	weaponChangedRemote:FireClient(player, weaponId)
end

-- Fired only after a Feint has been fully accepted (still inside the swing's WindupSeconds,
-- swingCancelled set, attackEndsAt shortened) -- the Feint counterpart of sendMovementPerformed/
-- sendSlidePerformed. recoverySeconds is the new (shorter) commitment the feint replaced the
-- swing's own remaining windup+active+recovery with, echoed so PredictionMirror.OnFeintPerformed
-- can collapse its own mirrored attackEndsAt to the same value -- see handleFeintRequest.
local function sendFeintPerformed(player: Player, recoverySeconds: number): ()
	local payload: Types.FeintPerformedPayload = {
		RecoverySeconds = recoverySeconds,
	}
	feintPerformedRemote:FireClient(player, payload)
end

-- Fires Combat_ComboStateChanged to the player only when the M1 combo's finisher-ready state actually
-- flips (compared against state.finisherReadySynced), so the client can suppress its jump on the 4th
-- hit without a per-tick remote. Called every tick from onHeartbeat -- which is also where the combo
-- lapse is detected -- so both the "ready" (3rd hit landed) and "unready" (finisher thrown, lapsed,
-- or reset) edges reach the client within a tick of the server-authoritative change.
local function syncFinisherReady(player: Player, state: CombatState): ()
	local isReady = state.basicComboLanded >= Constants.Combat.BasicComboLength - 1
	if isReady == state.finisherReadySynced then
		return
	end
	state.finisherReadySynced = isReady
	local payload: Types.ComboStatePayload = { FinisherReady = isReady }
	comboStateChangedRemote:FireClient(player, payload)
	logger:debug("Combo state synced", { player = player.Name, finisherReady = isReady })
end

-- Writes the "RootControlLocked" Humanoid Attribute only on a transition (same shape as
-- syncFinisherReady above, an Attribute instead of a remote -- see CombatState.
-- rootControlLockedSynced's own header for why). True while this player's own rootPart CFrame is
-- currently being driven authoritatively by the server, not by their own client: a finisher/
-- DashPunch ragdoll tumbling their body (ragdollExpiry), or RagdollController.HoldAloft's rigid
-- AlignOrientation/AlignPosition pin on them as the air-combo attacker (airComboChaseExpiry) --
-- the exact same two conditions Movement.ComputeDesiredWalkSpeed already treats as "don't let this
-- player's own local input compete with the server," just surfaced to the client's presentation
-- layer too instead of only silencing WalkSpeed.
local function syncRootControlLocked(player: Player, state: CombatState, now: number): ()
	if not state.humanoid then
		return
	end
	local locked = now < state.ragdollExpiry or now < state.airComboChaseExpiry
	if locked == state.rootControlLockedSynced then
		return
	end
	state.rootControlLockedSynced = locked
	state.humanoid:SetAttribute(Constants.Attributes.RootControlLocked, locked)
	logger:debug("Root control lock synced", { player = player.Name, locked = locked })
end

-- Fires Combat_InCombatChanged only on a true/false transition (same shape as syncFinisherReady
-- above) -- the first real consumer of CombatState.inCombatUntil (see that field's own header):
-- drives the HUD's combat-state badge (Components/CombatStateBadge.lua). Purely a presentation
-- signal -- no request handler reads inCombatUntil, so this sync has no gameplay side effect.
local function syncInCombat(player: Player, state: CombatState, now: number): ()
	local isInCombat = now < state.inCombatUntil
	if isInCombat == state.inCombatSynced then
		return
	end
	state.inCombatSynced = isInCombat
	local payload: Types.InCombatPayload = { InCombat = isInCombat }
	inCombatChangedRemote:FireClient(player, payload)
	logger:debug("In-combat state synced", { player = player.Name, inCombat = isInCombat })
end

-- Anyone who currently has `targetPlayer` locked on loses that lock -- called when the target
-- leaves or dies, so no client is ever left tracking a lock-on target that no longer exists.
local function clearLockOnReferencesTo(targetPlayer: Player): ()
	for player, state in pairs(combatStates) do
		if state.lockOnTarget == targetPlayer then
			state.lockOnTarget = nil
			sendLockOnChanged(player, nil)
		end
	end
end

--
-- Targeting: server-computed, never client-supplied as damage proof
-- (engineering-standards.md/task brief: "never accept a client-provided target as authoritative
-- damage proof").
--

local function isValidHostileTarget(attackerState: CombatState, candidateState: CombatState): boolean
	if candidateState.player == attackerState.player then
		return false
	end
	if not candidateState.alive then
		return false
	end
	if not candidateState.humanoid or candidateState.humanoid.Health <= 0 then
		return false
	end
	if not candidateState.rootPart then
		return false
	end
	return true
end

-- Arc/line-of-sight geometry (isWithinAttackArc/hasLineOfSight) relocated to
-- Server/Combat/HitResolution.lua (HitResolution.IsSwingTargetValid) -- see that module's header.
-- Still called from onSwingHitCandidate/onBotSwingHitCandidate below, the only callers.

-- The hitbox swing's candidate roster: every other alive, hostile, fully-bound combat character
-- (players and training dummies alike), ordered so a still-legal lock-on target comes first
-- (HitboxResolver.MaxTargets can cap a swing below "everyone the box touches", so priority order
-- decides who gets the remaining slots), then the rest nearest-first -- dummies have no lock-on
-- concept (attackerState.lockOnTarget only ever references a Player), so they're always sorted in
-- with the "others" by distance, never prioritized. Recomputed fresh on every hitbox sample (see
-- startAttackSwing) so deaths/leaves/new lock-on state/dummy despawns mid-swing are always
-- reflected -- never trusted or cached across samples.
--
-- Nearby PLAYERS are found via a spatial query (Workspace:GetPartBoundsInRadius, bounded by
-- Constants.Combat.Hitboxes.MaxCandidateRadius) rather than scanning every player on the server --
-- a manual `pairs(combatStates)` scan here was exactly the unbounded cost
-- performance-optimization.md warns against (O(total server players) per sample, per
-- concurrently-attacking combatant, up to MaxSamplesPerSwing times per swing at 30Hz -- growing
-- with total player count even for a 1v1 duel in the corner of a crowded server). This mirrors
-- HitboxResolver.performSample's own overlap-query pattern one step later in the pipeline, so cost
-- now scales with local combat density instead. The locked-on target is fetched directly by key
-- instead of through the radius query, so it's never distance-filtered -- preserves the prior
-- behavior that an already-acquired lock-on target is always offered regardless of range.
-- Dummies (small, dev-only, MaxActive-capped) and the attacker's own bot(s) (O(1) via
-- botsByOwner) are cheap enough to keep scanning directly; neither was ever the scalability
-- concern this addresses.
local function getSwingCandidates(attackerState: CombatState): { Model }
	local attackerRoot = attackerState.rootPart
	local attackerCharacter = attackerState.character
	if not attackerRoot or not attackerCharacter then
		return {}
	end
	local origin = attackerRoot.Position

	local lockedModel: Model? = nil
	local others: { { Model: Model, Distance: number } } = {}

	local lockOnTarget = attackerState.lockOnTarget
	if lockOnTarget then
		local lockedState = combatStates[lockOnTarget]
		if
			lockedState
			and isValidHostileTarget(attackerState, lockedState)
			and lockedState.character
			and lockedState.rootPart
		then
			lockedModel = lockedState.character
		end
	end

	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = { attackerCharacter }

	local nearbyParts =
		Workspace:GetPartBoundsInRadius(origin, Constants.Combat.Hitboxes.MaxCandidateRadius, overlapParams)

	-- Every character has exactly one part named "HumanoidRootPart" -- filtering to just that name
	-- (rather than considering every limb/accessory part the radius query returns) means each
	-- nearby character is only ever classified/deduped once, same assumption onCharacterAdded/
	-- createTrainingDummy/createTrainingBot already make when they locate this part by name.
	local consideredPlayers: { [Player]: boolean } = {}
	for _, part in ipairs(nearbyParts) do
		if part.Name ~= "HumanoidRootPart" then
			continue
		end
		local model = part:FindFirstAncestorOfClass("Model")
		if not model then
			continue
		end
		local candidatePlayer = characterToPlayer[model]
		if not candidatePlayer or candidatePlayer == attackerState.player or candidatePlayer == lockOnTarget then
			continue
		end
		if consideredPlayers[candidatePlayer] then
			continue
		end
		consideredPlayers[candidatePlayer] = true

		local candidateState = combatStates[candidatePlayer]
		if not candidateState or not isValidHostileTarget(attackerState, candidateState) then
			continue
		end
		local character = candidateState.character
		local root = candidateState.rootPart
		if not character or not root then
			continue
		end

		table.insert(others, { Model = character, Distance = (root.Position - origin).Magnitude })
	end

	for dummyModel, dummyState in pairs(dummyStates) do
		if not dummyState.alive then
			continue
		end
		table.insert(others, { Model = dummyModel, Distance = (dummyState.rootPart.Position - origin).Magnitude })
	end

	-- Only the attacker's OWN bot(s) -- a bot is a private sparring partner (see the file header),
	-- never a hostile target for any other player.
	local ownedBots = botsByOwner[attackerState.player]
	if ownedBots then
		for _, botModel in ipairs(ownedBots) do
			local botState = botStates[botModel]
			if botState and botState.alive then
				table.insert(others, { Model = botModel, Distance = (botState.rootPart.Position - origin).Magnitude })
			end
		end
	end

	table.sort(others, function(a, b)
		return a.Distance < b.Distance
	end)

	local ordered: { Model } = {}
	if lockedModel then
		table.insert(ordered, lockedModel)
	end
	for _, entry in ipairs(others) do
		table.insert(ordered, entry.Model)
	end
	return ordered
end

-- Selects which combo-stage definition a throw uses, wrapping comboIndex over however many stages
-- are authored for this category under the equipped weapon's own Constants.Combat.Weapons[
-- weaponId].Stages -- adding a stage there is a data-only change, this never needs to change.
local function selectAttackDefinition(
	weaponId: Types.WeaponId,
	isHeavy: boolean,
	comboIndex: number
): Types.HitboxAttackDefinition
	local weapon = if weaponId == "Primary"
		then Constants.Combat.Weapons.Primary
		else Constants.Combat.Weapons.Secondary
	local stages = if isHeavy then weapon.Stages.Heavy else weapon.Stages.Basic
	assert(#stages > 0, "CombatSystem: no hitbox stages configured for this attack category")
	local stageIndex = ((comboIndex - 1) % #stages) + 1
	return stages[stageIndex]
end

-- Combo-lapse-reset: shared shape for the throw-based (Heavy) combo counter, used identically by a
-- real player's handleAttackRequest and a bot's RequestBotAttack -- both read comboIndex/comboExpiry
-- the same way (CombatState and BotState both have these two fields with the same meaning).
local function resetHeavyComboIfLapsed(state: { comboIndex: number, comboExpiry: number }, now: number): ()
	if now > state.comboExpiry then
		state.comboIndex = 0
	end
end

-- Combo-lapse-reset for the landing-based Basic (M1) combo -- CombatState-only, unlike
-- resetHeavyComboIfLapsed above (BotState has no basicComboLanded field: bots never throw the M1
-- finisher, see BotState's own comment). Always zeroes basicComboExpiry too, matching onHeartbeat's
-- proactive reset -- harmless from handleAttackRequest's own lapse check, which always reassigns
-- basicComboExpiry immediately afterward regardless of this helper's outcome.
local function resetBasicComboIfLapsed(state: CombatState, now: number): ()
	if now > state.basicComboExpiry then
		state.basicComboLanded = 0
		state.basicComboExpiry = 0
	end
end

--
-- Posture break / death
--

-- Shared posture-break trigger, unifying triggerPostureBreak/triggerDummyPostureBreak/
-- triggerBotPostureBreak (player/dummy/bot targets, defined just below and further down this file)
-- into one place. All three used to independently re-implement the exact same skeleton: bail if
-- the target's already dead (the killing blow that dropped posture to 0 already ran the death path
-- synchronously -- Humanoid.Died fires inside TakeDamage -- so a stale, contradictory PostureBreak
-- for a target whoever's watching was just told is dead must never go out; every caller already
-- checked "posture <= 0 and not wasPostureBroken" before calling in, so this is the one shared place
-- that additionally needs "and the target is still alive"), call HitResolution.ApplyPostureBreak,
-- log one line, and dispatch feedback. `target` only needs posture/postureBrokenExpiry --
-- ApplyPostureBreak already accepts CombatState/DummyState/BotState interchangeably via that same
-- duck-typed shape, so this reuses the exact same trick rather than inventing a new one.
--
-- What's genuinely different per participant type stays the caller's job, passed in as two
-- closures: `clearBlocking` (CombatState/BotState both have a `blocking` flag to drop the same way
-- a finisher launch does; DummyState has none at all -- a dummy never blocks -- so its wrapper below
-- passes a no-op) and `sendFeedbackFor` (a real player target always gets notified plus the
-- attacker if there is one; a dummy/bot target has no client of its own, so only the attacker, if
-- any, is notified, with a world position standing in for a target identity).
local function triggerPostureBreakShared(
	target: { posture: number, postureBrokenExpiry: number },
	humanoid: Humanoid?,
	attackerPlayer: Player?,
	logMessage: string,
	logFields: { [string]: any },
	clearBlocking: () -> (),
	sendFeedbackFor: (attackerPlayer: Player?) -> ()
): ()
	if humanoid and humanoid.Health <= 0 then
		return
	end
	HitResolution.ApplyPostureBreak(target)
	clearBlocking()

	logFields.attacker = if attackerPlayer then attackerPlayer.Name else "none"
	logger:info(logMessage, logFields)

	sendFeedbackFor(attackerPlayer)
end

-- attackerPlayer is who caused the break, if any (nil for ApplyServerDamage callers that don't
-- attribute one) -- forwarded into the feedback payload so both sides get the "exposed" signal.
local function triggerPostureBreak(targetPlayer: Player, targetState: CombatState, attackerPlayer: Player?): ()
	triggerPostureBreakShared(
		targetState,
		targetState.humanoid,
		attackerPlayer,
		"Posture break triggered",
		{ target = targetPlayer.Name, duration = Constants.Combat.PostureBreakDuration },
		function()
			targetState.blocking = false
		end,
		function(attacker: Player?)
			local payload = buildFeedbackPayload("PostureBreak", attacker, targetPlayer, nil, nil, nil)
			sendFeedback(targetPlayer, payload)
			if attacker then
				sendFeedback(attacker, payload)
			end
		end
	)
end

-- Ends a successfully-teched suspended exchange (CombatState.airComboSuspendedUntil/
-- airComboSuspendedWithAttacker -- see handleAirTechRequest's own header for how this state is
-- entered) and drops BOTH bodies back to normal footing. Reuses RagdollController.ClearHold on each
-- rootPart -- the same call the ordinary MaxHits-slam end-of-sequence path already uses, which
-- already reverses HoldAloft's live-body treatment (exitRigidHold) and restores network ownership,
-- so nothing new is needed here beyond zeroing the CombatState bookkeeping. Called from three
-- places: a resolved counter-punch (handleSuspendedCounterPunchRequest), a normal hit landing on the
-- still-suspended victim (resolveHitAgainstTarget), and either side's death/removal or the window
-- simply timing out unresolved (onHeartbeat/confirmDeath). `attackerState` is nil-safe -- the
-- attacker may have already left/died.
local function endSuspendedAirComboExchange(
	victimPlayer: Player,
	victimState: CombatState,
	attackerPlayer: Player?,
	attackerState: CombatState?
): ()
	if victimState.rootPart then
		RagdollController.ClearHold(victimState.rootPart, victimPlayer)
	end
	if attackerState and attackerState.rootPart then
		RagdollController.ClearHold(attackerState.rootPart, attackerPlayer)
	end
	victimState.airComboSuspendedUntil = 0
	victimState.airComboSuspendedWithAttacker = nil
	if attackerState then
		attackerState.airComboChaseExpiry = 0
	end
end

-- Reverse-scan cleanup for the OTHER direction: if the ATTACKER half of a suspended exchange dies or
-- leaves, the still-suspended VICTIM has no attacker left to resolve against and must be dropped too
-- -- same "never leave a player permanently pinned because the other half of an interaction vanished"
-- reasoning clearLockOnReferencesTo already applies to lock-on.
local function clearSuspendedReferencesTo(goneAttackerPlayer: Player): ()
	for victimPlayer, victimState in pairs(combatStates) do
		if victimState.airComboSuspendedWithAttacker == goneAttackerPlayer then
			endSuspendedAirComboExchange(victimPlayer, victimState, nil, nil)
		end
	end
end

local function confirmDeath(player: Player, state: CombatState): ()
	if state.deathConfirmed then
		return
	end
	state.deathConfirmed = true
	state.alive = false
	state.blocking = false
	state.sprinting = false
	state.dashWindowExpiry = 0
	state.slideWindowExpiry = 0
	state.ragdollExpiry = 0
	state.basicComboLanded = 0
	state.basicComboExpiry = 0
	state.finisherReadySynced = false
	state.rootControlLockedSynced = false
	state.inCombatSynced = false
	-- Deliberately does NOT RagdollController.Recover here: a body killed mid-ragdoll should stay
	-- limp for Roblox's own death handling rather than snap upright. The active ragdoll is cleared in
	-- onCharacterRemoving (before the corpse is replaced) or by RagdollController.Update's timer.
	-- A SUSPENDED death is different -- that body was never limp-ragdolled (it's rigid-held, see
	-- handleAirTechRequest), so dying mid-suspension should drop it normally rather than leave a
	-- corpse floating in an AlignPosition forever.
	if state.airComboSuspendedUntil ~= 0 then
		local suspendedWithPlayer = state.airComboSuspendedWithAttacker
		local suspendedWithState = if suspendedWithPlayer then combatStates[suspendedWithPlayer] else nil
		endSuspendedAirComboExchange(player, state, suspendedWithPlayer, suspendedWithState)
	end

	local killerUserId = state.pendingKillerUserId
	state.pendingKillerUserId = nil

	local killerPlayer: Player? = nil
	if killerUserId then
		killerPlayer = Players:GetPlayerByUserId(killerUserId)
	end

	logger:info("Death confirmed", {
		player = player.Name,
		killer = if killerPlayer then killerPlayer.Name else "none (environmental/other)",
	})

	clearLockOnReferencesTo(player)
	clearSuspendedReferencesTo(player)

	local payload = buildFeedbackPayload("Death", killerPlayer, player, nil, nil, nil)
	sendFeedback(player, payload)
	if killerPlayer then
		sendFeedback(killerPlayer, payload)
	end

	CombatSystem.OnPlayerKilled:Fire(player, killerPlayer)
end

--
-- Hit resolution -- the pure classify/damage-math/finisher logic that used to be duplicated across
-- the four functions below lives in Server/Combat/HitResolution.lua now (ClassifyDefense/
-- ComputeOutcome/ApplyFinisherPhysics/ApplyPostureBreak) -- see that module's header. Each function
-- here still owns its own state mutation and feedback/vitals dispatch, since those genuinely
-- differ per attacker/target combatant-type pairing (who has a client to send feedback to, who can
-- be launched by a finisher) and are tightly coupled to this System's own
-- private remote infrastructure.
--

-- Air combo (Constants.Combat.AirCombo, CombatState.airComboTarget/airComboDummyTarget/
-- airComboHitCount/airComboExpiry -- see those fields' own headers). Called from
-- resolveHitAgainstTarget/resolveHitAgainstDummy for any unmitigated (non-Block) Basic-category hit
-- against a real player or training-dummy target -- never for Heavy or the M1 finisher, see each
-- call site's own gate. Two shapes:
--   - debugName == "DashPunch": STARTS a new sequence. Launches the target (ragdolled, via the same
--     RagdollController.LaunchAndRagdoll a finisher uses) and holds the attacker's own body (NOT
--     ragdolled -- RagdollController.HoldAloft) at a fixed standoff point near them so they end up
--     together.
--   - Any other Basic hit landing on the attacker's OWN tracked air-combo target, while
--     airComboExpiry hasn't lapsed: CONTINUES the sequence (re-launches the target, refreshes the
--     window) or, once airComboHitCount reaches Constants.Combat.AirCombo.MaxHits, ENDS it with a
--     ground slam + bonus damage instead of a re-launch.
--
-- Unified across a real player target and a training-dummy target (used to be two separate ~150-
-- line functions, applyAirCombo/applyAirComboAgainstDummy, differing only in target shape) --
-- every genuine difference between the two is captured once in the `target: AirComboTarget` adapter
-- built by each call site below:
--   - `player` is nil for a dummy (RagdollController's own calls already accept a nil Player for a
--     non-player body -- this just threads that through instead of duplicating each call twice).
--   - `clearBlocking`/`setAsAirComboTarget`/`clearAirComboTarget`/`isCurrentAirComboTarget` hide
--     which underlying field gets touched -- CombatState.blocking/airComboTarget for a player vs. a
--     no-op/CombatState.airComboDummyTarget for a dummy (DummyState itself has no `blocking` field
--     at all -- a dummy never blocks).
--   - `setRagdollExpiry` hides which timer field gets pinned and how -- CombatState.ragdollExpiry
--     via math.max (never SHORTENS an existing lockout) for a player, DummyState.ragdollResetAt via
--     a flat overwrite plus Constants.Debug.TrainingDummy.LaunchResetBufferSeconds for a dummy (a
--     dummy has no lockout to preserve, just a respawn timer, and needs the extra buffer so you see
--     it get up before it resets -- same reasoning resolveHitAgainstDummy's own finisher block
--     already uses).
--   - `applyDamage` hides the slam-finisher's bonus-damage application -- godmode check +
--     kill-attribution + sendVitals for a player, a plain TakeDamage for a dummy (no godmode
--     concept, no vitals stream to sync).
-- Player-vs-dummy is still the only two shapes this covers -- a hit against a bot target never
-- reaches this function at all (resolveHitAgainstBot doesn't call it; bots never dash so can never
-- be the ATTACKER side of an air combo either, per CombatState.airComboTarget's own header).
type AirComboTarget = {
	model: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	-- nil for a dummy (no client of its own) -- forwarded straight into the RagdollController calls
	-- below, which already accept a nil Player for exactly this case.
	player: Player?,
	clearBlocking: () -> (),
	setRagdollExpiry: (number) -> (),
	isCurrentAirComboTarget: () -> boolean,
	setAsAirComboTarget: () -> (),
	clearAirComboTarget: () -> (),
	applyDamage: (number) -> (),
	-- Opens (refreshes) this target's air-tech escape window -- see CombatState.airTechWindowExpiry's
	-- own header and CombatSystem.lua's handleAirTechRequest. No-op for a dummy (no client, nothing to
	-- request an escape).
	openAirTechWindow: () -> (),
}

local function applyAirCombo(
	attackerPlayer: Player,
	attackerState: CombatState,
	target: AirComboTarget,
	debugName: string,
	now: number
): ()
	local cfg = Constants.Combat.AirCombo

	if debugName == "DashPunch" then
		target.setAsAirComboTarget()
		target.openAirTechWindow()
		attackerState.airComboHitCount = 1
		attackerState.airComboExpiry = now + cfg.AirborneSeconds

		-- Vertical motion is owned entirely by HoldAloft below now -- see Constants.Combat.AirCombo.
		-- HoverHeight's own header for why a launch velocity + gravity estimate got replaced.
		-- Horizontal pop + tumble spin stay: neither fights a position hold (AlignPosition only
		-- constrains position, not rotation), and they're what makes entering the hold read as a hit
		-- landing rather than a teleport.
		RagdollController.LaunchAndRagdoll(
			target.model,
			target.humanoid,
			target.rootPart,
			target.player,
			attackerState.rootPart,
			0,
			cfg.LaunchHorizontalVelocity,
			cfg.LaunchBackwardSpin,
			cfg.AirborneSeconds
		)
		local hoverPosition = target.rootPart.Position + Vector3.new(0, cfg.HoverHeight, 0)
		attackerState.airComboHoverPosition = hoverPosition
		RagdollController.HoldAloft(
			target.rootPart,
			target.player,
			hoverPosition,
			cfg.AirborneSeconds,
			cfg.HoverRiseSpeed,
			cfg.HoverResponsiveness
		)
		target.setRagdollExpiry(now + cfg.AirborneSeconds)
		-- A launched target can't keep holding guard while airborne and limp -- same rule a
		-- finisher's own launch already applies. No-op for a dummy (never blocks).
		target.clearBlocking()

		local attackerRoot = attackerState.rootPart
		if attackerRoot then
			-- Standoff offset: how far back + down the attacker's own hold parks them from the
			-- target's hover point, instead of holding them at the exact same point -- see
			-- CombatState.airComboChaseOffset's own header. Direction is away from the target, back
			-- toward wherever the attacker was actually standing when the punch landed (their real
			-- approach direction); falls back to a fixed world direction on the rare near-zero-
			-- distance case (DashPunch's own Offset/Size means this essentially never happens in
			-- practice) instead of normalizing a near-zero vector.
			local awayFromTarget = Vector3.new(
				attackerRoot.Position.X - target.rootPart.Position.X,
				0,
				attackerRoot.Position.Z - target.rootPart.Position.Z
			)
			local standoffDirection = if awayFromTarget.Magnitude
					> Constants.Combat.AirCombo.MinStandoffDirectionMagnitude
				then awayFromTarget.Unit
				else Vector3.new(0, 0, 1)
			local chaseOffset = standoffDirection * cfg.ChaseStandoffDistance
				- Vector3.new(0, cfg.ChaseBelowTargetOffset, 0)
			attackerState.airComboChaseOffset = chaseOffset

			-- The attacker's own hold -- see RagdollController.HoldAloft's own header for why this is
			-- the SAME mechanism the target's hover uses (a fixed-point AlignPosition pin) rather than
			-- a separate live-tracking chase: once the target settles, there's nothing left to
			-- continuously re-track, and holding the attacker to a fixed point too is what avoids the
			-- "snap up snap up" jerk a per-Heartbeat re-target caused.
			RagdollController.HoldAloft(
				attackerRoot,
				attackerPlayer,
				hoverPosition + chaseOffset,
				cfg.AirborneSeconds,
				cfg.ChaseSpeed,
				cfg.ChaseResponsiveness,
				-- liveBodyFacePoint = the target's hover position. Marks this as the attacker's LIVE
				-- (non-ragdolled) hold: cancels gravity so the soft pin doesn't sag ("float down"),
				-- quiets the Humanoid so the rise doesn't stutter ("stages of height"), and points the
				-- attacker at the target so continuation swings keep landing (not "OutsideArc"). See
				-- RagdollController.HoldAloft.
				hoverPosition
			)
			-- See CombatState.airComboChaseExpiry's own header -- without this, the player's own held
			-- WASD keeps fighting the hold's pull for the whole window instead of riding along.
			attackerState.airComboChaseExpiry = now + cfg.AirborneSeconds
		end
		return
	end

	if not target.isCurrentAirComboTarget() or now > attackerState.airComboExpiry then
		return
	end

	attackerState.airComboHitCount += 1

	if attackerState.airComboHitCount >= cfg.MaxHits then
		-- Slam finisher -- the sequence ends here regardless of whether the target survives it.
		-- Clear the still-active hold first -- a lingering upward AlignPosition pin fighting the
		-- slam's own downward velocity would read as a weaker slam than intended.
		RagdollController.ClearHold(target.rootPart, target.player)
		RagdollController.SlamToGround(
			target.model,
			target.humanoid,
			target.player,
			cfg.SlamDownVelocity,
			cfg.SlamKnockdownSeconds
		)
		target.setRagdollExpiry(now + cfg.SlamKnockdownSeconds)
		target.clearBlocking()

		-- Same godmode rule as every other damage source -- see CombatState.godmode's own header
		-- (folded into `applyDamage` for a player target; a dummy has no godmode concept at all).
		target.applyDamage(cfg.SlamBonusDamage)

		-- The attacker lands normally once the sequence is over -- clear their own hold too, same
		-- reasoning as the target's hold clear above (also hands their movement control back
		-- immediately instead of waiting out the rest of the window).
		if attackerState.rootPart then
			RagdollController.ClearHold(attackerState.rootPart, attackerPlayer)
		end
		-- ClearHold only hands back network ownership -- per its own header, it never touches this
		-- field, so it has to be zeroed right here or the player stays pinned at WalkSpeed 0 for
		-- whatever's left of the original window even though the pull already stopped.
		attackerState.airComboChaseExpiry = 0

		target.clearAirComboTarget()
		attackerState.airComboHitCount = 0
		attackerState.airComboExpiry = 0
		attackerState.airComboHoverPosition = nil
		attackerState.airComboChaseOffset = nil
	else
		-- Keep them locked into the ragdoll/lockout window for the next hit -- no re-launch, no
		-- velocity touch at all: HoldAloft below already has them settled at the right height, and
		-- both re-launching (the old bug -- Constants.Combat.AirCombo.HoverHeight's own header) and
		-- even a zero-velocity "launch" (a newer, smaller version of the same mistake -- stomping the
		-- hold's own settled velocity every hit, a small re-jerk each time) are exactly what
		-- ExtendRagdoll avoids by touching only the timer.
		RagdollController.ExtendRagdoll(target.model, cfg.AirborneSeconds)
		target.setRagdollExpiry(now + cfg.AirborneSeconds)
		-- Fresh air-tech opportunity on every continuation hit, not just the initial launch.
		target.openAirTechWindow()
		-- Refresh both holds at their SAME original points -- never freshly-computed ones, see
		-- CombatState.airComboHoverPosition/airComboChaseOffset's own headers for why that's what
		-- keeps the height/spacing fixed across continuation hits instead of ratcheting up.
		if attackerState.airComboHoverPosition then
			RagdollController.HoldAloft(
				target.rootPart,
				target.player,
				attackerState.airComboHoverPosition,
				cfg.AirborneSeconds,
				cfg.HoverRiseSpeed,
				cfg.HoverResponsiveness
			)
		end
		if attackerState.rootPart and attackerState.airComboHoverPosition and attackerState.airComboChaseOffset then
			RagdollController.HoldAloft(
				attackerState.rootPart,
				attackerPlayer,
				attackerState.airComboHoverPosition + attackerState.airComboChaseOffset,
				cfg.AirborneSeconds,
				cfg.ChaseSpeed,
				cfg.ChaseResponsiveness,
				-- liveBodyFacePoint = the target's stored hover position -- same live-body treatment
				-- (gravity-cancel + rigid hold + face-the-target) as the initial hold above.
				attackerState.airComboHoverPosition
			)
			-- Same refresh as the hold above -- see CombatState.airComboChaseExpiry's own header.
			attackerState.airComboChaseExpiry = now + cfg.AirborneSeconds
		end
		attackerState.airComboExpiry = now + cfg.AirborneSeconds
	end
end

-- The actual damage/posture/block/parry/death resolution for one attacker-target pair, given the
-- specific Types.HitboxAttackDefinition stage that landed. Called at most once per target per
-- swing -- HitboxResolver's dedup guarantees that (see onSwingHitCandidate below) -- so this
-- function itself never needs to worry about being invoked twice for the same hit. finisherVariant is
-- non-nil only for the M1 combo's 4th hit -- see the finisher block near the end.
-- Returns whether the hit CONNECTED (dealt damage/posture -- i.e. defenseKind is "None" or
-- "Block") as opposed to being fully avoided via Parry -- startAttackSwing's OnHit uses this (not
-- HitboxResolver's own dedup-facing true/false) to decide whether the landing-based M1 combo
-- counter advances, so a Parry can never fast-track a Finisher the way a whiff already can't (see
-- CombatState.basicComboLanded's own comment).
local function resolveHitAgainstTarget(
	attackerPlayer: Player,
	attackerState: CombatState,
	targetPlayer: Player,
	targetState: CombatState,
	definition: Types.HitboxAttackDefinition,
	isHeavy: boolean,
	finisherVariant: Types.FinisherVariant?
): boolean
	local targetHumanoid = targetState.humanoid
	if not targetHumanoid then
		return false
	end

	local now = os.clock()

	-- Landing/receiving a hit refreshes InCombat for BOTH sides regardless of outcome (hit/blocked/
	-- parried) -- the flag's job is "is this player mid-engagement," which is true whether the
	-- exchange favored the attacker or the defender. See CombatState.inCombatUntil's own header.
	attackerState.inCombatUntil = now + Constants.Combat.InCombatDurationSeconds
	targetState.inCombatUntil = now + Constants.Combat.InCombatDurationSeconds

	-- A real hit resolving against the target ends any suspended air-tech exchange they're currently
	-- in, regardless of outcome (hit/blocked/parried) and regardless of whether THIS attacker is who
	-- they were suspended with -- see CombatState.airComboSuspendedUntil's own header. An outside
	-- event deciding the encounter is exactly one of the ways that state is meant to resolve.
	if targetState.airComboSuspendedUntil ~= 0 then
		local suspendedWithPlayer = targetState.airComboSuspendedWithAttacker
		local suspendedWithState = if suspendedWithPlayer then combatStates[suspendedWithPlayer] else nil
		endSuspendedAirComboExchange(targetPlayer, targetState, suspendedWithPlayer, suspendedWithState)
	end

	local wasPostureBroken = now < targetState.postureBrokenExpiry
	local defenseKind = HitResolution.ClassifyDefense(
		now,
		targetState.postureBrokenExpiry,
		targetState.parryWindowExpiry,
		targetState.blocking
	)

	if defenseKind == "Parry" then
		logger:info("Parry detected", {
			attacker = attackerPlayer.Name,
			defender = targetPlayer.Name,
			attack = definition.DebugName,
		})

		-- Parry consumed on use -- punishes the attacker with posture damage + a stun, deals no
		-- damage to the defender.
		targetState.parryWindowExpiry = 0

		HitResolution.ApplyParryPunish(attackerState, now)
		sendVitals(attackerPlayer, attackerState)

		local payload = buildFeedbackPayload("Parried", attackerPlayer, targetPlayer, nil, nil, isHeavy)
		sendFeedback(attackerPlayer, payload)
		sendFeedback(targetPlayer, payload)

		if attackerState.posture <= 0 then
			triggerPostureBreak(attackerPlayer, attackerState, targetPlayer)
			sendVitals(attackerPlayer, attackerState)
		end

		-- Disarm: a Heavy attack that gets Parried disarms its attacker (Constants.Combat.Disarm) --
		-- see HitResolution.ShouldDisarm's own comment for why this is scoped to Heavy specifically.
		if HitResolution.ShouldDisarm(defenseKind, isHeavy) then
			HitResolution.ApplyDisarm(attackerState, now)
			local disarmPayload = buildFeedbackPayload("Disarmed", attackerPlayer, targetPlayer, nil, nil, isHeavy)
			sendFeedback(attackerPlayer, disarmPayload)
			sendFeedback(targetPlayer, disarmPayload)
		end

		return false
	end

	if defenseKind == "Block" then
		logger:debug(
			"Block detected",
			{ attacker = attackerPlayer.Name, defender = targetPlayer.Name, attack = definition.DebugName }
		)
	end

	local outcome = HitResolution.ComputeOutcome(definition, defenseKind)
	local finalDamage = outcome.Damage
	local finalPosture = outcome.Posture
	if targetState.godmode then
		finalDamage = 0
		finalPosture = 0
	end

	logger:info("Hit resolved", {
		attacker = attackerPlayer.Name,
		target = targetPlayer.Name,
		attack = definition.DebugName,
		isHeavy = isHeavy,
		blocked = defenseKind == "Block",
		damage = finalDamage,
		postureDamage = finalPosture,
	})

	targetState.posture = math.max(0, targetState.posture - finalPosture)

	if defenseKind ~= "Block" then
		-- Universal hit reaction (Constants.Combat.HitStunDuration/HitSlowDuration) -- a real,
		-- felt interruption on every unmitigated hit, distinct from the much harsher attacker-only
		-- parry punish above. Gates every action category via ACTION_GATES (Basic/Heavy/BlockStart/
		-- Dash/SwapWeapon all check Stun), not just attacks. math.max so this never shortens a
		-- longer lockout (parry stun, posture break) already in effect.
		targetState.stunExpiry = math.max(targetState.stunExpiry, now + Constants.Combat.HitStunDuration)
		targetState.hitSlowExpiry = now + Constants.Combat.HitSlowDuration
		-- Same-frame slow, but through the unified resolver rather than a raw
		-- BaseWalkSpeed*multiplier write: the resolver honors the BonusWalkSpeed attribute and any
		-- higher-priority speed claim (air-combo chase, dash) that a direct write would
		-- momentarily clobber until onHeartbeat reconciled it next tick. One formula, one writer.
		targetHumanoid.WalkSpeed = Movement.ComputeDesiredWalkSpeed(targetState, now)
	end

	if targetHumanoid.Health - finalDamage <= 0 then
		targetState.pendingKillerUserId = attackerPlayer.UserId
	end
	if finalDamage > 0 then
		targetHumanoid:TakeDamage(finalDamage)
	end

	sendVitals(targetPlayer, targetState)

	local kind: Types.CombatFeedbackKind = if defenseKind == "Block" then "Blocked" else "Hit"
	local payload = buildFeedbackPayload(
		kind,
		attackerPlayer,
		targetPlayer,
		finalDamage,
		finalPosture,
		isHeavy,
		nil,
		definition.DebugName
	)
	sendFeedback(attackerPlayer, payload)
	sendFeedback(targetPlayer, payload)

	if targetState.posture <= 0 and not wasPostureBroken then
		triggerPostureBreak(targetPlayer, targetState, attackerPlayer)
		sendVitals(targetPlayer, targetState)
	end

	-- Finisher knockback -- only on a clean (non-blocked) hit; parry already returned above, so
	-- reaching here unmitigated means the finisher connected. Blocking a finisher eats the heavy
	-- posture damage but stops the launch (the point of guarding). Uppercut/Downslam ragdoll the
	-- target and lock them out of acting for the same window (ragdollExpiry); Normal just adds hitstun.
	if finisherVariant and defenseKind ~= "Block" then
		local targetCharacter = targetState.character
		local targetRootPart = targetState.rootPart
		if targetCharacter and targetRootPart then
			local ragdollSeconds = HitResolution.ApplyFinisherPhysics(
				targetCharacter,
				targetHumanoid,
				targetRootPart,
				targetPlayer,
				finisherVariant,
				attackerState.rootPart
			)
			if ragdollSeconds > 0 then
				targetState.ragdollExpiry = math.max(targetState.ragdollExpiry, now + ragdollSeconds)
				-- A launched target can't keep holding guard while airborne and limp.
				targetState.blocking = false
			elseif finisherVariant == "Normal" then
				targetState.stunExpiry =
					math.max(targetState.stunExpiry, now + Constants.Combat.Finisher.Normal.ExtraStunSeconds)
			end
		end
	end

	-- Air combo -- only Basic-category hits (never Heavy, never the M1 finisher, which already has
	-- its own launch above) either start or continue a sequence. See applyAirCombo's own header.
	-- DashPunch (the double-tap-forward punch, definition.DebugName == "DashPunch") is what STARTS
	-- one on a clean connect -- the plain front-dash's own DashHit attack (handleDashRequest's
	-- other, non-double-tap front-dash attack) is a DIFFERENT debug name and never matches the
	-- "DashPunch" check inside applyAirCombo, so it can never start or continue a sequence -- see
	-- that function's own header for the full DashPunch-only launch condition.
	if not isHeavy and not finisherVariant and defenseKind ~= "Block" then
		local targetCharacter = targetState.character
		local targetRootPart = targetState.rootPart
		if targetCharacter and targetRootPart then
			-- Player-target adapter for the unified applyAirCombo -- see AirComboTarget's own header
			-- for what each closure hides. godmode/kill-attribution/vitals all fold into applyDamage
			-- here since only a real player target has any of those concepts.
			applyAirCombo(attackerPlayer, attackerState, {
				model = targetCharacter,
				humanoid = targetHumanoid,
				rootPart = targetRootPart,
				player = targetPlayer,
				clearBlocking = function()
					targetState.blocking = false
				end,
				setRagdollExpiry = function(expiry: number)
					targetState.ragdollExpiry = math.max(targetState.ragdollExpiry, expiry)
				end,
				isCurrentAirComboTarget = function()
					return attackerState.airComboTarget == targetPlayer
				end,
				setAsAirComboTarget = function()
					attackerState.airComboTarget = targetPlayer
				end,
				clearAirComboTarget = function()
					attackerState.airComboTarget = nil
				end,
				openAirTechWindow = function()
					targetState.airTechWindowExpiry = now + Constants.Combat.AirCombo.TechWindowSeconds
				end,
				applyDamage = function(amount: number)
					-- Same godmode rule as every other damage source -- see CombatState.godmode's
					-- own header.
					if not targetState.godmode then
						if targetHumanoid.Health - amount <= 0 then
							targetState.pendingKillerUserId = attackerPlayer.UserId
						end
						targetHumanoid:TakeDamage(amount)
					end
					sendVitals(targetPlayer, targetState)
				end,
			}, definition.DebugName, now)
		end
	end

	return true
end

-- Dummy equivalent of triggerPostureBreak -- shares triggerPostureBreakShared's skeleton now (see
-- that function's own header); a DummyState has no Player to key a target-side feedback send off
-- of and no `blocking` field, so its closures are simpler -- the attacker is the only one who ever
-- receives dummy feedback (dummies have no client of their own).
local function triggerDummyPostureBreak(dummyState: DummyState, attackerPlayer: Player?): ()
	triggerPostureBreakShared(
		dummyState,
		dummyState.humanoid,
		attackerPlayer,
		"Posture break triggered (dummy)",
		{ dummy = dummyState.model.Name },
		function() end,
		function(attacker: Player?)
			if attacker then
				local payload =
					buildFeedbackPayload("PostureBreak", attacker, nil, nil, nil, nil, dummyState.rootPart.Position)
				sendFeedback(attacker, payload)
			end
		end
	)
end

-- Dummy equivalent of resolveHitAgainstTarget -- much simpler since a dummy never blocks or
-- parries (no input of its own), so every hit is a plain, unmitigated "Hit". Still goes through
-- humanoid:TakeDamage (not a direct Health assignment) for the exact same reason the player path
-- does -- so Humanoid.Died and every other engine-level death behavior keep working.
local function resolveHitAgainstDummy(
	attackerPlayer: Player,
	dummyState: DummyState,
	definition: Types.HitboxAttackDefinition,
	isHeavy: boolean,
	finisherVariant: Types.FinisherVariant?
): ()
	local targetPosition = dummyState.rootPart.Position
	local wasPostureBroken = os.clock() < dummyState.postureBrokenExpiry

	-- A dummy never blocks/parries (no input of its own), so every hit is a plain,
	-- unmitigated "Hit" -- ComputeOutcome("None") is an identity passthrough of the definition's
	-- own numbers, same as the direct damage/postureDamage reads this replaced.
	local outcome = HitResolution.ComputeOutcome(definition, "None")
	local damage = outcome.Damage
	local postureDamage = outcome.Posture

	dummyState.posture = math.max(0, dummyState.posture - postureDamage)

	logger:info("Hit resolved (dummy)", {
		attacker = attackerPlayer.Name,
		dummy = dummyState.model.Name,
		attack = definition.DebugName,
		isHeavy = isHeavy,
		damage = damage,
		postureDamage = postureDamage,
	})

	-- Still goes through humanoid:TakeDamage (not a direct Health assignment) for the exact same
	-- reason the player path does -- so Humanoid.Died and every other engine-level death behavior
	-- keep working.
	if damage > 0 then
		dummyState.humanoid:TakeDamage(damage)
	end

	-- attackDebugName (definition.DebugName) is passed through here now -- matching
	-- resolveHitAgainstTarget's identical call -- so PredictionMirror.OnOwnSwingConnected on the
	-- attacker's own client can actually see it. It used to be omitted (defaulting to nil), which
	-- silently broke two things for solo dummy practice: the mirrored Basic-combo landing count
	-- (PredictedSwing always guessed stage 1, relying entirely on ConfirmSwing's crossfade to
	-- correct it) and, more visibly, PredictionMirror.IsInAirCombo -- OnOwnSwingConnected's very
	-- first line is `if isHeavy or not attackDebugName then return end`, so a nil name meant a
	-- DashPunch landed on a dummy could never open the mirror's airComboActiveUntil window, and the
	-- client kept locally predicting the Downslam/AirSlam animation for every follow-up M1 even
	-- after the server-side fix (this file's own inAirCombo check, above) started correctly
	-- continuing the combo -- the confirm echo's crossfade papered over it a beat late, but the
	-- predicted pose was still wrong the instant the press landed.
	local payload = buildFeedbackPayload(
		"Hit",
		attackerPlayer,
		nil,
		damage,
		postureDamage,
		isHeavy,
		targetPosition,
		definition.DebugName
	)
	sendFeedback(attackerPlayer, payload)

	if dummyState.posture <= 0 and not wasPostureBroken then
		triggerDummyPostureBreak(dummyState, attackerPlayer)
	end

	local attackerState = combatStates[attackerPlayer]

	-- A finisher launches/ragdolls a dummy exactly like a player (a dummy is a real physics
	-- character), so the uppercut/downslam are testable solo against one. No ownerPlayer (a dummy has
	-- no client) and no action lockout (a dummy never acts) -- just the physics.
	if finisherVariant then
		local ragdollSeconds = HitResolution.ApplyFinisherPhysics(
			dummyState.model,
			dummyState.humanoid,
			dummyState.rootPart,
			nil,
			finisherVariant,
			attackerState and attackerState.rootPart
		)
		-- Schedule the dummy to reset to spawn once the ragdoll has recovered (+ a buffer so you see it
		-- get up first) -- onHeartbeat's dummy loop does the actual reset. A Normal finisher doesn't
		-- ragdoll (ragdollSeconds == 0), so there's nothing to reset from.
		if ragdollSeconds > 0 then
			dummyState.ragdollResetAt = os.clock()
				+ ragdollSeconds
				+ Constants.Debug.TrainingDummy.LaunchResetBufferSeconds
		end
	end

	-- Air combo, solo-testable against a dummy -- see applyAirCombo's own header (unified across
	-- player/dummy targets). Same Basic-category-only gate the player-target path uses (never
	-- Heavy, never the M1 finisher, which already has its own launch above) -- see
	-- resolveHitAgainstTarget's own comment for why DashHit (the plain front-dash's own attack)
	-- never reaches applyAirCombo's own "DashPunch" launch condition either.
	if not isHeavy and not finisherVariant and attackerState then
		-- Rebind to a non-optional local -- attackerState is CombatState? (combatStates[attackerPlayer]
		-- may not exist), and Luau's nil-narrowing from the `and attackerState` check above doesn't
		-- extend into the closures built below, which capture and read it after this line.
		local attacker: CombatState = attackerState
		local resetBuffer = Constants.Debug.TrainingDummy.LaunchResetBufferSeconds
		-- Dummy-target adapter -- see AirComboTarget's own header for what each closure hides.
		-- clearBlocking is a no-op (DummyState has no `blocking` field -- a dummy never blocks);
		-- setRagdollExpiry is a flat overwrite (no math.max) plus the launch-reset buffer, matching
		-- resolveHitAgainstDummy's own finisher-reset scheduling just above; applyDamage is a plain
		-- TakeDamage (no godmode concept, no vitals stream to sync for a dummy).
		applyAirCombo(attackerPlayer, attacker, {
			model = dummyState.model,
			humanoid = dummyState.humanoid,
			rootPart = dummyState.rootPart,
			player = nil,
			clearBlocking = function() end,
			setRagdollExpiry = function(expiry: number)
				dummyState.ragdollResetAt = expiry + resetBuffer
			end,
			isCurrentAirComboTarget = function()
				return attacker.airComboDummyTarget == dummyState.model
			end,
			setAsAirComboTarget = function()
				attacker.airComboDummyTarget = dummyState.model
			end,
			clearAirComboTarget = function()
				attacker.airComboDummyTarget = nil
			end,
			-- A dummy has no client to request an escape with -- no-op.
			openAirTechWindow = function() end,
			applyDamage = function(amount: number)
				dummyState.humanoid:TakeDamage(amount)
			end,
		}, definition.DebugName, os.clock())
	end
end

-- Bot equivalent of triggerPostureBreak -- shares triggerPostureBreakShared's skeleton now (see
-- that function's own header); unlike triggerDummyPostureBreak, also drops the bot's own block the
-- way the player-side version does (a bot can be mid-block when this fires; a dummy never can, so
-- that closure is a no-op on the dummy path but not here).
local function triggerBotPostureBreak(botState: BotState, attackerPlayer: Player?): ()
	triggerPostureBreakShared(
		botState,
		botState.humanoid,
		attackerPlayer,
		"Posture break triggered (bot)",
		{ bot = botState.model.Name },
		function()
			botState.blocking = false
		end,
		function(attacker: Player?)
			if attacker then
				local payload =
					buildFeedbackPayload("PostureBreak", attacker, nil, nil, nil, nil, botState.rootPart.Position)
				sendFeedback(attacker, payload)
			end
		end
	)
end

-- Bot-as-defender equivalent of resolveHitAgainstTarget -- a real player attacked, a training bot
-- got hit. Mirrors that function's block/parry logic exactly (same Constants.Combat numbers) but
-- against BotState fields instead of a second CombatState, and only ever sends feedback to
-- attackerPlayer (the bot has no client of its own -- same one-sided reasoning as
-- resolveHitAgainstDummy, just with real block/parry mitigation this time since a bot, unlike a
-- dummy, actually blocks/parries).
-- Returns whether the hit CONNECTED -- see resolveHitAgainstTarget's identical header for why this
-- exists (startAttackSwing's OnHit gates M1 combo advancement on it). finisherVariant is non-nil
-- only for the M1 combo's 4th hit, mirroring resolveHitAgainstTarget/resolveHitAgainstDummy.
local function resolveHitAgainstBot(
	attackerPlayer: Player,
	attackerState: CombatState,
	botState: BotState,
	definition: Types.HitboxAttackDefinition,
	isHeavy: boolean,
	finisherVariant: Types.FinisherVariant?
): boolean
	local now = os.clock()
	local targetPosition = botState.rootPart.Position

	-- BotState has no inCombatUntil field (bots aren't a real system consumer of this flag today),
	-- but the attacking PLAYER'S own engagement is still real -- refresh it the same as any other
	-- landed swing.
	attackerState.inCombatUntil = now + Constants.Combat.InCombatDurationSeconds

	local wasPostureBroken = now < botState.postureBrokenExpiry
	local defenseKind =
		HitResolution.ClassifyDefense(now, botState.postureBrokenExpiry, botState.parryWindowExpiry, botState.blocking)

	if defenseKind == "Parry" then
		logger:info("Parry detected (bot defender)", {
			attacker = attackerPlayer.Name,
			defender = botState.model.Name,
			attack = definition.DebugName,
		})

		botState.parryWindowExpiry = 0

		HitResolution.ApplyParryPunish(attackerState, now)
		sendVitals(attackerPlayer, attackerState)

		local payload = buildFeedbackPayload("Parried", attackerPlayer, nil, nil, nil, isHeavy, targetPosition)
		sendFeedback(attackerPlayer, payload)

		if attackerState.posture <= 0 then
			triggerPostureBreak(attackerPlayer, attackerState, nil)
			sendVitals(attackerPlayer, attackerState)
		end

		if HitResolution.ShouldDisarm(defenseKind, isHeavy) then
			HitResolution.ApplyDisarm(attackerState, now)
			local disarmPayload =
				buildFeedbackPayload("Disarmed", attackerPlayer, nil, nil, nil, isHeavy, targetPosition)
			sendFeedback(attackerPlayer, disarmPayload)
		end

		return false
	end

	if defenseKind == "Block" then
		logger:debug("Block detected (bot defender)", {
			attacker = attackerPlayer.Name,
			defender = botState.model.Name,
			attack = definition.DebugName,
		})
	end

	local outcome = HitResolution.ComputeOutcome(definition, defenseKind)
	local finalDamage = outcome.Damage
	local finalPosture = outcome.Posture

	logger:info("Hit resolved (bot defender)", {
		attacker = attackerPlayer.Name,
		target = botState.model.Name,
		attack = definition.DebugName,
		isHeavy = isHeavy,
		blocked = defenseKind == "Block",
		damage = finalDamage,
		postureDamage = finalPosture,
	})

	botState.posture = math.max(0, botState.posture - finalPosture)

	if defenseKind ~= "Block" then
		-- Same universal hit reaction as resolveHitAgainstTarget's -- WalkSpeed clip omitted here
		-- since a bot's position is driven directly (onHeartbeat's bot loop), not by WalkSpeed, so
		-- there'd be nothing for it to visibly do. The stun half still matters: it briefly gates the
		-- bot's own next RequestBotAttack/RequestBotBlockStart. The bot's own Hit1/2/3 flinch is the
		-- visible half -- same "never while Block" gating as the player-facing PlayHitReaction.
		botState.stunExpiry = math.max(botState.stunExpiry, now + Constants.Combat.HitStunDuration)
		BotAnimator.PlayHitReaction(botState.model, definition.DebugName)
	end

	if botState.humanoid.Health - finalDamage <= 0 then
		botState.pendingKillerUserId = attackerPlayer.UserId
	end
	if finalDamage > 0 then
		botState.humanoid:TakeDamage(finalDamage)
	end

	local kind: Types.CombatFeedbackKind = if defenseKind == "Block" then "Blocked" else "Hit"
	local payload = buildFeedbackPayload(kind, attackerPlayer, nil, finalDamage, finalPosture, isHeavy, targetPosition)
	sendFeedback(attackerPlayer, payload)

	if botState.posture <= 0 and not wasPostureBroken then
		triggerBotPostureBreak(botState, attackerPlayer)
	end

	-- Finisher knockback -- mirrors resolveHitAgainstTarget's identical block, adapted for a bot
	-- target: BotState has no ragdollExpiry field (a bot's actions are driven by
	-- TrainingBotSystem's AI loop reading RequestBotAttack/RequestBotBlockStart, not a per-request
	-- client lockout) -- reusing stunExpiry as the bot's action-lockout during the ragdoll instead,
	-- since both of those entry points already gate on it.
	if finisherVariant and defenseKind ~= "Block" then
		local ragdollSeconds = HitResolution.ApplyFinisherPhysics(
			botState.model,
			botState.humanoid,
			botState.rootPart,
			nil,
			finisherVariant,
			attackerState.rootPart
		)
		if ragdollSeconds > 0 then
			botState.stunExpiry = math.max(botState.stunExpiry, now + ragdollSeconds)
			botState.blocking = false
		elseif finisherVariant == "Normal" then
			botState.stunExpiry = math.max(botState.stunExpiry, now + Constants.Combat.Finisher.Normal.ExtraStunSeconds)
		end
	end

	return true
end

-- Bot-as-attacker equivalent of resolveHitAgainstTarget -- a training bot attacked its owner.
-- Mirrors that function's block/parry logic exactly, attacker side now being BotState instead of
-- CombatState; a successful parry against the bot punishes botState's own posture/stun instead of
-- a second player's, and feedback only ever goes to targetPlayer (the bot has no client). Passing
-- nil for the "attacker" in buildFeedbackPayload/triggerPostureBreak below is deliberate -- a bot
-- has no Player identity to attribute, and CombatClient.lua already treats a nil AttackerUserId as
-- "not me" for anything gated on the local player being the attacker (e.g. the stun-effect/hit-sound
-- triggers), which is exactly correct here: the human defender is never the one who gets punished
-- for a bot's own attack.
local function resolveHitFromBotAgainstPlayer(
	botState: BotState,
	targetPlayer: Player,
	targetState: CombatState,
	definition: Types.HitboxAttackDefinition,
	isHeavy: boolean
): ()
	local targetHumanoid = targetState.humanoid
	if not targetHumanoid then
		return
	end

	local now = os.clock()

	-- Refreshes the real player's own InCombat (BotState has no such field -- a bot isn't a
	-- real system consumer of this flag today, see CombatState.inCombatUntil's own header).
	targetState.inCombatUntil = now + Constants.Combat.InCombatDurationSeconds

	-- Same "an outside hit resolves any suspended exchange" rule resolveHitAgainstTarget applies --
	-- see that function's own comment.
	if targetState.airComboSuspendedUntil ~= 0 then
		local suspendedWithPlayer = targetState.airComboSuspendedWithAttacker
		local suspendedWithState = if suspendedWithPlayer then combatStates[suspendedWithPlayer] else nil
		endSuspendedAirComboExchange(targetPlayer, targetState, suspendedWithPlayer, suspendedWithState)
	end

	local wasPostureBroken = now < targetState.postureBrokenExpiry
	local defenseKind = HitResolution.ClassifyDefense(
		now,
		targetState.postureBrokenExpiry,
		targetState.parryWindowExpiry,
		targetState.blocking
	)

	if defenseKind == "Parry" then
		logger:info("Parry detected (bot attacker)", {
			attacker = botState.model.Name,
			defender = targetPlayer.Name,
			attack = definition.DebugName,
		})

		targetState.parryWindowExpiry = 0

		botState.posture = math.max(0, botState.posture - Constants.Combat.ParryPunishPostureDamage)
		botState.stunExpiry = now + Constants.Combat.StunDuration

		local payload = buildFeedbackPayload("Parried", nil, targetPlayer, nil, nil, isHeavy)
		sendFeedback(targetPlayer, payload)

		if botState.posture <= 0 then
			triggerBotPostureBreak(botState, targetPlayer)
		end

		if HitResolution.ShouldDisarm(defenseKind, isHeavy) then
			HitResolution.ApplyDisarm(botState, now)
			local disarmPayload = buildFeedbackPayload("Disarmed", nil, targetPlayer, nil, nil, isHeavy)
			sendFeedback(targetPlayer, disarmPayload)
		end

		return
	end

	if defenseKind == "Block" then
		logger:debug("Block detected (bot attacker)", {
			attacker = botState.model.Name,
			defender = targetPlayer.Name,
			attack = definition.DebugName,
		})
	end

	local outcome = HitResolution.ComputeOutcome(definition, defenseKind)
	local finalDamage = outcome.Damage
	local finalPosture = outcome.Posture
	if targetState.godmode then
		finalDamage = 0
		finalPosture = 0
	end

	logger:info("Hit resolved (bot attacker)", {
		attacker = botState.model.Name,
		target = targetPlayer.Name,
		attack = definition.DebugName,
		isHeavy = isHeavy,
		blocked = defenseKind == "Block",
		damage = finalDamage,
		postureDamage = finalPosture,
	})

	targetState.posture = math.max(0, targetState.posture - finalPosture)

	if defenseKind ~= "Block" then
		-- Same universal hit reaction as resolveHitAgainstTarget's -- the human defender getting hit
		-- by a bot reacts exactly like getting hit by a real attacker. Slow goes through the
		-- unified resolver for the same single-writer reasons as that site.
		targetState.stunExpiry = math.max(targetState.stunExpiry, now + Constants.Combat.HitStunDuration)
		targetState.hitSlowExpiry = now + Constants.Combat.HitSlowDuration
		targetHumanoid.WalkSpeed = Movement.ComputeDesiredWalkSpeed(targetState, now)
	end

	if finalDamage > 0 then
		targetHumanoid:TakeDamage(finalDamage)
	end

	sendVitals(targetPlayer, targetState)

	local kind: Types.CombatFeedbackKind = if defenseKind == "Block" then "Blocked" else "Hit"
	local payload =
		buildFeedbackPayload(kind, nil, targetPlayer, finalDamage, finalPosture, isHeavy, nil, definition.DebugName)
	sendFeedback(targetPlayer, payload)

	if targetState.posture <= 0 and not wasPostureBroken then
		triggerPostureBreak(targetPlayer, targetState, nil)
		sendVitals(targetPlayer, targetState)
	end
end

-- HitboxResolver's OnHit callback for one swing: translates an overlapped Model back into a
-- Player/CombatState and runs every semantic check the raw geometry query can't (is this actually
-- a live hostile combatant, still within the definition's arc, with a clear line of sight) before
-- resolving the hit. Returns (counted, connected): `counted` is false (not a real hit -- stays
-- eligible for a later sample this same swing) for anything that fails validation, true once a
-- resolveHitAgainst* function has actually run -- this is HitboxResolver's own dedup-facing signal,
-- unchanged from before `connected` existed. `connected` is startAttackSwing's OnHit-facing signal
-- for whether the hit actually dealt damage/posture (true) or was fully avoided via Parry
-- (false) -- see resolveHitAgainstTarget/resolveHitAgainstBot's own headers for why this is a
-- second, distinct concept from dedup.
local function onSwingHitCandidate(
	attackerPlayer: Player,
	attackerState: CombatState,
	definition: Types.HitboxAttackDefinition,
	isHeavy: boolean,
	finisherVariant: Types.FinisherVariant?,
	hitCharacter: Model
): (boolean, boolean)
	local attackerRoot = attackerState.rootPart
	local attackerCharacter = attackerState.character
	if not attackerRoot or not attackerCharacter then
		return false, false
	end

	local dummyState = dummyStates[hitCharacter]
	if dummyState then
		if not dummyState.alive then
			return false, false
		end

		local isValid, rejectReason = HitResolution.IsSwingTargetValid(
			attackerRoot,
			attackerCharacter,
			dummyState.rootPart,
			dummyState.model,
			definition.ArcDegrees
		)
		if not isValid then
			logger:debug("Hit candidate rejected: " .. (rejectReason or "invalid"), {
				attacker = attackerPlayer.Name,
				target = dummyState.model.Name,
			})
			return false, false
		end

		logger:info("Target selected", {
			attacker = attackerPlayer.Name,
			target = dummyState.model.Name,
			attack = definition.DebugName,
			isHeavy = isHeavy,
		})

		resolveHitAgainstDummy(attackerPlayer, dummyState, definition, isHeavy, finisherVariant)
		-- Deliberately does NOT refresh attackerState.inCombatUntil -- a training dummy never fights
		-- back (no input of its own, see DummyState's own header), so hitting one is solo practice,
		-- not "actively fighting somebody." Contrast resolveHitFromBotAgainstPlayer/the bot-hit branch
		-- below, which DO refresh it -- a training bot is a real, adversarial combat participant that
		-- attacks/blocks/parries back, a dummy is not.
		-- A dummy never blocks/parries (no input of its own) -- every hit against one
		-- connects.
		return true, true
	end

	local botState = botStates[hitCharacter]
	if botState then
		if not botState.alive then
			return false, false
		end
		-- Only the bot's own owner can hit it in melee (a bot is a private sparring partner) --
		-- getSwingCandidates should already guarantee this (it only ever offers the attacker's own
		-- bot), but re-checked here since OnHit candidates ultimately come from a geometry query
		-- against whatever the Include filter allowed, not a trusted call site on its own.
		if botState.ownerPlayer ~= attackerPlayer then
			return false, false
		end

		local isValid, rejectReason = HitResolution.IsSwingTargetValid(
			attackerRoot,
			attackerCharacter,
			botState.rootPart,
			botState.model,
			definition.ArcDegrees
		)
		if not isValid then
			logger:debug("Hit candidate rejected: " .. (rejectReason or "invalid"), {
				attacker = attackerPlayer.Name,
				target = botState.model.Name,
			})
			return false, false
		end

		logger:info("Target selected", {
			attacker = attackerPlayer.Name,
			target = botState.model.Name,
			attack = definition.DebugName,
			isHeavy = isHeavy,
		})

		local connected =
			resolveHitAgainstBot(attackerPlayer, attackerState, botState, definition, isHeavy, finisherVariant)
		return true, connected
	end

	local targetPlayer = characterToPlayer[hitCharacter]
	if not targetPlayer then
		-- Not a warning-level surprise on its own -- HitboxResolver's Include filter is built from
		-- a candidate list this System already validated, so this should be rare, but a stale
		-- reverse-lookup entry would land here, which is worth seeing.
		logger:warn("Hitbox overlap resolved to no tracked player or dummy", {
			attacker = attackerPlayer.Name,
			character = hitCharacter.Name,
		})
		return false, false
	end
	local targetState = combatStates[targetPlayer]
	if not targetState then
		logger:warn(
			"Hitbox overlap target has no combat state",
			{ attacker = attackerPlayer.Name, target = targetPlayer.Name }
		)
		return false, false
	end
	if not isValidHostileTarget(attackerState, targetState) then
		logger:debug("Hit candidate rejected: target invalid", {
			attacker = attackerPlayer.Name,
			target = targetPlayer.Name,
			reason = "TargetNotHostileOrDead",
		})
		return false, false
	end

	local targetRoot = targetState.rootPart
	local targetCharacter = targetState.character
	if not targetRoot or not targetCharacter then
		logger:debug(
			"Hit candidate rejected: missing root part",
			{ attacker = attackerPlayer.Name, target = targetPlayer.Name }
		)
		return false, false
	end

	local isValid, rejectReason = HitResolution.IsSwingTargetValid(
		attackerRoot,
		attackerCharacter,
		targetRoot,
		targetCharacter,
		definition.ArcDegrees
	)
	if not isValid then
		logger:debug("Hit candidate rejected: " .. (rejectReason or "invalid"), {
			attacker = attackerPlayer.Name,
			target = targetPlayer.Name,
		})
		return false, false
	end

	logger:info("Target selected", {
		attacker = attackerPlayer.Name,
		target = targetPlayer.Name,
		attack = definition.DebugName,
		isHeavy = isHeavy,
	})

	local connected = resolveHitAgainstTarget(
		attackerPlayer,
		attackerState,
		targetPlayer,
		targetState,
		definition,
		isHeavy,
		finisherVariant
	)
	return true, connected
end

-- Shared "is this attacker's swing still worth sampling" builder for HitboxResolver.StartSwing's
-- IsStillValid -- startAttackSwing/throwStandaloneAttack/startBotAttackSwing all need the exact
-- same base check: the attacker must still be alive, still occupying the SAME rootPart instance the
-- swing captured at throw-time (a respawn between throw and a later active-frame sample must never
-- let a stale swing land on the new body), and not currently locked out by stun or a posture break.
-- A Parry (or a posture break) fully answers the swing that triggered it -- stop sampling the
-- instant either lockout is active, rather than letting an already-punished attacker's multi-target
-- swing keep landing full damage on the rest of its active window. (A successful Parry always sets
-- stunExpiry via Constants.Combat.StunDuration regardless of attack category, so this also covers
-- the Disarm case without a separate disarmedUntil check.)
--
-- isSwingCancelled is a closure rather than a plain boolean field lookup because whether (and how)
-- to check it is genuinely per-move: startAttackSwing (any M1 stage) and throwStandaloneAttack's
-- AirSlam both watch CombatState.swingCancelled (set by a successful Feint mid-windup -- see that
-- field's own header) -- DashPunch/DashHit deliberately don't (handleFeintRequest's own header
-- explains why those two stay out of Feint's scope) -- and a bot has no such field at all (a bot
-- can't Feint), so startBotAttackSwing always passes a closure that returns false.
local function isAttackerStillCommitted(
	state: {
		alive: boolean,
		rootPart: BasePart?,
		stunExpiry: number,
		postureBrokenExpiry: number,
	},
	rootPart: BasePart,
	isSwingCancelled: () -> boolean
): () -> boolean
	return function(): boolean
		local validityNow = os.clock()
		return state.alive
			and state.rootPart == rootPart
			and validityNow >= state.stunExpiry
			and validityNow >= state.postureBrokenExpiry
			and not isSwingCancelled()
	end
end

-- Schedules the swept hitbox for one accepted attack request via HitboxResolver -- everything
-- past this point (windup, active-window sampling, hit resolution, recovery) runs off
-- HitboxResolver.Update(), driven by this System's own Heartbeat connection (see onHeartbeat).
local function startAttackSwing(
	attackerPlayer: Player,
	attackerState: CombatState,
	definition: Types.HitboxAttackDefinition,
	isHeavy: boolean,
	finisherVariant: Types.FinisherVariant?
): ()
	local rootPart = attackerState.rootPart
	if not rootPart then
		return
	end

	local hitLanded = false

	HitboxResolver.StartSwing({
		AttackerRootPart = rootPart,
		Definition = definition,
		GetCandidates = function()
			return getSwingCandidates(attackerState)
		end,
		IsStillValid = isAttackerStillCommitted(attackerState, rootPart, function()
			return attackerState.swingCancelled
		end),
		OnHit = function(hitCharacter: Model): boolean
			local counted, connected =
				onSwingHitCandidate(attackerPlayer, attackerState, definition, isHeavy, finisherVariant, hitCharacter)
			if counted and not hitLanded then
				hitLanded = true
				-- A normal basic hit connecting advances the landing-based basic combo, exactly once
				-- per swing (on the first target struck -- a swing can hit several, but it's one combo
				-- step). Gated on `connected` (not `counted`): a Parry is not a whiff, but
				-- it's even less of a "connect" than one -- the defender fully avoided or countered a
				-- resolved attack, so it must not advance the combo any more than a whiff would (see
				-- CombatState.basicComboLanded's own comment). Finisher swings never advance it (they
				-- reset the string at throw), and heavy swings use the separate throw-based
				-- comboIndex, so neither touches basicComboLanded regardless of `connected`.
				if connected and not isHeavy and finisherVariant == nil then
					attackerState.basicComboLanded =
						math.min(attackerState.basicComboLanded + 1, Constants.Combat.BasicComboLength - 1)
					attackerState.basicComboExpiry = os.clock() + Constants.Combat.ComboResetSeconds
				end
			end
			return counted
		end,
		OnComplete = function()
			if not hitLanded then
				-- The closest equivalent to the old single-shot resolver's "no target found" --
				-- with per-sample swept hitboxes there's no single instant to reject at, only
				-- "the whole swing came and went without landing on anyone."
				logger:debug(
					"Swing ended with no hits",
					{ player = attackerPlayer.Name, attack = definition.DebugName }
				)
			end
		end,
	})
end

-- The attacker's own punching hand, for HitboxResolver.SwingConfig's optional AttackerTrackedPart
-- (see that field's own header) -- throwDashPunch/throwDashHit are the only two callers, per this
-- game's own "right-handed" bias already established elsewhere (Constants.Camera.ShiftLock's
-- ShoulderOffset frames the camera over the RIGHT shoulder). R15's RightHand is the real target;
-- R6 has no per-limb hand part, so "Right Arm" (the whole limb) is the closest equivalent -- still
-- meaningfully closer to the fist than the root part it'd otherwise fall back to. Returns nil (and
-- the caller falls back to plain root-relative tracking, per HitboxResolver's own contract) for
-- any other rig shape, or if the character/limb is missing entirely.
local function resolveAttackHandPart(character: Model?): BasePart?
	if not character then
		logger:debug("resolveAttackHandPart: no character -- falling back to root-relative tracking")
		return nil
	end
	local rightHand = character:FindFirstChild("RightHand")
	if rightHand and rightHand:IsA("BasePart") then
		return rightHand
	end
	local rightArm = character:FindFirstChild("Right Arm")
	if rightArm and rightArm:IsA("BasePart") then
		return rightArm
	end
	-- Diagnostic for the "hitbox spawns far behind where it should" report -- if this ever fires,
	-- the rig has neither a "RightHand" nor a "Right Arm" direct child and every DashPunch/DashHit
	-- is silently falling all the way back to root-relative tracking (Offset applied from the
	-- torso center, not the hand), which is exactly what "too far back" looked like before hand
	-- tracking existed at all.
	logger:debug(
		"resolveAttackHandPart: neither RightHand nor Right Arm found -- falling back to root-relative tracking",
		{ character = character.Name }
	)
	return nil
end

-- Unifies throwDashPunch/throwDashHit/throwAirSlam -- DashPunch (a Dash that Movement.
-- ResolveDashDirection resolved as "Front," reported as a double-tap, AND cleared its own
-- dashPunchReadyAt cooldown -- handleDashRequest's dashPunchThrown gate), DashHit (the plain
-- forward dash's OWN attack, thrown on every Dash that resolves "Front" and isn't already throwing
-- DashPunch -- handleDashRequest's dashHitThrown gate), and AirSlam (jump + M1, thrown by
-- handleAirSlamRequest whenever a Basic-attack press lands while airborne, at any time, no M1 combo
-- prerequisite) used to be three independently hand-duplicated ~35-line functions differing only in
-- which Constants.Combat.* definition was passed, whether a finisherVariant went along with it, and
-- whether the IsStillValid check watched CombatState.swingCancelled. All three are deliberately NOT
-- calls into startAttackSwing: that function's OnHit wrapper advances CombatState.basicComboLanded
-- on every connecting non-heavy, non-finisher hit, which none of these three (each its own move, not
-- an M1 string stage) may ever do -- they reuse onSwingHitCandidate directly instead, the same
-- per-candidate dummy/bot/player dispatch and hit resolution every other swing goes through, just
-- without that M1-specific side effect.
--
-- checkSwingCancelled is per-move, not per-category: DashPunch/DashHit deliberately don't watch it
-- (handleFeintRequest's own header explains why those two stay out of Feint's scope), AirSlam does
-- (a successful Feint mid-windup should cancel it the same way it cancels startAttackSwing's own M1
-- swings). finisherVariant is nil for DashPunch/DashHit and always "Downslam" for AirSlam -- a clean
-- AirSlam hit reuses the exact same RagdollController.SlamToGround knockback (via HitResolution.
-- ApplyFinisherPhysics) and CombatAnimator Downslam-clip resolution the M1 finisher's own airborne
-- variant used to produce, with no new physics/animation plumbing needed. A blocked or parried
-- AirSlam never launches -- guarding is still the counter, same as every other finisher-variant hit
-- (combat-philosophy.md's "no true unblockable").
local function throwStandaloneAttack(
	attackerPlayer: Player,
	attackerState: CombatState,
	definition: Types.HitboxAttackDefinition,
	finisherVariant: Types.FinisherVariant?,
	checkSwingCancelled: boolean
): ()
	local rootPart = attackerState.rootPart
	if not rootPart then
		return
	end

	local hitLanded = false

	HitboxResolver.StartSwing({
		AttackerRootPart = rootPart,
		-- Tracks the attacker's own hand instead of a fixed root-relative offset -- see
		-- resolveAttackHandPart's own header and HitboxResolver.SwingConfig.AttackerTrackedPart's
		-- for why. nil (falls back to plain root-relative) on a rig with neither RightHand nor
		-- "Right Arm", which the caller never needs to special-case.
		AttackerTrackedPart = resolveAttackHandPart(attackerState.character),
		Definition = definition,
		GetCandidates = function()
			return getSwingCandidates(attackerState)
		end,
		IsStillValid = isAttackerStillCommitted(attackerState, rootPart, function()
			return checkSwingCancelled and attackerState.swingCancelled
		end),
		OnHit = function(hitCharacter: Model): boolean
			local counted =
				onSwingHitCandidate(attackerPlayer, attackerState, definition, false, finisherVariant, hitCharacter)
			hitLanded = hitLanded or counted
			return counted
		end,
		OnComplete = function()
			if not hitLanded then
				logger:debug(definition.DebugName .. " ended with no hits", { player = attackerPlayer.Name })
			end
		end,
	})
end

-- A bot's swing only ever has one possible target: its owner (a bot is a private sparring
-- partner, per the file header) -- so this is a trivial single-candidate version of
-- getSwingCandidates, not a reuse of it (that function's lock-on/multi-target ordering has no
-- meaning here).
local function getBotSwingCandidates(botState: BotState): { Model }
	local ownerState = combatStates[botState.ownerPlayer]
	if not ownerState or not ownerState.alive then
		return {}
	end
	if not ownerState.humanoid or ownerState.humanoid.Health <= 0 then
		return {}
	end
	if not ownerState.character or not ownerState.rootPart then
		return {}
	end
	return { ownerState.character }
end

-- Bot equivalent of onSwingHitCandidate -- same arc/line-of-sight validation, restricted to the
-- bot's own owner (getBotSwingCandidates already guarantees this, re-checked here for the same
-- "OnHit candidates come from a geometry query, not a trusted call site" reason
-- onSwingHitCandidate's own bot branch re-checks ownership).
local function onBotSwingHitCandidate(
	botState: BotState,
	definition: Types.HitboxAttackDefinition,
	isHeavy: boolean,
	hitCharacter: Model
): boolean
	local botRoot = botState.rootPart

	local targetPlayer = characterToPlayer[hitCharacter]
	if not targetPlayer or targetPlayer ~= botState.ownerPlayer then
		return false
	end
	local targetState = combatStates[targetPlayer]
	if not targetState or not targetState.alive then
		return false
	end
	local targetRoot = targetState.rootPart
	local targetCharacter = targetState.character
	if not targetRoot or not targetCharacter then
		return false
	end

	local isValid, rejectReason =
		HitResolution.IsSwingTargetValid(botRoot, botState.model, targetRoot, targetCharacter, definition.ArcDegrees)
	if not isValid then
		logger:debug(
			"Bot hit candidate rejected: " .. (rejectReason or "invalid"),
			{ bot = botState.model.Name, target = targetPlayer.Name }
		)
		return false
	end

	logger:info("Target selected (bot attacker)", {
		bot = botState.model.Name,
		target = targetPlayer.Name,
		attack = definition.DebugName,
		isHeavy = isHeavy,
	})

	resolveHitFromBotAgainstPlayer(botState, targetPlayer, targetState, definition, isHeavy)
	return true
end

-- Bot equivalent of startAttackSwing -- schedules the swept hitbox for one accepted bot attack via
-- the same HitboxResolver.StartSwing engine a player's own attack uses.
local function startBotAttackSwing(botState: BotState, definition: Types.HitboxAttackDefinition, isHeavy: boolean): ()
	local rootPart = botState.rootPart

	HitboxResolver.StartSwing({
		AttackerRootPart = rootPart,
		Definition = definition,
		GetCandidates = function()
			return getBotSwingCandidates(botState)
		end,
		-- See isAttackerStillCommitted's own header -- a bot has no swingCancelled field at all (a
		-- bot can't Feint), so this always passes a closure that returns false.
		IsStillValid = isAttackerStillCommitted(botState, rootPart, function()
			return false
		end),
		OnHit = function(hitCharacter: Model): boolean
			return onBotSwingHitCandidate(botState, definition, isHeavy, hitCharacter)
		end,
	})
end

--
-- Request handlers
--

-- Every request handler below is a distinct action a player can be mid-doing, gated by some
-- subset of the "universal" per-player locks -- Stunned, PostureBroken, Ragdolled, Disarmed.
-- These four are declared here as DATA rather than re-typed as an if-chain in every handler,
-- because that's exactly the shape of bug that already slipped through once this was audited:
-- handleSwapWeaponRequest never checked Stun/PostureBroken/Ragdoll at all (a stunned, staggered,
-- or physically ragdolled player could swap weapons), simply because nobody remembered to copy
-- those three lines in when the handler was written -- the same failure mode any hand-duplicated
-- gate is one edit away from repeating for the NEXT action this game adds (a Bloodline active, an
-- Art). One table, one place a reviewer checks when a new lock or a new action shows up.
--
-- Commitment (attackEndsAt) and each action's own specific cooldown are DELIBERATELY NOT in this
-- table -- they're not uniform "just reject" checks the way the four above are: Basic/Heavy
-- BUFFERS a too-early press instead of rejecting it (CombatState.bufferedAttack), and every
-- action reads its own cooldown field (basicAttackReadyAt vs. dashCooldownExpiry vs.
-- weaponSwapReadyAt, etc.) with its own failure handling. Forcing those into this table would
-- fight the real differences between actions instead of removing genuine duplication -- they stay
-- inline in each handler, exactly as before.
export type ActionCategory =
	"Basic"
	| "Heavy"
	| "BlockStart"
	| "Dash"
	| "Slide"
	| "SprintStart"
	| "SwapWeapon"
	| "LockOn"
	| "Feint"

-- Every row reproduces today's ACTUAL behavior exactly, transcribed from what each handler
-- checked before this table existed -- except SwapWeapon's Stun/PostureBroken/Ragdoll, which were
-- all false (unchecked) and are now true, closing the gap described above. Disarm is false for
-- everything except Basic/Heavy by design, not oversight -- CombatState.disarmedUntil's own
-- header: a disarmed player "isn't helpless, just can't deal damage," so Block/Dash/Sprint/
-- SwapWeapon/LockOn all stay available while disarmed. SprintStart's Stun/PostureBroken stay
-- false too -- Movement.ComputeDesiredWalkSpeed already refuses to apply the sprint speed tier
-- while stunned/posture-broken, so `sprinting` is a harmless stored intent even set mid-lockout
-- (see handleSprintStart's own comment). LockOn is fully unrestricted -- a passive targeting
-- choice, not an action that grants any advantage on its own.
--
-- BlockStart.Stun retuned true -> false (direct playtest feedback: "I get put in the combo once
-- and it's over, I barely have time to parry"). HitStunDuration (Constants.Combat) is 0.6s and
-- math.max-refreshes on every landed hit specifically so it survives a full combo's inter-hit gap
-- -- with BlockStart also gated by Stun, that meant a victim tagged by hit 1 of a combo could not
-- even ATTEMPT Block/Parry against hits 2-4, a true stun-lock with zero counterplay. That directly
-- contradicts combat-philosophy.md's reference point ("a real parry window," "aggression and
-- defense both viable") and its Balance principle 1 ("reflexes beat reads at the bottom" requires
-- an actual reflex opportunity to exist). Basic/Heavy/Dash/Slide/SwapWeapon stay gated by Stun --
-- the thing worth preventing was a stunned player counter-attacking or freely disengaging
-- (Dash/Slide away, weapon-swapping out) for zero risk, not a defensive Block/Parry ATTEMPT, which
-- is exactly the skill-expression this combat system is built around and can still whiff/fail on
-- bad timing like any other parry.
local ACTION_GATES: { [ActionCategory]: { Stun: boolean, PostureBroken: boolean, Ragdoll: boolean, Disarm: boolean } } =
	{
		Basic = { Stun = true, PostureBroken = true, Ragdoll = true, Disarm = true },
		Heavy = { Stun = true, PostureBroken = true, Ragdoll = true, Disarm = true },
		BlockStart = { Stun = false, PostureBroken = true, Ragdoll = true, Disarm = false },
		Dash = { Stun = true, PostureBroken = true, Ragdoll = true, Disarm = false },
		-- Same row as Dash -- Slide is a movement-only burst (no damage), gated identically.
		Slide = { Stun = true, PostureBroken = true, Ragdoll = true, Disarm = false },
		SprintStart = { Stun = false, PostureBroken = false, Ragdoll = true, Disarm = false },
		SwapWeapon = { Stun = true, PostureBroken = true, Ragdoll = true, Disarm = false },
		LockOn = { Stun = false, PostureBroken = false, Ragdoll = false, Disarm = false },
		-- Feint only ever matters while mid-swing, and every one of these three lockouts already ends
		-- the swing itself via startAttackSwing/throwAirSlam's own IsStillValid before a Feint press
		-- could reach it -- included here for the same "one table, no hand-duplicated exceptions"
		-- reason as every other row, not because a live conflict was found. Disarm stays false, same
		-- reasoning as Block/Dash/Slide -- cancelling your own swing isn't dealing damage.
		Feint = { Stun = true, PostureBroken = true, Ragdoll = true, Disarm = false },
	}

-- Shared prefix every request handler below starts with: rate-limit check, combatStates[player]
-- lookup/nil-guard, alive check, then the four universal locks ACTION_GATES says apply to
-- `category`. Returns the validated CombatState on success, or (nil, rejectionReason) on the
-- first failing check -- callers still own calling logRejected/rejectAndNotify themselves (this
-- helper doesn't know the caller's action name for logging). Commitment and each action's own
-- cooldown are NOT checked here -- see ACTION_GATES' own header for why those stay inline per
-- handler, in their original order, after this call.
local function checkCommonPreconditions(
	player: Player,
	rateLimiter: RateLimiter.RateLimiterInstance,
	category: ActionCategory
): (CombatState?, string?)
	if rateLimiter:IsLimited(player) then
		return nil, "RateLimited"
	end

	local state = combatStates[player]
	if not state then
		return nil, "NoCombatState"
	end
	if not state.alive then
		return nil, "NotAlive"
	end

	local gates = ACTION_GATES[category]
	local now = os.clock()
	if gates.Stun and now < state.stunExpiry then
		return nil, "Stunned"
	end
	if gates.PostureBroken and now < state.postureBrokenExpiry then
		return nil, "PostureBroken"
	end
	if gates.Ragdoll and now < state.ragdollExpiry then
		return nil, "Ragdolled"
	end
	if gates.Disarm and now < state.disarmedUntil then
		return nil, "Disarmed"
	end

	return state, nil
end

-- The ONE place activeActionKind is ever written. Every commitment-consuming handler below calls
-- this exactly once, at the same moment it commits attackEndsAt (or, for Dash/Slide, right after
-- Movement.ApplyDash/ApplySlide has written that action's own window field). This turns "Dash's
-- commitment happens to outlast its own window, and so does Slide's" from an emergent, tuning-
-- dependent coincidence into a structural guarantee: starting any kind that isn't dash-shaped
-- force-clears dashWindowExpiry, and starting any kind that isn't Slide force-clears
-- slideWindowExpiry, unconditionally, regardless of what Constants.Combat's Duration/Commitment
-- numbers happen to say this week. handleSwapWeaponRequest deliberately does NOT call this -- it
-- never sets attackEndsAt or opens a movement window (it only CHECKS attackEndsAt and gates on its
-- own weaponSwapReadyAt cooldown), so there is nothing here for it to tag or clear.
local function setActiveAction(state: CombatState, kind: CombatActionKind): ()
	state.activeActionKind = kind
	if kind ~= "Dash" and kind ~= "DashPunch" and kind ~= "DashHit" then
		state.dashWindowExpiry = 0
	end
	if kind ~= "Slide" then
		state.slideWindowExpiry = 0
	end
end

-- Shared "select the swing, commit cooldown/attackEndsAt, throw it" tail for both
-- handleAttackRequest's direct-press path and onHeartbeat's input-buffer flush -- see
-- CombatState.bufferedAttack's own comment for why a second call site exists. Callers are
-- responsible for every legality gate (alive/stun/posture-broken/ragdoll/disarm/cooldown/
-- commitment) having already passed before calling this; it only ever selects+commits+throws.
-- Grounded only -- handleAttackRequest routes an airborne Basic-attack press to
-- handleAirSlamRequest instead, so this never runs mid-air (see Constants.Combat.AirSlam's own
-- header). holdingJump is the client's report of whether the jump key was held at the ORIGINAL
-- click (only meaningful for a basic attack, and only consulted if this basic press lands as the
-- combo finisher). It's a low-stakes cosmetic-variant hint, not authoritative combat state -- a
-- finisher must still connect to do anything, so trusting the client here at most lets a cheater
-- pick uppercut over a normal finisher.
local function commitAndThrowAttack(
	player: Player,
	state: CombatState,
	isHeavy: boolean,
	holdingJump: boolean,
	now: number
): ()
	local action = if isHeavy then "HeavyAttack" else "BasicAttack"

	-- Select the swing. The combo stage has to be resolved before the cooldown is committed, since
	-- cooldown comes from the specific stage this throw uses, not a flat per-category number.
	-- HEAVY uses the throw-based combo counter (wraps over the Heavy stages). BASIC (M1) uses the
	-- landing-based finisher combo: the stage is basicComboLanded + 1, and once that reaches
	-- Constants.Combat.BasicComboLength the swing is the Finisher instead of a normal Basic stage.
	local definition: Types.HitboxAttackDefinition
	local finisherVariant: Types.FinisherVariant? = nil

	if isHeavy then
		resetHeavyComboIfLapsed(state, now)
		local nextComboIndex = math.min(state.comboIndex + 1, Constants.Combat.MaxComboStacks)
		definition = selectAttackDefinition(state.equippedWeaponId, true, nextComboIndex)
		state.comboIndex = nextComboIndex
		state.comboExpiry = now + Constants.Combat.ComboResetSeconds
	else
		resetBasicComboIfLapsed(state, now)
		local stageIndex = state.basicComboLanded + 1
		if stageIndex >= Constants.Combat.BasicComboLength then
			-- The finisher. This is only ever reached grounded -- handleAttackRequest intercepts an
			-- airborne Basic-attack press into the standalone AirSlam attack before combo-stage
			-- selection ever runs (see Constants.Combat.AirSlam's own header), so the attacker being
			-- airborne here is no longer a case this function needs to handle. Variant is chosen here:
			-- holding jump -> Uppercut, else Normal (see HitResolution.SelectFinisherVariant and
			-- Constants.Combat.Finisher for the full reasoning, including why Downslam no longer comes
			-- from this path). The basic string is reset now -- the finisher ends it whether or not it
			-- connects, so the next M1 starts a fresh combo at stage 1.
			local equippedWeapon = if state.equippedWeaponId == "Primary"
				then Constants.Combat.Weapons.Primary
				else Constants.Combat.Weapons.Secondary
			definition = equippedWeapon.Stages.Finisher
			finisherVariant = HitResolution.SelectFinisherVariant(holdingJump)
			state.basicComboLanded = 0
			state.basicComboExpiry = 0
		else
			definition = selectAttackDefinition(state.equippedWeaponId, false, stageIndex)
			-- Refresh the window so the combo stays alive while the player is actively swinging; a
			-- landed hit advances basicComboLanded (startAttackSwing's OnHit), a whiff leaves it be.
			state.basicComboExpiry = now + Constants.Combat.ComboResetSeconds
		end
	end

	local readyAgainAt = now + definition.Cooldown
	if isHeavy then
		state.heavyAttackReadyAt = readyAgainAt
	else
		state.basicAttackReadyAt = readyAgainAt
	end
	state.attackEndsAt = now + definition.WindupSeconds + definition.ActiveSeconds + definition.RecoverySeconds
	setActiveAction(state, if isHeavy then "Heavy" else "Basic")
	-- Deliberately does NOT refresh inCombatUntil here -- throwing a swing isn't "actively fighting
	-- somebody" on its own (a whiffed swing at nobody shouldn't flag combat). InCombat only refreshes
	-- from an actual exchange with a real opponent -- see CombatState.inCombatUntil's own header for
	-- the current trigger list (hit resolution against a player/bot, a parry-punish, an air-tech).
	-- Feint eligibility for THIS swing -- see handleFeintRequest/CombatState.swingCancelled's own
	-- headers. Reset on every fresh throw so a stale cancellation from a previous swing can never
	-- carry over onto this one.
	state.currentSwingWindupEndsAt = now + definition.WindupSeconds
	state.swingCancelled = false
	-- Committing to an attack drops an active guard -- the same "one stance at a time" rule
	-- Movement.ApplyDash already enforces for Dash (it also sets state.blocking = false).
	-- Deliberately a cancel, not a rejection: choosing to swing while your guard happens to be up is
	-- a legitimate offensive choice (a feint into a punish), unlike the reverse (handleBlockStart's
	-- own AlreadyAttacking check), which stays a hard reject -- you can't cancel a swing you're
	-- already committed to into a free guard.
	state.blocking = false

	logAccepted(action, player, {
		attack = definition.DebugName,
		finisher = finisherVariant,
		damage = definition.Damage,
		postureDamage = definition.PostureDamage,
	})

	-- No sendVitals here: the attacker spends no resource at throw time now that Stamina is gone, so
	-- their vitals are unchanged until a hit actually resolves (which syncs the target, not them).
	sendAttackStarted(player, definition, isHeavy, state.equippedWeaponId, finisherVariant)
	startAttackSwing(player, state, definition, isHeavy, finisherVariant)
end

-- Whether `humanoid` counts as airborne for the jump+M1 AirSlam intercept below.
-- Humanoid.FloorMaterial alone (checked here in an earlier pass) is a physics/raycast-derived
-- property that lags a few ticks behind the actual jump input -- and worse server-side, since this
-- reads the replicated copy of a client-owned Humanoid, stacking network replication latency on top
-- of that physical-detection latency. That lag is what made "jump then click" only register when
-- mashing both keys: a press fired the instant Space is pressed almost always arrived before
-- FloorMaterial had actually flipped to Air. Humanoid:GetState() transitioning to Jumping fires the
-- instant the character controller processes the jump input, before physics has moved the character
-- at all, so treating Jumping (the initial upward impulse) OR Freefall (already airborne, e.g. off a
-- ledge with no jump input) as airborne -- FloorMaterial == Air stays as a fallback for any state
-- this doesn't cover -- is what makes a single, normally-timed jump + click register reliably.
local function isAirborneForAirSlam(humanoid: Humanoid): boolean
	if humanoid.FloorMaterial == Enum.Material.Air then
		return true
	end
	local state = humanoid:GetState()
	return state == Enum.HumanoidStateType.Jumping or state == Enum.HumanoidStateType.Freefall
end

-- Jump + M1 ("AirSlam"): a Basic-attack press made while airborne, at ANY time -- no M1 combo
-- prerequisite -- throws the standalone AirSlam attack instead of continuing/starting the grounded
-- M1 string. Modeled on handleDashRequest's own DashPunch commit tail: its own real cooldown
-- (CombatState.airSlamReadyAt), no input buffering (a too-early press just rejects outright, the
-- same simplicity Dash's own cooldown gate uses -- this move is rare/cooldown-gated enough that
-- smoothing a few-frames-early press isn't worth the buffered-attack machinery the grounded M1
-- string needs), and it never touches basicComboLanded/basicAttackReadyAt -- see throwAirSlam's own
-- header. rejectedKind/action stay "Basic"/"BasicAttack" throughout so the client's existing
-- Combat_ActionRejected handling (which only recognizes "Basic"/"Heavy"/"Dash"/"BlockStart") cancels
-- the predicted swing correctly -- see Types.RejectedActionKind's own header.
local function handleAirSlamRequest(player: Player, state: CombatState, now: number): ()
	if now < state.airSlamReadyAt or now < state.attackEndsAt then
		rejectAndNotify(
			"BasicAttack",
			"Basic",
			player,
			if now < state.airSlamReadyAt then "AirSlamCooldownActive" else "AlreadyAttacking"
		)
		return
	end

	local definition = Constants.Combat.AirSlam
	state.attackEndsAt = now + definition.WindupSeconds + definition.ActiveSeconds + definition.RecoverySeconds
	setActiveAction(state, "AirSlam")
	-- Deliberately does NOT refresh inCombatUntil at throw time -- see commitAndThrowAttack's
	-- identical comment; only an actual landed exchange does.
	state.airSlamReadyAt = now + definition.Cooldown
	-- Feint eligibility for THIS swing -- see commitAndThrowAttack's identical set and
	-- CombatState.swingCancelled's own header.
	state.currentSwingWindupEndsAt = now + definition.WindupSeconds
	state.swingCancelled = false
	-- Same "committing to an attack drops an active guard" rule commitAndThrowAttack/Movement.ApplyDash
	-- already enforce for every other action.
	state.blocking = false

	logAccepted("BasicAttack", player, {
		attack = definition.DebugName,
		damage = definition.Damage,
		postureDamage = definition.PostureDamage,
	})

	-- FinisherVariant = "Downslam" unconditionally -- lets the existing Combat_AttackStarted/
	-- CombatAnimator plumbing (finisherTrackName) pick the ground-slam clip with no new animation
	-- wiring; see Constants.Combat.AirSlam's own header.
	sendAttackStarted(player, definition, false, state.equippedWeaponId, "Downslam")
	throwStandaloneAttack(player, state, definition, "Downslam", true)
end

-- The suspended victim's own one-shot counter-punch -- redirected here from handleAttackRequest's
-- Basic-attack path while CombatState.airComboSuspendedUntil is active (see that field's own header
-- and the interception in handleAttackRequest below, which mirrors how an ordinary airborne press
-- already redirects into AirSlam). Deliberately NOT hitbox-timed like a real swing: the "target" of
-- this punch is a specific known entity (airComboSuspendedWithAttacker), not found via arc/overlap
-- sampling, so it resolves instantly -- the same "nothing to time a window against" shape the
-- air-tech's own punish already uses. Always ends the suspended exchange afterward regardless of
-- outcome (hit/blocked/parried) -- a one-shot make-or-break moment, not a repeatable option.
local function handleSuspendedCounterPunchRequest(player: Player, state: CombatState, now: number): ()
	local attackerPlayer = state.airComboSuspendedWithAttacker
	local attackerState = if attackerPlayer then combatStates[attackerPlayer] else nil
	if not attackerPlayer or not attackerState or not attackerState.alive then
		-- The attacker already left/died mid-exchange -- just drop the victim back to normal footing.
		endSuspendedAirComboExchange(player, state, attackerPlayer, attackerState)
		logRejected("BasicAttack", player, "SuspendedAttackerGone")
		return
	end

	-- "Only if the attacker is not hitting them" -- the attacker's own commitment lock is the same
	-- signal every OTHER action already reads to mean "currently mid-swing."
	if now < attackerState.attackEndsAt then
		logRejected("BasicAttack", player, "AttackerStillSwinging")
		return
	end

	local attackerHumanoid = attackerState.humanoid
	if not attackerHumanoid then
		endSuspendedAirComboExchange(player, state, attackerPlayer, attackerState)
		logRejected("BasicAttack", player, "AttackerMissingHumanoid")
		return
	end

	-- Still fully parryable/blockable by the attacker -- everything stays parryable, including this.
	local defenseKind = HitResolution.ClassifyDefense(
		now,
		attackerState.postureBrokenExpiry,
		attackerState.parryWindowExpiry,
		attackerState.blocking
	)

	if defenseKind == "Parry" then
		attackerState.parryWindowExpiry = 0
		HitResolution.ApplyParryPunish(state, now)
		sendVitals(player, state)
		local parryPayload = buildFeedbackPayload("Parried", player, attackerPlayer, nil, nil, false)
		sendFeedback(player, parryPayload)
		sendFeedback(attackerPlayer, parryPayload)
	else
		local damageMultiplier = if defenseKind == "Block" then Constants.Combat.BlockDamageMultiplier else 1
		local postureMultiplier = if defenseKind == "Block" then Constants.Combat.BlockPostureMultiplier else 1
		local finalDamage = Constants.Combat.AirCombo.SuspendedCounterDamage * damageMultiplier
		local finalPosture = Constants.Combat.AirCombo.SuspendedCounterPostureDamage * postureMultiplier
		if attackerState.godmode then
			finalDamage = 0
			finalPosture = 0
		end

		local wasPostureBroken = now < attackerState.postureBrokenExpiry
		attackerState.posture = math.max(0, attackerState.posture - finalPosture)
		if attackerHumanoid.Health - finalDamage <= 0 then
			attackerState.pendingKillerUserId = player.UserId
		end
		if finalDamage > 0 then
			attackerHumanoid:TakeDamage(finalDamage)
		end
		sendVitals(attackerPlayer, attackerState)

		local kind: Types.CombatFeedbackKind = if defenseKind == "Block" then "Blocked" else "Hit"
		local hitPayload = buildFeedbackPayload(
			kind,
			player,
			attackerPlayer,
			finalDamage,
			finalPosture,
			false,
			nil,
			"SuspendedCounter"
		)
		sendFeedback(player, hitPayload)
		sendFeedback(attackerPlayer, hitPayload)

		if attackerState.posture <= 0 and not wasPostureBroken then
			triggerPostureBreak(attackerPlayer, attackerState, player)
			sendVitals(attackerPlayer, attackerState)
		end
	end

	state.inCombatUntil = now + Constants.Combat.InCombatDurationSeconds
	attackerState.inCombatUntil = now + Constants.Combat.InCombatDurationSeconds

	endSuspendedAirComboExchange(player, state, attackerPlayer, attackerState)
	logAccepted("BasicAttack", player, { attack = "SuspendedCounter", defended = defenseKind })
end

local function handleAttackRequest(player: Player, isHeavy: boolean, holdingJump: boolean): ()
	local action = if isHeavy then "HeavyAttack" else "BasicAttack"
	local rejectedKind: Types.RejectedActionKind = if isHeavy then "Heavy" else "Basic"
	logReceived(action, player)

	local state, rejectReason = checkCommonPreconditions(player, attackRateLimiter, rejectedKind)
	if not state then
		rejectAndNotify(action, rejectedKind, player, rejectReason :: string)
		return
	end
	if not state.character then
		rejectAndNotify(action, rejectedKind, player, "MissingCharacter")
		return
	end
	local humanoid = state.humanoid
	if not humanoid then
		rejectAndNotify(action, rejectedKind, player, "MissingHumanoid")
		return
	end
	if not state.rootPart then
		rejectAndNotify(action, rejectedKind, player, "MissingRootPart")
		return
	end
	if humanoid.Health <= 0 then
		rejectAndNotify(action, rejectedKind, player, "HumanoidHealthNonPositive")
		return
	end

	-- Stun/PostureBroken/Ragdoll/Disarm already rejected above (checkCommonPreconditions,
	-- ACTION_GATES.Basic/Heavy) -- only commitment/cooldown are left to check here.
	local now = os.clock()

	-- Suspended counter-punch: a Basic-attack press while CombatState.airComboSuspendedUntil is
	-- active (a successfully-teched air-combo victim, still held aloft next to the attacker)
	-- redirects here instead of the grounded M1 string or AirSlam -- see
	-- handleSuspendedCounterPunchRequest's own header. Heavy is unaffected (only a Basic press can
	-- throw this, same scoping AirSlam itself uses). Checked BEFORE the AirSlam intercept below --
	-- a suspended player also reads as airborne-for-AirSlam (the same HoldAloft-never-clears-
	-- FloorMaterial reasoning that exemption's own comment documents), so without this check first a
	-- suspended player's Basic press would be hijacked into an ill-fitting AirSlam instead of the
	-- intended counter-punch.
	if not isHeavy and now < state.airComboSuspendedUntil then
		handleSuspendedCounterPunchRequest(player, state, now)
		return
	end

	-- Jump + M1: route an airborne Basic-attack press to the standalone AirSlam attack instead of
	-- the grounded M1 string -- see handleAirSlamRequest's/isAirborneForAirSlam's own headers. Heavy
	-- attacks are unaffected (only a Basic press can throw this).
	--
	-- EXEMPT while the attacker is mid-air-combo (state.airComboTarget OR state.airComboDummyTarget
	-- still set -- CombatState.airComboDummyTarget's own header: a Model-target training-dummy
	-- sequence is a parallel mechanic to the real-player one, both driven by the same unified
	-- applyAirCombo (AirComboTarget adapter picks which shape applies), sharing this SAME
	-- airComboExpiry field but tracking their target on separate fields -- missing either one here
	-- left solo dummy practice hitting the exact bug this whole check exists to fix), within its own
	-- airComboExpiry: applyAirCombo's DashPunch-start branch holds the ATTACKER's own body aloft too
	-- (RagdollController.HoldAloft), and that hold never restores Humanoid.FloorMaterial to solid
	-- ground -- so isAirborneForAirSlam reads true for the attacker's own follow-up M1 presses just
	-- as much as it does for a genuine jump. Without this exemption every M1 meant to CONTINUE the
	-- juggle (the non-DashPunch branch, reached via commitAndThrowAttack below) never got a chance to
	-- fire -- it was hijacked into AirSlam/Downslam first, every time, turning a double-tap-W
	-- (DashPunch) opener followed by M1 into "dash then instantly downslam" instead of an actual
	-- juggle. A real standalone jump+M1 (both target fields nil) is untouched by this check and still
	-- routes to AirSlam exactly as before.
	local inAirCombo = (state.airComboTarget ~= nil or state.airComboDummyTarget ~= nil) and now <= state.airComboExpiry
	if not isHeavy and not inAirCombo and isAirborneForAirSlam(humanoid) then
		handleAirSlamRequest(player, state, now)
		return
	end

	-- Cooldown/commitment: too early, not otherwise illegal -- buffer instead of dropping outright
	-- (CombatState.bufferedAttack's own comment has the full reasoning). onHeartbeat's flush check
	-- throws it automatically the instant this same gate opens, re-validating every other gate
	-- again at that point since state can change during the buffered window. Getting hit is NOT a
	-- bufferable reason here -- it already hard-rejected above via checkCommonPreconditions'
	-- ACTION_GATES.Stun check (Constants.Combat.HitStunDuration), a real lockout rather than a
	-- press that quietly queues up and auto-fires the instant the stun clears.
	local readyAt = if isHeavy then state.heavyAttackReadyAt else state.basicAttackReadyAt
	if now < readyAt or now < state.attackEndsAt then
		state.bufferedAttack = {
			IsHeavy = isHeavy,
			HoldingJump = holdingJump,
			ExpiresAt = now + Constants.Combat.AttackInputBufferSeconds,
		}
		logRejected(action, player, if now < readyAt then "CooldownActive" else "AlreadyAttacking", {
			remainingSeconds = math.max(readyAt, state.attackEndsAt) - now,
			buffered = true,
		})
		return
	end

	-- A legitimately-accepted press right now supersedes anything still buffered from an earlier,
	-- already-superseded press.
	state.bufferedAttack = nil
	commitAndThrowAttack(player, state, isHeavy, holdingJump, now)
end

-- Feint (right-click, RequestFeint): cancels the player's OWN Basic/Heavy/Finisher/AirSlam swing
-- while it's still telegraphing (WindupSeconds), before the hitbox can ever go active -- a mind-game
-- tool per combat-philosophy.md's "reads beat reflexes," not a free escape hatch. Legality is a
-- single timestamp check (CombatState.currentSwingWindupEndsAt, set at the same throw sites that set
-- attackEndsAt -- commitAndThrowAttack/handleAirSlamRequest); a successful feint sets swingCancelled
-- (read by startAttackSwing/throwAirSlam's own IsStillValid, which ends the swing before its next
-- sample -- see that field's own header in CombatTypes.lua) and shortens attackEndsAt to
-- Constants.Combat.Feint.RecoverySeconds instead of clearing it outright. The swing's own cooldown
-- (basicAttackReadyAt/heavyAttackReadyAt/airSlamReadyAt, already committed at throw time) is
-- deliberately left untouched -- a feinted attack still costs its real cooldown, so baiting with the
-- same attack slot repeatedly isn't free.
--
-- Deliberately scoped to Basic/Heavy/Finisher/AirSlam only -- NOT Dash/DashPunch/DashHit/Slide.
-- Those four are movement-integrated: their commitment is tied to a real Humanoid.WalkSpeed burst
-- (Movement.ApplyDash/ApplySlide), not a stationary telegraph, so "cancel the attack" has no clean
-- meaning that doesn't also mean "cancel the movement" -- a different mechanic this pass doesn't
-- add. handleDashRequest never sets currentSwingWindupEndsAt, so a Feint attempted mid-dash simply
-- rejects NotInWindup, identically to attempting one with no attack in progress at all.
--
-- Unlike Basic/Heavy/Dash/BlockStart/Slide, Feint has no predict-then-rollback pair -- no
-- Combat_ActionRejected case, just a plain logRejected on failure. The client's own local cancel of
-- its currently-playing swing animation (CombatAnimator.CancelActiveSwing) fires unconditionally at
-- press time and is always safe regardless of whether the server accepts this request (see
-- CombatClient.lua's Feint input branch), so a genuine reject leaves nothing to roll back.
local function handleFeintRequest(player: Player): ()
	logReceived("Feint", player)

	local state, rejectReason = checkCommonPreconditions(player, defensiveRateLimiter, "Feint")
	if not state then
		logRejected("Feint", player, rejectReason :: string)
		return
	end

	local now = os.clock()
	if now >= state.currentSwingWindupEndsAt then
		logRejected("Feint", player, "NotInWindup")
		return
	end

	state.swingCancelled = true
	state.attackEndsAt = now + Constants.Combat.Feint.RecoverySeconds
	setActiveAction(state, "Feint")

	logAccepted("Feint", player, { recoverySeconds = Constants.Combat.Feint.RecoverySeconds })
	sendFeintPerformed(player, Constants.Combat.Feint.RecoverySeconds)
end

-- Block and Parry are the same physical input (combat-philosophy.md's "Established systems" list
-- names Block/Parry/Disarm as one formal defensive layer; merging their input was an explicit
-- design request, not a unilateral redesign). Every accepted block press starts a plain block AND,
-- unless the parry-specific cooldown gate below rejects it, also opens a short parry
-- window at the start of that press (Constants.Combat.ParryWindowSeconds) -- a hit landing inside
-- that window is a parry (see resolveHitAgainstTarget's targetIsParrying check, which is unchanged
-- by this merge: it only cares whether now <= parryWindowExpiry, not how that field got set), and
-- a hit landing after the window closes but while still held is a normal block. Failing the
-- parry-availability gate never blocks the block itself -- a player who isn't off cooldown for a
-- parry attempt can still hold a plain block.
local function handleBlockStart(player: Player): ()
	logReceived("BlockStart", player)

	local state, rejectReason = checkCommonPreconditions(player, defensiveRateLimiter, "BlockStart")
	if not state then
		rejectAndNotify("BlockStart", "BlockStart", player, rejectReason :: string)
		return
	end
	local now = os.clock()
	-- Can't block while committed to your own swing (windup/active/recovery) -- edge case #10:
	-- "player tries to block during attack recovery."
	if now < state.attackEndsAt then
		rejectAndNotify("BlockStart", "BlockStart", player, "AlreadyAttacking")
		return
	end

	state.blocking = true
	setActiveAction(state, "BlockStart")
	-- Deliberately does NOT refresh inCombatUntil here -- raising Block with nobody actually
	-- attacking you isn't "actively fighting somebody." If this block goes on to actually stop a
	-- real incoming hit, that lands through resolveHitAgainstTarget's own refresh (both sides,
	-- "regardless of outcome (hit/blocked/parried)") -- see CombatState.inCombatUntil's own header.

	-- Parry availability is now purely a cooldown gate (Stamina is gone) -- every press that's off
	-- cooldown opens a parry window; one that isn't still starts a plain block. No sendVitals: opening
	-- a parry window changes no vital now that it costs nothing.
	local parryAvailable = now >= state.parryCooldownExpiry
	if parryAvailable then
		-- Ping compensation: the press physically happened ~ping ago on the client but only arrived
		-- now, so extend the window by the player's (capped) ping to give a laggy player back the
		-- time their connection ate -- see Constants.Combat.ParryPingCompensationMaxSeconds. Bots
		-- skip this (RequestBotBlockStart has no player/ping).
		local ping = 0
		local ok, pingValue = pcall(function()
			return player:GetNetworkPing()
		end)
		if ok and typeof(pingValue) == "number" then
			ping = math.clamp(pingValue, 0, Constants.Combat.ParryPingCompensationMaxSeconds)
		end
		state.parryWindowExpiry = now + Constants.Combat.ParryWindowSeconds + ping
		state.parryCooldownExpiry = now + Constants.Combat.ParryCooldownSeconds
		-- Broadcast the OBVIOUS, synced-for-all tell (bright highlight on this player, visible to
		-- everyone including their attacker).
		if state.character then
			broadcastParryWindowOpened(state.character)
		end
	end

	sendBlockStarted(player, parryAvailable)
	logAccepted("BlockStart", player, { parryWindowOpened = parryAvailable })
end

-- Deliberately NOT rate-limited, same reasoning as handleSprintStop below: honoring a release must
-- never fail, or a throttled BlockStop would leave state.blocking stuck true and the player unable
-- to drop their guard after they released the input. (BlockStart is rate-limited; a dropped start
-- just means no block, which is safe. A dropped stop is not.)
local function handleBlockStop(player: Player): ()
	logReceived("BlockStop", player)

	local state = combatStates[player]
	if not state then
		logRejected("BlockStop", player, "NoCombatState")
		return
	end
	state.blocking = false
	-- Releasing the block button early cancels any still-open parry window -- dropping your guard
	-- shouldn't leave a "free" parry chance hanging past the input that was supposed to end it.
	state.parryWindowExpiry = 0
	logAccepted("BlockStop", player)
end

local function handleLockOnRequest(player: Player, rawTargetUserId: unknown): ()
	logReceived("LockOn", player, { rawTargetUserId = rawTargetUserId })

	local state, rejectReason = checkCommonPreconditions(player, utilityRateLimiter, "LockOn")
	if not state then
		logRejected("LockOn", player, rejectReason :: string)
		return
	end
	if not state.rootPart then
		logRejected("LockOn", player, "MissingRootPart")
		return
	end

	if rawTargetUserId == nil then
		if state.lockOnTarget ~= nil then
			logAccepted("LockOn", player, { targetUserId = "nil (cleared)" })
			state.lockOnTarget = nil
			sendLockOnChanged(player, nil)
		else
			logRejected("LockOn", player, "AlreadyClear")
		end
		return
	end

	if typeof(rawTargetUserId) ~= "number" then
		logRejected("LockOn", player, "InvalidLockOnTarget", { payloadType = typeof(rawTargetUserId) })
		return
	end
	local targetUserId = rawTargetUserId :: number
	if targetUserId == player.UserId then
		logRejected("LockOn", player, "InvalidLockOnTarget", { note = "self" })
		return
	end

	local targetPlayer = Players:GetPlayerByUserId(targetUserId)
	if not targetPlayer then
		logRejected("LockOn", player, "InvalidLockOnTarget", { note = "player not found", targetUserId = targetUserId })
		return
	end

	local targetState = combatStates[targetPlayer]
	if not targetState or not isValidHostileTarget(state, targetState) then
		logRejected("LockOn", player, "InvalidLockOnTarget", { note = "not hostile/alive", target = targetPlayer.Name })
		return
	end

	local targetRoot = targetState.rootPart :: BasePart
	local attackerRoot = state.rootPart :: BasePart
	local distance = (targetRoot.Position - attackerRoot.Position).Magnitude
	if distance > Constants.Combat.LockOnRange then
		logRejected(
			"LockOn",
			player,
			"OutOfLockOnRange",
			{ distance = distance, range = Constants.Combat.LockOnRange, target = targetPlayer.Name }
		)
		return
	end

	logAccepted("LockOn", player, { target = targetPlayer.Name, targetUserId = targetUserId, distance = distance })

	state.lockOnTarget = targetPlayer
	sendLockOnChanged(player, targetUserId)
end

-- Weapon switching (combat-philosophy.md's "Established systems" list names this alongside
-- Lock-on/Block/Parry/Posture): a one-shot toggle between Constants.Combat.Weapons.Primary/
-- Secondary, gated by SwapCooldownSeconds so instant weapon-cycling can't be used as a combo
-- exploit -- exactly the purpose that doc names for the cooldown. Rate-limited under the utility
-- bucket (alongside LockOn/SprintStart), not the combat-critical one: swapping isn't a
-- latency-sensitive action the way Attack/Block/Dash are. Resets the in-progress combo counters on
-- a successful swap -- a weapon change is a different moveset with different stage arrays, so
-- carrying stage progress from the old weapon into the new one's Basic1/Heavy1 wouldn't mean
-- anything. Bots are not covered by this handler -- BotState has no equippedWeaponId field, and
-- TrainingBotSystem's AI loop never calls this; bots stay on Constants.Combat.Weapons.Default
-- permanently, matching this codebase's existing precedent that bots already lack several
-- player-only systems (sprint, lock-on). Gated by ACTION_GATES.SwapWeapon on
-- Stun/PostureBroken/Ragdoll (checkCommonPreconditions) -- a stunned, staggered, or physically
-- ragdolled player picking a new weapon made no sense mechanically or narratively, and nothing
-- here ever checked for it before this table existed. Deliberately does NOT call setActiveAction --
-- swapping never sets attackEndsAt or opens a dash/slide movement window (it only checks
-- attackEndsAt via ACTION_GATES/its own weaponSwapReadyAt cooldown), so there is no window field
-- for it to tag or force-close. Not a missed call site.
local function handleSwapWeaponRequest(player: Player): ()
	logReceived("SwapWeapon", player)

	local state, rejectReason = checkCommonPreconditions(player, utilityRateLimiter, "SwapWeapon")
	if not state then
		logRejected("SwapWeapon", player, rejectReason :: string)
		return
	end

	local now = os.clock()
	-- Can't swap mid-swing-commitment -- same commitment lock every other action already respects.
	if now < state.attackEndsAt then
		logRejected("SwapWeapon", player, "AlreadyAttacking", { remainingSeconds = state.attackEndsAt - now })
		return
	end
	if now < state.weaponSwapReadyAt then
		logRejected("SwapWeapon", player, "SwapCooldownActive", { remainingSeconds = state.weaponSwapReadyAt - now })
		return
	end

	local newWeaponId: Types.WeaponId = if state.equippedWeaponId == "Primary" then "Secondary" else "Primary"
	state.equippedWeaponId = newWeaponId
	state.weaponSwapReadyAt = now + Constants.Combat.Weapons.SwapCooldownSeconds
	state.comboIndex = 0
	state.basicComboLanded = 0
	state.basicComboExpiry = 0

	logAccepted("SwapWeapon", player, { weaponId = newWeaponId })
	sendWeaponChanged(player, newWeaponId)
end

-- Dash: the neutral-game positioning burst (the RequestDash remote / Dash key). No i-frame window
-- (dashWindowExpiry is a pure WalkSpeed burst), gated by its own cooldown and the shared
-- commitment lock (alive/stunned/posture-broken/commitment-lock pre-checks). Reuses attackEndsAt
-- as the shared commitment lock (so handleAttackRequest/handleBlockStart need no changes to reject
-- a new action mid-dash), and sends no direction -- the player's own movement input carries them,
-- and onHeartbeat's unified Movement.ComputeDesiredWalkSpeed drives the WalkSpeed burst off the
-- window timer rather than any task.delay here.
--
-- A forward-resolved Dash (Movement.ResolveDashDirection returns "Front") always ends with a
-- hitbox -- TWO SEPARATE attacks share that one moment, mutually exclusive per press:
--
--   * DashPunch -- the rarer, deliberate one. Only thrown when this press was ALSO a genuine
--     double-tap-forward (rawViaDoubleTapForward below) AND DashPunch's own dashPunchReadyAt
--     cooldown has cleared. Gets the longer DashFront* duration/commitment (a real lunge, not a
--     step), deals real damage/posture, and opens the air combo on a clean connect
--     (applyAirCombo's own "debugName == 'DashPunch'" check). See Constants.Combat.DashPunch's own
--     header for why this needs its own stricter cooldown, independent of Dash's own. A
--     double-tap-forward press while THIS cooldown is still active is fully rejected below (no
--     movement, no fallback hit) -- it does not fall through to DashHit.
--   * DashHit -- the ordinary one. Thrown on every OTHER forward dash that isn't a double-tap --
--     no double-tap needed, gated only by Dash's own plain movement cooldown. Same plain
--     DashDurationSeconds movement burst as a non-front dash (it's not a bigger lunge, just an
--     ordinary dash that happens to end with a lighter hit), weaker damage/posture than DashPunch,
--     and never opens the air combo (its own DebugName never matches DashPunch's launch
--     condition). See Constants.Combat.DashHit's own header.
--
-- rawViaDoubleTapForward is client-reported: whether THIS press came from the double-tap-W trigger
-- (CombatClient.lua) rather than the plain Dash keybind -- the same trust tier as
-- handleAttackRequest's holdingJump (a client-reported, hard-to-fully-verify gesture hint, not
-- server-derived truth like Movement.ResolveDashDirection's MoveDirection read). A dishonest client
-- claiming double-tap on every press only ever gets DashPunch at most once per dashPunchReadyAt's
-- own cooldown, identical to what an honest player gets from genuinely double-tapping that often --
-- but now COSTS them every OTHER forward press while that cooldown is active, since a claimed
-- double-tap rejects outright instead of falling back to DashHit the way an honest (non-double-tap)
-- press still would. Lying about this flag never gains anything and can only lose the DashHit
-- fallback, so there's no incentive to do it. Invalid/missing values fail closed (treated as
-- false, DashHit's case).
local function handleDashRequest(player: Player, rawViaDoubleTapForward: unknown): ()
	logReceived("Dash", player)

	local state, rejectReason = checkCommonPreconditions(player, defensiveRateLimiter, "Dash")
	if not state then
		rejectAndNotify("Dash", "Dash", player, rejectReason :: string)
		return
	end

	local now = os.clock()
	if now < state.attackEndsAt then
		rejectAndNotify("Dash", "Dash", player, "AlreadyAttacking")
		return
	end

	local viaDoubleTapForward = rawViaDoubleTapForward == true

	if now < state.dashCooldownExpiry then
		rejectAndNotify(
			"Dash",
			"Dash",
			player,
			"DashCooldownActive",
			{ remainingSeconds = state.dashCooldownExpiry - now }
		)
		return
	end
	-- Shared with Slide -- see CombatState.movementCooldownExpiry's own header. Catches the case
	-- Dash's own cooldown alone can't: a Slide fired recently enough that ALTERNATING would have
	-- renewed faster than either move's own designed pace.
	if now < state.movementCooldownExpiry then
		rejectAndNotify(
			"Dash",
			"Dash",
			player,
			"MovementCooldownActive",
			{ remainingSeconds = state.movementCooldownExpiry - now }
		)
		return
	end

	-- Direction is nil (never "Front") for a stationary Dash press with no held movement key -- see
	-- Movement.ResolveDashDirection's own header for why that must NOT count as a front dash (no
	-- actual dash happened to close the distance either attack's Offset assumes).
	local direction = Movement.ResolveDashDirection(state)
	local isFrontDash = direction == "Front"
	-- A genuine double-tap on a forward dash is DashPunch's own attack attempt, gated by its own
	-- attack-shaped cooldown (dashPunchReadyAt) -- a separate, stricter gate than Dash's own movement
	-- cooldown already checked above. This fully rejects the press (no fallback to DashHit): a
	-- double-tap while DashPunch is on cooldown should do nothing, not quietly land a consolation
	-- hit.
	local attemptedFrontDash = isFrontDash and viaDoubleTapForward
	if attemptedFrontDash and now < state.dashPunchReadyAt then
		rejectAndNotify(
			"Dash",
			"Dash",
			player,
			"DashPunchCooldownActive",
			{ remainingSeconds = state.dashPunchReadyAt - now }
		)
		return
	end

	local dashPunchThrown = attemptedFrontDash
	-- The ordinary attack: every OTHER forward dash -- no double-tap needed, no separate cooldown
	-- beyond Dash's own (already checked above).
	local dashHitThrown = isFrontDash and not dashPunchThrown
	local isBackDash = direction == "Back"

	Movement.ApplyDash(state, now, dashPunchThrown, isBackDash)
	setActiveAction(state, if dashPunchThrown then "DashPunch" elseif dashHitThrown then "DashHit" else "Dash")
	-- Neither branch below refreshes inCombatUntil at throw time -- a whiffed DashPunch/DashHit is
	-- still just "throwing a punch," not "actively fighting somebody." throwStandaloneAttack's own
	-- OnHit routes an actual landed hit through onSwingHitCandidate -> the same resolveHit* functions
	-- commitAndThrowAttack's swings use, which already refresh InCombat on a real connect -- see
	-- CombatState.inCombatUntil's own header.
	if dashPunchThrown then
		throwStandaloneAttack(player, state, Constants.Combat.DashPunch, nil, false)
		state.dashPunchReadyAt = now + Constants.Combat.DashPunch.Cooldown
	elseif dashHitThrown then
		throwStandaloneAttack(player, state, Constants.Combat.DashHit, nil, false)
		-- Movement.ApplyDash already set attackEndsAt to the plain DashCommitmentSeconds (it was
		-- called with dashPunchThrown = false) -- extend it to cover DashHit's own active+recovery
		-- tail so the player can't act again mid-recovery, the same "commitment has to span the
		-- whole hit" reasoning DashFrontCommitmentSeconds already applies to DashPunch.
		state.attackEndsAt = now + Constants.Combat.DashHitCommitmentSeconds
	end

	local durationSeconds = if dashPunchThrown
		then Constants.Combat.DashFrontDurationSeconds
		else Constants.Combat.DashDurationSeconds
	local commitmentSeconds = if dashPunchThrown
		then Constants.Combat.DashFrontCommitmentSeconds
		elseif dashHitThrown then Constants.Combat.DashHitCommitmentSeconds
		else Constants.Combat.DashCommitmentSeconds
	-- Echoed so the client's mirrored dashCooldownExpiry matches what Movement.ApplyDash actually
	-- just committed -- a back-dash's own longer DashBackCooldownSeconds, otherwise the plain
	-- DashCooldownSeconds. Without this the client would always mirror the SHORT constant regardless
	-- of direction, predicting a back-dash "ready again" well before the server's own real gate
	-- clears -- a real, avoidable misprediction/rollback (same reasoning AttackStartedPayload's own
	-- CooldownSeconds field already documents).
	local cooldownSeconds = if isBackDash
		then Constants.Combat.DashBackCooldownSeconds
		else Constants.Combat.DashCooldownSeconds

	logAccepted("Dash", player, {
		direction = direction,
		attemptedFrontDash = attemptedFrontDash,
		dashPunchThrown = dashPunchThrown,
		dashHitThrown = dashHitThrown,
		durationSeconds = durationSeconds,
	})
	sendMovementPerformed(player, commitmentSeconds, cooldownSeconds)
end

-- Slide: chained off Sprint (must already be holding Sprint AND have real held movement input) --
-- a bigger committed reposition than Dash, no hitbox (mirrors plain Dash, never DashPunch/DashHit).
-- Server-authoritative on every Slide-specific precondition: state.sprinting, Movement.IsMoving
-- (state), AND now Movement.ResolveDashDirection(state) ~= "Back" -- never trusting the client's own
-- belief about any of these; CombatClient's own canSlideLocally() only checks them locally to avoid
-- firing a request that's doomed to reject. Backward is disallowed entirely (not just cooldown-gated
-- like every other direction) -- Slide chained off Sprint was the fastest available way to retreat,
-- and combining it with a cheap Dash to keep the shared movementCooldownExpiry gate refreshed at
-- Dash's cheaper pace let a player retreat faster than either move's own designed cadence alone
-- intended. Removing Slide as a backward option closes that at the root instead of trying to tune
-- the shared cooldown any tighter. Dash keeps working in every direction, including backward, at its
-- own unchanged pace -- this is scoped to Slide specifically.
local function handleSlideRequest(player: Player): ()
	logReceived("Slide", player)

	local state, rejectReason = checkCommonPreconditions(player, defensiveRateLimiter, "Slide")
	if not state then
		rejectAndNotify("Slide", "Slide", player, rejectReason :: string)
		return
	end

	local now = os.clock()
	if now < state.attackEndsAt then
		rejectAndNotify("Slide", "Slide", player, "AlreadyAttacking")
		return
	end

	if now < state.slideCooldownExpiry then
		rejectAndNotify(
			"Slide",
			"Slide",
			player,
			"SlideCooldownActive",
			{ remainingSeconds = state.slideCooldownExpiry - now }
		)
		return
	end
	-- Shared with Dash -- see CombatState.movementCooldownExpiry's own header. Catches the case
	-- Slide's own cooldown alone can't: a Dash fired recently enough that ALTERNATING would have
	-- renewed faster than either move's own designed pace.
	if now < state.movementCooldownExpiry then
		rejectAndNotify(
			"Slide",
			"Slide",
			player,
			"MovementCooldownActive",
			{ remainingSeconds = state.movementCooldownExpiry - now }
		)
		return
	end

	if not state.sprinting then
		rejectAndNotify("Slide", "Slide", player, "NotSprinting")
		return
	end
	if not Movement.IsMoving(state) then
		rejectAndNotify("Slide", "Slide", player, "NotMoving")
		return
	end
	-- Backward Slide is disallowed entirely -- see this function's own header for why. Reuses Dash's
	-- own direction resolution (the same held-input-vs-facing dot product) rather than duplicating it.
	if Movement.ResolveDashDirection(state) == "Back" then
		rejectAndNotify("Slide", "Slide", player, "CannotSlideBackward")
		return
	end

	Movement.ApplySlide(state, now)
	setActiveAction(state, "Slide")

	logAccepted("Slide", player, { durationSeconds = Constants.Combat.SlideDurationSeconds })
	sendSlidePerformed(player, Constants.Combat.SlideCommitmentSeconds)
end

-- Reverse lookup for the air-tech escape below: airComboTarget lives on the ATTACKER's own
-- CombatState (see that field's own header), so there's no direct "who is juggling me" pointer on
-- the victim's side. Same reverse-scan shape as clearLockOnReferencesTo above. Only matches an
-- attacker whose sequence hasn't already lapsed (now <= airComboExpiry) -- a stale/expired
-- airComboTarget from a sequence that already ended naturally shouldn't count as "currently
-- juggled" for tech purposes.
local function findAirComboAttacker(victimPlayer: Player, now: number): (Player?, CombatState?)
	for attackerPlayer, attackerState in pairs(combatStates) do
		if attackerState.airComboTarget == victimPlayer and now <= attackerState.airComboExpiry then
			return attackerPlayer, attackerState
		end
	end
	return nil, nil
end

-- Double-tap-W air-tech: the victim of someone ELSE's air-combo juggle attempts to break the hold.
-- Deliberately does NOT go through checkCommonPreconditions/ACTION_GATES -- this is the one action
-- that must work WHILE ragdolled (that's the entire point: combat-philosophy.md's "no true
-- unblockable/unparryable without a telegraphed cost" means the juggle itself needs a real
-- counter). Still rate-limited (defensiveRateLimiter) and still requires a live CombatState.
--
-- Not itself a parryable exchange -- a defense against a defenseless state, the same way a Parry's
-- own attacker-punish isn't itself something the attacker can defend against. See
-- HitResolution.ApplyParryPunish's own header for why the punish logic is shared, not duplicated,
-- with a genuine Parry.
local function handleAirTechRequest(player: Player): ()
	logReceived("AirTech", player)

	if defensiveRateLimiter:IsLimited(player) then
		logRejected("AirTech", player, "RateLimited")
		return
	end
	local state = combatStates[player]
	if not state or not state.alive then
		logRejected("AirTech", player, "NoCombatState")
		return
	end

	local now = os.clock()
	if now < state.airTechReadyAt then
		logRejected("AirTech", player, "TechCooldownActive", { remainingSeconds = state.airTechReadyAt - now })
		return
	end

	local attackerPlayer, attackerState = findAirComboAttacker(player, now)
	if not attackerPlayer or not attackerState then
		-- Not actually juggled right now -- nothing to spam-prevent, so no cooldown is set.
		logRejected("AirTech", player, "NotJuggled")
		return
	end

	if now > state.airTechWindowExpiry then
		-- Genuinely mistimed: was juggled, missed the window. Cooldown applies -- see
		-- Constants.Combat.AirCombo.TechCooldownSeconds' own header for why.
		state.airTechReadyAt = now + Constants.Combat.AirCombo.TechCooldownSeconds
		logRejected("AirTech", player, "MistimedWindow")
		return
	end

	-- Success: this is a REAL parry, not a full escape -- convert the hold into a suspended, mutual
	-- exchange rather than dropping either body. Capture the fixed hold points BEFORE clearing the
	-- attacker's own air-combo bookkeeping below (those fields are what the points are computed from).
	local holdPosition = attackerState.airComboHoverPosition
	local chaseOffset = attackerState.airComboChaseOffset
	local attackerRootPart = attackerState.rootPart
	local cfg = Constants.Combat.AirCombo

	-- Un-ragdoll the victim's JOINTS only (ballsocket -> Motor6D reversal) -- ownership/controller
	-- state stays exactly as a ragdoll left it until the HoldAloft refresh just below re-applies the
	-- live-body treatment. See RagdollController.RecoverJointsOnly's own header for why the full
	-- Recover() would break this (hands ownership back to the player mid-hold).
	if state.character then
		RagdollController.RecoverJointsOnly(state.character)
	end
	-- Refresh the victim's OWN hold with a liveBodyFacePoint now supplied (previously nil, a ragdoll
	-- hold) -- this is what actually applies enterRigidHold/gravity-cancel/face-orientation, the SAME
	-- live-body treatment the attacker's own hold already uses, via HoldAloft's existing refresh-in-
	-- place path (see that function's own header).
	if state.rootPart and holdPosition and attackerRootPart then
		RagdollController.HoldAloft(
			state.rootPart,
			player,
			holdPosition,
			cfg.SuspendedSeconds,
			cfg.HoverRiseSpeed,
			cfg.HoverResponsiveness,
			attackerRootPart.Position
		)
	end
	-- Keep the ATTACKER suspended alongside them too (per design: "keep them in the air suspended
	-- WITH the attacker," not drop either body) -- refresh their existing hold to the same
	-- SuspendedSeconds window so it doesn't expire out from under the victim mid-exchange.
	if attackerRootPart and holdPosition and chaseOffset then
		RagdollController.HoldAloft(
			attackerRootPart,
			attackerPlayer,
			holdPosition + chaseOffset,
			cfg.SuspendedSeconds,
			cfg.ChaseSpeed,
			cfg.ChaseResponsiveness,
			holdPosition
		)
		attackerState.airComboChaseExpiry = now + cfg.SuspendedSeconds
	end

	state.ragdollExpiry = 0
	state.airTechWindowExpiry = 0
	-- A successful tech is NOT free -- see TechCooldownSeconds' own header: a zero-cost, infinitely
	-- repeatable escape + attacker punish would make the air-combo's own investment (DashPunch
	-- cooldown, chase commitment) worthless.
	state.airTechReadyAt = now + Constants.Combat.AirCombo.TechCooldownSeconds
	state.blocking = false
	state.airComboSuspendedUntil = now + cfg.SuspendedSeconds
	state.airComboSuspendedWithAttacker = attackerPlayer

	-- Ends the attacker's FREE auto-combo privilege -- any further attack they throw at this player
	-- now resolves as a normal swing (arc/LOS/ClassifyDefense all apply), not a guaranteed
	-- continuation hit against a helpless ragdoll. This is what makes "allowed to Block" meaningful.
	attackerState.airComboTarget = nil
	attackerState.airComboHitCount = 0
	attackerState.airComboExpiry = 0
	attackerState.airComboHoverPosition = nil
	attackerState.airComboChaseOffset = nil

	HitResolution.ApplyParryPunish(attackerState, now)
	state.inCombatUntil = now + Constants.Combat.InCombatDurationSeconds
	attackerState.inCombatUntil = now + Constants.Combat.InCombatDurationSeconds
	sendVitals(attackerPlayer, attackerState)

	local payload = buildFeedbackPayload("AirTechEscaped", attackerPlayer, player, nil, nil, false)
	sendFeedback(attackerPlayer, payload)
	sendFeedback(player, payload)

	if attackerState.posture <= 0 then
		triggerPostureBreak(attackerPlayer, attackerState, player)
		sendVitals(attackerPlayer, attackerState)
	end

	logAccepted("AirTech", player, { attacker = attackerPlayer.Name })
end

-- Sprint start/stop: a held movement state, not a one-shot action. handleSprintStart just records
-- the intent (Movement.SetSprinting(state, true)) regardless of current combat state --
-- onHeartbeat's Movement.ComputeDesiredWalkSpeed decides frame-by-frame whether that intent
-- actually raises WalkSpeed (it won't while blocking, mid-commitment, stunned, or posture-broken),
-- so a sprint press during a stun isn't "wasted": it takes effect the moment the gate clears while
-- the key is still held.
-- Deliberately not gated beyond alive -- a rejected press would silently drop a held intent the
-- client thinks is active. Mirrors Block's start/stop input shape (CombatClient.lua).
local function handleSprintStart(player: Player): ()
	logReceived("SprintStart", player)

	local state, rejectReason = checkCommonPreconditions(player, utilityRateLimiter, "SprintStart")
	if not state then
		logRejected("SprintStart", player, rejectReason :: string)
		return
	end

	Movement.SetSprinting(state, true)
	logAccepted("SprintStart", player)
end

-- Stop is deliberately NOT rate-limited: honoring a release must never fail, or a throttled stop
-- would leave state.sprinting stuck true and the player sprinting after they let go. (Start is
-- rate-limited; a dropped start just means no sprint, which is safe. A dropped stop is not.)
local function handleSprintStop(player: Player): ()
	logReceived("SprintStop", player)

	local state = combatStates[player]
	if not state then
		logRejected("SprintStop", player, "NoCombatState")
		return
	end
	Movement.SetSprinting(state, false)
	logAccepted("SprintStop", player)
end

-- The single, unified WalkSpeed resolver relocated to Server/Combat/Movement.lua
-- (Movement.ComputeDesiredWalkSpeed) -- see that module's header for the priority order. Still
-- called every tick from onHeartbeat below, the only caller.

--
-- Passive regen + hitbox scheduling (Heartbeat -- server-authoritative tick per
-- performance-optimization.md's "gameplay-critical validation and state resolution belongs on
-- RunService.Heartbeat"). HitboxResolver has no Heartbeat connection of its own -- see its
-- header -- this is the single tick that drives it.
--

local function onHeartbeat(deltaTime: number): ()
	HitboxResolver.Update(deltaTime)

	local now = os.clock()
	-- Auto-recover finisher ragdolls whose window has elapsed (RagdollController opens no Heartbeat of
	-- its own -- same single-tick reasoning as HitboxResolver).
	RagdollController.Update(now)

	for player, state in pairs(combatStates) do
		if not state.alive then
			continue
		end

		local changed = false

		if now >= state.postureBrokenExpiry and state.posture < state.maxPosture then
			state.posture =
				math.min(state.maxPosture, state.posture + Constants.Combat.PostureRegenPerSecond * deltaTime)
			changed = true
		end

		-- Bookkeeping only -- nothing gates on activeActionKind itself (attackEndsAt/the window
		-- fields remain the real timing authority), this just keeps the tag from visibly lingering
		-- past its own commitment window for anything reading it later (dev tooling, future systems).
		if state.activeActionKind ~= "None" and now >= state.attackEndsAt then
			state.activeActionKind = "None"
		end

		-- A successfully-teched suspended exchange (handleAirTechRequest) that neither side resolved
		-- (no counter-punch landed, no fresh hit landed) within its own window times out here --
		-- drops both bodies back to normal footing rather than leaving them suspended forever.
		if state.airComboSuspendedUntil ~= 0 and now >= state.airComboSuspendedUntil then
			local suspendedWithPlayer = state.airComboSuspendedWithAttacker
			local suspendedWithState = if suspendedWithPlayer then combatStates[suspendedWithPlayer] else nil
			endSuspendedAirComboExchange(player, state, suspendedWithPlayer, suspendedWithState)
		end

		-- WalkSpeed is driven by whichever effect currently claims it, computed fresh every tick
		-- (never scheduled with task.delay) so the three effects that can want to control it --
		-- dash burst, hit-slow clip, and sprint -- can never race a stale restore into clobbering
		-- one another. See Movement.ComputeDesiredWalkSpeed for the priority order. Only writes the
		-- property when it actually needs to change.
		if state.humanoid then
			local desiredWalkSpeed = Movement.ComputeDesiredWalkSpeed(state, now)
			if state.humanoid.WalkSpeed ~= desiredWalkSpeed then
				state.humanoid.WalkSpeed = desiredWalkSpeed
			end
		end

		-- Input-buffer flush -- see CombatState.bufferedAttack's own comment. Every gate that could
		-- have changed since the original (too-early) press is re-checked here, not just the
		-- cooldown/commitment that originally blocked it: a parry/posture-break/disarm landing
		-- during the buffered window should cancel it, not force the attack through.
		local buffered = state.bufferedAttack
		if buffered then
			if now > buffered.ExpiresAt then
				state.bufferedAttack = nil
			elseif
				now >= state.stunExpiry
				and now >= state.postureBrokenExpiry
				and now >= state.ragdollExpiry
				and now >= state.disarmedUntil
				and now >= state.attackEndsAt
				and now >= (if buffered.IsHeavy then state.heavyAttackReadyAt else state.basicAttackReadyAt)
			then
				state.bufferedAttack = nil
				if state.humanoid then
					commitAndThrowAttack(player, state, buffered.IsHeavy, buffered.HoldingJump, now)
				end
			end
		end

		-- Basic-combo lapse + finisher-ready sync. Reset the combo here (proactively, not just lazily
		-- at the next throw) if too long has passed since the last landed hit, so the client's
		-- jump-suppress state clears on time. syncFinisherReady then fires Combat_ComboStateChanged
		-- only on an actual ready/unready transition.
		if state.basicComboLanded > 0 then
			resetBasicComboIfLapsed(state, now)
		end
		syncFinisherReady(player, state)
		syncRootControlLocked(player, state, now)
		syncInCombat(player, state, now)

		if changed and now - state.lastVitalsSyncTime >= Constants.Combat.PassiveVitalsSyncInterval then
			sendVitals(player, state)
		end
	end

	-- Dummies only need posture regen (no vitals remote to throttle -- they have no client) -- this
	-- is what makes a dummy repeatedly useful for testing posture break rather than staying broken
	-- forever after the first one.
	for _, dummyState in pairs(dummyStates) do
		if not dummyState.alive then
			continue
		end

		if now >= dummyState.postureBrokenExpiry and dummyState.posture < dummyState.maxPosture then
			dummyState.posture =
				math.min(dummyState.maxPosture, dummyState.posture + Constants.Combat.PostureRegenPerSecond * deltaTime)
		end

		-- Return a finisher-launched dummy to its spawn once its ragdoll has recovered, fully healed,
		-- so it's a clean repeatable combo/finisher target (see resolveHitAgainstDummy, which sets
		-- ragdollResetAt to after the ragdoll window). Recover() is idempotent, so calling it here
		-- guarantees the ragdoll is cleared before the PivotTo even if the launch left it settling, and
		-- zeroing velocity stops residual launch momentum from carrying it off again after the teleport.
		if dummyState.ragdollResetAt > 0 and now >= dummyState.ragdollResetAt then
			RagdollController.Recover(dummyState.model)
			dummyState.model:PivotTo(dummyState.spawnCFrame)
			dummyState.rootPart.AssemblyLinearVelocity = Vector3.zero
			dummyState.humanoid.Health = dummyState.maxHealth
			dummyState.posture = dummyState.maxPosture
			dummyState.postureBrokenExpiry = 0
			dummyState.ragdollResetAt = 0
			logger:debug("Training dummy reset to spawn after launch", { dummy = dummyState.model.Name })
		end
	end

	-- Training bots: posture regen, plus a continuous facing update toward its owner so arc-gated
	-- attacks (both the bot's own swings and the owner's swings against it) can actually land without
	-- any real movement/pathfinding -- TrainingBotSystem.lua's header explains why translation/chasing
	-- is out of scope for now. Rotation only, position untouched, so this never fights the Humanoid's
	-- own physics.
	for _, botState in pairs(botStates) do
		if not botState.alive then
			continue
		end

		if now >= botState.postureBrokenExpiry and botState.posture < botState.maxPosture then
			botState.posture =
				math.min(botState.maxPosture, botState.posture + Constants.Combat.PostureRegenPerSecond * deltaTime)
		end

		local ownerState = combatStates[botState.ownerPlayer]
		if ownerState and ownerState.alive and ownerState.rootPart then
			local toOwner = ownerState.rootPart.Position - botState.rootPart.Position
			local flatToOwner = Vector3.new(toOwner.X, 0, toOwner.Z)
			if flatToOwner.Magnitude > Constants.Combat.ZeroVectorEpsilon then
				botState.rootPart.CFrame =
					CFrame.lookAt(botState.rootPart.Position, botState.rootPart.Position + flatToOwner)
			end
		end
	end

	CombatSystem.OnHeartbeatTick:Fire(deltaTime)
end

--
-- Character lifecycle
--

local function createFreshState(player: Player): CombatState
	return {
		player = player,
		character = nil,
		humanoid = nil,
		rootPart = nil,
		humanoidDiedConnection = nil,

		maxHealth = Constants.Combat.MaxHealth,
		posture = Constants.Combat.MaxPosture,
		maxPosture = Constants.Combat.MaxPosture,

		alive = false,
		blocking = false,
		deathConfirmed = false,

		lockOnTarget = nil,

		parryWindowExpiry = 0,
		parryCooldownExpiry = 0,
		stunExpiry = 0,
		postureBrokenExpiry = 0,
		inCombatUntil = 0,
		hitSlowExpiry = 0,

		sprinting = false,
		dashWindowExpiry = 0,
		dashCooldownExpiry = 0,
		dashIsBackward = false,
		dashPunchReadyAt = 0,
		slideWindowExpiry = 0,
		slideCooldownExpiry = 0,
		movementCooldownExpiry = 0,
		airSlamReadyAt = 0,

		basicAttackReadyAt = 0,
		heavyAttackReadyAt = 0,
		attackEndsAt = 0,
		activeActionKind = "None",
		currentSwingWindupEndsAt = 0,
		swingCancelled = false,
		comboIndex = 0,
		comboExpiry = 0,
		basicComboLanded = 0,
		basicComboExpiry = 0,
		finisherReadySynced = false,
		rootControlLockedSynced = false,
		inCombatSynced = false,
		ragdollExpiry = 0,
		disarmedUntil = 0,

		equippedWeaponId = Constants.Combat.Weapons.Default,
		weaponSwapReadyAt = 0,
		bufferedAttack = nil,

		airComboTarget = nil,
		airComboDummyTarget = nil,
		airComboHitCount = 0,
		airComboExpiry = 0,
		airComboChaseExpiry = 0,
		airComboHoverPosition = nil,
		airComboChaseOffset = nil,
		airTechWindowExpiry = 0,
		airTechReadyAt = 0,
		airComboSuspendedUntil = 0,
		airComboSuspendedWithAttacker = nil,

		godmode = false,
		savedFlightAutoRotate = nil,

		frozen = false,
		savedJumpPower = nil,
		speedMultiplier = 1,
		invisible = false,

		lastVitalsSyncTime = 0,
		pendingKillerUserId = nil,
	}
end

local function onCharacterAdded(player: Player, character: Model): ()
	local state = combatStates[player]
	if not state then
		return
	end

	if state.humanoidDiedConnection then
		state.humanoidDiedConnection:Disconnect()
		state.humanoidDiedConnection = nil
	end

	local humanoidInstance = character:WaitForChild("Humanoid", Constants.Network.WaitForChildTimeoutSeconds)
	if not humanoidInstance or not humanoidInstance:IsA("Humanoid") then
		warn(`CombatSystem: character for {player.Name} has no Humanoid -- combat state not bound`)
		return
	end
	local humanoid = humanoidInstance :: Humanoid

	local rootPartInstance = character:WaitForChild("HumanoidRootPart", Constants.Network.WaitForChildTimeoutSeconds)
	if not rootPartInstance or not rootPartInstance:IsA("BasePart") then
		warn(`CombatSystem: character for {player.Name} has no HumanoidRootPart -- combat state not bound`)
		return
	end
	local rootPart = rootPartInstance :: BasePart

	humanoid.MaxHealth = Constants.Combat.MaxHealth
	humanoid.Health = Constants.Combat.MaxHealth
	humanoid.WalkSpeed = Constants.Combat.BaseWalkSpeed
	-- See Constants.Combat.DefaultBonusWalkSpeed's own header -- a per-player Attribute so a future
	-- race/bloodline stat system can override it later without touching this spawn path.
	humanoid:SetAttribute(Constants.Attributes.BonusWalkSpeed, Constants.Combat.DefaultBonusWalkSpeed)
	-- Godmode is admin-granted state that deliberately survives respawn (SetPlayerGodmode's own
	-- header) -- re-apply the mirror attribute onto every fresh Humanoid so a live UI reading this
	-- attribute (DevMenu) stays accurate across a respawn instead of reading "off" on a new instance.
	humanoid:SetAttribute(Constants.Attributes.Godmode, state.godmode)
	-- Same "admin-granted state survives respawn" reasoning as Godmode above, for Frozen and
	-- SpeedMultiplier -- both are read directly as Attributes by Movement.ComputeDesiredWalkSpeed,
	-- so a fresh Humanoid instance needs them re-seeded or a respawn would silently unfreeze/reset
	-- to 1x.
	humanoid:SetAttribute(Constants.Attributes.Frozen, state.frozen)
	humanoid:SetAttribute(Constants.Attributes.SpeedMultiplier, state.speedMultiplier)
	if state.frozen then
		state.savedJumpPower = humanoid.JumpPower
		humanoid.JumpPower = 0
	end

	state.character = character
	state.humanoid = humanoid
	state.rootPart = rootPart
	characterToPlayer[character] = player

	-- Invisibility is admin-granted state that deliberately survives respawn too -- re-apply the
	-- Transparency effect directly to the fresh character's parts (see CombatSystem.SetPlayerInvisible's
	-- own header for why this can't just be a re-seeded Attribute the way Frozen/SpeedMultiplier are).
	humanoid:SetAttribute(Constants.Attributes.Invisible, state.invisible)
	if state.invisible then
		setCharacterTransparency(character, 1)
	end

	state.maxHealth = Constants.Combat.MaxHealth
	state.posture = Constants.Combat.MaxPosture
	state.maxPosture = Constants.Combat.MaxPosture

	state.alive = true
	state.blocking = false
	state.deathConfirmed = false
	-- Notify the client whenever a respawn actually clears a live lock-on -- without this, a player
	-- who died/respawned while still locked onto a target never learns their own bookkeeping was
	-- reset server-side, and the reticle keeps rendering that (no-longer-locked) target
	-- indefinitely. (CombatClient.lua also defensively clears its own presentation on every
	-- CharacterAdded/CharacterRemoving regardless of this notification, so this is belt-and-braces,
	-- not the only fix.)
	if state.lockOnTarget ~= nil then
		state.lockOnTarget = nil
		sendLockOnChanged(player, nil)
	end

	state.parryWindowExpiry = 0
	state.parryCooldownExpiry = 0
	state.stunExpiry = 0
	state.postureBrokenExpiry = 0
	state.inCombatUntil = 0
	state.hitSlowExpiry = 0

	state.sprinting = false
	state.dashWindowExpiry = 0
	state.dashCooldownExpiry = 0
	state.dashIsBackward = false
	state.dashPunchReadyAt = 0
	state.slideWindowExpiry = 0
	state.slideCooldownExpiry = 0
	state.movementCooldownExpiry = 0

	state.basicAttackReadyAt = 0
	state.heavyAttackReadyAt = 0
	state.attackEndsAt = 0
	state.activeActionKind = "None"
	state.currentSwingWindupEndsAt = 0
	state.swingCancelled = false
	state.comboIndex = 0
	state.comboExpiry = 0
	state.basicComboLanded = 0
	state.basicComboExpiry = 0
	state.finisherReadySynced = false
	state.rootControlLockedSynced = false
	state.inCombatSynced = false
	state.ragdollExpiry = 0
	state.disarmedUntil = 0

	state.equippedWeaponId = Constants.Combat.Weapons.Default
	state.weaponSwapReadyAt = 0
	-- A fresh character has nothing legitimately buffered from its previous life.
	state.bufferedAttack = nil

	-- Nor a stale air combo -- a respawn ends any juggle the previous life was mid-sequence on.
	state.airComboTarget = nil
	state.airComboDummyTarget = nil
	state.airComboHitCount = 0
	state.airComboExpiry = 0
	state.airComboChaseExpiry = 0
	state.airComboHoverPosition = nil
	state.airComboChaseOffset = nil
	state.airTechWindowExpiry = 0
	state.airTechReadyAt = 0
	state.airComboSuspendedUntil = 0
	state.airComboSuspendedWithAttacker = nil

	state.lastVitalsSyncTime = 0
	state.pendingKillerUserId = nil

	state.humanoidDiedConnection = humanoid.Died:Connect(function()
		confirmDeath(player, state)
	end)

	sendVitals(player, state)
end

local function onCharacterRemoving(player: Player): ()
	local state = combatStates[player]
	if not state then
		return
	end

	if state.humanoidDiedConnection then
		state.humanoidDiedConnection:Disconnect()
		state.humanoidDiedConnection = nil
	end

	if state.character then
		-- Clear any active finisher ragdoll before the character is replaced, so RagdollController
		-- doesn't hold a disabled-motor / server-owned reference to a soon-destroyed character.
		RagdollController.Recover(state.character)
		characterToPlayer[state.character] = nil
	end

	-- If this player was mid-suspended-exchange on EITHER side (the victim who teched, or the
	-- attacker someone teched against), don't leave the other half permanently pinned -- see
	-- endSuspendedAirComboExchange/clearSuspendedReferencesTo's own headers.
	if state.airComboSuspendedUntil ~= 0 then
		local suspendedWithPlayer = state.airComboSuspendedWithAttacker
		local suspendedWithState = if suspendedWithPlayer then combatStates[suspendedWithPlayer] else nil
		endSuspendedAirComboExchange(player, state, suspendedWithPlayer, suspendedWithState)
	end
	clearSuspendedReferencesTo(player)

	state.alive = false
	state.character = nil
	state.humanoid = nil
	state.rootPart = nil
	state.ragdollExpiry = 0

	clearLockOnReferencesTo(player)
end

local function onPlayerAdded(player: Player): ()
	combatStates[player] = createFreshState(player)

	player.CharacterAdded:Connect(function(character: Model)
		onCharacterAdded(player, character)
	end)
	player.CharacterRemoving:Connect(function()
		onCharacterRemoving(player)
	end)

	if player.Character then
		onCharacterAdded(player, player.Character)
	end
end

local function onPlayerRemoving(player: Player): ()
	local state = combatStates[player]
	if state then
		if state.humanoidDiedConnection then
			state.humanoidDiedConnection:Disconnect()
		end
		if state.character then
			characterToPlayer[state.character] = nil
		end
	end

	clearLockOnReferencesTo(player)
	clearSuspendedReferencesTo(player)
	combatStates[player] = nil
	attackRateLimiter:Clear(player)
	defensiveRateLimiter:Clear(player)
	utilityRateLimiter:Clear(player)
end

--
-- Training dummy lifecycle -- only reachable through CombatSystem.SpawnTrainingDummy in the
-- Public API section below, which only DevMenuSystem.lua calls (after its own whitelist check).
-- Nothing here trusts a caller's authorization; it isn't this System's job to re-check who's
-- allowed to spawn one, only to make sure a spawned dummy behaves correctly once it exists.
--

-- Forward-declared (type only, no value yet): confirmDummyDeath below needs to call this from
-- inside a task.delay callback before it's defined, since it and createTrainingDummy are
-- naturally mutually referential (death schedules a re-creation; creation wires up the Died
-- connection that leads back to death). The later `function createTrainingDummy(...)` assigns
-- to this same local -- Lua's `function name(...)` sugar resolves `name` by normal scoping, so
-- declaring it local first is what keeps that assignment from silently becoming a global.
local createTrainingDummy: (CFrame) -> DummyState

local function getDummiesFolder(): Folder
	if dummiesFolder and dummiesFolder.Parent then
		return dummiesFolder
	end
	local folder = Instance.new("Folder")
	folder.Name = "TrainingDummies"
	folder.Parent = Workspace
	dummiesFolder = folder
	return folder
end

local function getBotsFolder(): Folder
	if botsFolder and botsFolder.Parent then
		return botsFolder
	end
	local folder = Instance.new("Folder")
	folder.Name = "TrainingBots"
	folder.Parent = Workspace
	botsFolder = folder
	return folder
end

-- Floating name tag -- a bare NPC Humanoid (unlike a real Player's character) gets no automatic
-- nameplate from Roblox's core UI, so without this a dummy/bot would be visually indistinguishable
-- from any other default-appearance rig at a glance. Shared by both training dummies and training
-- bots (text/color are the only per-kind difference) rather than duplicated per kind.
local function attachCombatantLabel(model: Model, text: string, color: Color3): ()
	local adornee = model:FindFirstChild("Head") or model:FindFirstChild("HumanoidRootPart")
	if not adornee or not adornee:IsA("BasePart") then
		return
	end

	local labelConfig = Constants.Debug.CombatantLabel

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "CombatantLabel"
	billboard.Size = labelConfig.Size
	billboard.StudsOffset = labelConfig.StudsOffset
	billboard.AlwaysOnTop = true
	billboard.Adornee = adornee
	billboard.Parent = adornee

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = labelConfig.Font
	label.TextSize = labelConfig.TextSize
	label.Text = text
	label.TextColor3 = color
	label.TextStrokeTransparency = labelConfig.TextStrokeTransparency
	label.Parent = billboard
end

local function despawnDummy(model: Model): ()
	local dummyState = dummyStates[model]
	if not dummyState then
		return
	end
	if dummyState.humanoidDiedConnection then
		dummyState.humanoidDiedConnection:Disconnect()
	end
	dummyStates[model] = nil
	local index = table.find(dummySpawnOrder, model)
	if index then
		table.remove(dummySpawnOrder, index)
	end
	model:Destroy()
end

local function confirmDummyDeath(dummyState: DummyState): ()
	if dummyState.deathConfirmed then
		return
	end
	dummyState.deathConfirmed = true
	dummyState.alive = false

	logger:info("Training dummy defeated", { dummy = dummyState.model.Name })

	local model = dummyState.model
	local spawnCFrame = dummyState.spawnCFrame

	-- A dead Humanoid can't be revived in place (Roblox's Dead HumanoidStateType is terminal --
	-- setting Health back up does not undo it), so "respawn" means destroy the old model and
	-- create a genuinely fresh one at the same spawn point, exactly like a real player getting a
	-- new character on respawn rather than their old one being healed back up.
	task.delay(Constants.Debug.TrainingDummy.RespawnDelay, function()
		if not model.Parent then
			return -- already despawned (e.g. evicted to make room for a new one) while waiting
		end
		despawnDummy(model)
		createTrainingDummy(spawnCFrame)
		logger:info("Training dummy respawned")
	end)
end

-- Assigns the local forward-declared above confirmDummyDeath -- no `local` keyword here on
-- purpose, so this binds to that existing local instead of shadowing it with a new one.
function createTrainingDummy(spawnCFrame: CFrame): DummyState
	local description = Instance.new("HumanoidDescription")
	local model = Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
	model.Name = "TrainingDummy"

	local humanoidInstance = model:FindFirstChildOfClass("Humanoid")
	assert(humanoidInstance, "CreateHumanoidModelFromDescription did not produce a Humanoid")
	local humanoid = humanoidInstance :: Humanoid
	humanoid.MaxHealth = Constants.Debug.TrainingDummy.MaxHealth
	humanoid.Health = Constants.Debug.TrainingDummy.MaxHealth
	-- Keeps the dummy as one rigid assembly on death instead of ragdolling into scattered limbs,
	-- so PivotTo-ing it back to spawnCFrame on respawn (see confirmDummyDeath) moves it cleanly.
	humanoid.BreakJointsOnDeath = false

	local rootPartInstance = model:FindFirstChild("HumanoidRootPart")
	assert(
		rootPartInstance and rootPartInstance:IsA("BasePart"),
		"CreateHumanoidModelFromDescription did not produce a HumanoidRootPart"
	)
	local rootPart = rootPartInstance :: BasePart

	model:PivotTo(spawnCFrame)
	attachCombatantLabel(model, "Training Dummy", Constants.Debug.TrainingDummy.LabelColor)
	model.Parent = getDummiesFolder()

	local dummyState: DummyState = {
		model = model,
		humanoid = humanoid,
		rootPart = rootPart,
		spawnCFrame = spawnCFrame,
		maxHealth = Constants.Debug.TrainingDummy.MaxHealth,
		posture = Constants.Debug.TrainingDummy.MaxPosture,
		maxPosture = Constants.Debug.TrainingDummy.MaxPosture,
		postureBrokenExpiry = 0,
		alive = true,
		deathConfirmed = false,
		humanoidDiedConnection = nil,
		ragdollResetAt = 0,
	}

	dummyState.humanoidDiedConnection = humanoid.Died:Connect(function()
		confirmDummyDeath(dummyState)
	end)

	dummyStates[model] = dummyState
	table.insert(dummySpawnOrder, model)

	logger:info("Training dummy created", { dummy = model.Name, position = tostring(spawnCFrame.Position) })

	return dummyState
end

--
-- Training bot lifecycle -- only reachable through CombatSystem.SpawnTrainingBot/RequestBot* in
-- the Public API section below, which only TrainingBotSystem.lua calls. Nothing here trusts a
-- caller's authorization (same as the training dummy section above) -- it isn't this System's job
-- to re-check who's allowed to spawn/drive one, only to make sure a bot behaves correctly once it
-- exists. Unlike the dummy section, there's no forward-declared mutual recursion here -- bots do
-- NOT auto-respawn (see the file header), so death never schedules a re-creation from inside this
-- System.
--

local function despawnBot(model: Model): ()
	local state = botStates[model]
	if not state then
		return
	end
	if state.humanoidDiedConnection then
		state.humanoidDiedConnection:Disconnect()
	end
	botStates[model] = nil
	BotAnimator.UnbindBot(model)

	local owned = botsByOwner[state.ownerPlayer]
	if owned then
		local index = table.find(owned, model)
		if index then
			table.remove(owned, index)
		end
		if #owned == 0 then
			botsByOwner[state.ownerPlayer] = nil
		end
	end

	model:Destroy()
	CombatSystem.OnTrainingBotDespawned:Fire(model)
end

local function confirmBotDeath(botModel: Model, state: BotState): ()
	if state.deathConfirmed then
		return
	end
	state.deathConfirmed = true
	state.alive = false
	state.blocking = false

	local killerUserId = state.pendingKillerUserId
	state.pendingKillerUserId = nil
	local killerPlayer: Player? = nil
	if killerUserId then
		killerPlayer = Players:GetPlayerByUserId(killerUserId)
	end

	logger:info("Training bot defeated", {
		bot = botModel.Name,
		owner = state.ownerPlayer.Name,
		killer = if killerPlayer then killerPlayer.Name else "none",
	})

	if killerPlayer then
		local payload = buildFeedbackPayload("Death", killerPlayer, nil, nil, nil, nil, state.rootPart.Position)
		sendFeedback(killerPlayer, payload)
	end

	CombatSystem.OnTrainingBotKilled:Fire(botModel, state.ownerPlayer, killerPlayer)
end

local function createTrainingBot(ownerPlayer: Player, spawnCFrame: CFrame): BotState
	local description = Instance.new("HumanoidDescription")
	local model = Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
	model.Name = "TrainingBot"

	local humanoidInstance = model:FindFirstChildOfClass("Humanoid")
	assert(humanoidInstance, "CreateHumanoidModelFromDescription did not produce a Humanoid")
	local humanoid = humanoidInstance :: Humanoid
	-- Bot vitals reuse Constants.Combat directly (not Constants.Debug.TrainingBot -- see that
	-- table's own header) -- a training bot should feel like a real opponent, not an inflated
	-- punching bag like the dummy.
	humanoid.MaxHealth = Constants.Combat.MaxHealth
	humanoid.Health = Constants.Combat.MaxHealth
	humanoid.BreakJointsOnDeath = false

	local rootPartInstance = model:FindFirstChild("HumanoidRootPart")
	assert(
		rootPartInstance and rootPartInstance:IsA("BasePart"),
		"CreateHumanoidModelFromDescription did not produce a HumanoidRootPart"
	)
	local rootPart = rootPartInstance :: BasePart

	model:PivotTo(spawnCFrame)
	attachCombatantLabel(model, "Training Bot", Constants.Debug.TrainingBot.LabelColor)
	model.Parent = getBotsFolder()

	local state: BotState = {
		model = model,
		humanoid = humanoid,
		rootPart = rootPart,
		spawnCFrame = spawnCFrame,
		ownerPlayer = ownerPlayer,
		humanoidDiedConnection = nil,

		maxHealth = Constants.Combat.MaxHealth,
		posture = Constants.Combat.MaxPosture,
		maxPosture = Constants.Combat.MaxPosture,

		alive = true,
		blocking = false,
		deathConfirmed = false,

		parryWindowExpiry = 0,
		parryCooldownExpiry = 0,
		stunExpiry = 0,
		postureBrokenExpiry = 0,

		basicAttackReadyAt = 0,
		heavyAttackReadyAt = 0,
		attackEndsAt = 0,
		comboIndex = 0,
		comboExpiry = 0,
		disarmedUntil = 0,

		pendingKillerUserId = nil,
	}

	state.humanoidDiedConnection = humanoid.Died:Connect(function()
		confirmBotDeath(model, state)
	end)

	BotAnimator.BindBot(model)

	botStates[model] = state
	local owned = botsByOwner[ownerPlayer]
	if not owned then
		owned = {}
		botsByOwner[ownerPlayer] = owned
	end
	table.insert(owned, model)

	logger:info("Training bot created", {
		bot = model.Name,
		owner = ownerPlayer.Name,
		position = tostring(spawnCFrame.Position),
	})

	return state
end

--
-- Public API -- kept narrow per the task brief: read-only state, an alive check, a kill signal,
-- and a validated direct-damage hook for future non-melee sources (hazards, NPCs). No system
-- calls into CombatSystem's internals any other way.
--

function CombatSystem.IsAlive(player: Player): boolean
	local state = combatStates[player]
	return state ~= nil and state.alive
end

-- Read-only lock-on lookup -- DevMenuSystem.lua's admin actions (SetHealth/Godmode/Flight) use
-- this to resolve "whichever player the requesting admin currently has locked on" as their target
-- picker, reusing the existing lock-on system instead of a new player-select UI.
function CombatSystem.GetLockOnTarget(player: Player): Player?
	local state = combatStates[player]
	if not state then
		return nil
	end
	return state.lockOnTarget
end

function CombatSystem.GetCombatState(player: Player): Types.CombatSnapshot?
	local state = combatStates[player]
	if not state then
		return nil
	end

	local now = os.clock()
	return {
		Alive = state.alive,
		Health = if state.humanoid then state.humanoid.Health else 0,
		MaxHealth = state.maxHealth,
		Posture = state.posture,
		MaxPosture = state.maxPosture,
		Blocking = state.blocking,
		Stunned = now < state.stunExpiry,
		PostureBroken = now < state.postureBrokenExpiry,
		Disarmed = now < state.disarmedUntil,
		Attacking = now < state.attackEndsAt,
		Sprinting = state.sprinting,
		InCombat = now < state.inCombatUntil,
	}
end

-- Validated, server-only direct damage hook for non-melee sources (terrain hazards, NPC attacks)
-- that should still resolve through CombatSystem's health/posture/death pipeline instead of each
-- caller reinventing it. Does not apply block/parry mitigation -- that's specific to the
-- attacker-vs-target melee resolution above, not a general-purpose damage discount. The caller is
-- responsible for deciding *when* and *how much*; this function only validates the target still
-- exists and is alive, then applies the amounts it's given.
function CombatSystem.ApplyServerDamage(targetPlayer: Player, damageAmount: number, postureAmount: number?): boolean
	local state = combatStates[targetPlayer]
	if not state or not state.alive then
		return false
	end
	local humanoid = state.humanoid
	if not humanoid then
		return false
	end
	if damageAmount < 0 then
		return false
	end

	local now = os.clock()
	local wasPostureBroken = now < state.postureBrokenExpiry

	local clampedPosture = math.max(0, postureAmount or 0)
	if clampedPosture > 0 then
		state.posture = math.max(0, state.posture - clampedPosture)
	end

	if damageAmount > 0 then
		humanoid:TakeDamage(damageAmount)
	end

	sendVitals(targetPlayer, state)

	if state.posture <= 0 and not wasPostureBroken then
		triggerPostureBreak(targetPlayer, state, nil)
		sendVitals(targetPlayer, state)
	end

	return true
end

-- Admin-only actions (DevMenuSystem.lua's own whitelist check happens entirely before any of these
-- are ever called -- same trust boundary SpawnTrainingDummy/SpawnTrainingBot below already
-- establish: this System trusts its caller is a server-internal System, never re-checks
-- authorization itself).

-- Directly sets a player's Health, clamped to [0, their own MaxHealth] -- bypasses TakeDamage's
-- block/parry mitigation entirely (an admin override, not a combat action), but Humanoid.Health
-- hitting 0 still fires the normal Humanoid.Died path (onCharacterAdded's own
-- humanoidDiedConnection), so death/respawn behave exactly like an ordinary kill would.
function CombatSystem.SetPlayerHealth(targetPlayer: Player, health: number): boolean
	local state = combatStates[targetPlayer]
	if not state or not state.humanoid then
		return false
	end
	state.humanoid.Health = math.clamp(health, 0, state.humanoid.MaxHealth)
	sendVitals(targetPlayer, state)
	return true
end

-- Toggles godmode (CombatState.godmode's own header) -- zeroes damage/posture on every future hit
-- against this player until toggled off again. Does not itself change current Health/Posture, and
-- deliberately not reset on respawn (onCharacterAdded) -- an admin-granted state, not a per-life
-- transient like blocking/sprinting.
function CombatSystem.SetPlayerGodmode(targetPlayer: Player, enabled: boolean): boolean
	local state = combatStates[targetPlayer]
	if not state then
		return false
	end
	state.godmode = enabled
	-- Mirrors SetPlayerFlying's own "Flying" attribute below -- lets a client (DevMenu) read live
	-- Godmode state directly off the replicated Humanoid instead of guessing it from which button
	-- was last pressed.
	if state.humanoid then
		state.humanoid:SetAttribute(Constants.Attributes.Godmode, enabled)
	end
	return true
end

-- Toggles flight: PlatformStand suspends the Humanoid's own ground movement/gravity response (the
-- same trick RagdollController uses for a limp knockdown, reused here for the opposite reason --
-- staying fully upright and controllable while something else drives position), and the "Flying"
-- Attribute is what Client/DevMenu/FlightController.lua watches to know whether IT should
-- start/stop driving free 3D movement locally -- see that module's own header for the client half.
-- Server-side this is nothing more than a state flag + a Humanoid property; all the actual
-- movement happens client-side, same trust level as WalkSpeed itself (client-owned feel, per
-- luau-coding-standards.md's server/client split).
--
-- Also quiets/restores the Humanoid's own airborne/recovery controller (AutoRotate, GettingUp
-- state, a nudge into the Physics state) -- the same four-property recipe RagdollController.
-- enterRigidHold/exitRigidHold uses for a live (non-ragdolled) body under a physics pin. Needed for
-- Collide mode's LinearVelocity/AlignOrientation constraints (Client/DevMenu/FlightPhysics.lua): a
-- live Humanoid's own controller otherwise keeps fighting a physics-driven pin every frame. Harmless
-- for Noclip, whose direct CFrame write already overrides position regardless of controller state.
function CombatSystem.SetPlayerFlying(targetPlayer: Player, enabled: boolean): boolean
	local state = combatStates[targetPlayer]
	if not state or not state.humanoid then
		return false
	end
	local humanoid = state.humanoid
	humanoid.PlatformStand = enabled
	humanoid:SetAttribute(Constants.Attributes.Flying, enabled)

	if enabled then
		state.savedFlightAutoRotate = humanoid.AutoRotate
		humanoid.AutoRotate = false
		humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)
		pcall(function()
			humanoid:ChangeState(Enum.HumanoidStateType.Physics)
		end)
	else
		humanoid.AutoRotate = if state.savedFlightAutoRotate ~= nil then state.savedFlightAutoRotate else true
		humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
		pcall(function()
			humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
		end)
	end
	return true
end

-- Toggles Collide mode for the Constants.Debug.DevMenu "Collide" toggle -- mirrors SetPlayerFlying's
-- own shape exactly: server owns nothing but the flag/Attribute, every constraint/physics decision
-- is client-side (Client/DevMenu/FlightPhysics.lua), same trust tier as Flying itself. Independent
-- of whether Flying is currently true or false -- FlightController.lua watches BOTH Attributes live,
-- so toggling Collide mid-flight (or before takeoff) just changes which branch the next frame's
-- movement step takes.
function CombatSystem.SetPlayerFlightCollide(targetPlayer: Player, enabled: boolean): boolean
	local state = combatStates[targetPlayer]
	if not state or not state.humanoid then
		return false
	end
	state.humanoid:SetAttribute(Constants.Attributes.FlyCollide, enabled)
	return true
end

-- Creates a real, hittable training dummy at spawnCFrame -- swings resolve against it exactly
-- like a player (arc/LOS/dedup, posture break, death+respawn), it's just not a Player. Does NOT
-- check authorization -- that's DevMenuSystem.lua's job, entirely before this is ever called; this
-- function trusts its caller is a server-internal System, the same trust CombatSystem already
-- places in any in-process caller of ApplyServerDamage above. Evicts the oldest active dummy once
-- Constants.Debug.TrainingDummy.MaxActive is reached, so repeated use can't grow Workspace
-- unbounded. Returns (model, nil) on success or (nil, reasonString) on failure.
function CombatSystem.SpawnTrainingDummy(spawnCFrame: CFrame): (Model?, string?)
	if #dummySpawnOrder >= Constants.Debug.TrainingDummy.MaxActive then
		local oldest = dummySpawnOrder[1]
		if oldest then
			logger:info("Training dummy cap reached -- evicting oldest", { evicted = oldest.Name })
			despawnDummy(oldest)
		end
	end

	local ok, dummyStateOrError = pcall(createTrainingDummy, spawnCFrame)
	if not ok then
		logger:error("Failed to create training dummy", { errorMessage = tostring(dummyStateOrError) })
		return nil, "CreationFailed"
	end

	local dummyState = dummyStateOrError :: DummyState
	return dummyState.model, nil
end

-- Creates a real, hittable, ATTACKING training bot at spawnCFrame, owned by ownerPlayer -- unlike
-- SpawnTrainingDummy, a bot actually fights (see the file header). Does NOT check authorization
-- (DevMenuSystem.lua's job) or know anything about presets/weights (TrainingBotSystem.lua's job,
-- entirely after this returns) -- this function only creates the combat participant itself.
-- Evicts the owner's oldest bot once Constants.Debug.TrainingBot.MaxActivePerOwner is reached (a
-- bot is a private sparring partner, one per owner, not a squad). Returns (model, nil) on success
-- or (nil, reasonString) on failure.
function CombatSystem.SpawnTrainingBot(ownerPlayer: Player, spawnCFrame: CFrame): (Model?, string?)
	local owned = botsByOwner[ownerPlayer]
	local activeCount = (if owned then #owned else 0) + (pendingBotSpawns[ownerPlayer] or 0)
	if activeCount >= Constants.Debug.TrainingBot.MaxActivePerOwner then
		local oldest = owned and owned[1]
		if oldest then
			logger:info(
				"Training bot cap reached for owner -- evicting oldest",
				{ owner = ownerPlayer.Name, evicted = oldest.Name }
			)
			despawnBot(oldest)
		end
	end

	-- Reserve a slot before the yielding call below, and release it after (success or failure) --
	-- see pendingBotSpawns' own comment for the race this closes.
	pendingBotSpawns[ownerPlayer] = (pendingBotSpawns[ownerPlayer] or 0) + 1
	local ok, stateOrError = pcall(createTrainingBot, ownerPlayer, spawnCFrame)
	local remainingPending = (pendingBotSpawns[ownerPlayer] or 1) - 1
	if remainingPending <= 0 then
		pendingBotSpawns[ownerPlayer] = nil
	else
		pendingBotSpawns[ownerPlayer] = remainingPending
	end

	if not ok then
		logger:error("Failed to create training bot", { errorMessage = tostring(stateOrError) })
		return nil, "CreationFailed"
	end

	local state = stateOrError :: BotState
	return state.model, nil
end

-- Removes a training bot immediately (no death animation/delay) -- used by TrainingBotSystem.lua
-- both for its own cap eviction and for cleaning up an owner's bots on Players.PlayerRemoving.
-- Returns false if botModel isn't a currently-tracked bot (already despawned, or never one).
function CombatSystem.DespawnTrainingBot(botModel: Model): boolean
	if not botStates[botModel] then
		return false
	end
	despawnBot(botModel)
	return true
end

-- Read-only projection of a bot's combat state, for TrainingBotSystem.lua's decision loop to read
-- (e.g. "am I already Attacking/Blocking", "am I stunned") -- reuses Types.CombatSnapshot verbatim
-- since that type was already Player-agnostic (no Player-typed fields), the same shape
-- GetCombatState returns for a real player.
function CombatSystem.GetBotState(botModel: Model): Types.CombatSnapshot?
	local state = botStates[botModel]
	if not state then
		return nil
	end

	local now = os.clock()
	return {
		Alive = state.alive,
		Health = if state.humanoid then state.humanoid.Health else 0,
		MaxHealth = state.maxHealth,
		Posture = state.posture,
		MaxPosture = state.maxPosture,
		Blocking = state.blocking,
		Stunned = now < state.stunExpiry,
		PostureBroken = now < state.postureBrokenExpiry,
		Disarmed = now < state.disarmedUntil,
		Attacking = now < state.attackEndsAt,
		-- BotState has no sprint/dash fields -- bots don't use neutral-game movement yet (see
		-- TrainingBotSystem.lua's header, and the Reposition no-op in Types.TrainingBotWeights).
		Sprinting = false,
		-- BotState has no inCombatUntil field (not a real consumer of the flag today) -- zero-cost
		-- approximation reusing fields it already has, rather than growing BotState's schema for a
		-- currently-unused case. Flag for a real field if a future system needs bot-accurate InCombat.
		InCombat = now < state.attackEndsAt or now < state.comboExpiry,
	}
end

-- Server-internal (no remote, no rate limit -- the caller is always TrainingBotSystem.lua's own AI
-- loop, never a client) equivalent of handleAttackRequest, run against BotState instead of
-- CombatState -- identical legality checks (alive/stunned/posture-broken/commitment-lock/cooldown),
-- identical combo-stage selection via selectAttackDefinition, so a bot's attacks time exactly like a
-- player's. Returns true if the attack was accepted and a swing was started.
function CombatSystem.RequestBotAttack(botModel: Model, isHeavy: boolean): boolean
	local state = botStates[botModel]
	if not state or not state.alive then
		return false
	end
	if not state.humanoid or state.humanoid.Health <= 0 then
		return false
	end

	local now = os.clock()
	if now < state.stunExpiry or now < state.postureBrokenExpiry or now < state.disarmedUntil then
		return false
	end

	local readyAt = if isHeavy then state.heavyAttackReadyAt else state.basicAttackReadyAt
	if now < readyAt or now < state.attackEndsAt then
		return false
	end

	resetHeavyComboIfLapsed(state, now)
	local nextComboIndex = math.min(state.comboIndex + 1, Constants.Combat.MaxComboStacks)
	-- Bots always fight with the default weapon -- see handleSwapWeaponRequest's own comment for
	-- why bot weapon-switching is out of scope.
	local definition = selectAttackDefinition(Constants.Combat.Weapons.Default, isHeavy, nextComboIndex)

	state.comboIndex = nextComboIndex
	state.comboExpiry = now + Constants.Combat.ComboResetSeconds

	local readyAgainAt = now + definition.Cooldown
	if isHeavy then
		state.heavyAttackReadyAt = readyAgainAt
	else
		state.basicAttackReadyAt = readyAgainAt
	end
	state.attackEndsAt = now + definition.WindupSeconds + definition.ActiveSeconds + definition.RecoverySeconds

	logger:debug("Bot attack accepted", { bot = botModel.Name, isHeavy = isHeavy, attack = definition.DebugName })

	-- Bots never throw a Finisher (no landing-based combo tracking -- see BotAnimator.PlaySwing's
	-- own header), so finisherVariant is always nil here.
	BotAnimator.PlaySwing(botModel, definition.DebugName, nil)
	startBotAttackSwing(state, definition, isHeavy)
	return true
end

-- Server-internal equivalent of handleBlockStart, run against BotState -- same timed-block/parry
-- merge a real player's press gets (see handleBlockStart's own header): every accepted press
-- starts a plain block and, unless the parry cooldown gate rejects it, also opens a parry
-- window. Returns (accepted, parryWindowOpened) so TrainingBotSystem's AI can tell whether this
-- specific press actually armed a window (relevant for its Parry-preset timing behavior).
function CombatSystem.RequestBotBlockStart(botModel: Model): (boolean, boolean)
	local state = botStates[botModel]
	if not state or not state.alive then
		return false, false
	end

	local now = os.clock()
	if now < state.stunExpiry or now < state.postureBrokenExpiry or now < state.attackEndsAt then
		return false, false
	end

	state.blocking = true
	BotAnimator.PlayBlockHold(botModel)

	local parryAvailable = now >= state.parryCooldownExpiry
	if parryAvailable then
		state.parryWindowExpiry = now + Constants.Combat.ParryWindowSeconds
		state.parryCooldownExpiry = now + Constants.Combat.ParryCooldownSeconds
		BotAnimator.PlayParryFlash(botModel)
		-- Same OBVIOUS, synced-for-all parry-window tell a player gets -- so a bot reads as a real
		-- opponent you have to respect the parry of. No ping compensation: a bot has no client/latency.
		broadcastParryWindowOpened(botModel)
	end

	logger:debug("Bot block started", { bot = botModel.Name, parryWindowOpened = parryAvailable })
	return true, parryAvailable
end

-- Server-internal equivalent of handleBlockStop, run against BotState.
function CombatSystem.RequestBotBlockStop(botModel: Model): boolean
	local state = botStates[botModel]
	if not state then
		return false
	end
	state.blocking = false
	state.parryWindowExpiry = 0
	BotAnimator.StopBlockHold(botModel)
	logger:debug("Bot block stopped", { bot = botModel.Name })
	return true
end

--
-- Constants validation -- engineering-standards.md's "validate at every external boundary"
-- applied to Constants.lua itself: it's edited by hand, not generated, so a future restructure
-- (or a stale merge) could silently drop a field a request handler relies on. Every field checked
-- here is one selectAttackDefinition/handleAttackRequest actually reads; if this validation ever
-- needs to be updated, it's because those call sites started reading something new, not the other
-- way around. Runs once at Init(), before any remote is created -- a failure here means Init()
-- aborts entirely (no remotes, no handlers) rather than letting the first real attack request hit
-- nil arithmetic deep in resolveHitAgainstTarget.
--

local REQUIRED_DEFINITION_NUMBER_FIELDS =
	{ "WindupSeconds", "ActiveSeconds", "RecoverySeconds", "Damage", "PostureDamage", "Cooldown" }

local function validateAttackDefinition(category: string, index: number, definition: unknown): boolean
	if typeof(definition) ~= "table" then
		logger:error("Invalid Constants.Combat.Hitboxes entry: not a table", { category = category, index = index })
		return false
	end

	local candidate = definition :: { [string]: unknown }
	local ok = true

	if typeof(candidate.DebugName) ~= "string" then
		logger:error("Invalid hitbox definition: DebugName missing/non-string", { category = category, index = index })
		ok = false
	end
	if typeof(candidate.Size) ~= "Vector3" then
		logger:error("Invalid hitbox definition: Size is not a Vector3", { category = category, index = index })
		ok = false
	end
	if typeof(candidate.Offset) ~= "CFrame" then
		logger:error("Invalid hitbox definition: Offset is not a CFrame", { category = category, index = index })
		ok = false
	end
	for _, field in ipairs(REQUIRED_DEFINITION_NUMBER_FIELDS) do
		if typeof(candidate[field]) ~= "number" then
			logger:error(
				"Invalid hitbox definition: field missing/non-numeric",
				{ category = category, index = index, field = field }
			)
			ok = false
		end
	end

	return ok
end

local function validateAttackCategory(category: string, stages: unknown): boolean
	if typeof(stages) ~= "table" or #(stages :: { unknown }) == 0 then
		logger:error("Constants.Combat.Hitboxes." .. category .. " is missing or empty", {})
		return false
	end

	local ok = true
	for index, definition in ipairs(stages :: { unknown }) do
		if not validateAttackDefinition(category, index, definition) then
			ok = false
		end
	end
	return ok
end

-- If this ever fails, it means CombatSystem.lua's read side (selectAttackDefinition,
-- Constants.Combat.Weapons[weaponId].Stages) and Constants.lua's data side have drifted apart. The
-- fix is to bring them back in sync (update whichever side is stale), never to silently let
-- request handlers run against missing data.
--
-- One weapon's Basic/Heavy staged arrays + single Finisher definition (Constants.Combat.
-- Weapons[weaponId].Stages) -- reuses validateAttackCategory/validateAttackDefinition above,
-- namespaced per weapon so a validation failure's log message says which weapon drifted.
local function validateWeapon(weaponId: string, weaponData: unknown): boolean
	if typeof(weaponData) ~= "table" then
		logger:error("Invalid Constants.Combat.Weapons entry: not a table", { weaponId = weaponId })
		return false
	end
	local stages = (weaponData :: { [string]: unknown }).Stages
	if typeof(stages) ~= "table" then
		logger:error("Constants.Combat.Weapons." .. weaponId .. ".Stages is missing", {})
		return false
	end
	local stagesTable = stages :: { [string]: unknown }

	local basicOk = validateAttackCategory(weaponId .. ".Basic", stagesTable.Basic)
	local heavyOk = validateAttackCategory(weaponId .. ".Heavy", stagesTable.Heavy)
	-- The finisher is a single definition, not a staged array (handleAttackRequest reads
	-- Stages.Finisher directly), so it's validated as one definition rather than a category.
	local finisherOk = validateAttackDefinition(weaponId .. ".Finisher", 1, stagesTable.Finisher)

	return basicOk and heavyOk and finisherOk
end

local function validateCombatConstants(): boolean
	local weapons = Constants.Combat.Weapons
	if typeof(weapons) ~= "table" then
		logger:error(
			"Constants.Combat.Weapons is missing -- CombatSystem.lua reads per-stage attack data from "
				.. "Constants.Combat.Weapons[weaponId].Stages.Basic/Heavy/Finisher, not a flat Hitboxes."
				.. "Basic/Heavy table. Fix Constants.lua (or CombatSystem.lua if it's the one that drifted) "
				.. "before this System can safely accept any attack request.",
			{}
		)
		return false
	end

	local primaryOk = validateWeapon("Primary", weapons.Primary)
	local secondaryOk = validateWeapon("Secondary", weapons.Secondary)
	local defaultWeaponOk = weapons.Default == "Primary" or weapons.Default == "Secondary"
	if not defaultWeaponOk then
		logger:error("Constants.Combat.Weapons.Default missing/invalid or doesn't name a real weapon", {})
	end
	local swapCooldownOk = typeof(weapons.SwapCooldownSeconds) == "number" and weapons.SwapCooldownSeconds >= 0
	if not swapCooldownOk then
		logger:error("Constants.Combat.Weapons.SwapCooldownSeconds missing/invalid", {})
	end

	local hitboxes = Constants.Combat.Hitboxes
	if typeof(hitboxes) ~= "table" then
		logger:error("Constants.Combat.Hitboxes (geometry/sampling table) is missing", {})
		return false
	end

	local sampleRateOk = typeof(hitboxes.SampleRate) == "number" and hitboxes.SampleRate > 0
	if not sampleRateOk then
		logger:error("Constants.Combat.Hitboxes.SampleRate missing/invalid", {})
	end
	local maxSamplesOk = typeof(hitboxes.MaxSamplesPerSwing) == "number" and hitboxes.MaxSamplesPerSwing > 0
	if not maxSamplesOk then
		logger:error("Constants.Combat.Hitboxes.MaxSamplesPerSwing missing/invalid", {})
	end
	local maxCandidateRadiusOk = typeof(hitboxes.MaxCandidateRadius) == "number" and hitboxes.MaxCandidateRadius > 0
	if not maxCandidateRadiusOk then
		logger:error("Constants.Combat.Hitboxes.MaxCandidateRadius missing/invalid", {})
	end
	local sweepSubstepsOk = typeof(hitboxes.SweepSubsteps) == "number" and hitboxes.SweepSubsteps > 0
	if not sweepSubstepsOk then
		logger:error("Constants.Combat.Hitboxes.SweepSubsteps missing/invalid", {})
	end
	local maxPartsPerQueryOk = typeof(hitboxes.MaxPartsPerQuery) == "number" and hitboxes.MaxPartsPerQuery > 0
	if not maxPartsPerQueryOk then
		logger:error("Constants.Combat.Hitboxes.MaxPartsPerQuery missing/invalid", {})
	end

	local ok = primaryOk
		and secondaryOk
		and defaultWeaponOk
		and swapCooldownOk
		and sampleRateOk
		and maxSamplesOk
		and maxCandidateRadiusOk
		and sweepSubstepsOk
		and maxPartsPerQueryOk
	if ok then
		logger:info("Combat constants validated", {
			primaryBasicStages = #weapons.Primary.Stages.Basic,
			primaryHeavyStages = #weapons.Primary.Stages.Heavy,
			secondaryBasicStages = #weapons.Secondary.Stages.Basic,
			secondaryHeavyStages = #weapons.Secondary.Stages.Heavy,
			sampleRate = hitboxes.SampleRate,
		})
	end
	return ok
end

function CombatSystem.Init(): ()
	if not validateCombatConstants() then
		logger:error("CombatSystem.Init() aborted: combat constants failed validation (see errors above)")
		return
	end

	requestBasicAttackRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.RequestBasicAttack)
	logger:debug("Remote created", { name = RemoteNames.RequestBasicAttack })
	requestHeavyAttackRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.RequestHeavyAttack)
	logger:debug("Remote created", { name = RemoteNames.RequestHeavyAttack })
	requestBlockStartRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.RequestBlockStart)
	logger:debug("Remote created", { name = RemoteNames.RequestBlockStart })
	requestBlockStopRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.RequestBlockStop)
	logger:debug("Remote created", { name = RemoteNames.RequestBlockStop })
	requestDashRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.RequestDash)
	logger:debug("Remote created", { name = RemoteNames.RequestDash })
	requestSlideRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.RequestSlide)
	logger:debug("Remote created", { name = RemoteNames.RequestSlide })
	requestSprintStartRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.RequestSprintStart)
	logger:debug("Remote created", { name = RemoteNames.RequestSprintStart })
	requestSprintStopRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.RequestSprintStop)
	logger:debug("Remote created", { name = RemoteNames.RequestSprintStop })
	requestLockOnRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.RequestLockOn)
	logger:debug("Remote created", { name = RemoteNames.RequestLockOn })
	requestSwapWeaponRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.RequestSwapWeapon)
	logger:debug("Remote created", { name = RemoteNames.RequestSwapWeapon })
	requestFeintRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.RequestFeint)
	logger:debug("Remote created", { name = RemoteNames.RequestFeint })
	requestAirTechRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.RequestAirTech)
	logger:debug("Remote created", { name = RemoteNames.RequestAirTech })

	vitalsUpdatedRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.VitalsUpdated)
	logger:debug("Remote created", { name = RemoteNames.VitalsUpdated })
	inCombatChangedRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.InCombatChanged)
	logger:debug("Remote created", { name = RemoteNames.InCombatChanged })
	feedbackEventRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.FeedbackEvent)
	logger:debug("Remote created", { name = RemoteNames.FeedbackEvent })
	lockOnChangedRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.LockOnChanged)
	logger:debug("Remote created", { name = RemoteNames.LockOnChanged })
	attackStartedRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.AttackStarted)
	logger:debug("Remote created", { name = RemoteNames.AttackStarted })
	blockStartedRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.BlockStarted)
	logger:debug("Remote created", { name = RemoteNames.BlockStarted })
	movementPerformedRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.MovementPerformed)
	logger:debug("Remote created", { name = RemoteNames.MovementPerformed })
	slidePerformedRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.SlidePerformed)
	logger:debug("Remote created", { name = RemoteNames.SlidePerformed })
	comboStateChangedRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.ComboStateChanged)
	logger:debug("Remote created", { name = RemoteNames.ComboStateChanged })
	weaponChangedRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.WeaponChanged)
	logger:debug("Remote created", { name = RemoteNames.WeaponChanged })
	actionRejectedRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.ActionRejected)
	logger:debug("Remote created", { name = RemoteNames.ActionRejected })
	parryWindowOpenedRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.ParryWindowOpened)
	logger:debug("Remote created", { name = RemoteNames.ParryWindowOpened })
	feintPerformedRemote = NetworkBridge.CreateRemoteEvent(RemoteNames.FeintPerformed)
	logger:debug("Remote created", { name = RemoteNames.FeintPerformed })

	requestBasicAttackRemote.OnServerEvent:Connect(function(player: Player, rawHoldingJump: unknown)
		-- Coerce the client's jump-held hint to a strict boolean at the boundary (never trust the raw
		-- payload's type) -- it only ever selects Uppercut vs a normal finisher, see handleAttackRequest.
		handleAttackRequest(player, false, rawHoldingJump == true)
	end)
	logger:debug("Handler connected", { remote = RemoteNames.RequestBasicAttack })

	requestHeavyAttackRemote.OnServerEvent:Connect(function(player: Player)
		handleAttackRequest(player, true, false)
	end)
	logger:debug("Handler connected", { remote = RemoteNames.RequestHeavyAttack })

	requestBlockStartRemote.OnServerEvent:Connect(function(player: Player)
		handleBlockStart(player)
	end)
	logger:debug("Handler connected", { remote = RemoteNames.RequestBlockStart })

	requestBlockStopRemote.OnServerEvent:Connect(function(player: Player)
		handleBlockStop(player)
	end)
	logger:debug("Handler connected", { remote = RemoteNames.RequestBlockStop })

	requestDashRemote.OnServerEvent:Connect(function(player: Player, rawViaDoubleTapForward: unknown)
		handleDashRequest(player, rawViaDoubleTapForward)
	end)
	logger:debug("Handler connected", { remote = RemoteNames.RequestDash })

	requestSlideRemote.OnServerEvent:Connect(function(player: Player)
		handleSlideRequest(player)
	end)
	logger:debug("Handler connected", { remote = RemoteNames.RequestSlide })

	requestSprintStartRemote.OnServerEvent:Connect(function(player: Player)
		handleSprintStart(player)
	end)
	logger:debug("Handler connected", { remote = RemoteNames.RequestSprintStart })

	requestSprintStopRemote.OnServerEvent:Connect(function(player: Player)
		handleSprintStop(player)
	end)
	logger:debug("Handler connected", { remote = RemoteNames.RequestSprintStop })

	requestLockOnRemote.OnServerEvent:Connect(function(player: Player, rawTargetUserId: unknown)
		handleLockOnRequest(player, rawTargetUserId)
	end)
	logger:debug("Handler connected", { remote = RemoteNames.RequestLockOn })

	requestSwapWeaponRemote.OnServerEvent:Connect(function(player: Player)
		handleSwapWeaponRequest(player)
	end)
	logger:debug("Handler connected", { remote = RemoteNames.RequestSwapWeapon })

	requestFeintRemote.OnServerEvent:Connect(function(player: Player)
		handleFeintRequest(player)
	end)
	logger:debug("Handler connected", { remote = RemoteNames.RequestFeint })

	requestAirTechRemote.OnServerEvent:Connect(function(player: Player)
		handleAirTechRequest(player)
	end)
	logger:debug("Handler connected", { remote = RemoteNames.RequestAirTech })

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end

	RunService.Heartbeat:Connect(onHeartbeat)

	logger:info("CombatSystem.Init() complete")
end

-- Not cast to Types.SystemModule (unlike the other still-stub Systems) -- this module's public
-- surface is genuinely wider than the minimal Init-only lifecycle contract (GetCombatState,
-- IsAlive, OnPlayerKilled, ApplyServerDamage), and callers that require() this module directly
-- should see those types, not have them erased by a narrower cast.
return CombatSystem
