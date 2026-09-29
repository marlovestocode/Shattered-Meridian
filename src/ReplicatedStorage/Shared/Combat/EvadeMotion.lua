--!strict
--[[
	EvadeMotion.lua

	Owns: the evade's motion as pure math -- its speed at a moment in the glide, how far it has gone, and
	which of the four directional clips a glide reads as. One definition, used by the player's state
	(Client/Parkour/States/Evading.lua) AND the training bot's server-side drive (TrainingBotSystem), so the
	two are provably the same move. They used to be two copies of the same two numbers, and the copies are
	how the player's dodge and the bot's drifted into looking like different moves.

	Pure: no services, no Instances, no clock. Time is always "seconds since the glide started".

	Does not own: the numbers (EvadeConstants), or driving any body (the callers).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EvadeConstants = require(ReplicatedStorage.Shared.Combat.EvadeConstants)

local EvadeMotion = {}

-- Speed (studs/s) `elapsed` seconds into a glide: PeakSpeed * (1 - (t/T)^2), zero outside [0, T). A
-- quadratic ease-in to rest, so the body leaves at full speed and arrives with none -- no one-frame stop
-- at the end, which is what a flat speed with a hard cut reads as.
function EvadeMotion.SpeedAt(elapsed: number): number
	local duration = EvadeConstants.DurationSeconds
	if elapsed < 0 or elapsed >= duration or duration <= 0 then
		return 0
	end
	local fraction = elapsed / duration
	return EvadeConstants.PeakSpeed * (1 - fraction * fraction)
end

-- Distance (studs) covered `elapsed` seconds into a glide -- the integral of SpeedAt, clamped to the
-- glide's length. PeakSpeed * (t - t^3 / (3 T^2)).
function EvadeMotion.DistanceAt(elapsed: number): number
	local duration = EvadeConstants.DurationSeconds
	if elapsed <= 0 or duration <= 0 then
		return 0
	end
	local t = math.min(elapsed, duration)
	return EvadeConstants.PeakSpeed * (t - (t * t * t) / (3 * duration * duration))
end

-- The whole glide's distance.
function EvadeMotion.TotalDistance(): number
	return EvadeMotion.DistanceAt(EvadeConstants.DurationSeconds)
end

local function flatUnit(vector: Vector3, fallback: Vector3): Vector3
	local flat = Vector3.new(vector.X, 0, vector.Z)
	if flat.Magnitude < 1e-3 then
		return fallback
	end
	return flat.Unit
end

-- Which of the four directional clips a glide along `travel` reads as, for a body looking along
-- `facing`. The dominant axis wins; an exact diagonal resolves to Forward/Back, the more readable clip of
-- the two for a move that is mostly about getting out of the way.
function EvadeMotion.DirectionalVariant(travel: Vector3, facing: Vector3): string
	local forward = flatUnit(facing, Vector3.new(0, 0, -1))
	-- Right of a look vector (x, 0, z) is (-z, 0, x): for the default -Z facing, +X.
	local right = Vector3.new(-forward.Z, 0, forward.X)
	local flatTravel = flatUnit(travel, forward)
	local along = flatTravel:Dot(forward)
	local across = flatTravel:Dot(right)
	if math.abs(along) >= math.abs(across) then
		return if along >= 0 then "Forward" else "Back"
	end
	return if across > 0 then "Right" else "Left"
end

return EvadeMotion
