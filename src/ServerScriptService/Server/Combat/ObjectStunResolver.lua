--!strict
--[[
	ObjectStunResolver.lua

	Owns: detecting that a knocked-back target actually COLLIDED with world geometry BECAUSE of the
	move that hit them, and reporting it. The runtime behind Types.ObjectStunConfig -- see that
	type's own header for the authored knobs; this file is how they're enforced.

	The hard part is not "is there a wall there." It's causation. A naive proximity check fires
	constantly for anyone fighting with their back to a building, which makes the mechanic read as
	random rather than earned, and once it reads as random players stop trying to set it up. This
	module therefore never asks "is the target near a surface"; it asks "did this move throw them
	into one," and answers it with four independent gates, all authored per move:

	  1. CLEARANCE, checked once at Watch time. The target's own body volume is swept along the
	     direction they are about to be thrown, out to RequiredClearanceStuds. If it already finds a
	     qualifying surface, the watch is REFUSED outright -- a target already against the wall cannot
	     be knocked into it. This is the gate that kills the "standing next to a wall" false positive.
	  2. TRAVEL, checked every tick. The target must have moved MinTravelStuds from where they stood
	     when hit before any contact counts.
	  3. SPEED, checked at contact. They must still be moving at MinImpactSpeed. See `arrivalSpeed`
	     below for why the PREVIOUS tick's speed counts too -- the physics solver frequently stops a
	     body dead on the same frame the contact happens.
	  4. ANGLE, checked at contact. The angle between their travel direction and the surface's inward
	     normal must be within MaxImpactAngleDegrees, which rules out scraping ALONG a wall.

	CONTACT IS VOLUMETRIC. A body is not a line, and this module used to probe as though it were: one
	Workspace:Raycast from the root part's CENTRE along the travel direction. A target thrown
	shoulder-first into a pillar edge, or into a surface their centre line misses by a stud, reported
	no contact whatsoever -- so the mechanic went quiet in exactly the dramatic cases it exists for.
	Both probes now sweep a SPHERE sized from the target's own root part (probeRadiusFor).

	Sphere rather than box, deliberately, for three reasons:
	  * A ragdolled body tumbles. Workspace:Blockcast sweeps a box at ONE fixed orientation for the
	    whole cast, so feeding it the root part's live CFrame would change the swept cross-section
	    every frame -- the same geometry would register on one tick and not the next. A sphere has no
	    orientation at all, so contact is a pure function of position and radius.
	  * The clearance probe (registration, body upright and still) and the impact probe (mid-flight,
	    body tumbling) MUST agree about what counts as a surface in the way, or a move can refuse a
	    watch for a wall it would then never have triggered on. Rotation invariance makes that
	    agreement structural rather than something the two call sites have to maintain by hand.
	  * Deriving a box orientation from the travel direction instead is degenerate for a straight-up
	    or straight-down throw, and would need the box's own dimensions to change with it.

	A shape cast reports NOTHING for geometry it BEGINS already intersecting, and "nothing" is
	indistinguishable from "the way is clear" while meaning the exact opposite. Two things handle that
	here rather than letting it read as no contact:
	  * Every sweep starts a full body radius plus ProbePaddingStuds BEHIND the target and adds that
	    same distance to its length (sweepForContact). A surface the target is already touching then
	    sits at a short but non-zero distance from the sweep's origin -- an ordinary hit -- instead of
	    inside the sphere at frame zero. Without that offset the impact probe would go blind at the
	    exact moment of contact, which is the one moment it exists for. The space the offset occupies
	    is the space the target has just flown through, so it is empty by construction.
	  * The clearance probe additionally asks the question directly, as an overlap test
	    (findOverlappingContact). It is a backstop, not the primary answer: the sweep above already
	    covers a target merely touching a surface. It is kept because it is free (once per watch,
	    never per tick) and because it makes the refusal correct no matter which way the engine
	    resolves an initial intersection -- and for a gate whose entire job is to REFUSE, an extra
	    refusal is the safe direction to be wrong in.

	There is deliberately no equivalent per-tick backstop on the impact probe. An overlap test has no
	direction of its own, so it has to derive a normal from the closest point on the surface -- which
	is only unambiguously outward while the body is still OUTSIDE that surface. A body already buried
	in a wall, the one case a per-tick backstop would be for, is exactly the case where that normal's
	sign is not knowable, and a mechanic that fires on a guessed impact angle is worse than one that
	misses. The lookahead (speed * deltaTime + ProbeDistanceStuds) is what catches that body a tick
	earlier, on approach, while it is still in open air.

	Structured exactly like HitboxResolver: fire-and-forget registration (Watch), an internal array of
	in-flight records, and a single Update(deltaTime, now) that CombatSystem drives from its one
	existing Heartbeat connection -- no RunService connection of its own, no Init(), no boot order.
	Like that module it is also deliberately ignorant of the domain: it never learns what a Player, a
	CombatState, damage, or an animation is. It reports an ImpactReport through the caller's own
	OnImpact callback and CombatSystem decides what that means. In particular nothing here requires an
	attacker to be a Player -- AttackerPlayer/AttackerRootPart are carried through untouched and never
	read, and the cooldown/swing budgets are keyed by opaque strings -- so a bot or a dummy is watched
	exactly like a player if its caller chooses to register one.

	TIME COMES FROM THE CALLER, on both entry points: Watch(config, now) and Update(deltaTime, now).
	Reading os.clock() internally would let two calls in the same frame disagree about "now" (the
	cooldown a hit writes and the cooldown the next hit of the same swing reads), and would make the
	cooldown/cap behaviour untestable without sleeping.

	Cooldowns and trigger caps are enforced here rather than by the caller, because both are
	fundamentally about watches this module already tracks (a per-attacker-and-move cooldown, and a
	per-throw cap across however many victims one swing launched). Both are keyed by opaque strings
	the caller supplies, which is what keeps "what is an attacker" out of this file.

	Does not own: applying the stun, the bonus damage, the pin, the animations, or the follow-up
	attack (CombatSystem.lua), nor what counts as a legal target in the first place (the hit that
	launched them already resolved that).
]]

