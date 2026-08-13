--!strict
--[[
	EnvironmentProbe.lua

	Owns: every raycast and spatial query the parkour framework makes, and the per-frame budget that
	keeps them affordable. Fills the ParkourContext's Ground/Obstacle/WallLeft/WallRight/Ledge/
	CeilingClear fields; nothing else in the framework is allowed to cast a ray.

	THREE DESIGN DECISIONS THAT ARE THE WHOLE POINT OF THIS FILE:

	1. FEW RAYS, NOT MANY. The obvious way to measure an obstacle -- a vertical fan of forward rays
	   every 0.35 studs from the ankle to head height -- costs ~20 casts per frame per player and
	   scales terribly. This module instead uses the standard front-ray/top-down pair: one forward ray
	   finds the near face, then a single DOWNWARD ray from above that face finds the top surface, a
	   second downward ray past the far edge answers "is it shallow enough to vault, and is there
	   anywhere to land," and a short upward ray answers "is there anywhere to stand." Six rays worst
	   case for a complete obstacle description, and the common case (nothing ahead) is one.

	   The ledge search is the one probe that deliberately spends more than the minimum, and castSphere
	   below states the reason: it is the only probe whose question is "is the player reaching for
	   something roughly over there," and answering that with a zero-width line is how a grab the player
	   is certain they made gets reported as open air.

	2. CACHED AND SCHEDULED, NOT UNCONDITIONAL. Each probe family carries its own refresh interval
	   (ParkourConstants.Probe.*IntervalSeconds) and its last result. A state declares which probes it
	   actually depends on (ParkourTypes.StateDefinition.Probes) and those are forced fresh every
	   frame; everything else is served from cache at ~30Hz or skipped entirely while the character is
	   too slow to have anything to detect. Sprinting refreshes obstacles every frame because it is
	   about to vault; standing still refreshes almost nothing.

	3. A HARD PER-FRAME CEILING. Once ParkourConstants.Probe.MaxRaysPerFrame casts have been made in
	   one Update, further casts are refused and those probes keep last frame's cached answer for one
	   more frame. Probes are ordered by importance (ground first, then whatever the active state
	   requested, then the speculative ones), so the ceiling degrades the least important information
	   first instead of failing arbitrarily. This is what makes the design's "optimized enough to work
	   reliably during intense multiplayer combat" a property of the code rather than a hope -- the
	   worst case is bounded by a constant, not by what happens to be in front of the player.

	Every result table is persistent and mutated in place -- see the RESULT TABLES block below. This
	module allocates no tables and no Vector3s per frame beyond what the engine's own Raycast returns.

	Does not own: interpreting what it finds (Shared/Parkour/ObstacleClassifier.lua and the State
	modules), designer tag overrides (Shared/Parkour/ParkourTagging.lua supplies those and this module
	simply stamps them onto the results), or drawing any of it (Client/Parkour/ParkourDebug.lua reads
	these same results).
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)
local ParkourTagging = require(ReplicatedStorage.Shared.Parkour.ParkourTagging)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)

type GroundProbe = ParkourTypes.GroundProbe
type ObstacleProbe = ParkourTypes.ObstacleProbe
type WallProbe = ParkourTypes.WallProbe
type LedgeProbe = ParkourTypes.LedgeProbe
type ProbeRequest = ParkourTypes.ProbeRequest
type ParkourContext = ParkourTypes.ParkourContext

local EnvironmentProbe = {}

local UP = Vector3.new(0, 1, 0)
local PROBE = ParkourConstants.Probe
local OBSTACLE = ParkourConstants.Obstacle
local WALLRUN = ParkourConstants.WallRun
local LEDGE = ParkourConstants.Ledge
local SLOPE = ParkourConstants.Slope

--
-- RESULT TABLES -- allocated once at module load and mutated in place forever after. The framework
-- runs these every Heartbeat for the whole session; allocating six tables (and the Vector3s inside
-- them) per frame would put a steady, entirely avoidable load on the collector during exactly the
-- moments -- a fast chained traversal mid-fight -- when frame time matters most. Every consumer
-- reads fields immediately and never retains a reference (ParkourTypes documents this on each type),
-- which is what makes the reuse safe.
--

