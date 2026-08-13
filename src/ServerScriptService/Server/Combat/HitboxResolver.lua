--!strict
--[[
	HitboxResolver.lua

	Owns: the swept melee hitbox pipeline -- scheduling a swing's windup/active/recovery timeline,
	sampling the authored volume at each attacker pose during the active window, sweeping between
	samples via CFrame:Lerp sub-steps so fast relative movement can't skip a target between two
	discrete samples, and deduping so a given target is only ever counted once per swing. Pure
	geometry and scheduling -- this module has no idea what a Player, damage, posture, or block/parry
	even is.

	Sampling runs one of TWO paths, chosen per definition by isExactShape (see collectOverlappedModels,
	the single query both engines share):

	  * EXACT -- Shape nil (every hand-authored Constants.lua attack, implicitly Box), "Box", or
	    "Sphere". A single Workspace:GetPartBoundsInBox / GetPartBoundsInRadius call IS the volume,
	    so every overlapping part counts with no further filtering. Byte-identical to what this
	    module has always done, which is what makes the wider shape vocabulary a purely additive
	    change rather than a rewrite of hit detection for existing attacks.
	  * BROAD + NARROW -- any of the other ten Shared/HitboxShapes.lua shapes (Cone, Arc, Blade,
	    Slice, Beam, Cylinder, Capsule, Disc, Wedge, Pyramid), reached only by a Move Creation System
	    move that authored one. A conservative oriented-box query (HitboxShapes.BoundingBox) finds
	    candidate parts, then each is tested against the real volume (HitboxShapes.ContainsPoint) with
	    a slack margin derived from the part's own size. The debug renderer draws the exact same
	    decomposition the Move Editor's viewport does, from the same function, so the shape an admin
	    tuned and the shape they see in-world can't drift apart.

	The sampled pose is root-relative (AttackerRootPart.CFrame * Offset) by default, but a caller
	can optionally supply AttackerTrackedPart (SwingConfig) to have the box's POSITION follow a
	different part instead -- e.g. the attacker's own hand, for a punch whose reach a fixed
	root-relative offset can't accurately represent across every animation pose. The box's
	ORIENTATION always comes from AttackerRootPart regardless -- see AttackerTrackedPart's own
	header for why.

	Also owns a SECOND, independent engine -- StartProjectile/performProjectileSample, tracked in
	its own activeProjectiles table -- for a Move Creation System move authored with
	Types.HitboxAttackDefinition.Projectile set. Deliberately NOT unified with the swing engine
	above despite the similar windup/active/sampling shape: a swing's pose is recomputed from the
	ATTACKER's current position every sample (glued to them for its whole lifetime), while a
	projectile's pose is computed from a SPAWN pose captured once at launch, advanced purely by
	elapsed time and Speed thereafter -- the attacker can move, turn, or even die after firing and
	the projectile keeps flying regardless. A projectile also needs a real, always-visible Part (an
	admin/player must be able to see it travel, unlike a melee swing's own invisible-except-in-
	Studio-debug hitbox, since the swing ANIMATION is what communicates a melee attack visually) --
	see getProjectilesFolder's own header for why this can't reuse the Studio-only debug-part
	plumbing above it.

	Does not own: what counts as a legal target, arc/line-of-sight validation, or any damage/posture/
	block/parry resolution -- CombatSystem.lua owns all of that. Every overlapped Model this module
	finds is handed to the caller's `OnHit` callback (see SwingConfig/ProjectileConfig) for that
	caller to accept or reject; this module only tracks *whether the caller already said yes* for
	dedup purposes. It also doesn't decide *which* attack definition to use (combo stage selection,
	Basic vs Heavy, or melee vs projectile) -- it only ever runs the single
	Types.HitboxAttackDefinition it's handed.

	Driven entirely by CombatSystem.lua calling Update(deltaTime) once per Heartbeat -- this module
	does not connect its own RunService event or track boot order (no Init()), since it isn't a peer
	System per software-architecture.md, it's a narrow server-only helper for the one System that
	owns combat (performance-optimization.md's server-tick-discipline guidance is why CombatSystem
	drives this from its existing single Heartbeat connection rather than this module opening a
	second one).
]]

local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local HitboxShapes = require(ReplicatedStorage.Shared.HitboxShapes)
local HitboxDebugState = require(script.Parent.HitboxDebugState)