local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local Logger = require(ReplicatedStorage.Shared.Logger)

local ObjectStunResolver = {}

local logger = Logger.scope("ObjectStunResolver")

local Tuning = Constants.Combat.ObjectStun

export type SurfaceKind = "Wall" | "Floor" | "Ceiling" | "Prop"

-- Everything CombatSystem needs to react to a confirmed impact. Deliberately carries the whole
-- authored Config back out rather than expecting the caller to have kept it: the caller registered
-- the watch potentially seconds earlier, from a definition it no longer holds.
export type ImpactReport = {
	Target: Model,
	TargetRootPart: BasePart,
	AttackerPlayer: Player?,
	AttackerRootPart: BasePart?,
	MoveId: string,
	Config: Types.ObjectStunConfig,

	Surface: SurfaceKind,
	HitPart: BasePart,
	HitPosition: Vector3,
	-- Points OUT of the surface, toward where the target came from -- so the pin/rebound directions
	-- are +HitNormal and the "how head-on was this" test is against -HitNormal.
	HitNormal: Vector3,
	ImpactSpeed: number,
	ImpactAngleDegrees: number,
	TravelStuds: number,
	ElapsedSeconds: number,
	-- Radius of the sphere the contact was found with -- i.e. this module's approximation of the
	-- target's own body. Reported so a caller placing the body against the surface (the pin) can work
	-- from the same figure the detection used instead of assuming a body size of its own.
	ProbeRadiusStuds: number,
}

