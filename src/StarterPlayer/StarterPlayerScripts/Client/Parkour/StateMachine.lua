--!strict
--[[
	StateMachine.lua

	Owns: the generic, movement-agnostic state machine every parkour state runs inside -- registration,
	the per-frame dispatch, transition arbitration by priority, entry/exit callbacks, elapsed-time
	bookkeeping, and the transition history the debug overlay reads.

	Deliberately knows NOTHING about parkour. It never mentions a wall, a ledge or a slide; it takes
	ParkourTypes.StateDefinition tables and ParkourTypes.ParkourContext values and moves between them.
	That is the whole reason the design's "do not use a basic collection of if-statements for every
	movement mechanic ... new movement mechanics can be added later without having to rewrite the
	existing system" requirement is actually satisfied rather than merely claimed: adding a mechanic
	is one new file under States/ plus one line in States/init.lua, and this file does not change.
	It is also why this module is headlessly testable (src/Tests/Parkour/StateMachine.spec.lua drives
	it with synthetic states and a synthetic context, no character required).

	THE TWO TRANSITION ROUTES, and why there are exactly two:
	  1. SELF-DIRECTED -- the active state's Update returns the id it wants to hand off to. A state
	     always owns its own exit conditions; nothing else can decide that a slide is over.
	  2. PRE-EMPTION -- a registered state with a STRICTLY HIGHER Priority whose CanEnter accepts.
	     This is how "sprinting into a vault" happens without Sprinting.Update needing to know vaults
	     exist. Strictly higher, not higher-or-equal, so two states at the same priority can never
	     ping-pong, and so a state is never pre-empted by a peer that merely also happens to accept.
	A state marked Committed is exempt from route 2 entirely for as long as it is active -- that is
	what makes a vault/mantle/climb finish rather than being stolen mid-animation by whatever the
	character happens to be flying past.

	Does not own: what any state does (Client/Parkour/States/*), what the context contains
	(ParkourController.lua builds it), or any Instance/RunService/network concern.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)
local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)

type MovementStateId = ParkourTypes.MovementStateId
type StateDefinition = ParkourTypes.StateDefinition
type ParkourContext = ParkourTypes.ParkourContext

local StateMachine = {}
StateMachine.__index = StateMachine

-- One recorded transition, for the debug overlay's history list.
export type TransitionRecord = {
	From: MovementStateId,
	To: MovementStateId,
	-- "Self" for route 1, "Preempt" for route 2, "Forced" for an external ForceTransition (a
	-- respawn/bind reset, or combat taking the body).
	Route: "Self" | "Preempt" | "Forced",
	At: number,
}

-- What every registered state currently says about its own availability, for the debug overlay --
-- see EvaluateAvailability below.
export type AvailabilityRecord = {
	Id: MovementStateId,
	Available: boolean,
	Reason: string?,
}

export type Machine = typeof(setmetatable(
	{} :: {
		_states: { [string]: StateDefinition },
		-- Registration order, used only for a stable iteration order in EvaluateAvailability's debug
		-- output. The per-frame pre-emption scan uses _sorted below instead.
		_registered: { StateDefinition },
		-- Registered states sorted by descending Priority, rebuilt on each Register. The pre-emption
		-- scan walks this and stops at the first state whose priority is no longer above the active
		-- one's, which turns route 2 from "test every state every frame" into "test only the ones
		-- that could actually win."
		_sorted: { StateDefinition },
		_currentId: MovementStateId,
		_previousId: MovementStateId,
		_enteredAt: number,
		_history: { TransitionRecord },
		_availability: { AvailabilityRecord },
	},
	StateMachine
))

-- Creates an empty machine parked in `initialId`. The initial state is NOT entered (its Enter
-- callback does not fire) -- at construction time there is no context to hand it, and every real
-- caller immediately drives a first Update which will transition properly if the character isn't
-- actually idle.
function StateMachine.New(initialId: MovementStateId): Machine
	return setmetatable({
		_states = {},
		_registered = {},
		_sorted = {},
		_currentId = initialId,
		_previousId = initialId,
		_enteredAt = 0,
		_history = {},
		_availability = {},
	}, StateMachine) :: any
end

-- Registers a state. Re-registering the same id replaces the definition (harmless on a module
-- reload in Studio; a genuine duplicate registration in shipped code would be a bug the caller's own
-- registry ordering makes impossible).
function StateMachine.Register(self: Machine, definition: StateDefinition): ()
	local existing = self._states[definition.Id]
	self._states[definition.Id] = definition
	if not existing then
		table.insert(self._registered, definition)
	else
		for index, candidate in self._registered do
			if candidate.Id == definition.Id then
				self._registered[index] = definition
				break
			end
		end
	end

	table.clear(self._sorted)
	table.move(self._registered, 1, #self._registered, 1, self._sorted)
	table.sort(self._sorted, function(a: StateDefinition, b: StateDefinition): boolean
		if a.Priority == b.Priority then
			-- Deterministic tiebreak so a same-priority pair never reorders between frames, which
			-- would make pre-emption non-reproducible and any resulting bug unrepeatable.
			return a.Id < b.Id
		end
		return a.Priority > b.Priority
	end)
end

function StateMachine.GetCurrentId(self: Machine): MovementStateId
	return self._currentId
end

function StateMachine.GetPreviousId(self: Machine): MovementStateId
	return self._previousId
end

function StateMachine.GetDefinition(self: Machine, id: MovementStateId): StateDefinition?
	return self._states[id]
end

function StateMachine.GetCurrentDefinition(self: Machine): StateDefinition?
	return self._states[self._currentId]
end

function StateMachine.GetHistory(self: Machine): { TransitionRecord }
	return self._history
end

local function record(
	self: Machine,
	from: MovementStateId,
	to: MovementStateId,
	route: "Self" | "Preempt" | "Forced",
	now: number
): ()
	table.insert(self._history, { From = from, To = to, Route = route, At = now })
	-- Bounded ring: the overlay only ever shows the most recent handful, and an unbounded list on a
	-- session-long client would grow without limit for no reader.
	while #self._history > ParkourConstants.Debug.TransitionHistory do
		table.remove(self._history, 1)
	end
end

-- Performs a transition, running Exit on the outgoing state and Enter on the incoming one, in that
-- order. Both callbacks see a context whose CurrentStateId/PreviousStateId/StateElapsed already
-- reflect the transition being made, so neither has to reason about a half-applied machine.
--
-- A transition to an unregistered id is refused rather than erroring: a state returning a typo'd id
-- should leave the character in a working state and produce a visible refusal, not break movement
-- entirely for the rest of the session.
local function applyTransition(
	self: Machine,
	targetId: MovementStateId,
	context: ParkourContext,
	route: "Self" | "Preempt" | "Forced"
): boolean
	local target = self._states[targetId]
	if not target then
		return false
	end
	local fromId = self._currentId
	if fromId == targetId then
		return false
	end

	local outgoing = self._states[fromId]
	if outgoing and outgoing.Exit then
		context.CurrentStateId = fromId
		context.PreviousStateId = self._previousId
		outgoing.Exit(context, targetId)
	end

	self._previousId = fromId
	self._currentId = targetId
	self._enteredAt = context.Now

	context.CurrentStateId = targetId
	context.PreviousStateId = fromId
	context.StateElapsed = 0

	if target.Enter then
		target.Enter(context, fromId)
	end

	record(self, fromId, targetId, route, context.Now)
	return true
end

-- Externally-driven transition -- for the cases that are not the state machine's own decision:
-- binding a fresh character, combat taking the body, the feature being switched off. Bypasses
-- CanEnter deliberately (the caller is asserting, not asking) but still runs Exit/Enter so no state
-- is left holding a constraint or an animation.
function StateMachine.ForceTransition(self: Machine, targetId: MovementStateId, context: ParkourContext): boolean
	return applyTransition(self, targetId, context, "Forced")
end

-- One frame. Returns the id that is active when it finishes, which may differ from the id that was
-- active when it started.
--
-- At most ONE transition is applied per call, on purpose. Chaining several in a single frame (state
-- A hands to B, B immediately hands to C) would let a mis-authored pair of states loop forever
-- inside one Heartbeat and hang the client; capping at one bounds the worst case to a one-frame
-- delay per hop, which is imperceptible and always recoverable.
function StateMachine.Update(self: Machine, context: ParkourContext): MovementStateId
	local current = self._states[self._currentId]
	if not current then
		return self._currentId
	end

	context.CurrentStateId = self._currentId
	context.PreviousStateId = self._previousId
	context.StateElapsed = math.max(context.Now - self._enteredAt, 0)

	-- Route 1: the active state's own decision, which always outranks pre-emption -- a state that
	-- has decided it is finished must not be second-guessed by a peer that would also like a turn.
	local requested = current.Update(context)
	if requested and requested ~= self._currentId then
		applyTransition(self, requested, context, "Self")
		return self._currentId
	end

	if current.Committed then
		return self._currentId
	end

	-- Route 2: the highest-priority state above the active one whose CanEnter accepts. _sorted is
	-- descending, so the first acceptance found is definitively the winner and the scan can stop --
	-- and the whole loop can stop the moment priorities drop to the active state's own level.
	for _, candidate in self._sorted do
		if candidate.Priority <= current.Priority then
			break
		end
		if candidate.Id ~= self._currentId then
			local canEnter = candidate.CanEnter(context)
			if canEnter then
				applyTransition(self, candidate.Id, context, "Preempt")
				return self._currentId
			end
		end
	end

	return self._currentId
end

-- Asks EVERY registered state whether it would currently accept, and why not when it wouldn't.
-- Exists solely for Client/Parkour/ParkourDebug.lua -- this is the query that answers the design's
-- "display ... available parkour actions, and why a parkour action was or was not allowed."
--
-- Safe to call because CanEnter is contractually a pure predicate (ParkourTypes.StateDefinition's
-- own header) -- if a state ever violated that, this function would visibly corrupt movement while
-- the overlay was open, which is a good, loud failure for a contract violation rather than a silent
-- one.
--
-- Reuses its own result array across calls (the overlay refreshes on a timer forever) -- the caller
-- must read it before the next call.
function StateMachine.EvaluateAvailability(self: Machine, context: ParkourContext): { AvailabilityRecord }
	local records = self._availability
	table.clear(records)
	for _, definition in self._registered do
		local available, reason = definition.CanEnter(context)
		table.insert(records, { Id = definition.Id, Available = available, Reason = reason })
	end
	return records
end

return StateMachine
