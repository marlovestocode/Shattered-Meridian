--!strict
--[[
	BlimpWindVFX.lua

	Owns: the air a player aboard a blimp can actually SEE going past -- a volume of streaks that rides
	the viewer and is left behind in world space as the ship moves through it.

	THE SHIP MOVES; THE AIR DOES NOT. That sentence is the whole module. The obvious way to build wind
	is to animate particles flying backward past the camera at whatever speed a number says, and it is
	wrong in a way players feel without being able to name: the wind then has its own opinion about how
	fast the ship is going, and the two drift apart at exactly the moments that matter -- a turn, a
	rung change, a hull still carrying way after the engines cut. Here the particles are emitted around
	the viewer and then simply LEFT WHERE THEY WERE BORN (ParticleEmitter.LockedToPart = false, which
	is what makes a particle live in the world rather than follow its emitter). Nothing animates the
	rush. It IS the hull's velocity, seen against stationary air, and it is therefore correct for free
	in every case -- including the ones nobody thought to handle.

	Which is also why a blimp coasting to a stop watches its own wind die with nothing telling it to.

	IT IS DRIVEN OFF THE SAME MOTION SAMPLE AS THE CAMERA AND THE AUDIO -- Client/Camera/BlimpCamera's
	filtered hull physics, handed in rather than measured a fourth time. Three systems disagreeing
	about how fast the ship is going is three chances for the view, the sound and the air to contradict
	each other.

	THE ONE DELIBERATE LIE is a small backward drift of the particles' own, on top of the ship's
	motion (BlimpConstants.Wind.DriftFraction). It reads slightly faster than reality, which is roughly
	what an airship's own slipstream does near the hull -- and, load-bearing, ParticleEmitter.Orientation
	= VelocityParallel is the property that turns a round mote into a STREAK aligned with its own
	motion, and it needs a real velocity vector to align to. A particle that is honestly stationary in
	world space has none, and would render as a speck.

	THE VOLUME IS POSITIONED AND ORIENTED OFF THE HULL, NOT THE CAMERA -- the second correction this
	file has needed, after camera-relative positioning turned out to have its own failure mode. This
	game's blimp camera is a zoomed-out THIRD-PERSON CHASE view (see BlimpCamera's own header: "CameraType
	stays Custom throughout, so Roblox's own follow-cam keeps doing the mouse orbit") -- most of the time
	the viewer is watching their own ship from behind and above it, not standing at the wheel with their
	nose in the wind. A volume placed a handful of studs ahead of the CAMERA lands INSIDE OR BEHIND the
	ship's own hull from that framing -- the balloon and gondola sit between the camera and the emission
	point, occlude most of it, and what leaks out around the edges of the silhouette is exactly "wind
	coming from behind, below and to the side" instead of from in front. Anchoring both position (biased
	well ahead of the hull's own centre -- ForwardBiasStuds is sized to clear a real hull, not a camera's
	few-stud lead) and orientation (the hull's REAL velocity direction) to the SHIP fixes both problems at
	once: the volume sits in the open air ahead of the vessel where nothing occludes it regardless of how
	far back the chase camera has zoomed, and the emission direction still sweeps with a turn because it
	is still the ship's own, real, changing velocity vector -- never the camera's.

	WAVINESS IS A LIVE ACCELERATION, NOT A DIFFERENT SPAWN VELOCITY. Speed, EmissionDirection and
	SpreadAngle are each SNAPSHOTTED onto a particle at birth -- changing them after the fact only
	affects particles born from then on, which is exactly why they were the wrong tool for "clean ahead,
	then wavy as it passes": a snapshot can't change over one particle's own lifetime. Acceleration is
	the one motion property ParticleEmitter keeps applying to particles ALREADY in flight, every frame,
	for as long as they live -- so a streak is born straight and clean far out, and the same slow gust +
	turn-sway term (BlimpConstants.Wind.Turbulence) bends it more the longer it has been alive, which is
	naturally the moment it is closest to and passing the viewer. See Update's own comment for the two
	terms this composes (an ambient gust that never repeats, and a sway proportional to the hull's own
	yaw rate -- the turning cue).

	ONE PART, ONE EMITTER, FOR THE WHOLE SESSION. Acquired lazily on the first mount anybody ever makes
	and then reused -- most players never board a blimp, so building it at boot would cost every client
	in the server a Part and an emitter for a feature they will not touch. Between rides it is parked
	with its emitter disabled, which is genuinely free (an emitter at Rate 0 is still an emitter the
	renderer walks; a disabled one is not).

	Does not own: measuring the hull (Client/Camera/BlimpCamera.GetMotion, via Shared/Blimp/
	BlimpCameraMath.lua), when a mount begins or ends (Client/Blimp/BlimpController.lua), the tuning
	(Shared/Blimp/BlimpConstants.Wind), or the two audio loops that answer the same sample
	(Client/FX/BlimpAudio.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local BlimpConstants = require(ReplicatedStorage.Shared.Blimp.BlimpConstants)
local FlightMath = require(ReplicatedStorage.Shared.FlightMath)

local FXPool = require(script.Parent.FXPool)

local BlimpWindVFX = {}

local CONFIG = BlimpConstants.Wind

local field: Part? = nil
local emitter: ParticleEmitter? = nil

local active = false
-- The eased 0..1 intensity the emitter is actually showing, as distinct from the raw speed fraction
-- it is chasing. The particles themselves cannot ease -- each is born at whatever rate was set on its
-- frame -- so this is the only thing standing between a rung change and the weather switching.
local intensity = 0
-- Last values actually written, so a steady cruise stops writing properties entirely. Seeded to a
-- sentinel no real frame produces so the first frame after a mount always writes.
local lastRate = -1
local lastSpeed = -1

-- Seconds since this ride began -- the clock behind the turbulence gust, same "per-mount phase rather
-- than os.clock()" reasoning BlimpCameraMath.State.Elapsed already documents for the engine rumble.
local elapsed = 0

-- A persistent, unreplicated container -- same "off any world Model so nothing destroyed mid-effect
-- takes the instance with it" reasoning Client/FX/HitFlash.lua's and FlightVFX.lua's holders use, and
-- the same shared lazy-create helper.
local function getHolder(): Folder
	return FXPool.GetHolder("BlimpWindHolder", function(): Instance
		return Workspace
	end)
end

local function ensureField(): (Part, ParticleEmitter)
	local existingField, existingEmitter = field, emitter
	if existingField and existingEmitter and existingField.Parent then
		return existingField, existingEmitter
	end

	local part = Instance.new("Part")
	part.Name = "BlimpWindField"
	part.Size = CONFIG.VolumeStuds
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	-- A ParticleEmitter parented to a Part spawns from a random point inside that part's volume, which
	-- is the entire reason this is a Part rather than an Attachment: the emission volume IS the size
	-- above, with no ParticleEmitter.Shape configuration to get wrong.
	part.Parent = getHolder()

	local particles = Instance.new("ParticleEmitter")
	particles.Name = "Wind"
	particles.Texture = CONFIG.Texture
	particles.Color = ColorSequence.new(CONFIG.Color)
	particles.Lifetime = CONFIG.LifetimeSeconds
	particles.Rate = 0
	particles.SpreadAngle = Vector2.new(CONFIG.SpreadDegrees, CONFIG.SpreadDegrees)
	-- Emitted along the part's own Front face, which is its LookVector -- Update below aims that
	-- backward along the direction of travel, so the streaks run with the airflow rather than across it.
	particles.EmissionDirection = Enum.NormalId.Front
	-- THE LOAD-BEARING PROPERTY. False means a particle is placed in the world at birth and stays
	-- there; the rush past the deck is the emitter (riding the viewer) moving away from particles that
	-- are not moving. True would weld the whole field to the camera and the wind would freeze solid.
	particles.LockedToPart = false
	-- Zero, deliberately: inheriting the emitter's velocity would carry every particle along WITH the
	-- ship, which is the same freeze as LockedToPart by another route.
	particles.VelocityInheritance = 0
	particles.Acceleration = Vector3.zero
	particles.Drag = 0
	-- Aligns each streak with its own velocity -- see this file's header on why the particles are given
	-- a drift at all.
	particles.Orientation = Enum.ParticleOrientation.VelocityParallel
	particles.Squash = NumberSequence.new(CONFIG.Squash)
	-- Grown in and out by size as well as by opacity, so a streak enters and leaves the world rather
	-- than blinking into it.
	particles.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.35, CONFIG.StreakStuds),
		NumberSequenceKeypoint.new(1, 0),
	})
	particles.LightEmission = CONFIG.LightEmission
	particles.LightInfluence = 0
	particles.Enabled = false
	particles.Parent = part

	field = part
	emitter = particles
	return part, particles
