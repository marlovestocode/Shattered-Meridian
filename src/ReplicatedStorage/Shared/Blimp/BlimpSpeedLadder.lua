--!strict
--[[
	BlimpSpeedLadder.lua

	Owns: reading BlimpConstants.SpeedStates as a LADDER rather than as an array -- where the neutral
	rung is, what a rung's throttle and label are, and what happens when you ask to move up or down off
	either end of it.

	TOUCHES NO INSTANCE AND HOLDS NO STATE, the same contract Server/Blimp/BlimpDrive.lua's own header
	sets out and for the same payoff: "does All Stop actually stop it", "does shifting up from the top
	rung stay on the top rung" and "is the neutral rung the one with zero throttle" are answerable in
	the TestEZ suite without a place file. The current rung of a particular blimp is a number living on
	that blimp's record in Server/Systems/BlimpSystem.lua; this module only ever tells that number what
	it is allowed to become.

	IT LIVES IN Shared/, NOT Server/, BECAUSE BOTH SIDES ASK IT DIFFERENT QUESTIONS. The server asks
	"what throttle does rung 6 feed the integrator" and "where does +1 from here land"; the client's
	helm gauge asks "how many rungs are there, which are astern, and what is each one called" so it can
	draw the ladder at all. Those are the same three facts, and the alternative -- the gauge deriving
	them from the same constants table by hand -- is how a gauge ends up drawing a rung the server does
	not believe in.

	THE NEUTRAL RUNG IS FOUND, NEVER WRITTEN DOWN. NeutralIndex scans for the rung whose throttle is
	exactly zero rather than reading a StopIndex constant, because a StopIndex constant is a second
	place the ladder's shape is recorded and the two silently disagree the first time somebody inserts
	a rung. The scan runs once, at require time, not per call.

	Does not own: the rungs themselves or their tuning (Shared/Blimp/BlimpConstants.SpeedStates), which
	rung a given hull is on (Server/Systems/BlimpSystem.lua), how a throttle becomes motion
	(Server/Blimp/BlimpDrive.lua), or how the ladder is drawn (Client/UI/Components/SpeedLadder.lua).
]]

local BlimpConstants = require(script.Parent.BlimpConstants)

local BlimpSpeedLadder = {}

export type Rung = {
	Id: string,
	Label: string,
	Throttle: number,
}

local rungs: { Rung } = BlimpConstants.SpeedStates :: { Rung }

-- Resolved once at require time -- see this file's header on why this is a scan rather than a
-- constant. Falls back to rung 1 rather than erroring if a future ladder somehow has no zero rung:
-- a blimp whose "neutral" is full astern is a visible, fixable bug, and a module that throws at
-- require time takes the entire Blimp system's require graph down with it.
local neutralIndex = 1
for index, rung in rungs do
	if rung.Throttle == 0 then
		neutralIndex = index
		break
	end
end

function BlimpSpeedLadder.Count(): number
	return #rungs
end

-- The rung a hull sits on before anybody has touched the telegraph, and the rung every release path
-- resets it to.
function BlimpSpeedLadder.NeutralIndex(): number
	return neutralIndex
end

-- Bounds an arbitrary number into a real rung index. Every other function here funnels through this,
-- so there is exactly one place that decides what an out-of-range rung means.
function BlimpSpeedLadder.Clamp(index: number): number
	if index ~= index then
		-- NaN fails its own equality test, and math.clamp propagates it rather than rejecting it --
		-- a NaN rung would index the array with nil and take the whole tick down. Reachable only from
		-- arithmetic on a malformed delta, which is exactly the input this system takes off a remote.
		return neutralIndex
	end
	return math.clamp(math.floor(index), 1, #rungs)
end

function BlimpSpeedLadder.At(index: number): Rung
	return rungs[BlimpSpeedLadder.Clamp(index)]
end

-- The throttle axis to hand BlimpDrive.Step for this rung. The one function the server flight loop
-- actually calls every tick.
function BlimpSpeedLadder.ThrottleAt(index: number): number
	return BlimpSpeedLadder.At(index).Throttle
end

-- Moves `index` by `delta` rungs, SATURATING at each end rather than wrapping. Wrapping is the obvious
-- alternative and it is genuinely dangerous here: a pilot tapping up past Flank would land on Full
-- Astern, which on a loaded hull over a mountain is not a UI annoyance.
--
-- A delta of 0 is All Stop, not a no-op -- that is the panic key (see BlimpConstants.Network.
-- RemoteNames.ShiftSpeedState), and folding it in here rather than giving it its own remote keeps
-- "every way the telegraph moves" in one function.
function BlimpSpeedLadder.Shift(index: number, delta: number): number
	if delta == 0 then
		return neutralIndex
	end
	return BlimpSpeedLadder.Clamp(BlimpSpeedLadder.Clamp(index) + delta)
end

-- Turns whatever came off the ShiftSpeedState remote into a rung delta, or nil if it was not one.
-- Returns nil rather than 0 for a malformed payload for the same reason BlimpDrive.SanitizeIntent
-- does: 0 is a MEANINGFUL value here (All Stop), so it cannot double as the failure signal.
--
-- Clamps the magnitude to one rung. A client that asks to jump four rungs at once is either lagging
-- and batching, or lying; either way the honest answer is the one keypress it definitely earned, and
-- a pilot who genuinely wants four rungs presses the key four times.
function BlimpSpeedLadder.SanitizeDelta(raw: unknown): number?
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

return BlimpSpeedLadder