export type WatchConfig = {
	Target: Model,
	TargetRootPart: BasePart,
	AttackerPlayer: Player?,
	AttackerRootPart: BasePart?,
	MoveId: string,
	Config: Types.ObjectStunConfig,
	-- Direction the knockback is about to throw the target. Used for the clearance probe at
	-- registration, and as the fallback travel direction on a tick where the solver has already
	-- zeroed the target's velocity. Normalised on entry, so a caller that hands over an unscaled
	-- vector can't silently stretch every probe this watch ever casts.
	LaunchDirection: Vector3,
	-- Opaque key the per-move cooldown is tracked under (CombatSystem uses attacker + move id).
	CooldownKey: string,
	-- Opaque key MaxTriggersPerMove is counted under -- one per THROW, so a swing that launches
	-- three targets shares one budget across all three.
	SwingKey: string,
	-- Never treated as an impact surface: at minimum the target's own character and the attacker's.
	IgnoreInstances: { Instance },
	OnImpact: (ImpactReport) -> (),
}

-- One qualifying surface contact, whichever probe found it. Both the sweep and the overlap test
-- normalise into this so the speed/angle gates and the report are built in exactly one place --
-- otherwise the two probes would each need their own copy of gates 3 and 4 and could drift apart.
type SurfaceContact = {
	Part: BasePart,
	Position: Vector3,
	Normal: Vector3,
}

type Watch = {
	config: WatchConfig,
	raycastParams: RaycastParams,
	-- Normalised copy of config.LaunchDirection, and the sphere radius derived from the target's own
	-- root part. Both resolved once at registration: the root part's size cannot change mid-flight in
	-- any way this mechanic cares about, and recomputing them per tick would be pure waste.
	launchDirection: Vector3,
	probeRadius: number,
	startPosition: Vector3,
	lastPosition: Vector3,
	-- Last tick's speed, kept for exactly one frame -- see arrivalSpeed below.
	previousSpeed: number,
	elapsed: number,
	deadline: number,
}

-- Dense array, never a hash map with holes: Update walks it every Heartbeat, and removal is a
-- swap-with-last inside a reverse loop (removeWatchAt) so that walk stays a straight numeric
-- iteration no matter how many watches retire mid-tick.
local watches: { Watch } = {}

-- Per-CooldownKey timestamp before which this move may not object-stun again, and per-SwingKey
-- trigger tally with its own expiry so a completed throw's entry doesn't linger.
local cooldownUntil: { [string]: number } = {}
local triggersBySwing: { [string]: { count: number, expiresAt: number } } = {}

-- Earliest expiry across BOTH tables above, or math.huge when neither holds anything that can
-- expire. Sweeping those tables is a full walk of each; doing it every Heartbeat meant paying for
-- that walk on the overwhelming majority of ticks where nothing had expired at all. The watermark
-- makes the sweep amortised: Update pays one number comparison per tick and only walks when
-- something is genuinely due.
local nextBookkeepingExpiry = math.huge

-- Below this the direction is treated as unusable and the launch direction is substituted -- see
-- resolveTravelDirection. A body genuinely arrested by a collision reports a velocity in this
-- range, which is precisely the case that must not be read as "travelling toward (0,0,0)".
local MIN_DIRECTION_MAGNITUDE = 1e-3

local function newRaycastParams(ignoreInstances: { Instance }): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignoreInstances
	params.IgnoreWater = true
	-- Non-collidable decoration (foliage, banners, effect parts) never stops a thrown body
	-- physically, so it must not count as an impact surface either -- otherwise the mechanic would
	-- fire on things the player watched the victim pass straight through.
	params.RespectCanCollide = true
	return params
end

-- The overlap test's filter has to be the SAME filter the sweep uses, for the same reason the two
-- probes share qualification and cast shape: an exclusion list or a CanCollide rule that applied to
-- only one of them would let a surface count as blocking in one probe and invisible in the other.
local function newOverlapParams(ignoreInstances: { Instance }): OverlapParams
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignoreInstances
	params.RespectCanCollide = true
	return params
end

