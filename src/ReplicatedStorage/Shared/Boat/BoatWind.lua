--!strict
--[[
	BoatWind.lua

	Owns: the wind -- what it is doing at a given instant, how a hull's heading relates to it, how much
	drive that heading earns, how much sideways press it puts on the sails, and what to call it on a
	panel. This is the file that makes sailing a skill rather than a throttle.

	TOUCHES NO INSTANCE AND HOLDS NO STATE. Every function here is a pure function of a number, which is
	what makes "is a hull pointed at the wind really making zero way", "does the polar actually peak on a
	reach", and "does the heel flip sides as she gybes rather than snapping" answerable in the TestEZ
	suite without a place file.

	THE WIND IS A FUNCTION OF THE CLOCK, NOT A REPLICATED VALUE, and that is the load-bearing decision
	in this layer. Sample(now) is deterministic, so Server/Boat/BoatDrive.lua sails by it and every
	client's wind vane computes the same answer independently from Workspace:GetServerTimeNow(). No
	remote, no drift, no stale reading on a laggy client -- and no continuous quantity on the wire
	forever to say something both ends can already work out. See BoatConstants.Network.RemoteNames.
	HelmUpdated on why that omission is deliberate rather than an oversight.

	ONE CONVENTION, AND EVERY ANGLE IN THE LAYER IS MEASURED AGAINST IT: a BEARING names where the wind
	blows FROM, the way a sailor's does. A "northerly" is wind out of the north. Getting this backwards
	is by far the most likely bug in this file -- it produces a boat that sails beautifully straight at
	the thing it should be unable to approach -- so nothing here is ever called a "direction", and
	SourceLook below is named for the fact that it points AT the source.

	SIGN, TOO, IS LOAD-BEARING. RelativeAngle is SIGNED, and a positive value means the wind is on the
	PORT bow (see that function). Efficiency only ever reads the magnitude; the sign exists for exactly
	one consumer -- LateralFactor, which is what makes a boat heel away from the wind rather than into
	it, and which is the silhouette everybody recognises a sailing boat by.

	Does not own: the numbers (BoatConstants.Wind), the integration (Server/Boat/BoatDrive.lua), the
	swell (Shared/Boat/BoatWaterMath.lua), or anything about which boat is where.
]]

local BoatConstants = require(script.Parent.BoatConstants)
local BoatTypes = require(script.Parent.BoatTypes)

local BoatWind = {}

local TAU = math.pi * 2

-- Below this a direction vector has no heading to read off it -- it is pointing straight up or down,
-- or it is the zero vector. Reachable only from a caller handing in a degenerate CFrame.
local EPSILON = 1e-6

-- Wraps an angle into -pi..pi. The whole reason RelativeAngle can be compared and signed at all: a
-- naive subtraction of two yaws can land anywhere in -2pi..2pi, and a hull one degree to starboard of
-- the wind would otherwise read as 359 degrees to port.
local function wrapToPi(angle: number): number
	local wrapped = (angle + math.pi) % TAU
	if wrapped < 0 then
		wrapped += TAU
	end
	return wrapped - math.pi
end

-- Two sine terms at incommensurate periods, normalised back into -1..1. The secondary term is what
-- stops the result being a shape a player can memorise off one period of the primary -- see
-- BoatConstants.Wind's own header on why the wind wanders rather than jumping.
local function wander(now: number, primaryPeriod: number, secondaryPeriod: number, secondaryWeight: number): number
	local primary = math.sin(TAU * now / primaryPeriod)
	local secondary = math.sin(TAU * now / secondaryPeriod)
	return (primary + secondary * secondaryWeight) / (1 + secondaryWeight)
end

-- The unit vector pointing FROM anywhere TOWARD the wind's source, for a given bearing. Expressed as a
-- LookVector so it composes with everything else in this codebase: `SourceLook(b)` is exactly the
-- direction a CFrame yawed by `b` is facing.
--
-- Read by the client's wind vane and by nothing on the server -- the drive works in angles throughout,
-- because an angle is what a polar curve takes. Kept here rather than in the vane so the one place the
-- bearing convention is turned into geometry is the same file that documents the convention.
function BoatWind.SourceLook(bearingRadians: number): Vector3
	return CFrame.Angles(0, bearingRadians, 0).LookVector
end

-- The yaw whose LookVector is `direction`, flattened to the horizontal. The inverse of SourceLook, and
-- how a hull's bow becomes a number this file can compare against a bearing.
--
-- Flattened because a heading is a compass direction: a hull pitched by a swell must not read as
-- pointing somewhere else. Returns 0 for a degenerate input rather than erroring -- a boat that briefly
-- believes it is pointing at world -Z recovers on the next frame; one that errors every tick does not.
function BoatWind.BearingOfLook(direction: Vector3): number
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < EPSILON then
		return 0
	end
	return math.atan2(-flat.X, -flat.Z)
end

-- The world's wind at `now`. `now` is expected to be Workspace:GetServerTimeNow() on both machines --
-- see this file's header. Any monotonic clock produces a valid wind; only a SHARED one produces the
-- same wind on the server and on a client, which is the whole point.
function BoatWind.Sample(now: number): BoatTypes.WindSample
	local cfg = BoatConstants.Wind

	local swing = wander(now, cfg.SwingPeriodSeconds, cfg.SwingSecondaryPeriodSeconds, cfg.SwingSecondaryWeight)

	-- 0..1 rather than -1..1: strength has a floor, not a sign. See BoatConstants.Wind.MinStrength on
	-- why that floor is not zero.
	local gust = 0.5 + 0.5 * wander(now, cfg.GustPeriodSeconds, cfg.GustSecondaryPeriodSeconds, cfg.GustSecondaryWeight)

	return {
		BearingRadians = wrapToPi(cfg.BaseBearingRadians + swing * cfg.SwingRadians),
		Strength = cfg.MinStrength + (cfg.MaxStrength - cfg.MinStrength) * gust,
	}