end

-- The transparency ramp for a given intensity. Rebuilt per change rather than held at peak and scaled
-- some other way, because a NumberSequence is the only per-particle opacity ParticleEmitter has -- and
-- the whole ramp has to move together or the fade-in and fade-out stop matching.
local function transparencyFor(level: number): NumberSequence
	local peak = 1 - (1 - CONFIG.PeakTransparency) * level
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.3, peak),
		NumberSequenceKeypoint.new(1, 1),
	})
end

-- Begins a ride. Idempotent, and cheap to call on every mount -- the Part and emitter are built once
-- for the session on the first call and reused forever after.
function BlimpWindVFX.Start(): ()
	if active then
		return
	end
	active = true
	intensity = 0
	lastRate = -1
	lastSpeed = -1
	elapsed = 0
	local _part, particles = ensureField()
	particles.Rate = 0
	particles.Transparency = transparencyFor(0)
	particles.Enabled = true
end

-- Ends it. The already-live particles are deliberately NOT cleared: they are in world space, they have
-- half a second of life left, and letting them run out is a player stepping off a moving ship and
-- watching the last of its slipstream go past -- which is both free and more correct than a cut.
function BlimpWindVFX.Stop(): ()
	if not active then
		return
	end
	active = false
	local particles = emitter
	if particles then
		particles.Enabled = false
		particles.Rate = 0
	end
	lastRate = -1
	lastSpeed = -1
