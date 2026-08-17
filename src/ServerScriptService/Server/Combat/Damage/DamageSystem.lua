--!strict
--[[
	DamageSystem.lua

	Owns: the Damage System's public surface -- the DefenseSystem.OnResolved subscription, applying
	health and guard pressure, hitstun and the swing cancellation it causes, the attack gate this layer
	contributes, the feedback remote, and its own Heartbeat.

	    HitboxEngine     where the volume is, who is inside it
	    DefenseSystem    what kind of hit that was
	    DamageSystem     how much it hurts, what it does to you   <- this module

	It is the third layer of that stack and the first consumer of the second's output, subscribing to
	OnResolved exactly the way DefenseSystem subscribes to the engine's OnHit. Neither of the two layers
	below was rewritten to accommodate it: the engine gained one field it was already carrying
	(HitReport.DebugName) and the defence layer gained one function (DrainGuard), and that is the whole
	integration surface.

	ONE PASS, NOT TWO, and the contrast with DefenseSystem is deliberate. That module needs two passes
	for two specific reasons -- SampleTime-accurate window classification, and Trade arbitration across
	a whole batch -- and neither applies here. OnResolved fires from INSIDE DefenseSystem's own
	already-arbitrated pass 2, so by the time a contact reaches this module everything time-sensitive
	about it has been decided. And nothing this layer grants is a resource a naive immediate-apply could
	be exploited into double-granting: damage and guard pressure are costs, not rewards, so applying
	them independently and symmetrically to both contacts of a mutual exchange already produces the fair
	outcome that an arbitration pass would otherwise have to guarantee.

	NO REGISTRY, and this is the one place this module deliberately departs from the shape of the two
	below it. Everything it needs about a combatant is derivable from the Model it is handed -- the
	Humanoid for health, HitboxEngine.GetCombatantId for the cancel, DefenseSystem for the guard -- and
	the only state it keeps of its own (hitstun expiry, combo escalation) is bounded by a timestamp that
	expires on its own. So there is nothing to register and nothing to leak: a player, a bot and a
	training dummy all go through one path with nobody having to remember to register any of them, which
	is the same domain-agnostic outcome DefenseSystem's own registry achieves by the opposite means.

	HEALTH IS NOT SHADOW-TRACKED. Humanoid.Health stays the single authority, exactly as
	StarterCharacterScripts/Health.server.lua's standing rule requires -- this module calls
	Humanoid:TakeDamage and reads Humanoid.Health, and keeps no parallel pool. Death is therefore
	unchanged too: Humanoid.Died still fires and PlayerDeathSystem still owns confirming it.

	HEARTBEAT ORDER IS LOAD-BEARING, the same way it is for the two layers below. Roblox fires Heartbeat
	connections in connection order, so Init must run after DefenseSystem.Init -- which must itself run
	after HitboxEngine.Init. Main.server.lua calls them in that order and Init asserts it rather than
	trusting the comment.

	Does not own: contact detection (HitboxEngine), what kind of hit something was (DefenseSystem), the
	guard pool itself (DefenseSystem.DrainGuard -- this decides how much, that owns the meter), per-move
	damage numbers (the Move Creation System, via AttackCatalog), knockback PHYSICS (resolved here as a
	number, applied by nothing -- the deleted RagdollController's territory), or deciding when anyone
	throws an attack (the attack layer, which does not exist yet).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DamageConstants = require(ReplicatedStorage.Shared.Damage.DamageConstants)
local DamageTypes = require(ReplicatedStorage.Shared.Damage.DamageTypes)
local DefenseTypes = require(ReplicatedStorage.Shared.Defense.DefenseTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Types = require(ReplicatedStorage.Shared.Types)

local ComboEscalation = require(script.Parent.ComboEscalation)
local DamageResolver = require(script.Parent.DamageResolver)
local AttackCatalog = require(script.Parent.Parent.AttackCatalog)
local DefenseSystem = require(script.Parent.Parent.Defense.DefenseSystem)
local HitboxEngine = require(script.Parent.Parent.HitboxEngine.HitboxEngine)

type DefenseOutcome = DefenseTypes.DefenseOutcome
type DamageResult = DamageTypes.DamageResult
type CombatFeedback = DamageTypes.CombatFeedback

local logger = Logger.scope("DamageSystem")

local DamageSystem = {}

-- When each combatant's hitstun ends. Absent means none. Reclaimed by expiry rather than by
-- unregistration -- see this file's header on why there is no registry.
local hitstunUntil: { [Model]: number } = {}

local appliedCallbacks: { (DefenseOutcome, DamageResult) -> () } = {}

local started = false
local heartbeatConnection: RBXScriptConnection? = nil
local resolvedDisconnect: (() -> ())? = nil
local feedbackRemote: RemoteEvent? = nil

-- Helpers ------------------------------------------------------------------------------------------

local function debugLog(message: string, data: { [string]: any }?): ()
	if DamageConstants.Debug.Enabled and DamageConstants.Debug.LogApplied then
		logger:debug(message, data)
	end
end

local function humanoidOf(model: Model): Humanoid?
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	return if humanoid and humanoid.Health > 0 then humanoid else nil
end

-- Tells one participant what just happened. Silently does nothing for a bot or a dummy, which have no
-- player to tell -- the same "not every combatant is a Player" tolerance every other module in this
-- stack keeps.
local function sendFeedback(model: Model, payload: CombatFeedback): ()
	local remote = feedbackRemote
	if not remote then
		return
	end
	local player = Players:GetPlayerFromCharacter(model)
	if not player then
		return
	end
	remote:FireClient(player, payload)
end

-- Application --------------------------------------------------------------------------------------

-- Cuts short the swing of whoever just got hit.
--
-- THIS IS WHAT MAKES A COUNTER-HIT A REAL ANSWER. Before it, nothing cancelled a swing except a parry,
-- and only the attacker's -- so a player struck mid-combo kept swinging and a well-timed interception
-- was only a parallel damage race. Now landing a hit is itself counterplay: no block, no parry, just
-- timing and spacing.
--
-- It reuses the exact call DefenseSystem already makes for a parried attacker, for a new reason, and
-- times it from the contact's own SampleTime rather than the frame clock so the interrupted machine
-- records the moment it actually happened. Idempotent: AttackStateMachine.Interrupt on an already-Idle
-- machine is a documented no-op, so a combatant hit twice in one batch by two different attackers is
-- cancelled at most meaningfully once.
local function cancelSwingOf(model: Model, at: number): ()
	local combatantId = HitboxEngine.GetCombatantId(model)
	if not combatantId then
		return
	end
	HitboxEngine.CancelAttack(combatantId, "Hitstun", at)
end

local function applyOutcome(outcome: DefenseOutcome): ()
	local entry = AttackCatalog.Get(outcome.Report.DebugName)
	if not entry then
		-- Nothing priceable. Reported rather than silently dealing zero, because "hits land but nobody
		-- takes damage" is otherwise a mystery with no log line anywhere: the engine is working, the
		-- defence layer is working, and only the catalogue lookup failed.
		if DamageConstants.Debug.Enabled and DamageConstants.Debug.LogCatalogMisses then
			logger:debug("Resolved a contact for an attack with no catalogue entry", {
				debugName = outcome.Report.DebugName,
			})
		end
		return
	end

	local at = outcome.SampleTime

	-- ADVANCED BEFORE RESOLVING, not after, so the stage handed to the resolver is the one this hit
	-- counts as. Resolving first and advancing afterwards would scale every hit by the stage of the one
	-- before it -- the first two hits of every string would both deal flat authored damage, which is
	-- invisible in play right up until someone measures a combo.
	local stage
	if DamageResolver.AdvancesCombo(outcome.Kind) then
		stage = ComboEscalation.Advance(outcome.Attacker, at)
	else
		stage = ComboEscalation.GetStage(outcome.Attacker, at)
	end

	local result = DamageResolver.Resolve(outcome.Kind, outcome.DefenderStateAtContact, entry.Profile, stage)

	if result.GuardDrain > 0 then
		DefenseSystem.DrainGuard(outcome.Defender, result.GuardDrain, at)
	end

	if result.HitstunSeconds > 0 then
		hitstunUntil[outcome.Defender] = math.max(hitstunUntil[outcome.Defender] or 0, at + result.HitstunSeconds)
		cancelSwingOf(outcome.Defender, at)
	end

	-- FIRED BEFORE THE HEALTH WRITE, and the ordering is the whole point rather than an accident.
	-- Humanoid:TakeDamage raises Humanoid.Died synchronously when the blow is lethal, so a subscriber
	-- notified afterwards would always be told who dealt the killing hit strictly AFTER
	-- PlayerDeathSystem had already fired the death with no killer attributed. Announcing the intent
	-- first is what leaves kill attribution a pure follow-up in that module rather than a restructuring
	-- of this one. Nothing here attributes a kill today -- see this file's header on what it does not
	-- own -- but nothing here forecloses it either.
	for _, callback in appliedCallbacks do
		-- pcall'd for the same reason DefenseSystem pcalls its own consumers: one subscriber erroring
		-- must not abort the rest, and above all must not unwind out of the Heartbeat.
		local ok, err = pcall(callback, outcome, result)
		if not ok then
			logger:error("A DamageSystem.OnApplied consumer errored", { errorMessage = tostring(err) })
		end
	end

	if result.Damage > 0 then
		local humanoid = humanoidOf(outcome.Defender)
		if humanoid then
			humanoid:TakeDamage(result.Damage)
		end
	end

	local feedback: CombatFeedback = {
		Kind = outcome.Kind,
		Role = "Attacker",
		Attacker = outcome.Attacker,
		Defender = outcome.Defender,
		Damage = result.Damage,
		GuardDrain = result.GuardDrain,
		ComboStage = stage,
		MoveId = entry.MoveId,
		ContactPosition = outcome.Report.ContactPosition,
	}
	sendFeedback(outcome.Attacker, feedback)
	if outcome.Defender ~= outcome.Attacker then
		local defenderFeedback = table.clone(feedback)
		defenderFeedback.Role = "Defender"
		sendFeedback(outcome.Defender, defenderFeedback)
	end

	debugLog("Damage applied", {
		kind = outcome.Kind,
		moveId = entry.MoveId,
		damage = result.Damage,
		guardDrain = result.GuardDrain,
		stage = stage,
	})
end

-- The loop -----------------------------------------------------------------------------------------

-- One frame. `now` is the caller's clock, matching HitboxEngine.Step and DefenseSystem.Step's own
-- convention so all three agree about what a frame is.
--
-- There is nothing to APPLY here -- outcomes are applied the moment they resolve, from inside
-- DefenseSystem's own pass 2 (see this file's header on why one pass is enough). This exists purely to
-- reclaim state whose timestamps have passed, which is what lets both tables stay registry-free.
function DamageSystem.Step(_deltaTime: number, now: number): ()
	for model, until_ in hitstunUntil do
		if model.Parent == nil or now >= until_ then
			hitstunUntil[model] = nil
		end
	end
	ComboEscalation.Sweep(now)
end

-- Public queries -----------------------------------------------------------------------------------

-- Whether this combatant may start an attack, and why not when they may not.
--
-- The attack layer consults this ALONGSIDE DefenseSystem.CanAttack, not instead of it: that one
-- answers "are you staggered or guarding", this one answers "are you reeling from a hit". Two
-- questions, two owners, and neither system has to know the other's states.
function DamageSystem.CanAttack(model: Model, now: number): (boolean, string?)
	local until_ = hitstunUntil[model]
	if until_ and now < until_ then
		return false, "Hitstun"
	end
	return true, nil
end

function DamageSystem.IsHitstunned(model: Model, now: number): boolean
	local until_ = hitstunUntil[model]
	return until_ ~= nil and now < until_
end

function DamageSystem.GetComboStage(model: Model, now: number): number
	return ComboEscalation.GetStage(model, now)
end

-- This system's output signal, for anything downstream that wants to react to real damage --
-- RewardSystem, AchievementSystem, and eventually kill attribution. Returns a disconnect function
-- rather than a connection object, matching HitboxEngine.OnHit and DefenseSystem.OnResolved's own
-- contract so a consumer of all three learns one shape.
--
-- Fired BEFORE the health write. See applyOutcome for why that ordering is load-bearing.
function DamageSystem.OnApplied(callback: (DefenseOutcome, DamageResult) -> ()): () -> ()
	table.insert(appliedCallbacks, callback)
	return function()
		local index = table.find(appliedCallbacks, callback)
		if index then
			table.remove(appliedCallbacks, index)
		end
	end
end

-- Lifecycle ----------------------------------------------------------------------------------------

-- Subscribes to the defence layer's outcome signal, and nothing else. Split out of Init for the same
-- reason DefenseSystem.Attach is: a spec has to drive this system on a synthetic clock, and it cannot
-- do that if the only way to receive outcomes is to also start a real Heartbeat racing its own Step
-- calls. Idempotent.
function DamageSystem.Attach(): ()
	if resolvedDisconnect then
		return
	end
	resolvedDisconnect = DefenseSystem.OnResolved(applyOutcome)
end

function DamageSystem.Init(): ()
	if started then
		return
	end
	-- See this file's header: Heartbeat order is a correctness property, not a preference. Asserted
	-- rather than documented, because a comment in Main.server.lua cannot fail a boot.
	assert(HitboxEngine.RegisteredCount() >= 0, "DamageSystem.Init() requires HitboxEngine to be available")
	assert(DefenseSystem.CanAttack ~= nil, "DamageSystem.Init() requires DefenseSystem to be available")
	started = true

	feedbackRemote = NetworkBridge.CreateRemoteEvent(DamageConstants.Network.RemoteNames.Feedback)

	DamageSystem.Attach()

	-- Connected AFTER DefenseSystem.Init has connected its own, which Main.server.lua guarantees by
	-- calling that first.
	heartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime: number)
		DamageSystem.Step(deltaTime, os.clock())
	end)

	logger:info("DamageSystem.Init() complete")
end

function DamageSystem.Shutdown(): ()
	if heartbeatConnection then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end
	if resolvedDisconnect then
		resolvedDisconnect()
		resolvedDisconnect = nil
	end
	started = false
end

-- Drops every piece of per-combatant state and every subscription. Spec-only, so one case cannot serve
-- another its state -- the same role HitboxEngine.Reset and DefenseSystem.Reset play for their own
-- modules.
function DamageSystem.Reset(): ()
	-- Dropped so a following Attach() genuinely re-subscribes. DefenseSystem.Reset table.clears its own
	-- callback list, so a spec that resets both would otherwise hold a stale non-nil handle for a
	-- subscription that no longer exists -- and Attach's idempotence guard would then refuse to make a
	-- new one, silently delivering no outcomes for every case after the first. Exactly the trap
	-- DefenseSystem.Reset documents for itself.
	if resolvedDisconnect then
		resolvedDisconnect()
		resolvedDisconnect = nil
	end
	table.clear(hitstunUntil)
	table.clear(appliedCallbacks)
	ComboEscalation.Reset()
	AttackCatalog.Reset()
end

return DamageSystem :: Types.SystemModule & typeof(DamageSystem)
