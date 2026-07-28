--!strict
--[[
	BotCombat.lua

	Owns: training bot lifecycle (creation/eviction, death, despawn) and hit-resolution MECHANICS in
	either direction -- a real player attacking a bot (ResolveHitAgainstBot/triggerBotPostureBreak)
	and a bot attacking its owner (ResolveHitFromBotAgainstPlayer) -- plus the bot's own per-tick
	vitals regen and facing-toward-owner update (Update). Moved out of CombatSystem.lua (Chief
	Architect's decomposition audit) as its own Server/Combat/ sibling: a training bot is additive to
	real combat (CombatSystem.lua's own combatStates/CombatState stay untouched -- see BotState's own
	header in CombatTypes.lua), so its mechanics don't belong inside the real-player state machine
	either.

	Boundary with TrainingBotSystem.lua (which owns bot AI *decision-making* -- presets, weights, the
	Attack/Block/Parry weighted-reroll loop): that System never reaches into this module at all, or
	into CombatSystem.lua's internals -- it drives a bot purely through CombatSystem's own public
	RequestBotAttack/RequestBotBlockStart/RequestBotBlockStop/GetBotState/SpawnTrainingBot/
	DespawnTrainingBot surface, the same "server owns truth" boundary a real client already respects,
	just server-internal (see TrainingBotSystem.lua's own header). Those five public functions still
	live on CombatSystem.lua (unchanged public API, per this decomposition's own "no public API
	change" rule) -- CombatSystem.lua's own bodies now call into this module's GetLiveBotState/
	SpawnBot/DespawnBot instead of a private botStates table, but TrainingBotSystem.lua's own
	dependency graph is completely unaffected: it still only ever requires CombatSystem.lua, never
	this module.

	Boundary with CombatSystem.lua itself: that System still owns the swing-scheduling pipeline that
	decides a bot was hit at all in either direction (getSwingCandidates/onSwingHitCandidate for a
	player's own swing landing on their bot; getBotSwingCandidates/onBotSwingHitCandidate/
	startBotAttackSwing for the bot's OWN swing against its owner) -- this module never
	geometry-queries or schedules a swing itself, only resolves one CombatSystem.lua has already
	validated. It also still owns the two things this module needs from CombatSystem's own private
	world that it has no business owning itself: the Combat_FeedbackEvent/Combat_VitalsUpdated
	remotes (SendFeedback/SendVitals) and the real-player posture-break trigger
	(TriggerPlayerPostureBreak, CombatSystem.lua's own private triggerPostureBreak -- a bot's parry
	punish or a bot's own landed hit can each posture-break a REAL PLAYER, who has vitals/feedback
	infrastructure this module was never meant to own). All three are registered once via Init
	(called from CombatSystem.Init(), before any remote/Players wiring) rather than threaded as a
	per-call parameter -- see DummyCombat.lua's identical Init pattern for the same reasoning, plus
	one more: this module's confirmBotDeath fires from a Humanoid.Died CONNECTION set up once at bot-
	creation time, not from a per-call site CombatSystem.lua could hand fresh hooks to, so at least
	one of these three genuinely needs to be module-level state regardless.

	Does not own: authorization (DevMenuSystem.lua's whitelist gates every call into SpawnBot, the
	same trust CombatSystem.SpawnTrainingBot's own callers already placed in it -- that public
	function is now a one-line wrapper around this module's SpawnBot), preset/weight validation or AI
	decisions (TrainingBotSystem.lua, see the boundary note above), or the real-player combat state
	machine (CombatState/combatStates stay exactly in CombatSystem.lua).
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local Logger = require(ReplicatedStorage.Shared.Logger)
local CombatTypes = require(script.Parent.CombatTypes)
local HitResolution = require(script.Parent.HitResolution)
local Movement = require(script.Parent.Movement)
local BotAnimator = require(script.Parent.BotAnimator)
local CombatantLabel = require(script.Parent.CombatantLabel)
local FeedbackPayload = require(script.Parent.FeedbackPayload)

local logger = Logger.scope("BotCombat")

local BotCombat = {}

type CombatState = CombatTypes.CombatState
type BotState = CombatTypes.BotState

-- Fired (botModel: Model, ownerPlayer: Player, killerPlayer: Player?) once per confirmed training
-- bot death. CombatSystem.lua aliases this under its own public CombatSystem.OnTrainingBotKilled
-- name (same Instance, just re-exported) so TrainingBotSystem.lua's existing
-- `CombatSystem.OnTrainingBotKilled.Event:Connect(...)` keeps working unchanged -- see this file's
-- header for why ownership of *firing* it moved here alongside the rest of bot lifecycle.
local OnTrainingBotKilled = Instance.new("BindableEvent")
BotCombat.OnTrainingBotKilled = OnTrainingBotKilled

-- Fired (botModel: Model) from despawnBot, unconditionally, for every path a bot's model stops being
-- tracked -- cap eviction, the explicit DespawnBot API, all of it. CombatSystem.lua aliases this the
-- same way as OnTrainingBotKilled above.
local OnTrainingBotDespawned = Instance.new("BindableEvent")
BotCombat.OnTrainingBotDespawned = OnTrainingBotDespawned

-- Injected access to CombatSystem.lua's own private world -- see this file's header for the full
-- reasoning on why these three stay callbacks instead of a back-reference require.
export type Hooks = {
	SendFeedback: (Player, Types.CombatFeedbackPayload) -> (),
	SendVitals: (Player, CombatState) -> (),
	TriggerPlayerPostureBreak: (Player, CombatState, Player?) -> (),
}

local hooks: Hooks? = nil

function BotCombat.Init(newHooks: Hooks): ()
	hooks = newHooks
end

-- A training bot is a real combat participant that actually fights -- see BotState's own header in
-- CombatTypes.lua. Only reachable via BotCombat.SpawnBot, which only CombatSystem.SpawnTrainingBot
-- (and therefore only DevMenuSystem.lua, after its own whitelist check) ever calls.
local botStates: { [Model]: BotState } = {}
-- Every bot a given player currently owns, in spawn order -- lets SpawnBot evict the oldest once
-- Constants.Debug.TrainingBot.MaxActivePerOwner is reached, and lets GetOwnedAliveBots find "this
-- attacker's own bot(s)" in O(1) instead of scanning every bot on the server.
local botsByOwner: { [Player]: { Model } } = {}
local botsFolder: Folder? = nil
-- Pending-spawn count per owner, incremented before the yielding
-- Players:CreateHumanoidModelFromDescription call in createTrainingBot and decremented after --
-- closes a TOCTOU race where two near-simultaneous SpawnBot calls for the same owner could both read
-- botsByOwner's pre-creation count and both pass the MaxActivePerOwner cap check before either has
-- appended its new model. See SpawnBot.
local pendingBotSpawns: { [Player]: number } = {}

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
	OnTrainingBotDespawned:Fire(model)
end

local function confirmBotDeath(botModel: Model, state: BotState): ()
	if state.deathConfirmed then
		return
	end
	assert(hooks, "BotCombat.Init must run before any bot can be created")
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
		local payload = FeedbackPayload.Build("Death", killerPlayer, nil, nil, nil, nil, state.rootPart.Position)
		hooks.SendFeedback(killerPlayer, payload)
	end

	OnTrainingBotKilled:Fire(botModel, state.ownerPlayer, killerPlayer)
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
	CombatantLabel.Attach(model, "Training Bot", Constants.Debug.TrainingBot.LabelColor)
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

-- Was CombatSystem.SpawnTrainingBot's own body -- that public function is now a one-line wrapper
-- around this, per the task's "no public API change" requirement. Does NOT check authorization
-- (DevMenuSystem.lua's job) or know anything about presets/weights (TrainingBotSystem.lua's job,
-- entirely after this returns) -- this function only creates the combat participant itself. Evicts
-- the owner's oldest bot once Constants.Debug.TrainingBot.MaxActivePerOwner is reached (a bot is a
-- private sparring partner, one per owner, not a squad). Returns (model, nil) on success or (nil,
-- reasonString) on failure.
function BotCombat.SpawnBot(ownerPlayer: Player, spawnCFrame: CFrame): (Model?, string?)
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

-- Was CombatSystem.DespawnTrainingBot's own body -- that public function is now a one-line wrapper
-- around this. Removes a training bot immediately (no death animation/delay). Returns false if
-- botModel isn't a currently-tracked bot (already despawned, or never one).
function BotCombat.DespawnBot(botModel: Model): boolean
	if not botStates[botModel] then
		return false
	end
	despawnBot(botModel)
	return true
end

-- Read-only lookup returning the SAME live BotState table this module stores (not a copy) --
-- CombatTypes.lua's BotState is explicitly shared among Server/Combat/ siblings (see that file's own
-- header), so CombatSystem.lua's own RequestBotAttack/RequestBotBlockStart/RequestBotBlockStop/
-- GetBotState/onBotSwingHitCandidate/startBotAttackSwing/getBotSwingCandidates all read AND mutate
-- fields on the returned table directly, exactly as they did against the old private botStates
-- table -- this accessor only changes WHERE the table lives, never how callers use it.
function BotCombat.GetLiveBotState(model: Model): BotState?
	return botStates[model]
end

-- Every bot `ownerPlayer` currently owns that's still alive -- CombatSystem.lua's getSwingCandidates
-- builds its own swing-candidate roster from this instead of reaching into a private table (bounded
-- by Constants.Debug.TrainingBot.MaxActivePerOwner -- one bot per owner today, the same cost this
-- loop already had scanning botsByOwner directly before this module existed).
function BotCombat.GetOwnedAliveBots(ownerPlayer: Player): { BotState }
	local owned = botsByOwner[ownerPlayer]
	if not owned then
		return {}
	end
	local alive: { BotState } = {}
	for _, botModel in ipairs(owned) do
		local botState = botStates[botModel]
		if botState and botState.alive then
			table.insert(alive, botState)
		end
	end
	return alive
end

-- Bot equivalent of CombatSystem.lua's own triggerPostureBreak -- unlike the dummy version, also
-- drops the bot's own block the way the player-side version does (a bot can be mid-block when this
-- fires; a dummy never can).
local function triggerBotPostureBreak(
	botState: BotState,
	attackerPlayer: Player?,
	sendFeedback: (Player, Types.CombatFeedbackPayload) -> ()
): ()
	if not HitResolution.ApplyPostureBreak(botState, botState.humanoid) then
		return
	end
	botState.blocking = false

	logger:info("Posture break triggered (bot)", {
		bot = botState.model.Name,
		attacker = if attackerPlayer then attackerPlayer.Name else "none",
	})

	if attackerPlayer then
		local payload =
			FeedbackPayload.Build("PostureBreak", attackerPlayer, nil, nil, nil, nil, botState.rootPart.Position)
		sendFeedback(attackerPlayer, payload)
	end
end

-- Bot-as-defender equivalent of CombatSystem.lua's resolveHitAgainstTarget -- a real player attacked,
-- a training bot got hit. Mirrors that function's block/parry logic exactly (same Constants.Combat
-- numbers) but against BotState fields instead of a second CombatState, and only ever sends feedback
-- to attackerPlayer (the bot has no client of its own -- same one-sided reasoning as
-- DummyCombat.ResolveHit, just with real block/parry mitigation this time since a bot, unlike a
-- dummy, actually blocks/parries).
--
-- `attackerState` is the attacker's own live CombatState -- always already resolved and non-nil at
-- the one call site (CombatSystem.lua's onSwingHitCandidate already receives it as its own
-- parameter). Returns whether the hit CONNECTED -- startAttackSwing's OnHit gates M1 combo
-- advancement on it, mirroring resolveHitAgainstTarget's identical contract.
function BotCombat.ResolveHitAgainstBot(
	attackerPlayer: Player,
	attackerState: CombatState,
	botState: BotState,
	definition: Types.HitboxAttackDefinition,
	isHeavy: boolean,
	finisherVariant: Types.FinisherVariant?
): boolean
	assert(hooks, "BotCombat.Init must run before any hit can resolve against a bot")
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

		HitResolution.ApplyParryPunish(attackerState.Vitals, now)
		hooks.SendVitals(attackerPlayer, attackerState)

		local payload = FeedbackPayload.Build("Parried", attackerPlayer, nil, nil, nil, isHeavy, targetPosition)
		hooks.SendFeedback(attackerPlayer, payload)

		if attackerState.Vitals.posture <= 0 then
			hooks.TriggerPlayerPostureBreak(attackerPlayer, attackerState, nil)
			hooks.SendVitals(attackerPlayer, attackerState)
		end

		if HitResolution.ShouldDisarm(defenseKind, isHeavy) then
			HitResolution.ApplyDisarm(attackerState.Vitals, now)
			local disarmPayload =
				FeedbackPayload.Build("Disarmed", attackerPlayer, nil, nil, nil, isHeavy, targetPosition)
			hooks.SendFeedback(attackerPlayer, disarmPayload)
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
		-- since a bot's position is driven directly (BotCombat.Update), not by WalkSpeed, so there'd
		-- be nothing for it to visibly do. The stun half still matters: it briefly gates the bot's own
		-- next RequestBotAttack/RequestBotBlockStart. The bot's own Hit1/2/3 flinch is the visible
		-- half -- same "never while Block" gating as the player-facing PlayHitReaction.
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
	local payload = FeedbackPayload.Build(kind, attackerPlayer, nil, finalDamage, finalPosture, isHeavy, targetPosition)
	hooks.SendFeedback(attackerPlayer, payload)

	if botState.posture <= 0 and not wasPostureBroken then
		triggerBotPostureBreak(botState, attackerPlayer, hooks.SendFeedback)
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

-- Bot-as-attacker equivalent of CombatSystem.lua's resolveHitAgainstTarget -- a training bot attacked
-- its owner. Mirrors that function's block/parry logic exactly, attacker side now being BotState
-- instead of CombatState; a successful parry against the bot punishes botState's own posture/stun
-- instead of a second player's, and feedback only ever goes to targetPlayer (the bot has no client).
-- Passing nil for the "attacker" in FeedbackPayload.Build/TriggerPlayerPostureBreak below is
-- deliberate -- a bot has no Player identity to attribute, and CombatClient.lua already treats a nil
-- AttackerUserId as "not me" for anything gated on the local player being the attacker (e.g. the
-- stun-effect/hit-sound triggers), which is exactly correct here: the human defender is never the
-- one who gets punished for a bot's own attack.
--
-- `targetState` is the target's own live CombatState -- always already resolved and non-nil at the
-- one call site (CombatSystem.lua's onBotSwingHitCandidate). Any outside hit resolving against the
-- target that ends a suspended air-tech exchange (see CombatState.airComboSuspendedUntil's own
-- header) is the CALLER's responsibility now, run immediately before this function -- see
-- onBotSwingHitCandidate's own comment for why that stayed in CombatSystem.lua rather than becoming
-- a fourth Hook.
function BotCombat.ResolveHitFromBotAgainstPlayer(
	botState: BotState,
	targetPlayer: Player,
	targetState: CombatState,
	definition: Types.HitboxAttackDefinition,
	isHeavy: boolean
): ()
	assert(hooks, "BotCombat.Init must run before any hit can resolve from a bot")
	local targetHumanoid = targetState.humanoid
	if not targetHumanoid then
		return
	end

	local now = os.clock()

	-- Refreshes the real player's own InCombat (BotState has no such field -- a bot isn't a real
	-- system consumer of this flag today, see CombatState.inCombatUntil's own header).
	targetState.inCombatUntil = now + Constants.Combat.InCombatDurationSeconds

	local wasPostureBroken = now < targetState.Vitals.postureBrokenExpiry
	local defenseKind = HitResolution.ClassifyDefense(
		now,
		targetState.Vitals.postureBrokenExpiry,
		targetState.Vitals.parryWindowExpiry,
		targetState.blocking
	)

	if defenseKind == "Parry" then
		logger:info("Parry detected (bot attacker)", {
			attacker = botState.model.Name,
			defender = targetPlayer.Name,
			attack = definition.DebugName,
		})

		targetState.Vitals.parryWindowExpiry = 0

		botState.posture = math.max(0, botState.posture - Constants.Combat.ParryPunishPostureDamage)
		botState.stunExpiry = now + Constants.Combat.StunDuration

		local payload = FeedbackPayload.Build("Parried", nil, targetPlayer, nil, nil, isHeavy)
		hooks.SendFeedback(targetPlayer, payload)

		if botState.posture <= 0 then
			triggerBotPostureBreak(botState, targetPlayer, hooks.SendFeedback)
		end

		if HitResolution.ShouldDisarm(defenseKind, isHeavy) then
			HitResolution.ApplyDisarm(botState, now)
			local disarmPayload = FeedbackPayload.Build("Disarmed", nil, targetPlayer, nil, nil, isHeavy)
			hooks.SendFeedback(targetPlayer, disarmPayload)
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
	if HitResolution.IsGodmode(targetState) then
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

	targetState.Vitals.posture = math.max(0, targetState.Vitals.posture - finalPosture)

	if defenseKind ~= "Block" then
		-- Same universal hit reaction as resolveHitAgainstTarget's -- the human defender getting hit
		-- by a bot reacts exactly like getting hit by a real attacker. Slow goes through the unified
		-- resolver for the same single-writer reasons as that site.
		targetState.Vitals.stunExpiry = math.max(targetState.Vitals.stunExpiry, now + Constants.Combat.HitStunDuration)
		targetState.Vitals.hitSlowExpiry = now + Constants.Combat.HitSlowDuration
		targetHumanoid.WalkSpeed = Movement.ComputeDesiredWalkSpeed(targetState, now)
	end

	if finalDamage > 0 then
		targetHumanoid:TakeDamage(finalDamage)
	end

	hooks.SendVitals(targetPlayer, targetState)

	local kind: Types.CombatFeedbackKind = if defenseKind == "Block" then "Blocked" else "Hit"
	local payload =
		FeedbackPayload.Build(kind, nil, targetPlayer, finalDamage, finalPosture, isHeavy, nil, definition.DebugName)
	hooks.SendFeedback(targetPlayer, payload)

	if targetState.Vitals.posture <= 0 and not wasPostureBroken then
		hooks.TriggerPlayerPostureBreak(targetPlayer, targetState, nil)
		hooks.SendVitals(targetPlayer, targetState)
	end
end

-- Per-tick bot bookkeeping -- posture regen, plus a continuous facing update toward its owner so
-- arc-gated attacks (both the bot's own swings and the owner's swings against it) can actually land
-- without any real movement/pathfinding -- TrainingBotSystem.lua's header explains why translation/
-- chasing is out of scope for now. Rotation only, position untouched, so this never fights the
-- Humanoid's own physics. Driven from CombatSystem.lua's own onHeartbeat, the same "single Heartbeat
-- drives every sibling's Update" pattern HitboxResolver/RagdollController/DummyCombat already use.
-- `resolveOwnerRootPart` is how this module learns the owner's current rootPart without reaching
-- into CombatSystem.lua's private combatStates itself -- returns nil if the owner has no live,
-- alive, rootPart-bound CombatState right now (bot just keeps its current facing that tick).
function BotCombat.Update(now: number, deltaTime: number, resolveOwnerRootPart: (Player) -> BasePart?): ()
	for _, botState in pairs(botStates) do
		if not botState.alive then
			continue
		end

		if now >= botState.postureBrokenExpiry and botState.posture < botState.maxPosture then
			botState.posture =
				math.min(botState.maxPosture, botState.posture + Constants.Combat.PostureRegenPerSecond * deltaTime)
		end

		local ownerRootPart = resolveOwnerRootPart(botState.ownerPlayer)
		if ownerRootPart then
			local toOwner = ownerRootPart.Position - botState.rootPart.Position
			local flatToOwner = Vector3.new(toOwner.X, 0, toOwner.Z)
			if flatToOwner.Magnitude > Constants.Combat.ZeroVectorEpsilon then
				botState.rootPart.CFrame =
					CFrame.lookAt(botState.rootPart.Position, botState.rootPart.Position + flatToOwner)
			end
		end
	end
end

return BotCombat