-- Radius of the sphere both probes sweep, taken from the target's OWN root part so a boss, a player
-- and a training dummy are each approximated by their own body rather than by one hardcoded figure.
-- The largest half-extent (not a per-axis choice) because the sphere itself is orientation-free:
-- picking, say, the horizontal axes would make the radius depend on which way a tumbling body
-- happens to be facing, reintroducing exactly the frame-to-frame instability the sphere avoids.
local function probeRadiusFor(rootPart: BasePart): number
	local size = rootPart.Size
	local largestHalfExtent = math.max(size.X, size.Y, size.Z) * 0.5
	return math.clamp(largestHalfExtent, Tuning.MinProbeRadiusStuds, Tuning.MaxProbeRadiusStuds)
end

-- Prop is decided from the PART (unanchored = a loose object), everything else from the surface's
-- own normal. That ordering matters: a crate should read as a prop whichever of its faces was
-- struck, whereas a ramp steeper than the threshold should read as a wall regardless of what it is.
--
-- Note the interaction with Config.RequireAnchored: with it on (the default), an unanchored part is
-- rejected before ever reaching here, so "Prop" is only reachable by a move that deliberately turned
-- RequireAnchored off. That pairing is intentional -- a move about smashing someone through scenery
-- has to opt out of the "only solid world geometry counts" rule to do it.
local function classifySurface(part: BasePart, normal: Vector3): SurfaceKind
	if not part.Anchored then
		return "Prop"
	end
	if normal.Y >= Tuning.SurfaceNormalYThreshold then
		return "Floor"
	end
	if normal.Y <= -Tuning.SurfaceNormalYThreshold then
		return "Ceiling"
	end
	return "Wall"
end

local function surfaceAllowed(config: Types.ObjectStunConfig, kind: SurfaceKind): boolean
	if kind == "Floor" then
		return config.Surfaces.Floors
	elseif kind == "Ceiling" then
		return config.Surfaces.Ceilings
	elseif kind == "Prop" then
		return config.Surfaces.Props
	end
	return config.Surfaces.Walls
end

-- "Is this part big enough to plausibly stop a thrown body." Tests the SECOND largest extent, not
-- the smallest: a wall is legitimately thin on one axis (a 1 x 20 x 20 slab is a wall, not a twig),
-- so requiring all three axes to clear the bar would reject exactly the geometry this mechanic is
-- most about. Requiring the two largest to clear it means "the face you hit is at least this big in
-- both directions," which is the real question.
local function isLargeEnough(part: BasePart, minimumExtent: number): boolean
	if minimumExtent <= 0 then
		return true
	end
	local size = part.Size
	local largest = math.max(size.X, size.Y, size.Z)
	local smallest = math.min(size.X, size.Y, size.Z)
	local middle = size.X + size.Y + size.Z - largest - smallest
	return middle >= minimumExtent
end

