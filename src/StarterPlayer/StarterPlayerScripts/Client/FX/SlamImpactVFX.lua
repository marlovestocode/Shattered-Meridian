--!strict
--[[
	SlamImpactVFX.lua

	Owns: the ground-impact payoff for a Downslam finisher (Constants.Combat.Finisher.Downslam /
	Server/Combat/RagdollController.SlamToGround, plus the air-combo's own MaxHits slam --
	Server/Combat/AirCombo.lua reuses the identical SlamToGround call) -- a particle burst, physical
	debris chunks, and an expanding shockwave ring, all colored/shaped after whatever ground surface the
	slammed body actually lands on.

	Also owns DETECTING that moment -- mostly. SlamToGround is fire-and-forget velocity (gravity and
	the replicated ragdoll physics do the rest, see that function's own header), and for a GENUINE fall
	(real clearance beneath the target) this module watches the target's already-replicated
	HumanoidRootPart on Heartbeat and infers "hit the ground" from its own downward velocity arresting
	-- purely local presentation, driven off already-replicated state, same as MovementVFX/FlightVFX's
	own headers establish for every other module in this library.

	That inference structurally cannot catch the OTHER common case, though: a slam clamped down to
	near-zero usable drop (a target already standing on the ground -- the majority of both the M1
	finisher's own Downslam and the standalone AirSlam attack). That body falls its whole clamped
	distance and fully arrests within a single physics step, often within a single Heartbeat interval,
	sometimes within a single network replication snapshot -- there may be no sampleable "falling fast"
	frame at all, or the transient velocity may never even be sent to this client. For that case,
	BeginWatch's own `immediateImpact` parameter (Types.CombatFeedbackPayload.ImmediateGroundImpact)
	skips detection entirely: RagdollController.SlamToGround already knows authoritatively (Constants.
	Combat.Ragdoll.SlamImmediateImpactDropStuds) that this is the near-instant case, so it says so
	instead of leaving the client to guess at something it may be unable to observe at all.

	BeginWatch is called once per landed Downslam by BOTH the attacker's and the target's own clients
	(Client/Combat/CombatClient.lua's Combat_FeedbackEvent handler, gated exactly the way HitStop/
	CameraShake already gate every other combat FX call -- "only the two clients who actually received
	this feedback event," see HitStop.lua's header for why that's this codebase's existing convention,
	not a new one invented here). Each client watches the SAME shared replicated body independently and
	renders its own local copy of the impact VFX -- correct and cheap, the same "every client reacts to
	its own locally-visible replicated state" model every other FX call in this codebase already uses.
	A spectator not involved in the exchange never receives the feedback event that would start a watch,
	so they never see the impact either -- consistent with every other combat FX in this file (camera
	shake, hit-stop, hit-flash), not a gap specific to this feature.

	Scoped to targets resolvable to a live Player character (Combat_FeedbackEvent's TargetUserId) --
	a training dummy/bot target has no client-visible Instance reference on the feedback payload, only a
	stale hit-time TargetPosition, which isn't enough to track a moving ragdoll's actual ground contact.
	CombatClient.lua simply never calls BeginWatch for those targets; see its own call site comment.

	Does NOT own camera shake or hit-stop -- same split FlightVFX/FlightController.lua already
	establishes (FlightVFX owns the world-space ring; FlightController orchestrates shake/hit-stop
	alongside it). Because the exact impact MOMENT is only known once this module's own Heartbeat watch
	detects it, BeginWatch takes an `onImpact` callback rather than exposing a way to poll for the
	answer -- CombatClient.lua uses it to fire CameraShake.Shake(Constants.FX.CameraShake.FinisherSlam)
	and HitStop.FreezeAttacker/FreezeVictim at the exact same beat the ground VFX plays.

	Ground "mesh" without a mesh asset: this codebase has zero VFX/mesh assets budgeted (StunEffect.lua's
	own header) and this feature's own spec explicitly forbids guessing an asset id, so "matching the
	mesh of what they were slammed on" is read as matching PartType/proportions (jagged blocky rubble for
	stone/concrete, thin elongated splinters for wood, small round clumps for soft ground) rather than a
	literal mesh -- see Constants.FX.SlamImpact.DebrisKindByFloorMaterial's own header. Material and
	Color always come directly from a raycast against the real ground hit (that table only decides the
	debris SHAPE) -- see resolveGroundHit below.
]]

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local FXPool = require(script.Parent.FXPool)

local logger = Logger.scope("SlamImpactVFX")

local CONFIG = Constants.FX.SlamImpact

local SlamImpactVFX = {}

-- Holder ---------------------------------------------------------------------

-- A persistent, unreplicated container the pooled particles/debris/rings live under while active --
-- same "off any world Model so nothing destroyed mid-effect takes a pooled instance with it" reasoning
-- HitFlash.lua/FlightVFX.lua/MovementVFX.lua's own holders use. Lazily created via FXPool.GetHolder,
-- shared slot-space with those (each keyed by its own name).
local function getHolder(): Folder
	return FXPool.GetHolder("SlamImpactVFXHolder", function(): Instance
		return Workspace
	end)
end

-- Particle burst ---------------------------------------------------------------

local function makeParticleCarrier(): Part
	local part = Instance.new("Part")
	part.Name = "SlamImpactDustCarrier"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = CONFIG.Particle.CarrierPartSize
	part.Parent = nil

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "SlamDust"
	-- Reuses MovementDust's own sourced dust-puff sprite -- see this file's header and
	-- Constants.FX.SlamImpact's own comment for why, not a second copy of the same asset id.
	emitter.Texture = Constants.FX.MovementDust.Texture
	emitter.LightEmission = 0
	emitter.LightInfluence = 1
	emitter.Enabled = false
	emitter.Rate = 0
	emitter.Lifetime = NumberRange.new(CONFIG.Particle.LifetimeSeconds * 0.6, CONFIG.Particle.LifetimeSeconds)
	emitter.Speed = CONFIG.Particle.Speed
	emitter.SpreadAngle = CONFIG.Particle.SpreadAngle
	emitter.Size = CONFIG.Particle.SizeSequence
	emitter.Transparency = CONFIG.Particle.TransparencySequence
	emitter.Parent = part
	return part
end

local function resetParticleCarrier(part: Part): ()
	part.Parent = nil
end

local particlePool = FXPool.New(makeParticleCarrier, resetParticleCarrier, CONFIG.Particle.PoolMaxSize)

local function playParticleBurst(position: Vector3, color: Color3): ()
	local part = particlePool:Acquire()
	if not part then
		logger:debug("Particle pool at cap -- dropping slam-impact burst")
		return
	end
	local emitter = part:FindFirstChildOfClass("ParticleEmitter") :: ParticleEmitter
	emitter.Color = ColorSequence.new(color)
	part.CFrame = CFrame.new(position)
	part.Parent = getHolder()
	emitter:Emit(CONFIG.Particle.BurstCount)

	task.delay(CONFIG.Particle.LifetimeSeconds, function()
		particlePool:Release(part)
	end)
end

-- Physical debris chunks --------------------------------------------------------

local function makeDebrisChunk(): Part
	local part = Instance.new("Part")
	part.Name = "SlamDebris"
	part.Anchored = false
	-- See Constants.FX.SlamImpact.Debris's own header for why these stay false even though the chunk
	-- is otherwise a real, gravity-affected physics body -- a purely cosmetic, client-only, short-lived
	-- effect earning real collision would be a gameplay-affecting side effect for nothing gained.
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Parent = nil
	return part
end

local function resetDebrisChunk(part: Part): ()
	part.Parent = nil
	part.AssemblyLinearVelocity = Vector3.zero
	part.AssemblyAngularVelocity = Vector3.zero
	part.Transparency = 0
	part.Shape = Enum.PartType.Block
end

local debrisPool = FXPool.New(makeDebrisChunk, resetDebrisChunk, CONFIG.Debris.PoolMaxSize)

local function randomInRange(range: NumberRange): number
	return range.Min + math.random() * (range.Max - range.Min)
end

-- Silhouette only -- see this file's header on why shape (not a real mesh asset) is what "matching the
-- mesh of what they were slammed on" means here. Material/Color are set by the caller from the real
-- ground hit, never derived from `kind`.
local function sizeAndShapeFor(kind: string): (Vector3, Enum.PartType)
	if kind == "Wood" then
		local long = randomInRange(CONFIG.Debris.WoodLongSize)
		local thinA = randomInRange(CONFIG.Debris.WoodThinSize)
		local thinB = randomInRange(CONFIG.Debris.WoodThinSize)
		return Vector3.new(long, thinA, thinB), Enum.PartType.Block
	elseif kind == "Soft" then
		local size = randomInRange(CONFIG.Debris.SoftSize)
		return Vector3.new(size, size, size), Enum.PartType.Ball
	end
	-- "Rock" (and any unclassified material, per DefaultDebrisKind) -- jittered near-cubic block, and a
	-- Wedge roughly a third of the time so the rubble reads as jagged/broken rather than uniform cubes.
	local sizeX = randomInRange(CONFIG.Debris.RockSize)
	local sizeY = randomInRange(CONFIG.Debris.RockSize)
	local sizeZ = randomInRange(CONFIG.Debris.RockSize)
	local shape = if math.random() < 0.3 then Enum.PartType.Wedge else Enum.PartType.Block
	return Vector3.new(sizeX, sizeY, sizeZ), shape
end

local function spawnDebrisChunk(position: Vector3, material: Enum.Material, color: Color3, kind: string): ()
	local part = debrisPool:Acquire()
	if not part then
		return
	end

	local size, shape = sizeAndShapeFor(kind)
	part.Shape = shape
	part.Size = size
	part.Material = material
	part.Color = color

	local outwardAngle = math.random() * math.pi * 2
	local outwardSpeed = randomInRange(CONFIG.Debris.OutwardSpeed)
	local horizontal = Vector3.new(math.cos(outwardAngle), 0, math.sin(outwardAngle)) * outwardSpeed
	local upward = randomInRange(CONFIG.Debris.UpwardSpeed)

	part.CFrame = CFrame.new(position)
		* CFrame.Angles(math.random() * math.pi * 2, math.random() * math.pi * 2, math.random() * math.pi * 2)
	part.Parent = getHolder()
	part.AssemblyLinearVelocity = horizontal + Vector3.new(0, upward, 0)
	part.AssemblyAngularVelocity = Vector3.new(
		randomInRange(CONFIG.Debris.AngularSpeed),
		randomInRange(CONFIG.Debris.AngularSpeed),
		randomInRange(CONFIG.Debris.AngularSpeed)
	)

	local fadeDelay = math.max(0, CONFIG.Debris.LifetimeSeconds - CONFIG.Debris.FadeOutSeconds)
	task.delay(fadeDelay, function()
		if part.Parent then
			TweenService:Create(
				part,
				TweenInfo.new(CONFIG.Debris.FadeOutSeconds, Enum.EasingStyle.Sine, Enum.EasingDirection.In),
				{ Transparency = 1 }
			):Play()
		end
	end)
	task.delay(CONFIG.Debris.LifetimeSeconds, function()
		debrisPool:Release(part)
	end)
end

-- Shockwave ring ---------------------------------------------------------------

-- Same flattened-cylinder "expanding flat ring" shape FlightVFX.lua's own rings use, on its OWN pool
-- (see Constants.FX.SlamImpact.Ring's own header for why this doesn't share FlightVFX's pool).
local function makeRing(): Part
	local part = Instance.new("Part")
	part.Name = "SlamImpactRing"
	part.Shape = Enum.PartType.Cylinder
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Size = CONFIG.Ring.StartSize
	part.Parent = nil
	return part
end

local function resetRing(part: Part): ()
	part.Parent = nil
end

local ringPool = FXPool.New(makeRing, resetRing, CONFIG.Ring.PoolMaxSize)

local function playRing(position: Vector3, color: Color3): ()
	local part = ringPool:Acquire()
	if not part then
		return
	end
	part.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
	part.Color = color
	part.Transparency = CONFIG.Ring.StartTransparency
	part.Size = CONFIG.Ring.StartSize
	part.Parent = getHolder()

	local diameter = CONFIG.Ring.MaxRadiusStuds * 2
	local tween = TweenService:Create(
		part,
		TweenInfo.new(CONFIG.Ring.ExpandDurationSeconds, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
		{ Size = Vector3.new(0.2, diameter, diameter), Transparency = 1 }
	)
	tween:Play()
	tween.Completed:Once(function()
		ringPool:Release(part)
	end)
end

-- Ground detection --------------------------------------------------------------

-- Finds the real ground BasePart/Terrain the slam landed on, straight down from `position` (the
-- ragdoll's HumanoidRootPart, roughly chest height -- NOT ground level). Excludes `ignoreInstance` (the
-- ragdolled character) so its own limbs never self-hit. Returns the material, a best-effort ground
-- color (Terrain's own configured color for that material via Terrain:GetMaterialColor for a terrain
-- hit, the hit part's own Color for a regular BasePart, or the shared Constants.FX.MovementDust.
-- ColorByFloorMaterial fallback if the raycast finds nothing at all -- e.g. the slam landed over open
-- air/void), and the actual ground-level Position the ray hit -- the caller needs this to spawn the
-- burst/debris/ring AT the floor rather than floating at the root part's own torso height.
local function resolveGroundHit(position: Vector3, ignoreInstance: Instance): (Enum.Material, Color3, Vector3)
	local origin = position + Vector3.new(0, CONFIG.GroundRaycastStartHeightStuds, 0)
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = { ignoreInstance }
	raycastParams.IgnoreWater = true

	local result = Workspace:Raycast(origin, Vector3.new(0, -CONFIG.GroundRaycastDistanceStuds, 0), raycastParams)
	if not result then
		-- No ground found within range (open air/void) -- nothing to snap to, fall back to the root
		-- part's own position rather than leaving the caller with no coordinate at all.
		return Enum.Material.Plastic, Constants.FX.MovementDust.DefaultColor, position
	end

	local material = result.Material
	local colorLookup = Constants.FX.MovementDust.ColorByFloorMaterial :: { [Enum.Material]: Color3 }
	if result.Instance == Workspace.Terrain then
		local ok, terrainColor = pcall(function()
			return (Workspace.Terrain :: Terrain):GetMaterialColor(material)
		end)
		if ok then
			return material, terrainColor, result.Position
		end
	elseif result.Instance:IsA("BasePart") then
		return material, (result.Instance :: BasePart).Color, result.Position
	end

	return material, colorLookup[material] or Constants.FX.MovementDust.DefaultColor, result.Position
end

-- Fires the full impact -- particles, debris, ring. `character` is only used to exclude the ragdolled
-- body from its own ground raycast. `rootPosition` is the ragdoll's HumanoidRootPart position (used
-- only to aim the downward raycast); the VFX itself spawns at the raycast's own ground-level hit point,
-- not at rootPosition -- see resolveGroundHit's header for why those two differ.
local function triggerImpact(rootPosition: Vector3, character: Model): ()
	local material, color, groundPosition = resolveGroundHit(rootPosition, character)
	local kindLookup = CONFIG.DebrisKindByFloorMaterial :: { [Enum.Material]: string }
	local kind = kindLookup[material] or CONFIG.DefaultDebrisKind

	playParticleBurst(groundPosition, color)
	playRing(groundPosition, color)
	for _ = 1, CONFIG.Debris.Count do
		spawnDebrisChunk(groundPosition, material, color, kind)
	end
	logger:debug("Slam impact VFX played", { material = material.Name, kind = kind })
end

-- Impact watch --------------------------------------------------------------

-- One generation counter per watched character so a NEW slam landing on the same body (re-slammed
-- before a prior watch resolved -- rare, but possible via overlapping AirSlams/air-combo sequences)
-- invalidates the OLD watch instead of letting two overlapping loops both eventually fire.
local watchGeneration: { [Model]: number } = {}

-- Watches `character`'s HumanoidRootPart for the moment a fast downward fall arrests (ground contact),
-- then plays the impact VFX there and invokes `onImpact` (if given) with the same world position -- see
-- this file's header for why camera shake/hit-stop are the CALLER's responsibility, fired off that
-- callback rather than owned here. Safe to call from both the attacker's and the target's own client for
-- the same slam (each just watches its own locally-replicated copy of the body independently). No-op if
-- `character` has no HumanoidRootPart right now. Bounded by CONFIG.MaxWatchSeconds so a body that dies,
-- despawns, or never arrests (falls into the void) can't leave a dangling watch running forever.
--
-- `immediateImpact` (Types.CombatFeedbackPayload.ImmediateGroundImpact) bypasses the fall-then-arrest
-- poll below entirely when true. That poll infers a physics event from Heartbeat-rate (~60Hz) samples
-- of REPLICATED velocity, which works fine for a genuine multi-frame fall (there are many chances to
-- sample it mid-fall) but structurally can't catch a slam clamped down to near-zero usable drop (a
-- target already standing on the ground -- the common case for both the M1 finisher's own Downslam and
-- the standalone AirSlam attack): that body falls its entire clamped distance and fully arrests within
-- a single physics step, often within a single Heartbeat interval, sometimes within a single network
-- replication snapshot -- the transient fast-falling velocity this poll looks for may never be sampled,
-- or may never even be sent to this client at all. RagdollController.SlamToGround already knows,
-- authoritatively, whether this is that case (Constants.Combat.Ragdoll.SlamImmediateImpactDropStuds),
-- so when it says so, this just plays the impact after a short fixed settle delay instead of guessing.
function SlamImpactVFX.BeginWatch(character: Model, onImpact: ((Vector3) -> ())?, immediateImpact: boolean?): ()
	local rootPartInstance = character:FindFirstChild("HumanoidRootPart")
	if not rootPartInstance or not rootPartInstance:IsA("BasePart") then
		return
	end
	local rootPart = rootPartInstance

	local generation = (watchGeneration[character] or 0) + 1
	watchGeneration[character] = generation

	-- Releases this watch's ownership of `character`'s entry in watchGeneration -- guarded by the
	-- same generation-equality check every read/write here already uses, since a NEWER watch may
	-- have already taken over `character` (re-slammed before this one resolved), in which case ITS
	-- generation is the live one and must not be clobbered. Without this, watchGeneration never drops
	-- a key: a Luau table key is a strong reference, so every watched slam permanently pinned the
	-- entire destroyed character Model (once it died/respawned) for the rest of the client session.
	local function releaseWatch(): ()
		if watchGeneration[character] == generation then
			watchGeneration[character] = nil
		end
	end

	local function fireImpact(): ()
		if watchGeneration[character] ~= generation or not rootPart.Parent then
			return
		end
		local okPosition, position = pcall(function()
			return rootPart.Position
		end)
		if okPosition then
			triggerImpact(position, character)
			if onImpact then
				onImpact(position)
			end
		end
		-- This watch has resolved (fired, or failed to read a position on an already-dying body) --
		-- release it either way, same as every other terminal branch below.
		releaseWatch()
	end

	if immediateImpact then
		task.delay(CONFIG.ImmediateImpactDelaySeconds, fireImpact)
		return
	end

	local startClock = os.clock()
	local observedFastFall = false
	local connection: RBXScriptConnection? = nil

	local function stopWatch(): ()
		if connection then
			connection:Disconnect()
			connection = nil
		end
	end

	connection = RunService.Heartbeat:Connect(function()
		if watchGeneration[character] ~= generation then
			-- Superseded by a newer watch on the same character -- stop quietly, the newer watch owns
			-- reporting this body's next impact (and already owns the table entry -- do NOT release
			-- it here, that would delete the newer watch's own generation out from under it).
			stopWatch()
			return
		end
		if os.clock() - startClock >= CONFIG.MaxWatchSeconds then
			-- Gave up without ever firing (fell into the void, or just never arrested) -- nothing else
			-- will ever release this watch's entry, so it must happen here.
			stopWatch()
			releaseWatch()
			return
		end

		local ok, velocity = pcall(function()
			return rootPart.AssemblyLinearVelocity
		end)
		if not ok or not rootPart.Parent then
			-- Character died/despawned mid-slam, or the part was destroyed -- give up cleanly, no VFX,
			-- and release the same as the MaxWatchSeconds give-up above.
			stopWatch()
			releaseWatch()
			return
		end

		if velocity.Y <= -CONFIG.FastFallSpeedThreshold then
			observedFastFall = true
		end

		if observedFastFall and math.abs(velocity.Y) <= CONFIG.ImpactArrestSpeedThreshold then
			-- stopWatch() only disconnects the Heartbeat -- release happens inside fireImpact() below
			-- (called next), never here, so its own watchGeneration[character] ~= generation guard
			-- still sees this watch's real generation and doesn't spuriously bail on itself.
			stopWatch()
			fireImpact()
		end
	end)
end

return SlamImpactVFX
