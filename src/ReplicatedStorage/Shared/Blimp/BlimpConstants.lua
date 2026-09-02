--!strict
--[[
	BlimpConstants.lua

	Owns: the Blimp layer's whole authoring contract and its tunables -- the CollectionService tags a
	builder puts on a Model in Studio, the per-model Attribute overrides that let one blimp differ from
	another without a code change, the Attachment names that pin hands and feet to authored points, the
	remote names, and the default flight numbers.

	A STANDALONE MODULE, not a Constants.Blimp section, following the precedent Constants.lua's own
	header sets out for exactly this case (Combat and Flight both left it for the same reason): this is
	one system's own tuning surface, and it is read by a Server System, two Server sub-modules and a
	Client controller, none of which should have to require the whole cross-system registry to learn how
	fast a blimp turns.

	THE AUTHORING CONTRACT, in full -- everything a builder does in Studio, and nothing else:

	  1. Tag the blimp MODEL with "Blimp".                                (required)
	  2. Tag one BasePart inside it with "BlimpHelm" -- the wheel.        (required for a pilot)
	  3. Tag any number of parts with "BlimpHandhold" -- rails, ropes.    (optional, passengers)
	  4. Tag the exhaust housing with "BlimpExhaust" -- its emitters       (optional, thrust FX)
	     burn while the pilot is under power.
	  5. On a station, add an Attachment named "Stand" -- the pilot stands  (optional, exact placement)
	     there, facing its LookVector.
	  6. On a station part, add Attachments named "LeftGrip"/"RightGrip".  (optional, exact hand placement)
	  7. On the model, set any of the BlimpCruiseSpeed/... Attributes.     (optional, per-blimp tuning)

	THE BOW IS WHEREVER THE PILOT FACES -- there is no separate "which way is forward" to author, and that
	is a deliberate collapse rather than an omission. The first version of this system derived the pilot's
	side from the helm part's Z axis and the hull's forward from the root mesh's, independently; both are
	arbitrary modelling artefacts, so it shipped a blimp whose pilot stood on the wrong side of the wheel
	AND flew backwards, and those read as two unrelated bugs when they were one bug twice. Now the default
	stand side is DETECTED (BlimpTagging.ResolveStandOffset takes the side with deck under it, and where a
	deck runs both sides of the fitting, the side nearer the hull's centre -- so the pilot stands on the
	ship and looks out over the wheel) and the bow follows from it, so the common case needs no authoring
	at all and the uncommon case is fixed by adding one Attachment.

	The escape hatch, if a hull still flies the wrong way: the BlimpForwardYaw Attribute below, in degrees.

	Nothing else is required and no part needs a particular name -- the same "tags and attributes, never
	hardcoded object names" requirement Shared/Parkour/ParkourTagging.lua's header quotes from the design
	doc. A model with no grip Attachments still works: BlimpArmPose falls back to two points derived from
	the station part's own size, which is right for a plain railing and merely approximate for a detailed
	wheel -- which is exactly when a builder should add the Attachments.

	Does not own: how the tags are RESOLVED (BlimpTagging.lua -- the ancestor walk and the model/station
	pairing live there), the flight integration (Server/Blimp/BlimpDrive.lua), or the mount rules
	(Server/Systems/BlimpSystem.lua).
]]

-- The ONE require this otherwise standalone file makes, and only for the two Controls shapes below.
-- The alternative -- naming those shapes here -- would put a Blimp-layer type somewhere other than the
-- file whose whole job is Blimp-layer types. It also buys a real check rather than only tidiness:
-- Release names a Types.KeybindAction, and the annotation is what makes a typo there a type error
-- instead of a legend that silently reads "Unbound" and a press that silently never matches.
local BlimpTypes = require(script.Parent.BlimpTypes)

local BlimpConstants = {}

-- CollectionService tag names. Unlike ParkourTagging's set these have no Attribute twin: a parkour tag
-- answers "may I do X to this surface", which a designer wants to flip from the Properties panel on one
-- part, whereas these answer "is this object a blimp / a helm" -- a structural fact about the build, set
-- once, and much better served by the Tag Editor's bulk selection than by individually-typed booleans.
BlimpConstants.Tags = {
	-- On the MODEL. Everything inside it becomes one welded, driven body -- see BlimpAssembly.lua.
	Model = "Blimp",
	-- On ONE BasePart inside a tagged model. The pilot's station: mounting here hands this player the
	-- blimp's steering until they dismount. A model with two helms is a build error, not a two-pilot
	-- feature -- BlimpTagging.ResolveStations logs it and keeps the first.
	Helm = "BlimpHelm",
	-- On any number of BaseParts inside a tagged model. A passenger's station: welds and poses exactly
	-- like the helm, feeds no steering.
	Handhold = "BlimpHandhold",
	-- On any number of BaseParts inside a tagged model -- the exhaust/thruster housings. EVERY
	-- ParticleEmitter beneath a tagged part runs while the pilot is calling for forward thrust and stops
	-- when they let go.
	--
	-- A TAG RATHER THAN "every emitter in the model" because those are not the same set and the
	-- difference is invisible until it bites: a blimp with an ambient smoke plume off the furnace, or
	-- dust motes in the gondola, would have them cut out every time the pilot eased off the throttle.
	-- The tag says which emitters are THRUST, which is a thing only the builder knows.
	Exhaust = "BlimpExhaust",
	-- On ONE BasePart inside a tagged model -- the furnace, where BOTH coal and water are loaded in a
	-- single interaction. Deliberately ONE tag, not a separate furnace/water-tank pair -- the furnace
	-- and the water intake are one station on the hull, not two things a builder places side by side.
	-- Anyone nearby (not just the pilot) can walk up and deposit whatever they're carrying of EACH
	-- resource in one prompt press, and take it back out again at a second prompt on the same part
	-- (Prompt.UnloadActionText below) -- see Fuel below and Server/Systems/BlimpSystem.lua's
	-- depositFuel/unloadFuel.
	-- A model with no Furnace tag never gates on fuel at all (BlimpTagging.ResolveFuelStation's own
	-- contract) -- the same "absent tag, unlimited operation" fallback every other optional tag in
	-- this file already has.
	Furnace = "BlimpFurnace",
}

-- Optional Attachment names, looked up on a STATION part only. Each has a documented fallback, so a
-- blimp built without any of them still mounts correctly -- these exist to make a detailed model look
-- deliberate, not to make a plain one work.
BlimpConstants.Attachments = {
	-- Where the two hands are placed. Absent -> BlimpArmPose derives a symmetric pair from the station
	-- part's own size, along its widest horizontal axis.
	LeftGrip = "LeftGrip",
	RightGrip = "RightGrip",
	-- Where the mounted character's HumanoidRootPart is welded, and which way it faces. Absent ->
	-- BlimpConstants.Mount.Offset below, in the station part's own space.
	Stand = "Stand",
}

-- Per-model Attribute overrides. Set any of these on the tagged MODEL to give one blimp its own handling
-- without a second tag or a code change; unset falls through to Drive below. A cargo hauler and a scout
-- skiff are the same system with two Attribute sets.
BlimpConstants.ModelAttributes = {
	-- DEGREES of yaw from the root part's own facing to the hull's bow. The escape hatch for "my blimp
	-- flies backwards": set 180 and it does not. Unlike every other entry here this one is SIGNED and 0 is
	-- a meaningful value, so it is read by its own resolver rather than the positive-only one.
	ForwardYaw = "BlimpForwardYaw",
	CruiseSpeed = "BlimpCruiseSpeed",
	TurnRate = "BlimpTurnRate",
	ClimbSpeed = "BlimpClimbSpeed",
	MinAltitude = "BlimpMinAltitude",
	MaxAltitude = "BlimpMaxAltitude",
	-- Fuel (see the Fuel table below). Same "unset falls through to the shipped default" contract as
	-- every entry above -- a hull that only wants a bigger coal bin sets CoalCapacity and leaves the
	-- rest alone.
	CoalCapacity = "BlimpCoalCapacity",
	WaterCapacity = "BlimpWaterCapacity",
	CoalMinimum = "BlimpCoalMinimum",
	WaterMinimum = "BlimpWaterMinimum",
	CoalBurnRate = "BlimpCoalBurnRate",
	WaterBurnRate = "BlimpWaterBurnRate",
}