local function hasRequiredTag(part: BasePart, tag: string): boolean
	if tag == "" then
		return true
	end
	if CollectionService:HasTag(part, tag) then
		return true
	end
	-- Walked up rather than checked on the part alone: a level designer tags the MODEL ("this
	-- building is slam-worthy"), not each of its forty parts.
	local ancestor: Instance? = part.Parent
	while ancestor and ancestor ~= Workspace do
		if CollectionService:HasTag(ancestor, tag) then
			return true
		end
		ancestor = ancestor.Parent
	end
	return false
end

-- Every non-directional filter a candidate surface must pass, shared by the clearance probe at
-- registration and the impact test each tick, and by both the sweep and the overlap test within
-- each of those -- all four paths must agree on what "a qualifying surface" is, or a move could
-- refuse to start a watch against a wall it would then never trigger on (or worse, the reverse).
local function partQualifies(part: BasePart, normal: Vector3, config: Types.ObjectStunConfig): boolean
	if config.RequireAnchored and not part.Anchored then
		return false
	end
	if not hasRequiredTag(part, config.RequirePartTag) then
		return false
	end
	if not isLargeEnough(part, config.MinSurfaceExtentStuds) then
		return false
	end
	return surfaceAllowed(config, classifySurface(part, normal))
end

local function contactFromResult(result: RaycastResult, config: Types.ObjectStunConfig): SurfaceContact?
	local part = result.Instance
	if not part:IsA("BasePart") then
		return nil
	end
	if not partQualifies(part, result.Normal, config) then
		return nil
	end
	return { Part = part, Position = result.Position, Normal = result.Normal }
end

-- Sweeps the target's body volume `reachStuds` further along `direction` than the target's own
-- centre already is. The backwards offset and the matching addition to the cast length are what stop
-- a surface the target is ALREADY touching from sitting inside the sphere at frame zero, where a
-- shape cast reports nothing at all -- see this file's header. `reachStuds` therefore keeps meaning
-- exactly what its authored sources say: studs measured forward from the target.
local function sweepForContact(
	position: Vector3,
	direction: Vector3,
	reachStuds: number,
	radius: number,
	raycastParams: RaycastParams
): RaycastResult?
	local backOff = radius + Tuning.ProbePaddingStuds
	return Workspace:Spherecast(
		position - direction * backOff,
		radius,
		direction * (backOff + reachStuds),
		raycastParams
	)
end

-- The direct form of the same question the clearance sweep asks (see the header for why it is asked
-- twice, and why only there). Unlike a sweep an overlap test has no direction of its own, so
-- surfaces BEHIND the target are filtered out explicitly here -- without that, a target with their
-- back to a building would be refused a watch for the wall behind them while being thrown into open
-- ground, which is the precise opposite of what the clearance gate is for.
local function findOverlappingContact(
	position: Vector3,
	direction: Vector3,
	radius: number,
	config: Types.ObjectStunConfig,
	overlapParams: OverlapParams
): SurfaceContact?
	for _, instance in ipairs(Workspace:GetPartBoundsInRadius(position, radius, overlapParams)) do
		if not instance:IsA("BasePart") then
			continue
		end
		local surfacePoint = instance:GetClosestPointOnSurface(position)
		local outward = position - surfacePoint
		local gap = outward.Magnitude
		-- GetPartBoundsInRadius answers with bounding boxes, so a part whose real geometry never
		-- reaches the sphere still comes back; the closest surface point is what makes this exact.
		-- A zero-length outward vector (centre exactly on, or inside, the surface) is skipped rather
		-- than guessed at: with no usable normal the surface can neither be classified nor
		-- angle-tested, and a body that deep into geometry was already probed on approach.
		if gap <= MIN_DIRECTION_MAGNITUDE or gap > radius then
			continue
		end
		local normal = outward / gap
		if normal:Dot(direction) >= 0 then
			continue
		end
		if partQualifies(instance, normal, config) then
			return { Part = instance, Position = surfacePoint, Normal = normal }
		end
	end
	return nil
end

-- Which way the target is actually travelling this tick. Prefers live velocity; falls back to the
-- frame's own position delta, then to the original launch direction. Both fallbacks exist for the
-- same reason: on the frame a body collides, the solver has often already zeroed its velocity, and
-- a zero vector's .Unit is NaN -- reading that as a direction would produce a garbage probe and,
-- worse, a garbage impact angle that might pass the head-on test by accident.
local function resolveTravelDirection(watch: Watch, velocity: Vector3, currentPosition: Vector3): Vector3
	if velocity.Magnitude > MIN_DIRECTION_MAGNITUDE then
		return velocity.Unit
	end
	local frameDelta = currentPosition - watch.lastPosition
	if frameDelta.Magnitude > MIN_DIRECTION_MAGNITUDE then
		return frameDelta.Unit
	end
	return watch.launchDirection
end

local function recordExpiry(expiresAt: number): ()
	if expiresAt < nextBookkeepingExpiry then
		nextBookkeepingExpiry = expiresAt
	end
end

-- Registers a target to be watched for an object impact. `now` is the caller's own clock (the same
-- one it passes to Update), never read from os.clock() here -- see this file's header. Returns
-- (accepted, reason) -- a refusal is entirely normal and never an error: the hit that triggered it
-- still lands and resolves as usual, the target simply doesn't get the object-stun reaction. Reasons
-- are returned rather than logged at warn level for exactly that reason, and so the specs can assert
-- on them.
function ObjectStunResolver.Watch(config: WatchConfig, now: number): (boolean, string?)
	local stunConfig = config.Config
	if not stunConfig.Enabled then
		return false, "Disabled"
	end
	if not config.TargetRootPart.Parent or not config.Target.Parent then
		return false, "NoTarget"
	end

	-- Spelled as "not (magnitude > epsilon)" rather than "magnitude <= epsilon" so a NaN component
	-- refuses too: every comparison involving NaN is false, so the negated form catches it while the
	-- direct form would wave it through. A watch built on an unusable direction is not merely
	-- inert -- it probes along a garbage axis for its whole life while holding one of the
	-- MaxActiveWatches slots.
	local launchMagnitude = config.LaunchDirection.Magnitude
	if not (launchMagnitude > MIN_DIRECTION_MAGNITUDE) then
		return false, "InvalidLaunchDirection"
	end
	local launchDirection = config.LaunchDirection / launchMagnitude

	local readyAt = cooldownUntil[config.CooldownKey]
	if readyAt and now < readyAt then
		return false, "CooldownActive"
	end

	local tally = triggersBySwing[config.SwingKey]
	if tally and tally.count >= stunConfig.MaxTriggersPerMove then
		return false, "TriggerCapReached"
	end

	-- A hard ceiling on concurrent watches, since each one is a shape cast per tick. Declining past
	-- it degrades this one mechanic in a large brawl instead of everyone's frame time -- the same
	-- "bound the worst case rather than let it scale with population" reasoning
	-- Constants.Combat.Hitboxes.MaxCandidateRadius applies to candidate gathering.
	if #watches >= Tuning.MaxActiveWatches then
		return false, "TooManyWatches"
	end

	local raycastParams = newRaycastParams(config.IgnoreInstances)
	local origin = config.TargetRootPart.Position
	local probeRadius = probeRadiusFor(config.TargetRootPart)

	-- GATE 1, the causation check that matters most -- see this file's header, including why the
	-- same question is asked in two forms here and in only one form per tick.
	if stunConfig.RequiredClearanceStuds > 0 then
		local swept =
			sweepForContact(origin, launchDirection, stunConfig.RequiredClearanceStuds, probeRadius, raycastParams)
		if swept and contactFromResult(swept, stunConfig) then
			return false, "AlreadyAgainstSurface"
		end
		local overlapParams = newOverlapParams(config.IgnoreInstances)
		if findOverlappingContact(origin, launchDirection, probeRadius, stunConfig, overlapParams) then
			return false, "AlreadyAgainstSurface"
		end
	end

	table.insert(watches, {
		config = config,
		raycastParams = raycastParams,
		launchDirection = launchDirection,
		probeRadius = probeRadius,
		startPosition = origin,
		lastPosition = origin,
		previousSpeed = 0,
		elapsed = 0,
		deadline = math.min(stunConfig.MaxTravelSeconds, Tuning.MaxWatchSeconds),
	})
	return true, nil
