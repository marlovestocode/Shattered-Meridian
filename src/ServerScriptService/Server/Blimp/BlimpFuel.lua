--!strict
--[[
	BlimpFuel.lua

	Owns: the fuel simulation -- draining Coal/Water while the engine is under power, accepting a
	deposit up to whatever room is left in the tank, handing a deposit back out again (Withdraw), and
	answering "is this hull grounded" and "how long until it is." Mirrors Server/Blimp/BlimpDrive.lua's own shape exactly and for the same reason:
	every function here takes a BlimpTypes.FuelState/FuelTuning and returns a FuelState (or a plain
	number), touching no Instance at all, which is what makes the actual behaviour -- does coal really
	burn ten times slower than water, does a deposit really cap at the tank's remaining room, does the
	minimum really gate the engine before the tank is dry -- testable in the TestEZ suite without a
	place file. Server/Systems/BlimpSystem.lua owns every Instance touch and calls this for the
	arithmetic, the same split it already has with BlimpDrive.

	THE MINIMUM IS AN OPERATING RESERVE, NOT A DEPLETION FLOOR -- see BlimpConstants.Fuel's own header
	for the full argument (a real steam boiler's low-water cutoff is the model). IsDepleted compares
	the live level against FuelTuning.CoalMinimum/WaterMinimum, never against zero, and SecondsUntilMinimum
	answers "how long until THAT line is crossed," not "how long until empty." A hull can be sitting on
	475 coal and still be grounded because water alone dropped under its own minimum.

	Does not own: the tuning numbers themselves (Shared/Blimp/BlimpConstants.lua), the per-model
	overrides (Shared/Blimp/BlimpTagging.ResolveFuelTuning), which players may deposit into a tank or
	how much they're carrying (Server/Systems/BlimpSystem.lua and Server/Systems/
	ResourceGatheringSystem.lua respectively), or what happens to the DRIVE once depleted (BlimpSystem's
	own heartbeat tick decides to substitute a neutral intent -- this module has no notion of intent at
	all).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BlimpTypes = require(ReplicatedStorage.Shared.Blimp.BlimpTypes)

local BlimpFuel = {}

-- Seconds. Same reasoning and same value as BlimpDrive.MAX_STEP_SECONDS: a tick longer than this is a
-- server hitch or a Studio breakpoint, not flight time, and burning fuel for the whole stalled
-- duration would drain a tank in one bad frame for no in-fiction reason.
local MAX_STEP_SECONDS = 0.25

-- A freshly registered blimp's fuel state -- always empty. See this file's header and
-- BlimpConstants.Fuel's own header: a blimp starts unfueled, matching "users have to collect these
-- items to use the blimp." There is no CoalCapacity/WaterCapacity argument here on purpose -- an empty
-- tank is empty regardless of how big it is.
function BlimpFuel.NewState(): BlimpTypes.FuelState
	return { Coal = 0, Water = 0 }
end

-- One tick. Pure: `state` is never mutated, the successor is returned. Draining happens only while
-- `thrusting` is true -- the exact same isUnderPower(intent) condition BlimpSystem already computes
-- once per Heartbeat to drive the exhaust FX, passed in rather than re-derived here so "the exhaust is
-- burning" and "fuel is draining" can never disagree about what counts as under power.
function BlimpFuel.Step(
	state: BlimpTypes.FuelState,
	thrusting: boolean,
	tuning: BlimpTypes.FuelTuning,
	deltaTime: number
): BlimpTypes.FuelState
	if not thrusting then
		return state
	end
	local dt = math.clamp(deltaTime, 0, MAX_STEP_SECONDS)
	if dt <= 0 then
		return state
	end

	return {
		Coal = math.max(0, state.Coal - tuning.CoalBurnPerSecond * dt),
		Water = math.max(0, state.Water - tuning.WaterBurnPerSecond * dt),
	}
end

-- Accepts as much of `amount` as fits in the named tank's remaining room, returning the successor
-- state and how much was actually accepted (0 for a full tank or a non-positive `amount`) -- the
-- caller (BlimpSystem.depositFuel) needs the accepted figure to know how much to debit off the
-- player's own carried total, and must never debit more than the tank actually took.
function BlimpFuel.Deposit(
	state: BlimpTypes.FuelState,
	resource: BlimpTypes.FuelResource,
	amount: number,
	tuning: BlimpTypes.FuelTuning
): (BlimpTypes.FuelState, number)
	if amount <= 0 then
		return state, 0
	end

	local capacity = if resource == "Coal" then tuning.CoalCapacity else tuning.WaterCapacity
	local current = if resource == "Coal" then state.Coal else state.Water
	local room = math.max(0, capacity - current)
	local accepted = math.min(amount, room)
	if accepted <= 0 then
		return state, 0
	end

	if resource == "Coal" then
		return { Coal = current + accepted, Water = state.Water }, accepted
	end
	return { Coal = state.Coal, Water = current + accepted }, accepted
end

-- The mirror of Deposit above: takes as much of `amount` as the named tank actually HAS, returning
-- the successor state and how much came out. The caller (BlimpSystem.unloadFuel) has already
-- clamped `amount` to the room left under the withdrawing player's own carry cap, and must never
-- credit them more than this returns.
--
-- TAKES NO FuelTuning, and the asymmetry with Deposit is the point rather than an oversight. A
-- deposit is bounded by a number that belongs to the HULL (its capacity), so it needs the tuning; a
-- withdrawal is bounded on the tank side only by what is in there, and on the player side by a cap
-- this module has no business knowing about (Shared/Blimp/BlimpConstants.Carry -- see that table's
-- own header on why the carry caps live with the tank capacities and not here).
--
-- DELIBERATELY IGNORES THE OPERATING MINIMUM. Draining a tank below its own CoalMinimum/WaterMinimum
-- grounds the hull (IsDepleted below), and that is allowed: the minimum exists to stop an ENGINE
-- running a tank dry mid-flight, not to hold a player's own coal hostage in a ship they are standing
-- next to. A refusal here would be a rule with no fiction behind it -- you can always shovel the
-- last of the coal back out of a furnace.
function BlimpFuel.Withdraw(
	state: BlimpTypes.FuelState,
	resource: BlimpTypes.FuelResource,
	amount: number
): (BlimpTypes.FuelState, number)
	if amount <= 0 then
		return state, 0
	end

	local current = if resource == "Coal" then state.Coal else state.Water
	local withdrawn = math.min(amount, math.max(0, current))
	if withdrawn <= 0 then
		return state, 0
	end

	if resource == "Coal" then
		return { Coal = current - withdrawn, Water = state.Water }, withdrawn
	end
	return { Coal = state.Coal, Water = current - withdrawn }, withdrawn
end

-- True once either pool has dropped below its own operating reserve -- see this file's header. The
-- engine gates on THIS, never on either pool reaching literal zero.
function BlimpFuel.IsDepleted(state: BlimpTypes.FuelState, tuning: BlimpTypes.FuelTuning): boolean
	return state.Coal < tuning.CoalMinimum or state.Water < tuning.WaterMinimum
end

-- Seconds of continuous thrust before each pool crosses its own Minimum -- what the Driver HUD's
-- "estimated time remaining" and status color are both derived from (Client/UI/Screens/BlimpFuel).
-- math.huge while `thrusting` is false: an idle engine burns nothing, so there is no meaningful
-- countdown to report, and math.huge reads as "safe" to every caller that buckets it against a
-- threshold without needing a separate "is this even draining" flag.
function BlimpFuel.SecondsUntilMinimum(
	state: BlimpTypes.FuelState,
	tuning: BlimpTypes.FuelTuning,
	thrusting: boolean
): (number, number)
	if not thrusting then
		return math.huge, math.huge
	end

	local coalSeconds = if tuning.CoalBurnPerSecond > 0
		then math.max(0, state.Coal - tuning.CoalMinimum) / tuning.CoalBurnPerSecond
		else math.huge
	local waterSeconds = if tuning.WaterBurnPerSecond > 0
		then math.max(0, state.Water - tuning.WaterMinimum) / tuning.WaterBurnPerSecond
		else math.huge
	return coalSeconds, waterSeconds
end

return BlimpFuel