local ground: GroundProbe = {
	Grounded = false,
	NearGround = false,
	Distance = math.huge,
	Normal = UP,
	SlopeAngle = 0,
	Standable = false,
	Material = Enum.Material.Air,
	Instance = nil,
	FrictionScale = 1,
	SampledAt = 0,
}

local obstacle: ObstacleProbe = {
	Found = false,
	Distance = math.huge,
	Height = 0,
	Depth = math.huge,
	Normal = UP,
	TopPosition = Vector3.zero,
	HasLandingSpace = false,
	HasStandingSpace = false,
	Instance = nil,
	VaultAllowed = true,
	MantleAllowed = true,
	SampledAt = 0,
}

local function makeWallProbe(): WallProbe
	return {
		Found = false,
		Distance = math.huge,
		Normal = UP,
		Tangent = Vector3.zero,
		TiltAngle = 90,
		Instance = nil,
		WallRunAllowed = true,
		BounceScale = 1,
		SampledAt = 0,
	}
end

local wallLeft: WallProbe = makeWallProbe()
local wallRight: WallProbe = makeWallProbe()

local ledge: LedgeProbe = {
	Found = false,
	EdgePosition = Vector3.zero,
	WallNormal = UP,
	HasStandingSpace = false,
	HasHangSpace = false,
	Instance = nil,
	Allowed = true,
	SampledAt = 0,
}

local ceilingClear = true
local ceilingSampledAt = 0

--
-- Bound character state
--

local raycastParams: RaycastParams? = nil
local boundCharacter: Model? = nil
-- Distance from the root part's centre down to the sole of the character's feet -- half the root's
-- own height plus the Humanoid's hip height. Every "height above the foot plane" measurement in this
-- file is relative to this, so obstacle height bands read as real-world knee/waist/chest heights on
-- any rig scale rather than being calibrated to one specific avatar.
local footOffset = 3

-- Casts made so far this Update. Reset at the top of Update; consulted by castRay below.
local rayBudgetUsed = 0