end

-- Swap-with-last, not table.remove: order between watches is meaningless, and every caller iterates
-- backwards, so the element moved down into `index` has always been visited already this pass.
local function removeWatchAt(index: number): ()
	local last = #watches
	watches[index] = watches[last]
	watches[last] = nil
end

local function pruneBookkeeping(now: number): ()
	if now < nextBookkeepingExpiry then
		return
	end

	local earliest = math.huge
	for key, readyAt in pairs(cooldownUntil) do
		if now >= readyAt then
			cooldownUntil[key] = nil
		elseif readyAt < earliest then
			earliest = readyAt
		end
	end
	for key, tally in pairs(triggersBySwing) do
		if now >= tally.expiresAt then
			triggersBySwing[key] = nil
		elseif tally.expiresAt < earliest then
			earliest = tally.expiresAt
		end
	end
	nextBookkeepingExpiry = earliest
end

-- Re-checked at impact, not only at registration: a swing that launched several targets registers
-- all of their watches up front, and whichever one lands first is the one that spends the budget.
-- Returns false when the budget is already gone, in which case the caller retires the watch without
-- reporting anything.
local function spendBudgets(watch: Watch, now: number): boolean
	local config = watch.config
	local stunConfig = config.Config

	local readyAt = cooldownUntil[config.CooldownKey]
	if readyAt and now < readyAt then
		return false
	end
	local tally = triggersBySwing[config.SwingKey]
	if tally and tally.count >= stunConfig.MaxTriggersPerMove then
		return false
	end

	if stunConfig.CooldownSeconds > 0 then
		local readyAgainAt = now + stunConfig.CooldownSeconds
		cooldownUntil[config.CooldownKey] = readyAgainAt
		recordExpiry(readyAgainAt)
	end
	-- Outlives any watch that could still be counting against it, so the cap holds for the whole
	-- throw and the entry then disappears on its own.
	local expiresAt = now + Tuning.MaxWatchSeconds
	triggersBySwing[config.SwingKey] = {
		count = (if tally then tally.count else 0) + 1,
		expiresAt = expiresAt,
	}
	recordExpiry(expiresAt)
	return true