end

-- One frame. `hullCFrame` is the assembly root's own replicated CFrame -- its Position anchors the
-- volume (see file header on why that's the hull's job now, not the camera's). `hullVelocity` is the
-- same assembly's replicated velocity, RAW -- both its Magnitude (intensity) and its Unit (which way
-- particles actually launch, and where the volume sits relative to the hull) are used here. `yawRate`
-- is the same filtered radians/second BlimpCamera.GetMotion() already hands the camera and the
-- telemetry readout -- the turning cue, not a fourth measurement of it. `cruiseSpeed` is THIS hull's
-- own resolved cruise speed, so a blimp tuned to half speed still reaches full weather at ITS full
-- speed.
--
-- AND THE FRACTION IS DERIVED HERE, UNSIGNED, rather than taken from the camera's own SpeedFraction.
-- That one is deliberately signed-and-clamped-to-zero (see BlimpCameraMath.Motion) because a pull-back
-- and an FOV widen answer "how fast is this going", and backing out of a mooring is not fast. Air does
-- not care which way you are pointed: a hull making way astern is moving through exactly as much of it,
-- and reusing the camera's fraction here would have shown a dead-calm sky on every reverse.
--
-- Silently ignored while stopped, so a caller needs no "am I aboard" check of its own.
function BlimpWindVFX.Update(
	hullCFrame: CFrame,
	hullVelocity: Vector3,
	yawRate: number,
	cruiseSpeed: number,
	deltaTime: number
): ()
	if not active then
		return
	end
	local particles = emitter
	local part = field
	if not particles or not part then
		return
	end

	local absoluteSpeed = hullVelocity.Magnitude

	-- Below the floor the emitter is switched OFF rather than run at zero -- see
	-- BlimpConstants.Wind.MinimumSpeed. A moored blimp should cost nothing at all.
	if absoluteSpeed < CONFIG.MinimumSpeed then
		if particles.Enabled then
			particles.Enabled = false
			particles.Rate = 0
			lastRate = -1
		end
		intensity = 0
		return
	end
	if not particles.Enabled then
		particles.Enabled = true
	end
	elapsed += deltaTime

	local target = math.clamp(absoluteSpeed / math.max(cruiseSpeed, 1), 0, 1)
	intensity += (target - intensity) * FlightMath.EaseAlpha(CONFIG.IntensityEaseSpeed, deltaTime)

	-- BOTH position and orientation are the hull's own, real travel direction now -- see file header on
	-- why a camera-relative volume ended up occluded by the ship it was meant to fly into. Biased well
	-- ahead of the hull's CENTRE (ForwardBiasStuds is sized to clear a real hull's length, not a
	-- camera's few-stud lead), so the volume sits in open air ahead of the vessel regardless of how far
	-- back a chase camera has zoomed. absoluteSpeed is already confirmed >= MinimumSpeed (well above
	-- zero) by the guard above, so .Unit is always safe here.
	local travelDirection = hullVelocity.Unit
	local centre = hullCFrame.Position + travelDirection * CONFIG.ForwardBiasStuds
	-- AIMED BACKWARD -- a part's Front face is its LookVector, so looking back along travel sends the
	-- streaks the way the air is going.
	part.CFrame = CFrame.lookAt(centre, centre - travelDirection)

	-- Quantized before the comparison so a hull holding a steady speed stops writing properties
	-- altogether -- the same "the single most expensive thing a per-frame system can do for no effect"
	-- reasoning Client/FX/CameraOffsetComposer.lua's own conditional write documents.
	local rate = math.floor(intensity * CONFIG.MaxRate)
	if rate ~= lastRate then
		lastRate = rate
		particles.Rate = rate
		particles.Transparency = transparencyFor(intensity)
	end

	local drift = math.floor(absoluteSpeed * CONFIG.DriftFraction)
	if drift ~= lastSpeed then
		lastSpeed = drift
		particles.Speed = NumberRange.new(drift * 0.8, drift * 1.2)
	end

	-- WAVINESS + TURN SWAY -- a live Acceleration, written every frame regardless of whether it changed
	-- (unlike Rate/Speed above): it is a Vector3 with no cheap "did this actually change" comparison
	-- worth making, and unlike those two, this is the one property meant to keep nudging particles
	-- already in flight -- see file header on why that's the point.
	--
	-- Two terms on the same horizontal-right axis (perpendicular to travel, same construction
	-- BlimpCameraMath.Observe uses for its own rightAxis):
	--   * An ambient gust -- two incommensurate sines, same "never visibly repeats" technique
	--     BlimpConstants.Camera.Rumble already uses, just an order of magnitude slower (this is a sway,
	--     not machinery).
	--   * A turn sway proportional to yawRate -- the wind shear a real turn produces, made visible.
	--     Signed so a turn to starboard sweeps the streaks the opposite way, matching which side the air
	--     is being shoved off of.
	local turbulence = CONFIG.Turbulence
	local rightAxis = Vector3.new(-travelDirection.Z, 0, travelDirection.X)
	local gustPhase = elapsed * turbulence.Frequency
	local gust = (math.sin(gustPhase) * 0.6 + math.sin(gustPhase * turbulence.BeatRatio) * 0.4)
		* turbulence.MaxGustAccelStuds
	local turnSway = math.clamp(
		yawRate * turbulence.TurnAccelPerYawRate,
		-turbulence.MaxTurnAccelStuds,
		turbulence.MaxTurnAccelStuds
	)
	particles.Acceleration = rightAxis * (gust + turnSway)
end

return BlimpWindVFX