local HitboxResolver = {}

-- Sub-sample count and per-query part cap live in Constants.Combat.Hitboxes.SweepSubsteps/
-- MaxPartsPerQuery -- were module-local constants here, moved per luau-coding-standards.md's "no
-- magic numbers in system logic" now that every other hitbox tunable lives in Constants.lua.

--
-- Debug visualization, gated on HitboxDebugState.IsEnabled() -- a runtime-toggleable flag an
-- authorized admin flips live via DevMenuSystem.lua's GetHitboxDebug/SetHitboxDebug remotes (see
-- HitboxDebugState.lua's own header), works in Studio AND a published server alike. Formerly a
-- static Constants.Combat.DebugHitboxes read additionally hard-gated on RunService:IsStudio() --
-- that constant is now only HitboxDebugState's own boot-time default. Purely a rendered Part per
-- sampled pose; nothing here is read by, or can influence, the actual overlap query above it in
-- performSample. Cosmetics live in Constants.Combat.Hitboxes.DebugPart, alongside this table's own
-- sibling tunables (SweepSubsteps/MaxPartsPerQuery) -- see that field's own header.
--

local DEBUG_PART_LIFETIME = Constants.Combat.Hitboxes.DebugPart.LifetimeSeconds
local DEBUG_PART_COLOR = Constants.Combat.Hitboxes.DebugPart.Color
local DEBUG_PART_TRANSPARENCY = Constants.Combat.Hitboxes.DebugPart.Transparency

local debugFolder: Folder? = nil

local function getDebugFolder(): Folder
	if debugFolder and debugFolder.Parent then
		return debugFolder
	end
	local folder = Instance.new("Folder")
	folder.Name = "HitboxDebug"
	folder.Parent = Workspace
	debugFolder = folder
	return folder
end

-- ALWAYS-visible (never gated on Studio/DebugHitboxes, unlike getDebugFolder above) -- a fired
-- projectile IS the attack's visual, not a debug aid layered on top of an animation, so every
-- player needs to see it travel in a live server. Kept as its own folder/name (not parented into
-- HitboxDebug) so the two concerns -- "temporary debug visualization" and "real gameplay object" --
-- can never be confused by anything inspecting Workspace (a moderation tool, a screenshot, a
-- Studio explorer).
local projectilesFolder: Folder? = nil

local function getProjectilesFolder(): Folder
	if projectilesFolder and projectilesFolder.Parent then
		return projectilesFolder
	end
	local folder = Instance.new("Folder")
	folder.Name = "MoveProjectiles"
	folder.Parent = Workspace
	projectilesFolder = folder
	return folder
end

-- True when this definition's overlap query IS its volume, so the broadphase result needs no
-- narrow-phase filtering. Every hand-authored Constants attack leaves Shape nil (implicitly Box)
-- and every Move Creation System Box/Sphere move qualifies too -- see
-- HitboxShapes.IsExactBroadphase and Types.HitboxAttackDefinition.Shape's own header for why that
-- split is what keeps existing attacks byte-identical.
local function isExactShape(definition: Types.HitboxAttackDefinition): boolean
	local shape = definition.Shape
	return shape == nil or HitboxShapes.IsExactBroadphase(shape)
end

local function newDebugPart(): Part
	local part = Instance.new("Part")
	part.Name = "HitboxSample"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.ForceField
	part.Color = DEBUG_PART_COLOR
	part.Transparency = DEBUG_PART_TRANSPARENCY
	return part
end

