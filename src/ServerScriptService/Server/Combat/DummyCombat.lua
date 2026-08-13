--!strict
--[[
	DummyCombat.lua

	Owns: training dummy lifecycle and hit resolution -- creation/eviction (SpawnDummy), death +
	auto-respawn (confirmDummyDeath/createTrainingDummy's mutual recursion), the per-tick posture
	regen + post-launch respawn-to-spawn reset (Update), and resolving an accepted swing that landed
	on one (ResolveHit/triggerDummyPostureBreak). Moved out of CombatSystem.lua (Chief Architect's
	decomposition audit) as its own Server/Combat/ sibling: a training dummy is additive to real
	combat (CombatSystem.lua's own combatStates/CombatState stay untouched -- see DummyState's own
	header in CombatTypes.lua), so its mechanics don't belong inside the real-player state machine
	either.

	CombatSystem.lua still owns the swing-scheduling pipeline that decides a dummy was hit at all
	(getSwingCandidates/onSwingHitCandidate, which call GetAliveDummies/GetDummyState/ResolveHit
	below only after its own arc/line-of-sight validation passes) -- this module never geometry-
	queries or validates a candidate itself. It also still owns the two things this module needs from
	CombatSystem's own private world that it has no business owning itself: the Combat_FeedbackEvent
	remote (SendFeedback) and the air-combo state machine (ApplyAirCombo -- still CombatSystem.lua's
	own private applyAirCombo as of this decomposition pass, pending its own future extraction). Both
	are passed in per-call via the Hooks table below rather than requiring CombatSystem.lua back,
	which is what keeps this a one-way dependency (CombatSystem -> DummyCombat, never the reverse).

	Does not own: authorization (DevMenuSystem.lua's whitelist gates every call into SpawnDummy, the
	same trust CombatSystem.SpawnTrainingDummy's own callers already placed in it -- that public
	function is now a one-line wrapper around this module's SpawnDummy), or the real-player combat
	state machine (CombatState/combatStates stay exactly in CombatSystem.lua).
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local Logger = require(ReplicatedStorage.Shared.Logger)
local CombatTypes = require(script.Parent.CombatTypes)
local HitResolution = require(script.Parent.HitResolution)
local RagdollController = require(script.Parent.RagdollController)
local CombatantLabel = require(script.Parent.CombatantLabel)
local FeedbackPayload = require(script.Parent.FeedbackPayload)

local logger = Logger.scope("DummyCombat")

local DummyCombat = {}

type CombatState = CombatTypes.CombatState
type DummyState = CombatTypes.DummyState
type AirComboTarget = CombatTypes.AirComboTarget

-- Injected access to CombatSystem.lua's own private world -- see this file's header for why these
-- two specifically stay callbacks instead of a back-reference require. `ApplyAirCombo` mirrors
-- CombatSystem.lua's own private applyAirCombo signature exactly. Registered once via Init (called
-- from CombatSystem.Init(), before any remote/Players wiring, so it's always set by the time a real
-- swing could ever resolve against a dummy) rather than threaded as a per-call parameter -- every
-- caller in this module already runs well after boot, and a module-level registration keeps
-- CombatSystem.lua's own call sites (onSwingHitCandidate) from having to rebuild/pass the same two
-- closures on every single hit.
export type Hooks = {
	SendFeedback: (Player, Types.CombatFeedbackPayload) -> (),
	ApplyAirCombo: (Player, CombatState, AirComboTarget, string, boolean, number) -> (),
}

local hooks: Hooks? = nil

function DummyCombat.Init(newHooks: Hooks): ()
	hooks = newHooks
end

-- A training dummy is a real hittable combat participant, just not a Player -- see DummyState's own
-- header in CombatTypes.lua. Only reachable via DummyCombat.SpawnDummy, which only
-- CombatSystem.SpawnTrainingDummy (and therefore only DevMenuSystem.lua, after its own whitelist
-- check) ever calls.
local dummyStates: { [Model]: DummyState } = {}
-- Spawn order, oldest first -- lets SpawnDummy evict the oldest dummy once
-- Constants.Debug.TrainingDummy.MaxActive is reached, without needing a separate despawn action.
local dummySpawnOrder: { Model } = {}
local dummiesFolder: Folder? = nil

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

-- Forward-declared (type only, no value yet): confirmDummyDeath needs to call this from inside a
-- task.delay callback before it's defined, since it and createTrainingDummy are naturally mutually
-- referential (death schedules a re-creation; creation wires up the Died connection that leads back
-- to death). The later `function createTrainingDummy(...)` assigns to this same local -- Lua's
-- `function name(...)` sugar resolves `name` by normal scoping, so declaring it local first is what
-- keeps that assignment from silently becoming a global.
local createTrainingDummy: (CFrame) -> DummyState

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
	-- setting Health back up does not undo it), so "respawn" means destroy the old model and create
	-- a genuinely fresh one at the same spawn point, exactly like a real player getting a new
	-- character on respawn rather than their old one being healed back up.
	task.delay(Constants.Debug.TrainingDummy.RespawnDelay, function()
		if not model.Parent then
			return -- already despawned (e.g. evicted to make room for a new one) while waiting
		end
		despawnDummy(model)
		createTrainingDummy(spawnCFrame)
		logger:info("Training dummy respawned")
	end)
end

-- Assigns the local forward-declared above -- no `local` keyword here on purpose, so this binds to
-- that existing local instead of shadowing it with a new one.
function createTrainingDummy(spawnCFrame: CFrame): DummyState
	local description = Instance.new("HumanoidDescription")
	local model = Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
	model.Name = "TrainingDummy"

	local humanoidInstance = model:FindFirstChildOfClass("Humanoid")
	assert(humanoidInstance, "CreateHumanoidModelFromDescription did not produce a Humanoid")
	local humanoid = humanoidInstance :: Humanoid
	humanoid.MaxHealth = Constants.Debug.TrainingDummy.MaxHealth
	humanoid.Health = Constants.Debug.TrainingDummy.MaxHealth
	-- Keeps the dummy as one rigid assembly on death instead of ragdolling into scattered limbs, so
	-- PivotTo-ing it back to spawnCFrame on respawn (see confirmDummyDeath) moves it cleanly.
	humanoid.BreakJointsOnDeath = false

	local rootPartInstance = model:FindFirstChild("HumanoidRootPart")
	assert(
		rootPartInstance and rootPartInstance:IsA("BasePart"),
		"CreateHumanoidModelFromDescription did not produce a HumanoidRootPart"
	)
	local rootPart = rootPartInstance :: BasePart

	model:PivotTo(spawnCFrame)
	CombatantLabel.Attach(model, "Training Dummy", Constants.Debug.TrainingDummy.LabelColor)
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

-- Was CombatSystem.SpawnTrainingDummy's own body -- that public function is now a one-line wrapper
-- around this, per the task's "no public API change" requirement. Does NOT check authorization --
-- that's DevMenuSystem.lua's job, entirely before this is ever reached. Evicts the oldest active
-- dummy once Constants.Debug.TrainingDummy.MaxActive is reached, so repeated use can't grow
-- Workspace unbounded. Returns (model, nil) on success or (nil, reasonString) on failure.
function DummyCombat.SpawnDummy(spawnCFrame: CFrame): (Model?, string?)
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

-- Read-only lookup for CombatSystem.lua's own onSwingHitCandidate -- returns the SAME live DummyState
-- table this module stores (not a copy), since CombatTypes.lua's DummyState is explicitly shared
-- among Server/Combat/ siblings (see that file's own header). The caller only ever reads fields off
-- it (alive/rootPart/model) for its own arc/LOS validation, never mutates it directly.
function DummyCombat.GetDummyState(model: Model): DummyState?
	return dummyStates[model]
end

-- Every currently-alive dummy's live state -- CombatSystem.lua's getSwingCandidates builds its own
-- swing-candidate roster from this instead of reaching into a private table (bounded by
-- Constants.Debug.TrainingDummy.MaxActive -- a handful of entries at most, the same cost this loop
-- already had scanning dummyStates directly before this module existed).
function DummyCombat.GetAliveDummies(): { DummyState }
	local alive: { DummyState } = {}
	for _, dummyState in pairs(dummyStates) do
		if dummyState.alive then
			table.insert(alive, dummyState)
		end
	end
	return alive
end

-- Dummy equivalent of CombatSystem.lua's own triggerPostureBreak -- a DummyState has no Player to
-- key a target-side feedback send off of and no `blocking` field, so this is simpler: the attacker
-- is the only one who ever receives dummy feedback (dummies have no client of their own).
local function triggerDummyPostureBreak(
	dummyState: DummyState,
	attackerPlayer: Player?,
	sendFeedback: (Player, Types.CombatFeedbackPayload) -> ()
): ()
	if not HitResolution.ApplyPostureBreak(dummyState, dummyState.humanoid) then
		return
	end

	logger:info("Posture break triggered (dummy)", {
		dummy = dummyState.model.Name,
		attacker = if attackerPlayer then attackerPlayer.Name else "none",
	})

	if attackerPlayer then
		local payload =
			FeedbackPayload.Build("PostureBreak", attackerPlayer, nil, nil, nil, nil, dummyState.rootPart.Position)
		sendFeedback(attackerPlayer, payload)
	end
end

-- Dummy equivalent of CombatSystem.lua's resolveHitAgainstTarget -- much simpler since a dummy never
-- blocks or parries (no input of its own), so every hit is a plain, unmitigated "Hit". Still goes
-- through humanoid:TakeDamage (not a direct Health assignment) for the exact same reason the player
-- path does -- so Humanoid.Died and every other engine-level death behavior keep working.
--
-- `attackerState` is the attacker's own live CombatState -- always already resolved and non-nil at
-- the one call site (CombatSystem.lua's onSwingHitCandidate already receives it as its own
-- parameter, itself threaded down from the swing's original throw-time lookup) -- this module never
-- reaches into combatStates itself.
function DummyCombat.ResolveHit(
	attackerPlayer: Player,
	attackerState: CombatState,
	dummyState: DummyState,
	definition: Types.HitboxAttackDefinition,
	isHeavy: boolean,
	finisherVariant: Types.FinisherVariant?
): ()
	assert(hooks, "DummyCombat.Init must run before any hit can resolve against a dummy")
	local targetPosition = dummyState.rootPart.Position
	local wasPostureBroken = os.clock() < dummyState.postureBrokenExpiry

	-- A dummy never blocks/parries (no input of its own), so every hit is a plain, unmitigated
	-- "Hit" -- ComputeOutcome("None") is an identity passthrough of the definition's own numbers.
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

	if damage > 0 then
		dummyState.humanoid:TakeDamage(damage)
	end

	-- attackDebugName (definition.DebugName) is passed through here so PredictionMirror.
	-- OnOwnSwingConnected on the attacker's own client can see it (mirrored combo landing count,
	-- air-combo mirror window) -- see resolveHitAgainstTarget's identical call in CombatSystem.lua.
	-- finisherVariant echo mirrors that same call site's own gate (not blocked -- a dummy hit is
	-- always resolved as "None" defense, dummies have no block/parry concept -- and the dummy's own
	-- post-damage Health already reflects `damage` above, matching ApplyFinisherPhysics's own
	-- "Health <= 0" guard just below).
	local resolvedFinisherVariant: Types.FinisherVariant? = if finisherVariant
			and dummyState.humanoid.Health > 0
		then finisherVariant
		else nil
	local payload = FeedbackPayload.Build(
		"Hit",
		attackerPlayer,
		nil,
		damage,
		postureDamage,
		isHeavy,
		targetPosition,
		definition.DebugName,
		nil,
		resolvedFinisherVariant
	)
	hooks.SendFeedback(attackerPlayer, payload)

	if dummyState.posture <= 0 and not wasPostureBroken then
		triggerDummyPostureBreak(dummyState, attackerPlayer, hooks.SendFeedback)
	end

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
			attackerState.rootPart
		)
		-- Schedule the dummy to reset to spawn once the ragdoll has recovered (+ a buffer so you see
		-- it get up first) -- DummyCombat.Update does the actual reset. A Normal finisher doesn't
		-- ragdoll (ragdollSeconds == 0), so there's nothing to reset from.
		if ragdollSeconds > 0 then
			dummyState.ragdollResetAt = os.clock()
				+ ragdollSeconds
				+ Constants.Debug.TrainingDummy.LaunchResetBufferSeconds
		end
	end

	-- Air combo, solo-testable against a dummy -- see AirComboTarget's own header in CombatTypes.lua
	-- (unified across player/dummy targets). Same Basic-category-only gate the player-target path
	-- uses (never Heavy, never the M1 finisher, which already has its own launch above). startsAirCombo
	-- mirrors resolveHitAgainstTarget's identical computation in CombatSystem.lua -- see AirCombo.
	-- Apply's own header for the DashPunch-or-StartsAirCombo launch condition this feeds.
	if not isHeavy and not finisherVariant then
		local resetBuffer = Constants.Debug.TrainingDummy.LaunchResetBufferSeconds
		local startsAirCombo = definition.Knockback ~= nil and definition.Knockback.StartsAirCombo == true
		-- Dummy-target adapter -- see AirComboTarget's own header for what each closure hides.
		-- clearBlocking is a no-op (DummyState has no `blocking` field -- a dummy never blocks);
		-- setHeldExpiry is a no-op too -- `player = nil` below is what AirCombo.Apply itself branches
		-- on to keep a dummy fully ragdolled the whole sequence, so this closure is never actually
		-- called, it just satisfies the AirComboTarget type; setRagdollExpiry is a flat overwrite (no
		-- math.max) plus the launch-reset buffer, matching this function's own finisher-reset
		-- scheduling just above; applyDamage is a plain TakeDamage (no godmode concept, no vitals
		-- stream to sync for a dummy).
		hooks.ApplyAirCombo(attackerPlayer, attackerState, {
			model = dummyState.model,
			humanoid = dummyState.humanoid,
			rootPart = dummyState.rootPart,
			player = nil,
			clearBlocking = function() end,
			setHeldExpiry = function() end,
			setRagdollExpiry = function(expiry: number)
				dummyState.ragdollResetAt = expiry + resetBuffer
			end,
			isCurrentAirComboTarget = function()
				return attackerState.AirCombo.airComboDummyTarget == dummyState.model
			end,
			setAsAirComboTarget = function()
				attackerState.AirCombo.airComboDummyTarget = dummyState.model
			end,
			clearAirComboTarget = function()
				attackerState.AirCombo.airComboDummyTarget = nil
			end,
			applyDamage = function(amount: number)
				dummyState.humanoid:TakeDamage(amount)
			end,
			-- onGroundSlam intentionally omitted (nil) -- a dummy has no TargetUserId for
			-- SlamImpactVFX.BeginWatch to resolve a live Player character from, so there is no
			-- client-side ground-impact watch to trigger regardless (see that module's own header on
			-- why it's scoped to real players only). AirCombo.lua already guards this field as optional.
		}, definition.DebugName, startsAirCombo, os.clock())
	end
end

-- Per-tick dummy bookkeeping -- posture regen, and returning a finisher-launched dummy to its spawn
-- point once its ragdoll has recovered (+ a buffer so you see it get up first). Driven from
-- CombatSystem.lua's own onHeartbeat, the same "single Heartbeat drives every sibling's Update"
-- pattern HitboxResolver/RagdollController already use -- dummies only need posture regen + the
-- respawn-reset (no vitals remote to throttle, they have no client), which is what makes a dummy
-- repeatedly useful for testing posture break rather than staying broken forever after the first one.
function DummyCombat.Update(now: number, deltaTime: number): ()
	for _, dummyState in pairs(dummyStates) do
		if not dummyState.alive then
			continue
		end

		if now >= dummyState.postureBrokenExpiry and dummyState.posture < dummyState.maxPosture then
			dummyState.posture =
				math.min(dummyState.maxPosture, dummyState.posture + Constants.Combat.PostureRegenPerSecond * deltaTime)
		end

		-- Recover() is idempotent, so calling it here guarantees the ragdoll is cleared before the
		-- PivotTo even if the launch left it settling, and zeroing velocity stops residual launch
		-- momentum from carrying it off again after the teleport.
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
end

return DummyCombat
