--!strict
--[[
	BoatConstants.lua

	Owns: the Boat layer's whole authoring contract and its tunables -- the CollectionService tags a
	builder puts on a Model (and on the water) in Studio, the per-model Attribute overrides that let one
	hull differ from another without a code change, the remote names, the wind model's own numbers, and
	the default sailing figures.

	A STANDALONE MODULE, not a Constants.Boat section, following the precedent Constants.lua's own
	header sets out and Shared/Blimp/BlimpConstants.lua already follows: this is one system's own tuning
	surface, read by a Server System, three Server sub-modules and a Client controller, none of which
	should have to require the whole cross-system registry to learn how close to the wind a boat lies.

	THE AUTHORING CONTRACT, in full -- everything a builder does in Studio, and nothing else:

	  1. Tag the boat MODEL with "Boat".                                   (required)
	  2. Tag one BasePart inside it with "BoatHelm" -- the wheel/tiller.   (required for a pilot)
	  3. Tag any number of parts with "BoatHandhold" -- rails, shrouds.    (optional, passengers)
	  4. Tag any number of parts with "BoatWake" -- its ParticleEmitters   (optional, wake FX)
	     run while the hull is making way.
	  5. Tag every WATER surface in the map with "BoatWater".              (required, once per map)
	  6. On a station, add an Attachment named "Stand".                    (optional, exact placement)
	  7. On a station part, add Attachments "LeftGrip"/"RightGrip".        (optional, exact hands)
	  8. On the model, set any of the BoatHullSpeed/... Attributes.        (optional, per-hull tuning)

	ITEM 5 IS THE ONE A BUILDER FORGETS, and it is the only entry here whose absence produces a boat
	that looks broken rather than a boat that is merely plain. Every other optional tag degrades to a
	sensible default; an untagged sea has no surface for a hull to float on, so every boat in it reads
	as Beached and refuses to make way. That failure is deliberately loud -- Server/Boat/BoatWater.lua
	warns once when a boat is registered in a world with no tagged water at all -- because the
	alternative (silently inventing a sea level) is a number nobody authored that would then be wrong
	for every map after the first.

	THE BOW IS WHEREVER THE PILOT FACES, exactly as on a blimp and for the same reason -- see
	Shared/Vessel/VesselTagging.ResolveStandOffset, which is the shared code both layers use, and its
	header for the two-bugs-that-were-one-bug story behind it. The escape hatch, if a hull still sails
	stern-first: the BoatForwardYaw Attribute below, in degrees.

	SAIL, NOT ENGINE, AND THAT CHANGES WHAT THE CONTROLS MEAN. A blimp's telegraph rung IS its speed; a
	boat's sail rung is only how much canvas is set, and the speed that produces depends on the wind's
	strength and on the angle the hull is holding to it. Setting full sail while pointing into the wind
	produces nothing at all. That is not a punishment -- it is the mechanic: getting somewhere upwind
	means tacking, which means a player has to read the wind rather than hold W.

	Does not own: how the tags are RESOLVED (BoatTagging.lua and Shared/Vessel/VesselTagging.lua), the
	wind curve itself (BoatWind.lua reads the numbers below and owns the arithmetic), the wave
	arithmetic (BoatWaterMath.lua), the sailing integration (Server/Boat/BoatDrive.lua), or the mount
	rules (Server/Systems/BoatSystem.lua and Server/Vessel/VesselMount.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- The ONE require this otherwise standalone file makes, and only for the two Controls shapes at the
-- bottom -- the same reach, for the same reason, BlimpConstants.lua already documents.
local VesselTypes = require(ReplicatedStorage.Shared.Vessel.VesselTypes)

local BoatConstants = {}

-- CollectionService tag names. Unlike ParkourTagging's set these have no Attribute twin, for the reason
-- BlimpConstants.Tags gives: these answer "is this object a boat / a helm / the sea", which is a
-- structural fact about the build, set once, and much better served by the Tag Editor's bulk selection
-- than by individually-typed booleans.
BoatConstants.Tags = {
	-- On the MODEL. Everything inside it becomes one welded, driven body -- see
	-- Server/Vessel/VesselAssembly.lua.
	Model = "Boat",
	-- On ONE BasePart inside a tagged model. The pilot's station: mounting here hands this player the
	-- boat's steering until they dismount. A model with two helms is a build error, not a two-pilot
	-- feature -- VesselTagging.ResolveStations logs it and keeps the first.
	Helm = "BoatHelm",
	-- On any number of BaseParts inside a tagged model. A passenger's station: welds and poses exactly
	-- like the helm, feeds no steering.
	Handhold = "BoatHandhold",
	-- On any number of BaseParts inside a tagged model -- the bow and the quarters, typically. EVERY
	-- ParticleEmitter beneath a tagged part runs while the hull is making way above
	-- Wake.MinSpeedFraction and stops when she loses it.
	--
	-- A TAG RATHER THAN "every emitter in the model", for the reason BlimpConstants.Tags.Exhaust gives:
	-- a boat with a galley fire or a lantern haze would have them cut out every time she lost way. The
	-- tag says which emitters are WAKE, which is a thing only the builder knows.
	Wake = "BoatWake",
	-- On every BasePart that IS water -- a sea slab, a lake, a river section. NOT on a boat; this is
	-- the one tag in this file that goes on the world rather than on a vessel.
	--
	-- THE TOP FACE IS THE WATERLINE, and a plane is expected to be LEVEL. A part's top face is read as
	-- its centre plus half its height, which is exact for an unrotated slab and for one rotated about Y
	-- (the two shapes anybody actually builds a sea out of), and merely approximate for one a builder
	-- has tilted. Tilting one is not supported and is not detected: the water would render sloped and
	-- boats would float at its average height. Build a sloping river as a run of level sections, which
	-- is what a real one is.
	--
	-- MANY SMALL PLANES ARE FINE AND ARE THE INTENDED SHAPE. Containment is tested per hull per tick
	-- against every tagged plane, and the test is one CFrame multiply and two comparisons -- a map with
	-- a hundred tagged river sections costs a boat a hundred of those, which is nothing. Overlapping
	-- planes at different heights resolve to the HIGHEST, so a lock or a raised canal laid over a sea
	-- slab does the obvious thing.
	Water = "BoatWater",
}

-- Optional Attachment names, looked up on a STATION part only. Each has a documented fallback, so a
-- boat built without any of them still mounts correctly -- these exist to make a detailed model look
-- deliberate, not to make a plain one work. Deliberately the SAME NAMES a blimp uses: a builder who has
-- rigged one vehicle in this game has rigged them all, and two names for one concept would be a second
-- thing to remember for no gain.
BoatConstants.Attachments = {
	-- Where the two hands are placed. Absent -> VesselArmPose derives a symmetric pair from the station
	-- part's own size, along its widest horizontal axis.
	LeftGrip = "LeftGrip",
	RightGrip = "RightGrip",
	-- Where the mounted character's HumanoidRootPart is welded, and which way it faces. Absent ->
	-- VesselTagging.ResolveStandOffset detects a side; see its header.
	Stand = "Stand",
}

-- Per-model Attribute overrides. Set any of these on the tagged MODEL to give one boat its own handling
-- without a second tag or a code change; unset falls through to Drive below. A fishing skiff and a
-- cargo junk are the same system with two Attribute sets.
BoatConstants.ModelAttributes = {
	-- DEGREES of yaw from the root part's own facing to the hull's bow. The escape hatch for "my boat
	-- sails stern-first": set 180 and it does not. Unlike every other entry here this one is SIGNED and
	-- 0 is a meaningful value, so it is read by its own resolver rather than the positive-only one.
	ForwardYaw = "BoatForwardYaw",
	HullSpeed = "BoatHullSpeed",
	TurnRate = "BoatTurnRate",
	-- The one override most hulls actually need, because it depends entirely on where the artist put
	-- the model's largest part -- see Drive.WaterlineOffset.
	WaterlineOffset = "BoatWaterlineOffset",
	-- How much this hull is pushed bodily downwind. A shallow-draught skiff makes far more leeway than
	-- a deep-keeled trader, and this is the only knob that expresses that.
	LeewayFraction = "BoatLeeway",
}

-- Default handling. Every number here is chosen so a boat reads as a large displacement hull being
-- persuaded rather than a vehicle being driven -- which is also what makes a server-authoritative drive
-- (one input round trip of latency, see BoatSystem.lua's header) imperceptible: the acceleration ramps
-- below are an order of magnitude longer than the ping they hide.
BoatConstants.Drive = {
	-- Studs/second with full canvas, in a full wind, on the best point of sail -- the ceiling, and a
	-- speed a hull only reaches when the player has actually earned it by finding a reach. A walking
	-- player is 16 and a full-gear runner is 81, so a well-sailed boat outruns a runner and a badly
	-- sailed one does not, which is the right shape for a vehicle whose skill floor is "read the wind".
	HullSpeed = 62,
	-- Studs/second with the sails backed. Deliberately feeble: backing a square sail is how you get off
	-- a beach or out of a berth, not a way to travel. A symmetric astern would make the helm feel like
	-- a twin-stick controller, which is the same argument BlimpConstants.Drive.ReverseSpeed makes.
	SternwaySpeed = 14,
	-- Studs/second^2 toward the commanded speed. Against HullSpeed this is a ~7 second run-up to full
	-- -- longer than a blimp's, because canvas fills and a hull's mass has to be persuaded through
	-- water rather than air.
	Acceleration = 9,
	-- Studs/second^2 shed when the commanded speed is BELOW the current one -- see
	-- BoatTypes.DriveTuning.Deceleration. Lower than Acceleration on purpose: there is no brake on a
	-- sailing hull, and the ~12 seconds it takes to carry her way off from full is the single most
	-- boat-like number in this file. Do not "fix" a boat that will not stop by raising this; that IS
	-- the vehicle.
	Deceleration = 5,
	-- Radians/second at full steer AND full rudder authority. ~11.4 seconds for a full circle, half
	-- again as long as a blimp's, and still short enough that a player can dodge a rock they saw.
	TurnRate = 0.55,
	TurnAcceleration = 1.1,
	-- A RUDDER IS A WING IN A MOVING FLUID -- with no water flowing past it, it does almost nothing.
	-- Authority ramps linearly from MinRudderAuthority at a standstill to 1 at
	-- RudderAuthorityFullAtSpeedFraction of HullSpeed.
	--
	-- THIS IS THE SINGLE MOST IMPORTANT NUMBER FOR WHETHER THIS READS AS A BOAT. Without it a hull
	-- pirouettes on the spot, which no vessel does and which quietly deletes the whole reason to keep
	-- way on through a turn. The floor is not zero because a hull with literally no steerage is one a
	-- player cannot recover from a beaching with -- backing off a shoal needs a little rudder at
	-- almost no speed.
	MinRudderAuthority = 0.06,
	RudderAuthorityFullAtSpeedFraction = 0.45,
	-- Studs of sideways slip per stud/second of speed, at full press -- i.e. hard on the wind. Scaled
	-- down toward zero as the wind comes aft, because a boat running downwind is being pushed the way
	-- she is already going.
	--
	-- Small on purpose. Leeway is meant to be a thing a player notices when they try to hold a course
	-- close-hauled past a headland, not a thing that makes the boat feel like it is on ice.
	LeewayFraction = 0.16,
	-- Studs the hull's ROOT part sits above the water surface. The default assumes a root roughly
	-- amidships in a hull whose deck is a couple of studs above the waterline; a model built any other
	-- way sets BoatWaterlineOffset and is done.
	WaterlineOffset = 2,
	-- How fast the target's Y may chase a change in water level, and how fast that rate itself ramps.
	-- Ramped rather than snapped so a hull crossing from a river onto a lake at a different level rises
	-- to it over a beat instead of teleporting, and so the swell lifts her rather than jerking her.
	HeaveSpeed = 26,
	HeaveAcceleration = 55,
	-- Visible heel per radian/second of yaw and per unit of wind pressure, applied at PRESENTATION time
	-- only (see BoatTypes.DriveState on why the integrator's own Target stays upright).
	--
	-- THE WIND TERM IS THE ONE THAT SELLS IT. A blimp banks only when it turns; a boat under press of
	-- canvas leans away from the wind and STAYS leaning for as long as the sails are drawing, which is
	-- the silhouette everybody recognises. At the numbers below a full-sail beam reach heels ~17
	-- degrees and a hard turn adds ~12 more, inside a ceiling that keeps a passenger on the deck.
	HeelRadiansPerTurnRate = 0.38,
	HeelRadiansPerWindPressure = 0.30,
	MaxHeelRadians = 0.42,
	-- Visible bow-up trim per stud/second^2 of surge, and its ceiling. Small -- a hull squats a little
	-- as she gathers way and settles as she loses it, and anything more reads as a speedboat planing.
	TrimRadiansPerAccel = 0.02,
	MaxTrimRadians = 0.09,
	-- Studs the chase target may lead the hull's actual position by. See BoatDrive.ClampLead and
	-- BlimpDrive.lua's header for the debt-discharge problem this bounds; smaller than a blimp's
	-- because a boat is slower and a smaller lead is still invisible at these speeds.
	MaxLeadStuds = 60,
}

-- The sail rungs -- the boat's equivalent of an engine telegraph, and read by exactly the same
-- machinery (Shared/Boat/BoatSailLadder.lua binds Shared/Vessel/VesselSpeedLadder.lua to this table).
-- Nothing indexes this array by a literal number; the neutral rung is FOUND by its own zero fraction
-- rather than written down twice.
--
-- FIVE RUNGS, NOT A BLIMP'S EIGHT, and the difference is a real one rather than a shortcut. A
-- telegraph is the ONLY thing that sets an airship's speed, so it wants a fine ladder worth walking. A
-- boat's speed is already continuously modulated by the wind and by the angle she is holding to it --
-- the player is "steering the throttle" every second they are at the wheel -- so a fine sail ladder
-- would be a second continuous control shadowing one they already have. Five settings a sailor would
-- recognise say everything the rung actually needs to.
BoatConstants.SailStates = {
	{ Id = "Backed", Label = "SAILS BACKED", Throttle = -1 },
	{ Id = "Furled", Label = "FURLED", Throttle = 0 },
	{ Id = "Reefed", Label = "REEFED", Throttle = 0.45 },
	{ Id = "Working", Label = "WORKING SAIL", Throttle = 0.75 },
	{ Id = "Full", Label = "FULL SAIL", Throttle = 1 },
}

-- THE WIND. One wind for the whole map, and it is a pure function of the clock -- no state, no
-- replication, no per-boat weather. Shared/Boat/BoatWind.lua owns the arithmetic; these are its
-- numbers.
--
-- DETERMINISTIC RATHER THAN REPLICATED, which is the load-bearing decision in this table. The server
-- sails by this and every client draws its wind vane from it, both reading
-- Workspace:GetServerTimeNow() -- so the vane on a player's helm panel is not a value that was pushed
-- to them and might be stale, it is the same value the server used, computed independently and
-- arriving at the same answer. The alternative -- a WindUpdated remote -- would put a continuous
-- quantity on the wire forever to say something both ends can already work out, which is the exact
-- thing BlimpConstants.Network.RemoteNames.HelmUpdated's own header refuses.
--
-- IT WANDERS RATHER THAN JUMPING. Two sine terms at incommensurate periods, so the bearing never
-- repeats a pattern a player could memorise and never steps -- a wind that shifted discontinuously
-- would take a close-hauled boat into irons with no warning and no way to have read it coming.
BoatConstants.Wind = {
	-- Radians. The prevailing bearing -- the direction the wind blows FROM -- that the swings below are
	-- measured around. 0 is "from world -Z".
	BaseBearingRadians = 0,
	-- Radians either side of that. ~50 degrees of swing means a course that was a beam reach an hour
	-- ago may be close-hauled now, which is enough to make the wind a thing worth watching and far
	-- short of enough to make a plotted passage impossible.
	SwingRadians = 0.9,
	-- Seconds. The two periods are deliberately not multiples of one another, so their sum never
	-- repeats on either one's beat.
	SwingPeriodSeconds = 214,
	SwingSecondaryPeriodSeconds = 79,
	-- Relative weight of the faster of those two terms. Small, so the wind's shape is the slow swing
	-- with a wobble on it, rather than two swings a player cannot separate.
	SwingSecondaryWeight = 0.32,
	-- Strength floor and ceiling, both 0..1. THE FLOOR IS NOT ZERO ON PURPOSE: a flat calm is a boat
	-- nobody can move, for a minute and a half, with no explanation on screen and nothing the player
	-- can do -- which is indistinguishable from the vehicle being broken. A slow wind is a worse
	-- passage; no wind is a bug report.
	MinStrength = 0.45,
	MaxStrength = 1,
	GustPeriodSeconds = 47,
	GustSecondaryPeriodSeconds = 17,
	GustSecondaryWeight = 0.4,

	-- THE POLAR. How much of HullSpeed a hull makes at a given angle off the wind, and the whole reason
	-- sailing is a skill here. Angles are the absolute value of the signed bearing from the bow to the
	-- wind's source, so 0 is dead into it and pi is dead astern.
	--
	-- Inside NoGoRadians the sails luff and drive is EXACTLY zero, however much canvas is set. That
	-- hard zero is deliberate rather than a steep falloff: "in irons" has to be a state a player can
	-- name and recognise, and a boat that crawls forward at 4% while pointing at the wind teaches
	-- nobody anything.
	NoGoRadians = 0.73, -- ~42 degrees
	-- Where the polar peaks -- a broad beam reach. Real, not invented: a fore-and-aft rig is fastest
	-- with the wind a little abaft the beam.
	PeakRadians = 1.83, -- ~105 degrees
	-- What is left dead downwind. Below 1 because the sails blanket one another and because apparent
	-- wind falls off with your own speed when you run before it -- which is also why "just point
	-- downwind" is not the answer to everything.
	RunningEfficiency = 0.72,

	-- The band edges the five POINT-OF-SAIL NAMES are read off, as absolute angles off the wind. Names
	-- only: BoatWind.Efficiency never reads these, and the speed curve above never reads them either, so
	-- moving one changes what the helm panel CALLS a heading and changes nothing about how the hull
	-- sails.
	--
	-- WRITTEN OUT RATHER THAN DERIVED FROM NoGoRadians/PeakRadians, even though a first pass did derive
	-- them (midpoints and offsets) and it looked tidier. The tidiness is a trap: it silently couples the
	-- WORDS on a player's panel to a retune of the physics, so nudging the polar's peak by five degrees
	-- would quietly re-label a heading the player had learned to recognise. Two things that happen to
	-- have similar numbers are still two things. src/Tests/Boat/BoatWind.spec.lua pins them in order and
	-- pins Peak inside the beam-reach band, which is the actual invariant worth enforcing.
	CloseHauledMaxRadians = 1.27, -- ~73 degrees
	BeamReachMaxRadians = 2.09, -- ~120 degrees
	BroadReachMaxRadians = 2.71, -- ~155 degrees
}

-- Sails held with nobody at the wheel -- the boat's Adrift mode, and the exact analogue of a blimp's
-- autopilot (BlimpConstants.Autopilot). Read that table's header for the full argument; it holds here
-- word for word, including the safety half.
--
-- WHAT IT IS NOT: a course computer. It holds the SAIL SETTING, not a destination -- the hull keeps its
-- current heading because BoatDrive.Step's yaw rate decays to zero on a neutral rudder all by itself,
-- not because anything is steering. That is the whole feature: a skipper sets working sail, leaves the
-- wheel, and goes forward while the ship keeps sailing.
--
-- AND IT ENDS THE MOMENT THE SHIP IS EMPTY. The instant the last person steps off, the sails are furled
-- and the latch dropped (Server/Systems/BoatSystem.Dismount), so the hull carries her way off and lies
-- there. Only after the window below is she formally Anchored. Stopping is what a player means by "I'm
-- getting off"; anchoring is a separate decision the ship makes later, on its own, once nobody has come
-- back for it.
BoatConstants.Adrift = {
	-- Seconds the hull lies unoccupied -- no pilot AND no passengers -- before she is called Anchored.
	-- Long enough that a skipper who dies at the wheel and swims back finds their boat where they left
	-- it; short enough that an abandoned one has visibly settled by the time the next player walks past.
	AbandonGraceSeconds = 8,
}

-- Running aground. Reached whenever the water probe finds no tagged plane under the hull, from any
-- mode, and left again the moment one appears.
--
-- NOT A PUNISHMENT AND NOT A DEATH. A beached boat keeps her rudder (at MinRudderAuthority) and keeps
-- her sternway, so backing off a shoal is a thing a player does in a few seconds by ringing the sails
-- to Backed. The only thing refused is FORWARD drive, which is the one input that would otherwise let a
-- player push the hull further up the beach and strand it somewhere with no water behind it either.
BoatConstants.Beaching = {
	-- Studs/second^2 of extra deceleration applied on top of Drive.Deceleration while beached, as a
	-- multiple of it. A hull that hits shore does not coast for twelve seconds.
	DecelerationMultiple = 4,
	-- Studs the hull's target Y is held above the LAST known waterline while beached. Zero: she stays at
	-- the height the water left her at rather than sinking, which is what a grounded hull does.
	--
	-- Written down rather than left implicit because the alternative -- letting the target Y follow
	-- nothing -- is what a first implementation does, and it drops the hull through the map.
	HeldWaterlineOffsetStuds = 0,
}

-- The swell. Deterministic from world position and Workspace:GetServerTimeNow(), for exactly the same
-- reason the wind is: the server lifts the hull by it and every client's camera reads the result off
-- the hull's own replicated motion, so there is nothing to send. Shared/Boat/BoatWaterMath.lua owns the
-- arithmetic.
--
-- TWO CROSSED WAVES, NOT ONE. A single sine is instantly readable as a sine -- the hull pitches on a
-- perfect metronome and the sea looks like corrugated iron. Two at different wavelengths, periods and
-- headings beat against each other into something that never quite repeats, which is what an open sea
-- does, for the cost of one extra sin() per sample.
BoatConstants.Swell = {
	-- Studs of vertical amplitude, and studs between crests, for the primary train.
	Amplitude = 1.6,
	WavelengthStuds = 90,
	PeriodSeconds = 5.5,
	-- Radians. The primary train's heading, as a world yaw.
	HeadingRadians = 0.4,
	-- The secondary train. Shorter, faster, smaller, and crossing the primary at a wide angle.
	CrossAmplitude = 0.85,
	CrossWavelengthStuds = 143,
	CrossPeriodSeconds = 8.2,
	CrossHeadingRadians = 1.42,
	-- Radians of hull pitch/roll per unit of surface SLOPE (dY/dStud) under her. 1 would lay the hull
	-- exactly along the water's surface, which is right for a raft and far too much for a boat with a
	-- keel -- a real hull's inertia means she does not follow every wavelet.
	TiltPerSlope = 0.55,
	MaxTiltRadians = 0.16,
}

-- The physics drive itself. See Server/Vessel/VesselAssembly.lua for why these are mass-scaled rather
-- than absolute: the same tag has to sail a model whose mass nobody has told this file about.
BoatConstants.Physics = {
	-- MaxForce as a multiple of (assembly mass * workspace.Gravity). Lower than a blimp's 14 because a
	-- boat is not holding herself up against gravity -- the constraint's vertical job is only to keep
	-- her sitting on a surface that is already there, not to levitate several tonnes indefinitely.
	ForceGravityMultiple = 9,
	-- MaxTorque as a multiple of (assembly mass * gravity). Swinging a long hull round needs a great
	-- deal more than moving it does, hence the two-order-of-magnitude gap -- the same shape a blimp's
	-- pair has, for the same reason.
	TorqueGravityMultiple = 200,
	-- AlignPosition/AlignOrientation Responsiveness. Low on purpose: this IS the weight. Raising it
	-- toward the 200 ceiling makes the boat track its target rigidly and stop reading as having mass.
	-- Slightly lower than a blimp's, because a boat is slower and can afford to trail its target
	-- further before that reads as lag rather than as inertia.
	PositionResponsiveness = 28,
	OrientationResponsiveness = 16,
	-- Every non-root BasePart in the assembly is made Massless so the assembly's mass -- and therefore
	-- every force above -- depends only on the root part, not on how many deck fittings the artist added
	-- last week. Set false only if a hull genuinely needs authored mass distribution.
	MasslessNonRootParts = true,
	-- Studs/second. AlignPosition.MaxVelocity -- the hard ceiling on how fast this constraint may ever
	-- move the hull while closing a position error, independent of how large that error is. Sized well
	-- clear of HullSpeed so ordinary sailing never touches it, and tight enough that a Drive.MaxLeadStuds
	-- -sized debt closes in about half a second rather than as a snap.
	MaxDriveVelocity = 110,
}

-- Safety nets that protect something OTHER than the hull itself. Kept as its own table rather than
-- folded into Physics above because it is conceptually a different kind of number: everything in
-- Physics tunes how the HULL moves, this tunes how fast something ELSE may leave after touching it.
-- See Shared/Vessel/VesselSafety.lua's own header for the mechanism this defends against.
BoatConstants.Safety = {
	-- Studs/second. Ceiling on a PLAYER's own velocity while they are in contact with any part of a boat
	-- hull.
	--
	-- DELIBERATELY THE SAME NUMBER AS BlimpConstants.Safety.MaxContactSpeed AND
	-- ParkourConstants.Validation.MaxTravelSpeed, and not a new one invented for this file: that
	-- constant is already this codebase's authored answer to "the fastest a player's velocity could
	-- plausibly, legitimately be". Three copies of one number is worse than one, but a cross-require
	-- from a standalone vehicle module into Parkour's constants is worse still -- so
	-- src/Tests/Boat/BoatSafety.spec.lua pins all three to the same value instead, which is what forces
	-- a future retune of one to look at the others.
	MaxContactSpeed = 180,
}

-- The ProximityPrompt each station carries. See BoatSystem.lua's header for why a native prompt is the
-- one place a Roblox built-in beat rolling it against KeybindManager.
BoatConstants.Prompt = {
	StationPromptName = "BoatStationPrompt",
	HelmActionText = "Take the Helm",
	HandholdActionText = "Hold On",
	HelmObjectText = "Boat",
	HandholdObjectText = "Boat",
	-- Studs. Roughly arm's reach plus a step -- close enough that a player standing at the wheel gets it
	-- and one walking past on the deck does not.
	MaxActivationDistance = 10,
	-- A tap, not a hold. A hold duration is what you use to stop an accidental press being costly, and
	-- mounting is instantly reversible with the same key.
	HoldDuration = 0,
	-- False, for the reason a blimp's is: a helm on a boat with rigging, a mast and a deckhouse in front
	-- of it fails a line-of-sight test from perfectly reasonable standing positions, and a prompt that
	-- flickers as a player walks round their own boat reads as broken.
	RequiresLineOfSight = false,
}

BoatConstants.Mount = {
	-- Studs from the station part's centre to the mounted body, when there is no Stand Attachment to say
	-- otherwise. WHICH SIDE is not a constant -- VesselTagging.ResolveStandOffset picks it.
	DefaultStandReach = 2.5,
	-- Seconds between stale-mount sweeps. A mounted player who stops being reachable (their character is
	-- destroyed out from under the weld, the boat is deleted under them) is released by the sweep rather
	-- than left welded to a corpse.
	StaleSweepSeconds = 1,
	-- Studs the released character is lifted before their body is handed back, so a dismount inside the
	-- station part's own volume does not spawn them intersecting it and get them flung.
	ReleaseClearance = 1.5,
	-- Studs/second a released body may be carrying OVER the hull's own current speed. A MARGIN, not a
	-- ceiling -- see Shared/Vessel/VesselMount.ReleaseSpeedCeiling and
	-- BlimpConstants.Mount.ReleaseSpeedMargin's own header for why anchoring to the hull's speed is the
	-- only formulation that is right at both ends of the range.
	ReleaseSpeedMargin = 24,
	-- Seconds after a release during which the tick keeps re-applying that same clamp, covering the
	-- velocity Roblox's own depenetration solver can hand a body one step after it stops being part of
	-- the hull's assembly.
	ReleaseSettleSeconds = 0.75,
}

-- Arm placement. See Shared/Vessel/VesselArmPose.lua for the solver these feed. Identical to a blimp's,
-- and deliberately so: the numbers describe a pair of human arms on a ship's wheel, which is the same
-- object in both cases.
BoatConstants.Pose = {
	FallbackGripHalfWidth = 0.9,
	FallbackGripMaxHalfWidth = 1.6,
	ElbowPoleSign = 1,
	MaxReachFraction = 0.98,
}

-- The mounted body's own lean (Shared/Vessel/VesselPilotPose.lua). Read that file's header and
-- BlimpConstants.Lean's; the two channels and their opposite signs are the same here.
--
-- STRONGER THAN A BLIMP'S ON BOTH CHANNELS, because the deck under the body is doing more. A blimp's
-- crew stand on a floor that banks only when the pilot turns; a boat's stand on one that is heeled
-- under press of sail and lifting on every swell, and a body that stayed vertical through that would
-- read as glued down.
BoatConstants.Lean = {
	RollRadiansPerYawRate = 0.9,
	MaxRollRadians = 0.32,
	PitchRadiansPerAccel = -0.02,
	MaxPitchRadians = 0.24,
	-- The third channel is the hull's HEAVE rate here rather than a commanded climb -- see
	-- Shared/Vessel/VesselPilotPose.Config.PitchRadiansPerClimbRate. Larger than a blimp's coefficient
	-- against a much smaller input: a swell lifts a hull by a stud or two per second, where an airship
	-- climbs at fifty.
	PitchRadiansPerClimbRate = -0.02,
	Stiffness = 11,
	Damping = 0.9,
	HeadCounterFraction = 0.4,
	SwayStuds = 0.22,
}

-- The wake FX gate. One number, and it is a SPEED FRACTION rather than a mode test on purpose: a hull
-- that has lost way but is still nominally Piloted should not be throwing spray, and one carrying her
-- way off after the sails came in should, right up until she actually stops.
BoatConstants.Wake = {
	-- Fraction of HullSpeed above which the tagged emitters run. Low: a boat leaves a visible wake at a
	-- walking pace.
	MinSpeedFraction = 0.12,
}

-- The pilot's/passenger's own camera while aboard (Client/Camera/BoatCamera.lua). PRESENTATION ONLY --
-- nothing here reaches a single gameplay outcome.
--
-- EVERY CHANNEL IS A SPRING, NOT AN EASE, for the reason BlimpConstants.Camera's own header gives at
-- length: a camera aboard a heavy thing being pushed around should OVERSHOOT and settle. Damping below
-- 1 is what buys that.
--
-- The input is the HULL'S OWN PHYSICS, read locally off the assembly's replicated velocities every
-- frame -- never a number the server sent.
BoatConstants.Camera = {
	Smoothing = {
		VelocityEaseSpeed = 12,
		-- Slower than the velocity filter on purpose -- acceleration is a difference of an already-noisy
		-- signal, so it is the noisiest thing here and the one a player is least able to see directly.
		AccelEaseSpeed = 5,
	},
	Roll = {
		-- Radians of view roll per radian/second of hull yaw rate, and the ceiling on it. SMALLER than
		-- the body's own lean coefficient (Lean.RollRadiansPerYawRate) on purpose: the person leans
		-- further than the view does, so a player watching another player sees the lean, and a player
		-- looking through their own eyes is not made seasick by it.
		RadiansPerYawRate = 0.3,
		MaxRadians = 0.16,
		Stiffness = 7,
		Damping = 0.62,
	},
	Bob = {
		-- Studs of vertical camera travel per stud/second of hull heave. Sub-unity: the head damps the
		-- deck, it does not follow it.
		StudsPerHeaveRate = 0.05,
		MaxStuds = 0.7,
		Stiffness = 9,
		Damping = 0.7,
	},
	Lead = {
		-- Studs the view slides aft under acceleration, per stud/second^2 of surge -- the sense of being
		-- left behind as she gathers way.
		StudsPerAccel = 0.08,
		MaxStuds = 1.4,
		Stiffness = 6,
		Damping = 0.66,
	},
	-- The one-shot the view takes when the sail rung moves, so ringing on more canvas is felt rather
	-- than only read off a gauge. Applied as an impulse into the Lead spring's velocity.
	Kick = {
		StudsPerRung = 0.35,
	},
}

-- Sound.
--
-- AUTHORED AHEAD OF ITS CONSUMER, and said out loud rather than left to be discovered: there is no
-- Client/FX/BoatAudio.lua yet, so nothing reads Stages below today. Smoothing IS live -- it is what
-- Shared/Boat/BoatMotion.lua binds, and every mounted body's lean is filtered through it.
--
-- Kept here rather than deleted for the same reason BlimpConstants.Drive.NitrousSpeed is: the three
-- bands and their names are a design decision somebody made, and the alternative to writing them down
-- is re-guessing them from scratch the day there are sounds to play. Wiring them up is one file --
-- `VesselSpeedStage.New(BoatConstants.Audio.Stages, BoatConstants.Audio.StageHysteresis)` -- plus a
-- call from Client/Boat/BoatController.applyPoses, which already takes the per-frame speed sample an
-- audio module would need. A bound-but-unread module written NOW would be an orphan, which this
-- codebase's CLAUDE.md is explicit about not shipping.
BoatConstants.Audio = {
	-- The three speed bands. EnterFraction is a fraction of this hull's own HullSpeed; the first
	-- stage's is 0 by definition, and the dead band between them is StageHysteresis below -- see
	-- Shared/Vessel/VesselSpeedStage.lua's header on why that band is the whole of that module.
	Stages = {
		{
			Id = "Lying",
			Label = "LYING TO",
			EnterFraction = 0,
			PlaybackSpeed = 0.85,
			LoopVolumeScale = 0.35,
			LoopSpeedScale = 0.8,
		},
		{
			Id = "Making",
			Label = "MAKING WAY",
			EnterFraction = 0.3,
			PlaybackSpeed = 1,
			LoopVolumeScale = 0.8,
			LoopSpeedScale = 1,
		},
		{
			Id = "Driving",
			Label = "DRIVING",
			EnterFraction = 0.72,
			PlaybackSpeed = 1.15,
			LoopVolumeScale = 1,
			LoopSpeedScale = 1.2,
		},
	},
	StageHysteresis = 0.06,
}

BoatConstants.Controls = {
	-- THE LEFT STICK IS THE RUDDER AND THE FACE BUTTONS ARE THE SAIL ORDERS, which is
	-- BlimpConstants.Controls' own split with one axis removed -- read that table's header for the full
	-- argument, all of which holds here.
	--
	-- DELIBERATELY THE SAME KEYS AS A BLIMP'S, minus the Lift row a boat has no use for. A player who
	-- has sailed one vehicle in this game has sailed them all, and inventing a second scheme for the
	-- second vehicle would be a second thing to learn for no gain at all. The one thing that changes is
	-- what the keys MEAN: W/S move canvas rather than speed, and X furls rather than ringing All Stop.
	--
	-- Space and LeftShift are now free at a helm and are deliberately left free rather than spent. A
	-- boat may yet want an anchor, a sounding lead or a spyglass, and a scheme with no headroom is one
	-- where the next control has to displace an existing one.
	Steer = {
		Positive = Enum.KeyCode.D,
		Negative = Enum.KeyCode.A,
		Gamepad = Enum.KeyCode.Thumbstick1,
	} :: VesselTypes.HelmAxisBinding,

	-- ButtonY is the TOP of the face diamond and ButtonA is the BOTTOM, so more canvas is up and less is
	-- down, both under one thumb.
	--
	-- ButtonA CARRIES THE SAME SCOPED EXEMPTION IT DOES ON A BLIMP, and for exactly the same two
	-- reasons -- read BlimpConstants.Controls' own paragraph on it. Both halves apply here unchanged:
	-- VesselMount.Attach sets Humanoid.PlatformStand (so the native jump is suspended), and Roblox
	-- marks every ButtonA press gameProcessedEvent = true unconditionally, so BoatController's
	-- onInputBegan must NOT drop this input on that flag. Tests/Boat/BoatHelmControls.spec.lua pins it.
	SailUp = { Keyboard = Enum.KeyCode.W, Gamepad = Enum.KeyCode.ButtonY } :: VesselTypes.HelmPressBinding,
	SailDown = { Keyboard = Enum.KeyCode.S, Gamepad = Enum.KeyCode.ButtonA } :: VesselTypes.HelmPressBinding,
	-- B/Circle is the near-universal cancel, which is what furling is: the panic press that takes every
	-- sail off her from wherever the rung was.
	Furl = { Keyboard = Enum.KeyCode.X, Gamepad = Enum.KeyCode.ButtonB } :: VesselTypes.HelmPressBinding,
	-- A MODE TOGGLE, so it can afford the one control here that takes a thumb off the stick -- a player
	-- picks the moment they leave the wheel, they do not pick the moment they need rudder.
	Adrift = { Keyboard = Enum.KeyCode.G, Gamepad = Enum.KeyCode.DPadLeft } :: VesselTypes.HelmPressBinding,
	-- THE ONE ROW WITH AN Action INSTEAD OF A KEYBOARD KEY: the release shares the rebindable Interact
	-- bind with the prompt that started the mount. ButtonX rather than Interact's own pad chord, because
	-- that is the button that put the player here (a ProximityPrompt's GamepadKeyCode defaults to
	-- ButtonX) and because asking for a two-finger gesture to get off a ship heading out to sea is the
	-- wrong place to spend a chord.
	Release = { Action = "Interact", Gamepad = Enum.KeyCode.ButtonX } :: VesselTypes.HelmPressBinding,
}

-- Helm input feel, read only by Client/Boat/BoatController.lua. Same three numbers, same reasoning, as
-- BlimpConstants.Input -- read that table for why the repeat has an initial delay and why the axis
-- epsilon is a resolution rather than a deadzone.
BoatConstants.Input = {
	SailRepeatDelaySeconds = 0.38,
	-- Slower than a blimp's, because the ladder is shorter: against five rungs this is still under a
	-- second end to end, and a slower step is easier to let go of on the rung you meant.
	SailRepeatIntervalSeconds = 0.22,
	HelmAxisEpsilon = 0.02,
}

BoatConstants.Network = {
	RemoteNames = {
		-- Client -> server. The pilot's ONE held axis -- the rudder -- at IntentSendHz. Named Set rather
		-- than Request because it carries no action to approve: the server clamps it and integrates it,
		-- and a non-pilot firing it is dropped at the gate.
		SetHelmInput = "Boat_SetHelmInput",
		-- Client -> server, from the pilot only. Moves the sail setting by a signed number of rungs
		-- (VesselSpeedLadder.Shift clamps it), or -- with a delta of 0 -- furls outright.
		--
		-- A DELTA RATHER THAN AN ABSOLUTE INDEX: a rung index is a claim about a ladder whose length the
		-- client only knows because it read the same constants file, and the day a hull gets a bespoke
		-- rig that stops being true silently. A delta is a claim about a KEYPRESS, which is the only
		-- thing the client actually witnessed.
		ShiftSailState = "Boat_ShiftSailState",
		-- Client -> server, from the pilot only. Arms/disarms the Adrift latch. Its own remote rather
		-- than a field on SetHelmInput because it is an EDGE, and an edge riding on a 15Hz state stream
		-- is a press that can be missed or, worse, applied twice.
		ToggleAdrift = "Boat_ToggleAdrift",
		-- Client -> server. Leave the station. Its own remote rather than a second ProximityPrompt: the
		-- prompt on an occupied station is disabled precisely so a passing player never sees a live
		-- "Take the Helm" on a wheel someone is holding.
		RequestDismount = "Boat_RequestDismount",
		-- Server -> ALL clients. Someone mounted or dismounted; carries VesselTypes.MountChangedPayload.
		MountChanged = "Boat_MountChanged",
		-- Server -> EVERY player currently aboard one hull (FireClient per occupant, never a broadcast).
		-- BoatTypes.HelmUpdatedPayload: the hull mode, the sail rung, and whether Adrift is armed.
		--
		-- PASSENGERS GET IT TOO. "We are beached" and "she is sailing herself" are the SHIP's state, and
		-- a passenger who cannot see them has no way to tell a deliberate manoeuvre from the skipper
		-- having died at the wheel.
		--
		-- CARRIES ONLY DISCRETE STATE -- no speed, no heading, AND NO WIND. The first two are continuous
		-- and every client aboard already reads them for free off the hull's own replicated velocity to
		-- drive the camera. The wind is the more interesting omission: it is continuous AND it is not on
		-- the hull, so it looks like the one thing that has to be pushed -- and it does not, because
		-- BoatConstants.Wind is a deterministic function of Workspace:GetServerTimeNow() that both ends
		-- evaluate independently to the same answer. See that table's own header. Pushing it would be
		-- paying network, forever, for a number the receiver can already compute.
		HelmUpdated = "Boat_HelmUpdated",
	},
	-- How often the pilot client pushes its axis. 15/s is far more than a vehicle this slow needs, and an
	-- order of magnitude below the rate limit below, so a pilot on a bad connection degrades to coarser
	-- steering rather than to rejected input.
	IntentSendHz = 15,
	-- Per-player-per-second budgets. Separate buckets, not one, for the same reason EmoteSystem keeps
	-- its play and loadout limits apart: a steering stream must never be able to eat the dismount press
	-- that gets a player off a boat heading out to sea.
	MaxIntentPerSecond = 30,
	MaxDismountPerSecond = 4,
	MaxSailShiftPerSecond = 12,
	MaxAdriftTogglePerSecond = 4,
}

return BoatConstants
