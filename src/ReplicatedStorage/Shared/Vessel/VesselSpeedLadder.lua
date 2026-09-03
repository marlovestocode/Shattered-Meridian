--!strict
--[[
	VesselSpeedLadder.lua

	Owns: reading a table of rungs as a LADDER rather than as an array -- where the neutral rung is,
	what a rung's throttle and label are, and what happens when you ask to move up or down off either
	end of it. One binding of this is a blimp's engine telegraph; another is a boat's sail settings.

	LIFTED OUT OF Shared/Blimp/BlimpSpeedLadder.lua when the Boat layer arrived, and the interesting
	part of the lift is what did NOT change: every rule below (saturate rather than wrap, find the
	neutral rather than write it down, nil rather than 0 for a malformed delta) was argued for a
	telegraph and is exactly as correct for a sail rig. The only thing that was ever blimp-specific was
	which table it read.

	TOUCHES NO INSTANCE AND HOLDS NO MUTABLE STATE. The current rung of a particular hull is a number
	living on that hull's record in its own System; this module only ever tells that number what it is
	allowed to become. That is what makes "does All Stop actually stop it", "does shifting up from the
	top rung stay on the top rung" and "is the neutral rung the one with zero throttle" answerable in
	the TestEZ suite without a place file.

	IT LIVES IN Shared/, NOT Server/, BECAUSE BOTH SIDES ASK IT DIFFERENT QUESTIONS. The server asks
	"what throttle does rung 6 feed the integrator" and "where does +1 from here land"; the client's
	gauge asks "how many rungs are there, which are astern, and what is each one called" so it can draw
	the ladder at all. Those are the same three facts, and the alternative -- the gauge deriving them
	from the same constants table by hand -- is how a gauge ends up drawing a rung the server does not
	believe in.

	THE NEUTRAL RUNG IS FOUND, NEVER WRITTEN DOWN. New() scans for the rung whose throttle is exactly
	zero rather than taking a StopIndex, because a StopIndex is a second place the ladder's shape is
	recorded and the two silently disagree the first time somebody inserts a rung. The scan runs once,
	at binding time, not per call.

	Does not own: the rungs themselves or their tuning (each vehicle's own Constants file), which rung a
	given hull is on (that vehicle's System), how a throttle becomes motion (that vehicle's Drive), or
	how the ladder is drawn (Client/UI/Components/SpeedLadder.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VesselTypes = require(ReplicatedStorage.Shared.Vessel.VesselTypes)

local VesselSpeedLadder = {}

export type Rung = VesselTypes.Rung

export type Ladder = {
	Count: () -> number,
	NeutralIndex: () -> number,
	Clamp: (index: number) -> number,
	At: (index: number) -> Rung,
	ThrottleAt: (index: number) -> number,
	Shift: (index: number, delta: number) -> number,
	SanitizeDelta: (raw: unknown) -> number?,
}

-- Turns whatever came off a shift remote into a rung delta, or nil if it was not one. Returns nil
-- rather than 0 for a malformed payload for the same reason a Drive's own SanitizeIntent does: 0 is a
-- MEANINGFUL value here (the panic key -- see Shift below), so it cannot double as the failure signal.
--
-- Clamps the magnitude to one rung. A client that asks to jump four rungs at once is either lagging
-- and batching, or lying; either way the honest answer is the one keypress it definitely earned, and a
-- pilot who genuinely wants four rungs presses the key four times.
--
-- MODULE-LEVEL RATHER THAN PER-LADDER, because it is the only function here whose answer does not
-- depend on the rungs at all -- it is validation of an untrusted number, not a question about a ladder.
-- Every bound ladder re-exposes it anyway (see New) so a call site that already holds one is not made
-- to reach for two modules.
function VesselSpeedLadder.SanitizeDelta(raw: unknown): number?
	if typeof(raw) ~= "number" then
		return nil
	end
	local delta = raw :: number
	if delta ~= delta or delta == math.huge or delta == -math.huge then
		return nil
	end
	if delta == 0 then
		return 0
	end
	return if delta > 0 then 1 else -1
end

-- Binds one authored table of rungs. See this file's header on why the neutral is scanned for here
-- rather than passed in.
--
-- Falls back to rung 1 rather than erroring if a ladder somehow has no zero rung: a hull whose
-- "neutral" is full astern is a visible, fixable bug, and a module that throws at require time takes
-- that whole vehicle's require graph down with it.
function VesselSpeedLadder.New(rungs: { Rung }): Ladder
	local neutralIndex = 1
	for index, rung in rungs do
		if rung.Throttle == 0 then
			neutralIndex = index
			break
		end
	end

	local ladder = {}

	function ladder.Count(): number
		return #rungs
	end

	-- The rung a hull sits on before anybody has touched the control, and the rung every release path
	-- resets it to.
	function ladder.NeutralIndex(): number
		return neutralIndex
	end

	-- Bounds an arbitrary number into a real rung index. Every other function here funnels through
	-- this, so there is exactly one place that decides what an out-of-range rung means.
	function ladder.Clamp(index: number): number
		if index ~= index then
			-- NaN fails its own equality test, and math.clamp propagates it rather than rejecting it --
			-- a NaN rung would index the array with nil and take the whole tick down. Reachable only
			-- from arithmetic on a malformed delta, which is exactly the input this system takes off a
			-- remote.
			return neutralIndex
		end
		return math.clamp(math.floor(index), 1, #rungs)
	end

	function ladder.At(index: number): Rung
		return rungs[ladder.Clamp(index)]
	end

	-- The throttle axis to hand the integrator for this rung. The one function a server tick actually
	-- calls every frame.
	function ladder.ThrottleAt(index: number): number
		return ladder.At(index).Throttle
	end

	-- Moves `index` by `delta` rungs, SATURATING at each end rather than wrapping. Wrapping is the
	-- obvious alternative and it is genuinely dangerous here: a pilot tapping up past the top rung
	-- would land on full astern, which on a loaded hull is not a UI annoyance.
	--
	-- A delta of 0 is the neutral rung, not a no-op -- that is the panic key, and folding it in here
	-- rather than giving it its own remote keeps "every way the control moves" in one function.
	function ladder.Shift(index: number, delta: number): number
		if delta == 0 then
			return neutralIndex
		end
		return ladder.Clamp(ladder.Clamp(index) + delta)
	end

	ladder.SanitizeDelta = VesselSpeedLadder.SanitizeDelta

	return ladder
end

return VesselSpeedLadder