-- Shape-aware, so the debug part is never misleading about the real hitbox:
--   * Sphere renders a Ball sized 2*Radius and Box renders a Block sized Size, each matching
--     exactly the query performSample ran for it (GetPartBoundsInRadius / GetPartBoundsInBox).
--   * Every other shape renders HitboxShapes.BuildPreviewParts' decomposition -- the SAME
--     decomposition the Move Editor's own viewport draws, from the same function, so what an admin
--     tuned in the editor and what they see in-world during a real swing are the same silhouette
--     rather than two independent approximations that can drift.
local function renderDebugHitbox(pose: CFrame, definition: Types.HitboxAttackDefinition): ()
	if not HitboxDebugState.IsEnabled() then
		return
	end

	local dimensions = definition.Dimensions
	if not isExactShape(definition) then
		if not dimensions then
			-- Structurally unreachable in practice (MoveRegistryManager.Validate guarantees
			-- Dimensions for every authored non-Box/Sphere move -- see collectOverlappedModels'
			-- own identical guard/comment above), but definition.Size is ONLY ever populated for
			-- Shape == "Box" (MoveTypes.MoveDefinition.Size's own header), so falling through to
			-- the Box/Sphere branch below for e.g. a Cone would assign nil to Part.Size -- a
			-- non-optional Vector3 property -- and throw from inside this module's own Heartbeat
			-- loop (HitboxResolver.Update), which would cut that frame's sampling for every OTHER
			-- concurrently active swing short too. Skipping the render (rather than guessing a
			-- shape it was never given the numbers for) is the same defensive posture
			-- collectOverlappedModels takes for the same unreachable case.
			return
		end
		local folder = getDebugFolder()
		for _, piece in ipairs(HitboxShapes.BuildPreviewParts(definition.Shape :: HitboxShapes.ShapeId, dimensions)) do
			local part = newDebugPart()
			part.Shape = piece.PartType
			part.Size = piece.Size
			part.CFrame = pose * piece.CFrame
			part.Parent = folder
			Debris:AddItem(part, DEBUG_PART_LIFETIME)
		end
		return
	end

	local part = newDebugPart()
	if definition.Shape == "Sphere" then
		local diameter = (definition.Radius :: number) * 2
		part.Shape = Enum.PartType.Ball
		part.Size = Vector3.new(diameter, diameter, diameter)
	elseif definition.Size then
		part.Size = definition.Size
	else
		-- Same unreachable-in-practice guard as above: isExactShape means Shape is nil or "Box"
		-- here, and every hand-authored Constants attack (Shape nil) and every Box move always
		-- carries a real Size -- but assigning nil to Part.Size would throw regardless of how
		-- confident that guarantee is, so this stays a skip, not a trust.
		return
	end
	part.CFrame = pose
	part.Parent = getDebugFolder()

	Debris:AddItem(part, DEBUG_PART_LIFETIME)
end

-- The ONE overlap query both engines below run, over an already-computed list of swept poses.
-- Extracted when the shape vocabulary widened from two to twelve: the swing and projectile samplers
-- had carried an identical copy of this loop, and a twelve-shape broadphase/narrow-phase split
-- duplicated across two functions is exactly the kind of thing that ends up fixed in one of them.
--
-- Returns every distinct Model overlapping ANY pose that isn't already in `alreadyHit`, unordered --
-- the caller applies its own priority sort and MaxTargets cap, which is where those two engines
-- genuinely differ.
local function collectOverlappedModels(
	definition: Types.HitboxAttackDefinition,
	poses: { CFrame },
	candidates: { Model },
	alreadyHit: { [Model]: boolean }
): { Model }
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Include
	overlapParams.FilterDescendantsInstances = candidates
	overlapParams.MaxParts = Constants.Combat.Hitboxes.MaxPartsPerQuery

	local exact = isExactShape(definition)
	local dimensions = definition.Dimensions
	if not exact and not dimensions then
		-- Structurally unreachable: MoveRegistryManager.Validate guarantees Dimensions for every
		-- authored move, and DefaultMoveRegistry.ApplyEdit writes it for every non-Box/Sphere retune.
		-- Guarded rather than indexed anyway, because the alternative to a defensive branch here is
		-- an error thrown from inside a Heartbeat loop that would take the whole combat tick down.
		return {}
	end

	-- Broadphase geometry for a non-exact shape: an oriented box that conservatively contains the
	-- volume, offset into the shape's own local frame (non-identity for the shapes that grow
	-- forward from their origin rather than straddling it).
	local boundsSize, boundsCentre = Vector3.zero, CFrame.identity
	if not exact then
		boundsSize, boundsCentre = HitboxShapes.BoundingBox(definition.Shape :: HitboxShapes.ShapeId, dimensions)
	end

	local overlapped: { Model } = {}
	local seen: { [Model]: boolean } = {}

	for _, pose in ipairs(poses) do
		local parts: { BasePart }
		if definition.Shape == "Sphere" then
			-- Rotation-irrelevant, so orientation sweeping still happens for consistency but has no
			-- effect on which parts overlap.
			parts = Workspace:GetPartBoundsInRadius(pose.Position, definition.Radius :: number, overlapParams)
		elseif exact then
			parts = Workspace:GetPartBoundsInBox(pose, definition.Size, overlapParams)
		else
			parts = Workspace:GetPartBoundsInBox(pose * boundsCentre, boundsSize, overlapParams)
		end

		for _, part in ipairs(parts) do
			local model = part:FindFirstAncestorOfClass("Model") :: Model?
			if not model or alreadyHit[model] or seen[model] then
				continue
			end
			if not exact then
				-- Narrow phase. The broadphase returns whole PARTS but the shape test takes a
				-- POINT, so the part's own inscribed radius (half its smallest extent) is passed as
				-- slack -- a part clipping the volume by a sliver still counts, which is the right
				-- failure direction for a hitbox. See Constants.Combat.Hitboxes
				-- .NarrowPhaseMarginFraction.
				local localPoint = pose:PointToObjectSpace(part.Position)
				local margin = math.min(part.Size.X, part.Size.Y, part.Size.Z)
					* Constants.Combat.Hitboxes.NarrowPhaseMarginFraction
				if
					not HitboxShapes.ContainsPoint(
						definition.Shape :: HitboxShapes.ShapeId,
						dimensions,
						localPoint,
						margin
					)
				then
					continue
				end
			end
			seen[model] = true
			table.insert(overlapped, model)
		end
	end

	return overlapped