-- Default flight handling. Deliberately slow and heavily damped: every number here is chosen so the blimp
-- reads as a large mass being persuaded rather than a vehicle being driven, which is also what makes a
-- server-authoritative drive (one input round trip of latency -- see BlimpSystem.lua's header)
-- imperceptible. The acceleration ramps below are an order of magnitude longer than the ping they hide.
BlimpConstants.Drive = {
	-- Studs/second at full throttle. A walking player is 16; a blimp that outruns one on foot stops
	-- feeling like a blimp.
	CruiseSpeed = 110,
	-- Not read by BlimpDrive -- there is no nitrous system yet. This is the OLD CruiseSpeed, kept here as
	-- the number a future throttle-boost mechanic should chase, so that mechanic still tops out at the
	-- speed this hull was originally tuned and shipped at, rather than someone re-guessing a "fast" number
	-- from scratch. Wire it up by having that system feed BlimpDrive.Step a Tuning whose CruiseSpeed is
	-- this instead of the line above, not by adding a second axis to DriveIntent.
	NitrousSpeed = 130,
	-- Astern is deliberately a fraction of ahead -- an airship reverses by grumbling backwards, and a
	-- symmetric reverse makes the helm feel like a twin-stick controller.
	ReverseSpeed = 40,
	-- Studs/second^2 toward the commanded speed. Against CruiseSpeed this is a ~2.5s run-up to full ahead
	-- -- still long enough to feel like mass, short enough that leaving a dock is not a chore.
	Acceleration = 45,
	-- Radians/second at full steer. 0.8 is a ~8 second full circle: a pilot still commits to a turn, but
	-- at the cruise speed above a slower rate would make the turning CIRCLE enormous rather than making
	-- the blimp feel heavy -- past a point those two stop being the same knob.
	TurnRate = 0.8,
	TurnAcceleration = 1.6,
	ClimbSpeed = 55,
	ClimbAcceleration = 35,
	-- Visible roll per radian/second of yaw, applied at PRESENTATION time only (see BlimpTypes.DriveState
	-- on why the integrator's own Target stays upright). At the numbers above, a full-rate turn banks
	-- ~14 degrees -- readable from the deck, nowhere near enough to slide a passenger off it.
	BankRadiansPerTurnRate = 0.3,
	-- The altitude band the drive holds a blimp inside. The floor is what stops a pilot burying the hull
	-- in terrain and leaving the constraints to fight the ground forever; the ceiling is what stops a
	-- bored pilot leaving the map entirely with three passengers aboard.
	MinAltitude = 30,
	MaxAltitude = 900,
	-- Studs. The most `Target` (BlimpDrive's own integrator state) may lead the hull's ACTUAL position
	-- before Server/Systems/BlimpSystem.onHeartbeatTick claws it back via BlimpDrive.ClampLead. Step() has
	-- no way to know the hull has stopped moving -- see that file's header on why it must stay blind to
	-- the real CFrame -- so if something holds the hull still (a player wedged against it, a doorway, a
	-- stuck weld) Target keeps marching forward as though flight were unobstructed, and the gap between
	-- them is debt with no ceiling of its own. Sized well above the tracking lag CruiseSpeed and
	-- Physics.PositionResponsiveness already produce on a clean flight path (a few studs -- see that
	-- entry's own comment) so ordinary flight never touches this bound, and well below what even a couple
	-- of seconds of a dead stop would otherwise bank (CruiseSpeed studs of NEW debt every second, forever,
	-- until whatever is blocking the hull gives way).
	MaxLeadStuds = 100,
}

-- THE ENGINE TELEGRAPH -- the ordered ladder of throttle notches a pilot steps through, lowest (full
-- astern) at index 1 through to flank (the highest) at the end. Ahead and astern live on ONE ladder
-- rather than two, with All Stop as an ordinary rung in the middle, because that is what a telegraph
-- physically is and because it collapses "which direction am I going" and "how hard" into a single
-- number a gauge can draw and a single pair of keys can walk.
--
-- WHY THE THROTTLE IS NOTCHED AND STEERING IS NOT. A held key is the right input for something you
-- correct continuously and release the instant it is enough -- a rudder, an elevator. It is the wrong
-- input for a setting you choose and then leave for minutes at a time, which is exactly what an
-- airship's power is: a pilot picks half ahead and then stops thinking about it. Notches also give
-- Autopilot below something to LATCH -- "the speed the pilot left it at" is a rung, not a snapshot of
-- how hard somebody was leaning on W.
--
-- Throttle is fed to BlimpDrive.Step exactly as a held axis would be, so nothing in the integrator
-- knows this ladder exists -- see Server/Blimp/BlimpDrive.lua's own header on why it stays blind to
-- everything above it. Astern's own much lower ceiling is still Drive.ReverseSpeed's job, NOT this
-- table's: the -1 rung means "as hard astern as this hull goes", not "as fast as full ahead".
--
-- Flank is a real step above Full (1.0 against 0.85), not a duplicate top rung with a louder name --
-- a ladder whose last two rungs fly identically teaches a player the gauge is decoration.
--
-- Read by Shared/Blimp/BlimpSpeedLadder.lua (the resolver -- indices, clamping, the neutral rung) and
-- rendered by Client/UI/Screens/BlimpHelm. Nothing indexes this array by a literal number; the
-- neutral rung is FOUND by its own zero throttle rather than written down twice.
BlimpConstants.SpeedStates = {
	{ Id = "FullAstern", Label = "FULL ASTERN", Throttle = -1 },
	{ Id = "SlowAstern", Label = "SLOW ASTERN", Throttle = -0.5 },
	{ Id = "Stop", Label = "ALL STOP", Throttle = 0 },
	{ Id = "DeadSlow", Label = "DEAD SLOW", Throttle = 0.25 },
	{ Id = "Slow", Label = "SLOW AHEAD", Throttle = 0.45 },
	{ Id = "Half", Label = "HALF AHEAD", Throttle = 0.7 },
	{ Id = "Full", Label = "FULL AHEAD", Throttle = 0.85 },
	{ Id = "Flank", Label = "FLANK", Throttle = 1 },
}

-- Autopilot: the helm holds whatever rung the pilot left it on, with nobody standing there.
--
-- WHAT IT IS NOT: a course computer. It holds the TELEGRAPH, not a destination -- the hull keeps its
-- current heading because BlimpDrive.Step's yaw rate decays to zero on a neutral steer axis all by
-- itself, not because anything here is steering. That is the whole feature: a pilot sets half ahead,
-- engages it, and walks the deck to load coal while the ship keeps making way.
--
-- AND IT ENDS THE MOMENT THE SHIP IS EMPTY, which is the safety half. An armed autopilot with nobody
-- aboard is a runaway hull flying a straight line into the altitude band's own ceiling forever, and
-- the only thing that would ever stop it is a server restart.
--
-- THE SHIP STOPS FIRST AND SINKS LATER -- two distinct beats, not one. The instant the last person
-- steps off, the telegraph is rung down to All Stop and the autopilot latch is dropped
-- (Server/Systems/BlimpSystem.Dismount), so the hull coasts to a halt over its own deceleration ramp
-- and then HOVERS. Only after the window below does it begin to come down.
--
-- Those two used to be one beat -- the ship kept making way for the whole window and then started
-- descending -- and it was wrong in a way that is obvious the first time you do it: you step off onto
-- a dock and your ship sails away from you, still under power, for eight seconds. Stopping is the
-- thing a pilot means by "I'm getting off"; landing is a separate decision the ship makes later, on
-- its own, once nobody has come back for it.
BlimpConstants.Autopilot = {
	-- Seconds the hull hovers, stationary and unoccupied -- no pilot AND no passengers -- before the
	-- landing sequence begins. Long enough that a pilot who dies at the wheel and sprints back aboard
	-- finds their ship at the altitude they left it; short enough that an abandoned one is not still
	-- hanging over the map when the next player walks past it.
	AbandonGraceSeconds = 8,
}

-- The unattended landing. Reached only from BlimpFlightMode's own Landing mode -- a hull that has been
-- empty for Autopilot.AbandonGraceSeconds above -- and never from anything a player pressed.
--
-- THE FLOOR HAS TO MOVE FOR THIS TO WORK AT ALL. Drive.MinAltitude is an absolute world Y, and its
-- whole job is to stop a pilot burying the hull in terrain; a hull descending onto a mountain would
-- stop dead in mid-air at that altitude and hang there. So the landing hands BlimpDrive.Step a
-- per-tick floor derived from an actual downward raycast instead (see BlimpDrive.Step's own
-- floorOverride parameter and Server/Systems/BlimpSystem's probe) -- which is also the one and only
-- reason this system ever needs to know what is underneath a blimp.
BlimpConstants.Landing = {
	-- The commanded Lift axis while descending. Deliberately far short of -1: an abandoned ship should
	-- settle, not drop, and anyone who runs back and boards it mid-descent should be able to arrest it
	-- comfortably the moment they take the helm.
	DescentLiftAxis = -0.55,
	-- Studs of hull-centre clearance over whatever the probe found. This is the landed altitude, not a
	-- warning band -- the drive's floor is set to (groundY + this) and the hull simply comes to rest
	-- against it. Sized for a large hull's own half-height plus a gondola, so a moored blimp sits over
	-- the ground rather than inside it.
	TouchdownClearanceStuds = 14,
	-- Studs of slop above that clearance still counted as "resting on it". The hull chases its floor
	-- through a soft AlignPosition (Physics.PositionResponsiveness is low ON PURPOSE -- that is the
	-- floatiness), so it never actually settles AT the floor, it hovers a few studs over it forever.
	-- Without this the settle timer would reset every frame and a landed blimp would never once reach
	-- Grounded.
	TouchdownToleranceStuds = 5,
	-- Seconds resting at that floor before the hull is called Grounded. Not cosmetic: it is what stops
	-- a hull that clips the top of a tree on the way down from latching Grounded a hundred studs up.
	SettleSeconds = 2,
	-- How often the downward probe runs, and how far it looks. Deliberately NOT per-tick: a raycast per
	-- blimp per frame to answer a question that changes over seconds is exactly the kind of always-on
	-- cost Shared/AmortizedReclaim.lua's own header argues against, and the probe only runs for hulls
	-- that are actually unoccupied in the first place.
	ProbeIntervalSeconds = 0.4,
	ProbeDepthStuds = 2000,
}

-- The physics drive itself. See BlimpAssembly.lua for why these are mass-scaled rather than absolute: the
-- same tag has to fly a model whose mass nobody has told this file about.
BlimpConstants.Physics = {
	-- MaxForce as a multiple of (assembly mass * workspace.Gravity) -- i.e. how many times its own weight
	-- the drive may pull with. Must be comfortably above 1 or the blimp cannot hold altitude, let alone
	-- climb, once a few passengers are welded aboard.
	ForceGravityMultiple = 14,
	-- MaxTorque as a multiple of (assembly mass * gravity). Swinging a long hull round needs a great deal
	-- more than lifting it does, hence the two-order-of-magnitude gap.
	TorqueGravityMultiple = 220,
	-- AlignPosition/AlignOrientation Responsiveness. Low on purpose: this IS the floatiness. Raising it
	-- toward the 200 ceiling makes the blimp track its target rigidly and stop reading as having mass.
	-- Raised alongside the speed pass: at 130 studs/second a responsiveness of 12 leaves the hull trailing
	-- its own target by a visible margin, which stops reading as floatiness and starts reading as lag.
	PositionResponsiveness = 35,
	OrientationResponsiveness = 20,
	-- Every non-root BasePart in the assembly is made Massless so the assembly's mass -- and therefore
	-- every force above -- depends only on the root part, not on how many decorative meshes the artist
	-- added last week. Set false only if a blimp genuinely needs authored mass distribution.
	MasslessNonRootParts = true,
	-- Studs/second. AlignPosition.MaxVelocity -- the actual hard ceiling on how fast this constraint may
	-- ever move the hull while closing a position error, independent of how large that error is or how it
	-- got there. Drive.MaxLeadStuds keeps the error itself from growing past a bound, but MaxForce alone
	-- (14x weight, see ForceGravityMultiple above) would still be free to close even a bounded gap at an
	-- unbounded speed.
	--
	-- TUNED TIGHT, NOT JUST "COMFORTABLY ABOVE NITROUS" -- a first pass at 200 (nearly 2x CruiseSpeed)
	-- closed the catastrophic multi-hundred-stud discharge but still read as a noticeable shove on release,
	-- because a flat ceiling this far above cruise is itself still fast enough to feel like one. 150 is the
	-- tightest value that stays above Drive.NitrousSpeed (130) with real margin, so a future boost mechanic
	-- is never felt fighting it, while a MaxLeadStuds-sized (100 stud) debt closing at this ceiling takes
	-- ~0.7s -- a firm but not violent catch-up, not a snap. This is still only the HULL's own ceiling, not
	-- what a player standing on it can be launched to -- see Safety.MaxContactSpeed below and
	-- Server/Blimp/BlimpSafety.lua for why the hull's speed and a touching player's speed had to be bounded
	-- separately: they are two different physics bodies, joined only by ordinary collision, not by this
	-- constraint.
	MaxDriveVelocity = 150,
}

-- Safety nets that protect something OTHER than the hull itself -- currently just the one, but kept as
-- its own table (rather than folded into Physics above) because it is conceptually a different kind of
-- number: everything in Physics tunes how the HULL flies, this tunes how fast something ELSE may leave
-- after touching it. See Server/Blimp/BlimpSafety.lua's own header for the mechanism this defends
-- against.
BlimpConstants.Safety = {
	-- Studs/second. Ceiling on a PLAYER's own velocity while they are in contact with any part of a
	-- Blimp hull -- independent of MaxDriveVelocity above, which only bounds the hull's own speed and does
	-- nothing for a character that gains velocity from Roblox's own collision solver while holding a
	-- movement key into a body driven by AlignPosition (a well-known behaviour around
	-- AlignPosition/BodyMover-driven parts, not a bug in this codebase's own movement code -- confirmed by
	-- reading every mover that CAN drive a player's AssemblyLinearVelocity here: ParkourMotor.Apply is a
	-- no-op for plain Idle/Walking/Falling, so ordinary walking into a hull is unmodified Humanoid WalkSpeed
	-- physics the whole way through).
	--
	-- DELIBERATELY THE SAME NUMBER AS ParkourConstants.Validation.MaxTravelSpeed, not a new one invented for
	-- this file: that constant is already this codebase's own authored answer to "the fastest a player's
	-- velocity could plausibly, legitimately be" (deliberately far above top-gear running at 81 and a full
	-- dash at ~40, so an honest fast mover near a blimp is never clipped mid-move). Reusing it means one
	-- retune of "how fast is too fast for a person to actually be going" keeps both systems honest instead
	-- of two ceilings silently drifting apart. Kept as a literal value rather than a cross-require from
	-- Blimp (a standalone module -- see this file's own header) into Shared/Parkour/ParkourConstants.lua;
	-- src/Tests/Blimp/BlimpSafety.spec.lua pins the two to the same value so a future retune of one is
	-- forced to look at the other.
	MaxContactSpeed = 180,
}

-- The fuel simulation. Two independent resources, both loaded at the SAME single station
-- (Tags.Furnace -- see that entry's own comment on why there is no separate water-tank tag), and both
-- gated together by whether the model carries that one tag at all -- see BlimpTagging.
-- ResolveFuelStation/ResolveFuelTuning. A blimp with no Furnace tag never gates on fuel at all; the
-- fuel system is all-or-nothing per hull, not choosable per resource.
--
-- MINIMUM IS AN OPERATING RESERVE, NOT A DEPLETION FLOOR -- the load-bearing distinction in this
-- whole table. This is modelled on a real steam boiler's low-water cutoff, which kills the burner
-- once the level drops below a safe line, well before the tank is actually dry: a hull sitting on
-- 475 coal is still grounded the instant water drops under its own Minimum. See
-- Server/Blimp/BlimpFuel.IsDepleted, which compares against Minimum, never against zero.
--
-- Water's Minimum is a larger FRACTION of its own Capacity than coal's (10% vs. 5%) on purpose --
-- water is the resource a pilot is meant to be watching constantly (see BurnPerSecond below), so its
-- safety margin bites earlier relative to a full tank than coal's does.
BlimpConstants.Fuel = {
	CoalCapacity = 500,
	WaterCapacity = 500,
	CoalMinimum = 25,
	WaterMinimum = 50,
	-- Units/second, consumed only while BlimpSystem.isUnderPower(intent) is true -- the exact same
	-- condition that already drives the exhaust FX, so "the exhaust is burning" and "fuel is draining"
	-- are one fact, never two that could drift apart. Water burns ~10x faster than coal on purpose --
	-- see this table's own header -- so a full 500 tank buys roughly 8 minutes of continuous thrust
	-- before water alone grounds the hull, against roughly 79 minutes for coal.
	CoalBurnPerSecond = 0.1,
	WaterBurnPerSecond = 1.0,
}

-- How much of each resource a player may carry at once, and how much a single successful gather
-- grants -- read by Server/Systems/ResourceGatheringSystem.lua, not by anything in the Blimp layer
-- itself (a carried resource is the PLAYER's business until it is deposited). Kept here rather than
-- in Shared/Gathering/GatheringConstants.lua because the caps exist entirely to serve the Fuel table
-- above: CarryCap matches Capacity 1:1 so a diligent gatherer can always fully restock an empty
-- blimp in one load, and the two must be retuned together.
BlimpConstants.Carry = {
	CoalCap = 500,
	WaterCap = 500,
}

-- The ProximityPrompt each station carries. The prompt is what makes this "walk up and press E" without
-- this codebase growing its own proximity/occlusion/mobile-button layer -- see BlimpSystem.lua's header
-- for why a native prompt is the one place a Roblox built-in beat rolling it against KeybindManager.
BlimpConstants.Prompt = {
	HelmActionText = "Take the Helm",
	HandholdActionText = "Hold On",
	HelmObjectText = "Blimp",
	HandholdObjectText = "Blimp",
	-- Studs. Roughly arm's reach plus a step -- close enough that a player standing at the wheel gets it
	-- and one walking past on the gangway does not.
	MaxActivationDistance = 10,
	-- A tap, not a hold. A hold duration is what you use to stop an accidental press being costly, and
	-- mounting is instantly reversible with the same key.
	HoldDuration = 0,
	RequiresLineOfSight = false,
	-- The furnace's loading prompt -- one station, deposits both coal and water in one press (see
	-- BlimpConstants.Tags.Furnace's own comment). Static text, deliberately -- ProximityPrompt
	-- properties replicate to every nearby client alike, so there is no cheap way to show "how much
	-- YOU are carrying" here without a second, per-player GUI surface, which is exactly the scope this
	-- feature chose not to add (see the Blimp Fuel plan's carried-resource decision). What a press
	-- DID is answered per-player instead, over Network.RemoteNames.FuelTransfer -- an empty-handed
	-- press used to be answered with silence, which is the bug that remote exists to close.
	FurnaceActionText = "Refuel",
	FurnaceObjectText = "Furnace",
	-- The Instance NAMES the server gives each prompt. Here rather than as string literals at the three
	-- places that use them because they were literals at three places and one of them was wrong: the
	-- client's own re-key pass (BlimpController.reKeyPrompt) matched only "BlimpPrompt", so a player who
	-- rebound Interact away from E left every FURNACE prompt in the game still listening for E. A shared
	-- name is what makes "every prompt this feature owns" an enumerable set instead of a convention.
	StationPromptName = "BlimpPrompt",
	FuelPromptName = "BlimpFuelPrompt",

	-- THE SECOND FURNACE PROMPT: taking it back out. A player who loaded 500 coal into the wrong hull,
	-- or who wants their stock back off a ship they are done with, had no way to reach it -- a deposit
	-- was a one-way door, and the only route back was to fly the fuel off as exhaust.
	--
	-- ITS OWN PROMPT RATHER THAN A MODE ON THE ONE ABOVE, because a ProximityPrompt has exactly one
	-- Triggered signal and no notion of a second gesture. Two prompts on one part is otherwise a build
	-- error this codebase warns about (BlimpSystem.registerBlimp's own station/furnace collision
	-- warning) -- what makes THIS pair legal is that the two are deliberately given different keys and
	-- pulled apart on screen with UIOffset below, which is precisely what the accidental collision
	-- never has.
	UnloadActionText = "Unload Fuel",
	-- A HOLD, unlike every other prompt in this file. Loading is safe to fumble (it moves fuel you
	-- gathered on purpose into a ship you walked up to); UNLOADING can strand a fuelled hull, so it
	-- gets the one thing a hold is actually for -- making an accidental press cost nothing.
	UnloadHoldDuration = 0.6,
	-- V, not the Interact bind. It has to differ from the load prompt's key or the engine has two
	-- prompts on one part listening for one press. V is unclaimed in Constants.Keybinds.Defaults (the
	-- whole table was checked, not just the blimp's own entries) AND unclaimed by the raw-KeyCode
	-- readers that table cannot see -- which is the check that actually matters here, and the one that
	-- ruled out the obvious first pick: X is the helm's own ALL STOP (Client/Blimp/BlimpController's
	-- onInputBegan), bound raw because the helm keys deliberately are not KeybindActions. Prompts are
	-- suppressed while mounted so the two could never have fired at once, but a feature that spends one
	-- key on two unrelated jobs is one rebind away from being a real collision, and F6/F5 (see
	-- Constants.Keybinds' OpenDevConsole comment) is what that looks like when nobody writes it down.
	--
	-- NOT re-keyed by Client/Blimp/BlimpController.reKeyPrompt -- that pass matches StationPromptName/
	-- FuelPromptName only, so a player who rebinds Interact moves the LOAD prompt and leaves this one
	-- where it is, which is correct: this key is not Interact and never was.
	UnloadKeyCode = Enum.KeyCode.V,
	-- ButtonY rather than the engine's default ButtonX, for the same "two prompts, one part, one
	-- press" reason as the keyboard key above -- every other prompt this System builds leaves
	-- GamepadKeyCode at its default.
	UnloadGamepadKeyCode = Enum.KeyCode.ButtonY,
	-- Pixels. Drops this prompt's UI clear of the load prompt's, which is parented to the SAME part
	-- and would otherwise render exactly on top of it -- two overlapping key glyphs at one point in
	-- space, which is how a deliberate pair would be mistaken for the accidental collision above.
	UnloadUIOffset = Vector2.new(0, 64),
	UnloadPromptName = "BlimpFuelUnloadPrompt",
}

-- Thrust FX. Driven off the pilot's THROTTLE AXIS, not off the hull's actual speed: the player pressed a
-- key and the exhaust should answer on that press, not five seconds later when the mass finally agrees.
-- The same reasoning in reverse is why it cuts on release rather than fading out with the deceleration
-- ramp -- an exhaust that trails a released key reads as broken, not as heavy.
BlimpConstants.Exhaust = {
	-- Reverse deliberately does NOT light the exhaust. A thruster that fires while the hull moves
	-- backwards is pointing the wrong way, and this is the one FX on the model a player can check against
	-- their own input.
	RequiresForwardThrottle = true,
}

BlimpConstants.Mount = {
	-- Studs from the station part's centre to the mounted body, when there is no "Stand" Attachment to say
	-- otherwise. WHICH SIDE is not a constant -- BlimpTagging.ResolveStandOffset picks it, because the side
	-- of a wheel a helmsman stands on is the side with a floor under it and, failing that, the side toward
	-- the middle of the ship. See that function; this is only how far back.
	DefaultStandReach = 2.5,
	-- Seconds between stale-mount sweeps. A mounted player who stops being reachable (their character is
	-- destroyed out from under the weld, the blimp is deleted mid-flight) is released by the sweep rather
	-- than left welded to a corpse -- the same "a hold needs a backstop that does not depend on the happy
	-- path" posture GrabSystem's own auto-release has.
	StaleSweepSeconds = 1,
	-- Studs the released character is lifted before their body is handed back, so a dismount inside the
	-- station part's own volume does not spawn them intersecting it and get them flung.
	ReleaseClearance = 1.5,
	-- Studs/second a released body may be carrying OVER the hull's own current speed. This is a MARGIN,
	-- not a ceiling: the clamp Server/Systems/BlimpSystem.Dismount applies is
	-- (hull speed + this), so it is self-tuning against however fast the ship happens to be going.
	--
	-- WHY RELATIVE AND NOT ABSOLUTE, which is the whole point of the number. A released body inherits the
	-- hull's velocity by design (that is what makes stepping off a moving ship a step rather than a stop
	-- -- see Dismount's own comment), so any flat ceiling is wrong at one end or the other: set it low
	-- enough to feel safe at a hover and it rips a passenger off a cruising hull's deck at 130 studs/second
	-- of relative speed, and the moving deck then sweeps into them and launches them far harder than the
	-- inheritance ever would have. Set it high enough to be safe at cruise and it does nothing at a hover.
	-- Anchoring to the hull's own speed keeps "you leave with the ship" exact while still trimming
	-- anything ABOVE it -- which is the part that is never legitimate.
	--
	-- Sized just over a full dash (~40 in Parkour terms is the fast end of self-propelled; 24 is
	-- comfortably inside ordinary running) so a player who genuinely jumps clear of a hovering blimp under
	-- their own power is never clipped, while the lever-arm term a long hull's rotation contributes
	-- (omega x r, unbounded in the radius the artist gave the model) is.
	ReleaseSpeedMargin = 24,
	-- Seconds after a release during which onHeartbeatTick keeps re-applying that same clamp. The one-shot
	-- write in Dismount fixes the velocity the body is HANDED; this covers the velocity Roblox's own
	-- depenetration solver can hand it back one step later, when a body that was welded flush to the deck
	-- becomes a separate colliding assembly overlapping it. Deliberately short -- it is a settle window for
	-- the separation impulse, not an ongoing leash on a player who has walked away.
	ReleaseSettleSeconds = 0.75,
}

-- Arm placement. See Shared/Blimp/BlimpArmPose.lua for the solver these feed.
BlimpConstants.Pose = {
	-- Fallback grip half-separation, in studs, when a station part carries no LeftGrip/RightGrip
	-- Attachments -- measured out along the part's widest horizontal axis from its centre.
	FallbackGripHalfWidth = 0.9,
	-- ...clamped by this, so a very wide railing does not splay the arms into a crucifixion pose.
	FallbackGripMaxHalfWidth = 1.6,
	-- Which way the elbows break. 1 puts the elbow behind the arm plane (the natural reach-forward pose);
	-- flipping it is what you would change if a bespoke station wanted an overhand grip.
	ElbowPoleSign = 1,
	-- Fraction of full arm extension the solver will reach before it stops reaching and simply points.
	-- Below 1 so a target at exactly arm's length does not produce a locked, visibly straight limb.
	MaxReachFraction = 0.98,
}

-- The mounted body's own lean (Shared/Blimp/BlimpPilotPose.lua) -- the layer between "this player is
-- welded to a station" and "this player is RIDING something". Same channel, same frame and the same
-- non-replicating Motor6D.Transform argument BlimpArmPose.lua's header spends its length on; read
-- that first, because everything true of the arms is true of this.
--
-- PHYSICS-DRIVEN, NOT AUTHORED, and for the same reason the camera is: the numbers below are
-- coefficients on the hull's OWN measured motion, so a lean is never a clip that has to be kept in
-- sync with how fast the ship actually turns. There is nothing here to drift out of date against a
-- retune of Drive above, and nothing that has to be re-authored for a hull with a different turn rate.
--
-- Two channels, and they are opposites on purpose -- which is the whole reason this reads as a person
-- rather than as a wobble:
--   * ROLL leans INTO the turn. A helmsman holding a wheel is anchored by their hands; the ship rolls
--     out from under them and they go with it.
--   * PITCH leans AGAINST the acceleration. Nothing anchors them fore-and-aft, so when the engines
--     bite they are left behind and brace backward, and when the ship brakes they pitch forward over
--     the wheel.
-- Getting either sign backwards produces a body that looks like it is being pushed by the animation
-- rather than by the ship, which is the exact failure mode this replaces.
BlimpConstants.Lean = {
	-- Radians of body roll per radian/second of hull yaw rate, and the ceiling on it. Larger than the
	-- camera's own Roll.RadiansPerYawRate -- the person leans further than the view does, which is what
	-- makes the lean visible to everyone ELSE on deck, who are the audience for this effect.
	RollRadiansPerYawRate = 0.75,
	MaxRollRadians = 0.28,
	-- Radians of body pitch per stud/second^2 of forward acceleration, and its ceiling. Negative
	-- coefficient: a POSITIVE acceleration should lean the body BACK.
	PitchRadiansPerAccel = -0.014,
	MaxPitchRadians = 0.22,
	-- Radians of body pitch per stud/second of climb rate -- a much smaller, slower channel than the
	-- surge above, since a lift's vertical acceleration is felt in the knees rather than the spine.
	PitchRadiansPerClimbRate = -0.0025,
	-- Spring rates for the whole pose, shared by both channels. Stiffer and more damped than the
	-- camera's: a body settles faster than a view does, and a person who visibly oscillates after a
	-- turn ends reads as unconscious.
	Stiffness = 11,
	Damping = 0.9,
	-- How much of the lean the WAIST takes versus the head. Splitting it is what stops the whole rig
	-- rotating as one board -- the head counter-rotates slightly toward level, the way a person keeps
	-- their eyes on the horizon. 0 disables the head channel outright without touching call sites.
	HeadCounterFraction = 0.35,
	-- Studs the mounted body's root is allowed to sway laterally with the turn, on top of the rotation
	-- -- weight shifting between the feet. Deliberately tiny: the body is WELDED to the station (see
	-- BlimpSystem's own header on why a weld and not a constraint), so this is presentation drift over
	-- a fixed anchor, not the body actually moving on the deck.
	SwayStuds = 0.18,
}

-- The pilot's/passenger's own camera while aboard (Client/Camera/BlimpCamera.lua, whose math lives in
-- Shared/Blimp/BlimpCameraMath.lua). PRESENTATION ONLY -- nothing here reaches a single gameplay
-- outcome, which is why it lives beside the flight numbers rather than in Constants.Camera: this is
-- the Blimp system's own tuning surface, and this file's own header already argues that case.
--
-- EVERY CHANNEL IS A SPRING, NOT AN EASE, and that is the difference between this camera and the two
-- that came before it. Constants.Camera.Flight's chase pull-back eases exponentially toward a target,
-- which always arrives from the same side and never overshoots -- correct for a value that just needs
-- to catch up. A camera aboard a heavy thing that is being pushed around should OVERSHOOT and settle:
-- the view leans a little too far into the turn and comes back, the horizon dips when the engines bite
-- and rises past level when they cut. Damping below 1 is what buys that; at exactly 1 the spring is
-- critically damped and reads like a (nicer) ease. Nothing here is tuned above 1.
--
-- The input is the HULL'S OWN PHYSICS, read locally off the assembly's AssemblyLinearVelocity/
-- AssemblyAngularVelocity every frame -- never a number the server sent. See BlimpCamera.lua's header
-- on why that is both the cheapest and the most honest source there is.
BlimpConstants.Camera = {
	-- How hard the raw physics sample is filtered before any spring sees it. Roblox's replicated
	-- velocities on a constraint-driven assembly are noisy at the frame scale; without this the roll
	-- channel buzzes even in level flight.
	Smoothing = {
		VelocityEaseSpeed = 14,
		-- Slower than the velocity filter on purpose -- acceleration is a difference of an already-noisy
		-- signal, so it is the noisiest thing here and the one a player is least able to see directly.
		AccelEaseSpeed = 5,
	},
	-- Roll into the turn. The biggest single contributor to "this thing is banking", and deliberately
	-- allowed to lag the hull's own visible bank (Drive.BankRadiansPerTurnRate) rather than mirror it
	-- -- a camera welded to the hull's roll reads as the WORLD tilting, which is both less legible and
	-- the most reliable way to make somebody motion sick.
	Roll = {
		RadiansPerYawRate = 0.85,
		Stiffness = 7,
		Damping = 0.62,
		MaxRadians = 0.24,
	},
	-- Yaw sway -- the view trailing behind the turn before catching up. Softer and slower than Roll so
	-- the two read as one motion with weight rather than two effects firing together.
	Sway = {
		RadiansPerYawRate = 0.5,
		Stiffness = 4.5,
		Damping = 0.55,
		MaxRadians = 0.18,
	},
	-- Pitch with climb rate. Positive climb pitches the view UP.
	Pitch = {
		RadiansPerClimbRate = 0.006,
		Stiffness = 5.5,
		Damping = 0.65,
		MaxRadians = 0.16,
	},
	-- Positional offset, in Humanoid.CameraOffset's local space (X = right, Y = up, Z = BACK -- the
	-- same convention Constants.Camera.ShiftLock.ShoulderOffset and FlightCamera's chase pull-back
	-- already use). Composed through Client/FX/CameraOffsetComposer.lua's named "Blimp" slot, never
	-- written to the Humanoid directly.
	Offset = {
		-- Backward pull at cruise -- speed reading as speed without touching camera position math.
		PullBackStudsAtCruise = 5.5,
		-- Studs of extra pull-back per stud/second^2 of forward acceleration, and forward push under
		-- braking (the same number, with the sign the acceleration already carries). THIS is the
		-- acceleration/deceleration channel the whole camera is named for: opening the throttle shoves
		-- the view back into the deck, cutting it lets the view drift forward past centre and settle.
		SurgeStudsPerAccel = 0.1,
		MaxSurgeStuds = 4,
		-- Vertical: the view sinks slightly as the ship rises and floats as it drops -- the inverse of
		-- the hull's own motion, which is what a body's own mass actually does in a lift.
		HeaveStudsPerClimbRate = -0.035,
		MaxHeaveStuds = 2.4,
		-- Lateral lean out of the turn. Small, and the one rotational-feeling channel that SURVIVES the
		-- comfort opt-out, because it is positional rather than rotational -- see BlimpCamera.lua's own
		-- SetMotionEnabled.
		SlideStudsPerYawRate = 1.9,
		MaxSlideStuds = 2.1,
		Stiffness = 6,
		Damping = 0.62,
	},
	-- FOV, through Client/FX/FOVOffset.lua's named "Blimp" continuous slot. Widening with speed, the
	-- same sign convention (and for the same reason) as Constants.Camera.Flight.FOVMaxDeltaAtBoost --
	-- soaring widens, sprinting narrows.
	Fov = {
		MaxDeltaAtCruise = 15,
		EaseSpeed = 3,
	},
	-- ENGINE RUMBLE -- a continuous, tiny, quasi-random tremor on roll and pitch, scaled by how hard
	-- the ship is working. The single biggest thing missing from the first pass at this camera, and the
	-- reason is worth stating: a blimp at a steady cruise has NO transient cues at all. The springs
	-- above all answer to CHANGE -- a turn, a climb, a throttle move -- so once the ship settles onto a
	-- heading they are all at rest and the view is as still as standing on solid ground, which is the
	-- opposite of what riding a working engine feels like. This is what fills that gap: it never
	-- settles, because an engine never does.
	--
	-- Deliberately BELOW the threshold of a conscious "the camera is shaking" read (a couple of tenths
	-- of a degree at full power). It is felt rather than seen, which is exactly the register
	-- docs/ui-ux-philosophy.md's Critical States rule asks for ("controlled animation... never use
	-- excessive flashing") -- and it is one of the three channels the vehicle-motion comfort toggle
	-- switches off, since it is rotational.
	--
	-- Two incommensurate sine pairs rather than math.noise: the ratio below is irrational enough that
	-- the sum never visibly repeats, it costs four sines instead of two gradient lookups, and it is
	-- deterministic, which means the spec can assert its bound.
	Rumble = {
		-- Peak radians at full speed. 0.004 rad is about a quarter of a degree.
		MaxRadians = 0.004,
		-- Hz. Fast enough to read as machinery rather than as sway -- the springs above already own
		-- everything slower than this.
		BaseFrequency = 11,
		-- The second oscillator's frequency as a multiple of the first. Irrational-ish on purpose.
		BeatRatio = 1.618,
		-- Floor on the rumble as a fraction of its peak, applied whenever the ship is under way at all.
		-- A hull at dead slow is still burning coal, and a rumble that scaled purely linearly from zero
		-- would make the engine inaudible-to-the-body at exactly the speeds a pilot spends most of their
		-- time at.
		IdleFraction = 0.35,
	},
	-- THE TELEGRAPH KICK -- a one-shot impulse fired when the rung actually moves.
	--
	-- This is the other half of the immersion problem, and it is a FEEDBACK problem rather than a feel
	-- one. A blimp takes about two and a half seconds to answer a rung change, so a pilot who rings
	-- down one notch gets no evidence for the better part of a second that anything happened at all --
	-- and a control that appears to do nothing is a control players press again. The kick is the
	-- receipt: the engines take up the load, the deck shoves, and the ship starts its slow answer.
	--
	-- Applied as an IMPULSE INTO THE EXISTING SPRINGS (a velocity injection), not as its own animated
	-- channel. That is both less code and more correct: a step change in commanded thrust IS an
	-- impulse, and feeding it to the spring that already owns fore-and-aft camera displacement means it
	-- composes with whatever that spring was already doing instead of fighting it.
	Kick = {
		-- Studs/second of velocity added to the fore-aft offset spring per rung of change. Positive
		-- rungs kick the view BACK (+Z), astern kicks it forward, and the sign is taken from the delta
		-- so ringing down from Flank to Full shoves the view forward exactly as braking does.
		OffsetVelocityPerRung = 9,
		-- Radians/second added to the pitch spring, same signed convention -- the nose of the view lifts
		-- as the deck pushes.
		PitchVelocityPerRung = 0.5,
		-- Degrees of one-shot FOV punch, through Client/FX/FOVOffset.lua's own Punch slot rather than
		-- this module's continuous one -- so it rides the SAME comfort opt-out
		-- (Types.ComfortSettings.FieldOfViewEffects) as every other impact punch in the game.
		FovPunchDegrees = -2.2,
		FovPunchOutSeconds = 0.07,
		FovPunchBackSeconds = 0.32,
	},
	-- The idle hover bob, applied to the offset's Y only while the hull is essentially stationary. Uses
	-- Shared/FlightMath.ComputeHoverBobOffset -- the same generator the dev-menu flight hover already
	-- uses, deliberately, rather than a second sine wave with its own phase.
	Bob = {
		AmplitudeStuds = 0.14,
		PeriodSeconds = 5.5,
		-- Studs/second of hull speed above which the bob has faded out entirely -- a ship under way has
		-- its own motion and does not need a second, slower one layered under it.
		FadeOutSpeed = 12,
		-- How fast the bob's own gain eases toward that fade, per second. The bob is a DRIVEN oscillation
		-- rather than a spring target (see BlimpCameraMath.Step), so it has no natural way to wind down --
		-- without this it would still be running at full amplitude on a released camera, and the release
		-- would keep the render step bound forever waiting for an offset that never settles.
		GainEaseSpeed = 3,
	},
}

-- THE WIND YOU CAN ACTUALLY SEE (Client/FX/BlimpWindVFX.lua) -- streaks of air rushing past everyone
-- aboard, spawned in a volume that rides the camera and left behind in WORLD space as the ship moves
-- through them.
--
-- THAT LAST PART IS THE WHOLE TRICK AND IT IS WHY THIS IS PHYSICS RATHER THAN DECORATION. The air is
-- not blowing; the ship is moving through still air. So the particles are emitted around the viewer
-- and then simply left where they were born (ParticleEmitter.LockedToPart = false, which is what makes
-- a particle live in the world instead of following its emitter). The rush past the deck is not
-- animated by anything -- it is the hull's own velocity, seen against stationary air. A blimp that
-- coasts to a stop watches the wind die on its own, with nothing telling it to, because there is
-- nothing left to move through.
--
-- The one deliberate departure from that: the particles get a small drift of their own, BACKWARD along
-- travel, on top of the ship's motion. Strictly that is a headwind nobody authored, and it is here for
-- two reasons. It reads slightly faster than reality, which is what an airship's own slipstream
-- actually does near the hull. And ParticleEmitter.Orientation = VelocityParallel -- the property that
-- turns a round mote into a STREAK aligned with its own motion -- needs a real velocity vector to
-- align to, and a particle that is honestly stationary in world space has none.
BlimpConstants.Wind = {
	-- ParticleEmitter's OWN DEFAULT texture, named explicitly. rbxasset:// (as opposed to
	-- rbxassetid://) is content that ships inside the Roblox client, so this is live today rather than
	-- blocked on somebody exporting a streak sprite -- and this particular path is the one the engine
	-- itself falls back to, which makes it the only texture id in this file that cannot be wrong.
	--
	-- It is a soft four-point sparkle at rest and reads nothing like wind. Stretched along its own
	-- velocity by Squash below it becomes a bright-cored streak, which is exactly a speed line. Swap it
	-- for a real streak sprite when there is one; nothing else here has to change.
	Texture = "rbxasset://textures/particles/sparkles_main.dds",
	-- Studs of the emission box. ENLARGED FROM THE PRIOR PASS -- against ForwardBiasStuds below (now
	-- measured from the HULL, not the camera), a 44-stud box read as a handful of far-off, sub-pixel
	-- specks rather than a field of visible weather; a bigger volume is what makes the effect legible at
	-- the distance a real hull now demands.
	VolumeStuds = Vector3.new(56, 34, 56),
	-- Studs ahead of the HULL'S OWN CENTRE (not the camera -- see Client/FX/BlimpWindVFX.lua's own
	-- header on why that changed). TRIMMED FROM A FIRST PASS AT 60 -- that value cleared the hull cleanly
	-- but, combined with a zoomed-out chase camera, put the whole effect far enough away to read as
	-- "barely there" rather than as wind. 40 is the balance: still clear of a typical hull's length (see
	-- BlimpAssembly's own header on why no fixed hull-length constant exists to derive this precisely),
	-- close enough that the bigger volume and streaks above/below actually register. Retune upward if a
	-- builder ships a hull long enough to still poke through.
	ForwardBiasStuds = 40,
	-- Particles per second at cruise. Against the shorter lifetime below this settles around 60
	-- concurrent -- StreakStuds, Squash and DriftFraction were all raised alongside the volume above so
	-- fewer, bigger, faster streaks read as clearly-legible wind rather than merely as more of the same
	-- faint specks.
	MaxRate = 150,
	LifetimeSeconds = NumberRange.new(0.3, 0.5),
	-- The particles' own backward drift, as a fraction of the hull's speed -- see this table's header on
	-- why it is not zero. RAISED FROM 0.35 -- the earlier value made each streak's own motion too gentle
	-- to read as a clear direction on its own, which is most of why a faint, slow, pale streak got
	-- misread as ambient floating motes drifting upward rather than as wind racing past.
	DriftFraction = 0.55,
	-- Degrees of scatter on the emission direction. Small: air moving past a hull is coherent, and a
	-- wide spread reads as smoke rather than as speed.
	SpreadDegrees = 7,
	-- How far a streak is stretched along its own velocity (ParticleEmitter.Squash). This is the
	-- difference between "specks drifting past" and "wind". Raised alongside StreakStuds and
	-- DriftFraction above, for the same reason -- a faster particle needs more squash to read as one
	-- continuous line rather than a blur.
	Squash = 7,
	-- Peak opacity. LOWERED (more opaque) from a first pass at 0.5 -- half-opacity pale streaks over a
	-- bright, overcast sky (this game's actual weather, per the reference screenshot this was tuned
	-- against) have almost no contrast left to see by the time distance and fog alone have thinned them.
	-- Read the number as "at its most visible, a streak is this transparent" -- 0.25 is three-quarters
	-- opaque at peak.
	PeakTransparency = 0.25,
	-- Studs of streak, at its widest point mid-life. Raised alongside the volume above -- bigger streaks
	-- read at the distance a hull-anchored (rather than camera-anchored) volume now sits at.
	StreakStuds = 3.2,
	-- How much the streaks glow rather than take world lighting. High: this is the difference between
	-- air you can see against a bright sky and air you can only see against the ground.
	LightEmission = 0.85,
	-- COOLER AND MORE SATURATED THAN THE FIRST PASS (214, 210, 232), which was near-white -- and
	-- near-white is exactly what a pale, overcast sky already is. A streak that is almost the same color
	-- as its background has nothing left to read by except opacity, which is why the first pass vanished
	-- into foggy weather specifically. This keeps the same cold violet-toward-frost register the design
	-- doc's Qi/chrome palette lives in, just with enough chroma to still contrast against a white sky.
	Color = Color3.fromRGB(150, 175, 225),
	-- Studs/second of hull speed below which the emitter is switched off outright rather than merely
	-- faded to nothing. A moored blimp should cost nothing at all, and an emitter at Rate 0 is still an
	-- emitter the renderer walks.
	MinimumSpeed = 6,
	-- How fast the visible intensity eases toward the speed it should be showing, per second. The
	-- particles themselves cannot ease -- each one is born at whatever rate was set that frame -- so
	-- this is what stops a rung change from switching the weather.
	--
	-- Kept BRISK on purpose. The signal it smooths is the hull's own speed, which already ramps over
	-- about two and a half seconds; anything slower here is a second smoothing pass stacked on a signal
	-- that was never sharp, and it shows up as air that visibly lags the ship it belongs to.
	IntensityEaseSpeed = 4.5,

	-- Live sideways Acceleration, applied to particles ALREADY in flight (unlike Speed/EmissionDirection
	-- above, which are frozen onto a particle at birth) -- see Client/FX/BlimpWindVFX.lua's own header
	-- for why that split is what turns "particles on rails" into "clean ahead, wavy as it passes, and
	-- sweeps with a turn". Both terms below share one axis: perpendicular to the hull's own travel
	-- direction, in the horizontal plane.
	Turbulence = {
		-- Studs/second^2, the ceiling on the ambient gust term. Small: this is a sway that becomes
		-- visible over a streak's own short lifetime, not a shake.
		MaxGustAccelStuds = 9,
		-- Hz. An order of magnitude under BlimpConstants.Camera.Rumble.BaseFrequency on purpose -- that
		-- one is the "machinery never settles" register; this is a slow ambient sway, not vibration.
		Frequency = 0.55,
		-- The second oscillator's frequency as a multiple of the first -- same "irrational-ish, never
		-- visibly repeats" technique Camera.Rumble already uses, at a slower rate.
		BeatRatio = 1.618,
		-- Studs/second^2 of sideways push per radian/second of the hull's own (filtered) yaw rate -- the
		-- turning cue. A real turn shoves the air it is carving through sideways; this is that shove,
		-- made visible, so the streaks visibly sweep with a turn instead of ignoring the ship's heading
		-- change. Signed off yawRate directly, so a turn to starboard sweeps opposite a turn to port.
		TurnAccelPerYawRate = 55,
		MaxTurnAccelStuds = 30,
	},
}

-- Engine and wind loops (Client/FX/BlimpAudio.lua), both driven off the SAME per-frame physics sample
-- the camera reads -- not off the telegraph rung. The exhaust FX answers the pilot's key press
-- (Exhaust above says why); the audio answers the hull, because a ship still making way after the
-- engines cut should still be making wind noise, and one straining toward a rung it has not reached
-- yet should still be roaring.
--
-- SoundIds are empty placeholders until real assets are uploaded -- SoundManager.PlayLooped/
-- SetLoopedVolume already no-op safely on an unset id, which is the same posture
-- Shared/Flight/FlightConstants.lua's own sound block ships in.
BlimpConstants.Audio = {
	EngineLoop = {
		SoundId = "",
		MaxVolume = 0.35,
		MinPlaybackSpeed = 0.7,
		MaxPlaybackSpeed = 1.25,
	},
	WindLoop = {
		SoundId = "",
		MaxVolume = 0.25,
		MinPlaybackSpeed = 0.85,
		MaxPlaybackSpeed = 1.15,
	},
	-- Seconds to fade each loop in on mount and out on dismount. A hard cut on a loop is the one thing
	-- that reliably makes a placeholder sound like a bug rather than a placeholder.
	FadeSeconds = 0.45,

	-- THE THREE FLIGHT STAGES. A ship is Slow, Cruising or Running, and crossing between them is an
	-- EVENT the pilot hears: a one-shot on the change, plus the engine loop settling into that stage's
	-- own volume and pitch band.
	--
	-- WHY STAGES AT ALL, when the loop already scales continuously with speed. A value that varies
	-- smoothly is one a player stops hearing -- it has no edges, so there is no moment to notice. The
	-- eight-rung telegraph is deliberately finer than a pilot can feel; three stages are deliberately
	-- coarser, and coarse is what makes each crossing land. It is the same reason a car with a
	-- continuously variable transmission feels slower than one that shifts.
	--
	-- ONE SOUND AT THREE PITCHES, not three uploads. SoundManager.Play takes a per-play playback speed
	-- (its own signature), so the stages are distinguishable today with a built-in placeholder rather
	-- than blocked on somebody recording three engine notes -- and when real assets arrive, giving each
	-- stage its own SoundId is a field, not a rewrite.
	StageChangeSound = {
		-- A built-in that ships with the client, so this is audible the moment you fly. Unmistakably a
		-- placeholder -- it is the stock UI ping, not an engine -- which is the point: it proves the
		-- staging works and asks to be replaced rather than quietly passing for finished.
		SoundId = "rbxasset://sounds/electronicpingshort.wav",
		Volume = 0.35,
	},
	-- Ordered slowest first. EnterFraction is this stage's floor as a fraction of the hull's own cruise
	-- speed; the first stage's is 0 by definition. Resolved by Shared/Blimp/BlimpSpeedStage.lua.
	Stages = {
		{
			Id = "Slow",
			Label = "SLOW",
			EnterFraction = 0,
			PlaybackSpeed = 0.78,
			LoopVolumeScale = 0.45,
			LoopSpeedScale = 0.85,
		},
		{
			Id = "Cruise",
			Label = "CRUISE",
			EnterFraction = 0.38,
			PlaybackSpeed = 1,
			LoopVolumeScale = 0.75,
			LoopSpeedScale = 1,
		},
		{
			Id = "Running",
			Label = "RUNNING",
			EnterFraction = 0.72,
			PlaybackSpeed = 1.3,
			LoopVolumeScale = 1,
			LoopSpeedScale = 1.2,
		},
	},
	-- The dead band around every threshold, in fraction units. WITHOUT THIS THE FEATURE IS A BUG: a
	-- hull holding station exactly on a boundary has a speed that jitters by a fraction of a percent
	-- from the physics solver alone, and a bare comparison would fire the stage-change sound several
	-- times a second forever. A stage is entered a little above its floor and left a little below it,
	-- so the crossing has to be meant.
	StageHysteresis = 0.07,
}

-- WHAT A PILOT PRESSES, PER DEVICE. One row per helm control, each naming the keyboard key and the
-- gamepad input that reach it -- and this table is the ONLY place either is written down.
--
-- IT EXISTS BECAUSE THE ANSWER WAS PREVIOUSLY GIVEN TWICE, in two files that could not check each
-- other: Client/Blimp/BlimpController.lua matched raw `Enum.KeyCode.W`/`S`/`X`/`G` in its own
-- InputBegan, and Client/UI/Screens/BlimpHelm/init.lua drew the literal strings "W"/"S"/"A"/"D"/
-- "SPACE"/"SHIFT" in its legend. Nothing connected them, so a key could be changed in one and left
-- wrong in the other with no error anywhere -- and the legend was wrong for a whole DEVICE
-- regardless, telling a player holding a controller to press W.
--
-- STILL NOT Types.KeybindActions, AND THAT IS THE SAME DECISION AS BEFORE, not an oversight this
-- table half-corrects. See Client/Blimp/BlimpController.lua's header: these are CONTEXTUAL -- read
-- only while this client is holding a helm, meaningless everywhere else, and invisible to a rebind
-- screen that has no notion of "while piloting". What changed is only that a contextual binding is
-- now DATA with two device columns, instead of a literal buried in a comparison and a string buried
-- in a legend.
--
-- THE GAMEPAD COLUMN IS CONFLICT-FREE BY CONSTRUCTION, and Tests/Blimp/BlimpHelmControls.spec.lua is
-- what keeps it that way. Every input below has a global meaning that is either physically inert
-- while mounted (the left stick -- BlimpSystem.mount sets PlatformStand, and RunSystem pins WalkSpeed
-- to 0 off Constants.Attributes.Mounted) or already gated on that same Attribute by its own consumer
-- (Client/Parkour/ParkourInput.lua for Slide/Roll/Dash/Leap, Client/Emotes/EmoteWheelClient.lua for
-- the wheel, Client/Camera/ShiftLockCamera.lua for shift lock). That is why this layer needs no
-- ContextActionService sink and no suppression switch of its own: nothing it takes was answering.
--
-- WHAT IS DELIBERATELY *NOT* HERE, and would each be a real collision if it were:
--   * DPadUp -- Constants.Keybinds.GamepadDefaults.SettingsToggle, which is NOT gated on Mounted and
--     must not be (a pilot has every right to open their settings mid-flight). The D-pad is the
--     obvious home for a notched engine telegraph, and this is the reason it is not the one chosen.
--   * DPadRight -- ToggleWeapon, read by Client/Combat/AttackInputClient.lua with no mount gate.
--   * ButtonL2 -- Constants.Keybinds.GamepadModifier. A throttle lever there would put the pad on the
--     chord layer for the whole time a pilot leaned on it.

BlimpConstants.Controls = {
	-- THE LEFT STICK IS THE SHIP'S ATTITUDE AND THE FACE BUTTONS ARE ITS ENGINE ORDER TELEGRAPH, and
	-- that split is the one design decision here worth defending. A rudder is held continuously and
	-- read as a magnitude; a telegraph is a latched lever moved a rung at a time. Putting both on one
	-- stick -- the tempting mapping, since W/S and A/D are one hand on a keyboard -- would mean a pilot
	-- could not hold a hard turn without that same stick crossing a throttle notch, which is a mis-ring
	-- caused by steering. Two different kinds of control, two different kinds of input.
	--
	-- Analog.Move is the right half of that module's two configs by construction: it takes the
	-- player's MoveDeadzone and deliberately NO sensitivity and NO invert, which is exactly what a
	-- rudder wants. A scaled rudder would silently retune how hard the ship turns, and an inverted one
	-- would put the helm over to port when the stick went to starboard.
	Steer = {
		Positive = Enum.KeyCode.D,
		Negative = Enum.KeyCode.A,
		Gamepad = Enum.KeyCode.Thumbstick1,
	} :: BlimpTypes.HelmAxisBinding,
	Lift = {
		Positive = Enum.KeyCode.Space,
		Negative = Enum.KeyCode.LeftShift,
		Gamepad = Enum.KeyCode.Thumbstick1,
	} :: BlimpTypes.HelmAxisBinding,

	-- ButtonY is the TOP of the face diamond and ButtonA is the BOTTOM, which is the whole reason this
	-- pair reads as a lever rather than as two arbitrary buttons -- ring up is up, ring down is down,
	-- and both are under one thumb. Taken together the four face buttons end up being the four helm
	-- commands laid out as a compass: Y ahead, A astern, B all stop, X let go.
	--
	-- ButtonA IS A DELIBERATE, SCOPED EXEMPTION FROM A RULE THIS PROJECT OTHERWISE HOLDS, and it is
	-- worth stating rather than discovering. Tests/Input/GamepadBindings.spec.lua asserts that
	-- Constants.Keybinds.GamepadDefaults never binds ButtonA, because that is Roblox's own native jump
	-- on every pad and an action there double-fires on every jump with nothing in this codebase able to
	-- stop it. That rule is about the GLOBAL map, and its premise is that the player can jump. At a
	-- helm they cannot: BlimpSystem.mount sets Humanoid.PlatformStand (which suspends the Humanoid's
	-- own jump handling outright) and welds the root to the station, and ParkourInput's IsJumpKeyDown
	-- poll is mount-gated (fixed 2026-08-30 -- pollJump was the one Jump/Slide/Roll/Dash/Leap reader
	-- that had been missing the isMounted() check the other four already had). The button is genuinely
	-- idle here in a way it never is anywhere else, which is exactly why the contextual map may spend
	-- it and the global map may not. Tests/Blimp/BlimpHelmControls.spec.lua pins both halves of that.
	--
	-- THAT REASONING IS ABOUT THE HUMANOID AND THE PARKOUR BUFFER -- IT SAYS NOTHING ABOUT INPUT
	-- ROUTING, and the gap between the two was a real bug (fixed 2026-08-30, in
	-- Client/Blimp/BlimpController.onInputBegan). Roblox marks EVERY gamepad ButtonA press as
	-- gameProcessedEvent = true, unconditionally -- an engine-level quirk (its own GUI-navigation mode
	-- treats A like a confirm click) that has nothing to do with jump, PlatformStand, or anything a
	-- game script can disable; devforum reports confirm even ContextActionService:UnbindAction on the
	-- jump action does not clear it. onInputBegan's ordinary `if gameProcessed then return end` guard
	-- therefore swallowed ThrottleDown on every pad while ThrottleUp/AllStop/Release/Autopilot all
	-- worked -- "everything but decelerate". See that function's own comment for the fix.
	--
	-- ButtonY IS ALSO Prompt.UnloadGamepadKeyCode BELOW, and that overlap is known and safe rather than
	-- missed. Prompt.UnloadKeyCode's own header sets a stricter bar for the KEYBOARD -- it refused X
	-- because that is All Stop, on the grounds that a key spent on two jobs is "one rebind away from
	-- being a real collision" -- and the reason that bar does not reach here is that the risk behind it
	-- does not: neither of these two is rebindable, so nothing can move them together. What holds them
	-- apart is not luck but BlimpController.setPromptsSuppressed, which turns ProximityPromptService
	-- off outright for a mounted client. Four helm commands and four face buttons leaves no margin to
	-- spend on a hypothetical either.
	--
	-- STILL ON THE STANDING PLAYTEST LIST, with the rest of the gamepad scheme -- see
	-- Constants.Keybinds.GamepadChords' own note. This pair is reasoned, not measured.
	ThrottleUp = { Keyboard = Enum.KeyCode.W, Gamepad = Enum.KeyCode.ButtonY } :: BlimpTypes.HelmPressBinding,
	ThrottleDown = { Keyboard = Enum.KeyCode.S, Gamepad = Enum.KeyCode.ButtonA } :: BlimpTypes.HelmPressBinding,
	-- B/Circle is the near-universal cancel, which is what All Stop is: the panic press that rings the
	-- telegraph straight down from wherever it was. Its plain binding is Dash.
	AllStop = { Keyboard = Enum.KeyCode.X, Gamepad = Enum.KeyCode.ButtonB } :: BlimpTypes.HelmPressBinding,
	-- A MODE TOGGLE, so it can afford the one control here that takes a thumb off the stick -- exactly
	-- the trade Constants.Keybinds.GamepadDefaults.ShiftLock makes for itself, and against the same
	-- D-pad. A player picks the moment they arm an autopilot; they do not pick the moment they need
	-- rudder. DPadLeft is shift lock's own button, and shift lock is gated on Mounted.
	Autopilot = { Keyboard = Enum.KeyCode.G, Gamepad = Enum.KeyCode.DPadLeft } :: BlimpTypes.HelmPressBinding,
	-- THE ONE ROW WITH AN Action INSTEAD OF A KEYBOARD KEY, because on that device it genuinely is one:
	-- the release shares the rebindable Interact bind with the prompt that started the mount, and has
	-- since this feature shipped. Client/Input/Glyph.lua resolves the Action for the keyboard half and
	-- the KeyCode for the gamepad half, so the legend follows a rebind on one device and draws the
	-- pad's own button on the other.
	--
	-- ButtonX RATHER THAN THE CHORD Interact ACTUALLY HAS ON A PAD (ButtonL2+ButtonX, per
	-- Constants.Keybinds.GamepadChords). Two reasons, either sufficient. It is the button that put the
	-- player here -- a ProximityPrompt's GamepadKeyCode defaults to ButtonX and BlimpSystem leaves the
	-- station prompts at that default, so mounting and dismounting become the same press. And a chord
	-- is the answer to a full button budget, which is not the situation at a helm: asking a player to
	-- find a two-finger gesture to get off a ship heading out to sea is the wrong place to spend one.
	Release = { Action = "Interact", Gamepad = Enum.KeyCode.ButtonX } :: BlimpTypes.HelmPressBinding,
}

-- Helm input feel, read only by Client/Blimp/BlimpController.lua. Lives here rather than as two
-- module-locals over there for the same reason every other number in this file does: it is a thing a
-- designer retunes, and a retune should not require opening an input handler.
BlimpConstants.Input = {
	-- HOLDING W OR S WALKS THE LADDER. A tap moves one rung; keeping the key down moves the rest on a
	-- repeat, so getting from All Stop to Flank is one held key rather than five deliberate presses.
	--
	-- Modelled on a keyboard's own auto-repeat rather than on a fixed rate, and the initial delay is
	-- the load-bearing half: without it every single-rung tap would risk becoming two, and a pilot who
	-- means "one notch back" would get two. The delay is what makes the tap and the hold two different
	-- gestures rather than two lengths of the same one.
	TelegraphRepeatDelaySeconds = 0.38,
	-- Seconds between rungs once the repeat has started. Against the ladder's length this is a little
	-- over a second from All Stop to Flank -- fast enough to feel like one motion, slow enough that a
	-- pilot can still see the gauge pass through each rung and let go on the one they wanted.
	--
	-- Comfortably inside Network.MaxSpeedShiftPerSecond below, so a held key can never rate-limit
	-- itself into dropped rungs.
	TelegraphRepeatIntervalSeconds = 0.17,
	-- How far either held axis has to move before the pilot's client spends a packet on it. Exists
	-- because of the gamepad, and only because of it: a keyboard rudder is three discrete values, so
	-- the exact comparison this replaces was free and the send stream really did cost "one packet for
	-- a steady rudder" the way BlimpController.pumpHelmInput's own comment claims. A thumbstick's
	-- value is different at every sample, so that same comparison would be true every tick and turn a
	-- pilot holding a perfectly steady stick into a permanent IntentSendHz stream.
	--
	-- It is NOT a deadzone and must not grow into one -- a resting stick already reads as exactly
	-- Vector2.zero (Client/Input/Analog.ApplyStick returns it below the player's own deadzone), so
	-- there is no drift here for this number to absorb. It is the resolution below which two DIFFERENT
	-- rudder positions are not worth telling the server apart, and 1/50th of full deflection is far
	-- finer than a hull this heavy can express.
	HelmAxisEpsilon = 0.02,
}

BlimpConstants.Network = {
	RemoteNames = {
		-- Client -> server. The pilot's two HELD axes -- rudder and elevator -- at IntentSendHz. Named
		-- Set rather than Request because it carries no action to approve: the server clamps it and
		-- integrates it, and a non-pilot firing it is dropped at the gate.
		--
		-- CARRIES NO THROTTLE, which is the one thing to notice here. Throttle is a telegraph RUNG now
		-- (see SpeedStates above), owned server-side and moved by ShiftSpeedState below, so a Throttle
		-- field on this stream would be a value the server was contractually obliged to ignore sixty
		-- times a minute -- exactly the kind of dead wire field that later gets read by accident. See
		-- BlimpTypes.HelmInput, which is this payload's shape, and BlimpTypes.DriveIntent, which is the
		-- integrator's and still has all three.
		SetHelmInput = "Blimp_SetHelmInput",
		-- Client -> server, from the pilot only. Moves the engine telegraph by a signed number of rungs
		-- (BlimpSpeedLadder.Shift clamps it), or -- with a delta of 0 -- slams it to All Stop.
		--
		-- A DELTA RATHER THAN AN ABSOLUTE INDEX, deliberately: a rung index is a claim about a ladder
		-- whose length the client only knows because it read the same constants file, and the day a hull
		-- gets a bespoke ladder that stops being true silently. A delta is a claim about a KEYPRESS,
		-- which is the only thing the client actually witnessed.
		ShiftSpeedState = "Blimp_ShiftSpeedState",
		-- Client -> server, from the pilot only. Arms/disarms the autopilot latch -- see
		-- BlimpConstants.Autopilot. Its own remote rather than a field on SetHelmInput above because it
		-- is an EDGE (a press), and an edge riding on a 15Hz state stream is a press that can be missed
		-- or, worse, applied twice.
		ToggleAutopilot = "Blimp_ToggleAutopilot",
		-- Client -> server. Leave the station. Deliberately its own remote rather than a second
		-- ProximityPrompt: the prompt on an occupied station is disabled (BlimpSystem.setPromptEnabled)
		-- precisely so a passing player never sees a live "Take the Helm" on a wheel someone is holding.
		RequestDismount = "Blimp_RequestDismount",
		-- Server -> ALL clients. Someone mounted or dismounted; carries BlimpTypes.MountChangedPayload.
		MountChanged = "Blimp_MountChanged",
		-- Server -> the PILOT ONLY (FireClient, never broadcast). A snapshot of that blimp's fuel --
		-- BlimpTypes.FuelUpdatedPayload -- pushed on mount, on deposit, on a depleted-state edge, and
		-- whenever a whole unit of either resource has burned off since the last push. This is the
		-- pilot's own instrument panel, not a fact other players need (unlike MountChanged's arm-pose
		-- broadcast), and it is deliberately NOT a 60Hz stream -- the client extrapolates the live
		-- number between snapshots off the known burn rate, the same way HUD.lua's ability-cooldown
		-- countdown ticks a server-given total locally instead of being pushed every frame.
		FuelUpdated = "Blimp_FuelUpdated",
		-- Server -> EVERY player currently aboard one hull (FireClient per occupant, never a broadcast).
		-- BlimpTypes.HelmUpdatedPayload: the flight mode, the telegraph rung, and whether autopilot is
		-- armed.
		--
		-- PASSENGERS GET IT TOO, unlike FuelUpdated immediately above, and that asymmetry is the whole
		-- design of the two panels. Fuel is the pilot's instrument -- a number only the person who can
		-- do something about it needs. "We are descending on autopilot" is the SHIP's state, and a
		-- passenger who cannot see it has no way to tell an intentional landing from the pilot having
		-- died at the wheel.
		--
		-- CARRIES ONLY DISCRETE STATE -- no speed, no altitude, no heading. Those are continuous, they
		-- change every frame, and every client aboard is ALREADY reading them for free off the hull's
		-- own replicated velocity to drive the camera (Client/Camera/BlimpCamera.lua). Pushing them
		-- would be paying network for a number the receiver can already see. So this is an edge push:
		-- one packet per mode change, per rung change, per autopilot toggle, and nothing in between.
		HelmUpdated = "Blimp_HelmUpdated",
		-- Server -> the DEPOSITING player only (FireClient), once per furnace prompt press. Carries
		-- BlimpTypes.FuelTransferPayload: which way it went, and what it actually did.
		--
		-- CARRIES BOTH DIRECTIONS, load and unload, on one remote and one payload
		-- (BlimpTypes.FuelTransferPayload's own Action field). They are the same interaction at the
		-- same station with the same three outcomes and the same audience; two remotes would be two
		-- client handlers that have to agree about all of it.
		--
		-- THIS EXISTS BECAUSE THE PROMPT USED TO BE SILENT ON EVERY OUTCOME BUT ONE. A deposit that
		-- moved nothing -- the depositor carrying no coal and no water, or both tanks already full --
		-- returned early with no signal of any kind, and the two states that produce it are exactly
		-- the two a new player is most likely to be in. The reported symptom was "I cannot put any
		-- fuel into the furnace": the prompt appeared, the press was received, the handler ran, and
		-- the game said nothing either way. Pressing a prompt and being told nothing is
		-- indistinguishable from a broken prompt.
		--
		-- FIRED AT THE DEPOSITOR, NOT AT THE PILOT, and they are frequently not the same person --
		-- the whole point of putting this prompt on the hull rather than behind the helm is that
		-- ground crew can load a ship they are not flying (BlimpSystem.depositFuel's own header). The
		-- pilot's gauges are FuelUpdated's job and stay that way.
		FuelTransfer = "Blimp_FuelTransfer",
	},
	-- How often the pilot client pushes its axes. 15/s is far more than a vehicle this slow needs, and an
	-- order of magnitude below the rate limit below, so a pilot on a bad connection degrades to coarser
	-- steering rather than to rejected input.
	IntentSendHz = 15,
	-- Per-player-per-second budgets. Two buckets, not one, for the same reason EmoteSystem keeps its play
	-- and loadout limits apart: a steering stream must never be able to eat the dismount press that gets
	-- a player off a blimp heading out to sea.
	MaxIntentPerSecond = 30,
	MaxDismountPerSecond = 4,
	-- Its own bucket, for the same reason dismount has one: a rung change is how a pilot stops a ship
	-- that is heading somewhere they do not want it, and a flooded steering stream must never be able
	-- to eat it. Generous against a human hand on a key -- the client already edge-triggers, so a rung
	-- per press is the honest ceiling and this is several times that.
	MaxSpeedShiftPerSecond = 12,
	MaxAutopilotTogglePerSecond = 4,
	-- A furnace transfer moves a player's ENTIRE carried amount (or the tank's entire contents) in one
	-- call, so there is nothing to gain from spamming it -- this budget exists purely as the same "every server-mutating
	-- trigger gets a bucket" defense-in-depth every other remote/prompt handler in this codebase
	-- already carries, not because a fast pilot needs headroom.
	-- ONE BUCKET OVER BOTH DIRECTIONS, not one each: load and unload are the same station and the same
	-- hand, and a player alternating them as fast as they can press is doing one thing, not two
	-- independent ones that could starve each other (which is the test the split buckets above pass
	-- and this one does not).
	MaxFuelTransferPerSecond = 4,
}

return BlimpConstants