end

-- One watch, one tick: advances its bookkeeping and answers with a full report only if all four
-- gates cleared. Returning nil means "still watching" -- expiry and target liveness are the caller's
-- to decide, since only it can retire the record.
local function advanceWatch(watch: Watch, deltaTime: number): ImpactReport?
	local config = watch.config
	local stunConfig = config.Config
	local rootPart = config.TargetRootPart

	local position = rootPart.Position
	local velocity = rootPart.AssemblyLinearVelocity
	local speed = velocity.Magnitude
	local travel = (position - watch.startPosition).Magnitude
	-- Read before the per-tick bookkeeping below overwrites them, since both feed the gates.
	local previousSpeed = watch.previousSpeed
	local direction = resolveTravelDirection(watch, velocity, position)

	watch.lastPosition = position
	watch.previousSpeed = speed

	-- GATE 2. Checked before any cast, so a target who hasn't been carried anywhere yet costs
	-- nothing beyond this comparison.
	if travel < stunConfig.MinTravelStuds then
		return nil
	end

	-- Clamped because deltaTime is not bounded: one long frame multiplied by a launch speed would
	-- otherwise sweep tens of studs ahead and report a collision with a wall the target is nowhere
	-- near yet.
	local reach = math.min(speed * deltaTime + stunConfig.ProbeDistanceStuds, Tuning.MaxProbeDistanceStuds)
	local swept = sweepForContact(position, direction, reach, watch.probeRadius, watch.raycastParams)
	local contact = if swept then contactFromResult(swept, stunConfig) else nil

	-- The tick something STOPPED them: a sweep that found nothing here is not trustworthy, because a
	-- body driven into a surface ends up overlapping it and a shape cast that starts overlapping
	-- reports nothing at all. Gated on the speed collapse so the ordinary ticks of a flight -- where
	-- the sweep's own answer is sound -- never pay for the overlap query.
	if
		contact == nil
		and previousSpeed >= stunConfig.MinImpactSpeed
		and speed < previousSpeed * Tuning.ArrestSpeedFraction
	then
		contact = findOverlappingContact(position, direction, watch.probeRadius, stunConfig, watch.overlapParams)
	end

	if contact == nil then
		return nil
	end

	-- GATE 3. The previous tick's speed counts because the physics solver very often arrests a body
	-- on the exact frame the contact happens -- by the time this code reads AssemblyLinearVelocity
	-- the collision has already consumed it, and judging the impact on the leftover would reject
	-- precisely the hardest slams. One frame of memory is enough for that case while still rejecting
	-- a target who genuinely decelerated over many frames.
	local arrivalSpeed = math.max(speed, previousSpeed)
	if arrivalSpeed < stunConfig.MinImpactSpeed then
		return nil
	end

	-- GATE 4. Zero degrees is dead-on into the surface; ninety is sliding along it.
	local headOn = math.clamp(direction:Dot(-contact.Normal), -1, 1)
	local impactAngle = math.deg(math.acos(headOn))
	if impactAngle > stunConfig.MaxImpactAngleDegrees then
		return nil
	end

	return {
		Target = config.Target,
		TargetRootPart = rootPart,
		AttackerPlayer = config.AttackerPlayer,
		AttackerRootPart = config.AttackerRootPart,
		MoveId = config.MoveId,
		Config = stunConfig,

		Surface = classifySurface(contact.Part, contact.Normal),
		HitPart = contact.Part,
		HitPosition = contact.Position,
		HitNormal = contact.Normal,
		ImpactSpeed = arrivalSpeed,
		ImpactAngleDegrees = impactAngle,
		TravelStuds = travel,
		ElapsedSeconds = watch.elapsed,
		ProbeRadiusStuds = watch.probeRadius,
	}