end

export type SwingConfig = {
	-- The attacker's HumanoidRootPart, read fresh every sample -- the hitbox tracks wherever this
	-- part currently is/faces, it is not frozen at swing start. Still the FACING source even when
	-- AttackerTrackedPart below is supplied -- see that field's own header for why.
	AttackerRootPart: BasePart,
	-- Optional. When supplied (and still parented -- see performSample's own fallback), the hitbox's
	-- POSITION tracks this part instead of AttackerRootPart's -- for an attack that should follow
	-- the attacker's actual swinging hand rather than a fixed root-relative guess (a hand ends up
	-- meaningfully forward of the torso center during a lunge, which a root-relative Offset alone
	-- can't account for across every animation pose). The hitbox's ORIENTATION still comes from
	-- AttackerRootPart, never the hand's own raw rotation -- a hand's rotation swings through wild
	-- angles over the course of a punch animation, and inheriting that would spin/tumble the box
	-- through the swing instead of sweeping cleanly forward the way Size/Offset were tuned to
	-- assume. Every OTHER attack (the M1 Basic/Heavy string) leaves this nil and keeps the original
	-- root-relative behavior unchanged.
	AttackerTrackedPart: BasePart?,
	Definition: Types.HitboxAttackDefinition,
	-- Called fresh on every sample so the candidate roster (deaths, leaves, new lock-on) is always
	-- current. Returning the attacker's own Model is harmless (never matches itself) but the caller
	-- should exclude it anyway to keep the box's own query small.
	GetCandidates: () -> { Model },
	-- Checked before every sample; returning false ends the swing immediately (no further sampling,
	-- OnComplete still fires) -- e.g. the attacker died or respawned since the swing started.
	IsStillValid: () -> boolean,
	-- Called at most once per distinct Model per swing (this module's own dedup guarantee), for
	-- every Model whose parts overlap the box and hasn't already returned true from this callback
	-- this swing. Return true to mean "this counted as a landed hit" -- the model is then excluded
	-- from all future samples this swing. Return false to mean "overlapped, but didn't count" (e.g.
	-- failed an arc/line-of-sight check) -- the model remains eligible and may be re-offered on a
	-- later sample if it's still overlapping.
	OnHit: (target: Model) -> boolean,
	OnComplete: (() -> ())?,
}

type ActiveSwing = {
	attackerRootPart: BasePart,
	attackerTrackedPart: BasePart?,
	definition: Types.HitboxAttackDefinition,
	getCandidates: () -> { Model },
	isStillValid: () -> boolean,
	onHit: (Model) -> boolean,
	onComplete: (() -> ())?,

	elapsed: number,
	timeSinceLastSample: number,
	sampleCount: number,
	hasPreviousSample: boolean,
	previousCFrame: CFrame,
	hitModels: { [Model]: boolean },
	hitCount: number,
}

local activeSwings: { [number]: ActiveSwing } = {}
local nextSwingId = 0

export type ProjectileConfig = {
	-- Captured ONCE at launch (the attacker's root CFrame * the move's Offset, at throw time) --
	-- unlike SwingConfig.AttackerRootPart, nothing here is read again after this call. The
	-- projectile's own forward direction (its local -Z) is baked into this pose at spawn and never
	-- re-derived from the attacker afterward.
	SpawnCFrame: CFrame,
	-- Definition.Projectile must be set (Speed/MaxRange) -- see Types.HitboxAttackDefinition's own
	-- header. Shape/Size/Radius/Damage/PostureDamage/MaxTargets all mean exactly what they mean for
	-- a swing; ArcDegrees is ignored (a fast-moving object already left the attacker's own facing
	-- arc behind, an arc check against the THROWER's current facing has no meaningful reading here).
	Definition: Types.HitboxAttackDefinition,
	-- Takes the projectile's own CURRENT position (re-queried fresh every sample as it travels) --
	-- deliberately NOT a zero-argument closure like SwingConfig.GetCandidates, since a projectile
	-- detaches from the attacker and can end up far outside whatever radius a caller might center on
	-- the attacker instead. See CombatSystem.getProjectileCandidates, the only real caller.
	GetCandidates: (currentPosition: Vector3) -> { Model },
	-- Same dedup/priority/MaxTargets contract as SwingConfig.OnHit, plus the projectile's OWN
	-- current-position Part (its visual, also serving as a real BasePart the caller can feed into
	-- HitResolution.IsSwingTargetValid's LOS check as the origin) -- a projectile has no
	-- "attacker root" of its own the way a swing does, so this is how the caller resolves one.
	OnHit: (target: Model, projectileRoot: BasePart) -> boolean,
	OnComplete: (() -> ())?,
}

type ActiveProjectile = {
	spawnCFrame: CFrame,
	definition: Types.HitboxAttackDefinition,
	getCandidates: (Vector3) -> { Model },
	onHit: (Model, BasePart) -> boolean,
	onComplete: (() -> ())?,
	visualPart: BasePart,
	-- Local offset from the projectile's true pose to where its visual Part must be centred -- see
	-- StartProjectile's own comment. Identity for every Box/Sphere projectile.
	visualOffset: CFrame,

	elapsed: number,
	timeSinceLastSample: number,
	sampleCount: number,
	hasPreviousSample: boolean,
	previousSampleCFrame: CFrame,
	hitModels: { [Model]: boolean },
	hitCount: number,
}

local activeProjectiles: { [number]: ActiveProjectile } = {}
local nextProjectileId = 0

local function performSample(swing: ActiveSwing): ()
	local definition = swing.definition
	local rootCFrame = swing.attackerRootPart.CFrame

	-- Tracked-part position, root-part facing -- see SwingConfig.AttackerTrackedPart's own header
	-- for why these are deliberately split rather than just using the tracked part's own full
	-- CFrame. Falls back to the root part's own position (i.e. the original, pre-tracking behavior)
	-- if no tracked part was supplied, or it's been destroyed/unparented since the swing started
	-- (e.g. a respawn mid-swing) -- never errors on a stale reference.
	local trackedPart = swing.attackerTrackedPart
	local trackedPosition = if trackedPart and trackedPart.Parent then trackedPart.Position else rootCFrame.Position
	local trackedCFrame = CFrame.new(trackedPosition) * (rootCFrame - rootCFrame.Position)

	local currentCFrame = trackedCFrame * definition.Offset

	-- Swept sub-poses between the previous and current sample (Constants.Combat.Hitboxes.
	-- SweepSubsteps); the very first sample of a swing has nothing to sweep from, so it's just the
	-- current pose.
	local poses: { CFrame }
	if swing.hasPreviousSample then
		poses = {}
		for step = 1, Constants.Combat.Hitboxes.SweepSubsteps do
			table.insert(
				poses,
				swing.previousCFrame:Lerp(currentCFrame, step / Constants.Combat.Hitboxes.SweepSubsteps)
			)
		end
	else
		poses = { currentCFrame }
	end

	-- Rendered (when DebugHitboxes is on) regardless of whether any candidate exists this sample --
	-- debug visualization is for verifying shape/reach/timing on its own, not only during a real
	-- exchange.
	for _, pose in ipairs(poses) do
		renderDebugHitbox(pose, definition)
	end

	local candidates = swing.getCandidates()
	if #candidates > 0 then
		-- Priority rank per candidate (1 = highest), so a capped swing (definition.MaxTargets)
		-- offers its remaining slots to the caller's ordered candidate list (locked-on target
		-- first -- see CombatSystem.lua's getSwingCandidates) instead of whatever order
		-- Workspace:GetPartBoundsInBox happens to return, which reflects its own spatial-query
		-- broadphase, not the FilterDescendantsInstances list's order -- a capped swing could
		-- otherwise land on an unlocked bystander instead of the locked target in a multi-target
		-- scrum even though the candidate list already put the locked target first.
		local priorityByModel: { [Model]: number } = {}
		for index, model in ipairs(candidates) do
			priorityByModel[model] = index
		end

		local maxTargets = definition.MaxTargets or math.huge

		-- Gather every distinct, not-yet-hit model this sample overlaps (across every sweep
		-- sub-pose) before applying the cap, so the cap is applied to a priority-sorted roster
		-- instead of incrementally to whatever order each pose's physics query happened to return.
		local overlapped = collectOverlappedModels(definition, poses, candidates, swing.hitModels)

		table.sort(overlapped, function(a, b)
			return (priorityByModel[a] or math.huge) < (priorityByModel[b] or math.huge)
		end)

		for _, model in ipairs(overlapped) do
			if swing.hitCount >= maxTargets then
				break
			end
			if swing.onHit(model) then
				swing.hitModels[model] = true
				swing.hitCount += 1
			end
		end
	end

	swing.previousCFrame = currentCFrame
	swing.hasPreviousSample = true
end

-- Pure kinematic pose from elapsed ACTIVE-window time (i.e. time since the projectile actually
-- launched, past its own Windup) -- travels in a straight line along the spawn pose's own local -Z
-- (Roblox's forward convention, matching every other Offset in this codebase), clamped at
-- MaxRange so a long ActiveSeconds can't outrun the authored travel distance.
local function computeProjectilePose(projectile: ActiveProjectile, activeElapsed: number): CFrame
	local projectileInfo = projectile.definition.Projectile :: { Speed: number, MaxRange: number }
	local traveledStuds = math.min(math.max(activeElapsed, 0) * projectileInfo.Speed, projectileInfo.MaxRange)
	return projectile.spawnCFrame * CFrame.new(0, 0, -traveledStuds)
end

-- Same overlap-query/sweep/dedup/priority shape as performSample above, parameterized by the
-- ALREADY-computed current pose (Update's own loop computes it every tick for smooth visual
-- movement; this function only runs at the coarser SampleRate cadence for the actual hit check --
-- see Update's own header for why those two are deliberately decoupled here but not for a swing).
local function performProjectileSample(projectile: ActiveProjectile, currentCFrame: CFrame): ()
	local definition = projectile.definition

	local poses: { CFrame }
	if projectile.hasPreviousSample then
		poses = {}
		for step = 1, Constants.Combat.Hitboxes.SweepSubsteps do
			table.insert(
				poses,
				projectile.previousSampleCFrame:Lerp(currentCFrame, step / Constants.Combat.Hitboxes.SweepSubsteps)
			)
		end
	else
		poses = { currentCFrame }
	end

	local candidates = projectile.getCandidates(currentCFrame.Position)
	if #candidates > 0 then
		local priorityByModel: { [Model]: number } = {}
		for index, model in ipairs(candidates) do
			priorityByModel[model] = index
		end

		local maxTargets = definition.MaxTargets or math.huge

		local overlapped = collectOverlappedModels(definition, poses, candidates, projectile.hitModels)

		table.sort(overlapped, function(a, b)
			return (priorityByModel[a] or math.huge) < (priorityByModel[b] or math.huge)
		end)

		for _, model in ipairs(overlapped) do
			if projectile.hitCount >= maxTargets then
				break
			end
			if projectile.onHit(model, projectile.visualPart) then
				projectile.hitModels[model] = true
				projectile.hitCount += 1
			end
		end
	end

	projectile.previousSampleCFrame = currentCFrame
	projectile.hasPreviousSample = true
end

-- Fire-and-forget: schedules a new, real, always-visible projectile tracked internally, advanced by
-- Update(). Spawns its visual Part immediately (hidden via Transparency=1 during Windup -- see
-- Update's own reveal-on-launch step) so its lifetime is bounded by a Debris:AddItem safety net
-- from the very start, independent of Update() ever running to a normal completion for it (a
-- belt-and-suspenders guard the swing engine doesn't need, since a swing owns no Instance of its
-- own to leak).
function HitboxResolver.StartProjectile(config: ProjectileConfig): ()
	assert(config.Definition.Projectile ~= nil, "StartProjectile requires Definition.Projectile to be set")
	local definition = config.Definition

	-- Non-identity only for a shape whose volume sits entirely in front of its own origin (Cone,
	-- Beam, Blade, Pyramid) -- their bounding box is centred half a Length ahead, so the visual Part
	-- has to be too, or a Beam would render straddling its spawn point instead of extending from it.
	local visualOffset = CFrame.identity

	local visualPart = Instance.new("Part")
	visualPart.Name = "Projectile_" .. definition.DebugName
	visualPart.Anchored = true
	visualPart.CanCollide = false
	visualPart.CanQuery = false
	visualPart.CanTouch = false
	visualPart.CastShadow = false
	visualPart.Material = Enum.Material.Neon
	visualPart.Color = DEBUG_PART_COLOR
	visualPart.Transparency = 1 -- hidden until the Windup telegraph ends -- see Update's reveal step
	if definition.Shape == "Sphere" then
		local diameter = (definition.Radius :: number) * 2
		visualPart.Shape = Enum.PartType.Ball
		visualPart.Size = Vector3.new(diameter, diameter, diameter)
	elseif not isExactShape(definition) and definition.Dimensions then
		-- Deliberately the shape's BOUNDING BOX rather than its full decomposition. A projectile's
		-- visual is one Part that has to be re-CFramed every tick as it flies (and doubles as the
		-- caller's line-of-sight origin -- see ProjectileConfig.OnHit), so a twelve-slab
		-- decomposition would mean twelve parts to move per tick per projectile for a shape the
		-- player only ever sees in motion. The HIT test is still exact
		-- (collectOverlappedModels' narrow phase); this is the travelling visual only.
		local boundsSize, boundsCentre =
			HitboxShapes.BoundingBox(definition.Shape :: HitboxShapes.ShapeId, definition.Dimensions)
		visualPart.Size = boundsSize
		visualOffset = boundsCentre
	else
		visualPart.Size = definition.Size
	end
	visualPart.CFrame = config.SpawnCFrame * visualOffset
	visualPart.Parent = getProjectilesFolder()

	local safetyNetSeconds = definition.WindupSeconds + definition.ActiveSeconds + definition.RecoverySeconds + 2
	Debris:AddItem(visualPart, safetyNetSeconds)

	nextProjectileId += 1
	activeProjectiles[nextProjectileId] = {
		spawnCFrame = config.SpawnCFrame,
		definition = definition,
		getCandidates = config.GetCandidates,
		onHit = config.OnHit,
		onComplete = config.OnComplete,
		visualPart = visualPart,
		visualOffset = visualOffset,

		elapsed = 0,
		timeSinceLastSample = math.huge,
		sampleCount = 0,
		hasPreviousSample = false,
		previousSampleCFrame = CFrame.identity,
		hitModels = {},
		hitCount = 0,
	}
end

-- Fire-and-forget: schedules a new swing tracked internally, advanced by Update(). No handle is
-- returned -- nothing in this codebase needs to cancel a swing mid-flight yet (IsStillValid already
-- covers "the attacker is no longer in a state where this swing should keep going"), and returning
-- one on spec would be exactly the kind of unused surface engineering-standards.md's "no stubs"
-- rule warns against.
function HitboxResolver.StartSwing(config: SwingConfig): ()
	nextSwingId += 1
	activeSwings[nextSwingId] = {
		attackerRootPart = config.AttackerRootPart,
		attackerTrackedPart = config.AttackerTrackedPart,
		definition = config.Definition,
		getCandidates = config.GetCandidates,
		isStillValid = config.IsStillValid,
		onHit = config.OnHit,
		onComplete = config.OnComplete,

		elapsed = 0,
		timeSinceLastSample = math.huge, -- forces an immediate sample on the first active-window tick
		sampleCount = 0,
		hasPreviousSample = false,
		previousCFrame = CFrame.identity,
		hitModels = {},
		hitCount = 0,
	}
end

-- Call once per Heartbeat from CombatSystem.lua. Advances every in-flight swing: ends it (and fires
-- OnComplete) once IsStillValid fails or its full windup+active+recovery timeline has elapsed;
-- otherwise samples the hitbox on a SampleRate cadence while inside the active window, up to
-- MaxSamplesPerSwing samples.
function HitboxResolver.Update(deltaTime: number): ()
	for id, swing in pairs(activeSwings) do
		if not swing.attackerRootPart.Parent or not swing.isStillValid() then
			activeSwings[id] = nil
			if swing.onComplete then
				swing.onComplete()
			end
			continue
		end

		swing.elapsed += deltaTime
		local definition = swing.definition
		local totalDuration = definition.WindupSeconds + definition.ActiveSeconds + definition.RecoverySeconds

		if swing.elapsed >= totalDuration then
			activeSwings[id] = nil
			if swing.onComplete then
				swing.onComplete()
			end
			continue
		end

		local activeWindowStart = definition.WindupSeconds
		local activeWindowEnd = activeWindowStart + definition.ActiveSeconds
		if swing.elapsed < activeWindowStart or swing.elapsed > activeWindowEnd then
			continue
		end

		if swing.sampleCount >= Constants.Combat.Hitboxes.MaxSamplesPerSwing then
			continue
		end

		swing.timeSinceLastSample += deltaTime
		if swing.timeSinceLastSample < Constants.Combat.Hitboxes.SampleRate then
			continue
		end

		swing.timeSinceLastSample = 0
		swing.sampleCount += 1
		performSample(swing)
	end

	-- Every in-flight projectile -- see this file's own header for why this is a separate loop
	-- rather than folded into the swing loop above. The visual Part's CFrame is updated EVERY tick
	-- (smooth travel), while the actual overlap/hit check only runs at the coarser SampleRate
	-- cadence, capped by MaxSamplesPerProjectile (a much higher ceiling than a swing's
	-- MaxSamplesPerSwing, since a projectile's own ActiveSeconds is expected to cover real seconds
	-- of flight, not a fraction of one) -- decoupling those two is what a swing never needed, since
	-- a swing has no independent "smooth visual" of its own to maintain (the animation IS the
	-- visual, and it plays via a completely separate system).
	for id, projectile in pairs(activeProjectiles) do
		projectile.elapsed += deltaTime
		local definition = projectile.definition
		local projectileInfo = definition.Projectile :: { Speed: number, MaxRange: number }
		local maxFlightSeconds = math.min(definition.ActiveSeconds, projectileInfo.MaxRange / projectileInfo.Speed)
		local totalDuration = definition.WindupSeconds + maxFlightSeconds
		local maxTargets = definition.MaxTargets or math.huge

		-- Ends the instant it's traveled its full range/time OR already landed on every target it's
		-- allowed to (MaxTargets doubles as pierce count -- see MoveProjectileConfig's own header) --
		-- a projectile that already hit its cap has nothing left to do flying on screen, unlike a
		-- swing (which keeps sampling out its own window regardless, since re-sampling costs nothing
		-- visually for an already-invisible hitbox).
		if projectile.elapsed >= totalDuration or projectile.hitCount >= maxTargets then
			activeProjectiles[id] = nil
			projectile.visualPart:Destroy()
			if projectile.onComplete then
				projectile.onComplete()
			end
			continue
		end

		if projectile.elapsed < definition.WindupSeconds then
			continue -- still telegraphing -- visual part stays hidden at its spawn pose
		end

		local activeElapsed = projectile.elapsed - definition.WindupSeconds
		local currentCFrame = computeProjectilePose(projectile, activeElapsed)
		projectile.visualPart.CFrame = currentCFrame * projectile.visualOffset
		if projectile.visualPart.Transparency == 1 then
			-- One-time reveal the instant Windup ends -- see StartProjectile's own initial
			-- Transparency=1 comment.
			projectile.visualPart.Transparency = DEBUG_PART_TRANSPARENCY
		end

		projectile.timeSinceLastSample += deltaTime
		if
			projectile.timeSinceLastSample >= Constants.Combat.Hitboxes.SampleRate
			and projectile.sampleCount < Constants.Combat.Hitboxes.MaxSamplesPerProjectile
		then
			projectile.timeSinceLastSample = 0
			projectile.sampleCount += 1
			performProjectileSample(projectile, currentCFrame)
		end
	end
end

return HitboxResolver
