--!strict
--[[
	BoatWaterMath.lua

	Owns: the water, as arithmetic -- whether there is any under a given point and how high it is, what
	the swell is doing there, and how much a hull sitting on that swell should pitch and roll.

	TOUCHES NO INSTANCE, which is the reason this file exists separately from Server/Boat/BoatWater.lua
	next door. That module walks CollectionService and turns tagged parts into BoatTypes.WaterPlane
	records; this one takes a list of those records and answers questions about it. The split is what
	makes "does a hull over the edge of a lake read as beached", "do two overlapping planes resolve to
	the higher one" and "does the swell's slope actually match its own height function" answerable in the
	TestEZ suite -- none of which could be asked at all if containment lived inside a tag walk.

	THE SWELL IS A FUNCTION OF POSITION AND THE CLOCK, exactly as the wind is (Shared/Boat/BoatWind.lua)
	and for the same payoff: the server lifts a hull by it, every client's camera reads the result off
	that hull's own replicated motion, and there is nothing to send. `now` is expected to be
	Workspace:GetServerTimeNow() on both machines.

	TWO CROSSED WAVE TRAINS, NOT ONE. A single sine is instantly readable AS a sine -- the hull pitches
	on a perfect metronome and the sea reads as corrugated iron. Two at different wavelengths, periods
	and headings beat against one another into something that never quite repeats, for the cost of one
	extra sin() and one extra cos() per sample.

	THE SLOPES ARE ANALYTIC, NOT SAMPLED. The obvious way to find which way the water is tilted under a
	hull is to evaluate the height at three nearby points and take differences -- and it costs three
	full evaluations, picks up a step-size parameter nobody can tune from first principles, and is
	wrong at exactly the scale that matters (a step shorter than the hull under-reports a long swell; a
	step longer over-smooths a short one). The height function here is a sum of sines, so its derivative
	is a sum of cosines and comes out of the same evaluation for one extra trig call apiece. Exact, no
	parameter, cheaper.

	Does not own: which parts are water (BoatConstants.Tags.Water and Server/Boat/BoatWater.lua), the
	numbers (BoatConstants.Swell), or what a hull does with the answer (Server/Boat/BoatDrive.lua).
]]

local BoatConstants = require(script.Parent.BoatConstants)
local BoatTypes = require(script.Parent.BoatTypes)

local BoatWaterMath = {}

local TAU = math.pi * 2

-- The highest tagged plane containing `position` horizontally, or nil if there is none -- which is the
-- Beached condition and the only thing that produces it.
--
-- HORIZONTAL CONTAINMENT ONLY, NEVER A HEIGHT TEST. A hull that has been shoved under the surface by a
-- collision, or one whose root sits a little high on a big swell, is still on the water; testing its Y
-- against the plane's would beach it for the duration and then un-beach it, which reads as the boat
-- randomly refusing to sail.
--
-- HIGHEST WINS, so a raised canal or a lock laid over a sea slab does the obvious thing. The cost of
-- that rule is the one case it gets wrong -- a navigable tunnel with water above it -- which is worth
-- knowing about and is not worth a knob: build the tunnel's own water and leave the slab above it
-- ending at the tunnel mouth.
--
-- Tested against EVERY plane rather than against a spatial index, deliberately. The test is one CFrame
-- multiply and two comparisons; a map with a hundred tagged river sections costs a boat a hundred of
-- those per tick, which is beneath measurement, and an index would be a structure to keep in step with
-- a builder's live tag edits for no gain anybody could feel.
function BoatWaterMath.SurfaceUnder(planes: { BoatTypes.WaterPlane }, position: Vector3): number?
	local best: number? = nil
	for _, plane in planes do
		local localPoint = plane.Inverse * position
		if math.abs(localPoint.X) > plane.HalfX or math.abs(localPoint.Z) > plane.HalfZ then
			continue
		end
		if best == nil or plane.TopY > best then
			best = plane.TopY
		end
	end
	return best
end