end

-- Call once per Heartbeat from CombatSystem.lua, alongside HitboxResolver.Update. Advances every
-- in-flight watch: drops it once its deadline passes or its target stops existing; otherwise probes
-- ahead along the target's travel direction and, on a qualifying contact that clears all four gates,
-- fires OnImpact exactly once and retires the watch.
function ObjectStunResolver.Update(deltaTime: number, now: number): ()
	pruneBookkeeping(now)

	-- Backwards so removeWatchAt's swap-with-last can never move an unvisited watch past the cursor,
	-- and so a handler that registers new watches (a follow-up attack can land its own hits) appends
	-- beyond it rather than into this pass.
	for index = #watches, 1, -1 do
		local watch = watches[index]
		local config = watch.config

		if not config.TargetRootPart.Parent or not config.Target.Parent then
			removeWatchAt(index)
			continue
		end

		watch.elapsed += deltaTime
		if watch.elapsed > watch.deadline then
			-- Expired untriggered. The single most important non-event in this module: it is what
			-- stops a target who was knocked back, recovered, and later walked into a wall from
			-- setting the mechanic off.
			removeWatchAt(index)
			continue
		end

		local report = advanceWatch(watch, deltaTime)
		if report == nil then
			continue
		end

		-- Retired and the budgets spent BEFORE OnImpact, so a handler that itself throws a follow-up
		-- attack (which can land its own hits, which can register their own watches) can never
		-- re-enter this loop against a watch that is still live.
		removeWatchAt(index)
		if not spendBudgets(watch, now) then
			continue
		end

		logger:debug("Object stun impact", {
			moveId = config.MoveId,
			target = config.Target.Name,
			surface = report.Surface,
			part = report.HitPart.Name,
			speed = math.floor(report.ImpactSpeed),
			angle = math.floor(report.ImpactAngleDegrees),
			travel = math.floor(report.TravelStuds),
		})

		config.OnImpact(report)
	end
end

-- Drops every watch belonging to one target -- called when a target dies, respawns, or is otherwise
-- no longer a coherent thing to slam into a wall. Their root part usually disappears with them
-- (which Update already handles), but a respawn reuses the character model name while replacing the
-- parts, and a stale watch holding the OLD root would keep probing from wherever that corpse was.
function ObjectStunResolver.ClearTarget(target: Model): ()
	for index = #watches, 1, -1 do
		if watches[index].config.Target == target then
			removeWatchAt(index)
		end
	end
end

function ObjectStunResolver.ActiveWatchCount(): number
	return #watches
end

-- Full teardown. Exists for the specs, which need each `it` to start from a known-empty resolver --
-- the same reason MoveRegistryManager.Init() clears its own table rather than assuming a fresh
-- module instance per test.
function ObjectStunResolver.Reset(): ()
	watches = {}
	cooldownUntil = {}
	triggersBySwing = {}
	nextBookkeepingExpiry = math.huge
end

return ObjectStunResolver
