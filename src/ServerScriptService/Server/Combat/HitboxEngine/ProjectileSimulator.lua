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
	segment: against bodies (CandidateGatherer's include-filtered broadphase, then HitboxGeometry's own
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

	WHAT A PARRY DOES TO A SHOT, which the defence layer asks for through HitboxEngine.ParryProjectile --
	the projectile counterpart of the CancelAttack it calls for a parried swing:
	  * ParryOne affects the shot parried; ParryAll every shot of the same volley still flying and still
	    owned by the thrower. (Shots of the volley that already ended -- consumed by a block in the same
	    batch, say -- stay ended: one parry window stops one attack, the rule DefenseSystem already keeps.)
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
	-- Launch/Update: the homing target, if any.
	Target: Model?,
	-- End: "Hit", "World", "Range", "Expired", "Parried", "Owner", "Barrier" (a realm's closed edge). Update: "Bounce" when the update is a
	-- bounce off the world, nil for a homing re-target/re-sync -- the one fact a client cannot derive
	-- from the new position and velocity alone, read only by presentation (a move's Bounce cue,
	-- MovePresentationTypes). It changes nothing the simulator or a layer above decides.
	Reason: string?,
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
	-- Seconds flown and studs travelled since launch (or since a parry sent it back).
	Age: number,
	Travelled: number,
	PiercesLeft: number,
	BouncesLeft: number,
	HitTargets: { [Model]: boolean },
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
}

local hooks: Hooks? = nil
local barrier: Barrier? = nil

local live: { Projectile } = {}
local retired: { Projectile } = {}
local byId: { [number]: Projectile } = {}
local pendingEvents: { ProjectileEvent } = {}

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
		Motion = if projectile.NoHoming
			then {
				Gravity = projectile.Motion.Gravity,
				Acceleration = projectile.Motion.Acceleration,
				HomingStrength = 0,
				MaxSpeed = projectile.Motion.MaxSpeed,
			}
			else projectile.Motion,
		Target = if projectile.Target then projectile.Target.Model else nil,
		At = at,
	})
end

local function pushUpdate(projectile: Projectile, at: number, reason: string?): ()
	push({
		Kind = "Update",
		Id = projectile.Id,
		GroupId = projectile.GroupId,
		Position = projectile.Position,
		Velocity = projectile.Velocity,
		Lead = 0,
		Target = if projectile.Target then projectile.Target.Model else nil,
		Reason = reason,
		At = at,
	})
end

-- Lifecycle -----------------------------------------------------------------------------------------

local function endProjectile(projectile: Projectile, at: number, reason: string, on: Model?): ()
	if projectile.EndedAt ~= nil then
		return
	end
	projectile.EndedAt = at
	projectile.EndReason = reason
	projectile.EndedOn = on
	push({
		Kind = "End",
		Id = projectile.Id,
		GroupId = projectile.GroupId,
		Position = projectile.Position,
		Velocity = projectile.Velocity,
		Lead = 0,
		Reason = reason,
		At = at,
	})
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
end

-- Puts a retired shot back in flight. The caller re-states it to clients (pushLaunch).
local function revive(projectile: Projectile): ()
	if projectile.EndedAt == nil then
		return
	end
	projectile.EndedAt = nil
	projectile.EndReason = nil
	projectile.EndedOn = nil
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
-- `exclude`, not already hit, within the spec's range and cone, best by its TargetSelection. The owner is
-- never a homing target, even for a shot that may hit its owner -- chasing the thrower is never meant.
local function selectTarget(
	exclude: Model,
	position: Vector3,
	heading: Vector3,
	spec: ProjectileSpec,
	hitTargets: { [Model]: boolean }?
): Owner?
	local range = spec.HomingRange
	local maxAngle = math.rad(spec.HomingMaxAngle)
	local best: Owner? = nil
	local bestScore = math.huge
	for _, candidate in requireHooks().Combatants() do
		if candidate.Model == exclude or (hitTargets and hitTargets[candidate.Model]) then
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
local function keepsTarget(projectile: Projectile): boolean
	local target = projectile.Target
	if target == nil or not isLiveBody(target) or projectile.HitTargets[target.Model] then
		return false
	end
	return (target.RootPart.Position - projectile.Position).Magnitude <= projectile.Spec.HomingRange
end

local function headingOf(projectile: Projectile): Vector3
	local speed = projectile.Velocity.Magnitude
	return if speed > EPSILON then projectile.Velocity / speed else projectile.Owner.RootPart.CFrame.LookVector
end

-- Launch --------------------------------------------------------------------------------------------

