--!strict
--[[
	TrainingBotSystem.lua

	Owns: everything CombatSystem.lua deliberately does NOT know about a training bot -- preset/
	weight data (ai-design.md's "Training bots" section: attack-only, block-only, parry-only,
	full-fight, aggressor, turtle, custom), validating a
	client-submitted spawn request before it ever reaches CombatSystem, and the AI decision loop
	that actually drives a spawned bot's actions. Talks to CombatSystem.lua exclusively through its
	public surface (SpawnTrainingBot/DespawnTrainingBot/GetBotState/RequestBot*/OnHeartbeatTick/
	OnTrainingBotKilled) -- the same "server owns truth" boundary a real client respects, just
	server-internal. Never reaches into CombatSystem's botStates or any other internal table.

	ParryOnly is a TIMING BEHAVIOR, not a separate weighted action: CombatSystem.lua's
	handleBlockStart merged Block and Parry into one input for real players (a Block press
	conditionally opens a short parry window), so there is no discrete "parry" request to weight
	against "attack"/"block" the way ai-design.md's original phrasing implies. Concretely: a
	Block-preset bot presses Block and HOLDS it (continuous guard); a Parry-preset bot stays
	unguarded and only presses Block reactively, timed against a detected incoming swing, then
	releases again shortly after -- hunting parries instead of turtling. Both still ultimately call
	CombatSystem.RequestBotBlockStart; only the calling pattern differs. See runBotDecisionTick.

	Movement: bots never translate/chase (CombatSystem.lua's onHeartbeat gives them a continuous
	facing update toward their owner, which is all arc-gated melee actually needs) -- this repo has
	no pathfinding/movement-AI infrastructure, so real repositioning/kiting-immunity is out of scope
	for now. Reposition stays present in Types.TrainingBotWeights for forward compatibility but is a
	documented no-op here.

	Respawn: CombatSystem.lua does not auto-respawn a bot the way it does a training dummy (it has
	no preset/weight data to recreate one with) -- this System listens for
	CombatSystem.OnTrainingBotKilled and decides whether/how to respawn, after
	Constants.Debug.TrainingBot.RespawnDelay, at the same spawn point with the same preset.

	Does not own: hit resolution, vitals, or any combat mechanic (CombatSystem.lua); authorization
	(DevMenuSystem.lua re-checks the whitelist server-side before ever calling into this System).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local Logger = require(ReplicatedStorage.Shared.Logger)

local CombatSystem = require(script.Parent.CombatSystem)

local logger = Logger.scope("TrainingBotSystem")

local TrainingBotSystem = {}

-- Preset weight table, heavy-attack chance, and parry-hold buffer all live in
-- Constants.Debug.TrainingBot (PresetWeights/HeavyAttackChance/ParryHoldBufferSeconds) -- were
-- module-local constants here, moved per luau-coding-standards.md's "no magic numbers in system
-- logic" alongside their existing siblings (RespawnDelay, SpawnDistance, etc).
local PRESET_WEIGHTS: { [string]: Types.TrainingBotWeights } = Constants.Debug.TrainingBot.PresetWeights

local VALID_PRESET_NAMES: { [string]: boolean } = {
	AttackOnly = true,
	BlockOnly = true,
	ParryOnly = true,
	FullFight = true,
	Aggressor = true,
	Turtle = true,
	Custom = true,
}

type BotAIState = {
	ownerPlayer: Player,
	presetName: Types.TrainingBotPresetName,
	weights: Types.TrainingBotWeights,
	spawnCFrame: CFrame,
	nextDecisionAt: number,
	-- True while a reactive parry-timing press is already scheduled (task.delay pending) for the
	-- swing currently in progress -- guards against re-scheduling a second press for the same
	-- swing on every tick while the owner's Attacking flag stays true.
	reactingToAttack: boolean,
}

local botAIStates: { [Model]: BotAIState } = {}

local function clampWeight(value: unknown): number
	if typeof(value) ~= "number" or value ~= value then -- typeof guard + NaN guard
		return 0
	end
	return math.clamp(value, 0, Constants.Debug.TrainingBot.MaxCustomWeight)
end

-- Server-side trust boundary for a client-submitted spawn request (ai-design.md: training bots
-- "must not become a backdoor for client-authoritative combat state"). Returns (weights,
-- presetName) on success; (nil, nil, rejectionReason) on failure. The returned weights table is
-- always freshly built here, never the client-submitted table itself, so a caller can never end up
-- holding (and later mutating) client-controlled data.
function TrainingBotSystem.ValidatePresetRequest(
	rawPresetName: unknown,
	rawCustomWeights: unknown
): (Types.TrainingBotWeights?, Types.TrainingBotPresetName?, string?)
	if typeof(rawPresetName) ~= "string" or not VALID_PRESET_NAMES[rawPresetName] then
		return nil, nil, "InvalidPreset"
	end
	local presetName = rawPresetName :: Types.TrainingBotPresetName

	if presetName ~= "Custom" then
		return table.clone(PRESET_WEIGHTS[presetName]), presetName, nil
	end

	if typeof(rawCustomWeights) ~= "table" then
		return nil, nil, "InvalidCustomWeights"
	end
	local candidate = rawCustomWeights :: { [string]: unknown }
	local weights: Types.TrainingBotWeights = {
		Attack = clampWeight(candidate.Attack),
		Block = clampWeight(candidate.Block),
		Parry = clampWeight(candidate.Parry),
		Reposition = clampWeight(candidate.Reposition),
	}
	return weights, presetName, nil
end

-- Attaches AI bookkeeping to an already-spawned bot (CombatSystem.SpawnTrainingBot must have
-- already succeeded) -- called by DevMenuSystem.lua after spawning, and by this System's own
-- respawn-after-death path.
function TrainingBotSystem.RegisterBot(
	botModel: Model,
	ownerPlayer: Player,
	presetName: Types.TrainingBotPresetName,
	weights: Types.TrainingBotWeights,
	spawnCFrame: CFrame
): ()
	botAIStates[botModel] = {
		ownerPlayer = ownerPlayer,
		presetName = presetName,
		weights = weights,
		spawnCFrame = spawnCFrame,
		nextDecisionAt = os.clock(),
		reactingToAttack = false,
	}
	logger:info("Training bot registered", { bot = botModel.Name, owner = ownerPlayer.Name, preset = presetName })
end

-- Reactive parry-timing watch -- only for bots with a nonzero Parry weight (see file header for
-- why this is behavioral, not a separate action). Runs every tick (not gated by
-- DecisionIntervalSeconds) because timing precision matters; the poll itself is a single dictionary
-- read per bot, not a scan, so this stays cheap. A late/mistimed press degrades gracefully for
-- free -- BotCombat.lua's ResolveHitAgainstBot already treats a press that lands after
-- parryWindowExpiry as a plain block, not a special case.
local function updateParryWatch(botModel: Model, aiState: BotAIState, botSnapshot: Types.CombatSnapshot): ()
	if aiState.weights.Parry <= 0 or botSnapshot.Blocking or botSnapshot.Attacking then
		return
	end

	local ownerSnapshot = CombatSystem.GetCombatState(aiState.ownerPlayer)
	local ownerAttacking = ownerSnapshot ~= nil and ownerSnapshot.Attacking

	if not ownerAttacking then
		aiState.reactingToAttack = false
		return
	end
	if aiState.reactingToAttack then
		return
	end
	aiState.reactingToAttack = true

	task.delay(Constants.Debug.TrainingBot.ReactionTimeSeconds, function()
		local liveState = botAIStates[botModel]
		if not liveState then
			return -- bot despawned while the reaction delay was pending
		end
		liveState.reactingToAttack = false

		local liveSnapshot = CombatSystem.GetBotState(botModel)
		if not liveSnapshot or not liveSnapshot.Alive or liveSnapshot.Attacking or liveSnapshot.Blocking then
			return
		end

		-- parryWindowOpened is false when the bot's own parry is still on cooldown -- in that case
		-- this press can only ever resolve as a plain block (CombatSystem.RequestBotBlockStart
		-- still starts one), which is a pointless flash-of-guard for a Parry-preset bot per this
		-- file's header ("stays unguarded and only presses Block reactively... hunting parries").
		-- Release immediately instead of holding for the parry window it never opened.
		local accepted, parryWindowOpened = CombatSystem.RequestBotBlockStart(botModel)
		if not accepted then
			return
		end
		if not parryWindowOpened then
			CombatSystem.RequestBotBlockStop(botModel)
			return
		end

		task.delay(Constants.Combat.ParryWindowSeconds + Constants.Debug.TrainingBot.ParryHoldBufferSeconds, function()
			if botAIStates[botModel] then
				CombatSystem.RequestBotBlockStop(botModel)
			end
		end)
	end)
end

-- Periodic weighted stance reroll -- gated by Constants.Debug.TrainingBot.DecisionIntervalSeconds,
-- separate from (and slower than) the reactive parry watch above. Only ever chooses between Attack
-- and Block (a two-way split of just those two weights) -- Parry isn't a "hold" state to roll into,
-- it's handled entirely by updateParryWatch, so including it here would double-represent the same
-- weight in two mechanisms.
local function rerollStance(botModel: Model, aiState: BotAIState, botSnapshot: Types.CombatSnapshot): ()
	if botSnapshot.Attacking then
		return
	end

	if botSnapshot.Blocking then
		-- Currently holding a continuous guard (Block-preset behavior, or FullFight/Turtle/etc
		-- leaning that way) -- small chance to drop guard and attack instead. Reactive parry
		-- presses release themselves on their own short timer in updateParryWatch, so this branch
		-- only ever sees a deliberately-held guard, never a reactive one.
		local total = aiState.weights.Attack + aiState.weights.Block
		if total > 0 and math.random() * total < aiState.weights.Attack then
			CombatSystem.RequestBotBlockStop(botModel)
		end
		return
	end

	local total = aiState.weights.Attack + aiState.weights.Block
	if total <= 0 then
		return
	end

	if math.random() * total < aiState.weights.Attack then
		local isHeavy = math.random() < Constants.Debug.TrainingBot.HeavyAttackChance
		CombatSystem.RequestBotAttack(botModel, isHeavy)
	else
		CombatSystem.RequestBotBlockStart(botModel)
	end
end

local function runBotDecisionTick(_deltaTime: number): ()
	local now = os.clock()
	for botModel, aiState in pairs(botAIStates) do
		local botSnapshot = CombatSystem.GetBotState(botModel)
		if not botSnapshot or not botSnapshot.Alive then
			continue
		end

		updateParryWatch(botModel, aiState, botSnapshot)

		if now < aiState.nextDecisionAt then
			continue
		end
		aiState.nextDecisionAt = now + Constants.Debug.TrainingBot.DecisionIntervalSeconds

		rerollStance(botModel, aiState, botSnapshot)
	end
end

local function onTrainingBotKilled(botModel: Model, ownerPlayer: Player, killerPlayer: Player?): ()
	local aiState = botAIStates[botModel]
	botAIStates[botModel] = nil
	if not aiState then
		return
	end

	logger:info("Training bot killed -- scheduling respawn", {
		bot = botModel.Name,
		owner = ownerPlayer.Name,
		killer = if killerPlayer then killerPlayer.Name else "none",
	})

	task.delay(Constants.Debug.TrainingBot.RespawnDelay, function()
		-- Despawn the dead bot's model UNCONDITIONALLY, before the owner-left check below -- only the
		-- RESPAWN is conditional on the owner still being here, never the cleanup.
		--
		-- Ordering matters and this used to leak: this handler clears botAIStates[botModel] up front
		-- (so a second kill can't double-schedule), which means onPlayerRemoving's own sweep over
		-- botAIStates no longer sees this bot and cannot clean it up either. With the despawn sitting
		-- below an early `return` for a departed owner, a player who disconnected inside the
		-- RespawnDelay window left the model permanently orphaned -- along with BotCombat's botStates
		-- entry, botsByOwner (retaining the departed Player as a live dict key), BotAnimator's
		-- tracksByBot entry, and, if the bot died mid-block, a per-bot RunService.Heartbeat connection
		-- that goes on reasserting animation weight on a dead track forever. Nothing else in the
		-- codebase would ever have collected it.
		CombatSystem.DespawnTrainingBot(botModel)

		if not ownerPlayer.Parent then
			return -- owner left before the respawn timer elapsed; the despawn above still ran
		end

		local newModel, failureReason = CombatSystem.SpawnTrainingBot(ownerPlayer, aiState.spawnCFrame)
		if not newModel then
			logger:warn("Training bot respawn failed", { owner = ownerPlayer.Name, reason = failureReason })
			return
		end

		TrainingBotSystem.RegisterBot(newModel, ownerPlayer, aiState.presetName, aiState.weights, aiState.spawnCFrame)
		logger:info(
			"Training bot respawned",
			{ bot = newModel.Name, owner = ownerPlayer.Name, preset = aiState.presetName }
		)
	end)
end

local function onPlayerRemoving(player: Player): ()
	for botModel, aiState in pairs(botAIStates) do
		if aiState.ownerPlayer == player then
			botAIStates[botModel] = nil
			CombatSystem.DespawnTrainingBot(botModel)
		end
	end
end

-- Drops this System's own AI-state bookkeeping for a bot model that stopped being tracked for any
-- reason OTHER than a real kill (cap eviction today; any future silent-despawn path automatically
-- too, since CombatSystem.lua's despawnBot fires this unconditionally) -- see
-- CombatSystem.OnTrainingBotDespawned's own comment for why this is a separate event from
-- OnTrainingBotKilled rather than reusing it. Idempotent: onTrainingBotKilled already clears this
-- same entry for a real death, so this is a harmless no-op removal of an already-nil key in that
-- case.
local function onTrainingBotDespawned(botModel: Model): ()
	botAIStates[botModel] = nil
end

function TrainingBotSystem.Init(): ()
	CombatSystem.OnHeartbeatTick.Event:Connect(runBotDecisionTick)
	CombatSystem.OnTrainingBotKilled.Event:Connect(onTrainingBotKilled)
	CombatSystem.OnTrainingBotDespawned.Event:Connect(onTrainingBotDespawned)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	logger:info("TrainingBotSystem.Init() complete")
end

-- Not cast to Types.SystemModule -- same reasoning as CombatSystem.lua's own return: this module's
-- public surface (ValidatePresetRequest, RegisterBot) is wider than the minimal Init-only
-- lifecycle contract.
return TrainingBotSystem