-- The swell's height at a world XZ, plus its two partial derivatives (studs of rise per stud of travel)
-- along world X and Z. Three returns rather than a table, because this runs per boat per tick and the
-- table would be pure garbage.
--
-- Each train contributes A * sin(k * (p . d) - omega * t), whose derivative along world axis `a` is
-- A * k * d.a * cos(of the same phase) -- the same phase, so the cos() is the only extra work.
function BoatWaterMath.Swell(x: number, z: number, now: number): (number, number, number)
	local cfg = BoatConstants.Swell

	local primaryLook = CFrame.Angles(0, cfg.HeadingRadians, 0).LookVector
	local primaryK = TAU / cfg.WavelengthStuds
	local primaryPhase = primaryK * (x * primaryLook.X + z * primaryLook.Z) - TAU * now / cfg.PeriodSeconds
	local primarySin = math.sin(primaryPhase)
	local primaryCos = math.cos(primaryPhase)

	local crossLook = CFrame.Angles(0, cfg.CrossHeadingRadians, 0).LookVector
	local crossK = TAU / cfg.CrossWavelengthStuds
	local crossPhase = crossK * (x * crossLook.X + z * crossLook.Z) - TAU * now / cfg.CrossPeriodSeconds
	local crossSin = math.sin(crossPhase)
	local crossCos = math.cos(crossPhase)

	local height = cfg.Amplitude * primarySin + cfg.CrossAmplitude * crossSin
	local slopeX = cfg.Amplitude * primaryK * primaryLook.X * primaryCos
		+ cfg.CrossAmplitude * crossK * crossLook.X * crossCos
	local slopeZ = cfg.Amplitude * primaryK * primaryLook.Z * primaryCos
		+ cfg.CrossAmplitude * crossK * crossLook.Z * crossCos

	return height, slopeX, slopeZ
end

-- Everything the drive needs to know about the water under one hull this tick: is there any, and what Y
-- should the waterline sit at once the swell is added in.
--
-- SurfaceY IS MEANINGLESS WHEN Supported IS FALSE and is returned as 0 rather than as a plausible
-- number, on purpose -- a caller that forgets to check the flag should get an obviously wrong answer at
-- the origin, not a subtly wrong one that puts the hull at sea level over a mountain.
function BoatWaterMath.Sample(planes: { BoatTypes.WaterPlane }, position: Vector3, now: number): BoatTypes.WaterSample
	local surface = BoatWaterMath.SurfaceUnder(planes, position)
	if surface == nil then
		return { SurfaceY = 0, Supported = false }
	end

	local height = BoatWaterMath.Swell(position.X, position.Z, now)
	return { SurfaceY = surface + height, Supported = true }
end

-- How far a hull lying on that surface should pitch and roll, in radians, given the world slopes under
-- her and her own flattened forward/right vectors. Returned in that order: pitch first, then roll.
--
-- BOTH SIGNS ARE POSITIVE AND BOTH ARE WORTH DERIVING RATHER THAN TRUSTING. For pitch: applying
-- CFrame.Angles(t, 0, 0) to a look vector of (0, 0, -1) gives (0, sin t, -cos t), so a positive angle
-- lifts the bow -- and water that is HIGHER ahead of her should lift the bow. For roll: a positive
-- rotation about the local Z lifts the starboard side (the same fact BlimpDrive.PresentationCFrame's
-- own negation is derived from), and water that is higher to starboard should lift it.
--
-- TiltPerSlope IS BELOW 1 AND MUST STAY THERE. At exactly 1 the hull lies precisely along the water's
-- surface, which is right for a raft and wrong for anything with a keel: a real hull's inertia means
-- she does not follow every wavelet, and a boat that did would look like a leaf.
function BoatWaterMath.TiltFor(slopeX: number, slopeZ: number, forward: Vector3, right: Vector3): (number, number)
	local cfg = BoatConstants.Swell

	local alongForward = slopeX * forward.X + slopeZ * forward.Z
	local alongRight = slopeX * right.X + slopeZ * right.Z

	local pitch = math.clamp(alongForward * cfg.TiltPerSlope, -cfg.MaxTiltRadians, cfg.MaxTiltRadians)
	local roll = math.clamp(alongRight * cfg.TiltPerSlope, -cfg.MaxTiltRadians, cfg.MaxTiltRadians)
	return pitch, roll
end

return BoatWaterMath