-- Rebuilds the shared RaycastParams for a freshly-spawned character. RespectCanCollide is the load-
-- bearing setting here: every FX part this codebase spawns (MovementVFX dust carriers, HitFlash
-- highlights, FlightVFX rings, this feature's own debug adorns) is CanCollide = false, so honoring
-- collidability means none of them can ever be mistaken for vaultable geometry without maintaining a
-- filter list that would need updating every time a new effect is added.
local function rebuildParams(character: Model): ()
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	params.IgnoreWater = true
	params.RespectCanCollide = true
	if PROBE.CollisionGroup ~= "" then
		params.CollisionGroup = PROBE.CollisionGroup
	end
	raycastParams = params
end

-- Binds a character and clears every cached result. Called from ParkourController's own character
-- bind path; safe to call repeatedly.
function EnvironmentProbe.BindCharacter(character: Model, humanoid: Humanoid, rootPart: BasePart): ()
	boundCharacter = character
	rebuildParams(character)
	footOffset = rootPart.Size.Y * 0.5 + humanoid.HipHeight

	ground.Grounded = false
	ground.NearGround = false
	ground.Distance = math.huge
	ground.SampledAt = 0
	obstacle.Found = false
	obstacle.SampledAt = 0
	wallLeft.Found = false
	wallLeft.SampledAt = 0
	wallRight.Found = false
	wallRight.SampledAt = 0
	ledge.Found = false
	ledge.SampledAt = 0
	ceilingClear = true
	ceilingSampledAt = 0
end

function EnvironmentProbe.Unbind(): ()
	boundCharacter = nil
	raycastParams = nil
end

-- The single cast entry point. Returns nil both for a genuine miss AND for a refusal on budget --
-- the two are deliberately indistinguishable to callers, because a probe that could not be cast this
-- frame must behave exactly like one that found nothing: it keeps its cached result (the caller only
-- writes the result table when it actually got to run), and the framework degrades to slightly stale
-- information rather than to a wrong answer.
local function castRay(origin: Vector3, direction: Vector3): RaycastResult?
	local params = raycastParams
	if not params then
		return nil
	end
	if rayBudgetUsed >= PROBE.MaxRaysPerFrame then
		return nil
	end
	rayBudgetUsed += 1
	return Workspace:Raycast(origin, direction, params)
end

-- The swept-sphere counterpart, on the same budget and with the same refusal semantics. Used by
-- exactly one probe -- the ledge face search -- because it is the only one whose question is "is the
-- player reaching for something roughly over there" rather than "what is exactly along this line."
--
-- A ray answers the second question and is the right tool everywhere else in this file. It is the
-- wrong tool on its own for a grab: it demands the root's centre line intersect the wall, so half a
-- stud of lateral drift past a pillar's corner, or a grab attempted while the camera is still
-- swinging, is a miss on geometry the player was plainly reaching for. One spherecast covers a
-- Ledge.GrabProbeRadius-wide corridor instead.
--
-- It does NOT replace the ray -- see tryLedgeDirection for the order the two run in and the engine
-- behavior that forces it.
local function castSphere(origin: Vector3, radius: number, direction: Vector3): RaycastResult?
	local params = raycastParams
	if not params then
		return nil
	end
	if rayBudgetUsed >= PROBE.MaxRaysPerFrame then
		return nil
	end
	rayBudgetUsed += 1
	return Workspace:Spherecast(origin, radius, direction, params)
end

-- True when this probe family's cached result is still inside its refresh interval and the caller
-- did not explicitly demand a fresh one. `forced` comes from the active state's own ProbeRequest.
local function isCacheFresh(sampledAt: number, intervalSeconds: number, now: number, forced: boolean): boolean
	if forced then
		return false
	end
	if sampledAt <= 0 then
		return false
	end
	return (now - sampledAt) < intervalSeconds
end

--
-- Ground
--

local function probeGround(rootPart: BasePart, now: number): ()
	local origin = rootPart.Position
	local reach = footOffset + SLOPE.GroundProbeDistance
	local result = castRay(origin, Vector3.new(0, -reach, 0))

	ground.SampledAt = now
	if not result then
		ground.Grounded = false
		ground.NearGround = false
		ground.Distance = math.huge
		ground.Normal = UP
		ground.SlopeAngle = 0
		ground.Standable = false
		ground.Material = Enum.Material.Air
		ground.Instance = nil
		ground.FrictionScale = 1
		return
	end

	-- Distance measured from the SOLE, not from the root's centre -- "0.2 studs above the floor" is
	-- meaningful, "3.2 studs from the root part to the floor" is not, and every threshold in
	-- ParkourConstants is written in the former terms.
	local distance = math.max(result.Distance - footOffset, 0)
	local slopeAngle = ParkourMath.SlopeAngle(result.Normal)
	local permissions = ParkourTagging.GetPermissions(result.Instance, now)

	ground.Distance = distance
	ground.Normal = result.Normal
	ground.SlopeAngle = slopeAngle
	ground.Standable = slopeAngle <= SLOPE.MaxWalkableAngleDegrees
	ground.Material = result.Material
	ground.Instance = result.Instance
	ground.FrictionScale = permissions.FrictionScale
	-- GROUNDED MEANS "TOUCHING A FLOOR", NOT "TOUCHING A FLOOR I COULD STAND ON". These used to be
	-- the same test, and that quietly made the steep-slope slide unreachable: on anything past
	-- MaxWalkableAngleDegrees the character was reported airborne, so States/Sliding.lua's first check
	-- handed straight off to Falling and the forced slide -- the entire feature for surfaces too steep
	-- to stand on -- could never run on the surfaces it exists for. `Standable` is still measured and
	-- still published (the debug overlay shows it, and it is the honest answer to "could this character
	-- stand here"); it simply is not part of whether the feet are touching something. The forced slide
	-- itself keys off SlopeAngle against Slope.ForcedSlideAngleDegrees directly -- a deliberately lower
	-- threshold than MaxWalkableAngleDegrees, so a slope starts taking you before it becomes literally
	-- unstandable.
	ground.Grounded = distance <= SLOPE.GroundedDistance
	ground.NearGround = distance <= SLOPE.GroundProbeDistance
end

--
-- Obstacle
--

local function clearObstacle(now: number): ()
	obstacle.SampledAt = now
	obstacle.Found = false
	obstacle.Distance = math.huge
	obstacle.Height = 0
	obstacle.Depth = math.huge
	obstacle.HasLandingSpace = false
	obstacle.HasStandingSpace = false
	obstacle.Instance = nil
	obstacle.VaultAllowed = true
	obstacle.MantleAllowed = true
end

-- Measures whatever is directly ahead along `travelDirection`. See the file header for the ray
-- layout; the sequence below is written so that every early exit leaves `obstacle` in a coherent
-- "nothing usable there" state rather than a half-filled one.
local function probeObstacle(rootPart: BasePart, travelDirection: Vector3, speed: number, now: number): ()
	local flatTravel = ParkourMath.Flatten(travelDirection)
	if flatTravel.Magnitude < ParkourConstants.Locomotion.InputMagnitudeThreshold then
		clearObstacle(now)
		return
	end
	local forward = flatTravel.Unit
	local footPosition = rootPart.Position - Vector3.new(0, footOffset, 0)

	-- Reach grows with speed: at a sprint the character covers more ground per frame and needs the
	-- vault decision made further out for the traversal to start before the near face is already past.
	local reach = math.clamp(
		OBSTACLE.ProbeDistance + speed * OBSTACLE.ProbeDistanceSpeedScale,
		OBSTACLE.ProbeDistance,
		OBSTACLE.ProbeMaxDistance
	)

	-- Two forward rays rather than one: a low one at shin height catches solid obstacles, and a
	-- fallback at waist height catches anything with a gap underneath (a railing, a table, a
	-- balcony lip) that the low ray would sail straight under and report as clear road.
	local lowOrigin = footPosition + UP * (OBSTACLE.StepMaxHeight * 0.5)
	local hit = castRay(lowOrigin, forward * reach)
	if not hit then
		local midOrigin = footPosition + UP * (OBSTACLE.HopMaxHeight * 0.85)
		hit = castRay(midOrigin, forward * reach)
	end
	if not hit then
		clearObstacle(now)
		return
	end

	local permissions = ParkourTagging.GetPermissions(hit.Instance, now)
	if permissions.Ignored then
		clearObstacle(now)
		return
	end

	local nearFace = hit.Position
	local horizontalDistance = ParkourMath.Flatten(nearFace - rootPart.Position).Magnitude

	-- Top finder: straight down from above the tallest thing this system cares about, nudged just
	-- past the near face so it lands ON the obstacle rather than skimming its front edge.
	local topScanHeight = OBSTACLE.MantleMaxHeight + 1.5
	local topOrigin = Vector3.new(nearFace.X, footPosition.Y + topScanHeight, nearFace.Z) + forward * 0.35
	local topHit = castRay(topOrigin, Vector3.new(0, -(topScanHeight + 1), 0))

	obstacle.SampledAt = now
	obstacle.Found = true
	obstacle.Distance = horizontalDistance
	obstacle.Normal = hit.Normal
	obstacle.Instance = hit.Instance
	obstacle.VaultAllowed = permissions.Vaultable
	obstacle.MantleAllowed = permissions.Mantleable

	if not topHit then
		-- No top surface inside the scan: either taller than anything traversable, or the scan was
		-- refused on budget. Both mean "do not traverse this," which math.huge expresses without the
		-- classifier needing a separate unknown-height case.
		obstacle.Height = math.huge
		obstacle.Depth = math.huge
		obstacle.TopPosition = nearFace
		obstacle.HasLandingSpace = false
		obstacle.HasStandingSpace = false
		return
	end

	obstacle.TopPosition = topHit.Position
	obstacle.Height = topHit.Position.Y - footPosition.Y

	-- Far-side probe: one downward ray past the maximum vaultable depth. Where it lands answers both
	-- remaining questions at once -- if it lands at roughly the obstacle's own top height the surface
	-- is still continuing (too deep to vault, so this is a mantle target); if it lands lower, there is
	-- a far edge inside the vaultable band and a floor to land on.
	local farPoint = nearFace + forward * (OBSTACLE.VaultMaxDepth + 0.5)
	local farOrigin = Vector3.new(farPoint.X, footPosition.Y + topScanHeight, farPoint.Z)
	local farHit = castRay(farOrigin, Vector3.new(0, -(topScanHeight + OBSTACLE.LandingClearanceHeight), 0))

	if farHit and farHit.Position.Y >= topHit.Position.Y - 0.5 then
		obstacle.Depth = math.huge
		obstacle.HasLandingSpace = false
	elseif farHit then
		obstacle.Depth = OBSTACLE.VaultMaxDepth
		-- Landing headroom: a floor on the far side is only useful if the character actually fits
		-- above it. Without this a vault over a wall into a crawlspace drops the character inside
		-- geometry.
		local headroom = castRay(farHit.Position + UP * 0.2, UP * OBSTACLE.LandingClearanceHeight)
		obstacle.HasLandingSpace = headroom == nil
	else
		-- Nothing at all on the far side within the probe's reach: a drop rather than a floor. Still
		-- vaultable -- vaulting a railing over a drop is a legitimate (and good) thing to do -- and
		-- States/Falling.lua takes over on the way down.
		obstacle.Depth = OBSTACLE.VaultMaxDepth
		obstacle.HasLandingSpace = true
	end

	-- Standing space on top, for the mantle decision.
	local standCheck = castRay(topHit.Position + UP * 0.3, UP * OBSTACLE.StandClearanceHeight)
	obstacle.HasStandingSpace = standCheck == nil
end

--
-- Walls
--

local function clearWall(probe: WallProbe, now: number): ()
	probe.SampledAt = now
	probe.Found = false
	probe.Distance = math.huge
	probe.Tangent = Vector3.zero
	probe.TiltAngle = 90
	probe.Instance = nil
	probe.WallRunAllowed = true
	probe.BounceScale = 1
end

local function probeWall(
	probe: WallProbe,
	rootPart: BasePart,
	sideDirection: Vector3,
	travelDirection: Vector3,
	now: number
): ()
	local hit = castRay(rootPart.Position, sideDirection * WALLRUN.ProbeDistance)
	if not hit then
		clearWall(probe, now)
		return
	end

	local permissions = ParkourTagging.GetPermissions(hit.Instance, now)
	if permissions.Ignored or not permissions.WallRunnable then
		clearWall(probe, now)
		-- Preserved rather than reset to the permissive default: a state that reads WallRunAllowed
		-- to explain a refusal (and the debug overlay, which shows exactly that) needs to be able to
		-- distinguish "no wall here" from "a wall the designer marked unusable."
		probe.WallRunAllowed = false
		probe.Instance = hit.Instance
		return
	end

	probe.SampledAt = now
	probe.Found = true
	probe.Distance = hit.Distance
	probe.Normal = hit.Normal
	probe.TiltAngle = ParkourMath.SurfaceTilt(hit.Normal)
	probe.Tangent = ParkourMath.WallTangent(hit.Normal, travelDirection)
	probe.Instance = hit.Instance
	-- A force-allow tag overrides the tilt check the wall-run state would otherwise apply -- reported
	-- by zeroing the measured tilt, so the state's own threshold comparison passes without the state
	-- needing to know tags exist.
	probe.WallRunAllowed = true
	if permissions.ForcedWallRun then
		probe.TiltAngle = 0
	end
	probe.BounceScale = permissions.BounceScale
end

--
-- Ledge
--

local function clearLedge(now: number): ()
	ledge.SampledAt = now
	ledge.Found = false
	ledge.HasStandingSpace = false
	ledge.HasHangSpace = false
	ledge.Instance = nil
	ledge.Allowed = true
end

-- One direction's worth of the ledge search: find a wall face along `forward`, find the lip above
-- that face, and check the lip sits inside the (sweep-widened) grab band. Fills `ledge` and returns
-- true on success; on failure it leaves `ledge` untouched so the caller can try another direction
-- without having to save and restore anything, and returns the part that refused on permissions --
-- if any -- so the caller can report WHY nothing was grabbable rather than just that nothing was.
local function tryLedgeDirection(
	headPosition: Vector3,
	forward: Vector3,
	sweep: number,
	now: number
): (boolean, BasePart?)
	-- RAY FIRST, SPHERE SECOND, and the order is load-bearing rather than an optimization.
	--
	-- A spherecast whose sphere is ALREADY overlapping geometry at its origin returns nil, not a
	-- distance-zero hit (asserted against the real engine in Tests/Parkour/LedgeProbeGeometry.spec).
	-- The head is a Ledge.GrabProbeRadius-wide sphere's worth of clearance away from a wall the
	-- character is pressed against, so sphere-first would report open air in exactly the situation the
	-- old single ray handled perfectly: hugging the face. Leading with the ray keeps that case exact and
	-- keeps the common "wall straight ahead" grab at its original one-cast cost; the sphere is then
	-- purely additive, spent only when the narrow instrument found nothing usable.
	--
	-- "Nothing usable" includes a hit too far off vertical to be a FACE -- a ray that skims over the lip
	-- and lands on a sloped roof behind it, say. Such a normal has no meaningful horizontal component,
	-- and ParkourMath.HangPosition backs the pose off ALONG that component, so accepting it places the
	-- character inside the wall they meant to hang on rather than off its face.
	local faceHit = castRay(headPosition, forward * LEDGE.GrabReachDistance)
	if not faceHit or ParkourMath.SurfaceTilt(faceHit.Normal) > LEDGE.MaxFaceTiltDegrees then
		faceHit = castSphere(headPosition, LEDGE.GrabProbeRadius, forward * LEDGE.GrabReachDistance)
	end
	if not faceHit or ParkourMath.SurfaceTilt(faceHit.Normal) > LEDGE.MaxFaceTiltDegrees then
		return false, nil
	end

	local permissions = ParkourTagging.GetPermissions(faceHit.Instance, now)
	if permissions.Ignored or not permissions.LedgeGrabbable then
		return false, faceHit.Instance
	end

	-- The lip: scan down from above the head band, just past the wall face. Both the top of the scan
	-- and the band it is measured against are stretched upward by `sweep` -- see probeLedge below.
	local scanTop = headPosition.Y + LEDGE.GrabBandAboveHead + sweep
	local scanOrigin = Vector3.new(faceHit.Position.X, scanTop, faceHit.Position.Z) + forward * 0.3
	local scanLength = LEDGE.GrabBandAboveHead + sweep + LEDGE.GrabBandBelowHead
	local lipHit = castRay(scanOrigin, Vector3.new(0, -scanLength, 0))
	if not lipHit then
		return false, nil
	end

	-- The lip must genuinely be an EDGE within the grab band, not the top of something far below or
	-- a ceiling far above -- both of which the scan can legitimately land on.
	local relativeHeight = lipHit.Position.Y - headPosition.Y
	if relativeHeight > LEDGE.GrabBandAboveHead + sweep or relativeHeight < -LEDGE.GrabBandBelowHead then
		return false, nil
	end

	local standCheck = castRay(lipHit.Position + UP * 0.3, UP * LEDGE.StandClearanceHeight)

	-- Room to hang, measured at the pose the hang will ACTUALLY use (hence the shared
	-- ParkourMath.HangPosition rather than an approximation): straight down from the hanging root for
	-- the rig's own root-to-sole distance plus a little air. A hit means the character's feet would be
	-- in the floor, which is not a hang -- see Ledge.HangFootClearance for the failure that produced.
	-- Nothing found is the common and correct case: a real ledge has open air under it.
	local hangPosition =
		ParkourMath.HangPosition(lipHit.Position, faceHit.Normal, LEDGE.HangVerticalOffset, LEDGE.HangHorizontalOffset)
	local hangCheck = castRay(hangPosition, Vector3.new(0, -(footOffset + LEDGE.HangFootClearance), 0))

	ledge.SampledAt = now
	ledge.Found = true
	ledge.EdgePosition = lipHit.Position
	ledge.WallNormal = faceHit.Normal
	ledge.HasStandingSpace = standCheck == nil
	ledge.HasHangSpace = hangCheck == nil
	ledge.Instance = lipHit.Instance
	ledge.Allowed = true
	return true, nil
end

-- Finds a grabbable edge ahead of an airborne character: a wall face within reach, whose top edge
-- sits inside a band around head height.
--
-- TWO THINGS MAKE THIS DIFFERENT FROM A SINGLE FORWARD PROBE, and both exist because the naive
-- version fails on grabs the player is certain they made:
--
--   * THE BAND IS SWEPT, not static. A static 4.2-stud window is stepped straight over by a fast
--     fall: at 90 studs/s and 45fps the head moves 2 studs a frame, and the lip that was above the
--     band on one sample is below it on the next. Stretching the top of the band by the distance
--     covered since the last sample asks the honest question -- "was this edge inside the band at any
--     point during the interval" -- instead of sampling a continuous fall at discrete points and
--     calling the gaps absence. The stretch is upward only: an edge that has already passed BELOW the
--     band was offered on an earlier frame and declined by geometry, not missed.
--
--   * IT SEARCHES UP TO TWO DIRECTIONS. Travel first, because that is where the body is going and it
--     is the direction a wall-jump departure or an arcing fall wants measured. Facing second, and only
--     when the two have genuinely diverged, because that is where the PLAYER is reaching -- strafing
--     sideways along a face while looking at it (shift lock, or any state that has taken AutoRotate)
--     points travel along the wall and facing at it, and travel-only reports open air the whole way
--     past a ledge the player is staring straight at.
local function probeLedge(rootPart: BasePart, travelDirection: Vector3, verticalSpeed: number, now: number): ()
	local headPosition = rootPart.Position + UP * (rootPart.Size.Y * 0.5)

	-- Measured against the last time this probe looked (which clearLedge stamps too, so it is a real
	-- "time since we last knew" rather than only a frame time) and clamped at both ends: the floor is
	-- there so a first sample after a long gap does not sweep the whole map, the ceiling is
	-- Ledge.GrabSweepMaxStuds' own reasoning about what still reads as catching yourself.
	local sinceLastSample = if ledge.SampledAt > 0 then math.clamp(now - ledge.SampledAt, 0, 0.1) else 0
	local sweep = math.clamp(math.max(-verticalSpeed, 0) * sinceLastSample, 0, LEDGE.GrabSweepMaxStuds)

	local facing = ParkourMath.SafeUnit(ParkourMath.Flatten(rootPart.CFrame.LookVector), Vector3.zero)
	local travel = ParkourMath.SafeUnit(ParkourMath.Flatten(travelDirection), Vector3.zero)
	local primary = if travel.Magnitude > 0 then travel else facing
	if primary.Magnitude < 1e-3 then
		clearLedge(now)
		return
	end

	local found, refusedInstance = tryLedgeDirection(headPosition, primary, sweep, now)
	if
		not found
		and facing.Magnitude > 0
		and ParkourMath.ApproachAngle(primary, facing) > LEDGE.GrabDirectionSplitDegrees
	then
		local facingFound, facingRefused = tryLedgeDirection(headPosition, facing, sweep, now)
		found = facingFound
		refusedInstance = refusedInstance or facingRefused
	end
	if found then
		return
	end

	clearLedge(now)
	if refusedInstance then
		-- Preserved rather than reset to the permissive default, same as probeWall's own refusal path: a
		-- state explaining why it will not grab, and the debug overlay showing that explanation, need
		-- "an edge the designer marked unusable" to be distinguishable from "no edge here."
		ledge.Allowed = false
		ledge.Instance = refusedInstance
	end
end

--
-- Ceiling
--

local function probeCeiling(rootPart: BasePart, now: number): ()
	ceilingSampledAt = now
	local origin = rootPart.Position + UP * (rootPart.Size.Y * 0.5)
	-- Reach is the crouch depth a slide recovers through -- the question is specifically "if I stood
	-- up right now, would my head be inside something," not "is there a roof somewhere above me."
	local hit = castRay(origin, UP * (ParkourConstants.Slide.HipHeightDelta + 0.6))
	ceilingClear = hit == nil
end

--
-- Update
--

-- Runs the probes for this frame and writes them onto `context`. `request` is the active state's
-- own ParkourTypes.ProbeRequest -- anything it names is refreshed unconditionally, everything else
-- obeys its cache interval and the idle skip.
--
-- Order is the degradation order under budget pressure: ground first (everything depends on it),
-- then the probes the active state actually declared, then the speculative ones that only feed
-- pre-emption. A frame that runs out of budget therefore loses the ability to notice a NEW
-- opportunity before it loses the ability to correctly continue what it is already doing.
function EnvironmentProbe.Update(context: ParkourContext, request: ProbeRequest): ()
	rayBudgetUsed = 0
	local now = context.Now
	local rootPart = context.RootPart

	if not isCacheFresh(ground.SampledAt, PROBE.GroundIntervalSeconds, now, request.Ground ~= false) then
		probeGround(rootPart, now)
	end
	context.Ground = ground

	-- Direction the character is actually heading. Falls back to facing when there is no meaningful
	-- movement, so a player walking slowly into a wall still gets it measured.
	local travelDirection = ParkourMath.Flatten(context.MoveDirection)
	if travelDirection.Magnitude < 1e-3 then
		travelDirection = ParkourMath.Flatten(rootPart.CFrame.LookVector)
	end
	local tooSlowToCare = context.PlanarSpeed < PROBE.IdleSkipSpeed and context.MoveIntent.Magnitude < 1e-3

	local wantObstacle = request.Obstacle == true
	if
		(wantObstacle or not tooSlowToCare)
		and not isCacheFresh(obstacle.SampledAt, PROBE.ObstacleIntervalSeconds, now, wantObstacle)
	then
		probeObstacle(rootPart, travelDirection, context.PlanarSpeed, now)
	elseif tooSlowToCare and not wantObstacle then
		-- Standing still: nothing can be vaulted, and leaving a stale hit cached would let a
		-- pre-emption fire off information from before the player stopped.
		clearObstacle(now)
	end
	context.Obstacle = obstacle

	local wantWalls = request.Walls == true
	if
		(wantWalls or not tooSlowToCare)
		and not isCacheFresh(wallLeft.SampledAt, PROBE.WallIntervalSeconds, now, wantWalls)
	then
		local right = ParkourMath.Flatten(rootPart.CFrame.RightVector)
		right = ParkourMath.SafeUnit(right, Vector3.new(1, 0, 0))
		probeWall(wallLeft, rootPart, -right, travelDirection, now)
		probeWall(wallRight, rootPart, right, travelDirection, now)
	elseif tooSlowToCare and not wantWalls then
		clearWall(wallLeft, now)
		clearWall(wallRight, now)
	end
	context.WallLeft = wallLeft
	context.WallRight = wallRight

	local wantLedge = request.Ledge == true
	-- Ledges are only meaningful while airborne, so this probe is skipped outright on the ground --
	-- the single largest saving in the whole schedule, since most frames are grounded frames.
	if
		(wantLedge or not ground.Grounded)
		and not isCacheFresh(ledge.SampledAt, PROBE.LedgeIntervalSeconds, now, wantLedge)
	then
		if ground.Grounded and not wantLedge then
			clearLedge(now)
		else
			probeLedge(rootPart, travelDirection, context.VerticalVelocity, now)
		end
	elseif ground.Grounded and not wantLedge then
		clearLedge(now)
	end
	context.Ledge = ledge

	local wantCeiling = request.Ceiling == true
	if wantCeiling and not isCacheFresh(ceilingSampledAt, PROBE.CeilingIntervalSeconds, now, true) then
		probeCeiling(rootPart, now)
	elseif not wantCeiling then
		-- Nothing is asking, so nothing is overhead as far as the framework is concerned. Reset
		-- rather than leaving a stale `false` that would keep a finished slide crouched forever.
		ceilingClear = true
	end
	context.CeilingClear = ceilingClear
end

-- How many casts the last Update actually made -- read by ParkourDebug.lua's readout so the ray
-- budget is observable rather than a number to be taken on faith.
function EnvironmentProbe.GetLastRayCount(): number
	return rayBudgetUsed
end

-- The live result tables, for the debug overlay to draw. Returned by reference on purpose (drawing
-- them must not copy six tables every readout) under the same read-immediately contract as every
-- other consumer.
function EnvironmentProbe.GetResults(): (GroundProbe, ObstacleProbe, WallProbe, WallProbe, LedgeProbe)
	return ground, obstacle, wallLeft, wallRight, ledge
end

function EnvironmentProbe.GetFootOffset(): number
	return footOffset
end

function EnvironmentProbe.GetBoundCharacter(): Model?
	return boundCharacter
end

return EnvironmentProbe
