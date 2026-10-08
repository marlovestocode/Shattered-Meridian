--!strict
--[[
	EnvironmentProbe.lua

	Owns: every raycast and spatial query the parkour framework makes, and the per-frame budget that
	keeps them affordable. Fills the ParkourContext's Ground/Obstacle/WallLeft/WallRight/Ledge/
	CeilingClear fields; nothing else in the framework is allowed to cast a ray.

	FOUR DESIGN DECISIONS THAT ARE THE WHOLE POINT OF THIS FILE:

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

	4. SURFACES, NOT PARTS. A mountain is a pile of overlapping, near-touching parts, and "the nearest hit of
	   one ray" moves between them as the character moves a fraction of a stud: a part barely poking out of
	   the real face, or buried in it, won samples and seated the character in it, and two parts a hair
	   apart took turns. So the wall probes, the ledge candidate and the mantle top describe a PLANE
	   (Shared/Parkour/SurfaceLock.lua; every number is ParkourConstants.Surface), with the part as a mere
	   label on it: a held plane is confirmed by the one centre ray, anything else is cross-checked by a few
	   more rays whose majority decides, a challenger must be clearly better to replace what is held, and
	   the geometry a pose would occupy (a hang's body, a mantle's end footprint) is checked as well as the
	   surface it attaches to. The extra rays are VALIDATION casts, on their own sub-budget
	   (Probe.MaxValidationRaysPerFrame) and mostly spent on the frame a surface is first seen.
	   Surface.Enabled = false restores the raw nearest-hit behavior exactly.

	Every result table is persistent and mutated in place -- see the RESULT TABLES block below. This
	module allocates no tables and no Vector3s per frame beyond what the engine's own Raycast returns.

	Does not own: interpreting what it finds (Shared/Parkour/ObstacleClassifier.lua and the State
	modules), designer tag overrides (Shared/Parkour/ParkourTagging.lua supplies those and this module
	simply stamps them onto the results), or drawing any of it (Client/Parkour/ParkourDebug.lua reads
	these same results).
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)
local SurfaceLock = require(ReplicatedStorage.Shared.Parkour.SurfaceLock)
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
local SURFACE = ParkourConstants.Surface

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
	TravelDirection = Vector3.zero,
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
		Position = Vector3.zero,
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
-- SURFACE STABILITY STATE -- the memory the probes did not used to have. See Shared/Parkour/SurfaceLock.lua
-- for what a lock IS and ParkourConstants.Surface for every number; this file only owns WHERE the rays go.
--
-- One lock per wall side, because the two sides hold two unrelated surfaces. The sample sets and the vote
-- result are shared scratch: each probe fills a set, votes, and reads the answer before returning, so
-- nothing is ever retained across calls -- the same read-immediately contract the result tables above use.
--
local wallLockLeft = SurfaceLock.NewLock()
local wallLockRight = SurfaceLock.NewLock()
local WALL_CLUSTER_RAYS = 4
local wallSamples = SurfaceLock.NewSampleSet(WALL_CLUSTER_RAYS + 1)
local wallConsensus = SurfaceLock.NewConsensus()
-- The ledge candidate's cross-check: a face and a lip sample from the centre of the grab plus one either side
-- along the wall (Ledge.ConsensusSpreadStuds). Two sets and two results because the face and the lip are
-- voted on separately and both answers are needed at once.
local LEDGE_SIDE_RAYS = 4
local LEDGE_BODY_RAYS = 3
local ledgeFaceSamples = SurfaceLock.NewSampleSet(3)
local ledgeLipSamples = SurfaceLock.NewSampleSet(3)
local ledgeFaceConsensus = SurfaceLock.NewConsensus()
local ledgeLipConsensus = SurfaceLock.NewConsensus()
-- The mantle target's TOP, held like a wall is. Steady state is the old single downward ray: the held top is
-- confirmed by the centre ray alone, and the two side scans are only paid when the centre ray lands somewhere
-- the held top is not.
local OBSTACLE_TOP_SIDE_RAYS = 2
local OBSTACLE_STAND_RAYS = 4
local obstacleTopLock = SurfaceLock.NewLock()
-- The top is held under the same rules as a wall EXCEPT the switch cooldown. A wall can afford to be loyal for
-- a tenth of a second after a switch (it only delays noticing a block that juts out); a top cannot, because
-- the mantle derives where the character ENDS from it, and a stale lower top while a higher one is ahead is a
-- pull-up that finishes inside the block. The hysteresis bands still apply -- only the backstop is dropped.
local TOP_SURFACE: SurfaceLock.Config = table.clone(SURFACE)
TOP_SURFACE.SwitchCooldownSeconds = 0
local obstacleTopSamples = SurfaceLock.NewSampleSet(OBSTACLE_TOP_SIDE_RAYS + 1)
local obstacleTopConsensus = SurfaceLock.NewConsensus()

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

-- Reused exclude list handed to the RaycastParams below -- the bound character plus every OTHER
-- player's character. Rebuilt only when the roster changes (see watchPlayers), never per frame.
local excludeList: { Instance } = {}

-- PEOPLE ARE NOT TERRAIN. This filter used to contain the local character alone, which meant every
-- other player in the server was fully solid parkour geometry: you could ledge-hang off someone's
-- shoulder, mantle them, vault them, and wall-run along a line of them. A post-hit rejection cannot
-- fix that on its own, either -- a body standing between the probe and a real wall STOPS the ray, so
-- discarding the hit afterwards would just blind the probe to the wall behind them. The bodies have
-- to be invisible to the cast itself, which is what this list is for.
--
-- ParkourTagging treats anything inside a Humanoid-bearing Model as Ignored as well, and the two are
-- not redundant: this list covers real Players (whose characters are the common case and whose
-- lifecycle Players gives us events for), while the tagging check catches every other body -- training
-- bots, dummies, NPCs -- with no roster to maintain. Belt and braces, cheap in both directions.
local function rebuildExcludeList(): ()
	table.clear(excludeList)
	if boundCharacter then
		table.insert(excludeList, boundCharacter)
	end
	for _, player in Players:GetPlayers() do
		local otherCharacter = player.Character
		-- The local player's own character is already in via boundCharacter above; adding it twice is
		-- harmless but pointless, and skipping it keeps the list's length honest.
		if otherCharacter and otherCharacter ~= boundCharacter then
			table.insert(excludeList, otherCharacter)
		end
	end
	local params = raycastParams
	if params then
		-- Reassigned rather than mutated in place: FilterDescendantsInstances returns a COPY, so
		-- table.insert-ing into the property's value does nothing at all. This is the one place the
		-- list actually reaches the engine.
		params.FilterDescendantsInstances = excludeList
	end
end

-- Rebuilds the shared RaycastParams for a freshly-spawned character. RespectCanCollide is the load-
-- bearing setting here: every FX part this codebase spawns (MovementVFX dust carriers, HitFlash
-- highlights, FlightVFX rings, this feature's own debug adorns) is CanCollide = false, so honoring
-- collidability means none of them can ever be mistaken for vaultable geometry without maintaining a
-- filter list that would need updating every time a new effect is added.
local function rebuildParams(): ()
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	params.RespectCanCollide = true
	if PROBE.CollisionGroup ~= "" then
		params.CollisionGroup = PROBE.CollisionGroup
	end
	raycastParams = params
	rebuildExcludeList()
end

-- Keeps the exclude list current as players join, leave and respawn. Connected exactly once, from
-- Start below -- a per-frame rebuild would allocate and re-walk the roster for an answer that changes
-- a handful of times per session, and a bind-time-only build would go stale the moment anyone else
-- respawned (leaving their OLD character excluded and their new one solid).
-- Connections are deliberately not retained. Every one of them is on Players or on a Player, both of
-- which outlive this module for the whole session, and nothing here ever disconnects -- the watch is
-- module-lifetime by design (see BindCharacter's own note on why it is connected once and never torn
-- down with the character). Holding them in a table would be a list nothing ever reads.
local playersWatched = false

-- NOT Shared/PlayerLifecycle.lua: this watches EVERY player's character, including other people's,
-- and what it wants from each is the Model's existence rather than a bound Humanoid -- the exclude
-- list has to be correct the instant a body appears, not once its Humanoid has replicated. That
-- binder is for "the local player's successive characters" and for per-player scopes; a roster watch
-- is a different shape wearing similar words.
local function watchPlayer(player: Player): ()
	player.CharacterAdded:Connect(rebuildExcludeList)
	player.CharacterRemoving:Connect(rebuildExcludeList)
	rebuildExcludeList()
end

local function watchPlayers(): ()
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
	Players.PlayerAdded:Connect(watchPlayer)
	Players.PlayerRemoving:Connect(rebuildExcludeList)
end

-- Binds a character and clears every cached result. Called from ParkourController's own character
-- bind path; safe to call repeatedly.
function EnvironmentProbe.BindCharacter(character: Model, humanoid: Humanoid, rootPart: BasePart): ()
	-- The roster watch is connected once, lazily, on the first bind -- module lifetime, not character
	-- lifetime, which is why it is not in the reset block below and why Unbind leaves it alone. Done
	-- here rather than through a new public Start() so ParkourController's boot path is unchanged.
	if not playersWatched then
		playersWatched = true
		watchPlayers()
	end
	boundCharacter = character
	rebuildParams()
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
	-- A held surface belongs to the body that was touching it. A respawn carrying one over would merge the
	-- new character's first contact into a wall the old one died against.
	SurfaceLock.Reset(wallLockLeft)
	SurfaceLock.Reset(wallLockRight)
	SurfaceLock.Reset(obstacleTopLock)
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

-- The VALIDATION cast: the extra rays that confirm a candidate surface is real geometry before anything
-- attaches to it (ParkourConstants.Surface). Counts against the frame ceiling like every other cast AND
-- against its own slice of it, Probe.MaxValidationRaysPerFrame -- see that constant for why it is a
-- sub-budget. A refusal returns nil exactly like castRay's, and every caller therefore asks
-- validationAvailable for its whole cluster first: a vote taken over a cluster that was cut off halfway
-- would be a vote with the wrong electorate.
local validationUsed = 0

local function validationAvailable(count: number): boolean
	return validationUsed + count <= PROBE.MaxValidationRaysPerFrame and rayBudgetUsed + count <= PROBE.MaxRaysPerFrame
end

local function castValidationRay(origin: Vector3, direction: Vector3): RaycastResult?
	local params = raycastParams
	if not params then
		return nil
	end
	if not validationAvailable(1) then
		return nil
	end
	rayBudgetUsed += 1
	validationUsed += 1
	return Workspace:Raycast(origin, direction, params)
end

-- Whether a hit is geometry at all, for the purposes of a vote. A tag that marks a part Ignored removes it
-- from the world as far as the framework is concerned, so it must not be a witness either; a part that is
-- merely not wall-runnable IS still a surface, and voting for it is exactly how a sliver of one is outvoted
-- by the wall behind it.
local function isVotingHit(hit: RaycastResult, now: number): boolean
	return not ParkourTagging.GetPermissions(hit.Instance, now).Ignored
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

-- The EVENT cast: same params and same tables, a different budget. Used only by the two one-shot scans
-- at the bottom of this file (the wall-jump target fan and the ledge-climb surface ladder), which run
-- at the instant a discrete action begins rather than every frame.
--
-- Why it does not simply use castRay: those scans arrive at the WORST possible moment for the per-frame
-- budget. A wall-jump happens on a frame that has already spent its ground, wall and ledge casts, so a
-- fan sharing MaxRaysPerFrame would be refused outright exactly when it is needed and the assist would
-- appear to work only when the player was doing nothing else. The costs are also genuinely different in
-- kind -- see Probe.MaxScanRaysPerEvent's own header.
--
-- It still ADDS to rayBudgetUsed, so the per-frame probes that run after a scan degrade to cached
-- results for that one frame rather than the scan being pretended free.
local scanBudgetUsed = 0

local function castScanRay(origin: Vector3, direction: Vector3): RaycastResult?
	local params = raycastParams
	if not params then
		return nil
	end
	if scanBudgetUsed >= PROBE.MaxScanRaysPerEvent then
		return nil
	end
	scanBudgetUsed += 1
	rayBudgetUsed += 1
	return Workspace:Raycast(origin, direction, params)
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
	obstacle.TravelDirection = Vector3.zero
	obstacle.HasLandingSpace = false
	obstacle.HasStandingSpace = false
	obstacle.Instance = nil
	obstacle.VaultAllowed = true
	obstacle.MantleAllowed = true
end

-- THE MANTLE TARGET'S TOP, as a plane. The top finder is one downward ray just past the near face, so a
-- sliver of a part standing a little proud of the real top -- or the gap between two blocks -- used to decide
-- the mantle height and with it where the character is pulled to. Returns the top's contact point, or nil
-- when the ray's hit cannot be trusted this frame (never when it can).
--
-- Same shape as probeWall: a centre ray that lands on the held top needs nothing more (one cast, as before);
-- anything else is checked by a scan either side along the face, the plane most of the three agree on is the
-- candidate, and the lock's hysteresis decides whether it replaces the held top. A genuinely rough top whose
-- three scans all disagree is NOT refused -- the centre ray's answer stands, because "this ledge is bumpy" is
-- not a reason to take the mantle away -- and neither is a refusal on budget; both only mean no extra
-- confidence this frame.
local function resolveObstacleTop(
	topHit: RaycastResult,
	topOrigin: Vector3,
	topDown: Vector3,
	forward: Vector3,
	now: number
): Vector3
	-- Vaulting and mantling are decisions a GROUNDED character makes (ObstacleClassifier answers "Airborne"
	-- otherwise), and States/Falling and Jumping force this probe every frame for other reasons -- so an
	-- airborne frame takes the raw top, spends nothing, and drops any held one rather than let it go stale.
	if not SURFACE.Enabled or not ground.Grounded then
		SurfaceLock.Reset(obstacleTopLock)
		return topHit.Position
	end
	local candidate: SurfaceLock.Candidate = topHit
	if
		not SurfaceLock.Matches(obstacleTopLock, topHit.Position, topHit.Normal, now, TOP_SURFACE)
		and validationAvailable(OBSTACLE_TOP_SIDE_RAYS)
	then
		SurfaceLock.Clear(obstacleTopSamples)
		SurfaceLock.Add(obstacleTopSamples, topHit.Position, topHit.Normal, topHit.Instance, topHit.Distance)
		local lateral = ParkourMath.SafeUnit(UP:Cross(forward), Vector3.zero)
		for side = -1, 1, 2 do
			local sideHit = castValidationRay(topOrigin + lateral * (side * OBSTACLE.TopConsensusSpreadStuds), topDown)
			if sideHit and isVotingHit(sideHit, now) then
				SurfaceLock.Add(
					obstacleTopSamples,
					sideHit.Position,
					sideHit.Normal,
					sideHit.Instance,
					sideHit.Distance
				)
			end
		end
		if
			obstacleTopSamples.Count > 1
			and SurfaceLock.Vote(obstacleTopSamples, obstacleTopConsensus, SURFACE.Consensus)
		then
			candidate = obstacleTopConsensus
		end
	end
	SurfaceLock.Observe(obstacleTopLock, candidate, topDown, now, TOP_SURFACE)
	-- The held plane's contact point sits where the centre ray's column crosses it, so the height reported is
	-- the held top's even when the centre ray itself hit a bump on it. Horizontal position is the ray's own:
	-- the mantle path is pulled toward this point and it should stay where the player is heading.
	local held = SurfaceLock.Distance(obstacleTopLock, topOrigin, topDown, topHit.Distance)
	return topOrigin + topDown.Unit * held
end

-- Whether the spot a mantle ENDS on is free of props. The pull-up finishes with the character standing a
-- short step in from the edge (States/Mantling's EndPosition), and the old gate asked about headroom at the
-- edge only, so a rock, rail or lamp post standing on the top a step further in was invisible and the
-- mantle ended inside it. Columns down the body's height over the end footprint -- centre and either side --
-- plus one forward cast at chest height across the gap from the edge to it.
--
-- StepToleranceStuds keeps the column bottoms above the surface, so a rough top is walked on rather than
-- refused, and a refusal on budget answers "not clear": declining a mantle for a frame is safe, ending one
-- inside a prop is not.
local function mantleFootprintClear(topPosition: Vector3, forward: Vector3, now: number): boolean
	local CLEAR = OBSTACLE.StandClearance
	if not validationAvailable(OBSTACLE_STAND_RAYS) then
		return false
	end
	local lateral = ParkourMath.SafeUnit(UP:Cross(forward), Vector3.zero)
	-- 1.1 is States/Mantling's own EndPosition step, which has no constant of its own to read.
	local footprint = topPosition + forward * 1.1
	local columnTop = footprint + UP * CLEAR.BodyHeightStuds
	local column = Vector3.new(0, -(CLEAR.BodyHeightStuds - CLEAR.StepToleranceStuds), 0)
	for index = 1, 3 do
		local offset = if index == 1
			then Vector3.zero
			elseif index == 2 then lateral * CLEAR.HalfWidthStuds
			else lateral * -CLEAR.HalfWidthStuds
		local hit = castValidationRay(columnTop + offset, column)
		if hit and isVotingHit(hit, now) then
			return false
		end
	end
	local chest = topPosition + UP * CLEAR.ChestHeightStuds
	local across = castValidationRay(chest, forward * 1.1)
	return not (across and isVotingHit(across, now))
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
	local topDown = Vector3.new(0, -(topScanHeight + 1), 0)
	local topHit = castRay(topOrigin, topDown)
	-- The top as a held PLANE rather than the raw hit of one ray: see resolveObstacleTop. Nil when there is no
	-- top at all, exactly as topHit is.
	local topPosition: Vector3? = nil
	if topHit then
		topPosition = resolveObstacleTop(topHit, topOrigin, topDown, forward, now)
	else
		SurfaceLock.Observe(obstacleTopLock, nil, topDown, now, TOP_SURFACE)
	end

	obstacle.SampledAt = now
	obstacle.Found = true
	obstacle.Distance = horizontalDistance
	obstacle.Normal = hit.Normal
	-- Frozen here rather than left for a caller to re-derive: `forward` is the exact vector every
	-- other field on this table (Normal, TopPosition, Depth below) was measured along, and a state
	-- that rebuilt its own travel direction independently at Enter -- from live input that has had a
	-- probe interval's worth of time to change -- would be pairing this frame's geometry with a
	-- different frame's intent. See ObstacleProbe.TravelDirection's own header.
	obstacle.TravelDirection = forward
	obstacle.Instance = hit.Instance
	obstacle.VaultAllowed = permissions.Vaultable
	obstacle.MantleAllowed = permissions.Mantleable

	if not topHit or not topPosition then
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

	obstacle.TopPosition = topPosition
	obstacle.Height = topPosition.Y - footPosition.Y

	-- Far-side probe: one downward ray past the maximum vaultable depth. Where it lands answers both
	-- remaining questions at once -- if it lands at roughly the obstacle's own top height the surface
	-- is still continuing (too deep to vault, so this is a mantle target); if it lands lower, there is
	-- a far edge inside the vaultable band and a floor to land on.
	local farPoint = nearFace + forward * (OBSTACLE.VaultMaxDepth + 0.5)
	local farOrigin = Vector3.new(farPoint.X, footPosition.Y + topScanHeight, farPoint.Z)
	local farHit = castRay(farOrigin, Vector3.new(0, -(topScanHeight + OBSTACLE.LandingClearanceHeight), 0))

	if farHit and farHit.Position.Y >= topPosition.Y - 0.5 then
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
	local standCheck = castRay(topPosition + UP * 0.3, UP * OBSTACLE.StandClearanceHeight)
	obstacle.HasStandingSpace = standCheck == nil

	-- The check above is made at the EDGE; the mantle ends a step in from it. Only asked when the classifier
	-- could actually pick Mantle for this obstacle, so a vault or hop never pays for it.
	if obstacle.HasStandingSpace and SURFACE.Enabled and ground.Grounded and OBSTACLE.StandClearance.Enabled then
		local needsMantle = obstacle.Height > OBSTACLE.VaultMaxHeight
			or obstacle.Depth > OBSTACLE.VaultMaxDepth
			or not obstacle.HasLandingSpace
		if
			needsMantle
			and obstacle.MantleAllowed
			and obstacle.Height <= OBSTACLE.MantleMaxHeight
			and obstacle.Distance <= OBSTACLE.MantleMaxReach
		then
			obstacle.HasStandingSpace = mantleFootprintClear(topPosition, forward, now)
		end
	end
end

--
-- Walls
--

local function clearWall(probe: WallProbe, now: number): ()
	probe.SampledAt = now
	probe.Found = false
	probe.Distance = math.huge
	probe.Position = Vector3.zero
	probe.Tangent = Vector3.zero
	probe.TiltAngle = 90
	probe.Instance = nil
	probe.WallRunAllowed = true
	probe.BounceScale = 1
end

-- Where the cluster's extra rays start, relative to the centre ray: the four points of a cross around it,
-- Surface.Wall.SpreadStuds out. Along the wall (horizontal, perpendicular to the cast) and up/down it, so a
-- narrow sliver, a seam or a one-part-deep recess has to fool a ray in each axis to win a vote.
local function clusterOffset(index: number, lateral: Vector3, spread: number): Vector3
	if index == 1 then
		return lateral * spread
	elseif index == 2 then
		return lateral * -spread
	elseif index == 3 then
		return UP * spread
	end
	return UP * -spread
end

-- One wall side, with the surface it is describing HELD between calls.
--
-- WHAT CHANGED, AND WHY. This used to publish the raw nearest hit of one ray every sample. On a mountain
-- built from many overlapping parts that hit moves from part to part as the character moves a fraction of
-- a stud, so the wall's normal jittered, a seam between two blocks read as the wall ending, and a part
-- poking a hair out of the real face -- or a sliver of one buried in it -- won samples and seated the
-- character in geometry. The probe now describes a PLANE (Shared/Parkour/SurfaceLock.lua) and the part is
-- only the label on it:
--
--   * FAST PATH. A held surface that the centre ray still lands on (same plane within Surface's
--     SameSurface tolerances) needs nothing else: the label follows the ray onto whichever flush part it
--     hit, and the normal eases. One cast, exactly the old cost.
--   * VALIDATED PATH. Anything else -- a first contact, a bump, a corner, a ray that landed somewhere the
--     held plane is not -- is checked by a four-ray cross around the centre ray, and the plane most of the
--     five agree on is the candidate. A sliver or a buried part is one ray's opinion against four.
--   * HYSTERESIS. The candidate is then offered to the lock, which decides whether it replaces what is held
--     (SurfaceLock.Observe's decision table). Two near-coincident parts can no longer take turns.
--
-- A centre ray that finds nothing drops the lock on the spot, with no grace: States/WallRunning's corner
-- turn depends on a lost wall being reported lost on the frame it goes.
--
-- A validation cluster the frame cannot afford keeps last sample's answer (the probe is left untouched and
-- retried next frame) instead of guessing.
local function probeWall(
	probe: WallProbe,
	lock: SurfaceLock.Lock,
	rootPart: BasePart,
	sideDirection: Vector3,
	travelDirection: Vector3,
	forwardDirection: Vector3,
	allowDiagonal: boolean,
	now: number
): ()
	local origin = rootPart.Position
	local castDirection = sideDirection * WALLRUN.ProbeDistance
	local hit = castRay(origin, castDirection)
	-- THE DIAGONAL FALLBACK, and the case it exists for: arriving at a wall HEAD-ON.
	--
	-- The side casts run along the character's own right vector, which is the correct instrument for the
	-- question they were written to answer -- "is there a wall alongside me to run on." It is the wrong
	-- instrument for the other question the wall probes now have to serve: "is there a wall here to kick
	-- off." A character flying into a wall face-first has that wall directly in FRONT of them, so both
	-- side casts run parallel to it and report open air, and States/WallRunning's own wall-select
	-- therefore refuses -- which is precisely where a chained traversal dies, since flying at the next
	-- surface is how a player arrives at it.
	--
	-- So when a side cast finds nothing, the same side is tried again angled forward. A wall dead ahead
	-- registers on both sides (the nearer wins in WallRunning's own selection); a wall genuinely off to
	-- one side registers there and not on the other. It cannot manufacture a spurious wall-RUN out of a
	-- head-on approach either: the tangent of a wall in front is perpendicular to the travel direction,
	-- so States/WallRunning's approach-angle gate refuses it exactly as it did before.
	--
	-- Only while airborne, and only when the straight cast missed: on the ground this would make walking
	-- toward a corner register walls beside the character that are not there, and paying two extra casts
	-- on frames that already found what they needed would be paying for nothing.
	if not hit and allowDiagonal then
		local diagonal = ParkourMath.SafeUnit(sideDirection + forwardDirection, Vector3.zero)
		if diagonal.Magnitude > 0 then
			castDirection = diagonal * (WALLRUN.ProbeDistance * WALLRUN.DiagonalProbeScale)
			hit = castRay(origin, castDirection)
		end
	end
	if not hit then
		SurfaceLock.Observe(lock, nil, castDirection, now, SURFACE)
		clearWall(probe, now)
		return
	end

	local permissions = ParkourTagging.GetPermissions(hit.Instance, now)
	if permissions.Ignored or not permissions.WallRunnable then
		SurfaceLock.Observe(lock, nil, castDirection, now, SURFACE)
		clearWall(probe, now)
		-- Preserved rather than reset to the permissive default: a state that reads WallRunAllowed
		-- to explain a refusal (and the debug overlay, which shows exactly that) needs to be able to
		-- distinguish "no wall here" from "a wall the designer marked unusable."
		probe.WallRunAllowed = false
		probe.Instance = hit.Instance
		return
	end

	local position = hit.Position
	local normal = hit.Normal
	local instance = hit.Instance
	local distance = hit.Distance

	if SURFACE.Enabled then
		local onHeldSurface = SurfaceLock.Matches(lock, hit.Position, hit.Normal, now, SURFACE)
		local candidate: SurfaceLock.Candidate? = hit
		if not onHeldSurface then
			if not validationAvailable(WALL_CLUSTER_RAYS) then
				-- Cannot confirm this frame, so do not decide anything. The probe and the lock stay exactly as
				-- they were; SampledAt is untouched, so the next Update retries instead of waiting out the
				-- cache interval.
				return
			end
			SurfaceLock.Clear(wallSamples)
			SurfaceLock.Add(wallSamples, hit.Position, hit.Normal, hit.Instance, hit.Distance)
			local lateral = ParkourMath.SafeUnit(UP:Cross(castDirection), Vector3.zero)
			for index = 1, WALL_CLUSTER_RAYS do
				local offset = clusterOffset(index, lateral, SURFACE.Wall.SpreadStuds)
				local extra = castValidationRay(origin + offset, castDirection)
				if extra and isVotingHit(extra, now) then
					SurfaceLock.Add(wallSamples, extra.Position, extra.Normal, extra.Instance, extra.Distance)
				end
			end
			if SurfaceLock.Vote(wallSamples, wallConsensus, SURFACE.Consensus) then
				candidate = wallConsensus
			else
				-- No plane has a majority. A held surface that is still fresh is kept as it is (it expires on its
				-- own if nothing confirms it); with nothing held there is nothing trustworthy to attach to.
				if not SurfaceLock.IsFresh(lock, now, SURFACE) then
					clearWall(probe, now)
					return
				end
				candidate = nil
			end
		end
		if candidate ~= nil then
			SurfaceLock.Observe(lock, candidate, castDirection, now, SURFACE)
		end
		position = lock.Position
		normal = lock.Normal
		instance = lock.Instance or hit.Instance
		distance = SurfaceLock.Distance(lock, origin, castDirection, hit.Distance)

		-- The label may have moved to a different part than the one the centre ray hit (an outvoted sliver, a
		-- flush neighbour), and the designer's tags are on parts. The part the plane is now credited to is
		-- the one whose permissions apply.
		if instance ~= hit.Instance then
			permissions = ParkourTagging.GetPermissions(instance, now)
			if permissions.Ignored or not permissions.WallRunnable then
				SurfaceLock.Reset(lock)
				clearWall(probe, now)
				probe.WallRunAllowed = false
				probe.Instance = instance
				return
			end
		end
	end

	probe.SampledAt = now
	probe.Found = true
	probe.Distance = distance
	probe.Position = position
	probe.Normal = normal
	probe.TiltAngle = ParkourMath.SurfaceTilt(normal)
	probe.Tangent = ParkourMath.WallTangent(normal, travelDirection)
	probe.Instance = instance
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

-- The result of a single-direction ledge search, as plain values rather than a mutated singleton --
-- see resolveLedgeAt's own header for why this exists separately from the `ledge` result table.
export type LedgeHit = {
	EdgePosition: Vector3,
	WallNormal: Vector3,
	HasStandingSpace: boolean,
	HasHangSpace: boolean,
	Instance: BasePart?,
}

-- Whether the body's footprint at a hang pose is free of geometry, for the cases the single column under the
-- root (Ledge.HangFootClearance) cannot see. Three vertical casts from near the lip down to just above the
-- soles: either side of the body along the face, and on the wall side of it. A CAST rather than an overlap
-- query on purpose -- see Ledge.BodyClearance for why a bounding-box query is wrong for a MeshPart mountain.
--
-- Two limits, stated so nobody mistakes them for oversights. A column that STARTS inside a part reports
-- nothing (a ray that begins inside geometry hits nothing), so geometry enclosing the whole top of a column is
-- not seen; the lip itself is kept out of the column by TopAboveRootStuds for the same reason. And a refusal
-- on budget answers "not clear": declining a grab for one frame is safe, hanging inside a rock is not.
local function hangBodyClear(hangPosition: Vector3, wallNormal: Vector3, facePosition: Vector3, now: number): boolean
	local BODY = LEDGE.BodyClearance
	if not validationAvailable(LEDGE_BODY_RAYS) then
		return false
	end
	local outward = ParkourMath.SafeUnit(ParkourMath.Flatten(wallNormal), Vector3.zero)
	if outward.Magnitude < 1e-3 then
		return true
	end
	local tangent = ParkourMath.SafeUnit(UP:Cross(outward), Vector3.zero)
	local top = hangPosition + UP * BODY.TopAboveRootStuds
	local column = Vector3.new(0, -(BODY.TopAboveRootStuds + footOffset - BODY.FootSkinStuds), 0)
	-- The wall-side column stops SkinStuds short of the face, so a body hanging close to the wall is not
	-- reported as inside the wall it is gripping.
	local gapToFace = (hangPosition - facePosition):Dot(outward)
	local wallSide = math.clamp(gapToFace - BODY.SkinStuds, 0, BODY.HalfDepthStuds)
	for index = 1, LEDGE_BODY_RAYS do
		local offset = if index == 1
			then tangent * BODY.HalfWidthStuds
			elseif index == 2 then tangent * -BODY.HalfWidthStuds
			else outward * -wallSide
		local hit = castValidationRay(top + offset, column)
		if hit and isVotingHit(hit, now) then
			return false
		end
	end
	return true
end

-- ONE DIRECTION'S WORTH OF THE LEDGE SEARCH, as a pure function of its inputs: find a wall face along
-- `forward`, find the lip above that face, and check the lip sits inside the (sweep-widened) grab
-- band. Returns the hit on success; on failure returns nil so the caller can try another direction
-- without having to save or restore anything, plus the part that refused on permissions -- if any --
-- so the caller can report WHY nothing was grabbable rather than just that nothing was.
--
-- FACTORED OUT OF THE SCHEDULED PROBE DELIBERATELY, so it has a second caller: EnvironmentProbe.
-- ProbeLedgeAt below, which States/LedgeHanging.lua's shimmy calls AD HOC, every frame, from an origin
-- and direction it chooses itself rather than the move/facing search probeLedge runs. A shimmy
-- continuation check happening to route through the SAME `ledge` singleton the scheduled Ledge probe
-- writes would mean two callers fighting over one result table within the same frame -- the ad hoc
-- check would either stomp the scheduled probe's answer or be stomped by it, depending on which ran
-- last. Returning values instead of mutating shared state is what makes a second caller safe at all.
--
-- `validate` turns on the SURFACE-STABILITY checks (ParkourConstants.Surface and Ledge.ConsensusSpreadStuds/
-- BodyClearance): the face and the lip are each confirmed by a ray either side along the wall, so a sliver
-- poking out of the real lip or face is outvoted rather than seated on, and the hang pose is checked for
-- geometry in the body's own footprint. Worth up to LEDGE_SIDE_RAYS + LEDGE_BODY_RAYS validation casts, which
-- is why the one caller that runs this at many sample points (FindLedgeLeapTarget) passes false and
-- validates only the candidate it picks.
local function resolveLedgeAt(
	headPosition: Vector3,
	forward: Vector3,
	sweep: number,
	now: number,
	validate: boolean
): (LedgeHit?, BasePart?)
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
		return nil, nil
	end

	local permissions = ParkourTagging.GetPermissions(faceHit.Instance, now)
	if permissions.Ignored or not permissions.LedgeGrabbable then
		return nil, faceHit.Instance
	end

	-- The lip: scan down from above the head band, just past the wall face. Both the top of the scan
	-- and the band it is measured against are stretched upward by `sweep` -- see probeLedge below.
	local scanTop = headPosition.Y + LEDGE.GrabBandAboveHead + sweep
	local scanOrigin = Vector3.new(faceHit.Position.X, scanTop, faceHit.Position.Z) + forward * 0.3
	local scanLength = LEDGE.GrabBandAboveHead + sweep + LEDGE.GrabBandBelowHead
	local lipHit = castRay(scanOrigin, Vector3.new(0, -scanLength, 0))
	if not lipHit then
		return nil, nil
	end

	-- The lip must genuinely be an EDGE within the grab band, not the top of something far below or
	-- a ceiling far above -- both of which the scan can legitimately land on.
	local relativeHeight = lipHit.Position.Y - headPosition.Y
	if relativeHeight > LEDGE.GrabBandAboveHead + sweep or relativeHeight < -LEDGE.GrabBandBelowHead then
		return nil, nil
	end

	local facePosition = faceHit.Position
	local faceNormal = faceHit.Normal
	local lipPosition = lipHit.Position
	local lipInstance = lipHit.Instance
	local validated = validate and SURFACE.Enabled
	if validated then
		if not validationAvailable(LEDGE_SIDE_RAYS) then
			return nil, nil
		end
		-- The centre face/lip pair goes first, so a split vote keeps the old single-ray answer (SurfaceLock.Vote
		-- breaks ties toward the earlier sample).
		SurfaceLock.Clear(ledgeFaceSamples)
		SurfaceLock.Add(ledgeFaceSamples, faceHit.Position, faceHit.Normal, faceHit.Instance, faceHit.Distance)
		SurfaceLock.Clear(ledgeLipSamples)
		SurfaceLock.Add(ledgeLipSamples, lipHit.Position, lipHit.Normal, lipHit.Instance, lipHit.Distance)
		local lateral = ParkourMath.SafeUnit(UP:Cross(forward), Vector3.zero)
		for side = -1, 1, 2 do
			local shift = lateral * (side * LEDGE.ConsensusSpreadStuds)
			local sideFace = castValidationRay(headPosition + shift, forward * LEDGE.GrabReachDistance)
			-- A side ray that finds no face ABSTAINS, and so does its lip ray: a post or a beam narrower than
			-- the spread has nothing at the sides, and a lip ray cast there would land on the floor far below
			-- and vote against a perfectly good ledge.
			if
				sideFace
				and isVotingHit(sideFace, now)
				and ParkourMath.SurfaceTilt(sideFace.Normal) <= LEDGE.MaxFaceTiltDegrees
			then
				SurfaceLock.Add(
					ledgeFaceSamples,
					sideFace.Position,
					sideFace.Normal,
					sideFace.Instance,
					sideFace.Distance
				)
				local sideScanOrigin = Vector3.new(sideFace.Position.X, scanTop, sideFace.Position.Z) + forward * 0.3
				local sideLip = castValidationRay(sideScanOrigin, Vector3.new(0, -scanLength, 0))
				if sideLip and isVotingHit(sideLip, now) then
					SurfaceLock.Add(
						ledgeLipSamples,
						sideLip.Position,
						sideLip.Normal,
						sideLip.Instance,
						sideLip.Distance
					)
				end
			end
		end
		-- One sample is a lone witness (a post, a beam, the end of a wall): nothing disagrees, so it stands.
		-- Two or more must produce a majority, or the candidate is refused as unconfirmed -- including two
		-- that disagree, which an interior corner can cause within ~SpreadStuds of the seam. Refusing a grab
		-- a step too close to a corner costs the player a sidestep; seating the hang on whichever of two
		-- disagreeing surfaces came first is the bug this exists to remove.
		if ledgeFaceSamples.Count > 1 then
			if not SurfaceLock.Vote(ledgeFaceSamples, ledgeFaceConsensus, SURFACE.Consensus) then
				return nil, nil
			end
			facePosition = ledgeFaceConsensus.Position
			faceNormal = ledgeFaceConsensus.Normal
			if ParkourMath.SurfaceTilt(faceNormal) > LEDGE.MaxFaceTiltDegrees or ledgeFaceConsensus.Instance == nil then
				return nil, nil
			end
			if ledgeFaceConsensus.Instance ~= faceHit.Instance then
				local winnerPermissions = ParkourTagging.GetPermissions(ledgeFaceConsensus.Instance, now)
				if winnerPermissions.Ignored or not winnerPermissions.LedgeGrabbable then
					return nil, ledgeFaceConsensus.Instance
				end
			end
		end
		if ledgeLipSamples.Count > 1 then
			if not SurfaceLock.Vote(ledgeLipSamples, ledgeLipConsensus, SURFACE.Consensus) then
				return nil, nil
			end
			lipPosition = ledgeLipConsensus.Position
			lipInstance = ledgeLipConsensus.Instance
			-- The band was judged on the centre ray's height; the voted lip may sit elsewhere in it.
			local votedHeight = lipPosition.Y - headPosition.Y
			if votedHeight > LEDGE.GrabBandAboveHead + sweep or votedHeight < -LEDGE.GrabBandBelowHead then
				return nil, nil
			end
		end
	end

	local standCheck = castRay(lipPosition + UP * 0.3, UP * LEDGE.StandClearanceHeight)

	-- Room to hang, measured at the pose the hang will ACTUALLY use (hence the shared
	-- ParkourMath.HangPosition rather than an approximation): straight down from the hanging root for
	-- the rig's own root-to-sole distance plus a little air. A hit means the character's feet would be
	-- in the floor, which is not a hang -- see Ledge.HangFootClearance for the failure that produced.
	-- Nothing found is the common and correct case: a real ledge has open air under it.
	local hangPosition =
		ParkourMath.HangPosition(lipPosition, faceNormal, LEDGE.HangVerticalOffset, LEDGE.HangHorizontalOffset)
	local hangCheck = castRay(hangPosition, Vector3.new(0, -(footOffset + LEDGE.HangFootClearance), 0))
	local hasHangSpace = hangCheck == nil
	-- The column under the root says the feet are clear. It says nothing about the shoulders, the back or the
	-- legs, which is where a rock outcrop or a neighbouring part standing proud of the face would be. Only
	-- worth asking once the cheap column has passed.
	if hasHangSpace and validated and LEDGE.BodyClearance.Enabled then
		hasHangSpace = hangBodyClear(hangPosition, faceNormal, facePosition, now)
	end

	return {
		EdgePosition = lipPosition,
		WallNormal = faceNormal,
		HasStandingSpace = standCheck == nil,
		HasHangSpace = hasHangSpace,
		Instance = lipInstance,
	},
		nil
end

-- Thin wrapper around resolveLedgeAt that fills the shared `ledge` result table -- the scheduled
-- probe's own contract, unchanged from before the factoring above. Fills `ledge` and returns true on
-- success; on failure it leaves `ledge` untouched so the caller can try another direction without
-- having to save and restore anything.
local function tryLedgeDirection(
	headPosition: Vector3,
	forward: Vector3,
	sweep: number,
	now: number
): (boolean, BasePart?)
	local hit, refusedInstance = resolveLedgeAt(headPosition, forward, sweep, now, true)
	if not hit then
		return false, refusedInstance
	end
	ledge.SampledAt = now
	ledge.Found = true
	ledge.EdgePosition = hit.EdgePosition
	ledge.WallNormal = hit.WallNormal
	ledge.HasStandingSpace = hit.HasStandingSpace
	ledge.HasHangSpace = hit.HasHangSpace
	ledge.Instance = hit.Instance
	ledge.Allowed = true
	return true, nil
end

-- PUBLIC: a single ad hoc ledge search from a caller-chosen origin and direction, touching NO shared
-- state -- see resolveLedgeAt's own header for why this had to be a second entry point rather than a
-- second caller of the scheduled probe. `sweep` is 0 for every current caller (a shimmy or a leap
-- moves at a speed slow enough, and samples often enough, that the sweep widening the FALLING probe
-- needs is not needed here); accepted as a parameter anyway rather than hardcoded so a future caller
-- with the same "moving fast between samples" problem does not have to duplicate resolveLedgeAt to get
-- it.
function EnvironmentProbe.ProbeLedgeAt(headPosition: Vector3, forward: Vector3, sweep: number, now: number): LedgeHit?
	local hit = resolveLedgeAt(headPosition, forward, sweep, now, true)
	return hit
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
--     past a ledge the player is staring straight at. But travel stops being tried at all once it has
--     diverged from facing past GrabDirectionMaxSplitDegrees -- past that point it is not a strafe
--     along a face the player is looking at, it is the player moving substantially AWAY from where
--     they are looking (a shift-lock backpedal, most often), and searching it is how falling near a
--     wall behind the player's back auto-grabs an edge they never reached for. See that constant's own
--     header.
--
-- THE PRIMARY DIRECTION DELIBERATELY STOPS AT `moveIntent` AND DOES NOT FALL BACK TO FACING, unlike
-- every other direction this file computes (probeObstacle/probeWall both go MoveDirection -> facing,
-- via EnvironmentProbe.Update's own composite). Those probes only matter once the player has already
-- chosen to act -- moving, or standing at an obstacle they are about to enter a state against. A ledge
-- grab fires with NO button and NO state entry decision at all; it is Committed the instant CanEnter
-- agrees. Letting its search direction fall all the way back to "wherever the camera happens to be
-- pointed" means a character in genuine free-fall next to a wall -- zero measured velocity, zero held
-- input, camera merely orbited toward the face because that is where the player was last looking --
-- gets snatched out of a fall they never asked to interrupt. Facing is still exactly right as the
-- SECOND direction above (a player actively strafing while looking at a wall has real MoveDirection,
-- so it never reaches this fallback at all); it is only the fallback of last resort that this function
-- refuses to take.
local function probeLedge(
	rootPart: BasePart,
	moveDirection: Vector3,
	moveIntent: Vector3,
	verticalSpeed: number,
	now: number
): ()
	local headPosition = rootPart.Position + UP * (rootPart.Size.Y * 0.5)

	-- Measured against the last time this probe looked (which clearLedge stamps too, so it is a real
	-- "time since we last knew" rather than only a frame time) and clamped at both ends: the floor is
	-- there so a first sample after a long gap does not sweep the whole map, the ceiling is
	-- Ledge.GrabSweepMaxStuds' own reasoning about what still reads as catching yourself.
	local sinceLastSample = if ledge.SampledAt > 0 then math.clamp(now - ledge.SampledAt, 0, 0.1) else 0
	local sweep = math.clamp(math.max(-verticalSpeed, 0) * sinceLastSample, 0, LEDGE.GrabSweepMaxStuds)

	local facing = ParkourMath.SafeUnit(ParkourMath.Flatten(rootPart.CFrame.LookVector), Vector3.zero)
	-- See ParkourMath.PrimaryReachDirection's own header for why this stops at moveIntent rather than
	-- also falling back to `facing` the way every other direction in this file does.
	local primary = ParkourMath.PrimaryReachDirection(moveDirection, moveIntent)
	if primary.Magnitude < 1e-3 then
		clearLedge(now)
		return
	end

	-- How far primary has drifted from facing decides BOTH of the two-direction search's questions:
	-- whether facing is worth trying as a second cast (GrabDirectionSplitDegrees, below), and -- new --
	-- whether primary is worth trying AT ALL (GrabDirectionMaxSplitDegrees). Past the max, primary is
	-- travel/moveIntent pointed substantially behind the character rather than a strafe along a face
	-- they're looking at, and searching it is how a backpedal auto-grabs a wall the player never looked
	-- at. See GrabDirectionMaxSplitDegrees's own header.
	local divergence = if facing.Magnitude > 0 then ParkourMath.ApproachAngle(primary, facing) else 0

	local found, refusedInstance = false, nil
	if divergence <= LEDGE.GrabDirectionMaxSplitDegrees then
		found, refusedInstance = tryLedgeDirection(headPosition, primary, sweep, now)
	end
	if not found and facing.Magnitude > 0 and divergence > LEDGE.GrabDirectionSplitDegrees then
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
-- Event scans
--
-- Both of the functions below run ONCE, at the moment a discrete action begins, rather than on the
-- per-frame schedule everything above them obeys. They live here rather than in the states that call
-- them for the reason stated in this file's header: nothing else in the framework is allowed to cast a
-- ray, and "except for these two" would be the end of that guarantee. They have their own budget --
-- see castScanRay.
--

local wallJumpTarget: ParkourTypes.WallJumpTarget = {
	Found = false,
	AimPosition = Vector3.zero,
	SurfacePosition = Vector3.zero,
	Normal = UP,
	Instance = nil,
	Distance = math.huge,
	Score = 0,
	Corridor = false,
}

-- Rotates a horizontal direction by `yawDegrees` around the world up axis and tilts it up by
-- `pitchDegrees`. Written as an explicit tangent term rather than a second axis-angle rotation because
-- the yaw axis is world up and the pitch axis would be the yawed direction's own right vector -- two
-- rotations that have to be composed in the correct order, where adding a vertical component to an
-- already-yawed horizontal unit vector is the same answer with nothing to get backwards.
local function fanDirection(baseDirection: Vector3, yawDegrees: number, pitchDegrees: number): Vector3
	local yawed = CFrame.fromAxisAngle(UP, math.rad(yawDegrees)) * baseDirection
	if pitchDegrees == 0 then
		return ParkourMath.SafeUnit(yawed, baseDirection)
	end
	return ParkourMath.SafeUnit(yawed + UP * math.tan(math.rad(pitchDegrees)), baseDirection)
end

-- THE ASSISTED WALL-JUMP'S EYES: finds the surface the jump should be aimed at, or reports that there
-- isn't one.
--
-- A fan of rays across the open side of the character (the side the push is going anyway), plus a
-- shorter upward-angled arc so a balcony or a ledge above head height is findable at all -- a purely
-- horizontal fan only ever finds what is level with the jump, which would make the assist useless for
-- exactly the ascending chain it is most wanted for.
--
-- `excludeInstance`/`excludePosition` are the wall being jumped FROM. Both are needed and neither is
-- sufficient: the instance catches aiming back at the same part, and the radius catches aiming at the
-- neighbouring block of the same face, which is most walls -- and which would be the infinite ladder
-- States/WallRunning.lua's SameWallLockout exists to forbid, rebuilt out of wall-jumps. See
-- ParkourConstants.WallJump.Assist.SameWallIgnoreRadius.
--
-- Returns the shared result table under the same read-immediately contract as every other result in
-- this file. Never retain it.
function EnvironmentProbe.FindWallJumpTarget(
	rootPart: BasePart,
	aimDirection: Vector3,
	outwardDirection: Vector3,
	excludeInstance: BasePart?,
	excludePosition: Vector3?,
	now: number
): ParkourTypes.WallJumpTarget
	scanBudgetUsed = 0
	wallJumpTarget.Found = false
	wallJumpTarget.Score = 0
	wallJumpTarget.Distance = math.huge
	wallJumpTarget.Instance = nil
	wallJumpTarget.Corridor = false

	local ASSIST = ParkourConstants.WallJump.Assist
	if not ASSIST.Enabled then
		return wallJumpTarget
	end
	local aim = ParkourMath.SafeUnit(ParkourMath.Flatten(aimDirection), Vector3.zero)
	if aim.Magnitude < 1e-3 then
		return wallJumpTarget
	end

	-- Cast from a little above the root's centre, so the fan clears the lip of anything the character is
	-- currently level with rather than burying itself in the wall's own base.
	local origin = rootPart.Position + UP * 0.5
	local bestScore = 0

	-- THE CORRIDOR TEST, run FIRST and short-circuiting the whole ranked scan when it succeeds.
	--
	-- Straight out from the wall being kicked off, plus a ray either side to tolerate a shaft that is not
	-- perfectly square. What it is looking for is not the nearest or best-aimed surface but a specific
	-- geometric relationship -- a face turned back toward the one behind the character -- because that
	-- relationship, and only that, is what makes a climb possible rather than a crossing. It takes
	-- priority over the ranked scan for the same reason: when a player is in a chimney, going UP is what
	-- they are asking for, whatever else the fan might find off to one side.
	local outward = ParkourMath.SafeUnit(ParkourMath.Flatten(outwardDirection), Vector3.zero)
	if outward.Magnitude > 1e-3 then
		local function considerCorridor(direction: Vector3): boolean
			local hit = castScanRay(origin, direction * ASSIST.CorridorMaxGap)
			if not hit then
				return false
			end
			if ParkourTagging.GetPermissions(hit.Instance, now).Ignored then
				return false
			end
			-- Belt and braces against a concave surface curling round in front of itself: the cast points
			-- away from the wall being kicked off, so this should be unreachable, and a corridor kick that
			-- did somehow aim back at its own wall would be the free elevator with none of the guards.
			if excludeInstance ~= nil and hit.Instance == excludeInstance then
				return false
			end
			-- Measured along the OUTWARD axis rather than as a raw hit distance, so an angled side ray
			-- reports the corridor's true width instead of its own longer hypotenuse -- the gap is what the
			-- climb's height budget is computed from, and overstating it costs the player lift.
			local gap = (hit.Position - origin):Dot(outward)
			if gap < ASSIST.CorridorMinGap or gap > ASSIST.CorridorMaxGap then
				return false
			end
			-- The far face has to look back at the near one. This is the entire definition of a corridor,
			-- and it is what stops a single wall with something incidental in front of it from reading as a
			-- shaft to climb.
			local farNormal = ParkourMath.SafeUnit(ParkourMath.Flatten(hit.Normal), Vector3.zero)
			if farNormal.Magnitude < 1e-3 or farNormal:Dot(-outward) < ASSIST.CorridorOpposedDot then
				return false
			end

			wallJumpTarget.Found = true
			wallJumpTarget.Corridor = true
			wallJumpTarget.Score = 0
			wallJumpTarget.SurfacePosition = hit.Position
			wallJumpTarget.Normal = hit.Normal
			wallJumpTarget.Instance = hit.Instance
			wallJumpTarget.Distance = gap
			wallJumpTarget.AimPosition = hit.Position + farNormal * ASSIST.TargetOutwardOffset
			return true
		end

		if
			considerCorridor(outward)
			or considerCorridor(fanDirection(outward, ASSIST.CorridorSplayDegrees, 0))
			or considerCorridor(fanDirection(outward, -ASSIST.CorridorSplayDegrees, 0))
		then
			return wallJumpTarget
		end
	end

	local function consider(direction: Vector3): ()
		local hit = castScanRay(origin, direction * ASSIST.ScanDistance)
		if not hit then
			return
		end
		local permissions = ParkourTagging.GetPermissions(hit.Instance, now)
		if permissions.Ignored then
			return
		end
		-- The wall just left, by either test. See this function's own header.
		if excludeInstance ~= nil and hit.Instance == excludeInstance then
			return
		end
		if excludePosition ~= nil and (hit.Position - excludePosition).Magnitude <= ASSIST.SameWallIgnoreRadius then
			return
		end

		local score = ParkourMath.WallJumpCandidateScore(
			origin,
			aim,
			hit.Position,
			hit.Normal,
			ASSIST.MinTargetDistance,
			ASSIST.ScanDistance,
			ASSIST.AlignmentWeight,
			ASSIST.ProximityWeight,
			ASSIST.SquarenessWeight,
			ASSIST.MinAlignmentDot,
			ASSIST.MinSquarenessDot
		)
		if score <= bestScore then
			return
		end

		bestScore = score
		wallJumpTarget.Found = true
		wallJumpTarget.Score = score
		wallJumpTarget.SurfacePosition = hit.Position
		wallJumpTarget.Normal = hit.Normal
		wallJumpTarget.Instance = hit.Instance
		wallJumpTarget.Distance = (hit.Position - origin).Magnitude
		-- Aimed OUT from the face, so the arrival is beside the surface rather than inside it. Falls back
		-- to backing off along the ray when the face has no horizontal normal to back off along (a hit on
		-- something's underside, which the pitched arc can legitimately produce).
		local faceOutward = ParkourMath.SafeUnit(ParkourMath.Flatten(hit.Normal), -direction)
		wallJumpTarget.AimPosition = hit.Position + faceOutward * ASSIST.TargetOutwardOffset
	end

	local yawCount = math.max(ASSIST.ScanRayCount, 1)
	local yawStep = if yawCount > 1 then (ASSIST.ScanYawSpreadDegrees * 2) / (yawCount - 1) else 0
	for index = 0, yawCount - 1 do
		consider(fanDirection(aim, -ASSIST.ScanYawSpreadDegrees + yawStep * index, 0))
	end

	-- The upward arc is deliberately narrower than the flat fan: something overhead and far off to the
	-- side is not a jump anyone is asking for, where something overhead and roughly ahead is the whole
	-- ascending-chain case.
	local pitchCount = math.max(ASSIST.ScanPitchRayCount, 0)
	local pitchSpread = ASSIST.ScanYawSpreadDegrees * 0.5
	local pitchStep = if pitchCount > 1 then (pitchSpread * 2) / (pitchCount - 1) else 0
	for index = 0, pitchCount - 1 do
		consider(fanDirection(aim, -pitchSpread + pitchStep * index, ASSIST.ScanPitchDegrees))
	end

	return wallJumpTarget
end

local leapTarget: ParkourTypes.LeapTarget = {
	Found = false,
	LandingPosition = Vector3.zero,
	Normal = UP,
	Instance = nil,
	Distance = 0,
}

local ledgeLeapTarget: ParkourTypes.LedgeLeapTarget = {
	Found = false,
	LandingPosition = Vector3.zero,
	EdgePosition = Vector3.zero,
	WallNormal = UP,
	Instance = nil,
	Distance = 0,
}

-- Finds a grabbable edge along the player's own aim -- the ledge-to-ledge leap's target search, run at
-- the moment States/LedgeHanging.lua's Update sees a directional jump press while hanging.
--
-- DELIBERATELY SIMPLER THAN FindLeapTarget ABOVE, and the scoping is honest rather than accidental.
-- That scan solves a harder problem (any surface, found via a downward cast, with a whole "is this my
-- own footing" exclusion because a floor cast routinely lands on the floor the player is already
-- standing on) that does not apply here: a hang has no footing to exclude, and this is not searching
-- for a floor, it is searching for a WALL FACE WITH A LIP -- resolveLedgeAt's own job, reused rather
-- than reinvented. So this walks the aim ray outward and asks resolveLedgeAt the same question at each
-- sample point, taking the FARTHEST one that is both a real ledge and reachable by the same launch
-- solver Leaping.Enter already trusts (Constants.Leap.ApexClearance/ReachMargin/etc -- deliberately
-- the SAME numbers, not a parallel set, because the arc should feel like the same move whether it is
-- launched at an ordinary surface or at another ledge).
--
-- Farthest rather than nearest for the same reason FindLeapTarget's own header gives: the near ledge is
-- usually the one just released, or one an ordinary drop-and-catch already reaches, so choosing it
-- would make the whole move pointless.
function EnvironmentProbe.FindLedgeLeapTarget(
	rootPart: BasePart,
	aimDirection: Vector3,
	now: number
): ParkourTypes.LedgeLeapTarget
	scanBudgetUsed = 0
	ledgeLeapTarget.Found = false
	ledgeLeapTarget.Distance = 0
	ledgeLeapTarget.Instance = nil

	local LEDGE_LEAP = ParkourConstants.LedgeLeap
	local LEAP = ParkourConstants.Leap
	local flatAim = ParkourMath.SafeUnit(ParkourMath.Flatten(aimDirection), Vector3.zero)
	if flatAim.Magnitude < 1e-3 then
		-- Looking straight up or down: no planar direction to search along, and inventing one from the
		-- body's own facing would aim the search somewhere the player was not looking.
		return ledgeLeapTarget
	end

	local origin = rootPart.Position
	local bestSample = origin
	local sampleCount = math.max(LEDGE_LEAP.RangeSamples, 1)
	local step = if sampleCount > 1 then (LEDGE_LEAP.MaxRange - LEDGE_LEAP.MinRange) / (sampleCount - 1) else 0

	for index = 0, sampleCount - 1 do
		local distance = LEDGE_LEAP.MinRange + step * index
		local samplePoint = origin + flatAim * distance
		local hit, _refused = resolveLedgeAt(samplePoint, flatAim, 0, now, false)
		if hit and hit.HasHangSpace then
			local landing = ParkourMath.HangPosition(
				hit.EdgePosition,
				hit.WallNormal,
				LEDGE.HangVerticalOffset,
				LEDGE.HangHorizontalOffset
			)
			local landingDistance = ParkourMath.PlanarSpeed(landing - origin)
			-- Farthest wins, so a nearer sample already found this frame is not overwritten by a
			-- further one that solves worse -- see the header on why farthest is the right default at
			-- all.
			if landingDistance > ledgeLeapTarget.Distance then
				local _velocity, reachable = ParkourMath.SolveLaunchVelocity(
					origin,
					landing,
					Workspace.Gravity,
					LEAP.ApexClearance,
					LEAP.ReachMargin,
					LEAP.MinUpSpeed,
					LEAP.MaxUpSpeed,
					LEAP.MaxPlanarSpeed
				)
				if reachable then
					ledgeLeapTarget.Found = true
					ledgeLeapTarget.LandingPosition = landing
					ledgeLeapTarget.EdgePosition = hit.EdgePosition
					ledgeLeapTarget.WallNormal = hit.WallNormal
					ledgeLeapTarget.Instance = hit.Instance
					ledgeLeapTarget.Distance = landingDistance
					bestSample = samplePoint
				end
			end
		end
	end

	-- The scan above ran unvalidated -- it samples many points, and validating each would cost more than the
	-- frame's validation budget -- so the ONE point it settled on is confirmed now, the way the scheduled
	-- probe would have confirmed it. A leap aimed at a sliver, or at a hang pose with a rock in it, would
	-- launch the character into exactly what the hang checks exist to refuse. The confirmed pose can differ
	-- from the scanned one by a few tenths, so the landing is re-derived from it and the launch re-solved:
	-- the target is kept only if it is still reachable.
	if ledgeLeapTarget.Found and SURFACE.Enabled then
		local confirmed = resolveLedgeAt(bestSample, flatAim, 0, now, true)
		local keep = false
		if confirmed and confirmed.HasHangSpace then
			local landing = ParkourMath.HangPosition(
				confirmed.EdgePosition,
				confirmed.WallNormal,
				LEDGE.HangVerticalOffset,
				LEDGE.HangHorizontalOffset
			)
			local _velocity, reachable = ParkourMath.SolveLaunchVelocity(
				origin,
				landing,
				Workspace.Gravity,
				LEAP.ApexClearance,
				LEAP.ReachMargin,
				LEAP.MinUpSpeed,
				LEAP.MaxUpSpeed,
				LEAP.MaxPlanarSpeed
			)
			if reachable then
				keep = true
				ledgeLeapTarget.LandingPosition = landing
				ledgeLeapTarget.EdgePosition = confirmed.EdgePosition
				ledgeLeapTarget.WallNormal = confirmed.WallNormal
				ledgeLeapTarget.Instance = confirmed.Instance
				ledgeLeapTarget.Distance = ParkourMath.PlanarSpeed(landing - origin)
			end
		end
		if not keep then
			ledgeLeapTarget.Found = false
			ledgeLeapTarget.Distance = 0
			ledgeLeapTarget.Instance = nil
		end
	end

	return ledgeLeapTarget
end

-- WHERE A LEAP LANDS: the FARTHEST surface along the player's own view direction that the launch caps
-- can actually reach.
--
-- Farthest, not nearest, and that is the whole character of the move rather than an implementation
-- detail. A leap that picks the near ledge when the player is plainly looking at the far one has
-- misread them -- and the near ledge was reachable with an ordinary jump anyway, so choosing it makes
-- pressing the dedicated Leap key pointless. The scan therefore walks OUTWARD and keeps the last thing
-- that works.
--
-- "Works" is three questions, and all three have to be asked here rather than left to the state:
--   * Is there a floor under this point at all? (a downward cast from above it)
--   * Is it standable, and is there room to stand? (slope, then a headroom cast)
--   * Can the launch caps actually get there? (ParkourMath.SolveLaunchVelocity's own reachability,
--     asked with the same numbers States/Leaping will fly with)
-- The third is what makes the promise honest. Without it the scan happily returns a rooftop eighty
-- studs away that the solver then refuses, and pressing Leap produces the fallback hop instead of the
-- leap the player could see themselves making.
--
-- The view ray is cast once first, and it does two jobs. It bounds the open-air samples -- a wall across
-- the courtyard is not a place to land, but the TOP of that wall very much is, and samples beyond it are
-- inside geometry rather than in the open -- and it is the definition of LOOKING DIRECTLY AT something,
-- which is what decides whether the player's own footing is allowed to be a target at all. See
-- Leap.IgnoreNearRadius, and `direct` in consider below.
--
-- `groundInstance` is whatever the character is currently standing on (ParkourContext.Ground.Instance),
-- passed in rather than probed for here because the ground probe has already answered that question this
-- frame and asking again would be a second opinion that could differ from the first.
function EnvironmentProbe.FindLeapTarget(
	rootPart: BasePart,
	aimDirection: Vector3,
	groundInstance: BasePart?,
	now: number
): ParkourTypes.LeapTarget
	scanBudgetUsed = 0
	leapTarget.Found = false
	leapTarget.Distance = 0
	leapTarget.Instance = nil

	local LEAP = ParkourConstants.Leap
	local aim = ParkourMath.SafeUnit(aimDirection, Vector3.zero)
	if aim.Magnitude < 1e-3 then
		return leapTarget
	end
	local flatAim = ParkourMath.SafeUnit(ParkourMath.Flatten(aim), Vector3.zero)
	if flatAim.Magnitude < 1e-3 then
		-- Looking straight up or straight down. There is no planar direction to leap along, and inventing
		-- one from the body's facing would send the player somewhere they were not looking.
		return leapTarget
	end

	local origin = rootPart.Position
	-- How far the open air extends along the view ray. Anything past this is behind something solid.
	local blockedAt = LEAP.MaxRange
	local viewHit = castScanRay(origin, aim * LEAP.MaxRange)
	local viewHitInstance: BasePart? = nil
	if viewHit then
		blockedAt = (viewHit.Position - origin).Magnitude
		viewHitInstance = viewHit.Instance
	end

	-- Tests one candidate landing point and records it if it beats what we have. Called in increasing
	-- distance order, so "beats" is simply "is further" -- hence the comparison on Distance rather than a
	-- score.
	--
	-- `direct` says the player is LOOKING AT this surface rather than merely looking over it: the view ray
	-- itself landed on it (or on the structure it belongs to). It is the only thing that lets a candidate
	-- through the near-surface rule below.
	local function consider(surfaceTop: Vector3, normal: Vector3, instance: BasePart?, direct: boolean): ()
		if ParkourMath.SlopeAngle(normal) > SLOPE.MaxWalkableAngleDegrees then
			return
		end
		if ParkourTagging.GetPermissions(instance, now).Ignored then
			return
		end
		-- THE NEAR-SURFACE RULE. A downward cast from a point along the view ray finds whatever is under
		-- that point -- which, on any decent-sized platform, is the platform the player is standing on.
		-- With "take the farthest" on top of that, the leap's answer to "what am I looking at" became a
		-- spot on the player's own floor, thirty studs away, that they never asked for and could have
		-- walked to.
		--
		-- Not banned outright, because leaping down your own ramp or along your own roof is legitimate --
		-- gated on actually looking at the spot. Looking ACROSS a surface (the ray passes over it and hits
		-- something beyond, or nothing) is not looking at it; looking INTO it is.
		if not direct then
			local isOwnFooting = instance ~= nil and instance == groundInstance
			local isWhereWeAlreadyAre = (surfaceTop - origin).Magnitude <= LEAP.IgnoreNearRadius
			if isOwnFooting or isWhereWeAlreadyAre then
				return
			end
		end
		-- Pulled in from wherever the cast happened to meet the surface, along the leap's own direction.
		-- This is the "perfect ledge jump" in one line: aiming at the exact point found puts the landing
		-- on the lip, where a stud of error is a miss.
		local landing = surfaceTop + flatAim * LEAP.LandingInsetStuds
		local distance = ParkourMath.PlanarSpeed(landing - origin)
		if distance < LEAP.MinRange or distance <= leapTarget.Distance then
			return
		end
		local headroom = castScanRay(landing + UP * 0.3, UP * LEAP.SurfaceHeadroom)
		if headroom ~= nil then
			return
		end
		-- Asked with exactly the numbers States/Leaping.Enter will fly with, so a target this function
		-- offers is one the solver has already agreed to.
		local _velocity, reachable = ParkourMath.SolveLaunchVelocity(
			origin,
			landing,
			Workspace.Gravity,
			LEAP.ApexClearance,
			LEAP.ReachMargin,
			LEAP.MinUpSpeed,
			LEAP.MaxUpSpeed,
			LEAP.MaxPlanarSpeed
		)
		if not reachable then
			return
		end

		leapTarget.Found = true
		leapTarget.LandingPosition = landing
		leapTarget.Normal = normal
		leapTarget.Instance = instance
		leapTarget.Distance = distance
	end

	-- The top of whatever the view ray ran into. Checked FIRST, before the open-air samples, because it
	-- is the most likely thing the player means: they are looking at a building, and the leap they want
	-- is onto it. Its own down-cast starts above the hit and a little past it, so it lands on the roof
	-- rather than skimming the face.
	if viewHit then
		local pastFace = viewHit.Position + flatAim * 0.6
		local roofHit = castScanRay(
			pastFace + UP * LEAP.SurfaceScanAbove,
			Vector3.new(0, -(LEAP.SurfaceScanAbove + LEAP.SurfaceScanBelow), 0)
		)
		if roofHit then
			-- Direct by construction: this candidate exists because the view ray ran into the structure it
			-- belongs to. The roof part and the face the ray hit are usually different instances, which is
			-- why directness is passed as a fact rather than re-derived from an instance comparison.
			consider(roofHit.Position, roofHit.Normal, roofHit.Instance, true)
		end
	end

	-- Open-air samples, walking outward. Each one asks "if I were above this point, what is underneath
	-- it" -- which is how a leap across a gap onto a lower roof, or down into a courtyard, is found at
	-- all. Stops at whatever the view ray hit: past that the samples are inside geometry.
	local farthestSample = math.min(blockedAt, LEAP.MaxRange)
	if farthestSample > LEAP.MinRange then
		local sampleCount = math.max(LEAP.RangeSamples, 1)
		local step = if sampleCount > 1 then (farthestSample - LEAP.MinRange) / (sampleCount - 1) else 0
		for index = 0, sampleCount - 1 do
			local distance = LEAP.MinRange + step * index
			local samplePoint = origin + aim * distance
			local floorHit = castScanRay(
				samplePoint + UP * LEAP.SurfaceScanAbove,
				Vector3.new(0, -(LEAP.SurfaceScanAbove + LEAP.SurfaceScanBelow), 0)
			)
			if floorHit then
				-- Direct only when this sample landed on the very thing the view ray hit -- i.e. the player
				-- is looking INTO this surface, not over it. Everything else here is inferred from a
				-- downward cast, which is exactly the path that used to serve up the player's own floor.
				consider(
					floorHit.Position,
					floorHit.Normal,
					floorHit.Instance,
					floorHit.Instance ~= nil and floorHit.Instance == viewHitInstance
				)
			end
		end
	end

	return leapTarget
end

-- WHERE A LEDGE CLIMB ACTUALLY ENDS: the real standable surface behind a lip, measured rather than
-- assumed.
--
-- A ladder of downward casts at increasing insets from the edge, taking the first that is both
-- standable (slope within the walkable limit) and has headroom. Each inset looks both ABOVE the lip's
-- own height and well below it, because both cases are ordinary geometry: a stepped roof rises behind
-- its edge, a parapet has a lower walkway behind it, and the old derived end position -- one authored
-- step in, at the lip's own height -- was floating or buried in every one of them.
--
-- Returns found/position/normal. A false means "nothing measurable back there," which is the honest
-- answer for a railing or a lip on a sloped face; States/LedgeClimbing.lua keeps its derived position
-- for that case rather than refusing a climb the player already committed to.
function EnvironmentProbe.FindStandSurface(
	edgePosition: Vector3,
	forward: Vector3,
	now: number
): (boolean, Vector3, Vector3)
	scanBudgetUsed = 0
	local flatForward = ParkourMath.SafeUnit(ParkourMath.Flatten(forward), Vector3.zero)
	if flatForward.Magnitude < 1e-3 then
		return false, edgePosition, UP
	end

	local sampleCount = math.max(LEDGE.ClimbInsetSamples, 1)
	local insetStep = if sampleCount > 1 then (LEDGE.ClimbInsetMax - LEDGE.ClimbInsetMin) / (sampleCount - 1) else 0

	for index = 0, sampleCount - 1 do
		local inset = LEDGE.ClimbInsetMin + insetStep * index
		local scanOrigin = edgePosition + flatForward * inset + UP * LEDGE.ClimbSurfaceScanAbove
		local hit =
			castScanRay(scanOrigin, Vector3.new(0, -(LEDGE.ClimbSurfaceScanAbove + LEDGE.ClimbSurfaceScanBelow), 0))
		if hit then
			local permissions = ParkourTagging.GetPermissions(hit.Instance, now)
			if not permissions.Ignored and ParkourMath.SlopeAngle(hit.Normal) <= SLOPE.MaxWalkableAngleDegrees then
				local headroom = castScanRay(hit.Position + UP * 0.3, UP * LEDGE.ClimbSurfaceHeadroom)
				if headroom == nil then
					return true, hit.Position, hit.Normal
				end
			end
		end
	end

	return false, edgePosition, UP
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
	validationUsed = 0
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
		-- The direction the diagonal fallback leans toward. Travel rather than facing, because the case it
		-- serves is arriving at a surface -- what matters is where the body is GOING, and under shift lock
		-- facing is the camera rather than the flight. Falls back to facing when there is no travel, which
		-- is the same composite `travelDirection` above already resolved.
		local forward = ParkourMath.SafeUnit(ParkourMath.Flatten(travelDirection), Vector3.zero)
		-- Never during a wall-RUN, which is the one state that reads these probes as a CONTINUING contact
		-- rather than as a search. States/WallRunning re-derives its tangent from the live normal every
		-- frame precisely so a corner ends the run instead of the run clipping through it -- and a fallback
		-- that answers "the straight cast lost the wall" with a perpendicular wall further ahead would
		-- swing that tangent ninety degrees and carry the run around the corner, which is the exact
		-- behavior that file's header rules out.
		--
		-- EXCEPT WHILE THAT SAME STATE IS CATCHING, which is the opposite case in every particular the
		-- paragraph above turns on: the wall a catch holds IS the one dead ahead (the only thing this
		-- fallback can see), it re-derives no tangent, and it has no corner pivot to mislead. The
		-- exemption is not a loosening -- without it the catch could not exist at all. It entered from
		-- Falling, where the fallback is live, and then lost its own wall on the very next frame once the
		-- current state had become WallRunning and the fallback switched off; a one-frame catch reads in
		-- play as exactly the bounce it was built to replace. See ParkourContext.WallCatchActive.
		local wallRunSearching = context.CurrentStateId ~= "WallRunning" or context.WallCatchActive
		local allowDiagonal = not ground.Grounded and forward.Magnitude > 0 and wallRunSearching
		probeWall(wallLeft, wallLockLeft, rootPart, -right, travelDirection, forward, allowDiagonal, now)
		probeWall(wallRight, wallLockRight, rootPart, right, travelDirection, forward, allowDiagonal, now)
	elseif tooSlowToCare and not wantWalls then
		clearWall(wallLeft, now)
		clearWall(wallRight, now)
		SurfaceLock.Reset(wallLockLeft)
		SurfaceLock.Reset(wallLockRight)
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
			-- Raw MoveDirection/MoveIntent, NOT the `travelDirection` composite above -- that composite
			-- already folded in the facing fallback for the obstacle/wall probes, and probeLedge's own
			-- header explains why an automatic, no-button grab is the one place that fallback has to stop
			-- before it reaches facing.
			probeLedge(rootPart, context.MoveDirection, context.MoveIntent, context.VerticalVelocity, now)
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

-- How many of those casts were VALIDATION casts (the surface-stability cross-checks), out of
-- Probe.MaxValidationRaysPerFrame -- read by the debug overlay beside the total.
function EnvironmentProbe.GetLastValidationRayCount(): number
	return validationUsed
end

-- The surfaces the wall probes are HOLDING, for the debug overlay and for specs: left, right. Returned by
-- reference under the same read-immediately contract as GetResults.
function EnvironmentProbe.GetWallLocks(): (SurfaceLock.Lock, SurfaceLock.Lock)
	return wallLockLeft, wallLockRight
end

function EnvironmentProbe.GetFootOffset(): number
	return footOffset
end

function EnvironmentProbe.GetBoundCharacter(): Model?
	return boundCharacter
end

return EnvironmentProbe
