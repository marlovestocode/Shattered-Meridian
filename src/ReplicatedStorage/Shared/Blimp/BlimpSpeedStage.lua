--!strict
--[[
	BlimpSpeedStage.lua

	Owns: which of the three flight stages -- Slow, Cruise, Running -- a hull is currently in, and the
	hysteresis that decides when it has genuinely changed rather than merely wobbled.

	THE HYSTERESIS IS THE WHOLE MODULE, and without it the feature it serves is a bug. A blimp holding
	a steady rung does not hold a steady speed: the constraint solver, a passenger's mass joining the
	assembly and ordinary replication jitter move it by a fraction of a percent every frame. A bare
	`fraction >= threshold` comparison against that would flip back and forth across a boundary several
	times a second -- and since crossing a stage plays a sound (see BlimpConstants.Audio.Stages), that
	is not a subtle glitch, it is a machine-gun of pings. So a stage is entered a little ABOVE its own
	floor and left a little BELOW it, and the gap between those two is the dead band.

	Which is also why this takes the CURRENT stage as an argument rather than deriving one from the
	speed alone. "Which stage is 0.38 in" has no answer on its own; "which stage is 0.38 in, given we
	were in Cruise" does. A pure function of the speed could not have hysteresis at all.

	TOUCHES NO INSTANCE AND HOLDS NO STATE, the same contract Shared/Blimp/BlimpSpeedLadder.lua sets
	out next door and for the same payoff: "does a hull sitting exactly on a boundary stay put" and
	"does a hull that jumps from a standstill to flank land on the right stage rather than stepping
	through them" are answerable in the TestEZ suite. The current stage is a number living in
	Client/FX/BlimpAudio.lua; this module only tells that number what it may become.

	IT IS SEPARATE FROM THE TELEGRAPH ON PURPOSE, even though both are "how fast is this ship". The
	telegraph is what the pilot ASKED for -- eight rungs, deliberately finer than anyone can feel, so
	the ladder is worth walking. A stage is what the ship is actually DOING -- three bands, deliberately
	coarser than the rungs, so that crossing one is an event. A value that varies smoothly is one a
	player stops hearing; the coarseness is what puts edges back in.

	Does not own: the stage definitions or the dead band (BlimpConstants.Audio.Stages/StageHysteresis),
	the sounds (Client/FX/BlimpAudio.lua), or measuring the hull (Client/Camera/BlimpCamera.lua).
]]

local BlimpConstants = require(script.Parent.BlimpConstants)

local BlimpSpeedStage = {}

export type Stage = {
	Id: string,
	Label: string,
	EnterFraction: number,
	PlaybackSpeed: number,
	LoopVolumeScale: number,
	LoopSpeedScale: number,
}

local stages: { Stage } = BlimpConstants.Audio.Stages :: { Stage }
-- Half the dead band, because it is applied symmetrically either side of each threshold -- the entry
-- edge sits this far above the floor and the exit edge this far below it.
local halfBand = BlimpConstants.Audio.StageHysteresis / 2

function BlimpSpeedStage.Count(): number
	return #stages
end

function BlimpSpeedStage.At(index: number): Stage
	return stages[math.clamp(math.floor(index), 1, #stages)]
end

-- The stage a hull at `speedFraction` should be in, given it is currently in `currentIndex`.
--
-- Two loops rather than one comparison, so a hull that jumps several bands at once (boarding a ship
-- already at flank, or a landing hull dropping to a standstill) lands on the RIGHT stage in one call
-- instead of stepping through the intervening ones a frame at a time -- which would play every stage
-- sound on the way past.
--
-- Only one of the two can ever run: climbing requires being below the next floor and falling requires
-- being below this one, and the dead band guarantees those cannot both be true of a settled index.
function BlimpSpeedStage.Resolve(currentIndex: number, speedFraction: number): number
	local index = math.clamp(math.floor(currentIndex), 1, #stages)
	-- NaN fails its own equality test and would fall through both loops silently, latching whatever
	-- stage was current forever. Reachable from a divide by a zero cruise speed.
	if speedFraction ~= speedFraction then
		return index
	end

	while index < #stages and speedFraction >= stages[index + 1].EnterFraction + halfBand do
		index += 1
	end
	while index > 1 and speedFraction < stages[index].EnterFraction - halfBand do
		index -= 1
	end
	return index
end

return BlimpSpeedStage
