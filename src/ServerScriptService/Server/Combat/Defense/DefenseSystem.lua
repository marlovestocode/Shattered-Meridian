--!strict
--[[
	DefenseSystem.lua

	Owns: the Defense System's public surface -- the HitboxEngine.OnHit subscription, the per-combatant
	registry, the block/parry remotes, the DefenseState Attribute, and the two-pass resolution that
	turns contacts into outcomes.

	WHAT THIS LAYER IS FOR. The hitbox engine reports contacts and deliberately refuses to say what a
	contact MEANS. This system is the first consumer of that signal: it decides what KIND of hit it
	was -- clean, blocked, parried, traded, guard-broken, backstab -- and then stops. It emits a
	DefenseOutcome and applies no damage, no health, no knockback. The damage layer subscribes to
	OnResolved exactly the way this subscribes to OnHit, and neither had to be rewritten to
	accommodate the other.

	    HitboxEngine     where the volume is, who is inside it
	    DefenseSystem    what kind of hit that was              <- this module
	    DamageSystem     how much it hurts, what it does to you

	THE ONE THING THE LAYER ABOVE REACHES BACK FOR is the guard meter, because guard doubles as the
	posture pool -- see DefenseSystem.DrainGuard's own header. That is a narrow, one-function seam and
	it keeps the pool's ownership here rather than splitting it across two systems.

	TWO PASSES, AND WHY ONE IS NOT ENOUGH. The engine subdivides a Heartbeat into up to eight substeps
	and fires OnHit from inside that loop, so one frame can deliver contacts tens of milliseconds
	apart -- comfortably wider than a parry window.
	  * PASS 1 runs eagerly inside OnHit and CLASSIFIES each contact against the defender's posture at
	    that contact's own SampleTime (DefenseStateMachine.StateAt/BlockHeldAt/IsParryLiveAt). Nothing
	    is applied. Classifying the whole frame against the posture at frame END would let a hit that
	    landed before ParryStart be parried, and one that landed after it closed be parried too,
	    both silently. Running here also means the bearing is measured against poses from the substep
	    the contact was found in rather than from the end of the frame.
	  * PASS 2 runs at the end of the frame, ARBITRATES trades across the batch, then applies and
	    emits. Trades need the whole batch by definition, and applying eagerly would mean whichever
	    report arrived first cancelled the other before the trade could be seen.

	THE ONE-FRAME RESIDUAL, stated rather than hidden. Because cancels apply in pass 2, a parried
	attacker's swing keeps sampling for the remainder of the frame it was parried in and can land a
	contact after the parry that killed it. It is bounded at one frame, and it is the same bound the
	engine already accepts elsewhere -- its substep loop deliberately defers a callback-started
	follow-up swing to the next frame for the same reason. DefenseSystem.spec asserts the bound rather
	than the absence.

	HEARTBEAT ORDER IS LOAD-BEARING. Roblox fires Heartbeat connections in connection order, so this
	module's Step must run after HitboxEngine's or pass 2 executes before the substeps that fill its
	buffer and every batch resolves a frame late -- invisibly, and only on some boot orders. Init
	asserts the engine is already started rather than trusting a comment in Main.server.lua.

	Does not own: contact detection (HitboxEngine), window timing (Shared/Defense/ParryWindows.lua),
	damage of any kind, or the attack move set. Attack GATING is here rather than in the engine
	(CanAttack) precisely so the engine stays ignorant of stagger and remains standalone.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local DefenseTypes = require(ReplicatedStorage.Shared.Defense.DefenseTypes)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local ParkourOwnership = require(ReplicatedStorage.Shared.Parkour.ParkourOwnership)
local HitboxEngineConstants = require(ReplicatedStorage.Shared.HitboxEngine.HitboxEngineConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local ParryWindows = require(ReplicatedStorage.Shared.Defense.ParryWindows)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local Trove = require(ReplicatedStorage.Shared.Trove)
local Types = require(ReplicatedStorage.Shared.Types)
local WeaponDefenseAnimations = require(ReplicatedStorage.Shared.Defense.WeaponDefenseAnimations)

local DefenseStateMachine = require(script.Parent.DefenseStateMachine)
local GuardMeter = require(script.Parent.GuardMeter)
local OutcomeResolver = require(script.Parent.OutcomeResolver)
local HitboxEngine = require(script.Parent.Parent.HitboxEngine.HitboxEngine)

type DefenseState = DefenseTypes.DefenseState
type DefenseOutcome = DefenseTypes.DefenseOutcome
type PendingContact = DefenseTypes.PendingContact
type HitReport = HitboxTypes.HitReport

local logger = Logger.scope("DefenseSystem")

local DefenseSystem = {}

type Registration = {
	Model: Model,
	RootPart: BasePart,
	Humanoid: Humanoid,
	Machine: DefenseStateMachine.Machine,
	Guard: GuardMeter.Meter,
	-- The clip whose markers define this combatant's parry window. Empty when they have none, which
	-- is the fail-closed case: their block still works, it just never opens a window.
	ParryAnimationId: string,
	-- Whether THIS system currently holds RootControlLocked for this body. Mirrors the engine's own
	-- HoldsMovementLock flag, and for the same reason -- two writers to one Attribute need each to
	-- know whether it is the one holding it.
	HoldsMovementLock: boolean,
	-- The DefenseState last actually written to the Humanoid Attribute, so publishState can skip the
	-- write when Step re-asserts the same state it already published. See publishState's own header.
	PublishedState: DefenseState?,
}

local registrations: { [Model]: Registration } = {}
-- This frame's classified-but-unapplied contacts. Cleared at the end of every Step.
local pending: { PendingContact } = {}
-- Defenders whose parry has already been spent by an earlier contact in THIS batch. Being surrounded
-- is supposed to be dangerous: one window stops one attack. Kept here rather than by consuming the
-- machine's own flag in pass 1, so pass 1 genuinely applies nothing.
local parryConsumedThisBatch: { [Model]: boolean } = {}

local outcomeCallbacks: { (DefenseOutcome) -> () } = {}

local started = false
local heartbeatTrove = Trove.New()
local hitDisconnect: (() -> ())? = nil
local stateChangedRemote: RemoteEvent? = nil
local rateLimiter = RateLimiter.New(DefenseConstants.Network.MaxCallsPerSecondPerPlayer)

-- The clip used by any combatant registered without one of their own.
local defaultParryAnimationId = ""

-- Helpers ------------------------------------------------------------------------------------------

local function debugLog(message: string, data: { [string]: any }?): ()
	if DefenseConstants.Debug.Enabled and DefenseConstants.Debug.LogOutcomes then
		logger:debug(message, data)
	end
end

-- One-way latency for a player-backed combatant, in seconds. Zero for anything else -- a bot or a
-- training dummy has no connection to refund.
local function pingSecondsFor(model: Model): number
	local player = Players:GetPlayerFromCharacter(model)
	if not player then
		return 0
	end
	local ok, ping = pcall(function()
		return player:GetNetworkPing()
	end)
	if not ok or typeof(ping) ~= "number" or ping ~= ping or ping < 0 then
		return 0
	end
	return ping
end

-- Publishes the live state so the HUD and any future spectator tooling can read it off the Humanoid
-- for free, and takes or releases the movement lock for the two states that genuinely remove control.
--
-- THE STATE ATTRIBUTE ITSELF IS DEDUPED, THE MOVEMENT LOCK IS NOT (see below for why the lock already
-- was). Step calls this every frame for every registration regardless of whether the state actually
-- changed -- RunSystem.lua's own header names writing an unchanged replicated Attribute sixty times a
-- second as "the single most expensive thing a System with a Heartbeat can do for no effect", and this
-- system used to do exactly that on every Humanoid it manages. PublishedState is what makes a re-
-- assertion of the same state a no-op instead of a property write.
--
-- ROOTCONTROLLOCKED HAS TWO WRITERS -- this system and HitboxEngine, which holds it for the duration
-- of a locking swing's Active window. They are kept from fighting by ordering rather than by locking:
-- in pass 2 an attacker's swing is CANCELLED before they are staggered, so the engine has already
-- released before this takes it. Step re-asserts every frame while the condition lasts, so even if
-- the engine clears it out from under us the gap is one frame, and this only ever CLEARS the
-- Attribute when it is the holder.
local function publishState(registration: Registration, state: DefenseState): ()
	local humanoid = registration.Humanoid
	if humanoid.Parent == nil then
		return
	end
	if registration.PublishedState ~= state then
		registration.PublishedState = state
		humanoid:SetAttribute(DefenseConstants.DefenseStateAttribute, state)
	end

	local wantsLock = state == "Staggered" or state == "GuardBroken"
	if wantsLock == registration.HoldsMovementLock then
		return
	end
	registration.HoldsMovementLock = wantsLock
	if wantsLock then
		humanoid:SetAttribute(HitboxEngineConstants.RootControlLockedAttribute, true)
	else
		-- Only cleared because this system is the holder. If the engine is mid-swing on this body it
		-- will have set the Attribute itself and will clear it through its own exit path.
		humanoid:SetAttribute(HitboxEngineConstants.RootControlLockedAttribute, nil)
	end
end

local function notifyClient(registration: Registration, state: DefenseState, attackerPosition: Vector3?): ()
	local remote = stateChangedRemote
	if not remote then
		return
	end
	local player = Players:GetPlayerFromCharacter(registration.Model)
	if not player then
		return
	end
	remote:FireClient(player, {
		State = state,
		Guard = registration.Guard:Get(),
		GuardMax = registration.Guard:GetMax(),
		-- Sent only on a parry, so the client can snap the defender to face their attacker. The snap
		-- is done client-side rather than by writing CFrame from here: the client owns its own
		-- character's physics, so a server rotation write would be fought and then overwritten. Feel
		-- belongs on the client; the decision that a parry happened stays here.
		FaceTowards = attackerPosition,
	})
end

-- Registry -----------------------------------------------------------------------------------------

-- Registers a combatant. Mirrors HitboxEngine.RegisterCombatant's shape (model, root, humanoid) on
-- purpose -- anything the engine accepts as a fighter, this accepts as a defender, so a bot and a
-- dummy get the same defensive rules a player does with no branching anywhere.
function DefenseSystem.RegisterCombatant(
	model: Model,
	rootPart: BasePart,
	humanoid: Humanoid,
	parryAnimationId: string?
): ()
	if registrations[model] then
		DefenseSystem.UnregisterCombatant(model)
	end

	local registration: Registration = {
		Model = model,
		RootPart = rootPart,
		Humanoid = humanoid,
		Machine = nil :: any,
		Guard = GuardMeter.New(),
		ParryAnimationId = parryAnimationId or defaultParryAnimationId,
		HoldsMovementLock = false,
		PublishedState = nil,
	}
	registration.Machine = DefenseStateMachine.New({
		OnTransition = function(_from: DefenseState, to: DefenseState, _at: number)
			publishState(registration, to)
			notifyClient(registration, to, nil)
			if DefenseConstants.Debug.Enabled and DefenseConstants.Debug.LogTransitions then
				logger:debug("Defense state changed", { model = model.Name, to = to })
			end
		end,
	})

	registrations[model] = registration
	publishState(registration, "Neutral")
end

function DefenseSystem.UnregisterCombatant(model: Model): ()
	local registration = registrations[model]
	if not registration then
		return
	end
	-- Released explicitly rather than left to the Humanoid being destroyed: a character that is
	-- unregistered but not destroyed (a spectator handoff, a spec reset) must not be left with this
	-- system's movement lock set on it forever.
	if registration.HoldsMovementLock and registration.Humanoid.Parent ~= nil then
		registration.Humanoid:SetAttribute(HitboxEngineConstants.RootControlLockedAttribute, nil)
	end
	if registration.Humanoid.Parent ~= nil then
		registration.Humanoid:SetAttribute(DefenseConstants.DefenseStateAttribute, nil)
	end
	registrations[model] = nil
	parryConsumedThisBatch[model] = nil
end

function DefenseSystem.IsRegistered(model: Model): boolean
	return registrations[model] ~= nil
end

-- The clip every combatant registered without one of their own uses. Nothing arms a parry until this
-- (or a per-combatant id) resolves to a window -- see ParryWindows' fail-closed rule.
function DefenseSystem.SetDefaultParryAnimation(animationId: string): ()
	defaultParryAnimationId = animationId
end

-- Re-points ONE combatant's parry clip, which re-points that combatant's parry WINDOW -- the markers
-- on this id are the window (see Shared/Defense/ParryWindows.lua), so this is a timing change, not a
-- cosmetic one.
--
-- EXISTS FOR THE WEAPON SWAP, and the layering is the reason it is a setter here rather than this
-- System reaching for the answer itself. Which weapon a combatant holds is the ATTACK layer's fact
-- (SwingSequencer's record, published through AttackRequestSystem.OnWeaponChanged), and Defense sits
-- two layers BELOW Attack -- a require in that direction would invert the stack. So the composition
-- root wires the two together: Server/Main.server.lua subscribes to that signal and calls this with
-- WeaponDefenseAnimations.GetParry(weaponId). Same shape as SetDefaultParryAnimation directly above,
-- which Main.server.lua already calls for the same "the boot script knows both, the layer knows one"
-- reason.
--
-- A blank id is a legitimate argument, not an error: it is what a combatant with no parry clip at all
-- resolves to, and it fail-closes exactly as an unregistered combatant does -- the block still works,
-- no window ever opens. Silently ignores a model that is not registered (an unbound character mid-
-- respawn), since RegisterCombatant re-reads the default for the new life anyway.
function DefenseSystem.SetParryAnimation(model: Model, animationId: string): ()
	local registration = registrations[model]
	if not registration then
		return
	end
	registration.ParryAnimationId = animationId
end

-- Input --------------------------------------------------------------------------------------------

-- The block/parry input edge. Exposed as a function as well as being wired to the remote, so a bot
-- can defend through exactly the same path a player does.
function DefenseSystem.SetBlocking(model: Model, blocking: boolean, now: number): ()
	local registration = registrations[model]
	if not registration then
		return
	end
	if blocking then
		-- A committed traversal refuses the guard, on the same rule and through the same predicate
		-- AttackRequestSystem.Throw refuses a swing with -- see Shared/Parkour/ParkourOwnership. Raising
		-- a guard mid-vault would be the cheapest possible way to make every traversal safe, which is
		-- the opposite of what committing to one is supposed to mean.
		--
		-- ONLY THE PRESS. A Release always goes through: refusing one would strand a guard already up
		-- when the traversal started, held open with no input able to lower it -- the machine's own
		-- Press/Release pairing is what keeps the state honest, and a gate that can break the pair is a
		-- worse bug than the one it is closing.
		if ParkourOwnership.OwnsBody(registration.Humanoid) then
			return
		end
		local window = ParryWindows.Get(registration.ParryAnimationId)
		registration.Machine:Press(now, window, pingSecondsFor(model))
	else
		registration.Machine:Release(now)
	end
end

local function handleSetBlocking(player: Player, rawBlocking: unknown): ()
	if rateLimiter:IsLimited(player) then
		return
	end
	if typeof(rawBlocking) ~= "boolean" then
		return
	end
	local character = player.Character
	if not character then
		return
	end
	-- Same gate, same reasoning, as AttackRequestSystem's own Mounted refusal: a body welded to a blimp
	-- station belongs to the vehicle, and a guard raised from one would be a defence the arm pose is
	-- already overwriting the animation for. Read as an Attribute, not through a BlimpSystem require.
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid:GetAttribute(Constants.Attributes.Mounted) == true then
		return
	end
	DefenseSystem.SetBlocking(character, rawBlocking, os.clock())
end

-- Pass 1 -------------------------------------------------------------------------------------------

-- Classifies one contact against the defender's posture AT ITS SAMPLETIME. Applies nothing.
local function onHit(report: HitReport): ()
	local registration = registrations[report.Target]
	if not registration then
		-- An unregistered target has no defence at all, which is a legitimate state (scenery, a
		-- combatant registered with the engine but not here). Reported as Clean so the damage layer
		-- still sees every contact, rather than dropped.
		if #pending < DefenseConstants.MaxPendingContactsPerFrame then
			table.insert(pending, {
				Report = report,
				Attacker = report.Attacker,
				Defender = report.Target,
				BearingDegrees = 0,
				DefenderStateAtContact = "Neutral" :: DefenseState,
				Result = {
					Kind = "Clean" :: DefenseTypes.OutcomeKind,
					Guard = 0,
					GuardDelta = 0,
					ConsumesParry = false,
				},
				SampleTime = report.SampleTime,
			})
		end
		return
	end

	if #pending >= DefenseConstants.MaxPendingContactsPerFrame then
		-- Bounded rather than allowed to make an already-bad frame worse. Same reasoning as
		-- HitboxEngineConstants.MaxActiveSwings.
		return
	end

	local attackerRoot = report.Attacker:FindFirstChild("HumanoidRootPart")
	local attackerPosition = if attackerRoot and attackerRoot:IsA("BasePart")
		then attackerRoot.Position
		else report.ContactPosition
	local defenderCFrame = registration.RootPart.CFrame
	local bearing = OutcomeResolver.BearingDegrees(defenderCFrame.LookVector, defenderCFrame.Position, attackerPosition)

	local machine = registration.Machine
	local at = report.SampleTime
	-- ADVANCED TO THE CONTACT'S OWN TIME BEFORE IT IS QUERIED. Pass 1 runs inside the engine's Step,
	-- which is the frame BEFORE this system's own Step advances anything -- so without this the
	-- machine's live segment still describes whatever it was at the end of the LAST frame, and
	-- StateAt would report a window still open that closed two substeps ago. Advancing a clock is not
	-- applying a contact, so this does not break pass 1's "applies nothing" rule; contacts arrive in
	-- ascending SampleTime, so it is monotonic, and an `at` that predates the last Update is a no-op
	-- because transitions only fire when now >= the time they were due.
	machine:Update(at)
	local result = OutcomeResolver.Resolve({
		DefenderState = machine:StateAt(at),
		BearingDegrees = bearing,
		PowerLevel = report.PowerLevel,
		Guard = registration.Guard:Get(),
		GuardMax = registration.Guard:GetMax(),
		BlockHeld = machine:BlockHeldAt(at),
		ParryLive = machine:IsParryLiveAt(at),
		ParryConsumed = parryConsumedThisBatch[report.Target] == true,
	})

	if result.ConsumesParry then
		-- Marked in the batch, not on the machine: pass 1 applies nothing, and the machine's own flag
		-- is set in pass 2 alongside every other application.
		parryConsumedThisBatch[report.Target] = true
	end

	table.insert(pending, {
		Report = report,
		Attacker = report.Attacker,
		Defender = report.Target,
		BearingDegrees = bearing,
		DefenderStateAtContact = machine:StateAt(at),
		Result = result,
		SampleTime = at,
	})
end

-- Pass 2 -------------------------------------------------------------------------------------------

local function emit(outcome: DefenseOutcome): ()
	for _, callback in outcomeCallbacks do
		-- pcall'd because a consumer erroring must not take down the rest of the batch -- an outcome
		-- half-applied across two subscribers is worse than one subscriber missing an outcome.
		local ok, err = pcall(callback, outcome)
		if not ok then
			logger:error("A DefenseSystem.OnResolved consumer errored", { errorMessage = tostring(err) })
		end
	end
end

local function applyContact(contact: PendingContact, now: number): ()
	local defenderRegistration = registrations[contact.Defender]
	local kind = contact.Result.Kind

	if defenderRegistration then
		local machine = defenderRegistration.Machine
		local guard = defenderRegistration.Guard

		if contact.Result.ConsumesParry then
			machine:ConsumeParry(contact.SampleTime)
		end

		-- A block is the only thing that suppresses regeneration, and only because it is the only
		-- thing that spends the pool. A parry's restore must not also start a regen delay, or the
		-- reward would partly cancel itself.
		local spendsGuard = kind == "Blocked" or kind == "GuardBroken"
		guard:Set(contact.Result.Guard, now, spendsGuard)

		if kind == "GuardBroken" then
			machine:BreakGuard(now)
		end
	end

	if kind == "Parried" or kind == "Trade" then
		local attackerId = HitboxEngine.GetCombatantId(contact.Attacker)
		if attackerId then
			-- CANCELLED BEFORE STAGGERED, and the order is load-bearing: the engine clears
			-- RootControlLocked through its own exit path when a swing ends, so staggering first
			-- would have the engine clear the lock this system had just taken. Timed from the
			-- contact's SampleTime rather than the frame-end clock, so the attacker's own machine
			-- records the interruption at the substep it actually happened.
			HitboxEngine.CancelAttack(attackerId, if kind == "Trade" then "Traded" else "Parried", contact.SampleTime)
		end
	end

	if kind == "Parried" then
		-- A TRADE STAGGERS NOBODY. Both sides read correctly and both lose their swing; punishing
		-- either would make a mutual success into a mutual failure.
		local attackerRegistration = registrations[contact.Attacker]
		if attackerRegistration then
			attackerRegistration.Machine:Stagger(now)
		end
		if defenderRegistration then
			notifyClient(defenderRegistration, defenderRegistration.Machine:GetState(), contact.Report.ContactPosition)
		end
	end

	emit({
		Kind = kind,
		Report = contact.Report,
		Attacker = contact.Attacker,
		Defender = contact.Defender,
		BearingDegrees = contact.BearingDegrees,
		DefenderStateAtContact = contact.DefenderStateAtContact,
		Guard = contact.Result.Guard,
		GuardDelta = contact.Result.GuardDelta,
		SampleTime = contact.SampleTime,
	})
	debugLog("Contact resolved", { kind = kind, defender = contact.Defender.Name })
end

-- The loop -----------------------------------------------------------------------------------------

-- One frame. `now` is the caller's clock and is treated as the END of the frame, matching
-- HitboxEngine.Step's own convention so the two agree about what a frame is.
function DefenseSystem.Step(deltaTime: number, now: number): ()
	-- Machines first: a window that closed during this frame must have closed before the batch is
	-- arbitrated, or a whiff's recovery would be charged a frame late.
	for _, registration in registrations do
		local machine = registration.Machine
		machine:Update(now)
		local state = machine:GetState()
		-- Re-asserted every frame while the condition lasts -- see publishState's two-writer note.
		publishState(registration, state)

		-- Guard regenerates only from a posture that is not spending it. Blocking is excluded because
		-- you cannot rebuild a guard you are actively holding up, and Staggered because suppressing
		-- regeneration is one of the three costs that stops "a parried attacker can still block" from
		-- making the punish hollow.
		local regenerates = state ~= "Blocking" and state ~= "Staggered" and not machine:IsBlockHeld()
		registration.Guard:Regenerate(deltaTime, now, regenerates)
	end

	if #pending == 0 then
		return
	end

	OutcomeResolver.ArbitrateTrades(pending)
	for _, contact in pending do
		applyContact(contact, now)
	end

	table.clear(pending)
	table.clear(parryConsumedThisBatch)
end

-- Public queries -----------------------------------------------------------------------------------

-- Whether this combatant may start an attack, and why not when they may not.
--
-- ATTACK GATING IS THIS LAYER'S JOB, not the engine's -- the engine stays ignorant of stagger, which
-- is what keeps it standalone. The input layer consults this before HitboxEngine.RequestAttack.
--
-- Nothing consumes it yet: the attack input layer went with Client/Combat/CombatClient.lua and has
-- not been rebuilt, so stagger's no-attack rule is correct here and unenforced in play until it is.
function DefenseSystem.CanAttack(model: Model): (boolean, string?)
	local registration = registrations[model]
	if not registration then
		return true, nil
	end
	return registration.Machine:CanAttack()
end

function DefenseSystem.GetState(model: Model): DefenseState?
	local registration = registrations[model]
	return if registration then registration.Machine:GetState() else nil
end

function DefenseSystem.GetGuard(model: Model): (number?, number?)
	local registration = registrations[model]
	if not registration then
		return nil, nil
	end
	return registration.Guard:Get(), registration.Guard:GetMax()
end

-- Drains guard from OUTSIDE a blocked contact, breaking it if the drain empties the pool. Returns
-- (remaining, delta, broke); (nil, nil, false) for an unregistered model.
--
-- WHY THIS EXISTS: GUARD IS ALSO THE POSTURE POOL. Everything above this function only ever moves
-- guard while a player is actively blocking -- spent on a mitigated hit, restored on a parry -- which
-- means on its own it cannot touch a player who never raises a guard at all. The damage layer supplies
-- the other half: a hit that connects with no guard covering it drains the same meter, so turtling and
-- never engaging defence are both answerable with one resource and one HUD number instead of a second
-- parallel posture bar.
--
-- OWNERSHIP STAYS HERE rather than the damage layer reaching into GuardMeter itself. This module owns
-- the pool, the machine, the regeneration rule and what a break DOES; the caller owns only the
-- decision of how much and when. Two writers to one meter is two places for it to be computed
-- differently, which is the exact reasoning GuardMeter's own pure/stateful split already records.
--
-- `blockRegen` is passed true for the same reason a blocked hit passes it: without it, guard would
-- refill between the hits of a combo and the pressure would never accumulate into anything.
function DefenseSystem.DrainGuard(model: Model, amount: number, now: number): (number?, number?, boolean)
	local registration = registrations[model]
	if not registration then
		return nil, nil, false
	end
	if typeof(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return registration.Guard:Get(), 0, false
	end

	local remaining, delta, broke = GuardMeter.ApplyDrain(registration.Guard:Get(), amount)
	registration.Guard:Set(remaining, now, true)
	if broke then
		registration.Machine:BreakGuard(now)
	end

	-- Pushed to the owning client because nothing else would. notifyClient is otherwise only reached
	-- from a state TRANSITION, and an unblocked hit that merely dents the guard is not one -- so
	-- without this the meter would drain invisibly and a player's first sign of the mechanic would be
	-- the break itself. A break does transition, and would double-notify, so it is left to the
	-- transition hook to report.
	if not broke then
		notifyClient(registration, registration.Machine:GetState(), nil)
	end

	return remaining, delta, broke
end

-- This system's sole output. Returns a disconnect function rather than a connection object, matching
-- HitboxEngine.OnHit's own contract so a consumer of both learns one shape.
function DefenseSystem.OnResolved(callback: (DefenseOutcome) -> ()): () -> ()
	table.insert(outcomeCallbacks, callback)
	return function()
		local index = table.find(outcomeCallbacks, callback)
		if index then
			table.remove(outcomeCallbacks, index)
		end
	end
end

-- Lifecycle ----------------------------------------------------------------------------------------

-- Subscribes to the engine's contact signal, and nothing else. Split out of Init for the same reason
-- HitboxEngine keeps Step public and its own Init one line wide: a spec has to be able to drive this
-- system on a synthetic clock, and it cannot do that if the only way to receive contacts is to also
-- start a real Heartbeat that races the spec's own Step calls. Idempotent.
function DefenseSystem.Attach(): ()
	if hitDisconnect then
		return
	end
	hitDisconnect = HitboxEngine.OnHit(onHit)
end

function DefenseSystem.Init(): ()
	if started then
		return
	end
	-- See this file's header: Heartbeat order is a correctness property, not a preference. Asserted
	-- rather than documented, because a comment in Main.server.lua cannot fail a boot.
	assert(
		HitboxEngine.RegisteredCount() >= 0 and HitboxEngine.EngagedCount() >= 0,
		"DefenseSystem.Init() requires HitboxEngine to be available"
	)
	started = true

	local setBlocking = NetworkBridge.CreateRemoteEvent(DefenseConstants.Network.RemoteNames.SetBlocking)
	setBlocking.OnServerEvent:Connect(handleSetBlocking)
	stateChangedRemote = NetworkBridge.CreateRemoteEvent(DefenseConstants.Network.RemoteNames.StateChanged)

	DefenseSystem.Attach()

	-- REGISTERS PLAYER CHARACTERS ITSELF, rather than waiting to be told by whoever registers them
	-- with the hitbox engine. Defence does not depend on the engine's registry -- it needs one of its
	-- own for the machine and the guard pool, and GetCombatantId is consulted only to cancel a
	-- parried swing (and correctly returns nil when the attacker is unknown to the engine). So a
	-- player can block and parry from the moment this ships, months before the attack layer that
	-- registers engine combatants is rebuilt.
	--
	-- Bots and dummies are NOT auto-registered: they have no CharacterAdded to hang off, and whoever
	-- spawns them already knows when they exist. They call RegisterCombatant directly.
	-- Through Shared/PlayerLifecycle.lua, which supplies the per-player character hookup AND the
	-- Init()-time sweep for players who joined before this System booted. The Humanoid arrives already
	-- resolved; the HumanoidRootPart stays this System's own lookup, since RegisterCombatant requires
	-- a root explicitly rather than trusting rig-joint auto-detection.
	PlayerLifecycle.BindAllPlayers({
		Scope = "DefenseSystem",
		OnCharacter = function(_player: Player, character: Model, humanoid: Humanoid)
			local rootPart = character:FindFirstChild("HumanoidRootPart")
			if not rootPart or not rootPart:IsA("BasePart") then
				return
			end
			DefenseSystem.RegisterCombatant(character, rootPart, humanoid)
		end,
		OnCharacterRemoving = function(_player: Player, character: Model)
			DefenseSystem.UnregisterCombatant(character)
		end,
		-- Separate from OnCharacterRemoving above and NOT redundant with it: CharacterRemoving does not
		-- fire for a player who simply leaves the server, so the registration has to be dropped here too.
		OnPlayerRemoving = function(player: Player)
			rateLimiter:Clear(player)
			local character = player.Character
			if character then
				DefenseSystem.UnregisterCombatant(character)
			end
		end,
	})

	-- Connected AFTER HitboxEngine.Init has connected its own, which Main.server.lua guarantees by
	-- calling that first.
	heartbeatTrove:Connect(RunService.Heartbeat, function(deltaTime: number)
		DefenseSystem.Step(deltaTime, os.clock())
	end)

	-- Warms every window this system might arm and warns per missing one, so an unmarked clip is a
	-- startup warning rather than a mid-fight mystery. Spawned rather than awaited: it makes web
	-- calls, and blocking the server boot on a rate-limited endpoint would be worse than the first
	-- few seconds of play having no parry armed.
	--
	-- EVERY WEAPON'S PARRY CLIP, not just the default -- WeaponDefenseAnimations.GetParryIds sweeps
	-- Workspace.Weapons for per-weapon Animations/PARRY overrides and returns them alongside the
	-- baseline. Warming only the baseline (which is all this did before per-weapon clips existed)
	-- would leave a weapon that authors its own parry strictly worse off than one that authors none:
	-- ParryWindows.Get never yields, so an id nobody prefetched returns nil at press time and that
	-- weapon's parry would never once arm, with no error anywhere.
	--
	-- Reads Workspace.Weapons at Init, which Main.server.lua has already populated by running
	-- WeaponRoster.Start() before the combat stack boots. A weapon added to the folder after this
	-- point is not swept -- the same boot-time-snapshot property WeaponRoster itself has.
	local parryIds = WeaponDefenseAnimations.GetParryIds()
	-- GetParryIds' own baseline is DefenseConstants.ParryAnimationId, which is what Main.server.lua
	-- happens to pass to SetDefaultParryAnimation -- but this System's contract is that the default is
	-- whatever that setter was LAST given, not that constant. Appended (deduplicated) rather than
	-- assumed already present, so a caller that sets a different default still gets it warmed.
	if defaultParryAnimationId ~= "" and table.find(parryIds, defaultParryAnimationId) == nil then
		table.insert(parryIds, defaultParryAnimationId)
	end
	if #parryIds > 0 then
		task.spawn(function()
			ParryWindows.ValidateAll(parryIds)
		end)
	end

	logger:info("DefenseSystem.Init() complete")
end

function DefenseSystem.Shutdown(): ()
	heartbeatTrove:Clean()
	if hitDisconnect then
		hitDisconnect()
		hitDisconnect = nil
	end
	started = false
end

-- Drops every registration and buffered contact. Spec-only, so one case cannot serve another its
-- state -- the same role HitboxEngine.Reset plays for the engine.
function DefenseSystem.Reset(): ()
	-- Dropped so a following Attach() genuinely re-subscribes. HitboxEngine.Reset table.clears its own
	-- callback list, so a spec that resets both would otherwise be left holding a stale non-nil handle
	-- for a subscription that no longer exists -- and Attach's idempotence guard would then refuse to
	-- make a new one, silently delivering no contacts for every case after the first.
	if hitDisconnect then
		hitDisconnect()
		hitDisconnect = nil
	end
	for model in registrations do
		DefenseSystem.UnregisterCombatant(model)
	end
	table.clear(registrations)
	table.clear(pending)
	table.clear(parryConsumedThisBatch)
	table.clear(outcomeCallbacks)
	defaultParryAnimationId = ""
end

return DefenseSystem :: Types.SystemModule & typeof(DefenseSystem)
