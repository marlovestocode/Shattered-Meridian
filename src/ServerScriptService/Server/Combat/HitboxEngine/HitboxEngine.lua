--!strict
--[[
	HitboxEngine.lua

	Owns: everything about WHERE an attack's damage volume is and WHO is inside it. Registration of
	combatants, the attack lifecycle, its own Heartbeat, substepped sampling, dynamic sizing, the
	per-swing hit budget, and one output signal.

	It reports hits. It does not decide what a hit means.

	That sentence is the entire boundary, and it is the reason this module exists at all. The system
	this replaces (Server/Systems/CombatSystem.lua, ~4,900 lines) fused hit detection with damage,
	posture, blocking, parry resolution, ragdoll, knockback, status effects, animation, audio, VFX and
	networking, so no part of it could be reasoned about -- or replaced -- without the others. Here,
	damage does not appear. Blocking does not appear. Nothing in this file knows what a Player is.
	A future consumer layer subscribes to OnHit and decides all of it; that layer can be rewritten
	without touching a line of geometry, and this engine can be tested without one existing.

	The same discipline is what makes registration domain-agnostic: a player, a training bot and an
	inert dummy are the same thing to this module -- a Model, a root part and a Humanoid -- exactly as
	Server/Combat/ObjectStunResolver.lua refuses to learn what a Player is. ComboStage and PowerLevel
	arrive as plain numbers from the caller; the engine scales a volume with them and never asks
	whether they came from a combo counter, a Qi pool or a cultivation Tier.

	HOW A HITBOX "ACTUALLY STAYS", which is the thing the user asked for and the thing naive Roblox
	hitboxes get wrong. Three mechanisms, none of which is optional:

	  1. THE POSE IS NEVER BAKED. The hitbox's world CFrame is recomposed from the attachment part's
	     LIVE CFrame at every single sample. Resolving it once when the swing starts -- which is the
	     common shortcut -- produces a volume hanging in the air where the attacker used to be, which
	     is why so many attacks appear to hit behind a moving target.
	  2. SAMPLING IS DECOUPLED FROM FRAME RATE. A Heartbeat that delivers more than
	     MinSubstepSeconds is subdivided, and the WHOLE pipeline -- state machine advancement as well
	     as sampling -- runs at each substep against interpolated poses. This fixes two distinct
	     failures with one mechanism: a fast swing tunnelling between samples, and a short Active
	     window falling entirely between two Heartbeats on a loaded server. See
	     HitboxEngineConstants' header.
	  3. CONTACT IS CONTINUOUS, NOT INSTANTANEOUS. Every candidate is tested against the volume swept
	     between the previous sample's pose and this one's, not just against the volume at this one.
	     Substepping shrinks the gap; the swept test closes what is left of it.

	SERVER-AUTHORITATIVE, WITH NO CLIENT PREDICTION, by explicit choice. There is no rollback, no
	client mirror, no remote in this file, and the deleted PredictionMirror/CombatClient pair is not
	being rebuilt. The engine's answer is the only answer. Substepping is what buys back the
	responsiveness prediction would have -- a swing's Active window is honoured at its authored
	timing regardless of server frame rate -- without any of the reconciliation surface.

	LAG COMPENSATION IS NOT THAT (2026-10-07, owner-requested). The engine keeps a short history of where
	every body was (PoseHistory) and tests a player's swing that MISSES a body once more where that attacker
	saw it -- rewound by their one-way latency plus the replication buffer, capped
	(HitboxEngineConstants.LagCompensation). Both the record and the latency are the server's own; no client
	claims anything, nothing is rolled back, and the answer is still this engine's. It replaces, for player
	swings, the TargetTrail velocity guess that stood in for a history while this paragraph ruled one out.

	TIME COMES FROM THE CALLER on Step(deltaTime, now), the same rule ObjectStunResolver keeps, and it
	is why this engine is testable at all: a spec drives Step with a synthetic clock and asserts on
	tunnelling behaviour at frame rates that would be impossible to produce by waiting. Init() is a
	thin wrapper that connects Heartbeat to Step -- the user asked for a module that runs itself, and
	it does, but "runs itself" is one function call wide so nothing about it is untestable.

	PROJECTILES ARE THE SAME ENGINE. An AttackDefinition carrying a Projectile block (ProjectileTypes)
	runs the identical swing lifecycle, but its Active window opens by LAUNCHING a volley instead of
	sampling a volume on the body. The shots fly in ProjectileSimulator.lua, stepped inside this file's
	own substep loop, and their contacts leave through the same OnHit fan-out as a swing's -- so every
	layer above sees one stream of HitReports in ascending SampleTime, and a projectile is blocked,
	parried, evaded and priced by exactly the systems a swing is. The two things the defence layer can
	do to a shot after judging it -- ParryProjectile and PassProjectile -- are the projectile
	counterparts of CancelAttack, and OnProjectileEvents is what the attack layer replicates to clients.

	Does not own: damage, posture, blocking, parry outcomes, ragdoll, knockback, status effects,
	animation, audio, VFX, remotes, or any client-side code. It does not touch the InCombat Attribute
	-- that is a broader "still fighting" signal belonging to whatever layer applies damage, not to a
	swing-by-swing engine.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local HitboxAnchor = require(ReplicatedStorage.Shared.HitboxEngine.HitboxAnchor)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local HitboxGeometry = require(ReplicatedStorage.Shared.HitboxEngine.HitboxGeometry)
local HitboxEngineConstants = require(ReplicatedStorage.Shared.HitboxEngine.HitboxEngineConstants)
local CallbackList = require(ReplicatedStorage.Shared.CallbackList)
local Logger = require(ReplicatedStorage.Shared.Logger)
local Trove = require(ReplicatedStorage.Shared.Trove)

local AttackStateMachine = require(ServerScriptService.Server.Combat.HitboxEngine.AttackStateMachine)
local CandidateGatherer = require(ServerScriptService.Server.Combat.HitboxEngine.CandidateGatherer)
local ProjectileSimulator = require(ServerScriptService.Server.Combat.HitboxEngine.ProjectileSimulator)
local PoseHistory = require(ServerScriptService.Server.Combat.HitboxEngine.PoseHistory)
local NetworkLatency = require(ServerScriptService.Server.Combat.NetworkLatency)
local RootControl = require(ServerScriptService.Server.Combat.RootControl)
local CombatTick = require(script.Parent.Parent.CombatTick)

type AttackDefinition = HitboxTypes.AttackDefinition
type Dimensions = HitboxTypes.Dimensions
type HitReport = HitboxTypes.HitReport
type ShapeKind = HitboxTypes.ShapeKind
type Swing = AttackStateMachine.Swing

local HitboxEngine = {}

local logger = Logger.scope("HitboxEngine")

-- The live sampling state of one combatant's Active window. One of these is allocated per combatant
-- at registration and REUSED for every swing they ever throw -- swings start several times a second
-- in a real fight, and a fresh record (plus a fresh hit set) each time is garbage the collector has
-- to walk mid-combat for no reason. Everything in it is rewritten by beginActiveWindow.
type ActiveSwing = {
	Swing: Swing,
	Shape: ShapeKind,
	AttachmentPart: BasePart,
	-- Live post-scaling dimensions for THIS sample, and for the previous one. Two records rather than
	-- one because the swept test interpolates between them: a charge attack's volume is genuinely a
	-- different size at each end of the interval, and testing both ends against the larger of the two
	-- would report hits the hitbox never actually made.
	Dimensions: Dimensions,
	PreviousDimensions: Dimensions,
	-- Pose at the start of the current FRAME, which is what substep interpolation runs from. Distinct
	-- from PreviousSamplePose, which moves with each substep.
	FrameStartPose: CFrame,
	PreviousSamplePose: CFrame?,
	-- Targets already hit by this swing, and how many. Cleared, not reallocated, at each Active entry.
	HitTargets: { [Model]: boolean },
	HitCount: number,
	MaxTargets: number,
	-- How far back this swing's targets are also tested (HitboxEngineConstants.LagCompensation): the
	-- attacker's one-way latency plus the replication buffer, capped. 0 for a bot or dummy, or with the
	-- compensation off. Fixed when the window opens -- one latency read per swing, not per sample.
	RewindSeconds: number,
	-- The broadphase's answer for THIS FRAME, gathered once at the swing's first sample of the frame and
	-- narrow-phased by every substep after it (see frameCandidates). Owned per record, never shared: two
	-- swings sampled in the same substep must not overwrite each other's list. CandidateFrame is the
	-- frameIndex it was gathered on; any other value means "gather again".
	Candidates: { BasePart },
	CandidateCount: number,
	CandidateFrame: number,
}

type Combatant = {
	Id: number,
	Model: Model,
	RootPart: BasePart,
	Humanoid: Humanoid,
	Machine: AttackStateMachine.Machine,
	Record: ActiveSwing,
	-- Non-nil exactly while the Active window is open. The sampling loop reads this and nothing else
	-- to decide whether to sample; the state machine's hooks are what set and clear it, so the window
	-- opens and closes on the precise substep the machine says it does.
	ActiveSwing: ActiveSwing?,
	-- True while this engine is holding the RootControlLocked Attribute for this combatant, so it is
	-- released exactly once and only by whoever set it.
	HoldsMovementLock: boolean,
	-- Where this body's root has been, one sample per frame (PoseHistory) -- what other swings rewind it by.
	History: PoseHistory.History,
	-- Until when this body's OWN swings get no lag compensation (SuspendCompensation): MovementGuard saw it move
	-- implausibly, and a body whose positions cannot be trusted is not handed the rewind.
	CompensationSuspendedUntil: number,
}

-- Dense array walked every substep, plus the id and model indexes into it. Never a hash map with
-- holes: removal is swap-with-last inside a reverse loop, the same reasoning
-- ObjectStunResolver.removeWatchAt documents.
local combatants: { Combatant } = {}
local combatantById: { [number]: Combatant } = {}
local modelToCombatant: { [Instance]: Combatant } = {}

-- Every combatant whose machine is NOT Idle. The substep loop walks only this, so an idle server full
-- of registered players costs nothing per frame beyond the liveness sweep below.
local engaged: { Combatant } = {}

-- Every registered model as a plain list, rebuilt on every registration change: the projectile world
-- cast's Exclude filter (bodies are swept by the hurtbox index, CandidateGatherer, never by the cast).
local registeredModels: { Model } = {}

-- OnHit's and OnProjectileEvents' subscribers (Shared/CallbackList.lua): pcall'd per consumer, and Fire allocates
-- nothing, which matters for OnHit -- it fires once per contact inside the Heartbeat.
local hitListeners: CallbackList.CallbackList<HitReport> = CallbackList.New(logger, "HitboxEngine.OnHit")
local projectileListeners: CallbackList.CallbackList<{ ProjectileSimulator.ProjectileEvent }> =
	CallbackList.New(logger, "HitboxEngine.OnProjectileEvents")

-- The engine clock at the moment a state machine hook is running. The machine's hooks are handed a Swing,
-- not a time, and a projectile volley has to launch at the substep its Active window actually opened --
-- so the two places that drive a machine into Active (RequestAttack's Begin, and the substep loop's
-- Update) record the time they are driving it at, here, immediately before.
local hookNow = 0

-- Bumped once per Step. What a record's CandidateFrame is compared against.
local frameIndex = 0

-- What sampleSwing collects a sample's NEW (not yet hit this swing), CONTAINED owners into, so they
-- can be sorted nearest-attacker-first before MaxTargets is applied rather than reported in whatever
-- order the broadphase happened to return them -- "nearest" is what a real swing catching several
-- people at once should mean; broadphase order is an implementation detail with no gameplay meaning.
-- NOT pooled, unlike each record's Candidates list: a sample that finds a genuine contact is rare relative to
-- the 120Hz substep rate (the same reasoning reportHit's own HitReport allocation already rests on in
-- this file), so allocating only on that rare path is the right trade, not a hot-path concern.
type ContactCandidate = { Part: BasePart, Owner: Combatant, Distance: number }

-- Hoisted rather than written inline at the table.sort call below. The comparator is stateless, so
-- an inline function literal there would allocate a fresh closure on every sample of every active
-- hitbox -- and the pass-2 sort runs on the frames where the engine is already busiest, since it only
-- happens when a hitbox found more contacts than it had target slots for.
local function byNearestContact(a: ContactCandidate, b: ContactCandidate): boolean
	return a.Distance < b.Distance
end

-- Scratch source Dimensions for applyScaling's SizeFromAttachmentPart branch, reused across every
-- swing that opens one -- filled with the resolved part's live Size immediately before being handed
-- to HitboxGeometry.ScaleDimensions, and never read outside that one call. Single-threaded by
-- construction (the engine's own Heartbeat is the only caller), same reasoning as
-- HitboxGeometry.SCRATCH_DIMENSIONS.
local partSizeScratch: Dimensions = HitboxTypes.DefaultDimensions()

local nextCombatantId = 1
local heartbeatTrove = Trove.New()

-- Round-robin cursor for the liveness sweep. Characters despawn without telling this module, and a
-- combatant whose Model has been destroyed would otherwise sit in the registry forever holding a slot
-- in the broadphase filter. Walking the whole registry every frame to find them would be a full scan
-- on the overwhelming majority of frames where nobody has despawned, so the sweep is amortised over
-- frames instead -- the same "pay one comparison per tick, do the walk only when it can pay off"
-- reasoning behind ObjectStunResolver's nextBookkeepingExpiry watermark.
local livenessCursor = 1
local LIVENESS_CHECKS_PER_FRAME = 4

-- How far up from a candidate part the engine will look for a registered owner. A body part is one
-- level under the character Model; an accessory's Handle is two (Handle -> Accessory -> Model); a
-- tool's is the same. Six is generous enough for any rig and still bounds the walk, so a part buried
-- deep in unrelated geometry cannot make ownership resolution scale with scene depth.
local MAX_OWNER_DEPTH = 6

local function debugEnabled(): boolean
	return HitboxEngineConstants.Debug.Enabled
end

-- Runtime override for the volume visualiser, or nil to use the file constants below.
--
-- SEPARATE FROM Debug.Enabled ON PURPOSE, and it deliberately wins over BOTH constants. Those two
-- gate the engine's per-sample LOGGING as well, which is a genuine performance cost at 120 samples a
-- second per swing -- so "show me the hitboxes" must not be a request to also flood Output, and
-- turning the visualiser on must not require an admin to first know that a second, unrelated master
-- switch exists. One question, one answer.
--
-- Server-wide rather than per-player, because a debug volume is a real replicated Workspace Part that
-- everyone near it already sees -- there is no per-player visibility to key this by, so pretending
-- otherwise would be a lie in the API shape. That is also exactly why the toggle is admin-gated at
-- its DevMenu call site: flipping this is visible to the whole server.
local drawVolumesOverride: boolean? = nil

local function drawVolumesEnabled(): boolean
	if drawVolumesOverride ~= nil then
		return drawVolumesOverride
	end
	return HitboxEngineConstants.Debug.Enabled and HitboxEngineConstants.Debug.DrawVolumes
end

-- Debug visualization ---------------------------------------------------------------------------------
--
-- Server-side Parts, not a client-side overlay -- the same "Studio debug-Part cosmetics" shape the
-- deleted HitboxResolver.lua used (see Constants.lua's own note on that history). Simpler than a
-- remote-driven client visualiser and gets the same result for free: a server-authored Part replicates
-- to every client with no networking code of this module's own to write or keep in sync. Gated on
-- HitboxEngineConstants.Debug.DrawVolumes so it never ships visible in a real server.
local debugVolumeFolder: Folder? = nil
local debugVolumes: { [Combatant]: BasePart } = {}

local function ensureDebugVolumeFolder(): Folder
	local existing = debugVolumeFolder
	if existing and existing.Parent then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "HitboxDebugVolumes"
	folder.Parent = Workspace
	debugVolumeFolder = folder
	return folder
end

local function showDebugVolume(combatant: Combatant, shape: ShapeKind, dimensions: Dimensions, pose: CFrame): ()
	local part = debugVolumes[combatant]
	if not part or part.Parent == nil then
		part = Instance.new("Part")
		part.Name = `HitboxDebug_{combatant.Model.Name}`
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.CastShadow = false
		part.Material = Enum.Material.Neon
		part.Color = Color3.fromRGB(255, 40, 40)
		part.Transparency = 0.55

		-- The Part alone reads as scenery under normal lighting -- a Highlight is what actually makes
		-- this impossible to miss: AlwaysOnTop draws through walls and every other character, and it
		-- ignores the scene's own lighting entirely (a translucent coloured Part can wash out against a
		-- bright sky or a Neon material nearby; a Highlight cannot).
		local highlight = Instance.new("Highlight")
		highlight.Name = "OutlineHighlight"
		highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		highlight.FillColor = Color3.fromRGB(255, 40, 40)
		highlight.FillTransparency = 0.5
		highlight.OutlineColor = Color3.fromRGB(255, 220, 0)
		highlight.OutlineTransparency = 0
		highlight.Parent = part

		part.Parent = ensureDebugVolumeFolder()
		debugVolumes[combatant] = part
	end
	local size, localOffset = HitboxGeometry.BoundingBox(shape, dimensions)
	part.Shape = if shape == "Sphere" or shape == "Capsule" then Enum.PartType.Ball else Enum.PartType.Block
	-- A zero axis (Roblox refuses a Part.Size component of 0) would otherwise error on a degenerate
	-- dimension -- a Height-less Arc, say -- so this floors each axis rather than trusting the
	-- dimension is already sanitised to something Part.Size can hold.
	part.Size = Vector3.new(math.max(size.X, 0.05), math.max(size.Y, 0.05), math.max(size.Z, 0.05))
	part.CFrame = pose * localOffset
end

local function hideDebugVolume(combatant: Combatant): ()
	local part = debugVolumes[combatant]
	if part then
		part:Destroy()
		debugVolumes[combatant] = nil
	end
end

-- Drops every live debug Part and the folder holding them.
--
-- Needed because the ordinary hide path is per-combatant and runs at the END of a swing: without this,
-- switching the visualiser off would leave whatever volumes happened to be mid-swing frozen in the
-- world until their owners next swung, which reads as the toggle not working. Turning it off means
-- they are gone now.
local function clearAllDebugVolumes(): ()
	for combatant, part in debugVolumes do
		part:Destroy()
		debugVolumes[combatant] = nil
	end
	local folder = debugVolumeFolder
	if folder then
		folder:Destroy()
		debugVolumeFolder = nil
	end
end

-- Registration --------------------------------------------------------------------------------------

local function rebuildBroadphaseFilter(): ()
	table.clear(registeredModels)
	for index, combatant in combatants do
		registeredModels[index] = combatant.Model
	end
	CandidateGatherer.SetBodies(combatants)
	ProjectileSimulator.SetRegisteredModels(registeredModels)
end

local function newDimensions(): Dimensions
	return HitboxTypes.DefaultDimensions()
end

-- Which part a definition's Offset is composed against. Resolved once when the Active window opens
-- rather than per sample -- a rig's part set does not change mid-swing, and the sample loop checks
-- the resolved part is still parented anyway. The chain itself is Shared/HitboxEngine/HitboxAnchor's,
-- so the Move Editor's in-world preview anchors exactly where this does.
local function resolveAttachmentPart(combatant: Combatant, attachment: HitboxTypes.AttachmentPoint): BasePart
	return HitboxAnchor.Resolve(combatant.Model, combatant.RootPart, attachment)
end

local function setMovementLock(combatant: Combatant, locked: boolean): ()
	if combatant.HoldsMovementLock == locked then
		return
	end
	combatant.HoldsMovementLock = locked
	local humanoid = combatant.Humanoid
	-- A CLAIM, not a write (Server/Combat/RootControl.lua): a stagger, a grab or an air combo may hold the same
	-- body, and ending this swing must not hand it back to the client while one of them still does. Released
	-- even for an unparented Humanoid, so the claim set never outlives the swing.
	RootControl.Set(humanoid, RootControl.Owners.Swing, locked)
	if humanoid.Parent == nil then
		return
	end
	-- The body is HELD, not just handed over: RunSystem pins WalkSpeed to 0 off this one (a move's "Locks
	-- movement" used to set only the Attribute above, which nothing zeroes speed for, so it slowed the
	-- attacker to committed pace instead of stopping them).
	humanoid:SetAttribute(HitboxEngineConstants.SwingRootedAttribute, if locked then true else nil)
end

-- Scaling -------------------------------------------------------------------------------------------

-- Resolves the total size multiplier for a swing. The engine's whole knowledge of "power" and "combo"
-- lives in these fifteen lines and consists entirely of arithmetic on two numbers it was handed.
local function evaluateScale(
	scaling: HitboxTypes.ScalingProfile,
	comboStage: number,
	powerLevel: number,
	activeElapsed: number
): number
	local multipliers = scaling.ComboStageMultipliers
	-- Clamped, not wrapped or errored: a caller whose combo counter runs past what this attack
	-- authored multipliers for should get the attack's biggest size, not a crash inside a Heartbeat.
	local index = math.clamp(math.floor(comboStage), 1, #multipliers)
	local scale = multipliers[index] * (1 + scaling.PowerMultiplierPerUnit * powerLevel)

	if scaling.ChargeSeconds > 0 then
		local charge = math.clamp(activeElapsed / scaling.ChargeSeconds, 0, 1)
		scale *= 1 + (scaling.ChargedScaleMultiplier - 1) * charge
	end

	return math.clamp(scale, HitboxEngineConstants.MinScaleMultiplier, scaling.MaxScaleMultiplier)
end

local function applyScaling(record: ActiveSwing, activeElapsed: number): ()
	local definition = record.Swing.Definition
	local scale = evaluateScale(definition.Scaling, record.Swing.ComboStage, record.Swing.PowerLevel, activeElapsed)

	-- SizeFromAttachmentPart substitutes the SOURCE dimensions ScaleDimensions reads from -- the
	-- resolved AttachmentPart's own live Size instead of the definition's hand-authored BaseDimensions
	-- -- so ComboStage/PowerLevel scaling still applies on top exactly as it would otherwise. Box only:
	-- every other shape has no notion of "this part's size" (a Cone's AngleDegrees, an Arc's Radius/
	-- InnerRadius, have no BasePart.Size equivalent), so the flag is simply inert for them. Radius/
	-- InnerRadius/AngleDegrees still flow from BaseDimensions even in this branch -- a Box never reads
	-- them, but copying them keeps partSizeScratch a fully-populated Dimensions rather than one with
	-- stale leftovers from whatever swing last used it.
	local attachmentPart = record.AttachmentPart
	if definition.SizeFromAttachmentPart and definition.Shape == "Box" and attachmentPart.Parent then
		local size = attachmentPart.Size
		local sizeMultiplier = definition.SizeMultiplier or 1
		partSizeScratch.Width = size.X * sizeMultiplier
		partSizeScratch.Height = size.Y * sizeMultiplier
		partSizeScratch.Length = size.Z * sizeMultiplier
		partSizeScratch.Radius = definition.BaseDimensions.Radius
		partSizeScratch.InnerRadius = definition.BaseDimensions.InnerRadius
		partSizeScratch.AngleDegrees = definition.BaseDimensions.AngleDegrees
		HitboxGeometry.ScaleDimensions(partSizeScratch, scale, record.Dimensions)
		return
	end

	HitboxGeometry.ScaleDimensions(definition.BaseDimensions, scale, record.Dimensions)
end

-- Sampling ------------------------------------------------------------------------------------------

local function resolveOwner(part: BasePart): Combatant?
	local instance: Instance? = part
	for _ = 1, MAX_OWNER_DEPTH do
		if instance == nil then
			return nil
		end
		local owner = modelToCombatant[instance]
		if owner then
			return owner
		end
		instance = instance.Parent
	end
	return nil
end

-- Whether a combatant's body is dead -- a LIVENESS fact, like a model that left the world (sweepLiveness), and
-- answered here for the same reason: a corpse is not something to report a contact on, and a dead body's swing
-- is not still being thrown. What a death MEANS (credit, respawn) stays with the layers above.
local function isDead(combatant: Combatant): boolean
	local humanoid = combatant.Humanoid
	return humanoid.Parent == nil or humanoid.Health <= 0
end

-- The LIVING registered combatant `part` belongs to, or nil -- the owner a swing or a shot may report a contact
-- on. A corpse's parts resolve to nil, which both sampling loops already skip, so a shot passes through it.
local function livingOwnerOf(part: BasePart): Combatant?
	local owner = resolveOwner(part)
	if owner and isDead(owner) then
		return nil
	end
	return owner
end

-- The engine's one output, for a swing's contact and a projectile's alike.
--
-- Every callback is pcall'd (CallbackList): a consumer that errors must not abort the remaining consumers,
-- and above all must not unwind out of the Heartbeat and stop the engine sampling for everyone. One of
-- the two points where foreign code runs inside the engine's loop -- flushProjectileEvents is the other,
-- guarded the same way.
local function emitHit(report: HitReport): ()
	hitListeners:Fire(report)
end

local function reportHit(
	attacker: Combatant,
	target: Combatant,
	part: BasePart,
	record: ActiveSwing,
	pose: CFrame,
	now: number
): ()
	-- The one table this engine allocates on a hit path, and deliberately so: a HitReport ESCAPES to
	-- consumers who may hold it (a damage layer queuing it, a log keeping it), so a pooled record
	-- would be rewritten underneath them. Hits are bounded by MaxTargetsPerSwing and are orders of
	-- magnitude rarer than samples, so this is the right place to spend an allocation and the sampling
	-- loop is the wrong one.
	local report: HitReport = {
		Attacker = attacker.Model,
		Target = target.Model,
		TargetPart = part,
		Shape = record.Shape,
		-- A copy, not the live record: `record.Dimensions` is mutated in place on the very next sample,
		-- so handing it out would give every consumer a value that changes behind their back.
		Dimensions = HitboxGeometry.CopyDimensions(record.Dimensions, newDimensions()),
		-- The point on the TARGET's surface nearest the hitbox origin, not the part's centre. The
		-- centre is what the containment test uses (it is the only point that is unambiguously "the
		-- target"), but a consumer spawning an impact effect wants the place the blow visibly landed,
		-- and a torso's centre is inside the body. One engine call, on a path bounded by
		-- MaxTargetsPerSwing -- affordable here in a way it would not be in the sampling loop.
		ContactPosition = part:GetClosestPointOnSurface(pose.Position),
		ComboStage = record.Swing.ComboStage,
		PowerLevel = record.Swing.PowerLevel,
		SampleTime = now,
		DebugName = record.Swing.Definition.DebugName,
		Source = "Melee",
	}

	if debugEnabled() and HitboxEngineConstants.Debug.LogSwings then
		logger:debug("Hit", {
			attack = record.Swing.Definition.DebugName,
			attacker = attacker.Model.Name,
			target = target.Model.Name,
			part = part.Name,
			comboStage = record.Swing.ComboStage,
		})
	end

	emitHit(report)
end

-- How far BEHIND its live position a moving target is tested as well (HitboxEngineConstants.TargetTrail),
-- or nil for a body that is standing still or when the allowance is off. Horizontal only: the lag in the
-- attacker's view is along the ground the target is covering, and a jump's vertical speed would otherwise
-- stretch the test into the air above or below them.
local function trailOffsetOf(target: Combatant): Vector3?
	local trail = HitboxEngineConstants.TargetTrail
	if not trail.Enabled then
		return nil
	end
	local velocity = target.RootPart.AssemblyLinearVelocity
	local flat = Vector3.new(velocity.X, 0, velocity.Z)
	local speed = flat.Magnitude
	if speed < trail.MinSpeed then
		return nil
	end
	local studs = math.min(speed * trail.TrailSeconds, trail.MaxStuds)
	return flat.Unit * studs
end

-- How far back a swing by `attacker` tests its targets (HitboxEngineConstants.LagCompensation): its one-way
-- latency plus the replication buffer, capped; 0 for a body with no connection (a bot, a dummy) or with the
-- compensation off.
local function rewindFor(attacker: Combatant, now: number): number
	local config = HitboxEngineConstants.LagCompensation
	if not config.Enabled or now < attacker.CompensationSuspendedUntil then
		return 0
	end
	local oneWay = NetworkLatency.OneWaySeconds(attacker.Model)
	if oneWay <= 0 then
		return 0
	end
	return math.min(oneWay + config.InterpolationSeconds, config.MaxRewindSeconds)
end

-- How far `target` is to be shifted back to stand where a swing rewound by `rewindSeconds` saw it at `now`, or
-- nil when that is too small to be worth a second test (MinDisplacementStuds). Capped at MaxDisplacementStuds,
-- the same bound the broadphase is widened by, so a rewound body can never be tested outside what was gathered.
local function compensationOf(target: Combatant, rewindSeconds: number, now: number): Vector3?
	local config = HitboxEngineConstants.LagCompensation
	local displacement = PoseHistory.DisplacementSince(target.History, now - rewindSeconds)
	local studs = displacement.Magnitude
	if studs < config.MinDisplacementStuds then
		return nil
	end
	if studs > config.MaxDisplacementStuds then
		return displacement.Unit * config.MaxDisplacementStuds
	end
	return displacement
end

-- The candidates every remaining substep of THIS FRAME will narrow-phase, gathered once.
--
-- ONE BROADPHASE PER FRAME, NOT PER SUBSTEP (2026-10-08). Bodies move once per physics step, so every
-- substep of a frame queried the very same target positions -- only the attacker's pose is interpolated
-- between substeps -- and a swing paid two or three identical broadphase queries a frame for one answer.
-- The query now covers the whole of what is left of the frame's sweep at once: a sphere around the segment
-- from the previous sample's pose to this frame's end pose, padded by the volume's circumradius (so any
-- rotation of it along the way is inside), the broadphase margin and, for a compensated swing, the rewind
-- allowance. Every substep pose lies on that segment (CFrame:Lerp interpolates position linearly), so the
-- superset is exact for the narrow phase, which still makes the answer exact.
--
-- A CHARGING volume (Scaling.ChargeSeconds > 0) changes size between substeps, so it keeps gathering per
-- substep rather than guessing the frame's largest size.
local function frameCandidates(record: ActiveSwing, previousPose: CFrame, endPose: CFrame, extra: number): number
	local charging = record.Swing.Definition.Scaling.ChargeSeconds > 0
	if not charging and record.CandidateFrame == frameIndex then
		return record.CandidateCount
	end
	local size, localCentre = HitboxGeometry.BoundingBox(record.Shape, record.Dimensions)
	local reach = localCentre.Magnitude + size.Magnitude / 2
	local from = previousPose.Position
	local to = endPose.Position
	local radius = (to - from).Magnitude / 2 + reach + HitboxEngineConstants.BroadphaseMarginStuds + extra
	local count = CandidateGatherer.GatherSphere((from + to) / 2, radius, record.Candidates)
	record.CandidateCount = count
	record.CandidateFrame = frameIndex
	return count
end

-- One combatant, one substep. `alpha` is how far through the current frame this substep sits, used to
-- interpolate the attachment pose between where it was when the frame began and where it is now.
local function sampleSwing(combatant: Combatant, record: ActiveSwing, now: number, alpha: number): ()
	local attachment = record.AttachmentPart
	if attachment.Parent == nil then
		-- The rig lost the part mid-swing (a tool unequipped, a limb destroyed). Ending the swing is
		-- the honest response: continuing against a stale CFrame would sample a volume attached to
		-- nothing, in world space, wherever that part last was.
		combatant.Machine:Interrupt("AttachmentLost", now)
		return
	end

	local livePose = attachment.CFrame * record.Swing.Definition.Offset
	local pose = record.FrameStartPose:Lerp(livePose, alpha)
	local previousPose = record.PreviousSamplePose or pose

	-- Previous dimensions are captured BEFORE this sample's are computed, so the swept test always
	-- interpolates between two genuinely consecutive sizes. For a non-charging attack the two are
	-- identical every sample and the copy is a no-op worth its uniformity.
	HitboxGeometry.CopyDimensions(record.Dimensions, record.PreviousDimensions)
	if record.Swing.Definition.Scaling.ChargeSeconds > 0 then
		applyScaling(record, combatant.Machine:GetActiveElapsed(now))
	end

	if drawVolumesEnabled() then
		showDebugVolume(combatant, record.Shape, record.Dimensions, pose)
	end

	-- A compensated swing gathers wider, so a body that has since left the volume is still a candidate.
	local compensated = record.RewindSeconds > 0
	local count = frameCandidates(
		record,
		previousPose,
		livePose,
		if compensated then HitboxEngineConstants.LagCompensation.MaxDisplacementStuds else 0
	)
	local candidates = record.Candidates
	if debugEnabled() and CandidateGatherer.WasSaturated(count) then
		logger:warn("Broadphase saturated; candidates may have been dropped", {
			attack = record.Swing.Definition.DebugName,
			attacker = combatant.Model.Name,
		})
	end

	local margin = HitboxEngineConstants.NarrowPhaseMarginStuds

	-- Pass 1: find every NEW, CONTAINED owner this sample, without reporting anything yet.
	local contacts: { ContactCandidate }? = nil
	for index = 1, count do
		local part = candidates[index]
		local owner = livingOwnerOf(part)
		-- An unowned part cannot happen while the Include filter holds only registered models, but the
		-- check is not free to omit: the filter is rebuilt from a registry this loop does not lock, and
		-- a part whose owner unregistered between the query and this line would otherwise be reported
		-- as a hit on a combatant that no longer exists.
		if owner == nil or owner == combatant then
			continue
		end
		if record.HitTargets[owner.Model] then
			continue
		end

		-- Dedupes an owner with more than one candidate part inside the volume this sample (an arm and
		-- a torso, say) down to one contact -- pass 2 decides how many DIFFERENT owners get reported,
		-- not how many of one owner's parts got touched.
		if contacts then
			local alreadyCollected = false
			for _, contact in contacts do
				if contact.Owner == owner then
					alreadyCollected = true
					break
				end
			end
			if alreadyCollected then
				continue
			end
		end

		-- Every shape runs the narrow phase, including Box and Sphere. The old resolver skipped it for
		-- those two on the grounds that their bounding box IS their volume -- true of the shape, but
		-- not of this query: the broadphase is inflated by BroadphaseMarginStuds to cover the swept
		-- region, and it matches on part BOUNDING BOXES while the test below is against a part's
		-- centre. Trusting the broadphase here would make a Box hit noticeably further than authored.
		local contained = HitboxGeometry.SweptContainsPoint(
			record.Shape,
			record.PreviousDimensions,
			previousPose,
			record.Dimensions,
			pose,
			part.Position,
			margin
		)
		if not contained then
			-- Tested again where the attacker SAW this body. A miss only -- a part already inside never pays
			-- for this. A player's swing rewinds the body's own recorded history (LAG COMPENSATION, this file's
			-- header); anything else falls back to the moving-target allowance (TargetTrail), a little behind
			-- the body along its own motion.
			local trail = if compensated then compensationOf(owner, record.RewindSeconds, now) else trailOffsetOf(owner)
			if trail == nil then
				continue
			end
			contained = HitboxGeometry.SweptContainsPoint(
				record.Shape,
				record.PreviousDimensions,
				previousPose,
				record.Dimensions,
				pose,
				part.Position - trail,
				margin
			)
			if not contained then
				continue
			end
		end

		if not contacts then
			contacts = {}
		end
		table.insert(contacts, {
			Part = part,
			Owner = owner,
			Distance = (owner.RootPart.Position - combatant.RootPart.Position).Magnitude,
		})
	end

	-- Pass 2: nearest-attacker-first, up to whatever's left of MaxTargets.
	if contacts then
		table.sort(contacts, byNearestContact)
		for _, contact in contacts do
			if record.HitCount >= record.MaxTargets then
				break
			end
			record.HitTargets[contact.Owner.Model] = true
			record.HitCount += 1
			reportHit(combatant, contact.Owner, contact.Part, record, pose, now)
		end
	end

	record.PreviousSamplePose = pose
end

-- Lifecycle hooks -------------------------------------------------------------------------------------

local function beginActiveWindow(combatant: Combatant, swing: Swing): ()
	local definition = swing.Definition
	local record = combatant.Record

	-- A projectile attack's Active window opens by launching its volley, and nothing on the body samples:
	-- ActiveSwing stays nil, so the loop below never looks for a volume here. The movement lock is the
	-- same as a swing's -- a caster planting their feet to fire is authored exactly the way a heavy is.
	if definition.Projectile then
		local anchor = resolveAttachmentPart(combatant, definition.AttachmentPart)
		ProjectileSimulator.Launch(combatant, anchor, definition, swing.ComboStage, swing.PowerLevel, hookNow)
		if definition.LocksMovement then
			setMovementLock(combatant, true)
		elseif definition.LocksWindup then
			-- Only the windup was locked: the volley is out, the caster is free.
			setMovementLock(combatant, false)
		end
		if debugEnabled() and HitboxEngineConstants.Debug.LogSwings then
			logger:debug("Projectile volley launched", {
				attack = definition.DebugName,
				attacker = combatant.Model.Name,
			})
		end
		return
	end

	-- A VOLUMELESS swing (a realm's cast: Server/Combat/Domain) is a real swing -- its windup, Active window,
	-- recovery, locks, feint and clip sync all run -- that samples nothing on the body. ActiveSwing stays nil
	-- exactly as it does for a projectile's, so no volume is gathered, tested or drawn, and nothing in front
	-- of the caster can be hit by the cast itself. The movement locks are the same.
	if definition.Volumeless then
		if definition.LocksMovement then
			setMovementLock(combatant, true)
		elseif definition.LocksWindup then
			setMovementLock(combatant, false)
		end
		if debugEnabled() and HitboxEngineConstants.Debug.LogSwings then
			logger:debug("Volumeless swing opened its Active window", {
				attack = definition.DebugName,
				attacker = combatant.Model.Name,
			})
		end
		return
	end

	record.Swing = swing
	record.Shape = definition.Shape
	record.AttachmentPart = resolveAttachmentPart(combatant, definition.AttachmentPart)
	record.MaxTargets = definition.MaxTargetsPerSwing or HitboxEngineConstants.DefaultMaxTargetsPerSwing
	record.HitCount = 0
	table.clear(record.HitTargets)

	-- Evaluated once, here, for everything that is not a charge attack -- see ScalingProfile's header
	-- for why a volume that silently changes size mid-window is unreadable to the player being hit.
	applyScaling(record, 0)
	HitboxGeometry.CopyDimensions(record.Dimensions, record.PreviousDimensions)

	-- The window opens with no previous pose, so the first sample's swept test degenerates to a single
	-- instantaneous test against the opening pose. That is correct: there is no earlier pose for the
	-- hitbox to have swept from, and inventing one from the windup would let an attack hit during
	-- frames it was not yet active.
	record.FrameStartPose = record.AttachmentPart.CFrame * definition.Offset
	record.PreviousSamplePose = nil
	record.RewindSeconds = rewindFor(combatant, hookNow)
	record.CandidateFrame = -1

	combatant.ActiveSwing = record

	if definition.LocksMovement then
		setMovementLock(combatant, true)
	elseif definition.LocksWindup then
		-- Only the windup was locked: the Active window opens and the attacker is free to move.
		setMovementLock(combatant, false)
	end

	if debugEnabled() and HitboxEngineConstants.Debug.LogSwings then
		logger:debug("Active window opened", {
			attack = definition.DebugName,
			attacker = combatant.Model.Name,
			comboStage = swing.ComboStage,
			powerLevel = swing.PowerLevel,
		})
	end
end

local function endActiveWindow(combatant: Combatant, _swing: Swing): ()
	combatant.ActiveSwing = nil
	hideDebugVolume(combatant)
end

-- Fires once per swing on the return to Idle, by every route -- completed recovery, interruption, the
-- runaway deadline, unregistration. The movement lock is released HERE rather than when the Active
-- window closes, so a committed attack keeps the body through its recovery frames: releasing it at
-- the end of Active would let a player cancel every recovery by moving, which removes the entire cost
-- of throwing a heavy attack.
local function endSwing(combatant: Combatant, swing: Swing, completed: boolean): ()
	combatant.ActiveSwing = nil
	setMovementLock(combatant, false)

	if debugEnabled() and HitboxEngineConstants.Debug.LogSwings then
		logger:debug("Swing ended", {
			attack = swing.Definition.DebugName,
			attacker = combatant.Model.Name,
			completed = completed,
			reason = swing.InterruptReason,
		})
	end
end

-- Public API -------------------------------------------------------------------------------------------

-- Registers anything that can swing or be swung at. Deliberately takes the three Instances it
-- actually needs rather than a Player or a character wrapper: that is what lets a player, a training
-- bot and an inert dummy go through one code path, and what stops this engine growing a notion of
-- "who is a real fighter" that the gameplay layer would then have to agree with.
function HitboxEngine.RegisterCombatant(model: Model, rootPart: BasePart, humanoid: Humanoid): number
	local existing = modelToCombatant[model]
	if existing then
		return existing.Id
	end

	local id = nextCombatantId
	nextCombatantId += 1

	local combatant: Combatant = {
		Id = id,
		Model = model,
		RootPart = rootPart,
		Humanoid = humanoid,
		Machine = nil :: any,
		Record = {
			Swing = nil :: any,
			Shape = "Box" :: ShapeKind,
			AttachmentPart = rootPart,
			Dimensions = newDimensions(),
			PreviousDimensions = newDimensions(),
			FrameStartPose = CFrame.identity,
			PreviousSamplePose = nil,
			HitTargets = {},
			HitCount = 0,
			MaxTargets = HitboxEngineConstants.DefaultMaxTargetsPerSwing,
			RewindSeconds = 0,
			Candidates = {},
			CandidateCount = 0,
			CandidateFrame = -1,
		},
		ActiveSwing = nil,
		HoldsMovementLock = false,
		History = PoseHistory.New(HitboxEngineConstants.LagCompensation.HistoryCapacity),
		CompensationSuspendedUntil = 0,
	}

	combatant.Machine = AttackStateMachine.New({
		OnEnterActive = function(swing: Swing)
			beginActiveWindow(combatant, swing)
		end,
		OnExitActive = function(swing: Swing)
			endActiveWindow(combatant, swing)
		end,
		OnSwingEnded = function(swing: Swing, completed: boolean)
			endSwing(combatant, swing, completed)
		end,
	})

	table.insert(combatants, combatant)
	combatantById[id] = combatant
	modelToCombatant[model] = combatant
	rebuildBroadphaseFilter()

	-- The outward signal that this model is an engine-known fighter. The hot path uses
	-- modelToCombatant instead (an O(1) table lookup this module already owns), so the tag exists for
	-- other systems -- a movement probe that needs to exclude bodies, a future consumer layer, a debug
	-- visualiser. See HitboxEngineConstants.CombatantTag.
	if not CollectionService:HasTag(model, HitboxEngineConstants.CombatantTag) then
		CollectionService:AddTag(model, HitboxEngineConstants.CombatantTag)
	end

	return id
end

local function removeCombatantAt(index: number, now: number): ()
	local combatant = combatants[index]
	if combatant == nil then
		return
	end

	-- Reset runs the ordinary Exit path, so a combatant unregistered mid-swing releases its movement
	-- lock rather than leaving a despawning character's Humanoid with RootControlLocked set -- which,
	-- on a respawn that reuses the Humanoid, would park the new character's parkour permanently.
	combatant.Machine:Reset(now)

	local last = #combatants
	combatants[index] = combatants[last]
	combatants[last] = nil

	combatantById[combatant.Id] = nil
	modelToCombatant[combatant.Model] = nil
	CollectionService:RemoveTag(combatant.Model, HitboxEngineConstants.CombatantTag)

	for engagedIndex = #engaged, 1, -1 do
		if engaged[engagedIndex] == combatant then
			local lastEngaged = #engaged
			engaged[engagedIndex] = engaged[lastEngaged]
			engaged[lastEngaged] = nil
		end
	end

	rebuildBroadphaseFilter()
end

function HitboxEngine.UnregisterCombatant(combatantId: number): boolean
	local combatant = combatantById[combatantId]
	if combatant == nil then
		return false
	end
	for index, candidate in combatants do
		if candidate == combatant then
			removeCombatantAt(index, os.clock())
			return true
		end
	end
	return false
end

-- Stops lag compensation for `model`'s own swings until `untilAt` (os.clock()) -- Server/Combat/MovementGuard.lua's
-- answer to a body that moved implausibly. Only ever extends; a swing already open keeps the rewind it opened with.
function HitboxEngine.SuspendCompensation(model: Model, untilAt: number): ()
	local combatant = modelToCombatant[model]
	if combatant then
		combatant.CompensationSuspendedUntil = math.max(combatant.CompensationSuspendedUntil, untilAt)
	end
end

-- How far back a swing by this model tests its targets (LagCompensation), for its spec and the debug readout.
function HitboxEngine.RewindFor(model: Model, now: number?): number
	local combatant = modelToCombatant[model]
	return if combatant then rewindFor(combatant, now or os.clock()) else 0
end

function HitboxEngine.GetCombatantId(model: Model): number?
	local combatant = modelToCombatant[model]
	return if combatant then combatant.Id else nil
end

-- Starts an attack. Returns (accepted, reason) -- a refusal is normal and never an error, matching
-- ObjectStunResolver.Watch's contract: a player mashing during their own recovery is ordinary play.
-- The caller decides whether to buffer the input or drop it; this engine has no input buffer because
-- how long an input should survive is a feel question, and feel questions belong to the layer that
-- knows what the move is.
--
-- `startedAt` (optional) BACKDATES the swing: the moment the caller judges it to have begun, for a press
-- that spent time on the wire (AttackConstants.Latency). The engine enforces the two limits that are about
-- the swing rather than the player: never before this combatant's previous swing ended, and never so far
-- back that the Active window would already have been due -- only the windup ever shortens, so a
-- backdated swing can never hit on the frame it arrives. Returns the start actually used as a third value,
-- so the caller builds the rest of the swing's timeline from the same instant.
function HitboxEngine.RequestAttack(
	combatantId: number,
	definition: AttackDefinition,
	comboStage: number,
	powerLevel: number,
	startedAt: number?
): (boolean, string?, number?)
	local combatant = combatantById[combatantId]
	if combatant == nil then
		return false, "NotRegistered"
	end
	if combatant.Model.Parent == nil or combatant.RootPart.Parent == nil then
		return false, "NoCharacter"
	end
	if isDead(combatant) then
		return false, "Dead"
	end
	if combatant.Machine:IsAttacking() then
		return false, "Busy"
	end
	if #engaged >= HitboxEngineConstants.MaxActiveSwings then
		-- Bounds the engine's worst-case frame cost rather than letting it scale with how many people
		-- happen to be fighting. Degrading one attack in a mass brawl is the right failure; degrading
		-- everyone's frame time is not.
		return false, "TooManySwings"
	end

	-- No cache here: this used to be a table-identity-keyed cache on the theory that a real attack is
	-- requested from the same authored table thousands of times. It never actually hit -- the caller
	-- (AttackCatalog.Get) projects a fresh AttackDefinition table on every call, so every lookup missed,
	-- and the cache itself cost a weak-table insert plus GC traversal for nothing. Sanitising is a
	-- single per-field walk; just do it.
	local sanitized, problems = HitboxTypes.SanitizeDefinition(definition)
	if debugEnabled() and #problems > 0 then
		logger:warn("Attack definition corrected", {
			attack = sanitized.DebugName,
			problems = table.concat(problems, "; "),
		})
	end

	-- Guarded here rather than trusted, because they come from a caller and flow straight into the
	-- geometry: a NaN combo stage would make math.clamp return NaN, index the multiplier list with it,
	-- and produce a hitbox of NaN size that silently never hits anything.
	local safeCombo = if typeof(comboStage) == "number" and comboStage == comboStage then comboStage else 1
	local safePower = if typeof(powerLevel) == "number" and powerLevel == powerLevel then math.max(powerLevel, 0) else 0

	local now = os.clock()
	local begin = now
	if typeof(startedAt) == "number" and startedAt == startedAt and startedAt < now then
		-- One substep short of the windup, so the machine is still winding up when it is next stepped.
		local earliest = now - math.max(sanitized.WindupSeconds - HitboxEngineConstants.MinSubstepSeconds, 0)
		local idleSince = combatant.Machine:GetIdleSince()
		if idleSince then
			earliest = math.max(earliest, idleSince)
		end
		begin = math.clamp(startedAt, math.min(earliest, now), now)
	end
	hookNow = begin
	local accepted, reason = combatant.Machine:Begin(sanitized, safeCombo, safePower, begin)
	if not accepted then
		return false, reason
	end

	table.insert(engaged, combatant)
	-- A move that locks its WINDUP holds the body from the first instant of the swing, not from the Active
	-- window (beginActiveWindow releases it again there unless LocksMovement carries the lock on).
	if sanitized.LocksWindup == true then
		setMovementLock(combatant, true)
	end
	return true, nil, begin
end

-- Cuts a swing short. What a consumer layer calls when a parry, a stun or a ragdoll needs to end an
-- attack that is still swinging -- the engine itself never decides that any of those happened.
--
-- `now` is the caller's clock, like every other entry point here and on AttackStateMachine. It used
-- to read os.clock() itself, which was the single exception in this engine and broke that module's
-- own stated rule ("TIME COMES FROM THE CALLER on every entry point, never from os.clock() here").
-- It matters for the parry: Server/Combat/Defense/DefenseSystem.lua cancels a parried swing at the
-- SUBSTEP the parry landed rather than at the end of the frame it was noticed in, and a wall-clock
-- read here would file the interruption tens of milliseconds late and make that path the one thing
-- in either system that a spec could not drive on a synthetic clock.
--
-- Defaults to os.clock() when omitted, so a caller with no meaningful substep time (an admin command,
-- a teardown) does not have to invent one.
function HitboxEngine.CancelAttack(combatantId: number, reason: string, now: number?): boolean
	local combatant = combatantById[combatantId]
	if combatant == nil then
		return false
	end
	return combatant.Machine:Interrupt(reason, now or os.clock())
end

-- Ends a swing EARLY, but only from its Recovery -- the one phase where nothing is left to hit with. For
-- the attack layer's hit-confirm cancel (AttackConstants.HitConfirm): a swing that landed may be cut
-- partway through its recovery into the next action. Returns whether it cut anything.
--
-- Its own entry point rather than CancelAttack with a reason, because the phase check IS the contract. A
-- caller that wants to end recovery must not be able to end a windup or an active window by mistake,
-- and this engine is the only place that knows which phase a swing is in right now. Goes through the
-- ordinary Interrupt path, so the movement lock and the hit set clean up exactly as for any other end.
function HitboxEngine.CancelRecovery(combatantId: number, now: number?): boolean
	local combatant = combatantById[combatantId]
	if combatant == nil then
		return false
	end
	local at = now or os.clock()
	local machine = combatant.Machine
	-- Brought up to `at` first, so a recovery that already ran out this frame is reported as over
	-- rather than cut.
	if machine:Update(at) ~= "Recovery" then
		return false
	end
	return machine:Interrupt("RecoveryCancel", at)
end

-- Debug visualisation ---------------------------------------------------------------------------------

-- Turns the swing-volume visualiser on or off for the WHOLE SERVER, live, in Studio or a published
-- place. Overrides HitboxEngineConstants.Debug's own two switches in both directions -- see
-- drawVolumesOverride's own header for why this is one question rather than two.
--
-- Switching off destroys every volume immediately rather than letting them expire with their swings.
--
-- The engine deliberately does no authorization of its own here: it has no notion of who a player is,
-- and growing one would be the first crack in it being a standalone module. The gate lives at the call
-- site, in DevMenuSystem's own admin whitelist, exactly where every other privileged action's does.
function HitboxEngine.SetDebugVolumesEnabled(enabled: boolean): ()
	drawVolumesOverride = enabled
	if not enabled then
		clearAllDebugVolumes()
	end
	logger:info("Hitbox debug volumes toggled", { enabled = enabled })
end

-- Whether volumes are currently drawn, resolving the runtime override against the file constants the
-- same way the sampler itself does -- so a caller asking before anything has toggled gets the honest
-- boot default rather than a hardcoded false.
function HitboxEngine.IsDebugVolumesEnabled(): boolean
	return drawVolumesEnabled()
end

-- Drops the runtime override, returning the visualiser to whatever HitboxEngineConstants.Debug says.
-- Spec-only -- production has no reason to want "whatever the file said" back mid-session.
function HitboxEngine.ClearDebugVolumesOverride(): ()
	drawVolumesOverride = nil
	if not drawVolumesEnabled() then
		clearAllDebugVolumes()
	end
end

function HitboxEngine.GetAttackState(combatantId: number): AttackStateMachine.AttackState?
	local combatant = combatantById[combatantId]
	return if combatant then combatant.Machine:GetState() else nil
end

-- Whether this combatant's swing is in its Active window RIGHT NOW with a volume that reaches `target`'s
-- root, within `marginStuds` on top of the engine's own narrow-phase margin. False for a swing winding up
-- or recovering, a projectile attack (its volume is the shot, not the body), and a target this swing has
-- already struck. The defence layer's clash test (DefenseConstants.Clash): two blades that are both out
-- and reach each other. A query only -- like every other answer here, what it MEANS is the caller's.
function HitboxEngine.ActiveSwingReaches(combatantId: number, target: Model, marginStuds: number): boolean
	local combatant = combatantById[combatantId]
	local record = if combatant then combatant.ActiveSwing else nil
	if record == nil or record.HitTargets[target] then
		return false
	end
	local attachment = record.AttachmentPart
	local targetCombatant = modelToCombatant[target]
	if attachment.Parent == nil or targetCombatant == nil then
		return false
	end
	local pose = attachment.CFrame * record.Swing.Definition.Offset
	return HitboxGeometry.ContainsPoint(
		record.Shape,
		record.Dimensions,
		pose:PointToObjectSpace(targetCombatant.RootPart.Position),
		HitboxEngineConstants.NarrowPhaseMarginStuds + math.max(marginStuds, 0)
	)
end

-- Projectiles ---------------------------------------------------------------------------------------

-- What a PARRY does to a shot, once the defence layer has judged one: the shot's own authored response
-- (ProjectileTypes' ParryBehavior/ParryResponse) -- ended, or reflected or reversed as the parrier's. The
-- projectile counterpart of CancelAttack, which is what the same layer calls for a parried swing, and
-- like it the engine decides nothing here: whether a parry happened is the caller's answer. Returns
-- whether the id named a shot (one ended longer ago than RetireGraceSeconds is forgotten).
function HitboxEngine.ParryProjectile(projectileId: number, parrier: Model, now: number?): boolean
	return ProjectileSimulator.Parry(projectileId, parrier, now or os.clock())
end

-- What an EVADE does to a shot: undoes the contact, so the shot flies on through the body it touched.
function HitboxEngine.PassProjectile(projectileId: number, target: Model, now: number?): boolean
	return ProjectileSimulator.Pass(projectileId, target, now or os.clock())
end

-- THE REALM'S ONE SEAM INTO THE ENGINE (Server/Combat/Domain/DomainSystem.lua, which sits above every combat
-- layer as a sibling of the attack layer). A realm delivers its strikes and volleys as shots -- so the
-- defence layer still judges each contact and the damage layer still prices it, as the move it names -- but
-- no swing throws them. Two functions, one concern: launching a volley from a world aim, and holding the
-- barrier slot a realm's closed edge is enforced through. Nothing here learns what a realm is: `options`
-- is a target, an exclusivity flag, an opaque id and a damage scale (ProjectileSimulator.LaunchOptions).
--
-- `definition` must carry a Projectile block (a realm's strike synthesises one; its volley uses the move's
-- own). `owner` must be registered -- the contacts are reported as its. Returns (groupId, launched); (0, 0)
-- for an unregistered owner or a definition with no Projectile block.
function HitboxEngine.LaunchVolley(
	owner: Model,
	definition: AttackDefinition,
	aim: CFrame,
	powerLevel: number,
	now: number,
	options: ProjectileSimulator.LaunchOptions?
): (number, number)
	local combatant = modelToCombatant[owner]
	if combatant == nil or definition.Projectile == nil then
		return 0, 0
	end
	return ProjectileSimulator.LaunchAimed(combatant, aim, definition, powerLevel, now, options)
end

-- Holds (or clears, with nil) the projectile barrier slot. One slot, one holder: the realm runtime sets it
-- while any realm with a closed edge is up and clears it when the last one ends, so a server with no realm
-- pays one nil check per shot step.
function HitboxEngine.SetProjectileBarrier(callback: ProjectileSimulator.Barrier?): ()
	ProjectileSimulator.SetBarrier(callback)
end

-- Every change to a shot a client needs to draw it (ProjectileSimulator.ProjectileEvent), batched once
-- per engine frame. The engine has no remote; the attack layer subscribes and sends these on. Returns a
-- disconnect function, like OnHit.
function HitboxEngine.OnProjectileEvents(callback: ({ ProjectileSimulator.ProjectileEvent }) -> ()): () -> ()
	return projectileListeners:Connect(callback)
end

function HitboxEngine.LiveProjectileCount(): number
	return ProjectileSimulator.LiveCount()
end

local function flushProjectileEvents(now: number): ()
	local events = ProjectileSimulator.Flush(now)
	if #events == 0 then
		return
	end
	projectileListeners:Fire(events)
end

-- The engine's sole output. Returns a disconnect function rather than a connection object so a
-- consumer's teardown is one call with no handle type to learn.
function HitboxEngine.OnHit(callback: (HitReport) -> ()): () -> ()
	return hitListeners:Connect(callback)
end

-- The loop -------------------------------------------------------------------------------------------

local function sweepLiveness(now: number): ()
	local total = #combatants
	if total == 0 then
		return
	end
	for _ = 1, math.min(LIVENESS_CHECKS_PER_FRAME, total) do
		if livenessCursor > #combatants then
			livenessCursor = 1
		end
		local combatant = combatants[livenessCursor]
		if combatant == nil then
			break
		end
		if combatant.Model.Parent == nil or combatant.RootPart.Parent == nil then
			-- Removal swaps the last element into this slot, so the cursor deliberately does NOT
			-- advance: the element now sitting here has not been checked yet.
			removeCombatantAt(livenessCursor, now)
		else
			livenessCursor += 1
		end
	end
end

-- How many substeps a frame of `frameSeconds` is divided into. Pure, and public so a spec can pin the
-- common case: an ordinary 60Hz Heartbeat (a hair over 1/60) is TWO substeps, not three -- see
-- HitboxEngineConstants.SubstepOvershootTolerance.
function HitboxEngine.SubstepsFor(frameSeconds: number): number
	local exact = frameSeconds / HitboxEngineConstants.MinSubstepSeconds
	return math.clamp(
		math.ceil(exact - HitboxEngineConstants.SubstepOvershootTolerance),
		1,
		HitboxEngineConstants.MaxSubstepsPerFrame
	)
end

-- One frame. Drives every non-idle combatant's state machine and samples every open Active window,
-- subdivided into substeps so neither depends on the server's frame rate. `now` is the caller's clock
-- and is treated as the END of the frame -- the frame is deemed to have started at `now - deltaTime`,
-- which is what makes an interpolated substep time meaningful.
function HitboxEngine.Step(deltaTime: number, now: number): ()
	local frameSeconds = math.clamp(deltaTime, 0, HitboxEngineConstants.MaxFrameSeconds)
	frameIndex += 1
	sweepLiveness(now)

	-- Where every body is this frame, for lag-compensated swings to rewind (PoseHistory). Before the idle
	-- return below, so a history already exists the moment a swing opens. One Vector3 per body per frame,
	-- written in place.
	if HitboxEngineConstants.LagCompensation.Enabled then
		for _, combatant in combatants do
			if combatant.RootPart.Parent ~= nil then
				PoseHistory.Record(combatant.History, now, combatant.RootPart.Position)
			end
		end
	end

	if #engaged == 0 and ProjectileSimulator.LiveCount() == 0 then
		-- Events can still be waiting: a parry reflects or ends a shot from DefenseSystem's Step, after
		-- this one has run, and those go out with the next frame's batch.
		ProjectileSimulator.Step(0, now)
		flushProjectileEvents(now)
		return
	end

	local substeps = HitboxEngine.SubstepsFor(frameSeconds)
	local frameStart = now - frameSeconds

	-- Anchors this frame's pose interpolation before anything advances. Done in its own pass because
	-- the substep loop below both reads FrameStartPose and moves PreviousSamplePose, so capturing it
	-- inside that loop would anchor each substep to the previous substep and flatten the
	-- interpolation back into the per-frame sampling this engine exists to avoid.
	for _, combatant in engaged do
		local record = combatant.ActiveSwing
		if record then
			record.FrameStartPose = record.PreviousSamplePose
				or (record.AttachmentPart.CFrame * record.Swing.Definition.Offset)
		end
	end

	for step = 1, substeps do
		local alpha = step / substeps
		local subNow = frameStart + frameSeconds * alpha

		-- Backwards so the swap-with-last retirement below can never move an unvisited combatant past
		-- the cursor, and so a hit callback that starts a NEW attack appends beyond the cursor rather
		-- than into this pass -- a follow-up swing should begin next frame, not recursively inside the
		-- frame that triggered it.
		for index = #engaged, 1, -1 do
			local combatant = engaged[index]

			if combatant.Model.Parent == nil or combatant.RootPart.Parent == nil then
				combatant.Machine:Reset(subNow)
			elseif isDead(combatant) then
				-- Killed mid-swing: the swing ends here, through the ordinary Interrupt path, so its movement
				-- lock and hit set clean up as for any other end. Nothing more of it can land.
				combatant.Machine:Interrupt("Died", subNow)
			else
				hookNow = subNow
				combatant.Machine:Update(subNow)
				local record = combatant.ActiveSwing
				if record then
					sampleSwing(combatant, record, subNow, alpha)
				end
			end

			if not combatant.Machine:IsAttacking() then
				local last = #engaged
				engaged[index] = engaged[last]
				engaged[last] = nil
			end
		end

		-- Shots fly after the swings, in the same substep: one launched by a window that opened this
		-- substep takes its first step now, and every contact either kind reports carries this substep's
		-- time, so the stream OnHit subscribers see stays in ascending SampleTime.
		ProjectileSimulator.Step(frameSeconds / substeps, subNow)

		if #engaged == 0 and ProjectileSimulator.LiveCount() == 0 then
			break
		end
	end

	flushProjectileEvents(now)
end

-- Puts the engine on the frame: the first phase of Server/Combat/CombatTick.lua's one combat Heartbeat
-- (and, being the first combat System to boot, what connects it). Deliberately one line wide, with all the
-- behaviour in Step(deltaTime, now) above, so the engine stays drivable from a spec with a synthetic
-- clock. Idempotent: a second Init() is a no-op rather than a second registration.
function HitboxEngine.Init(): ()
	if heartbeatTrove:Count() > 0 then
		return
	end
	heartbeatTrove:Add(CombatTick.Register("HitboxEngine", HitboxEngine.Step))
	logger:info("Hitbox engine started")
end

function HitboxEngine.Shutdown(): ()
	heartbeatTrove:Clean()
end

function HitboxEngine.RegisteredCount(): number
	return #combatants
end

function HitboxEngine.EngagedCount(): number
	return #engaged
end

-- Full teardown. Exists for the specs, which need each `it` to start from a known-empty engine -- the
-- same reason ObjectStunResolver.Reset does.
function HitboxEngine.Reset(): ()
	HitboxEngine.Shutdown()
	local now = os.clock()
	for index = #combatants, 1, -1 do
		removeCombatantAt(index, now)
	end
	table.clear(combatants)
	table.clear(engaged)
	hitListeners:Clear()
	projectileListeners:Clear()
	table.clear(registeredModels)
	ProjectileSimulator.Reset()
	combatantById = {}
	modelToCombatant = {}
	livenessCursor = 1
	-- Dropped so one spec toggling the visualiser cannot leave it on for every case after it -- the
	-- same "no case serves another its state" contract every other line in this function keeps.
	HitboxEngine.ClearDebugVolumesOverride()
	CandidateGatherer.Reset()
	ProjectileSimulator.SetRegisteredModels(registeredModels)
end

-- The simulator's view of this engine: its registry and its one output, never a way to change either.
ProjectileSimulator.Bind({
	OwnerOf = function(part: BasePart): ProjectileSimulator.Owner?
		return livingOwnerOf(part)
	end,
	CombatantOf = function(model: Model): ProjectileSimulator.Owner?
		return modelToCombatant[model]
	end,
	Combatants = function(): { ProjectileSimulator.Owner }
		return combatants :: any
	end,
	Report = emitHit,
})

return HitboxEngine
