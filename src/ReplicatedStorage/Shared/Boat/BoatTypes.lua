--!strict
--[[
	BoatTypes.lua

	Owns: the shapes the Boat layer is written in -- what a helmsman's steering intent looks like on the
	wire, what the wind is, what the water under a hull is, the drive integrator's own state/tuning
	pair, and the helm cue every player aboard is told about.

	Deliberately NOT a section of Shared/Types.lua, and not a section of Shared/Vessel/VesselTypes.lua
	either. The first is the rule every per-system types module in this codebase already follows -- a
	module whose types live somewhere else cannot be removed without unpicking that somewhere else. The
	second is the more interesting line: VesselTypes owns what a blimp and a boat AGREE on (a station, a
	mount cue, a telegraph rung), and everything here is what they do not. A blimp has a Lift axis and
	an altitude band; a boat has a sail setting, a point of sail and a waterline. Neither vocabulary
	belongs in the other's file, and putting both in the shared one would make "which of these does my
	vehicle have" unanswerable from the type alone.

	Does not own: the tunable numbers themselves (BoatConstants.lua), the wind model (BoatWind.lua) or
	the wave arithmetic (BoatWaterMath.lua) -- both of which are written entirely against the shapes
	below and touch no Instance -- or how a tagged Model becomes one driveable body
	(Server/Vessel/VesselAssembly.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VesselTypes = require(ReplicatedStorage.Shared.Vessel.VesselTypes)

local BoatTypes = {}

-- Re-exported so a Boat-layer file naming a station or a mount cue does not have to require two types
-- modules to say one thing. The definitions live in Shared/Vessel/VesselTypes.lua because a boat's
-- helm and a blimp's are the same object.
export type StationKind = VesselTypes.StationKind
export type MountChangedPayload = VesselTypes.MountChangedPayload

-- What the pilot's client actually SENDS, at BoatConstants.Network.IntentSendHz. ONE AXIS -- the
-- rudder -- and nothing else.
--
-- The sail setting is not on this stream for the same reason a blimp's throttle is not on its own: it
-- is a RUNG the server owns (BoatConstants.SailStates), moved by its own edge remote. A client can
-- assert "one notch more canvas", never "make me go this fast". And unlike a blimp, a boat has no
-- third axis at all -- there is no lift, and the vertical is the water's business, not the pilot's.
export type HelmInput = {
	Steer: number, -- -1 (port) .. 1 (starboard)
}

-- What the INTEGRATOR consumes, assembled server-side from the latched rung plus the pilot's rudder.
-- Two types rather than one with an optional field, for the reason BlimpTypes gives for the same pair:
-- they answer different questions and have different authorities.
export type DriveIntent = {
	-- The rung's own fraction of full canvas, -1 (sails backed, making sternway) .. 1 (full sail).
	-- NOT a speed: how fast this actually drives the hull depends on the wind and on the angle the hull
	-- is holding to it, which is the whole game -- see BoatWind.Efficiency.
	Sail: number,
	Steer: number,
}

-- What the hull is DOING with itself, as decided once per tick by Server/Boat/BoatHullMode.lua. One
-- value, five states, and every one is a different answer to "who is sailing this":
--
--   Moored   -- nobody is at the wheel and nothing is latched. Sails come in, the hull carries its way
--               off and then lies to. Covers three situations that want identical behaviour: a hull
--               with crew aboard and nobody steering, a freshly registered hull, and -- the case that
--               matters most -- a hull everybody has just stepped off, for the whole drift window
--               before the anchor goes down.
--   Piloted  -- a player is holding the helm. The ordinary case, and the only one where a human's keys
--               reach the integrator.
--   Adrift   -- the helm is empty, somebody is still aboard, and the sail rung is latched. The boat's
--               equivalent of a blimp's autopilot, and the same feature for the same reason: a skipper
--               walking the deck while the ship keeps sailing. See BoatConstants.Adrift.
--   Anchored -- nobody has been aboard for the abandon grace. Sails furled, way carried off, holding
--               station on the water. Not a player-reachable mode.
--   Beached  -- there is no water under the hull. Forward drive is refused outright and only sternway
--               can get her off. Also not player-chosen, but unlike Anchored it is a thing a pilot can
--               sail themselves INTO, which is why it is a mode rather than a flag.
--
-- A BLIMP NEEDS TWO TERMINAL STATES HERE AND A BOAT NEEDS ONE, which is the only structural difference
-- between this machine and BlimpFlightMode's. An abandoned airship has to DESCEND before it can rest,
-- so Landing and Grounded are genuinely two different things it is doing. An abandoned boat is already
-- at rest height -- the water holds it up whether anyone is aboard or not -- so there is nothing
-- between "give up" and "lie there". Anchored is that single state. Resisting the urge to mirror the
-- blimp's pair for symmetry is the point: a Landing-shaped mode here would be a state the hull passed
-- through in zero ticks, forever.
--
-- A STRING UNION RATHER THAN A SET OF BOOLEANS, for the reason BlimpTypes.HullMode's own comment gives
-- at length: one value cannot be in two modes, so nobody downstream has to invent a precedence rule.
export type HullMode = "Moored" | "Piloted" | "Adrift" | "Anchored" | "Beached"

-- How the hull is lying to the wind, as a name a helm panel can print. Derived from one angle by
-- BoatWind.PointOfSail; carried nowhere on the wire, because every client can work it out from the
-- hull's own replicated facing and the same deterministic wind the server sailed by.
--
--   InIrons     -- bow inside the no-go arc. The sails luff and drive is ZERO however much canvas is
--                  set. The one state a player has to actively get out of, and the reason tacking is a
--                  skill rather than a formality.
--   CloseHauled -- as near the wind as she will lie and still make way. Slow, and the fastest way to
--                  gain ground upwind.
--   BeamReach   -- wind on the side. Fastest point of sail, which is a real fact about boats and not a
--                  balance decision.
--   BroadReach  -- wind over the quarter. Nearly as fast and far more forgiving.
--   Running     -- wind dead astern. Slower than a reach, because the sails blanket one another and
--                  the apparent wind falls off with your own speed.
export type PointOfSail = "InIrons" | "CloseHauled" | "BeamReach" | "BroadReach" | "Running"

-- The world's wind at one instant. ONE WIND FOR THE WHOLE MAP -- there is no per-boat weather -- and
-- it is a pure function of the clock (BoatWind.Sample), which is what lets the server sail by it and
-- every client draw the same vane without a single byte on the wire.
export type WindSample = {
	-- Radians, a world yaw, naming the direction the wind blows FROM -- the sailor's convention, and
	-- the one every angle in this layer is measured against. A "northerly" is wind FROM the north.
	--
	-- Getting this backwards is the single most likely bug in the whole layer, which is why the field
	-- is named Bearing rather than Direction: a bearing is where you look to find the thing, a
	-- direction is where the thing is going, and those are opposite here.
	BearingRadians: number,
	-- 0..1. Scales every boat's speed. Never reaches 0 -- see BoatConstants.Wind.MinStrength on why a
	-- flat calm is a worse mechanic than a slow one.
	Strength: number,
}

-- One tagged water plane, reduced to what a containment test actually needs. Built once per tagged
-- part by Server/Boat/BoatWater.lua and consumed by BoatWaterMath.SurfaceUnder, which is pure --
-- that split is what makes "does a hull over the edge of a lake read as beached" answerable in the
-- TestEZ suite without a place file.
export type WaterPlane = {
	-- World Y of the plane's top face. See BoatConstants.Tags.Water on why a water part is expected to
	-- be level, and what happens if a builder tilts one.
	TopY: number,
	-- The part's own CFrame inverted, cached so a containment test is one multiply rather than a
	-- PointToObjectSpace call into the engine per boat per tick.
	Inverse: CFrame,
	HalfX: number,
	HalfZ: number,
}

-- What the water is doing under one hull this tick.
export type WaterSample = {
	-- World Y the hull's waterline should sit at, INCLUDING the swell. Meaningless when Supported is
	-- false, and callers must not read it then -- there is no honest number for "the height of water
	-- that is not there".
	SurfaceY: number,
	-- Whether any tagged plane was found under the hull at all. False is the Beached condition.
	Supported: boolean,
}

-- The integrator's whole world. Target is the pose the drive constraints are CHASING, not the pose the
-- boat is in -- the gap between the two is what makes this read as a heavy displacement hull rather
-- than a brick on rails, and nothing here ever reads the boat's real CFrame back (see BoatDrive.lua's
-- header, and BlimpDrive.lua's before it, on why closing that loop fights the constraints).
--
-- Target is deliberately kept UPRIGHT (yaw only, no heel, no trim). The visible heel is derived at
-- presentation time from the turn rate, the wind pressure and the wave slope
-- (BoatDrive.PresentationCFrame), so a turn that ends leaves no accumulated roll to unwind and a hull
-- shoved by a collision cannot roll itself under.
export type DriveState = {
	Target: CFrame,
	Speed: number,
	YawRate: number,
	-- Studs/second the target's own Y is currently moving at, ramped rather than snapped so a hull
	-- crossing from a river onto a lake at a different level rises to it instead of teleporting.
	HeaveRate: number,
}

export type DriveTuning = {
	-- Which way is BOW, as a yaw offset in radians from the root part's own LookVector. Resolved once
	-- at registration by VesselTagging.ResolveForwardYaw -- see that function for the two ways to
	-- author it and for why a root part's own axis is never the answer.
	ForwardYawRadians: number,
	-- Studs/second with full canvas set, in a full wind, on the best point of sail. Every other speed
	-- this hull ever makes is this multiplied by three fractions, all of them below 1: the rung, the
	-- wind's strength and the point-of-sail efficiency.
	HullSpeed: number,
	-- Studs/second with the sails backed. Feeble on purpose -- see BoatConstants.SailStates.
	SternwaySpeed: number,
	Acceleration: number,
	-- Studs/second^2 shed when the commanded speed is BELOW the current one. Deliberately its own
	-- number and deliberately smaller than Acceleration: a displacement hull under way has no brake,
	-- and "she carries her way" is the single most boat-like thing about how one handles.
	Deceleration: number,
	TurnRate: number,
	TurnAcceleration: number,
	-- The floor on rudder authority at a standstill, as a fraction of TurnRate, and the speed fraction
	-- at which authority reaches 1. A rudder is a wing in a moving fluid: with no water flowing past
	-- it, it does almost nothing. This pair is what stops a boat pirouetting on the spot, which is the
	-- most common way a vehicle stops reading as a boat.
	MinRudderAuthority: number,
	RudderAuthorityFullAtSpeedFraction: number,
	-- Studs of sideways slip per stud/second of speed, at full press. A boat does not travel where she
	-- points; she is pushed bodily downwind, most when hard on the wind and least when running.
	LeewayFraction: number,
	-- Studs the hull's ROOT sits above the water surface. The one number a builder is most likely to
	-- need per model, since it depends entirely on where the artist put the hull's largest part.
	WaterlineOffset: number,
	-- How fast the target's Y may chase a change in water level, and how fast that rate itself ramps.
	HeaveSpeed: number,
	HeaveAcceleration: number,
	-- Visible heel per radian/second of yaw, and per unit of wind pressure on the sails. Applied at
	-- PRESENTATION time only -- see DriveState above.
	HeelRadiansPerTurnRate: number,
	HeelRadiansPerWindPressure: number,
	MaxHeelRadians: number,
	-- Visible bow-up trim per stud/second^2 of surge.
	TrimRadiansPerAccel: number,
	MaxTrimRadians: number,
}

-- Server -> every player aboard ONE hull, on an edge. See BoatConstants.Network.RemoteNames.
-- HelmUpdated's own comment for why passengers get this and for why there is not a single continuous
-- quantity in here -- including, notably, no wind.
export type HelmUpdatedPayload = {
	Mode: HullMode,
	-- 1-based index into BoatConstants.SailStates, sent alongside its own Label rather than leaving the
	-- client to index that table itself: the client would get the same answer today, but the day a hull
	-- carries a bespoke rig the index alone stops being enough and the failure is a WRONG word on the
	-- gauge, not a missing one.
	SailIndex: number,
	SailLabel: string,
	-- The rung's own canvas fraction, -1..1 -- what the gauge fills to, and what tells it which side of
	-- furled this rung sits on without re-deriving it from the index.
	SailFraction: number,
	SailCount: number,
	Adrift: boolean,
	-- This hull's resolved bow correction, in radians. Constant for the life of a registration, which
	-- is exactly why it can ride a discrete edge push instead of forcing a continuous one.
	--
	-- SENT RATHER THAN RE-RESOLVED CLIENT-SIDE, even though VesselTagging is a Shared module the client
	-- could call itself: that resolution ends in two downward raycasts against the deck under the helm,
	-- and a client is streaming -- the deck part may simply not be loaded on the frame a player boards,
	-- so the client would silently resolve a DIFFERENT bow from the server and draw a compass that
	-- disagreed with the direction the ship visibly travels.
	ForwardYawRadians: number,
}

return BoatTypes
