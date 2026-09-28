--!strict
--[[
	BoatDrive.lua

	Owns: the sailing integration -- turning a sail setting, a rudder and the wind into the pose the
	boat's drive constraints are told to chase, one tick at a time, plus the validation that turns an
	untrusted table off a remote into a HelmInput.

	TOUCHES NO INSTANCE, ON PURPOSE, and the same contract Server/Blimp/BlimpDrive.lua sets out next
	door buys more here than it does there. Every function below takes plain values -- a state, an
	intent, a tuning, a wind sample, a water sample -- and returns one; nothing reads a part, a
	constraint, or Workspace. That is what makes the questions this system actually needs answered
	testable without a place file, and they are questions no amount of playtesting settles quickly:
	does a hull pointed inside the no-go arc really make ZERO way with full sail set, does the rudder
	genuinely go dead as she loses steerage, does a beached hull refuse forward drive while keeping
	sternway, and does the heel swap sides smoothly through a gybe. Server/Systems/BoatSystem.lua owns
	every Instance touch and calls this for the arithmetic.

	NOTHING HERE EVER READS THE BOAT'S REAL CFrame BACK. The integrator advances its own Target from its
	own previous Target, and the constraints chase whatever that is. Closing the loop -- re-seeding
	Target from the hull's actual pose each tick -- is the obvious-looking change and it is wrong twice
	over: the gap between target and actual IS the weight (a target that snaps to the hull can never lead
	it, so the boat stops having mass), and a hull shoved by a collision would drag its own target along,
	so a nudge would become a permanent course change no helmsman asked for. ClampLead is the bounded
	exception, for the reason BlimpDrive.ClampLead's own header sets out in full.

	THE THREE THINGS THAT MAKE THIS A BOAT AND NOT A SLOWER BLIMP, all of them in Step:

	  1. SPEED IS THE WIND'S, NOT THE PLAYER'S. The sail rung is a fraction of CANVAS. What it produces
	     is that fraction times the wind's strength times the polar (Shared/Boat/BoatWind.Efficiency),
	     and inside the no-go arc the polar is exactly zero. A player who sets full sail at the wind goes
	     nowhere, and the only way out is to bear away or back her out -- which is what makes tacking a
	     skill rather than a formality.
	  2. THE RUDDER DIES WITH THE WAY. Authority ramps from a near-zero floor at a standstill to full at
	     a fraction of hull speed. A vehicle that pivots on the spot is not a boat, and losing steerage
	     as you lose way is the thing that makes a player keep some on through a turn.
	  3. SHE DOES NOT GO WHERE SHE POINTS. Leeway slides the hull bodily downwind on top of her forward
	     travel, so holding a course close-hauled past a headland is a thing you have to allow for.

	SUCH THAT THE FOURTH -- THE WATER -- IS THE VERTICAL. There is no lift axis and no altitude band: the
	target's Y chases the water's surface, ramped rather than snapped, and a tick that finds no water
	under the hull holds the last height instead of falling through the map.

	Does not own: the constraints (Server/Vessel/VesselAssembly.lua), who is allowed to steer
	(Server/Systems/BoatSystem.lua), the mode machine (Server/Boat/BoatHullMode.lua), the wind curve
	(Shared/Boat/BoatWind.lua), the swell (Shared/Boat/BoatWaterMath.lua), the tuning numbers
	(Shared/Boat/BoatConstants.lua), or the per-model overrides (Shared/Boat/BoatTagging.ResolveTuning).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BoatTypes = require(ReplicatedStorage.Shared.Boat.BoatTypes)
local BoatWaterMath = require(ReplicatedStorage.Shared.Boat.BoatWaterMath)
local BoatWind = require(ReplicatedStorage.Shared.Boat.BoatWind)

local BoatDrive = {}

-- Seconds. A tick longer than this is a server hitch or a Studio breakpoint, not sailing time, and
-- integrating it whole would teleport the target sixty studs and leave the hull chasing a point it
-- cannot see. Clamping is the honest response: the boat loses the stalled time rather than banking it.
local MAX_STEP_SECONDS = 0.25

-- Below this the yaw-only rebuild has no direction to work from. Only reachable if a caller hands in a
-- Target that is already degenerate, which is why the fallback is "keep the previous facing" rather than
-- an error -- a boat that stops turning is recoverable, one that errors every Heartbeat is not.
local EPSILON = 1e-4

local function approach(current: number, target: number, maxDelta: number): number
	if current < target then
		return math.min(current + maxDelta, target)
	end
	return math.max(current - maxDelta, target)
end

local function isFiniteNumber(value: unknown): boolean
	if typeof(value) ~= "number" then
		return false
	end
	local number = value :: number
	return number == number and number ~= math.huge and number ~= -math.huge
end

function BoatDrive.NeutralIntent(): BoatTypes.DriveIntent
	return { Sail = 0, Steer = 0 }
end

function BoatDrive.NewState(origin: CFrame): BoatTypes.DriveState
	local look = origin.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	local facing = if flat.Magnitude > EPSILON then flat.Unit else Vector3.new(0, 0, -1)
	return {
		-- Seeded UPRIGHT from wherever the hull happens to be sitting, discarding any heel or trim the
		-- builder left in the model's own rotation -- see BoatTypes.DriveState on why Target carries yaw
		-- and nothing else.
		Target = CFrame.lookAt(origin.Position, origin.Position + facing),
		Speed = 0,
		YawRate = 0,
		HeaveRate = 0,
	}
end

-- Turns whatever came off the SetHelmInput remote into a HelmInput, or nil if it was not one. nil rather
-- than a neutral input for a malformed payload: neutral is a MEANINGFUL value (centre the rudder), so it
-- cannot double as the failure signal -- the same rule BlimpDrive.SanitizeIntent follows.
--
-- Clamped rather than rejected for an out-of-range number. A client that sends 3.0 is claiming something
-- a key press cannot produce, but the honest reading of it is still "hard over", and rejecting the packet
-- would leave the last axis latched -- which is a worse outcome than honouring the clamp.
function BoatDrive.SanitizeHelmInput(raw: unknown): BoatTypes.HelmInput?
	if typeof(raw) ~= "table" then
		return nil
	end
	local input = raw :: { [string]: unknown }
	if not isFiniteNumber(input.Steer) then
		return nil
	end
	return { Steer = math.clamp(input.Steer :: number, -1, 1) }
end

-- The world yaw this hull's BOW is pointing along -- her own Target facing plus the authored bow
-- correction. The one number every wind question in the layer is asked about, and the reason
-- BoatTypes.DriveTuning.ForwardYawRadians exists at all.
function BoatDrive.BowBearing(state: BoatTypes.DriveState, tuning: BoatTypes.DriveTuning): number
	local bow = state.Target * CFrame.Angles(0, tuning.ForwardYawRadians, 0)
	return BoatWind.BearingOfLook(bow.LookVector)
end

-- The commanded speed for a sail setting on this heading in this wind, in studs/second. Signed.
--
-- STERNWAY IGNORES THE WIND ENTIRELY, and that is a deliberate departure from the model above it rather
-- than an omission. Backing sails in a real boat depends very much on where the wind is; here it must
-- not, because sternway is this vehicle's only escape hatch from its two dead ends -- stuck head to
-- wind, and run up on a beach -- and an escape hatch that only works in some winds is one a player will
-- one day find closed with no way to reason about why. It is feeble
-- (BoatConstants.Drive.SternwaySpeed) precisely so it can afford to be reliable.
local function commandedSpeedFor(
	sail: number,
	tuning: BoatTypes.DriveTuning,
	wind: BoatTypes.WindSample,
	relativeAngle: number
): number
	if sail < 0 then
		return sail * tuning.SternwaySpeed
	end
	return sail * wind.Strength * BoatWind.Efficiency(relativeAngle) * tuning.HullSpeed
end

-- How much of TurnRate the rudder can actually command at this speed, 0..1 -- see this file's header,
-- point 2. Linear from the floor at a standstill to 1 at RudderAuthorityFullAtSpeedFraction of hull
-- speed, and flat at 1 above that.
--
-- READS THE MAGNITUDE OF THE SPEED, so a hull making sternway steers as well as one making the same
-- speed ahead. A real rudder reverses its effect when the water flows over it backwards, and modelling
-- that was tried and taken out: it is correct seamanship and it reads as a bug, because the only time
-- most players ever make sternway is when they are already in trouble and the helm suddenly answering
-- backwards is indistinguishable from the controls being broken. Keeping it un-reversed is the
-- deliberate choice, not the naive one.
local function rudderAuthority(speed: number, tuning: BoatTypes.DriveTuning): number
	local hullSpeed = math.max(tuning.HullSpeed, EPSILON)
	local fraction = math.abs(speed) / hullSpeed
	local rampSpan = math.max(tuning.RudderAuthorityFullAtSpeedFraction, EPSILON)
	local ramp = math.clamp(fraction / rampSpan, 0, 1)
	return tuning.MinRudderAuthority + (1 - tuning.MinRudderAuthority) * ramp
end

-- One tick. Pure: `state` is never mutated, the successor is returned.
--
-- `decelerationMultiple` is 1 in ordinary sailing and BoatConstants.Beaching.DecelerationMultiple while
-- aground -- a hull that hits shore does not coast for twelve seconds. Passed in rather than derived
-- from `water.Supported` here so the one place that decides what beaching MEANS stays
-- Server/Boat/BoatHullMode.lua, and this function keeps taking only numbers.
function BoatDrive.Step(
	state: BoatTypes.DriveState,
	intent: BoatTypes.DriveIntent,
	tuning: BoatTypes.DriveTuning,
	wind: BoatTypes.WindSample,
	water: BoatTypes.WaterSample,
	deltaTime: number,
	decelerationMultiple: number
): BoatTypes.DriveState
	local dt = math.clamp(deltaTime, 0, MAX_STEP_SECONDS)
	if dt <= 0 then
		return state
	end

	local relativeAngle = BoatWind.RelativeAngle(BoatDrive.BowBearing(state, tuning), wind.BearingRadians)

	local commandedSpeed = commandedSpeedFor(intent.Sail, tuning, wind, relativeAngle)
	-- AGROUND: forward drive is refused outright, sternway is not. See BoatConstants.Beaching on why
	-- that asymmetry is the whole of the recovery path -- and note the refusal is here rather than in
	-- the mode machine, because "she will not go that way" is a fact about the hull's contact with the
	-- ground, not about who is steering.
	if not water.Supported and commandedSpeed > 0 then
		commandedSpeed = 0
	end

	-- Two ramps, not one, and the slower is the one that makes her a boat -- see
	-- BoatConstants.Drive.Deceleration. "Toward zero" is measured on MAGNITUDE, so a hull asked to go
	-- astern while still making way forward loses her way on the deceleration ramp first and only then
	-- gathers sternway on the acceleration one, which is what actually happens.
	local slowing = math.abs(commandedSpeed) < math.abs(state.Speed)
	local speedRate = if slowing then tuning.Deceleration * math.max(decelerationMultiple, 1) else tuning.Acceleration
	local speed = approach(state.Speed, commandedSpeed, speedRate * dt)

	local commandedYaw = intent.Steer * tuning.TurnRate * rudderAuthority(speed, tuning)
	local yawRate = approach(state.YawRate, commandedYaw, tuning.TurnAcceleration * dt)

	-- Yaw first, then translate along the NEW heading. Translating first would make every turn a series
	-- of tiny straight segments taken before the bow came round, which reads as the hull crabbing.
	-- Negated because a positive Steer axis is starboard, and Roblox turns right on a negative Y rotation.
	local turned = state.Target * CFrame.Angles(0, -yawRate * dt, 0)
	-- Travel runs along the hull's BOW, which is its own facing plus the authored correction -- NOT along
	-- Target.LookVector directly. Those are the same thing only for a model whose root part happens to be
	-- oriented the way the artist drew the ship.
	--
	-- The yaw INPUT above is untouched by the correction on purpose: which world rotation counts as "to
	-- starboard" does not depend on where the bow is, so steering stays correct the moment travel does.
	local forward = (turned * CFrame.Angles(0, tuning.ForwardYawRadians, 0)).LookVector

	-- LEEWAY: the hull is pushed bodily the way the wind is going, on top of where she is pointing. The
	-- wind's BEARING names where it comes from (Shared/Boat/BoatWind.lua's one convention), so the push
	-- is along the NEGATIVE of the source look.
	--
	-- Scaled by |sin| of the angle off the wind, which is the LATERAL force -- zero head to wind and zero
	-- dead astern, largest on the beam. Worth saying what this deliberately is not: the textbook figure
	-- is a leeway ANGLE, lateral force over forward drive, and that formulation divides by a quantity
	-- that is exactly zero in irons. Modelling the force instead is bounded everywhere, is smooth
	-- through both a tack and a gybe, and differs from the textbook only in that a boat close-hauled
	-- makes slightly less leeway than she strictly should.
	local leewaySpeed = math.abs(speed) * tuning.LeewayFraction * math.abs(BoatWind.LateralFactor(relativeAngle))
	local leewayDirection = -BoatWind.SourceLook(wind.BearingRadians)

	local horizontal = turned.Position + forward * (speed * dt) + leewayDirection * (leewaySpeed * dt)

	-- THE VERTICAL IS THE WATER'S, NOT THE PILOT'S. Chased on a ramped rate rather than assigned, so a
	-- hull crossing from a river onto a lake at a different level rises to it over a beat instead of
	-- teleporting, and so a swell lifts her rather than jerking her.
	--
	-- WITH NO WATER UNDER HER, HOLD THE LAST HEIGHT. Not fall, not seek anything -- hold. A first
	-- implementation lets the target Y follow nothing and drops the hull through the map; the second
	-- lets it seek some default sea level and teleports a beached boat to it.
	local currentY = turned.Position.Y
	local targetY = if water.Supported then water.SurfaceY + tuning.WaterlineOffset else currentY
	local gap = targetY - currentY
	local desiredHeave = math.clamp(gap / dt, -tuning.HeaveSpeed, tuning.HeaveSpeed)
	local heaveRate = approach(state.HeaveRate, desiredHeave, tuning.HeaveAcceleration * dt)
	local nextY = currentY + heaveRate * dt
	-- Overshoot guard. The ramped rate carries momentum, so without this the hull would sail past the
	-- surface and come back -- a bob the swell is already providing and that would beat against it.
	if (targetY - nextY) * gap < 0 then
		nextY = targetY
		heaveRate = 0
	end

	local position = Vector3.new(horizontal.X, nextY, horizontal.Z)

	local look = turned.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	local facing = if flat.Magnitude > EPSILON then flat.Unit else state.Target.LookVector

	return {
		Target = CFrame.lookAt(position, position + facing),
		Speed = speed,
		YawRate = yawRate,
		HeaveRate = heaveRate,
	}
end

-- Bounds how far `target` may lead `actualPosition`, clamping only the DISTANCE between them along the
-- straight line that already separates them -- the direction and `target`'s own rotation are untouched.
-- See Server/Blimp/BlimpDrive.ClampLead's header for the debt-discharge problem this exists to bound;
-- it is the same problem on a boat and the same fix.
--
-- Returns `target` UNCHANGED (the same value, not an equal copy) when it is already within the bound,
-- which is every tick of a clean passage -- the caller relies on that to know whether it needs to write
-- anything back into the state at all.
function BoatDrive.ClampLead(target: CFrame, actualPosition: Vector3, maxLeadStuds: number): CFrame
	local offset = target.Position - actualPosition
	local distance = offset.Magnitude
	if distance <= maxLeadStuds then
		return target
	end
	local clampedPosition = actualPosition + (offset / distance) * maxLeadStuds
	return target.Rotation + clampedPosition
end

-- What the orientation constraint is actually given: the upright target, plus the heel and trim the
-- current moment earns. Derived, never stored -- see BoatTypes.DriveState.
--
-- THE TILT IS APPLIED IN THE BOW'S FRAME, NOT THE ROOT'S, which is the one place this differs
-- structurally from BlimpDrive.PresentationCFrame. Pitch and roll only mean anything relative to fore-
-- and-aft and athwartships, and a model whose root part is turned 90 degrees from its bow would
-- otherwise get its heel applied as trim. Conjugating by the bow correction costs two multiplies and
-- makes the result independent of how the artist happened to orient the largest mesh.
--
-- THREE CONTRIBUTIONS TO THE ROLL, AND THE WIND ONE IS WHAT SELLS IT:
--   * The turn. A hull rolls out from under a helm put hard over. Negated for the same reason the yaw
--     integration is: positive YawRate is a starboard turn, and a positive roll about the local Z LIFTS
--     the starboard side, so dropping it takes a negative.
--   * The wind. A boat under press of canvas leans AWAY from the wind and stays leaning for as long as
--     the sails are drawing -- the silhouette everybody recognises, and the one thing a blimp's banking
--     model has no equivalent of. BoatWind.LateralFactor is positive for a wind on the port bow, which
--     pushes her over to starboard, which is again a negative roll.
--   * The swell, via BoatWaterMath.TiltFor, which also supplies the wave half of the pitch.
function BoatDrive.PresentationCFrame(
	state: BoatTypes.DriveState,
	tuning: BoatTypes.DriveTuning,
	sailFraction: number,
	wind: BoatTypes.WindSample,
	surgeAcceleration: number,
	slopeX: number,
	slopeZ: number
): CFrame
	local bowCorrection = CFrame.Angles(0, tuning.ForwardYawRadians, 0)
	local bow = state.Target * bowCorrection

	local relativeAngle = BoatWind.RelativeAngle(BoatWind.BearingOfLook(bow.LookVector), wind.BearingRadians)
	local pressure = BoatWind.Pressure(sailFraction, wind.Strength, relativeAngle)

	local turnHeel = -state.YawRate * tuning.HeelRadiansPerTurnRate
	local windHeel = -BoatWind.LateralFactor(relativeAngle) * pressure * tuning.HeelRadiansPerWindPressure
	local heel = math.clamp(turnHeel + windHeel, -tuning.MaxHeelRadians, tuning.MaxHeelRadians)

	local trim =
		math.clamp(surgeAcceleration * tuning.TrimRadiansPerAccel, -tuning.MaxTrimRadians, tuning.MaxTrimRadians)

	local wavePitch, waveRoll = BoatWaterMath.TiltFor(slopeX, slopeZ, bow.LookVector, bow.RightVector)

	return state.Target * bowCorrection * CFrame.Angles(trim + wavePitch, 0, heel + waveRoll) * bowCorrection:Inverse()
end

return BoatDrive
