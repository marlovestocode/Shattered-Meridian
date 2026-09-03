--!strict
--[[
	VesselSpeedStage.lua

	Owns: which band of a coarse speed ladder -- Slow, Cruise, Running -- a hull is currently in, and
	the hysteresis that decides when it has genuinely changed rather than merely wobbled.

	LIFTED OUT OF Shared/Blimp/BlimpSpeedStage.lua when the Boat layer arrived. Nothing below is
	airship-specific and nothing below changed; only the stage table and the dead band are parameters
	now instead of module-scope reads.

	THE HYSTERESIS IS THE WHOLE MODULE, and without it the feature it serves is a bug. A hull holding a
	steady rung does not hold a steady speed: the constraint solver, a passenger's mass joining the
	assembly and ordinary replication jitter move it by a fraction of a percent every frame. A bare
	`fraction >= threshold` comparison against that would flip back and forth across a boundary several
	times a second -- and since crossing a stage plays a sound, that is not a subtle glitch, it is a
	machine-gun of pings. So a stage is entered a little ABOVE its own floor and left a little BELOW it,
	and the gap between those two is the dead band.

	Which is also why Resolve takes the CURRENT stage as an argument rather than deriving one from the
	speed alone. "Which stage is 0.38 in" has no answer on its own; "which stage is 0.38 in, given we
	were in Cruise" does. A pure function of the speed could not have hysteresis at all.

	TOUCHES NO INSTANCE AND HOLDS NO MUTABLE STATE, the same contract Shared/Vessel/VesselSpeedLadder.lua
	sets out next door and for the same payoff: "does a hull sitting exactly on a boundary stay put" and
	"does a hull that jumps from a standstill to flank land on the right stage rather than stepping
	through them" are answerable in the TestEZ suite. The current stage is a number living in that
	vehicle's audio module; this module only tells that number what it may become.

	IT IS SEPARATE FROM THE TELEGRAPH ON PURPOSE, even though both are "how fast is this hull". The
	telegraph is what the pilot ASKED for -- many rungs, deliberately finer than anyone can feel, so the
	ladder is worth walking. A stage is what the hull is actually DOING -- three bands, deliberately
	coarser than the rungs, so that crossing one is an event. A value that varies smoothly is one a
	player stops hearing; the coarseness is what puts edges back in.

	Does not own: the stage definitions or the dead band (each vehicle's own Constants.Audio), the sounds
	(that vehicle's FX module), or measuring the hull (that vehicle's camera module).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VesselTypes = require(ReplicatedStorage.Shared.Vessel.VesselTypes)

local VesselSpeedStage = {}

export type Stage = VesselTypes.Stage

export type StageLadder = {
	Count: () -> number,
	At: (index: number) -> Stage,
	Resolve: (currentIndex: number, speedFraction: number) -> number,
}

-- Binds one authored table of stages and the dead band they are separated by.
function VesselSpeedStage.New(stages: { Stage }, hysteresis: number): StageLadder
	-- Half the dead band, because it is applied symmetrically either side of each threshold -- the
	-- entry edge sits this far above the floor and the exit edge this far below it.
	local halfBand = hysteresis / 2

	local ladder = {}

	function ladder.Count(): number
		return #stages
	end

	function ladder.At(index: number): Stage
		return stages[math.clamp(math.floor(index), 1, #stages)]
	end

	-- The stage a hull at `speedFraction` should be in, given it is currently in `currentIndex`.
	--
	-- Two loops rather than one comparison, so a hull that jumps several bands at once (boarding a ship
	-- already at flank, or a landing hull dropping to a standstill) lands on the RIGHT stage in one
	-- call instead of stepping through the intervening ones a frame at a time -- which would play every
	-- stage sound on the way past.
	--
	-- Only one of the two can ever run: climbing requires being below the next floor and falling
	-- requires being below this one, and the dead band guarantees those cannot both be true of a
	-- settled index.
	function ladder.Resolve(currentIndex: number, speedFraction: number): number
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

	return ladder
end

return VesselSpeedStage
