--!strict
--[[
	ProjectileTypes.lua

	Owns: the projectile vocabulary -- what a projectile attack IS to HitboxEngine (ProjectileSpec), what
	a projectile contact adds to a HitReport (ProjectileContact), the option lists, the authorable bounds,
	and the ONE field list every copy, encoding and validation of a spec walks.

	A PROJECTILE IS A WAY OF DELIVERING AN ATTACK, NOT A SECOND COMBAT SYSTEM. A move with a Projectile
	block is thrown through the identical path as any other (AttackRequestSystem -> HitboxEngine), keeps
	its windup, active window, recovery, cooldown, feint and clip sync, and its contacts come out of the
	engine's one OnHit signal as ordinary HitReports -- so DefenseSystem decides block/parry/evade and
	DamageSystem prices the hit exactly as it does a swing. The only difference is what happens when the
	Active window opens: instead of sampling a volume attached to the body, the engine launches volumes
	that fly (Server/Combat/HitboxEngine/ProjectileSimulator.lua).

	ENGINE VOCABULARY, AUTHORED DIRECTLY -- the same choice MoveTypes made for the melee hitbox. The Move
	Editor's MoveProjectileConfig IS this ProjectileSpec, so MoveTypes.ToEngineAttackDefinition copies it
	rather than translating it, and there is no second shape to drift.

	THE FIELD LIST (Fields, below) IS THE SCHEMA. Copy, the wire encoding, Validate and the engine's
	sanitiser all iterate it, so a field added here is carried by every one of them at once. The failure
	it closes is the one MoveTypes.Clone's header describes: a hand-written copy that forgets a field.

	Where a field's semantics are not obvious from its name:
	  * Shape and the body's measurements (2026-10-01). A shot is a VOLUME, not only a point with a radius:
	    Shape names one of HitboxTypes' shapes (Shapes, below -- the ones that make sense flying) and Size,
	    Length, Width, Height, InnerRadius and AngleDegrees are the measurements it reads, exactly the
	    fields HitboxTypes.FieldsFor lists for it (Size IS the Radius field). The body is oriented along
	    its heading; a shape that grows from its origin (Cone, Pyramid, Wedge, Frustum) flies point first.
	    Sphere is the default and reads only Size, so every record from before this existed still means
	    what it meant. Shared/HitboxEngine/ProjectileBody.lua turns a spec into the geometry the simulator
	    sweeps and the client draws.
	  * Spread. Single fires ONE projectile whatever Count says (the count is kept, so switching back
	    restores it). Fan spreads Count evenly across SpreadAngle in the aim's horizontal plane -- 5 at 30
	    degrees fly at -15, -7.5, 0, 7.5, 15 -- and a 360 fan is a full ring with no doubled shot.
	    Horizontal and Vertical are PARALLEL formations, a row or a column Spacing studs apart, none
	    diverging. Radial is a ring around the aim axis, every shot SpreadAngle/2 off it (a hollow cone;
	    180 is a flat disc). The aim's roll turns every pattern's plane (a Fan rolled 90 is vertical).
	  * Size is the RADIUS of a round shape, in studs -- the sphere that flies by default.
	  * Gravity pulls down in studs/s^2 (negative floats up). Acceleration is along the heading; speed is
	    clamped to [0, Limits.Speed.Max], so a decelerating shot stops and hangs until its lifetime ends.
	  * Characters and world are separate questions. Piercing (+ MaxPierces) is what a CHARACTER does to
	    it: off, the first target ends it; on, it passes through MaxPierces targets and the next ends it.
	    CollisionBehavior is what WORLD GEOMETRY does to it: Destroy, Bounce (off the surface, MaxBounces
	    times, then destroyed), or Continue (passes through walls).
	  * Homing turns the heading toward a target at HomingStrength degrees per second, choosing among
	    registered combatants within HomingRange and HomingMaxAngle of its heading, by TargetSelection
	    ("Nearest" by distance, "Aim" by smallest angle off the heading). SpawnDirection "Target" aims the
	    volley with the same range, cone and selection, so both answers agree about who "the target" is.
	  * Parry. ParryBehavior is how the EXISTING parry treats this projectile: ParryOne affects the shot
	    that was parried, ParryAll affects every live shot of the same volley (its GroupId) and drops its
	    waves not yet fired, CannotParry makes a parry window read as a held guard -- the shot is blocked,
	    never parried. ParryResponse is
	    what a parry does to the shot: ExistingParry (it is destroyed and the thrower is staggered exactly
	    as a parried swing is), Destroy, Reflect (the parrier owns it, it flies in ReflectionDirection with
	    the two Reflected multipliers applied), or Reverse (the parrier owns it, it retraces its path).

	  * Formations beyond a line (2026-10-26). Grid lays Count shots out in rows of Columns, Spacing apart
	    both ways, all flying parallel. Circle puts them on a ring FormationRadius round the aim axis, all
	    flying parallel (a Ring -- Radial -- shares one origin and diverges instead). FormationRadius also
	    pushes every Fan and Radial shot's ORIGIN out along its own heading, so a 360 fan with a radius is a
	    ring of emitters round the thrower firing outward. ConvergeDistance (0 = off) re-aims every shot
	    through one point that far down the aim: a Row or a Circle that closes on a spot.
	  * Waves (2026-10-26). WaveCount volleys, WaveIntervalSeconds apart; inside a wave ShotIntervalSeconds
	    staggers the shots one by one (0 fires them together). Each wave is rolled WaveRollDegrees further
	    round the aim axis than the last -- a Circle or a Ring with a roll is a spiral. WaveAim Follow
	    re-aims every wave from where the thrower is now; Fixed fires every wave along the aim the first one
	    took. AlternateSides fires every second wave from the mirror image of the spawn -- the other hand
	    for a hand anchor, the offset's right/left flipped for any anchor (dual wielding). A wave not yet
	    fired belongs to its swing: an INTERRUPTED swing (stun, parry, death) fires no more of them; one that
	    completes fires them all.
	  * SpawnFrom. Anchor is the thrower's anchor plus the offset. Target stands the offset in a frame at the
	    target -- right, up and forward relative to the line from the thrower to it -- so "Up 25, fires At
	    target" drops a shot onto someone from above. The target is picked exactly as SpawnDirection Target
	    picks one (HomingRange, HomingMaxAngle, TargetSelection); with none in reach it spawns at the anchor.
	  * Height. SpawnHeight lifts the spawn point along WORLD up, after the offset -- unlike the offset's own
	    Up, which is the anchor's up and so tilts with a hand or a weapon. HeightFrom Spawn adds it to wherever
	    the offset put the spawn; Ground measures it from the ground under that point instead (the first
	    world surface below, the same cast the walls use; with no ground within reach it falls back to
	    Spawn), so a wave can skim the floor wherever the thrower stands, or a strike start 25 studs above it.
	    Only the spawn point moves: the volley's aim is still the anchor's or the thrower's.
	  * Range and speed. RangeMode Path measures MaxRange along the flight (a bouncing or homing shot spends
	    it on every turn); Displacement measures it as the straight distance from where the shot spawned.
	    MinSpeed and MaxSpeed bound what Acceleration and Gravity can do to its speed.
	  * Weave. WeaveDegrees swings the heading that far either side of its course, WeaveFrequency times a
	    second, in WeavePlane (Horizontal: side to side; Vertical: up and down). It is a function of the shot's
	    age, so the client's visual weaves on the same path at any frame rate. WeaveMirrored inverts it on
	    every second shot of a volley -- two shots in a Row braid.
	  * Return. ReturnAfterSeconds (0 = never) is a boomerang: at that age the shot turns back to its thrower
	    at ReturnTurnRate degrees per second, may hit again on the way back, and ends ("Returned") when it
	    reaches them. MaxRange starts over for the way back.
	  * Homing's window. HomingDelaySeconds is how long a shot flies straight before it starts to turn;
	    HomingDurationSeconds (0 = the whole flight) how long it turns after that. LeadTarget aims a volley
	    fired At target where the target will be, for the shot's speed, rather than where it is.
	  * Contacts. RehitSeconds (0 = once) lets a piercing shot strike the same body again after that long;
	    each strike spends a pierce. ProximityRadius (0 = off) ends the shot ("Proximity") as soon as a body
	    it could hit is that close -- a mine, a proximity fuse. Damage falls off linearly from
	    FalloffStartStuds travelled to MaxRange, down to FalloffMinScale (1 = no falloff).
	  * End effects. When a shot ends, ExplodeOn and SplitOn decide whether it bursts and whether it splits:
	    Impact is a body, the world or a proximity fuse; Expire is its range or lifetime running out; Always
	    is both. A shot that is parried, stopped by a barrier or returns to its thrower does neither. A burst
	    strikes every body within ExplosionRadius but the ones this shot already struck, priced at
	    ExplosionDamageScale of the shot, unparryable (a parry window reads as a guard). A split launches
	    SplitCount shots from where it ended, in SplitPattern across SplitAngle, at SplitSpeedScale of the
	    speed, each the same shot otherwise -- for SplitGenerations generations. ExplosionScope says which
	    generation bursts: Every, SplitOnly (a cluster bomb: only the bomblets burst) or OriginalOnly.
	  * Budget. A cast may fire at most Caps.ShotsPerCast shots counting every wave and every split, over at
	    most Caps.CastSeconds; Validate refuses one past either (ProjectileOverBudget, ProjectileCastTooLong)
	    rather than guess which number to cut. Warnings lists settings that cannot take effect as set.

	Does not own: flight, collision or parry mechanics (ProjectileSimulator), the motion math
	(ProjectileMotion), what a contact MEANS (DefenseSystem, DamageSystem), or the move schema around the
	block (MoveTypes).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Sanitize = require(ReplicatedStorage.Shared.Sanitize)

local ProjectileTypes = {}

export type SpreadPattern = "Single" | "Fan" | "Horizontal" | "Vertical" | "Radial" | "Grid" | "Circle"
export type BodyShape =
	"Sphere"
	| "Capsule"
	| "Ellipsoid"
	| "Cylinder"
	| "Box"
	| "Cone"
	| "Pyramid"
	| "Wedge"
	| "Frustum"
	| "Crescent"
	| "Cross"
	| "Pillar"
export type SpawnDirection = "Facing" | "Anchor" | "Target"
export type CollisionBehavior = "Destroy" | "Bounce" | "Continue"
export type TargetSelection = "Nearest" | "Aim"
export type ParryBehavior = "ParryOne" | "ParryAll" | "CannotParry"
export type ParryResponse = "ExistingParry" | "Destroy" | "Reflect" | "Reverse"
export type ReflectionDirection = "ToOwner" | "ParrierFacing" | "Mirror"
export type WaveAim = "Follow" | "Fixed"
export type SpawnFrom = "Anchor" | "Target"
export type RangeMode = "Path" | "Displacement"
export type WeavePlane = "Horizontal" | "Vertical"
-- Which end reasons trigger an end effect (this file's header, End effects).
export type EndTrigger = "Never" | "Impact" | "Expire" | "Always"
export type ExplosionScope = "Every" | "SplitOnly" | "OriginalOnly"
export type SplitPattern = "Fan" | "Radial"
export type HeightFrom = "Spawn" | "Ground"

export type ProjectileSpec = {
	Count: number,
	SpreadPattern: SpreadPattern,
	SpreadAngle: number,
	Spacing: number,
	Speed: number,
	LifetimeSeconds: number,
	MaxRange: number,
	Shape: BodyShape,
	Size: number,
	Length: number,
	Width: number,
	Height: number,
	InnerRadius: number,
	AngleDegrees: number,
	SpawnDirection: SpawnDirection,
	Gravity: number,
	Acceleration: number,
	Piercing: boolean,
	MaxPierces: number,
	CollisionBehavior: CollisionBehavior,
	MaxBounces: number,
	Homing: boolean,
	HomingStrength: number,
	HomingMaxAngle: number,
	HomingRange: number,
	TargetSelection: TargetSelection,
	CanHitOwner: boolean,
	ParryBehavior: ParryBehavior,
	ParryResponse: ParryResponse,
	ReflectionDirection: ReflectionDirection,
	ReflectedDamageMultiplier: number,
	ReflectedSpeedMultiplier: number,
	-- 2026-10-26 (this file's header, "Formations beyond a line" onward).
	Columns: number,
	FormationRadius: number,
	ConvergeDistance: number,
	WaveCount: number,
	WaveIntervalSeconds: number,
	ShotIntervalSeconds: number,
	WaveRollDegrees: number,
	WaveAim: WaveAim,
	AlternateSides: boolean,
	SpawnFrom: SpawnFrom,
	SpawnHeight: number,
	HeightFrom: HeightFrom,
	RangeMode: RangeMode,
	MinSpeed: number,
	MaxSpeed: number,
	WeaveDegrees: number,
	WeaveFrequency: number,
	WeavePlane: WeavePlane,
	WeaveMirrored: boolean,
	ReturnAfterSeconds: number,
	ReturnTurnRate: number,
	HomingDelaySeconds: number,
	HomingDurationSeconds: number,
	LeadTarget: boolean,
	RehitSeconds: number,
	ProximityRadius: number,
	FalloffStartStuds: number,
	FalloffMinScale: number,
	ExplodeOn: EndTrigger,
	ExplosionRadius: number,
	ExplosionDamageScale: number,
	ExplosionScope: ExplosionScope,
	SplitOn: EndTrigger,
	SplitCount: number,
	SplitPattern: SplitPattern,
	SplitAngle: number,
	SplitSpeedScale: number,
	SplitGenerations: number,
}

-- What a projectile contact carries on its HitReport, beyond what every contact does. Everything a layer
-- above needs to treat a shot as a shot and not as the thrower's body, and nothing it would have to ask
-- the engine for later:
--   * SourcePosition -- where the blow came FROM, for the defender's block arc. A projectile hits from its
--     own direction of travel, not from wherever the thrower is standing now.
--   * Direction -- unit heading at the contact, for knockback along the flight.
--   * Parryable / StaggersOwner -- ParryBehavior and ParryResponse, reduced to the two questions the
--     defence layer asks.
--   * DamageScale -- the product of every Reflected multiplier this shot has picked up, 1 for a shot
--     nobody has turned. An opaque passthrough, like ComboStage: the engine carries it, the damage layer
--     applies it.
--   * DomainId -- the realm that delivered this shot (Server/Combat/Domain), nil for every shot a swing
--     threw. Opaque passthrough again: the engine stamps it, the damage layer prices a realm's contact
--     flat (it is the realm striking, not a link in its owner's string).
export type ProjectileContact = {
	Id: number,
	GroupId: number,
	SourcePosition: Vector3,
	Direction: Vector3,
	Parryable: boolean,
	StaggersOwner: boolean,
	DamageScale: number,
	DomainId: string?,
	-- True for a burst's contact (ExplodeOn): not the shot touching, but the blast round where it ended.
	-- SourcePosition is the blast's centre and Parryable is false, so no layer needs to branch on it;
	-- presentation and the trace read it.
	Blast: boolean?,
}

-- Option lists, in the order the editor offers them.
-- The shapes a shot may be: HitboxTypes' own, less the ones that make no sense flying (Beam and Arc are
-- reaches from a body, Hemisphere is a dome sat on a face). Spelled out here rather than read from
-- HitboxTypes because HitboxTypes requires this module; MoveTypes.spec pins every entry to a real
-- ShapeKind.
ProjectileTypes.Shapes = {
	"Sphere",
	"Capsule",
	"Ellipsoid",
	"Cylinder",
	"Box",
	"Cone",
	"Pyramid",
	"Wedge",
	"Frustum",
	"Crescent",
	"Cross",
	"Pillar",
} :: { BodyShape }
ProjectileTypes.SpreadPatterns =
	{ "Single", "Fan", "Horizontal", "Vertical", "Radial", "Grid", "Circle" } :: { SpreadPattern }
ProjectileTypes.SpawnDirections = { "Facing", "Anchor", "Target" } :: { SpawnDirection }
ProjectileTypes.CollisionBehaviors = { "Destroy", "Bounce", "Continue" } :: { CollisionBehavior }
ProjectileTypes.TargetSelections = { "Aim", "Nearest" } :: { TargetSelection }
ProjectileTypes.ParryBehaviors = { "ParryOne", "ParryAll", "CannotParry" } :: { ParryBehavior }
ProjectileTypes.ParryResponses = { "ExistingParry", "Destroy", "Reflect", "Reverse" } :: { ParryResponse }
ProjectileTypes.ReflectionDirections = { "ToOwner", "ParrierFacing", "Mirror" } :: { ReflectionDirection }
ProjectileTypes.WaveAims = { "Follow", "Fixed" } :: { WaveAim }
ProjectileTypes.SpawnFroms = { "Anchor", "Target" } :: { SpawnFrom }
ProjectileTypes.RangeModes = { "Path", "Displacement" } :: { RangeMode }
ProjectileTypes.WeavePlanes = { "Horizontal", "Vertical" } :: { WeavePlane }
ProjectileTypes.EndTriggers = { "Never", "Impact", "Expire", "Always" } :: { EndTrigger }
ProjectileTypes.ExplosionScopes = { "Every", "SplitOnly", "OriginalOnly" } :: { ExplosionScope }
ProjectileTypes.SplitPatterns = { "Fan", "Radial" } :: { SplitPattern }
ProjectileTypes.HeightFroms = { "Spawn", "Ground" } :: { HeightFrom }

-- Which ProjectileSimulator end reasons each EndTrigger class covers. A reason in neither (Parried,
-- Barrier, Returned, Owner) never triggers an end effect.
ProjectileTypes.ImpactReasons = { Hit = true, World = true, Proximity = true } :: { [string]: boolean }
ProjectileTypes.ExpireReasons = { Range = true, Expired = true } :: { [string]: boolean }

-- Whether a shot that ended for `reason` fires an effect set to `trigger`.
function ProjectileTypes.Triggers(trigger: EndTrigger, reason: string): boolean
	if trigger == "Never" then
		return false
	end
	local impact = ProjectileTypes.ImpactReasons[reason] == true
	local expire = ProjectileTypes.ExpireReasons[reason] == true
	if trigger == "Impact" then
		return impact
	elseif trigger == "Expire" then
		return expire
	end
	return impact or expire
end

-- What one cast may cost, whatever is authored (this file's header, Budget). HitboxEngineConstants
-- .Projectile.MaxLive still bounds the whole server on top of it.
ProjectileTypes.Caps = {
	ShotsPerCast = 128,
	CastSeconds = 6,
}

type Range = { Min: number, Max: number }

-- Authorable bounds, in Constants.MoveEditor.Limits' {Min, Max} shape: MoveRegistryManager.Validate
-- clamps against them and the editor renders its fields from them, so the two cannot disagree about a
-- range -- the arrangement GrabConstants.Limits already has with the Grab fields.
ProjectileTypes.Limits = {
	Count = { Min = 1, Max = 32 },
	SpreadAngle = { Min = 0, Max = 360 },
	Spacing = { Min = 0, Max = 20 },
	Speed = { Min = 1, Max = 400 },
	LifetimeSeconds = { Min = 0.1, Max = 10 },
	MaxRange = { Min = 1, Max = 1000 },
	Size = { Min = 0.1, Max = 24 },
	Length = { Min = 0.2, Max = 60 },
	Width = { Min = 0.2, Max = 40 },
	Height = { Min = 0.2, Max = 40 },
	InnerRadius = { Min = 0, Max = 24 },
	AngleDegrees = { Min = 1, Max = 179 },
	Gravity = { Min = -200, Max = 200 },
	Acceleration = { Min = -400, Max = 400 },
	MaxPierces = { Min = 1, Max = 64 },
	MaxBounces = { Min = 1, Max = 32 },
	HomingStrength = { Min = 0, Max = 1080 },
	HomingMaxAngle = { Min = 0, Max = 180 },
	HomingRange = { Min = 0, Max = 500 },
	ReflectedDamageMultiplier = { Min = 0, Max = 5 },
	ReflectedSpeedMultiplier = { Min = 0.1, Max = 5 },
	Columns = { Min = 1, Max = 16 },
	FormationRadius = { Min = 0, Max = 30 },
	ConvergeDistance = { Min = 0, Max = 300 },
	WaveCount = { Min = 1, Max = 12 },
	WaveIntervalSeconds = { Min = 0, Max = 2 },
	ShotIntervalSeconds = { Min = 0, Max = 0.5 },
	WaveRollDegrees = { Min = -180, Max = 180 },
	SpawnHeight = { Min = -20, Max = 100 },
	MinSpeed = { Min = 0, Max = 400 },
	MaxSpeed = { Min = 1, Max = 400 },
	WeaveDegrees = { Min = 0, Max = 90 },
	WeaveFrequency = { Min = 0.1, Max = 10 },
	ReturnAfterSeconds = { Min = 0, Max = 10 },
	ReturnTurnRate = { Min = 30, Max = 1440 },
	HomingDelaySeconds = { Min = 0, Max = 5 },
	HomingDurationSeconds = { Min = 0, Max = 10 },
	RehitSeconds = { Min = 0, Max = 5 },
	ProximityRadius = { Min = 0, Max = 30 },
	FalloffStartStuds = { Min = 0, Max = 1000 },
	FalloffMinScale = { Min = 0, Max = 1 },
	ExplosionRadius = { Min = 0.5, Max = 60 },
	ExplosionDamageScale = { Min = 0, Max = 5 },
	SplitCount = { Min = 2, Max = 16 },
	SplitAngle = { Min = 0, Max = 360 },
	SplitSpeedScale = { Min = 0.1, Max = 3 },
	SplitGenerations = { Min = 1, Max = 3 },
} :: { [string]: Range }

type Field = {
	Name: string,
	Kind: "Number" | "Enum" | "Boolean",
	Default: any,
	-- Number: rounded to a whole number after clamping.
	Integer: boolean?,
	-- Enum: the legal values.
	Options: { string }?,
}

-- THE schema -- see this file's header. Order is the order a spec is written out in.
ProjectileTypes.Fields = {
	{ Name = "Count", Kind = "Number", Default = 1, Integer = true },
	{ Name = "SpreadPattern", Kind = "Enum", Default = "Single", Options = ProjectileTypes.SpreadPatterns },
	{ Name = "SpreadAngle", Kind = "Number", Default = 30 },
	{ Name = "Spacing", Kind = "Number", Default = 2 },
	{ Name = "Speed", Kind = "Number", Default = 90 },
	{ Name = "LifetimeSeconds", Kind = "Number", Default = 2 },
	{ Name = "MaxRange", Kind = "Number", Default = 150 },
	{ Name = "Shape", Kind = "Enum", Default = "Sphere", Options = ProjectileTypes.Shapes },
	{ Name = "Size", Kind = "Number", Default = 1 },
	{ Name = "Length", Kind = "Number", Default = 4 },
	{ Name = "Width", Kind = "Number", Default = 2 },
	{ Name = "Height", Kind = "Number", Default = 2 },
	{ Name = "InnerRadius", Kind = "Number", Default = 0 },
	{ Name = "AngleDegrees", Kind = "Number", Default = 60 },
	{ Name = "SpawnDirection", Kind = "Enum", Default = "Facing", Options = ProjectileTypes.SpawnDirections },
	{ Name = "Gravity", Kind = "Number", Default = 0 },
	{ Name = "Acceleration", Kind = "Number", Default = 0 },
	{ Name = "Piercing", Kind = "Boolean", Default = false },
	{ Name = "MaxPierces", Kind = "Number", Default = 1, Integer = true },
	{ Name = "CollisionBehavior", Kind = "Enum", Default = "Destroy", Options = ProjectileTypes.CollisionBehaviors },
	{ Name = "MaxBounces", Kind = "Number", Default = 1, Integer = true },
	{ Name = "Homing", Kind = "Boolean", Default = false },
	{ Name = "HomingStrength", Kind = "Number", Default = 180 },
	{ Name = "HomingMaxAngle", Kind = "Number", Default = 60 },
	{ Name = "HomingRange", Kind = "Number", Default = 60 },
	{ Name = "TargetSelection", Kind = "Enum", Default = "Aim", Options = ProjectileTypes.TargetSelections },
	{ Name = "CanHitOwner", Kind = "Boolean", Default = false },
	{ Name = "ParryBehavior", Kind = "Enum", Default = "ParryOne", Options = ProjectileTypes.ParryBehaviors },
	{ Name = "ParryResponse", Kind = "Enum", Default = "ExistingParry", Options = ProjectileTypes.ParryResponses },
	{
		Name = "ReflectionDirection",
		Kind = "Enum",
		Default = "ToOwner",
		Options = ProjectileTypes.ReflectionDirections,
	},
	{ Name = "ReflectedDamageMultiplier", Kind = "Number", Default = 1 },
	{ Name = "ReflectedSpeedMultiplier", Kind = "Number", Default = 1 },
	-- 2026-10-26. Every default reproduces the behaviour from before its field existed, so a record saved
	-- earlier flies exactly as it did.
	{ Name = "Columns", Kind = "Number", Default = 3, Integer = true },
	{ Name = "FormationRadius", Kind = "Number", Default = 0 },
	{ Name = "ConvergeDistance", Kind = "Number", Default = 0 },
	{ Name = "WaveCount", Kind = "Number", Default = 1, Integer = true },
	{ Name = "WaveIntervalSeconds", Kind = "Number", Default = 0.25 },
	{ Name = "ShotIntervalSeconds", Kind = "Number", Default = 0 },
	{ Name = "WaveRollDegrees", Kind = "Number", Default = 0 },
	{ Name = "WaveAim", Kind = "Enum", Default = "Follow", Options = ProjectileTypes.WaveAims },
	{ Name = "AlternateSides", Kind = "Boolean", Default = false },
	{ Name = "SpawnFrom", Kind = "Enum", Default = "Anchor", Options = ProjectileTypes.SpawnFroms },
	{ Name = "SpawnHeight", Kind = "Number", Default = 0 },
	{ Name = "HeightFrom", Kind = "Enum", Default = "Spawn", Options = ProjectileTypes.HeightFroms },
	{ Name = "RangeMode", Kind = "Enum", Default = "Path", Options = ProjectileTypes.RangeModes },
	{ Name = "MinSpeed", Kind = "Number", Default = 0 },
	-- The old global cap (Limits.Speed.Max), which every shot was clamped to before this field.
	{ Name = "MaxSpeed", Kind = "Number", Default = 400 },
	{ Name = "WeaveDegrees", Kind = "Number", Default = 0 },
	{ Name = "WeaveFrequency", Kind = "Number", Default = 2 },
	{ Name = "WeavePlane", Kind = "Enum", Default = "Horizontal", Options = ProjectileTypes.WeavePlanes },
	{ Name = "WeaveMirrored", Kind = "Boolean", Default = false },
	{ Name = "ReturnAfterSeconds", Kind = "Number", Default = 0 },
	{ Name = "ReturnTurnRate", Kind = "Number", Default = 540 },
	{ Name = "HomingDelaySeconds", Kind = "Number", Default = 0 },
	{ Name = "HomingDurationSeconds", Kind = "Number", Default = 0 },
	{ Name = "LeadTarget", Kind = "Boolean", Default = false },
	{ Name = "RehitSeconds", Kind = "Number", Default = 0 },
	{ Name = "ProximityRadius", Kind = "Number", Default = 0 },
	{ Name = "FalloffStartStuds", Kind = "Number", Default = 0 },
	{ Name = "FalloffMinScale", Kind = "Number", Default = 1 },
	{ Name = "ExplodeOn", Kind = "Enum", Default = "Never", Options = ProjectileTypes.EndTriggers },
	{ Name = "ExplosionRadius", Kind = "Number", Default = 8 },
	{ Name = "ExplosionDamageScale", Kind = "Number", Default = 1 },
	{ Name = "ExplosionScope", Kind = "Enum", Default = "Every", Options = ProjectileTypes.ExplosionScopes },
	{ Name = "SplitOn", Kind = "Enum", Default = "Never", Options = ProjectileTypes.EndTriggers },
	{ Name = "SplitCount", Kind = "Number", Default = 3, Integer = true },
	{ Name = "SplitPattern", Kind = "Enum", Default = "Fan", Options = ProjectileTypes.SplitPatterns },
	{ Name = "SplitAngle", Kind = "Number", Default = 60 },
	{ Name = "SplitSpeedScale", Kind = "Number", Default = 1 },
	{ Name = "SplitGenerations", Kind = "Number", Default = 1, Integer = true },
} :: { Field }

-- Starting points ------------------------------------------------------------------------------------------
--
-- A WEAPON, a spell or a wave by name. The editor's "Start from" menu writes Values onto the spec -- its
-- shape and measurements and nothing else, so the flight, the volley and the parry answers an author has
-- set are kept. Every value is inside Limits and names a field its shape reads (MoveTypes.spec pins both).
export type Preset = {
	Id: string,
	Label: string,
	Note: string,
	Values: { [string]: any },
}

ProjectileTypes.Presets = {
	{
		Id = "Orb",
		Label = "Orb -- a plain sphere",
		Note = "The default. Round, so it is equally easy to hit from every side.",
		Values = { Shape = "Sphere", Size = 1 },
	},
	{
		Id = "Fireball",
		Label = "Fireball -- a big sphere",
		Note = "Slow and wide. A target has to leave the whole line, not just step aside.",
		Values = { Shape = "Sphere", Size = 2.5 },
	},
	{
		Id = "Arrow",
		Label = "Arrow -- a thin shaft",
		Note = "Narrow and fast; threads a gap a sphere would not.",
		Values = { Shape = "Capsule", Size = 0.3, Length = 3.5 },
	},
	{
		Id = "Spear",
		Label = "Spear -- a long capsule",
		Note = "Long as well as thin: it clips a target a body-length before the tip arrives.",
		Values = { Shape = "Capsule", Size = 0.55, Length = 8 },
	},
	{
		Id = "Kunai",
		Label = "Kunai -- a pointed dart",
		Note = "A small pyramid flying point first.",
		Values = { Shape = "Pyramid", Width = 0.9, Height = 0.5, Length = 3 },
	},
	{
		Id = "Shuriken",
		Label = "Shuriken -- a flat cross",
		Note = "Four short blades in one plane; small, flat and quick.",
		Values = { Shape = "Cross", Width = 3.2, Length = 3.2, Height = 0.5, Size = 0.45 },
	},
	{
		Id = "SwordWave",
		Label = "Sword wave -- a crescent",
		Note = "A cut thrown forward: wide across, thin front to back, bulging in the direction of travel.",
		Values = { Shape = "Crescent", Size = 5, InnerRadius = 4.2, Length = 2, Height = 1.6 },
	},
	{
		Id = "Cutter",
		Label = "Cutter -- a flat disc",
		Note = "A spinning saucer, wide and very thin.",
		Values = { Shape = "Pillar", Size = 2.6, Height = 0.5 },
	},
	{
		Id = "Boulder",
		Label = "Boulder -- a squat ellipsoid",
		Note = "Heavy and blunt; wider and taller than long.",
		Values = { Shape = "Ellipsoid", Width = 5, Height = 4.5, Length = 5 },
	},
	{
		Id = "Log",
		Label = "Log -- a rolling cylinder",
		Note = "A thick rod flying end first.",
		Values = { Shape = "Cylinder", Size = 1.2, Length = 7 },
	},
	{
		Id = "Wall",
		Label = "Wall -- a slab",
		Note = "A flat sheet that has to be jumped, not sidestepped.",
		Values = { Shape = "Box", Width = 12, Height = 6, Length = 1.5 },
	},
	{
		Id = "Drill",
		Label = "Drill -- a cone",
		Note = "A cone flying point first; narrow at the leading edge.",
		Values = { Shape = "Cone", Length = 5, AngleDegrees = 40 },
	},
	{
		Id = "Blade",
		Label = "Blade -- a flat wedge",
		Note = "A dagger-shaped slab: pointed ahead, widening behind, always the same height.",
		Values = { Shape = "Wedge", Width = 3, Height = 0.8, Length = 5 },
	},
	{
		Id = "Tide",
		Label = "Tide -- a low wide bar",
		Note = "A box wider than the player and no taller than their shins.",
		Values = { Shape = "Box", Width = 16, Height = 2, Length = 3 },
	},
} :: { Preset }

function ProjectileTypes.PresetById(id: string): Preset?
	for _, preset in ProjectileTypes.Presets do
		if preset.Id == id then
			return preset
		end
	end
	return nil
end

-- A fresh spec at every default -- what the editor seeds a newly projectile move with.
function ProjectileTypes.Defaults(): ProjectileSpec
	local spec = {} :: any
	for _, field in ProjectileTypes.Fields do
		spec[field.Name] = field.Default
	end
	return spec :: ProjectileSpec
end

-- A field-by-field copy through the schema list, never a table.clone: what comes out is exactly the
-- schema's fields, so junk riding on a malformed source is not reproduced (MoveTypes.Clone's reasoning).
function ProjectileTypes.Copy(spec: ProjectileSpec): ProjectileSpec
	local copy = {} :: any
	for _, field in ProjectileTypes.Fields do
		copy[field.Name] = (spec :: any)[field.Name]
	end
	return copy :: ProjectileSpec
end

-- The gate for an untrusted spec -- a client draft, a DataStore record, a source file. Strict on
-- identity, lenient on numbers, the split MoveRegistryManager.Validate keeps for every block: a value of
-- the wrong type, or an option that does not exist, rejects the whole block ("InvalidProjectile"); a
-- number out of range is clamped. An ABSENT field takes its default, so a record saved before a field was
-- added keeps loading.
function ProjectileTypes.Validate(raw: unknown): (ProjectileSpec?, string?)
	if typeof(raw) ~= "table" then
		return nil, "InvalidProjectile"
	end
	local source = raw :: { [string]: unknown }
	local spec = {} :: any
	for _, field in ProjectileTypes.Fields do
		local value = source[field.Name]
		if value == nil then
			spec[field.Name] = field.Default
		elseif field.Kind == "Number" then
			local range = ProjectileTypes.Limits[field.Name]
			local clamped = Sanitize.ClampNumber(value, range.Min, range.Max)
			if clamped == nil then
				return nil, "InvalidProjectile"
			end
			spec[field.Name] = if field.Integer then math.floor(clamped + 0.5) else clamped
		elseif field.Kind == "Enum" then
			if typeof(value) ~= "string" or table.find(field.Options :: { string }, value :: string) == nil then
				return nil, "InvalidProjectile"
			end
			spec[field.Name] = value
		else
			if typeof(value) ~= "boolean" then
				return nil, "InvalidProjectile"
			end
			spec[field.Name] = value
		end
	end
	-- Normalised rather than refused: a floor above the ceiling has exactly one reading.
	if spec.MinSpeed > spec.MaxSpeed then
		spec.MinSpeed = spec.MaxSpeed
	end
	local budget = ProjectileTypes.Budget(spec :: ProjectileSpec)
	if budget.Shots > ProjectileTypes.Caps.ShotsPerCast then
		return nil, "ProjectileOverBudget"
	end
	if budget.CastSeconds > ProjectileTypes.Caps.CastSeconds + 1e-6 then
		return nil, "ProjectileCastTooLong"
	end
	return spec :: ProjectileSpec, nil
end

-- How many shots a volley actually fires. Single is one whatever Count says (see this file's header).
function ProjectileTypes.ShotCount(spec: ProjectileSpec): number
	if spec.SpreadPattern == "Single" then
		return 1
	end
	return math.max(1, math.floor(spec.Count))
end

-- What one cast costs: shots per wave, waves, every shot counting each split generation at its fullest,
-- and seconds from the first shot to the last one launched by the waves (splits are not timed: they ride
-- their parents' flights). The worst case, not the expected one -- a split that never triggers still counts.
export type Budget = {
	ShotsPerWave: number,
	Waves: number,
	Shots: number,
	CastSeconds: number,
}

function ProjectileTypes.Budget(spec: ProjectileSpec): Budget
	local perWave = ProjectileTypes.ShotCount(spec)
	local waves = math.max(1, math.floor(spec.WaveCount))
	local layer = perWave * waves
	local shots = layer
	if spec.SplitOn ~= "Never" then
		for _ = 1, math.max(1, math.floor(spec.SplitGenerations)) do
			layer *= math.max(1, math.floor(spec.SplitCount))
			shots += layer
		end
	end
	return {
		ShotsPerWave = perWave,
		Waves = waves,
		Shots = shots,
		CastSeconds = (waves - 1) * spec.WaveIntervalSeconds + (perWave - 1) * spec.ShotIntervalSeconds,
	}
end

-- Settings that save fine but cannot take effect as set, or that behave in a way the author should know
-- before trusting a test -- one plain sentence each, in the order an author meets the fields. The Move
-- Editor's notes (MoveEditorSystem.DescribeMove) show them; nothing refuses on them.
function ProjectileTypes.Warnings(spec: ProjectileSpec): { string }
	local notes: { string } = {}
	local function note(text: string): ()
		table.insert(notes, text)
	end
	local pattern = spec.SpreadPattern
	local sharesOrigin = (pattern == "Single" or pattern == "Fan" or pattern == "Radial") and spec.FormationRadius <= 0

	if pattern == "Single" and spec.Count > 1 then
		note("Single fires one shot: Count only applies to the other spread patterns.")
	end
	if pattern == "Circle" and spec.FormationRadius <= 0 then
		note("A Circle with a zero radius starts every shot at one point, so they all fly down one line.")
	end
	if pattern == "Grid" and spec.Columns > spec.Count then
		note(`The grid has {spec.Count} shots, fewer than its {spec.Columns} columns: it is a single row.`)
	end
	if spec.ConvergeDistance > 0 and sharesOrigin then
		note("Converge has no effect: every shot already starts at one point. Use a Row, Column, Grid or Circle.")
	end
	if spec.WaveCount > 1 and spec.WaveIntervalSeconds <= 0 then
		note("Every wave fires at the same moment: give the waves an interval.")
	end

	if spec.Homing and spec.HomingStrength <= 0 then
		note("Homing is on with zero strength, so no shot ever turns.")
	end
	if spec.Homing and spec.HomingDelaySeconds >= spec.LifetimeSeconds then
		note("The homing delay is as long as the lifetime: no shot lives long enough to turn.")
	end
	local picksTarget = spec.SpawnDirection == "Target" or spec.Homing or spec.SpawnFrom == "Target"
	if picksTarget and (spec.HomingRange <= 0 or spec.HomingMaxAngle <= 0) then
		note("Target range or angle is zero, so no target can ever be picked.")
	end
	if spec.LeadTarget and spec.SpawnDirection ~= "Target" then
		note("Lead the target only aims a volley fired At target.")
	end
	if spec.SpawnFrom == "Target" then
		note("Spawning at the target needs one in range: with none, the volley spawns at the anchor instead.")
	end

	if spec.Speed > spec.MaxSpeed then
		note(
			`It launches at {spec.Speed} studs/s and is clamped to its max speed of {spec.MaxSpeed} on its first step.`
		)
	elseif spec.Speed < spec.MinSpeed then
		note(`It launches at {spec.Speed} studs/s and is raised to its min speed of {spec.MinSpeed} on its first step.`)
	end
	if spec.ReturnAfterSeconds > 0 and spec.ReturnAfterSeconds >= spec.LifetimeSeconds then
		note("It expires before its return time, so it never comes back.")
	end
	if spec.ReturnAfterSeconds > 0 and spec.CollisionBehavior == "Destroy" then
		note(
			"A wall ends a returning shot like any other: set the walls to Pass through for a boomerang that always comes back."
		)
	end
	if spec.Acceleration <= 0 and spec.Gravity == 0 and spec.ReturnAfterSeconds <= 0 then
		local reach = math.max(spec.Speed, spec.MinSpeed) * spec.LifetimeSeconds
		if spec.MaxRange > reach + 1e-3 then
			note(
				string.format(
					"Its lifetime runs out first: at %.0f studs/s a %.2fs shot only reaches %.0f of its %.0f-stud range.",
					spec.Speed,
					spec.LifetimeSeconds,
					reach,
					spec.MaxRange
				)
			)
		end
	end

	if spec.RehitSeconds > 0 and not spec.Piercing then
		note("Re-hit needs Piercing: a shot that is not piercing ends on the first body it strikes.")
	end
	if spec.ProximityRadius > 0 and spec.Piercing then
		note("The proximity fuse ends the shot before it can pierce anything.")
	end
	if spec.FalloffMinScale < 1 and spec.FalloffStartStuds >= spec.MaxRange then
		note("Damage falloff starts at or past the max range, so it never applies.")
	end
	if spec.ExplodeOn ~= "Never" and spec.ExplosionScope == "SplitOnly" and spec.SplitOn == "Never" then
		note("Only split shots burst, and nothing splits: no shot ever bursts.")
	end
	if spec.ExplodeOn ~= "Never" and spec.ExplosionScope == "OriginalOnly" and spec.SplitOn == "Never" then
		note("Original only is the same as Every when nothing splits.")
	end
	if spec.ParryBehavior ~= "CannotParry" and spec.ParryResponse == "ExistingParry" then
		note("A parried shot staggers its thrower wherever they are, exactly as a parried swing does.")
	end
	return notes
end

-- Behaviour starting points --------------------------------------------------------------------------------
--
-- The editor's second "Start from" menu: a whole BEHAVIOUR by name -- volley, waves, flight and what ends
-- it -- written onto the spec over the defaults for every behaviour field, so what an earlier recipe set does
-- not linger under a later one. The body (Presets above) and the parry answers are kept. COPIED into the
-- move, never referenced: changing a recipe here changes no move that was started from it. Every value is
-- inside Limits and the result is inside Caps (ProjectileTypes.spec pins both).
export type Recipe = {
	Id: string,
	Label: string,
	Note: string,
	Values: { [string]: any },
}

-- The fields a recipe owns: every field but the body's and the parry's. A recipe that does not name one of
-- these resets it to its default.
local NOT_BEHAVIOUR: { [string]: boolean } = {
	Shape = true,
	Size = true,
	Length = true,
	Width = true,
	Height = true,
	InnerRadius = true,
	AngleDegrees = true,
	ParryBehavior = true,
	ParryResponse = true,
	ReflectionDirection = true,
	ReflectedDamageMultiplier = true,
	ReflectedSpeedMultiplier = true,
}

function ProjectileTypes.IsBehaviourField(name: string): boolean
	return NOT_BEHAVIOUR[name] == nil
end

ProjectileTypes.Recipes = {
	{
		Id = "Bolt",
		Label = "Bolt -- one straight shot",
		Note = "Every behaviour field at its default: one shot, straight, ends on the first thing it meets.",
		Values = {},
	},
	{
		Id = "Shotgun",
		Label = "Shotgun -- a tight fan that falls off",
		Note = "Seven pellets across 24 degrees, short range, damage down to 40% by the end of it.",
		Values = {
			SpreadPattern = "Fan",
			Count = 7,
			SpreadAngle = 24,
			Speed = 140,
			LifetimeSeconds = 0.6,
			MaxRange = 45,
			FalloffStartStuds = 15,
			FalloffMinScale = 0.4,
		},
	},
	{
		Id = "Gatling",
		Label = "Gatling -- a stream from both hands",
		Note = "Ten waves a fraction apart, alternating sides, re-aimed as the thrower turns.",
		Values = {
			WaveCount = 10,
			WaveIntervalSeconds = 0.08,
			AlternateSides = true,
			Speed = 160,
			LifetimeSeconds = 1,
			MaxRange = 120,
		},
	},
	{
		Id = "Seekers",
		Label = "Seekers -- spread out, then close in",
		Note = "Four shots fan wide, fly straight for a moment, then turn hard onto the nearest target.",
		Values = {
			SpreadPattern = "Fan",
			Count = 4,
			SpreadAngle = 120,
			Speed = 60,
			LifetimeSeconds = 3,
			MaxRange = 200,
			Homing = true,
			HomingStrength = 360,
			HomingMaxAngle = 180,
			HomingRange = 120,
			HomingDelaySeconds = 0.35,
			TargetSelection = "Nearest",
		},
	},
	{
		Id = "Lances",
		Label = "Lances -- a row that converges",
		Note = "Five shots side by side, all aimed through one point 40 studs ahead; each pierces one body.",
		Values = {
			SpreadPattern = "Horizontal",
			Count = 5,
			Spacing = 3,
			ConvergeDistance = 40,
			Speed = 120,
			LifetimeSeconds = 1.2,
			MaxRange = 80,
			Piercing = true,
			MaxPierces = 1,
		},
	},
	{
		Id = "Spiral",
		Label = "Spiral -- a turning circle of waves",
		Note = "Eight waves of a six-shot circle, each turned 20 degrees further: a corkscrew down the aim.",
		Values = {
			SpreadPattern = "Circle",
			Count = 6,
			FormationRadius = 3,
			WaveCount = 8,
			WaveIntervalSeconds = 0.12,
			WaveRollDegrees = 20,
			Speed = 60,
			LifetimeSeconds = 2,
			MaxRange = 90,
		},
	},
	{
		Id = "Halo",
		Label = "Halo -- a ring of emitters firing outward",
		Note = "Twelve shots from a ring round the thrower, every one flying away from the centre.",
		Values = {
			SpreadPattern = "Fan",
			Count = 12,
			SpreadAngle = 360,
			FormationRadius = 4,
			Speed = 80,
			LifetimeSeconds = 0.8,
			MaxRange = 50,
		},
	},
	{
		Id = "Serpents",
		Label = "Serpents -- two shots that braid",
		Note = "A pair side by side, weaving in mirror image so they cross and re-cross down the line.",
		Values = {
			SpreadPattern = "Horizontal",
			Count = 2,
			Spacing = 1.5,
			WeaveDegrees = 35,
			WeaveFrequency = 1.5,
			WeaveMirrored = true,
			Speed = 70,
			LifetimeSeconds = 2,
			MaxRange = 120,
		},
	},
	{
		Id = "Boomerang",
		Label = "Boomerang -- out and back",
		Note = "Turns for home after 0.6s, cuts through up to four bodies each way, passes walls, ends in the hand.",
		Values = {
			Speed = 70,
			LifetimeSeconds = 3,
			MaxRange = 60,
			ReturnAfterSeconds = 0.6,
			ReturnTurnRate = 720,
			Piercing = true,
			MaxPierces = 4,
			CollisionBehavior = "Continue",
		},
	},
	{
		Id = "ClusterBomb",
		Label = "Cluster bomb -- lobbed, bursts into bomblets",
		Note = "A slow arcing shell that splits into six bomblets wherever it ends; only the bomblets burst.",
		Values = {
			Speed = 60,
			Gravity = 40,
			LifetimeSeconds = 1.2,
			MaxRange = 80,
			SplitOn = "Always",
			SplitCount = 6,
			SplitPattern = "Radial",
			SplitAngle = 120,
			SplitSpeedScale = 0.5,
			ExplodeOn = "Impact",
			ExplosionScope = "SplitOnly",
			ExplosionRadius = 6,
			ExplosionDamageScale = 0.6,
		},
	},
	{
		Id = "SkyStrike",
		Label = "Sky strike -- falls on the target",
		Note = "Spawns 25 studs above the target and fires down at it, leading its movement, and bursts on impact.",
		Values = {
			SpawnFrom = "Target",
			SpawnHeight = 25,
			SpawnDirection = "Target",
			LeadTarget = true,
			HomingRange = 80,
			HomingMaxAngle = 70,
			Speed = 120,
			LifetimeSeconds = 1,
			MaxRange = 60,
			ExplodeOn = "Impact",
			ExplosionRadius = 7,
		},
	},
	{
		Id = "Mine",
		Label = "Mine -- stops, waits, detonates",
		Note = "Slides to a stop, sits up to eight seconds, and bursts the moment a body comes within six studs.",
		Values = {
			Speed = 20,
			Acceleration = -40,
			LifetimeSeconds = 8,
			MaxRange = 30,
			ProximityRadius = 6,
			ExplodeOn = "Always",
			ExplosionRadius = 9,
		},
	},
} :: { Recipe }

function ProjectileTypes.RecipeById(id: string): Recipe?
	for _, recipe in ProjectileTypes.Recipes do
		if recipe.Id == id then
			return recipe
		end
	end
	return nil
end

-- Writes `recipe` onto `spec` in place: every behaviour field to the recipe's value or, when it names none,
-- to the field's default. The body and the parry answers are untouched.
function ProjectileTypes.ApplyRecipe(spec: ProjectileSpec, recipe: Recipe): ()
	for _, field in ProjectileTypes.Fields do
		if ProjectileTypes.IsBehaviourField(field.Name) then
			local value = recipe.Values[field.Name];
			(spec :: any)[field.Name] = if value == nil then field.Default else value
		end
	end
end

return ProjectileTypes
