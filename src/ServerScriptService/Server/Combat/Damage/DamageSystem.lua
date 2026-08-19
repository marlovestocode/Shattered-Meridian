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
	the only state it keeps of its own (hitstun expiry, combo escalation, the attacker-lunge window
	below) is bounded by a timestamp that expires on its own. So there is nothing to register and
	nothing to leak: a player, a bot and a training dummy all go through one path with nobody having
	to remember to register any of them, which is the same domain-agnostic outcome DefenseSystem's own
	registry achieves by the opposite means.

	ALSO OWNS (DamageConstants.AttackerLunge): a brief forced-forward Humanoid:Move() for the ATTACKER
	on a landed Basic-string (M1) hit -- a felt "the punch connected" cue, distinct from the knockback
	PHYSICS mentioned below (that is the DEFENDER's reaction to a hit; this is the attacker's own body
	on a hit they landed). Never writes WalkSpeed -- see RunSystem.lua's sole-owner rule -- it only
	forces MoveDirection for a few frames at whatever speed is already in effect, the same
	Humanoid:Move() surface touch controls/gamepads/AI already drive a character through.

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

local AmortizedReclaim = require(ReplicatedStorage.Shared.AmortizedReclaim)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local DamageConstants = require(ReplicatedStorage.Shared.Damage.DamageConstants)
local DamageTypes = require(ReplicatedStorage.Shared.Damage.DamageTypes)
local DefenseTypes = require(ReplicatedStorage.Shared.Defense.DefenseTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Trove = require(ReplicatedStorage.Shared.Trove)
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

-- Round-robin reclaim cursor for hitstunUntil -- see Step below, and Shared/AmortizedReclaim.lua for
-- why lungeUntil directly beneath it deliberately does NOT get one.
local hitstunReclaim = AmortizedReclaim.New()

-- When each attacker's post-M1-hit forced-forward window ends. Same "reclaimed by expiry, no
-- registry" shape as hitstunUntil above -- see this file's header's AttackerLunge paragraph.
local lungeUntil: { [Model]: number } = {}

local appliedCallbacks: { (DefenseOutcome, DamageResult) -> () } = {}

local started = false
local heartbeatTrove = Trove.New()
local resolvedDisconnect: (() -> ())? = nil
local feedbackRemote: RemoteEvent? = nil

-- Helpers ------------------------------------------------------------------------------------------

local function debugLog(message: string, data: { [string]: any }?): ()
	if DamageConstants.Debug.Enabled and DamageConstants.Debug.LogApplied then
		logger:debug(message, data)
	end
end

-- Whether `moveId` is a weapon's Basic (M1) string hit -- gates DamageConstants.AttackerLunge.
-- LIVE MoveIds never match the hand-authored DebugName fields on Constants.Combat.Weapons[...].
-- Stages.Basic ("Basic1", "Dagger1", ...); every attack actually thrown resolves through
-- DefaultMoveRegistry's synthetic scheme instead. Restated here rather than shared, the same
-- "coupling is to the naming convention, not to a shared function" reasoning Shared/Attack/
-- AttackWindows.lua's MarkerNameFor documents for its own identical pattern. A custom Move-Editor
-- move can never match this shape (its MoveId is an author-assigned slug), so this correctly
-- excludes those too -- Heavy and Finisher get no forward nudge, same as before this existed.
local function isBasicMoveId(moveId: string): boolean
	return string.match(moveId, "^default:%a+:Basic:%d+$") ~= nil
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

	-- M1 (Basic weapon-string) hits are priced at flat authored damage every time, never scaled by the
	-- string's own escalation -- see DamageConstants.Combo.DamageMultiplierPerStage's own header for why
	-- that multiplier exists for everything else. `stage` above still tracks the real combo depth (feedback/
	-- Finisher-eligibility/UI all need the true number), so only the value fed into the resolver is pinned;
	-- pin to 1 rather than skip Resolve entirely so Basic keeps the exact same Clean/Blocked/Backstab/
	-- GuardBroken pricing rules as everything else, just at ComboMultiplier(1) == 1.
	local pricingStage = if isBasicMoveId(entry.MoveId) then 1 else stage
	local result = DamageResolver.Resolve(outcome.Kind, outcome.DefenderStateAtContact, entry.Profile, pricingStage)

	if result.GuardDrain > 0 then
		DefenseSystem.DrainGuard(outcome.Defender, result.GuardDrain, at)
	end

	if result.HitstunSeconds > 0 then
		hitstunUntil[outcome.Defender] = math.max(hitstunUntil[outcome.Defender] or 0, at + result.HitstunSeconds)
		cancelSwingOf(outcome.Defender, at)
	end

	-- A landed M1 (Basic weapon-string) hit gives the ATTACKER a brief forced-forward nudge, driven
	-- from Step below -- see DamageConstants.AttackerLunge's own comment. Parried is excluded because
	-- nothing of the attacker's own swing actually connected; every other resolved kind (Clean,
	-- Blocked, Backstab, GuardBroken, Trade) still counts as the swing having landed on something.
	if DamageConstants.AttackerLunge.Enabled and outcome.Kind ~= "Parried" and isBasicMoveId(entry.MoveId) then
		lungeUntil[outcome.Attacker] = at + DamageConstants.AttackerLunge.DurationSeconds
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
		local humanoid = CharacterUtil.LiveHumanoidOf(outcome.Defender)
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
-- Outcomes themselves are applied the moment they resolve, from inside DefenseSystem's own pass 2
-- (see this file's header on why one pass is enough) -- most of what happens here is reclaiming
-- state whose timestamps have passed, which is what lets hitstunUntil/ComboEscalation stay
-- registry-free. The one exception is the attacker-lunge loop below: DamageConstants.AttackerLunge
-- needs a few consecutive FRAMES of Humanoid:Move(), not a single instantaneous write, so it rides
-- this System's already-connected Heartbeat rather than opening a second one.
function DamageSystem.Step(_deltaTime: number, now: number): ()
	-- AMORTISED, and no longer an expiry sweep. Every reader of hitstunUntil (CanAttack,
	-- IsHitstunned) already compares the stored timestamp against its own `now`, so an entry that has
	-- passed its expiry but has not yet been dropped is invisible from outside -- which means the
	-- eviction was never doing anything a reader could observe, and a full walk of the table every
	-- frame was paying for it. What the sweep IS still for is stopping the outer table from holding a
	-- reference to a destroyed character forever, and that is what the cursor does, a fixed handful of
	-- keys per frame regardless of how many combatants exist. The table's size is unchanged by the
	-- switch: it was already bounded by live-combatant count, since a fresh hit overwrites the
	-- existing entry rather than adding one.
	hitstunReclaim:Step(hitstunUntil)
	-- Left as a full walk deliberately: unlike hitstunUntil, this one's `now` is part of its own
	-- public contract (Sweep(now)), and its table is bounded by live-combatant count either way.
	ComboEscalation.Sweep(now)

	-- DELIBERATELY A FULL WALK, unlike hitstunUntil above. This loop does per-entry WORK -- it calls
	-- Humanoid:Move() on every live entry, every frame -- so an amortised cursor here would not be a
	-- delayed cleanup, it would be a dropped frame of the lunge. It is also naturally tiny: only
	-- combatants inside their post-hit forward window are ever in it. See
	-- Shared/AmortizedReclaim.lua's header on that distinction.
	for model, until_ in lungeUntil do
		if model.Parent == nil or now >= until_ then
			lungeUntil[model] = nil
			continue
		end
		local humanoid = CharacterUtil.LiveHumanoidOf(model)
		-- PrimaryPart, not Humanoid.RootPart -- every registration path into this combat stack
		-- (HitboxEngine.RegisterCombatant, DefenseSystem.RegisterCombatant) already requires and is
		-- handed a root explicitly rather than trusting Roblox's own rig-joint auto-detection, and a
		-- real player character's PrimaryPart is always its HumanoidRootPart. Same guarantee, no new
		-- dependency on rig internals this module has never needed before.
		local rootPart = model.PrimaryPart
		if humanoid and rootPart then
			-- The same Humanoid:Move() surface touch controls/gamepads/AI already drive a character
			-- through -- forces MoveDirection for this one frame regardless of what the player is
			-- actually holding, at whatever WalkSpeed RunSystem currently has in effect. relativeToCamera
			-- = false: the world-space LookVector is the swing's own facing, not the player's camera.
			humanoid:Move(rootPart.CFrame.LookVector, false)
		end
	end
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

-- Whether Step is currently forcing this attacker forward via DamageConstants.AttackerLunge. Same
-- read-only, timestamp-bounded query shape as IsHitstunned above -- exists so a spec can assert on
-- the gating decision directly rather than on a real Humanoid's physics response, which a synthetic
-- Step has no way to guarantee the timing of.
function DamageSystem.IsLunging(model: Model, now: number): boolean
	local until_ = lungeUntil[model]
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
	heartbeatTrove:Connect(RunService.Heartbeat, function(deltaTime: number)
		DamageSystem.Step(deltaTime, os.clock())
	end)

	logger:info("DamageSystem.Init() complete")
end

function DamageSystem.Shutdown(): ()
	heartbeatTrove:Clean()
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
	table.clear(lungeUntil)
	hitstunReclaim:Reset()
	table.clear(appliedCallbacks)
	ComboEscalation.Reset()
	AttackCatalog.Reset()
end

return DamageSystem :: Types.SystemModule & typeof(DamageSystem)