end

-- The signed angle from a hull's BOW to the wind's SOURCE, in -pi..pi. 0 is the wind dead ahead (in
-- irons); pi (or -pi) is the wind dead astern (running).
--
-- POSITIVE MEANS THE WIND IS ON THE PORT BOW. Worth deriving rather than trusting, because every heel
-- sign in the layer hangs off it: a CFrame yawed by +θ has a LookVector rotating from world -Z toward
-- world -X, and a hull facing -Z has its RightVector (starboard) at +X. So rotating the bow by a
-- POSITIVE angle swings it to PORT, and a wind source at a positive offset from the bow is a wind to
-- port.
function BoatWind.RelativeAngle(bowBearingRadians: number, windBearingRadians: number): number
	return wrapToPi(windBearingRadians - bowBearingRadians)
end

-- THE POLAR: what fraction of her hull speed a boat makes at this angle off the wind, 0..1. Three
-- pieces, and each one is a claim about sailing rather than about curve-fitting:
--
--   1. INSIDE THE NO-GO ARC, EXACTLY ZERO. Not a steep falloff -- zero. "In irons" has to be a state a
--      player can name and recognise and get themselves out of, and a boat that creeps forward at 4%
--      while pointed at the wind teaches nobody anything and quietly deletes the reason to tack.
--   2. FROM THERE TO THE PEAK, A SMOOTHSTEP. Smooth at BOTH ends on purpose: a linear ramp would put a
--      corner at the no-go edge, so a boat easing out of irons would jump from nothing to a third of
--      hull speed in one degree, which reads as the wind switching on rather than as the sails filling.
--   3. PAST THE PEAK, A COSINE EASE DOWN TO RunningEfficiency. Also smooth at both ends, so a gybe --
--      swinging the stern through the wind, which passes straight through pi -- has no step in it.
--
-- Takes the SIGNED angle and immediately discards the sign, rather than demanding the caller take an
-- absolute value first: which side the wind is on has nothing to do with how fast you go, and a caller
-- who has to remember to abs() is a caller who will one day forget.
function BoatWind.Efficiency(relativeAngle: number): number
	local cfg = BoatConstants.Wind
	local angle = math.abs(wrapToPi(relativeAngle))

	if angle <= cfg.NoGoRadians then
		return 0
	end

	if angle <= cfg.PeakRadians then
		local span = cfg.PeakRadians - cfg.NoGoRadians
		local t = if span > EPSILON then (angle - cfg.NoGoRadians) / span else 1
		return t * t * (3 - 2 * t)
	end

	local span = math.pi - cfg.PeakRadians
	local u = if span > EPSILON then (angle - cfg.PeakRadians) / span else 1
	local eased = 0.5 - 0.5 * math.cos(math.pi * math.clamp(u, 0, 1))
	return 1 + (cfg.RunningEfficiency - 1) * eased
end

-- The SIGNED lateral component of the sails' press, -1..1 -- what makes a boat lean away from the wind.
-- Positive means the push is toward starboard.
--
-- sin(), NOT sign(), AND THAT IS THE WHOLE FUNCTION. The obvious implementation is "which side is the
-- wind on, times how hard it is blowing", i.e. a sign() -- and it is wrong in a way that only shows up
-- once, spectacularly: sign() is discontinuous at pi, so a boat gybing (passing the wind across her
-- stern) would snap her heel from one side to the other in a single frame. sin() is zero at BOTH ends
-- of the range and peaks on the beam, which is smooth through a gybe AND is where the lateral force
-- actually is -- a hull running dead downwind is being pushed the way she is already going, and does
-- not heel from it at all.
--
-- Positive relativeAngle means the wind is on the PORT bow (see RelativeAngle), so the push is to
-- starboard and sin() of a positive angle is positive: the two conventions agree without a negation,
-- which is worth knowing before adding one.
function BoatWind.LateralFactor(relativeAngle: number): number
	return math.sin(wrapToPi(relativeAngle))
end

-- How hard the sails are pressing, 0..1: canvas set, times the wind's strength, times how well this
-- heading uses it.
--
-- EFFICIENCY IS IN HERE, which is a real choice and not just reuse. It means a hull sitting in irons
-- with full sail set does not heel -- and that is right: her sails are luffing, flogging back and
-- forth with no shape and no force in them. A player who has stalled head-to-wind should SEE a boat
-- that has gone limp, not one still laid over as if she were driving.
function BoatWind.Pressure(sailFraction: number, windStrength: number, relativeAngle: number): number
	return math.abs(sailFraction) * windStrength * BoatWind.Efficiency(relativeAngle)
end

-- What to CALL this heading on a helm panel. Names only -- nothing in the drive reads this, and the
-- band edges it uses are deliberately separate constants from the polar's own (see
-- BoatConstants.Wind.CloseHauledMaxRadians).
function BoatWind.PointOfSail(relativeAngle: number): BoatTypes.PointOfSail
	local cfg = BoatConstants.Wind
	local angle = math.abs(wrapToPi(relativeAngle))

	if angle <= cfg.NoGoRadians then
		return "InIrons"
	end
	if angle <= cfg.CloseHauledMaxRadians then
		return "CloseHauled"
	end
	if angle <= cfg.BeamReachMaxRadians then
		return "BeamReach"
	end
	if angle <= cfg.BroadReachMaxRadians then
		return "BroadReach"
	end
	return "Running"
end

return BoatWind