-- The volley's aim: a world CFrame at the spawn point (anchor.CFrame * Offset) looking down the volley's
-- centre. The Offset's own rotation always turns the volley -- yaw and pitch aim it, roll turns its plane.
local function aimFor(owner: Owner, anchor: BasePart, definition: AttackDefinition, spec: ProjectileSpec): CFrame
	local spawnPose = anchor.CFrame * definition.Offset
	if spec.SpawnDirection == "Anchor" then
		return spawnPose
	end
	local turn = definition.Offset.Rotation
	local facing = CFrame.new(spawnPose.Position) * owner.RootPart.CFrame.Rotation * turn
	if spec.SpawnDirection == "Target" then
		local target = selectTarget(owner.Model, spawnPose.Position, owner.RootPart.CFrame.LookVector, spec, nil)
		if target then
			local toward = target.RootPart.Position - spawnPose.Position
			if toward.Magnitude > EPSILON then
				return lookAlong(spawnPose.Position, toward.Unit) * turn
			end
		end
	end
	return facing
end

-- The shared launch behind Launch (a swing's Active window) and LaunchAimed (a realm). `aim` is the
-- volley's world CFrame; `options` is nil for a swing.
local function launchVolley(
	owner: Owner,
	aim: CFrame,
	definition: AttackDefinition,
	comboStage: number,
	powerLevel: number,
	now: number,
	options: LaunchOptions?
): (number, number)
	local spec = definition.Projectile
	if spec == nil then
		return 0, 0
	end
	compact(now)

	local fixedTarget: Owner? = nil
	if options and options.Target then
		fixedTarget = requireHooks().CombatantOf(options.Target)
	end
	local exclusive: Model? = if options and options.Exclusive and fixedTarget then fixedTarget.Model else nil

	local groupId = nextGroupId
	nextGroupId += 1
	local motion = ProjectileMotion.MotionOf(spec)
	local body = ProjectileBody.Of(spec)
	local shots = ProjectileMotion.Volley(spec, aim)

	local launched = 0
	for _, shot in shots do
		if #live >= TUNING.MaxLive then
			logger:warn("Projectile ceiling reached; volley cut short", {
				attack = definition.DebugName,
				launched = launched,
				requested = #shots,
			})
			break
		end
		local projectile: Projectile = {
			Id = nextId,
			GroupId = groupId,
			Owner = owner,
			Spec = spec,
			Motion = motion,
			DebugName = definition.DebugName,
			Body = body,
			ComboStage = comboStage,
			PowerLevel = powerLevel,
			Position = shot.Origin,
			Velocity = shot.Direction * spec.Speed,
			Age = 0,
			Travelled = 0,
			PiercesLeft = spec.MaxPierces,
			BouncesLeft = spec.MaxBounces,
			HitTargets = {},
			Target = nil,
			RetargetAt = 0,
			ResyncAt = TUNING.HomingResyncSeconds,
			DamageScale = if options and options.DamageScale then math.max(options.DamageScale, 0) else 1,
			NoHoming = false,
			EndedAt = nil,
			EndReason = nil,
			EndedOn = nil,
			Exclusive = exclusive,
			DomainId = if options then options.DomainId else nil,
		}
		nextId += 1
		if motion.HomingStrength > 0 then
			projectile.Target = fixedTarget or selectTarget(owner.Model, shot.Origin, shot.Direction, spec, nil)
			projectile.RetargetAt = TUNING.RetargetSeconds
		end
		table.insert(live, projectile)
		byId[projectile.Id] = projectile
		pushLaunch(projectile, now)
		launched += 1
	end
	return groupId, launched
end

-- Launches `definition`'s volley for `owner`, from `anchor`. Returns the volley's GroupId and how many
-- shots actually launched (fewer than the spec's count only when MaxLive would be passed).
function ProjectileSimulator.Launch(
	owner: Owner,
	anchor: BasePart,
	definition: AttackDefinition,
	comboStage: number,
	powerLevel: number,
	now: number
): (number, number)
	local spec = definition.Projectile
	if spec == nil then
		return 0, 0
	end
	return launchVolley(owner, aimFor(owner, anchor, definition, spec), definition, comboStage, powerLevel, now, nil)
end

-- Launches `definition`'s volley for `owner` from a world `aim` no swing produced -- see this file's
-- header (A VOLLEY NOT THROWN BY A SWING). The owner must be a registered combatant (it is who the
-- contacts are reported as coming from); the volley's own SpawnDirection is not consulted -- `aim` is it.
function ProjectileSimulator.LaunchAimed(
	owner: Owner,
	aim: CFrame,
	definition: AttackDefinition,
	powerLevel: number,
	now: number,
	options: LaunchOptions?
): (number, number)
	return launchVolley(owner, aim, definition, 1, powerLevel, now, options)
end

-- Holds (or, with nil, clears) the barrier slot -- see this file's header.
function ProjectileSimulator.SetBarrier(callback: Barrier?): ()
	barrier = callback
end

-- Contacts ------------------------------------------------------------------------------------------

local function report(projectile: Projectile, target: Owner, part: BasePart, at: Vector3, now: number): ()
	local heading = headingOf(projectile)
	local body = projectile.Body
	local contact: ProjectileTypes.ProjectileContact = {
		Id = projectile.Id,
		GroupId = projectile.GroupId,
		SourcePosition = at - heading * TUNING.SourceProbeStuds,
		Direction = heading,
		Parryable = projectile.Spec.ParryBehavior ~= "CannotParry",
		StaggersOwner = projectile.Spec.ParryResponse == "ExistingParry",
		DamageScale = projectile.DamageScale,
		DomainId = projectile.DomainId,
	}
	requireHooks().Report({
		Attacker = projectile.Owner.Model,
		Target = target.Model,
		TargetPart = part,
		Shape = body.Shape,
		-- A copy: a consumer may keep a report, and the body's own table is shared by every shot of the volley.
		Dimensions = table.clone(body.Dimensions),
		ContactPosition = part:GetClosestPointOnSurface(at),
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
		if owner == nil or projectile.HitTargets[owner.Model] then
			continue
		end
		local exclusive = projectile.Exclusive
		if exclusive ~= nil and owner.Model ~= exclusive then
			continue
		end
		if owner.Model == projectile.Owner.Model and not mayHitOwner(projectile) then
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
		projectile.HitTargets[contact.Owner.Model] = true
		report(projectile, contact.Owner, contact.Part, at, now)
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

local function stepOne(projectile: Projectile, dt: number, now: number): ()
	if projectile.EndedAt ~= nil then
		return
	end
	local spec = projectile.Spec

	projectile.Age += dt
	if projectile.Age >= spec.LifetimeSeconds then
		endProjectile(projectile, now, "Expired", nil)
		return
	end

	local homes = projectile.Motion.HomingStrength > 0 and not projectile.NoHoming
	local homingPoint: Vector3? = nil
	if homes and projectile.Exclusive ~= nil then
		-- Pinned to one body: follow it while it lives, and never pick another.
		local target = projectile.Target
		if target and isLiveBody(target) then
			homingPoint = target.RootPart.Position
		end
	elseif homes then
		if not keepsTarget(projectile) then
			local previous = projectile.Target
			projectile.Target = nil
			if projectile.Age >= projectile.RetargetAt then
				projectile.RetargetAt = projectile.Age + TUNING.RetargetSeconds
				projectile.Target = selectTarget(
					projectile.Owner.Model,
					projectile.Position,
					headingOf(projectile),
					spec,
					projectile.HitTargets
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
	local to, velocity = ProjectileMotion.Integrate(from, projectile.Velocity, projectile.Motion, dt, homingPoint)

	-- Range: the step stops where the range runs out.
	local rangeLeft = math.max(spec.MaxRange - projectile.Travelled, 0)
	local stepLength = (to - from).Magnitude
	local rangeEnds = stepLength >= rangeLeft
	if rangeEnds and stepLength > EPSILON then
		to = from + (to - from) * (rangeLeft / stepLength)
	end

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

	sweepBodies(projectile, from, reach, now)
	if projectile.EndedAt ~= nil then
		return
	end
	projectile.Travelled += (reach - from).Magnitude

	if worldHit then
		if spec.CollisionBehavior == "Bounce" and projectile.BouncesLeft > 0 then
			projectile.BouncesLeft -= 1
			projectile.Velocity = ProjectileMotion.Reflect(velocity, worldHit.Normal)
			projectile.Position = reach + worldHit.Normal * TUNING.BounceSeparationStuds
			pushUpdate(projectile, now, "Bounce")
		else
			projectile.Position = reach
			projectile.Velocity = velocity
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
		endProjectile(projectile, at, "Parried", nil)
		return
	end

	local thrower = projectile.Owner
	revive(projectile)
	local speed = projectile.Velocity.Magnitude
	if speed <= EPSILON then
		speed = projectile.Spec.Speed
	end
	local direction: Vector3
	if response == "Reverse" then
		direction = -headingOf(projectile)
		projectile.NoHoming = true
	else
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

-- Applies the parried shot's ParryResponse, to it alone or (ParryAll) to every shot of its volley still
-- flying for the same thrower. Returns whether the id named a shot at all.
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
	pendingEvents = {}
	nextId = 1
	nextGroupId = 1
end

return ProjectileSimulator
