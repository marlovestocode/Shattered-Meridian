--!strict
--[[
	AttackStateMachine.lua

	Owns: the lifecycle of ONE combatant's attack -- Idle -> Windup -> Active -> Recovery -> Idle, plus
	the Interrupted escape reachable from any of the three attack phases. One instance per registered
	combatant, created and driven by HitboxEngine.lua.

	Structurally this follows Client/Parkour/StateMachine.lua's conventions on purpose --
	CanEnter/Enter/Update/Exit per state, an explicit transition record, a machine that never reaches
	inside a state -- so that anyone who has read the movement FSM already knows how to read this one.
	It is NOT that module, and does not use it: parkour's is parameterised over movement-specific
	context and state-id types and lives on the client, and generalising it to serve both would couple
	the combat engine to the movement framework precisely where this engine is supposed to be
	standalone. Five fixed states with no registration API is also simply the right size for the job;
	parkour's dynamic registry exists because new movement states get added, and there is no sixth
	attack phase coming.

	TWO DIFFERENCES FROM THE PARKOUR MACHINE, both deliberate:

	1. TRANSITIONS CHAIN WITHIN ONE UPDATE. Parkour applies at most one transition per call because
	   its graph is cyclic and a mis-authored pair of states could otherwise spin forever inside a
	   single Heartbeat. This graph is a straight line -- Windup only ever leads to Active, Active only
	   to Recovery, Recovery only to Idle, and Idle leads nowhere on its own -- so the chain is finite
	   by construction and bounded at four hops. Refusing to chain would instead mean a phase authored
	   at zero seconds (a jab with no windup) silently costing a frame each, which is real, felt input
	   latency in exactly the attacks tuned to have none. MAX_CHAINED_TRANSITIONS caps it anyway, since
	   a bound that depends on nobody ever adding a cycle is not a bound.

	2. PHASE BOUNDARIES USE THE TIME THEY WERE DUE, NOT THE TIME THEY WERE NOTICED. When a 50ms windup
	   is observed to have finished 8ms late, Active begins at the 50ms mark, not at 58ms. Carrying the
	   overshoot forward instead would let every phase start a little later than the last, so an
	   attack's total length would depend on server frame timing -- and frame data that drifts under
	   load is frame data players cannot learn. This is also what makes the engine's substepping
	   worthwhile: sampling finely is pointless if the window being sampled has itself slid.

	TIME COMES FROM THE CALLER on every entry point, never from os.clock() here -- the same rule
	Server/Combat/ObjectStunResolver.lua keeps. Two calls within one frame must agree on "now", the
	engine's substep loop deliberately drives this machine at times BETWEEN Heartbeats, and a machine
	that read its own clock could not be tested without sleeping.

	Does not own: hitbox geometry, sampling, targets, or what an attack does to anyone (HitboxEngine.lua
	and its future consumer layer). It knows an attack has phases and how long they last. It has never
	heard of a hit.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local HitboxEngineConstants = require(ReplicatedStorage.Shared.HitboxEngine.HitboxEngineConstants)

type AttackDefinition = HitboxTypes.AttackDefinition

local AttackStateMachine = {}
AttackStateMachine.__index = AttackStateMachine

export type AttackState = "Idle" | "Windup" | "Active" | "Recovery" | "Interrupted"

-- Everything about the attack currently in flight. Held by the machine for the swing's whole life so
-- a consumer reacting to a hit found in the Active window can still see the ComboStage the caller
-- requested it with, seconds after the call that started it returned.
export type Swing = {
	Definition: AttackDefinition,
	ComboStage: number,
	PowerLevel: number,
	StartedAt: number,
	-- Set only when the swing ended via Interrupt. Read by the engine's OnSwingEnded hook to decide
	-- whether the attack completed or was cut short.
	InterruptReason: string?,
}

-- Callbacks the engine hands the machine at construction. Kept as an explicit hook table rather than
-- letting the engine poll GetState() every tick, because the engine has to react to the EXACT moment
-- a boundary is crossed -- setting RootControlLocked, opening a swing's hit set -- and a poller that
-- notices a boundary one tick late is a lock applied one tick late.
export type Hooks = {
	OnEnterActive: ((Swing) -> ())?,
	OnExitActive: ((Swing) -> ())?,
	-- Fires once per swing, on the return to Idle by any route. `completed` is false when the swing
	-- was interrupted.
	OnSwingEnded: ((Swing, completed: boolean) -> ())?,
}

export type Machine = typeof(setmetatable(
	{} :: {
		_state: AttackState,
		_previousState: AttackState,
		-- Time the CURRENT state began, in the caller's clock. Set to the time a transition was DUE,
		-- not the time it was observed -- see this file's header.
		_enteredAt: number,
		_swing: Swing?,
		_hooks: Hooks,
	},
	AttackStateMachine
))

-- Four is the real maximum (Windup -> Active -> Recovery -> Idle from a standing start). Eight leaves
-- room for a phase to be added without this becoming a silent cap, while still guaranteeing Update
-- terminates if someone ever introduces a cycle.
local MAX_CHAINED_TRANSITIONS = 8

-- How long each timed phase lasts, given the swing in flight. Idle has no duration (it never ends on
-- its own) and Interrupted has a duration of zero (it always resolves to Idle on the very next
-- evaluation, which the chaining above means is usually the same Update).
local function phaseDuration(state: AttackState, swing: Swing): number?
	local definition = swing.Definition
	if state == "Windup" then
		return definition.WindupSeconds
	elseif state == "Active" then
		return definition.ActiveSeconds
	elseif state == "Recovery" then
		return definition.RecoverySeconds
	elseif state == "Interrupted" then
		return 0
	end
	return nil
end

local function nextState(state: AttackState): AttackState?
	if state == "Windup" then
		return "Active"
	elseif state == "Active" then
		return "Recovery"
	elseif state == "Recovery" then
		return "Idle"
	elseif state == "Interrupted" then
		return "Idle"
	end
	return nil
end

function AttackStateMachine.New(hooks: Hooks?): Machine
	return setmetatable({
		_state = "Idle" :: AttackState,
		_previousState = "Idle" :: AttackState,
		_enteredAt = 0,
		_swing = nil,
		_hooks = hooks or {},
	}, AttackStateMachine) :: any
end

function AttackStateMachine.GetState(self: Machine): AttackState
	return self._state
end

function AttackStateMachine.GetPreviousState(self: Machine): AttackState
	return self._previousState
end

function AttackStateMachine.GetSwing(self: Machine): Swing?
	return self._swing
end

function AttackStateMachine.IsAttacking(self: Machine): boolean
	return self._state ~= "Idle"
end

-- When the machine last went Idle, or nil while a swing is in flight. A swing may not be backdated to
-- before this (HitboxEngine.RequestAttack's startedAt): the body was still in its previous swing then.
function AttackStateMachine.GetIdleSince(self: Machine): number?
	return if self._state == "Idle" then self._enteredAt else nil
end

function AttackStateMachine.GetStateElapsed(self: Machine, now: number): number
	return math.max(now - self._enteredAt, 0)
end

-- Seconds the CURRENT swing has been in its Active window, or 0 outside one. This is what a charge
-- attack's growth is measured against -- see HitboxEngine's scaling evaluation.
function AttackStateMachine.GetActiveElapsed(self: Machine, now: number): number
	if self._state ~= "Active" then
		return 0
	end
	return math.max(now - self._enteredAt, 0)
end

-- Applies one transition, running Exit on the outgoing state then Enter on the incoming one. `at` is
-- when the transition is deemed to have happened, which for a timed boundary is when it was DUE.
local function applyTransition(self: Machine, target: AttackState, at: number): ()
	local from = self._state
	if from == target then
		return
	end

	local swing = self._swing
	local hooks = self._hooks

	-- Exit.
	if from == "Active" and swing and hooks.OnExitActive then
		hooks.OnExitActive(swing)
	end

	self._previousState = from
	self._state = target
	self._enteredAt = at

	-- Enter.
	if target == "Active" and swing and hooks.OnEnterActive then
		hooks.OnEnterActive(swing)
	elseif target == "Idle" then
		-- The swing is released here and nowhere else, so every route home -- completed recovery,
		-- interruption, the runaway-swing deadline -- frees it and fires exactly one OnSwingEnded.
		self._swing = nil
		if swing and hooks.OnSwingEnded then
			hooks.OnSwingEnded(swing, swing.InterruptReason == nil)
		end
	end
end

-- Starts an attack. Returns (accepted, reason) -- a refusal is entirely normal and never an error,
-- matching ObjectStunResolver.Watch's contract: a player mashing during their own recovery frames is
-- ordinary play, not a fault, and the caller decides whether to buffer the input or drop it. The
-- refusal reason is returned rather than logged so specs can assert on it and so a UI could show it.
function AttackStateMachine.Begin(
	self: Machine,
	definition: AttackDefinition,
	comboStage: number,
	powerLevel: number,
	now: number
): (boolean, string?)
	if self._state ~= "Idle" then
		return false, "Busy"
	end

	self._swing = {
		Definition = definition,
		ComboStage = comboStage,
		PowerLevel = powerLevel,
		StartedAt = now,
		InterruptReason = nil,
	}

	applyTransition(self, "Windup", now)
	-- Driven immediately so a definition with a zero-second windup reaches Active within the call
	-- that started it, rather than on the next tick. Same reasoning as the chaining rule above: the
	-- attacks most likely to author a zero windup are the ones whose whole point is that they come out
	-- instantly.
	AttackStateMachine.Update(self, now)
	return true, nil
end

-- Cuts a swing short from outside -- what a future consumer layer calls when a parry, a stun or a
-- ragdoll needs to end an attack that is still swinging. Interrupted runs the same Exit path a normal
-- finish would, so a locking swing cannot leave RootControlLocked set on a body nobody is animating.
function AttackStateMachine.Interrupt(self: Machine, reason: string, now: number): boolean
	if self._state == "Idle" then
		return false
	end
	-- Recorded BEFORE the transition, because applyTransition's Idle branch reads it to decide whether
	-- the swing completed.
	local swing = self._swing
	if swing then
		swing.InterruptReason = reason
	end
	applyTransition(self, "Interrupted", now)
	AttackStateMachine.Update(self, now)
	return true
end

-- Advances the machine to `now`. Returns the state that is active when it finishes, which may differ
-- from the one that was active when it started -- and, because transitions chain, may be several
-- states along.
function AttackStateMachine.Update(self: Machine, now: number): AttackState
	for _ = 1, MAX_CHAINED_TRANSITIONS do
		local swing = self._swing
		if self._state == "Idle" or swing == nil then
			break
		end

		-- Runaway guard, checked before the phase boundary so it wins over it. A swing whose owner
		-- never interrupts it and whose authored timings are absurd would otherwise hold one of the
		-- engine's MaxActiveSwings slots -- and, if it locks movement, the attacker's body -- for the
		-- rest of the session. Routed through Interrupted rather than jumping to Idle so it cleans up
		-- through the exact same path every other ending uses.
		if now - swing.StartedAt > HitboxEngineConstants.MaxSwingSeconds and self._state ~= "Interrupted" then
			swing.InterruptReason = "Expired"
			applyTransition(self, "Interrupted", now)
			continue
		end

		local duration = phaseDuration(self._state, swing)
		if duration == nil then
			break
		end

		local dueAt = self._enteredAt + duration
		if now < dueAt then
			break
		end

		local target = nextState(self._state)
		if target == nil then
			break
		end
		applyTransition(self, target, dueAt)
	end

	return self._state
end

-- Drops the machine straight to Idle, running the ordinary Exit path so nothing is left set on the
-- body. For teardown -- unregistration, a character despawning, a spec resetting between cases --
-- where there is no meaningful "now" and no consumer that should treat it as an in-game interruption.
function AttackStateMachine.Reset(self: Machine, now: number): ()
	if self._state ~= "Idle" then
		local swing = self._swing
		if swing then
			swing.InterruptReason = swing.InterruptReason or "Reset"
		end
		applyTransition(self, "Idle", now)
	end
	self._previousState = "Idle"
	self._enteredAt = now
end

return AttackStateMachine
