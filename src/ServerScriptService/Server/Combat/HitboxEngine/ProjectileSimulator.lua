--!strict
--[[
	ProjectileSimulator.lua

	Owns: every projectile in flight -- launching a volley when a projectile attack's Active window opens,
	flying it (ProjectileMotion), sweeping it against registered bodies and world geometry, homing,
	piercing, bouncing, and what a parry or an evade does to a shot after the defence layer has judged
	the contact. Created and driven by HitboxEngine.lua; nothing else requires it.

	PART OF THE ENGINE, NOT A LAYER BESIDE IT. HitboxEngine owns "where an attack's damage volume is and
	who is inside it", and a projectile is exactly a damage volume that moves. So a shot's contacts leave
	through the engine's own reporter as ordinary HitReports (plus HitReport.Projectile), in the engine's
	own substep loop -- ascending SampleTime alongside every swing's contacts, which is the order
	DefenseSystem's pass 1 depends on -- and every layer above classifies and prices them with no second
	path: DefenseSystem decides clean/blocked/parried/evaded, DamageSystem applies health, guard, hitstun,
	combo and knockback. There is no damage, parry or block logic in this file.

	SWEPT, BOTH WAYS. Each step moves a shot from where it was to where it will be, and tests that whole
	segment: against bodies (CandidateGatherer's hurtbox broadphase, then HitboxGeometry's own
	containment -- the same narrow phase a swing uses), and against the world as a Spherecast. A fast shot
	cannot tunnel through a body or a wall between two samples, whatever the frame rate.

	THE SHOT IS A VOLUME (2026-10-01, ProjectileBody). A plain sphere keeps its original path: the segment
	is a Capsule of the shot's radius. Any other Shape is swept as the shape itself -- HitboxGeometry's
	SweptContainsPoint between the body's pose at the start and the end of the step, the exact test a
	swinging hitbox gets -- with a bounding sphere around the segment for the broadphase, and the world cast
	moved to the body's leading edge with a radius of its thinnest half, so a long spear meets a wall with
	its tip rather than its middle.

	CONTACTS ALONG THE SEGMENT, NEAREST FIRST, each target once per shot (the per-shot HitTargets set is
	the same dedupe a swing's per-swing set is). A body in front of a wall is hit before the wall is.

	ONE VOLLEY, ONE HIT PER BODY (2026-10-27). A cast -- every shot, wave, split and burst of one GroupId -- is
	one attack, as a swing is: the first of its shots to reach a body is the volley's contact with that body,
	and the rest of the volley ignores that body (they fly on through it, exactly as a shot ignores a body
	in its own hit set) and still strike OTHER bodies once each. Whatever the defence layer then decides
	about that contact -- clean, blocked, parried, evaded -- is the volley's answer for that body. Without
	this a five-shot fan landed five priced hits, five combo steps and five ragdoll refreshes on one target,
	and every shot ended on the parrier in the frame before its parry could reach them (so ParryAll had
	nothing left to answer). The record is per thrower: a shot a parry hands to the parrier strikes for its
	new owner, so a reflected volley is one hit too. RehitSeconds reads across the volley as it reads for
	one shot; a shot's own repeat hits (its re-hit window, its way back home) are still its own HitTargets'.
	A realm's strikes are one LaunchVolley each, so each is its own volley -- a realm still lands one strike
	per pulse per target, and a Volley effect lands its move's volley once per pulse per target.

	WHAT A PARRY DOES TO A SHOT, which the defence layer asks for through HitboxEngine.ParryProjectile --
	the projectile counterpart of the CancelAttack it calls for a parried swing:
	  * ParryOne affects the shot parried; ParryAll every shot of the same volley still flying and still
	    owned by the thrower, every wave of it not yet fired, and every end effect (burst, split) of it still
	    waiting to resolve -- the whole volley is answered. (Shots of the volley that already ended -- consumed
	    by a block in the same batch, say -- stay ended: one parry window stops one attack, the rule
	    DefenseSystem already keeps.)
	  * ExistingParry and Destroy end the shot. Reflect and Reverse hand it to the parrier and send it
	    back -- a shot a contact already ended is brought back from where it ended (RetireGraceSeconds is
	    how long that stays possible). Its hit set, lifetime, range, pierces and bounces start over.

	WHAT AN EVADE DOES (HitboxEngine.PassProjectile): nothing, which takes undoing -- the contact already
	spent the shot (or one of its pierces), and an evaded shot flies on through, as an evaded swing does.

	A VOLLEY NOT THROWN BY A SWING (LaunchAimed, 2026-09-30) -- a realm's strike or volley
	(Server/Combat/Domain/DomainEffects.lua, through HitboxEngine.LaunchVolley). Identical flight and
	contacts; three launch options a swing never needs: a fixed homing TARGET, EXCLUSIVE (the shot can touch
	no body but that target -- a strike is delivered to one person, not to whoever stands in the line), and
	a DomainId stamped on its contacts (ProjectileContact.DomainId, opaque passthrough like DamageScale).

	THE BARRIER (SetBarrier). One optional slot, held by DomainSystem while a realm with a closed edge is
	up: asked once per shot per step whether that step may happen. A refused step ends the shot where it
	was ("Barrier"). An unset slot costs one nil check per step.

	WAVES ARE PENDING LAUNCHES (2026-10-26, ProjectileTypes' header). The first wave (or its first shot)
	launches when the window opens; every later one waits in `pending`, owned by its thrower, and fires on
	the substep its time comes -- re-aimed then (WaveAim Follow) or along the aim captured at the start
	(Fixed). One cast is one GroupId, so ParryAll answers every wave and split of it. A pending launch is
	dropped when its thrower is no longer a live registered body, and CancelPending (the engine calls it when
	a swing is INTERRUPTED) drops a swing's waves; a realm's (LaunchAimed) are not the swing's to cancel.

	END EFFECTS ARE DEFERRED TO THE NEXT FRAME (ResolveEndings). A shot that ends for a reason its ExplodeOn
	or SplitOn covers is retired with its effects PENDING and its End event held back; the engine calls
	ResolveEndings at the start of its next frame, after DefenseSystem has judged the contact that ended it.
	So an evade (Pass) revives the shot before it can burst, and a Destroy parry defuses it (it ends
	"Parried", no effect). Each shot resolves at most once per flight; a reflected shot flies anew and may
	burst again where it lands. The End event then goes out carrying Burst (the radius) when it burst. A
	parry resolved from DefenseSystem's rewind hold AFTER the burst cannot unburst it; that window is a frame
	or two, and the burst never strikes the parried body (it skips every body the shot struck).

	THE BURST is ordinary contacts: every registered body within ExplosionRadius whose hurtbox part is
	inside it, minus the bodies this shot already struck, its thrower (unless CanHitOwner) and anybody an
	Exclusive shot may not touch -- each reported once, unparryable, sourced at the blast's centre, and priced
	DamageScale x ExplosionDamageScale x falloff. THE SPLIT launches SplitCount children from where the shot
	ended -- along its heading, or off the surface for a wall -- sharing its GroupId, its hit set (so a child
	never strikes the body its parent just did) and its damage scale, one generation further on; nothing past
	SplitGenerations splits again, and MaxLive bounds the rest.

	A RETURNING SHOT (ReturnAfterSeconds) re-targets its thrower with ReturnMotionOf, clears its hit set
	(the way back may strike again), restarts its range from where it turned, says so in an Update tagged
	"Return" that carries the new Motion, and ends "Returned" within TUNING.ReturnCatchStuds of its thrower.

	TIME COMES FROM THE CALLER, the engine's rule: Step(dt, now) and every entry point take the engine's
	clock, so the specs fly shots on a synthetic one.

	Does not own: the vocabulary (ProjectileTypes), the motion math (ProjectileMotion), the replication of
	shots to clients (HitboxEngine hands Flush's events to its subscribers; the attack layer sends them),
	or anything about what a contact means.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local HitboxEngineConstants = require(ReplicatedStorage.Shared.HitboxEngine.HitboxEngineConstants)
local HitboxGeometry = require(ReplicatedStorage.Shared.HitboxEngine.HitboxGeometry)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)
local ProjectileBody = require(ReplicatedStorage.Shared.HitboxEngine.ProjectileBody)
local ProjectileMotion = require(ReplicatedStorage.Shared.HitboxEngine.ProjectileMotion)
local ProjectileTypes = require(ReplicatedStorage.Shared.HitboxEngine.ProjectileTypes)

local CandidateGatherer = require(script.Parent.CandidateGatherer)

type AttackDefinition = HitboxTypes.AttackDefinition
type Dimensions = HitboxTypes.Dimensions
type HitReport = HitboxTypes.HitReport
type ProjectileSpec = ProjectileTypes.ProjectileSpec

local logger = Logger.scope("ProjectileSimulator")

local ProjectileSimulator = {}

local TUNING = HitboxEngineConstants.Projectile
local EPSILON = 1e-4

-- What the simulator needs to know about a body: the same three Instances the engine registers.
export type Owner = {
	Model: Model,
	RootPart: BasePart,
	Humanoid: Humanoid,
}

-- The engine's side of the arrangement, bound once (HitboxEngine binds it at require time).
export type Hooks = {
	-- The registered combatant `part` belongs to, or nil.
	OwnerOf: (part: BasePart) -> Owner?,
	-- The registered combatant `model` is, or nil.
	CombatantOf: (model: Model) -> Owner?,
	-- Every registered combatant -- the candidates for homing and for an aimed volley. The engine's own
	-- registry is the server's list of who can be fought (the Combatant tag's source), so a target picked
	-- here is one the engine would report a contact on.
	Combatants: () -> { Owner },
	-- Hands one contact to the engine's OnHit subscribers.
	Report: (report: HitReport) -> (),
}

-- The barrier slot's signature (see this file's header): true refuses the step from `from` to `to`.
export type Barrier = (owner: Model, domainId: string?, from: Vector3, to: Vector3) -> boolean

-- What LaunchAimed takes beyond a swing's launch.
export type LaunchOptions = {
	-- The body every shot homes on from launch (the spec must home for it to steer).
	Target: Model?,
	-- The shot may touch no body but Target.
	Exclusive: boolean?,
	-- Stamped on every contact as ProjectileContact.DomainId.
	DomainId: string?,
	-- Starting damage scale (ProjectileContact.DamageScale): a contested realm's strikes land lighter.
	DamageScale: number?,
}

-- What clients are told, one event per change a client cannot work out for itself. Batched by Flush.
--   Launch  a shot starts flying -- a new one, or one a parry handed to someone else (same Id).
--   Update  the shot bounced, changed homing target, or is being re-stated so a homing visual
--           cannot drift. Position/Velocity are authoritative as of the event.
--   End     the shot is gone. Position is where.
export type EventKind = "Launch" | "Update" | "End"
export type ProjectileEvent = {
	Kind: EventKind,
	Id: number,
	GroupId: number,
	Position: Vector3,
	Velocity: Vector3,
	-- Seconds between the event and the end of the frame that flushed it, filled in by Flush -- so a
	-- client can fast-forward a visual by exactly how stale the event is.
	Lead: number,
	-- Launch only.
	Owner: Model?,
	MoveId: string?,
	Radius: number?,
	-- Launch only, and only for a shot that is not a plain sphere: the spec's body fields, from which a
	-- client builds the same ProjectileBody the server sweeps.
	Body: { [string]: any }?,
	LifetimeSeconds: number?,
	Motion: ProjectileMotion.Motion?,
	-- Launch only, and only for a shot the world does NOT simply destroy ("Bounce" or "Continue"): a client
	-- stops drawing a shot at the ground it meets, which is only right for the default Destroy.
	Walls: string?,
	-- Launch/Update: the homing target, if any.
	Target: Model?,
	-- End: "Hit", "World", "Range", "Expired", "Parried", "Owner", "Barrier" (a realm's closed edge),
	-- "Proximity" (its fuse), "Returned" (back in its thrower's hand). Update: "Bounce" when the update is a
	-- bounce off the world, "Return" when it turns for home (and then Motion is set), nil for a homing
	-- re-target/re-sync -- the one fact a client cannot derive from the new position and velocity alone, read
	-- only by presentation (a move's Bounce cue, MovePresentationTypes). It changes nothing the simulator or a
	-- layer above decides.
	Reason: string?,
	-- Launch/Update: the shot's age at the event, so a client weaves and gates homing on the same clock.
	Age: number?,
	-- End: the burst's radius, when the shot burst where it ended.
	Burst: number?,
	-- Internal: the engine clock at the event. Cleared by Flush.
	At: number?,
}

type Projectile = {
	Id: number,
	GroupId: number,
	Owner: Owner,
	Spec: ProjectileSpec,
	Motion: ProjectileMotion.Motion,
	DebugName: string,
	-- The volume the shot flies as (ProjectileBody), built once per volley and shared by its shots.
	Body: ProjectileBody.Body,
	ComboStage: number,
	PowerLevel: number,
	Position: Vector3,
	Velocity: Vector3,
	-- Seconds flown and studs travelled since launch (or since a parry sent it back). Travelled restarts,
	-- and Origin moves, when a returning shot turns for home: range is per leg.
	Age: number,
	Travelled: number,
	Origin: Vector3,
	PiercesLeft: number,
	BouncesLeft: number,
	-- Every body this shot has struck, and its Age when it last did (RehitSeconds reads it).
	HitTargets: { [Model]: number },
	Target: Owner?,
	-- Age at which a target-less homing shot next looks for one, and at which a homing shot is next
	-- re-stated to clients.
	RetargetAt: number,
	ResyncAt: number,
	-- Product of every Reflected multiplier this shot has picked up (ProjectileContact.DamageScale).
	DamageScale: number,
	-- A Reverse retraces the path; homing would bend it off it.
	NoHoming: boolean,
	-- Set when the shot ended; it is then retired until RetireGraceSeconds pass.
	EndedAt: number?,
	EndReason: string?,
	EndedOn: Model?,
	-- LaunchAimed's options (nil for a swing's volley). Exclusive pins the shot to Target: it never
	-- retargets and can touch no other body.
	Exclusive: Model?,
	DomainId: string?,
	-- 0 for a shot a cast launched, one more for each split it descends from.
	Generation: number,
	-- Turned for home (ReturnAfterSeconds).
	Returning: boolean,
	-- End effects (this file's header): Pending between the end and ResolveEndings; Done once resolved this
	-- flight; Defused by a parry that destroyed the shot. EndNormal is the wall's, for a split off it.
	EffectsPending: boolean,
	EffectsDone: boolean,
	Defused: boolean,
	EndNormal: Vector3?,
}

-- One launch still to come (this file's header, WAVES). Index nil fires the whole wave.
type PendingLaunch = {
	Owner: Owner,
	Anchor: BasePart,
	MirrorAnchor: BasePart,
	Definition: AttackDefinition,
	ComboStage: number,
	PowerLevel: number,
	GroupId: number,
	DueAt: number,
	Wave: number,
	Index: number?,
	-- The wave's aim, when it is fixed (WaveAim Fixed, or a realm's aimed volley); nil re-aims at fire time.
	Aim: CFrame?,
	Options: LaunchOptions?,
	-- A swing's waves, which CancelPending drops; a realm's are not.
	SwingBound: boolean,
}

-- One body a volley has struck (this file's header, ONE VOLLEY): by which shot, when on the engine clock,
-- and for which owner.
type VolleyStrike = {
	Id: number,
	At: number,
	By: Model,
}

local hooks: Hooks? = nil
local barrier: Barrier? = nil

local live: { Projectile } = {}
local retired: { Projectile } = {}
local byId: { [number]: Projectile } = {}
local pendingEvents: { ProjectileEvent } = {}
local pending: { PendingLaunch } = {}
local endings: { Projectile } = {}
-- Per GroupId, every body the volley has struck. Dropped once nothing of the volley is left (compact).
local volleyStrikes: { [number]: { [Model]: VolleyStrike } } = {}

-- A split's child spec, derived once per parent spec (weak keys: a spec dropped by its move goes too).
local splitSpecs: { [ProjectileSpec]: ProjectileSpec } = setmetatable({}, { __mode = "k" }) :: any

local nextId = 1
local nextGroupId = 1

-- The world cast: every registered body excluded (bodies are the Capsule sweep's job), and only what
-- would physically stop something -- a banner, a trigger volume or a decal plane is not a wall.
local worldParams = RaycastParams.new()
worldParams.FilterType = Enum.RaycastFilterType.Exclude
worldParams.FilterDescendantsInstances = {}
worldParams.RespectCanCollide = true

-- Reused across every sweep; single-threaded by construction (the engine's Heartbeat).
local candidateBuffer: { BasePart } = {}
local sweepDimensions: Dimensions = HitboxTypes.DefaultDimensions()

-- A frame at `position` looking along `direction` (unit). Straight up or down has no unique up vector,
-- so those take world X -- every caller here is a shape symmetric about its own axis, for which any up is
-- as good as another.
local function lookAlong(position: Vector3, direction: Vector3): CFrame
	local up = if math.abs(direction.Y) > 0.999 then Vector3.xAxis else Vector3.yAxis
	return CFrame.lookAt(position, position + direction, up)
end

local function requireHooks(): Hooks
	local bound = hooks
	assert(bound, "ProjectileSimulator used before HitboxEngine bound it")
	return bound
end

-- Binding ------------------------------------------------------------------------------------------

function ProjectileSimulator.Bind(engineHooks: Hooks): ()
	hooks = engineHooks
end

-- The engine calls this on every registration change, alongside the broadphase's own rebuild.
-- FilterDescendantsInstances copies the list, so the engine may keep reusing its buffer.
function ProjectileSimulator.SetRegisteredModels(models: { Model }): ()
	worldParams.FilterDescendantsInstances = models
end

-- Events --------------------------------------------------------------------------------------------

local function push(event: ProjectileEvent): ()
	table.insert(pendingEvents, event)
end

-- The body fields of a spec, for the wire: just the ones a ProjectileBody reads.
local function bodyWire(spec: ProjectileSpec): { [string]: any }
	return {
		Shape = spec.Shape,
		Size = spec.Size,
		Length = spec.Length,
		Width = spec.Width,
		Height = spec.Height,
		InnerRadius = spec.InnerRadius,
		AngleDegrees = spec.AngleDegrees,
	}
end

local function pushLaunch(projectile: Projectile, at: number): ()
	push({
		Kind = "Launch",
		Id = projectile.Id,
		GroupId = projectile.GroupId,
		Position = projectile.Position,
		Velocity = projectile.Velocity,
		Lead = 0,
		Owner = projectile.Owner.Model,
		MoveId = projectile.DebugName,
		Radius = projectile.Spec.Size,
		Body = if projectile.Body.IsSphere then nil else bodyWire(projectile.Spec),
		-- What is LEFT, so a shot a parry turned round is not drawn for a fresh full lifetime it has not got.
		LifetimeSeconds = math.max(projectile.Spec.LifetimeSeconds - projectile.Age, 0),
		-- A Reverse's own motion already homes and weaves nowhere (applyParryResponse); every other field of
		-- the motion is the one the server flies, so the client's visual cannot drift from it.
		Motion = projectile.Motion,
		Walls = if projectile.Spec.CollisionBehavior == "Destroy" then nil else projectile.Spec.CollisionBehavior,
		Target = if projectile.Target then projectile.Target.Model else nil,
		Age = projectile.Age,
		At = at,
	})
end

-- `motion` is sent only when the shot's motion itself changed (a "Return").
local function pushUpdate(projectile: Projectile, at: number, reason: string?, motion: ProjectileMotion.Motion?): ()
	push({
		Kind = "Update",
		Id = projectile.Id,
		GroupId = projectile.GroupId,
		Position = projectile.Position,
		Velocity = projectile.Velocity,
		Lead = 0,
		Target = if projectile.Target then projectile.Target.Model else nil,
		Reason = reason,
		Motion = motion,
		Age = projectile.Age,
		At = at,
	})
end

local function pushEnd(projectile: Projectile, at: number, reason: string, burst: number?): ()
	push({
		Kind = "End",
		Id = projectile.Id,
		GroupId = projectile.GroupId,
		Position = projectile.Position,
		Velocity = projectile.Velocity,
		Lead = 0,
		Reason = reason,
		Burst = burst,
		At = at,
	})
end

-- Lifecycle -----------------------------------------------------------------------------------------

-- Whether this shot bursts / splits when it ends for `reason` (ProjectileTypes' header, End effects).
local function burstsOn(projectile: Projectile, reason: string): boolean
	local spec = projectile.Spec
	if not ProjectileTypes.Triggers(spec.ExplodeOn, reason) then
		return false
	end
	local scope = spec.ExplosionScope
	if scope == "SplitOnly" then
		return projectile.Generation > 0
	elseif scope == "OriginalOnly" then
		return projectile.Generation == 0
	end
	return true
end

local function splitsOn(projectile: Projectile, reason: string): boolean
	local spec = projectile.Spec
	return projectile.Generation < spec.SplitGenerations and ProjectileTypes.Triggers(spec.SplitOn, reason)
end

local function endProjectile(projectile: Projectile, at: number, reason: string, on: Model?): ()
	if projectile.EndedAt ~= nil then
		return
	end
	projectile.EndedAt = at
	projectile.EndReason = reason
	projectile.EndedOn = on
	if not projectile.EffectsDone and (burstsOn(projectile, reason) or splitsOn(projectile, reason)) then
		-- Held for ResolveEndings, End event and all (this file's header).
		if not projectile.EffectsPending then
			projectile.EffectsPending = true
			table.insert(endings, projectile)
		end
		return
	end
	pushEnd(projectile, at, reason, nil)
end

-- Moves every ended shot from `live` to `retired`, and forgets retired shots past their grace. Swap-
-- with-last in a reverse walk, the engine's own idiom for its dense arrays.
local function compact(now: number): ()
	for index = #live, 1, -1 do
		local projectile = live[index]
		if projectile.EndedAt ~= nil then
			live[index] = live[#live]
			live[#live] = nil
			table.insert(retired, projectile)
		end
	end
	for index = #retired, 1, -1 do
		local projectile = retired[index]
		if projectile.EndedAt == nil or now - (projectile.EndedAt :: number) >= TUNING.RetireGraceSeconds then
			if projectile.EndedAt ~= nil then
				byId[projectile.Id] = nil
			end
			retired[index] = retired[#retired]
			retired[#retired] = nil
		end
	end
	if next(volleyStrikes) == nil then
		return
	end
	-- A volley's strike record outlives its last shot only as long as something could still read it: a
	-- shot in flight or retired (a parry may revive it), a wave still to fire, an end still to resolve.
	local held: { [number]: true } = {}
	for _, list in { live, retired, endings } do
		for _, projectile in list :: { Projectile } do
			held[projectile.GroupId] = true
		end
	end
	for _, entry in pending do
		held[entry.GroupId] = true
	end
	for groupId in volleyStrikes do
		if not held[groupId] then
			volleyStrikes[groupId] = nil
		end
	end
end

-- Whether another shot of `projectile`'s volley has already struck `model` for the same owner, inside the
-- spec's re-hit window (0 = never again) -- this file's header, ONE VOLLEY. The shot that struck it is not
-- held by its own record: its repeat hits are its HitTargets' question.
local function volleyHolds(projectile: Projectile, model: Model, now: number): boolean
	local struck = volleyStrikes[projectile.GroupId]
	local strike = if struck then struck[model] else nil
	if strike == nil or strike.Id == projectile.Id or strike.By ~= projectile.Owner.Model then
		return false
	end
	local rehit = projectile.Spec.RehitSeconds
	return rehit <= 0 or now - strike.At < rehit
end

local function noteVolleyStrike(projectile: Projectile, model: Model, now: number): ()
	local struck = volleyStrikes[projectile.GroupId] or {}
	volleyStrikes[projectile.GroupId] = struck
	struck[model] = { Id = projectile.Id, At = now, By = projectile.Owner.Model }
end

-- Puts a retired shot back in flight. The caller re-states it to clients (pushLaunch).
local function revive(projectile: Projectile): ()
	if projectile.EndedAt == nil then
		return
	end
	projectile.EndedAt = nil
	projectile.EndReason = nil
	projectile.EndedOn = nil
	-- An end whose effects were still pending never happened; ResolveEndings skips its entry.
	projectile.EffectsPending = false
	projectile.EndNormal = nil
	local index = table.find(retired, projectile)
	if index then
		retired[index] = retired[#retired]
		retired[#retired] = nil
	end
	table.insert(live, projectile)
end

-- Targets -------------------------------------------------------------------------------------------

local function isLiveBody(owner: Owner): boolean
	return owner.Model.Parent ~= nil and owner.RootPart.Parent ~= nil and owner.Humanoid.Health > 0
end

-- The target a shot at `position`, heading `heading`, would pick: a live registered body other than
-- `exclude`, not already hit (by `shot`, or by its volley), within the spec's range and cone, best by its
-- TargetSelection. The owner is never a homing target, even for a shot that may hit its owner -- chasing the
-- thrower is never meant.
local function selectTarget(
	exclude: Model,
	position: Vector3,
	heading: Vector3,
	spec: ProjectileSpec,
	shot: Projectile?,
	now: number
): Owner?
	local range = spec.HomingRange
	local maxAngle = math.rad(spec.HomingMaxAngle)
	local best: Owner? = nil
	local bestScore = math.huge
	for _, candidate in requireHooks().Combatants() do
		if candidate.Model == exclude then
			continue
		end
		if shot and (shot.HitTargets[candidate.Model] or volleyHolds(shot, candidate.Model, now)) then
			continue
		end
		if not isLiveBody(candidate) then
			continue
		end
		local offset = candidate.RootPart.Position - position
		local distance = offset.Magnitude
		if distance > range or distance <= EPSILON then
			continue
		end
		local angle = ProjectileMotion.AngleBetween(heading, offset / distance)
		if angle > maxAngle then
			continue
		end
		local score = if spec.TargetSelection == "Nearest" then distance else angle
		if score < bestScore then
			best, bestScore = candidate, score
		end
	end
	return best
end

-- A locked target stays locked while it is alive, unhit and in range -- no cone test once acquired, or a
-- shot that overshoots would drop a target it is still turning toward.
local function keepsTarget(projectile: Projectile, now: number): boolean
	local target = projectile.Target
	if
		target == nil
		or not isLiveBody(target)
		or projectile.HitTargets[target.Model]
		or volleyHolds(projectile, target.Model, now)
	then
		return false
	end
	return (target.RootPart.Position - projectile.Position).Magnitude <= projectile.Spec.HomingRange
end

local function headingOf(projectile: Projectile): Vector3
	local speed = projectile.Velocity.Magnitude
	return if speed > EPSILON then projectile.Velocity / speed else projectile.Owner.RootPart.CFrame.LookVector
end

-- Launch --------------------------------------------------------------------------------------------

-- How far down a HeightFrom Ground spawn looks for its ground, and how far above the spawn point the look
-- starts (so a spawn point just inside a slope still finds the surface it is in).
local GROUND_PROBE_STUDS = 200
local GROUND_PROBE_LIFT = 3

-- `spawnPose` lifted by the spec's SpawnHeight (ProjectileTypes' header, Height). The ground is the world
-- cast's own filter: bodies are excluded, so a shot is never stood on somebody's head.
local function raised(spec: ProjectileSpec, spawnPose: CFrame): CFrame
	if spec.SpawnHeight == 0 and spec.HeightFrom ~= "Ground" then
		return spawnPose
	end
	local groundY: number? = nil
	if spec.HeightFrom == "Ground" then
		local from = spawnPose.Position + Vector3.new(0, GROUND_PROBE_LIFT, 0)
		local hit = Workspace:Raycast(from, Vector3.new(0, -GROUND_PROBE_STUDS, 0), worldParams)
		groundY = if hit then hit.Position.Y else nil
	end
	return ProjectileMotion.Raise(spec, spawnPose, groundY)
end

-- The frame a SpawnFrom Target volley stands its offset in: at the target's root, looking along the level
-- line from the thrower to it (ProjectileTypes' header, SpawnFrom). Straight above or below falls back to
-- the thrower's own facing.
local function targetFrame(owner: Owner, target: Owner): CFrame
	local at = target.RootPart.Position
	local line = at - owner.RootPart.Position
	local level = Vector3.new(line.X, 0, line.Z)
	if level.Magnitude <= EPSILON then
		level = owner.RootPart.CFrame.LookVector
		level = Vector3.new(level.X, 0, level.Z)
	end
	if level.Magnitude <= EPSILON then
		return CFrame.new(at)
	end
	return CFrame.lookAt(at, at + level.Unit, Vector3.yAxis)
end

-- The volley's aim: a world CFrame at the spawn point (anchor.CFrame * offset, or the target's frame *
-- offset for SpawnFrom Target) looking down the volley's centre. The offset's own rotation always turns the
-- volley -- yaw and pitch aim it, roll turns its plane. `offset` is the move's, or its mirror image for an
-- AlternateSides wave.
local function aimFor(owner: Owner, anchor: BasePart, offset: CFrame, spec: ProjectileSpec): CFrame
	-- A weapon put away or a limb gone: the root stands in, so the wave still comes from the thrower.
	local source = if anchor.Parent ~= nil then anchor else owner.RootPart
	local facingLook = owner.RootPart.CFrame.LookVector

	local target: Owner? = nil
	local spawnPose: CFrame
	if spec.SpawnFrom == "Target" then
		target = selectTarget(owner.Model, owner.RootPart.Position, facingLook, spec, nil, 0)
		spawnPose = if target then targetFrame(owner, target) * offset else source.CFrame * offset
	else
		spawnPose = source.CFrame * offset
	end
	spawnPose = raised(spec, spawnPose)
	if spec.SpawnDirection == "Anchor" then
		return spawnPose
	end
	local position = spawnPose.Position
	local turn = offset.Rotation
	local facing = CFrame.new(position) * owner.RootPart.CFrame.Rotation * turn
	if spec.SpawnDirection == "Target" then
		-- The target the spawn was stood at, when there was one, so the two cannot disagree; otherwise picked
		-- from the spawn point, as it always was.
		local aimed = target or selectTarget(owner.Model, position, facingLook, spec, nil, 0)
		if aimed then
			local toward = aimed.RootPart.Position - position
			if toward.Magnitude > EPSILON then
				local direction = toward.Unit
				if spec.LeadTarget then
					direction = ProjectileMotion.Intercept(
						position,
						aimed.RootPart.Position,
						aimed.RootPart.AssemblyLinearVelocity,
						spec.Speed
					) or direction
				end
				return lookAlong(position, direction) * turn
			end
		end
	end
	return facing
end

-- A split's child spec (ProjectileTypes' header, End effects): the parent's, as one shot of SplitPattern
-- across SplitAngle at SplitSpeedScale of the speed, with nothing about the CAST carried over (no waves, no
-- formation offset, no convergence, no target spawn, no return). Built once per parent spec.
local function splitSpecOf(spec: ProjectileSpec): ProjectileSpec
	local cached = splitSpecs[spec]
	if cached then
		return cached
	end
	local child = ProjectileTypes.Copy(spec)
	local limits = ProjectileTypes.Limits
	child.SpreadPattern = spec.SplitPattern
	child.Count = spec.SplitCount
	child.SpreadAngle = spec.SplitAngle
	child.Speed = math.clamp(spec.Speed * spec.SplitSpeedScale, limits.Speed.Min, limits.Speed.Max)
	child.FormationRadius = 0
	child.ConvergeDistance = 0
	child.WaveCount = 1
	child.ShotIntervalSeconds = 0
	child.WaveRollDegrees = 0
	child.AlternateSides = false
	child.SpawnFrom = "Anchor"
	child.ReturnAfterSeconds = 0
	splitSpecs[spec] = child
	return child
end

-- What one batch of shots inherits beyond its spec: who, what, which cast, and -- for a split -- which
-- generation, whose hit set and whose damage scale.
type Lineage = {
	Owner: Owner,
	DebugName: string,
	Spec: ProjectileSpec,
	ComboStage: number,
	PowerLevel: number,
	GroupId: number,
	Options: LaunchOptions?,
	Generation: number,
	HitTargets: { [Model]: number }?,
	DamageScale: number?,
	Exclusive: Model?,
	DomainId: string?,
}

-- Launches `shots` (Volley indices `indices`, all of them when nil) as one batch. Returns how many launched
-- (fewer only when MaxLive would be passed). The single place a Projectile record is made.
local function launchShots(
	lineage: Lineage,
	shots: { ProjectileMotion.Shot },
	indices: { number }?,
	now: number
): number
	local spec = lineage.Spec
	local owner = lineage.Owner
	local options = lineage.Options

	local fixedTarget: Owner? = nil
	if options and options.Target then
		fixedTarget = requireHooks().CombatantOf(options.Target)
	end
	local exclusive: Model? = lineage.Exclusive
	if exclusive == nil and options and options.Exclusive and fixedTarget then
		exclusive = fixedTarget.Model
	end
	local damageScale = lineage.DamageScale
		or (if options and options.DamageScale then math.max(options.DamageScale, 0) else 1)

	local motion = ProjectileMotion.MotionOf(spec)
	local mirroredMotion: ProjectileMotion.Motion? = nil
	local body = ProjectileBody.Of(spec)

	local launched = 0
	local requested = if indices then #indices else #shots
	for slot = 1, requested do
		local index = if indices then indices[slot] else slot
		local shot = shots[index]
		if shot == nil then
			continue
		end
		if #live >= TUNING.MaxLive then
			logger:warn("Projectile ceiling reached; volley cut short", {
				attack = lineage.DebugName,
				launched = launched,
				requested = requested,
			})
			break
		end
		local shotMotion = motion
		if spec.WeaveMirrored and index % 2 == 0 then
			mirroredMotion = mirroredMotion or ProjectileMotion.MotionOf(spec, true)
			shotMotion = mirroredMotion :: ProjectileMotion.Motion
		end
		local projectile: Projectile = {
			Id = nextId,
			GroupId = lineage.GroupId,
			Owner = owner,
			Spec = spec,
			Motion = shotMotion,
			DebugName = lineage.DebugName,
			Body = body,
			ComboStage = lineage.ComboStage,
			PowerLevel = lineage.PowerLevel,
			Position = shot.Origin,
			Velocity = shot.Direction * spec.Speed,
			Age = 0,
			Travelled = 0,
			Origin = shot.Origin,
			PiercesLeft = spec.MaxPierces,
			BouncesLeft = spec.MaxBounces,
			HitTargets = if lineage.HitTargets then table.clone(lineage.HitTargets) else {},
			Target = nil,
			RetargetAt = 0,
			ResyncAt = TUNING.HomingResyncSeconds,
			DamageScale = damageScale,
			NoHoming = false,
			EndedAt = nil,
			EndReason = nil,
			EndedOn = nil,
			Exclusive = exclusive,
			DomainId = lineage.DomainId or (if options then options.DomainId else nil),
			Generation = lineage.Generation,
			Returning = false,
			EffectsPending = false,
			EffectsDone = false,
			Defused = false,
			EndNormal = nil,
		}
		nextId += 1
		if motion.HomingStrength > 0 then
			projectile.Target = fixedTarget
				or selectTarget(owner.Model, shot.Origin, shot.Direction, spec, projectile, now)
			projectile.RetargetAt = TUNING.RetargetSeconds
		end
		table.insert(live, projectile)
		byId[projectile.Id] = projectile
		pushLaunch(projectile, now)
		launched += 1
	end
	return launched
end

local function liveOwner(owner: Owner): boolean
	return isLiveBody(owner) and requireHooks().CombatantOf(owner.Model) == owner
end

-- The aim a pending launch fires along now: its own fixed aim, or a fresh one from where the thrower is.
local function aimOfPending(entry: PendingLaunch): CFrame
	local fixed = entry.Aim
	if fixed then
		return fixed
	end
	local spec = entry.Definition.Projectile :: ProjectileSpec
	local mirrored = spec.AlternateSides and entry.Wave % 2 == 0
	local offset = if mirrored then ProjectileMotion.MirrorOffset(entry.Definition.Offset) else entry.Definition.Offset
	return aimFor(entry.Owner, if mirrored then entry.MirrorAnchor else entry.Anchor, offset, spec)
end

local function lineageOf(entry: PendingLaunch): Lineage
	return {
		Owner = entry.Owner,
		DebugName = entry.Definition.DebugName,
		Spec = entry.Definition.Projectile :: ProjectileSpec,
		ComboStage = entry.ComboStage,
		PowerLevel = entry.PowerLevel,
		GroupId = entry.GroupId,
		Options = entry.Options,
		Generation = 0,
	}
end

-- Fires one pending launch: its whole wave, or its one staggered shot.
local function firePending(entry: PendingLaunch, now: number): number
	local spec = entry.Definition.Projectile :: ProjectileSpec
	local shots = ProjectileMotion.Volley(spec, aimOfPending(entry), entry.Wave)
	return launchShots(lineageOf(entry), shots, if entry.Index then { entry.Index } else nil, now)
end

-- Launches every due pending launch, oldest first, and drops any whose thrower is gone.
local function firePendingDue(now: number): ()
	if #pending == 0 then
		return
	end
	local due: { PendingLaunch }? = nil
	for index = #pending, 1, -1 do
		local entry = pending[index]
		local gone = not liveOwner(entry.Owner)
		if gone or entry.DueAt <= now + 1e-9 then
			pending[index] = pending[#pending]
			pending[#pending] = nil
			if not gone then
				local list = due or {}
				due = list
				table.insert(list, entry)
			end
		end
	end
	if due == nil then
		return
	end
	table.sort(due, function(a: PendingLaunch, b: PendingLaunch): boolean
		if a.DueAt ~= b.DueAt then
			return a.DueAt < b.DueAt
		end
		if a.Wave ~= b.Wave then
			return a.Wave < b.Wave
		end
		return (a.Index or 0) < (b.Index or 0)
	end)
	for _, entry in due do
		firePending(entry, now)
	end
end

-- The shared launch behind Launch (a swing's Active window) and LaunchAimed (a realm): every wave and
-- staggered shot of one cast, the ones due now launched at once and the rest queued. `fixedAim` is a
-- realm's aim (every wave fires along it); a swing passes nil and its spec's WaveAim decides. Returns the
-- cast's GroupId and how many shots launched NOW.
local function launchCast(
	owner: Owner,
	anchor: BasePart,
	mirrorAnchor: BasePart,
	definition: AttackDefinition,
	comboStage: number,
	powerLevel: number,
	now: number,
	fixedAim: CFrame?,
	options: LaunchOptions?
): (number, number)
	local spec = definition.Projectile
	if spec == nil then
		return 0, 0
	end
	compact(now)

	local groupId = nextGroupId
	nextGroupId += 1

	-- Fixed waves aim once, here: the first wave's aim and its mirror image.
	local aimOne: CFrame? = fixedAim
	local aimTwo: CFrame? = fixedAim
	if fixedAim == nil and spec.WaveAim == "Fixed" then
		aimOne = aimFor(owner, anchor, definition.Offset, spec)
		aimTwo = if spec.AlternateSides
			then aimFor(owner, mirrorAnchor, ProjectileMotion.MirrorOffset(definition.Offset), spec)
			else aimOne
	end

	local budget = ProjectileTypes.Budget(spec)
	local staggered = spec.ShotIntervalSeconds > 0 and budget.ShotsPerWave > 1
	local launched = 0
	for wave = 1, budget.Waves do
		local waveAim = if wave % 2 == 0 then aimTwo else aimOne
		for index = 1, if staggered then budget.ShotsPerWave else 1 do
			local entry: PendingLaunch = {
				Owner = owner,
				Anchor = anchor,
				MirrorAnchor = mirrorAnchor,
				Definition = definition,
				ComboStage = comboStage,
				PowerLevel = powerLevel,
				GroupId = groupId,
				DueAt = now + ProjectileMotion.FireTime(spec, wave, index),
				Wave = wave,
				Index = if staggered then index else nil,
				Aim = waveAim,
				Options = options,
				SwingBound = fixedAim == nil,
			}
			if entry.DueAt <= now + 1e-9 then
				launched += firePending(entry, now)
			elseif #pending < TUNING.MaxLive then
				table.insert(pending, entry)
			end
		end
	end
	return groupId, launched
end

-- Launches `definition`'s cast for `owner`, from `anchor` (and `mirrorAnchor`, the other hand, for an
-- AlternateSides wave -- the anchor itself when there is no other side). Returns the cast's GroupId and how
-- many shots launched at once (fewer than the spec's first wave only when MaxLive would be passed; later
-- waves are queued, this file's header).
function ProjectileSimulator.Launch(
	owner: Owner,
	anchor: BasePart,
	definition: AttackDefinition,
	comboStage: number,
	powerLevel: number,
	now: number,
	mirrorAnchor: BasePart?
): (number, number)
	return launchCast(owner, anchor, mirrorAnchor or anchor, definition, comboStage, powerLevel, now, nil, nil)
end

-- Launches `definition`'s volley for `owner` from a world `aim` no swing produced -- see this file's
-- header (A VOLLEY NOT THROWN BY A SWING). The owner must be a registered combatant (it is who the
-- contacts are reported as coming from); the volley's own SpawnDirection and SpawnFrom are not consulted --
-- `aim` is it, for every wave.
function ProjectileSimulator.LaunchAimed(
	owner: Owner,
	aim: CFrame,
	definition: AttackDefinition,
	powerLevel: number,
	now: number,
	options: LaunchOptions?
): (number, number)
	return launchCast(owner, owner.RootPart, owner.RootPart, definition, 1, powerLevel, now, aim, options)
end

-- Drops every wave `owner`'s swing has not fired yet -- the engine calls it when that swing is interrupted
-- (this file's header, WAVES). A realm's waves are untouched. Returns how many launches it dropped.
function ProjectileSimulator.CancelPending(owner: Model): number
	local dropped = 0
	for index = #pending, 1, -1 do
		local entry = pending[index]
		if entry.SwingBound and entry.Owner.Model == owner then
			pending[index] = pending[#pending]
			pending[#pending] = nil
			dropped += 1
		end
	end
	return dropped
end

function ProjectileSimulator.PendingCount(): number
	return #pending
end

-- Holds (or, with nil, clears) the barrier slot -- see this file's header.
function ProjectileSimulator.SetBarrier(callback: Barrier?): ()
	barrier = callback
end

-- Contacts ------------------------------------------------------------------------------------------

-- One contact. `travelled` is how far into its range the shot was when it touched (its falloff); `blast`
-- is a burst's centre and radius, nil for the shot itself touching.
local function report(
	projectile: Projectile,
	target: Owner,
	part: BasePart,
	at: Vector3,
	now: number,
	travelled: number,
	blast: { Centre: Vector3, Radius: number }?
): ()
	local spec = projectile.Spec
	local heading = headingOf(projectile)
	local body = projectile.Body
	local falloff = ProjectileMotion.Falloff(spec, travelled)
	local contact: ProjectileTypes.ProjectileContact
	local shape: HitboxTypes.ShapeKind = body.Shape
	local dimensions: Dimensions
	if blast then
		local outward = part.Position - blast.Centre
		contact = {
			Id = projectile.Id,
			GroupId = projectile.GroupId,
			SourcePosition = blast.Centre,
			Direction = if outward.Magnitude > EPSILON then outward.Unit else heading,
			Parryable = false,
			StaggersOwner = false,
			DamageScale = projectile.DamageScale * spec.ExplosionDamageScale * falloff,
			DomainId = projectile.DomainId,
			Blast = true,
		}
		shape = "Sphere"
		dimensions = HitboxTypes.DefaultDimensions()
		dimensions.Radius = blast.Radius
	else
		contact = {
			Id = projectile.Id,
			GroupId = projectile.GroupId,
			SourcePosition = at - heading * TUNING.SourceProbeStuds,
			Direction = heading,
			Parryable = spec.ParryBehavior ~= "CannotParry",
			StaggersOwner = spec.ParryResponse == "ExistingParry",
			DamageScale = projectile.DamageScale * falloff,
			DomainId = projectile.DomainId,
		}
		-- A copy: a consumer may keep a report, and the body's own table is shared by every shot of the volley.
		dimensions = table.clone(body.Dimensions)
	end
	requireHooks().Report({
		Attacker = projectile.Owner.Model,
		Target = target.Model,
		TargetPart = part,
		Shape = shape,
		Dimensions = dimensions,
		ContactPosition = part:GetClosestPointOnSurface(if blast then blast.Centre else at),
		ComboStage = projectile.ComboStage,
		PowerLevel = projectile.PowerLevel,
		SampleTime = now,
		DebugName = projectile.DebugName,
		Projectile = contact,
		Source = (if projectile.DomainId ~= nil then "Realm" else "Projectile") :: HitboxTypes.ContactSource,
	})
end

type Contact = { Owner: Owner, Part: BasePart, Along: number }

local function byAlong(a: Contact, b: Contact): boolean
	return a.Along < b.Along
end

-- Whether this shot may hit its own thrower right now: only when authored to, and only once it has had
-- time to leave the body it spawned inside -- otherwise every such shot would hit its thrower on frame one.
local function mayHitOwner(projectile: Projectile): boolean
	return projectile.Spec.CanHitOwner and projectile.Age >= TUNING.OwnerHitGraceSeconds
end

-- Whether this shot may not strike `model` right now: it already has, and RehitSeconds (0 = never again)
-- has not passed since.
local function struckRecently(projectile: Projectile, model: Model): boolean
	local at = projectile.HitTargets[model]
	if at == nil then
		return false
	end
	local rehit = projectile.Spec.RehitSeconds
	return rehit <= 0 or projectile.Age - at < rehit
end

-- Whether `owner` is a body this shot could strike at all right now, before any geometry: alive, not
-- struck too recently, allowed by Exclusive, and not the thrower unless it may hit them.
local function eligible(projectile: Projectile, owner: Owner, now: number): boolean
	if struckRecently(projectile, owner.Model) or volleyHolds(projectile, owner.Model, now) then
		return false
	end
	local exclusive = projectile.Exclusive
	if exclusive ~= nil and owner.Model ~= exclusive then
		return false
	end
	return owner.Model ~= projectile.Owner.Model or mayHitOwner(projectile)
end

-- Every new body the segment a -> b passes through, nearest first; reports each and applies Piercing.
local function sweepBodies(projectile: Projectile, a: Vector3, b: Vector3, now: number): ()
	local engine = requireHooks()
	local body = projectile.Body
	local delta = b - a
	local length = delta.Magnitude
	local heading = if length > EPSILON then delta / length else headingOf(projectile)
	-- The broadphase is a capsule round the segment: exact for a sphere, a bounding sphere for any other
	-- body (over-gathering is correct here -- the narrow phase below is what trims it).
	sweepDimensions.Radius = if body.IsSphere then body.CastRadius else body.BoundRadius
	sweepDimensions.Length = length
	local pose = if length > EPSILON then lookAlong((a + b) / 2, heading) else CFrame.new(a)

	local count = CandidateGatherer.Gather("Capsule", sweepDimensions, pose, candidateBuffer)
	if count == 0 then
		return
	end

	-- The body at both ends of the step, for the swept test; unused by a sphere.
	local poseStart: CFrame? = nil
	local poseEnd: CFrame? = nil
	if not body.IsSphere then
		poseStart = ProjectileBody.PoseAt(body, a, heading)
		poseEnd = ProjectileBody.PoseAt(body, b, heading)
	end

	local margin = HitboxEngineConstants.NarrowPhaseMarginStuds
	local contacts: { Contact }? = nil
	for index = 1, count do
		local part = candidateBuffer[index]
		local owner = engine.OwnerOf(part)
		if owner == nil or not eligible(projectile, owner, now) then
			continue
		end
		local touching: boolean
		if body.IsSphere then
			touching =
				HitboxGeometry.ContainsPoint("Capsule", sweepDimensions, pose:PointToObjectSpace(part.Position), margin)
		else
			touching = HitboxGeometry.SweptContainsPoint(
				body.Shape,
				body.Dimensions,
				poseStart :: CFrame,
				body.Dimensions,
				poseEnd :: CFrame,
				part.Position,
				margin
			)
		end
		if not touching then
			continue
		end
		local along = if length > EPSILON
			then math.clamp((part.Position - a):Dot(delta) / (length * length), 0, 1)
			else 0
		local list = contacts or {}
		contacts = list
		-- One contact per body: its nearest part along the path.
		local existing: Contact? = nil
		for _, contact in list do
			if contact.Owner.Model == owner.Model then
				existing = contact
				break
			end
		end
		if existing == nil then
			table.insert(list, { Owner = owner, Part = part, Along = along })
		elseif along < existing.Along then
			existing.Part = part
			existing.Along = along
		end
	end
	if contacts == nil then
		return
	end

	table.sort(contacts, byAlong)
	for _, contact in contacts do
		local at = a + delta * contact.Along
		projectile.HitTargets[contact.Owner.Model] = projectile.Age
		noteVolleyStrike(projectile, contact.Owner.Model, now)
		report(projectile, contact.Owner, contact.Part, at, now, projectile.Travelled + length * contact.Along)
		if not projectile.Spec.Piercing then
			projectile.Position = at
			endProjectile(projectile, now, "Hit", contact.Owner.Model)
			return
		end
		projectile.PiercesLeft -= 1
		if projectile.PiercesLeft < 0 then
			projectile.Position = at
			endProjectile(projectile, now, "Hit", contact.Owner.Model)
			return
		end
	end
end

-- Flight --------------------------------------------------------------------------------------------

local function distanceToSegment(point: Vector3, from: Vector3, to: Vector3): number
	local segment = to - from
	local lengthSquared = segment:Dot(segment)
	if lengthSquared < 1e-8 then
		return (point - from).Magnitude
	end
	local along = math.clamp((point - from):Dot(segment) / lengthSquared, 0, 1)
	return (point - (from + segment * along)).Magnitude
end

-- Whether a body this shot could strike is within its ProximityRadius of `at`.
local function fuseTripped(projectile: Projectile, at: Vector3, now: number): boolean
	local radius = projectile.Spec.ProximityRadius
	if radius <= 0 then
		return false
	end
	local engine = requireHooks()
	local count = CandidateGatherer.GatherSphere(at, radius, candidateBuffer)
	for index = 1, count do
		local part = candidateBuffer[index]
		local owner = engine.OwnerOf(part)
		if owner and eligible(projectile, owner, now) and (part.Position - at).Magnitude <= radius then
			return true
		end
	end
	return false
end

-- Turns a shot for home (ProjectileTypes' header, Return).
local function beginReturn(projectile: Projectile, now: number): ()
	projectile.Returning = true
	projectile.Motion = ProjectileMotion.ReturnMotionOf(projectile.Motion, projectile.Spec)
	projectile.Target = projectile.Owner
	table.clear(projectile.HitTargets)
	projectile.Travelled = 0
	projectile.Origin = projectile.Position
	pushUpdate(projectile, now, "Return", projectile.Motion)
end

-- Where the step from `from` to `to` stops, if the range runs out inside it: the step's end clipped, and
-- whether it was. Path range is spent along the flight; Displacement is the distance from the leg's origin.
local function clipToRange(projectile: Projectile, from: Vector3, to: Vector3): (Vector3, boolean)
	local spec = projectile.Spec
	local step = to - from
	local stepLength = step.Magnitude
	if spec.RangeMode == "Displacement" then
		local radius = spec.MaxRange
		local relative = from - projectile.Origin
		if (to - projectile.Origin).Magnitude < radius then
			return to, false
		end
		if relative.Magnitude >= radius or stepLength <= EPSILON then
			return from, true
		end
		-- |relative + step t| = radius, the root in (0, 1]: the shot is inside at t = 0.
		local a = step:Dot(step)
		local b = 2 * relative:Dot(step)
		local c = relative:Dot(relative) - radius * radius
		local t = (-b + math.sqrt(math.max(b * b - 4 * a * c, 0))) / (2 * a)
		return from + step * math.clamp(t, 0, 1), true
	end
	local rangeLeft = math.max(spec.MaxRange - projectile.Travelled, 0)
	if stepLength < rangeLeft then
		return to, false
	end
	if stepLength > EPSILON then
		return from + step * (rangeLeft / stepLength), true
	end
	return to, true
end

local function stepOne(projectile: Projectile, dt: number, now: number): ()
	if projectile.EndedAt ~= nil then
		return
	end
	local spec = projectile.Spec

	-- The age at the step's start drives the weave and homing's window (ProjectileMotion's header).
	local startAge = projectile.Age
	projectile.Age += dt
	if projectile.Age >= spec.LifetimeSeconds then
		endProjectile(projectile, now, "Expired", nil)
		return
	end

	if
		spec.ReturnAfterSeconds > 0
		and not projectile.Returning
		and not projectile.NoHoming
		and projectile.Age >= spec.ReturnAfterSeconds
	then
		beginReturn(projectile, now)
	end

	local homes = projectile.Motion.HomingStrength > 0 and not projectile.NoHoming
	local homingPoint: Vector3? = nil
	if projectile.Returning then
		-- Home is the thrower, whoever else is near: no retargeting on the way back.
		local thrower = projectile.Owner
		if not projectile.NoHoming and isLiveBody(thrower) then
			homingPoint = thrower.RootPart.Position
		end
	elseif homes and projectile.Exclusive ~= nil then
		-- Pinned to one body: follow it while it lives, and never pick another.
		local target = projectile.Target
		if target and isLiveBody(target) then
			homingPoint = target.RootPart.Position
		end
	elseif homes then
		if not keepsTarget(projectile, now) then
			local previous = projectile.Target
			projectile.Target = nil
			if projectile.Age >= projectile.RetargetAt then
				projectile.RetargetAt = projectile.Age + TUNING.RetargetSeconds
				projectile.Target = selectTarget(
					projectile.Owner.Model,
					projectile.Position,
					headingOf(projectile),
					spec,
					projectile,
					now
				)
			end
			if projectile.Target ~= previous then
				pushUpdate(projectile, now)
			end
		end
		local target = projectile.Target
		if target then
			homingPoint = target.RootPart.Position
		end
	end

	local from = projectile.Position
	local to, velocity =
		ProjectileMotion.Integrate(from, projectile.Velocity, projectile.Motion, dt, homingPoint, startAge)

	-- Range: the step stops where the range runs out.
	local rangeEnds: boolean
	to, rangeEnds = clipToRange(projectile, from, to)

	-- A realm's closed edge (the barrier slot): the step does not happen, and the shot ends where it is.
	local barrierCheck = barrier
	if barrierCheck and barrierCheck(projectile.Owner.Model, projectile.DomainId, from, to) then
		projectile.Velocity = velocity
		endProjectile(projectile, now, "Barrier", nil)
		return
	end

	-- The world, first as a distance: bodies in front of the wall are still hit before it.
	local segment = to - from
	local worldHit: RaycastResult? = nil
	if spec.CollisionBehavior ~= "Continue" and segment.Magnitude > EPSILON then
		-- From the body's leading edge: for a long shape the tip meets a wall before the middle does. A
		-- sphere's lead is zero, so it casts from its centre exactly as it always did.
		local body = projectile.Body
		local castFrom = if body.CastLead > 0 then from + segment.Unit * body.CastLead else from
		worldHit = Workspace:Spherecast(castFrom, body.CastRadius, segment, worldParams)
	end
	local reach = if worldHit then from + segment.Unit * worldHit.Distance else to

	-- Back in the thrower's hand, before it could strike anything on this step.
	if projectile.Returning and isLiveBody(projectile.Owner) then
		if distanceToSegment(projectile.Owner.RootPart.Position, from, reach) <= TUNING.ReturnCatchStuds then
			projectile.Position = reach
			projectile.Velocity = velocity
			endProjectile(projectile, now, "Returned", nil)
			return
		end
	end

	sweepBodies(projectile, from, reach, now)
	if projectile.EndedAt ~= nil then
		return
	end
	projectile.Travelled += (reach - from).Magnitude

	if fuseTripped(projectile, reach, now) then
		projectile.Position = reach
		projectile.Velocity = velocity
		endProjectile(projectile, now, "Proximity", nil)
		return
	end

	if worldHit then
		if spec.CollisionBehavior == "Bounce" and projectile.BouncesLeft > 0 then
			projectile.BouncesLeft -= 1
			projectile.Velocity = ProjectileMotion.Reflect(velocity, worldHit.Normal)
			projectile.Position = reach + worldHit.Normal * TUNING.BounceSeparationStuds
			pushUpdate(projectile, now, "Bounce")
		else
			projectile.Position = reach
			projectile.Velocity = velocity
			projectile.EndNormal = worldHit.Normal
			endProjectile(projectile, now, "World", nil)
		end
		return
	end

	projectile.Position = to
	projectile.Velocity = velocity
	if rangeEnds then
		endProjectile(projectile, now, "Range", nil)
		return
	end

	if homes and projectile.Age >= projectile.ResyncAt then
		projectile.ResyncAt = projectile.Age + TUNING.HomingResyncSeconds
		pushUpdate(projectile, now)
	end
end

-- One substep of every shot in flight. `now` is the substep's own time on the engine's clock.
function ProjectileSimulator.Step(dt: number, now: number): ()
	firePendingDue(now)
	if #live == 0 then
		if #retired > 0 then
			compact(now)
		end
		return
	end
	-- Backwards, so a shot launched by a hit callback mid-walk (a swing's Active window opening in the
	-- same substep) is appended past the cursor and first flies next substep.
	for index = #live, 1, -1 do
		local projectile = live[index]
		if projectile then
			stepOne(projectile, dt, now)
		end
	end
	compact(now)
end

-- End effects ---------------------------------------------------------------------------------------

-- Strikes every eligible body within the burst (this file's header, THE BURST). Returns the radius.
local function burst(projectile: Projectile, now: number): number
	local spec = projectile.Spec
	local engine = requireHooks()
	local centre = projectile.Position
	local radius = spec.ExplosionRadius
	local margin = HitboxEngineConstants.NarrowPhaseMarginStuds
	local count = CandidateGatherer.GatherSphere(centre, radius, candidateBuffer)
	-- Nearest part per body, collected before any report: a report's consumer may run code that gathers.
	local struck: { [Model]: { Owner: Owner, Part: BasePart, Distance: number } } = {}
	local order: { Model } = {}
	for index = 1, count do
		local part = candidateBuffer[index]
		local owner = engine.OwnerOf(part)
		-- Every body this shot ever struck is skipped, re-hit window or not: a burst never doubles a hit.
		if owner == nil or projectile.HitTargets[owner.Model] ~= nil or not eligible(projectile, owner, now) then
			continue
		end
		local distance = (part.Position - centre).Magnitude
		if distance > radius + margin then
			continue
		end
		local existing = struck[owner.Model]
		if existing == nil then
			struck[owner.Model] = { Owner = owner, Part = part, Distance = distance }
			table.insert(order, owner.Model)
		elseif distance < existing.Distance then
			existing.Part = part
			existing.Distance = distance
		end
	end
	table.sort(order, function(a: Model, b: Model): boolean
		return struck[a].Distance < struck[b].Distance
	end)
	local blast = { Centre = centre, Radius = radius }
	for _, model in order do
		local entry = struck[model]
		projectile.HitTargets[model] = projectile.Age
		noteVolleyStrike(projectile, model, now)
		report(projectile, entry.Owner, entry.Part, centre, now, projectile.Travelled, blast)
	end
	return radius
end

-- Launches the shot's children where it ended (this file's header, THE SPLIT).
local function split(projectile: Projectile, now: number): ()
	local heading = headingOf(projectile)
	local position = projectile.Position
	local normal = projectile.EndNormal
	if normal then
		-- Off the wall, not into it.
		local reflected = ProjectileMotion.Reflect(heading, normal)
		heading = if reflected.Magnitude > EPSILON then reflected.Unit else normal
		position += normal * TUNING.BounceSeparationStuds
	end
	local childSpec = splitSpecOf(projectile.Spec)
	local shots = ProjectileMotion.Volley(childSpec, lookAlong(position, heading))
	launchShots({
		Owner = projectile.Owner,
		DebugName = projectile.DebugName,
		Spec = childSpec,
		ComboStage = projectile.ComboStage,
		PowerLevel = projectile.PowerLevel,
		GroupId = projectile.GroupId,
		Options = nil,
		Generation = projectile.Generation + 1,
		HitTargets = projectile.HitTargets,
		DamageScale = projectile.DamageScale,
		Exclusive = projectile.Exclusive,
		DomainId = projectile.DomainId,
	}, shots, nil, now)
end

-- Resolves every end whose effects were held (this file's header, END EFFECTS ARE DEFERRED). The engine
-- calls it once at the start of each frame, after the defence layer has judged the previous one; `now` is
-- that frame's start, so the contacts a burst reports come before any the frame's substeps report.
function ProjectileSimulator.ResolveEndings(now: number): ()
	if #endings == 0 then
		return
	end
	local resolving = endings
	endings = {}
	for _, projectile in resolving do
		if not projectile.EffectsPending then
			-- Revived since (an evade, a reflect): that end never happened.
			continue
		end
		projectile.EffectsPending = false
		projectile.EffectsDone = true
		local reason = projectile.EndReason or "Expired"
		local at = projectile.EndedAt or now
		if projectile.Defused or projectile.EndedAt == nil then
			pushEnd(projectile, at, "Parried", nil)
			continue
		end
		local radius: number? = nil
		if burstsOn(projectile, reason) then
			radius = burst(projectile, now)
		end
		if splitsOn(projectile, reason) then
			split(projectile, now)
		end
		pushEnd(projectile, at, reason, radius)
	end
end

-- Whether anything is in flight, waiting to launch, or waiting to resolve -- the engine keeps stepping
-- the simulator while this is true.
function ProjectileSimulator.Busy(): boolean
	return #live > 0 or #pending > 0 or #endings > 0
end

-- Parry and evade -----------------------------------------------------------------------------------

-- The parrier's body, as a registered combatant, or nil.
local function bodyOf(model: Model): Owner?
	return requireHooks().CombatantOf(model)
end

local function reflectedDirection(projectile: Projectile, thrower: Owner, parrier: Owner): Vector3
	local heading = headingOf(projectile)
	local mode = projectile.Spec.ReflectionDirection
	if mode == "ToOwner" and thrower.RootPart.Parent ~= nil then
		local toward = thrower.RootPart.Position - projectile.Position
		if toward.Magnitude > EPSILON then
			return toward.Unit
		end
	elseif mode == "ParrierFacing" then
		return parrier.RootPart.CFrame.LookVector
	elseif mode == "Mirror" then
		local look = parrier.RootPart.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		if flat.Magnitude > EPSILON then
			local mirrored = ProjectileMotion.Reflect(heading, flat.Unit)
			if mirrored.Magnitude > EPSILON then
				return mirrored.Unit
			end
		end
	end
	return -heading
end

-- One shot's parry response. `parrier` is nil only for a body the engine does not know, which can own
-- nothing -- such a parry ends the shot whatever the response says.
local function applyParryResponse(projectile: Projectile, parrier: Owner?, at: number): ()
	local response = projectile.Spec.ParryResponse
	if parrier == nil or response == "ExistingParry" or response == "Destroy" then
		-- A shot whose contact already ended it is still awaiting its effects: the parry defuses them.
		projectile.Defused = true
		endProjectile(projectile, at, "Parried", nil)
		return
	end

	local thrower = projectile.Owner
	revive(projectile)
	-- A new flight, with its own end to come: it may burst or split again where that is.
	projectile.EffectsDone = false
	projectile.Defused = false
	if projectile.Returning then
		-- It was coming home to the thrower; it is the parrier's now, flying out.
		projectile.Returning = false
		projectile.Motion = ProjectileMotion.MotionOf(projectile.Spec)
	end
	projectile.Origin = projectile.Position
	local speed = projectile.Velocity.Magnitude
	if speed <= EPSILON then
		speed = projectile.Spec.Speed
	end
	local direction: Vector3
	if response == "Reverse" then
		direction = -headingOf(projectile)
		projectile.NoHoming = true
		-- Retracing means straight back: neither homing nor a weave may bend it off its own path, on the
		-- server or in the client's copy of the motion pushLaunch sends.
		local straight = table.clone(projectile.Motion)
		straight.HomingStrength = 0
		straight.WeaveRadians = 0
		projectile.Motion = straight
	else
		if projectile.NoHoming then
			-- A shot an earlier parry reversed flies with a straight copy of its motion; a reflect gives the
			-- spec's own back.
			projectile.Motion = ProjectileMotion.MotionOf(projectile.Spec)
		end
		direction = reflectedDirection(projectile, thrower, parrier)
		speed = math.min(speed * projectile.Spec.ReflectedSpeedMultiplier, projectile.Motion.MaxSpeed)
		projectile.DamageScale *= projectile.Spec.ReflectedDamageMultiplier
		projectile.NoHoming = false
	end

	projectile.Owner = parrier
	-- A turned shot is the parrier's now: no longer pinned to the body it was delivered to, and no longer
	-- the realm's (its barrier exemption and its flat realm pricing both belonged to the thrower).
	projectile.Exclusive = nil
	projectile.DomainId = nil
	projectile.Velocity = direction * speed
	projectile.Target = nil
	projectile.RetargetAt = 0
	projectile.ResyncAt = TUNING.HomingResyncSeconds
	projectile.Age = 0
	projectile.Travelled = 0
	projectile.PiercesLeft = projectile.Spec.MaxPierces
	projectile.BouncesLeft = projectile.Spec.MaxBounces
	table.clear(projectile.HitTargets)
	pushLaunch(projectile, at)
end

-- ParryAll's reach beyond the shots in flight (this file's header): the volley's waves not yet fired are
-- dropped -- there is nothing to turn back -- and its ends still waiting on a burst or a split are defused.
local function quellVolley(groupId: number, thrower: Model): ()
	for index = #pending, 1, -1 do
		local entry = pending[index]
		if entry.GroupId == groupId and entry.Owner.Model == thrower then
			pending[index] = pending[#pending]
			pending[#pending] = nil
		end
	end
	for _, ended in endings do
		if ended.GroupId == groupId and ended.Owner.Model == thrower and ended.EffectsPending then
			ended.Defused = true
		end
	end
end

-- Applies the parried shot's ParryResponse, to it alone or (ParryAll) to the whole of its volley still to
-- come for the same thrower. Returns whether the id named a shot at all.
function ProjectileSimulator.Parry(projectileId: number, parrierModel: Model, at: number): boolean
	local projectile = byId[projectileId]
	if projectile == nil then
		return false
	end
	local thrower = projectile.Owner.Model
	local affected = { projectile }
	if projectile.Spec.ParryBehavior == "ParryAll" then
		for _, other in live do
			if other ~= projectile and other.GroupId == projectile.GroupId and other.EndedAt == nil then
				if other.Owner.Model == thrower then
					table.insert(affected, other)
				end
			end
		end
		quellVolley(projectile.GroupId, thrower)
	end
	local parrier = bodyOf(parrierModel)
	for _, shot in affected do
		applyParryResponse(shot, parrier, at)
	end
	return true
end

-- Undoes what the contact on `targetModel` cost the shot -- the defence layer judged it evaded, so it
-- carries on as though it had never touched. The target stays in its hit set: it was not hit, but it
-- must not be hit by this shot a frame later either, the same as an evaded swing.
function ProjectileSimulator.Pass(projectileId: number, targetModel: Model, at: number): boolean
	local projectile = byId[projectileId]
	if projectile == nil then
		return false
	end
	if projectile.Spec.Piercing then
		projectile.PiercesLeft += 1
	end
	if projectile.EndedAt ~= nil and projectile.EndReason == "Hit" and projectile.EndedOn == targetModel then
		revive(projectile)
		pushLaunch(projectile, at)
	end
	return true
end

-- Housekeeping --------------------------------------------------------------------------------------

-- Hands over every event since the last Flush, each stamped with how long before `now` it happened.
function ProjectileSimulator.Flush(now: number): { ProjectileEvent }
	if #pendingEvents == 0 then
		return pendingEvents
	end
	local events = pendingEvents
	pendingEvents = {}
	for _, event in events do
		event.Lead = math.max(now - (event.At or now), 0)
		event.At = nil
	end
	return events
end

function ProjectileSimulator.LiveCount(): number
	return #live
end

-- Spec-only reads of one shot's state, by id.
function ProjectileSimulator.Inspect(projectileId: number): { [string]: any }?
	local projectile = byId[projectileId]
	if projectile == nil then
		return nil
	end
	return {
		Owner = projectile.Owner.Model,
		GroupId = projectile.GroupId,
		Position = projectile.Position,
		Velocity = projectile.Velocity,
		Alive = projectile.EndedAt == nil,
		EndReason = projectile.EndReason,
		PiercesLeft = projectile.PiercesLeft,
		BouncesLeft = projectile.BouncesLeft,
		DamageScale = projectile.DamageScale,
		Target = if projectile.Target then projectile.Target.Model else nil,
		DomainId = projectile.DomainId,
		Exclusive = projectile.Exclusive,
		Age = projectile.Age,
		Travelled = projectile.Travelled,
		Generation = projectile.Generation,
		Returning = projectile.Returning,
		EffectsPending = projectile.EffectsPending,
	}
end

-- Every live shot's id, oldest first. Spec-only.
function ProjectileSimulator.LiveIds(): { number }
	local ids = {}
	for _, projectile in live do
		table.insert(ids, projectile.Id)
	end
	table.sort(ids)
	return ids
end

function ProjectileSimulator.Reset(): ()
	barrier = nil
	table.clear(live)
	table.clear(retired)
	table.clear(byId)
	table.clear(pending)
	table.clear(endings)
	table.clear(volleyStrikes)
	pendingEvents = {}
	nextId = 1
	nextGroupId = 1
end

return ProjectileSimulator
