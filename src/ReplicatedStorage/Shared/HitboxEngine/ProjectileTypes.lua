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
	  * Spread. Single fires ONE projectile whatever Count says (the count is kept, so switching back
	    restores it). Fan spreads Count evenly across SpreadAngle in the aim's horizontal plane -- 5 at 30
	    degrees fly at -15, -7.5, 0, 7.5, 15 -- and a 360 fan is a full ring with no doubled shot.
	    Horizontal and Vertical are PARALLEL formations, a row or a column Spacing studs apart, none
	    diverging. Radial is a ring around the aim axis, every shot SpreadAngle/2 off it (a hollow cone;
	    180 is a flat disc). The aim's roll turns every pattern's plane (a Fan rolled 90 is vertical).
	  * Size is the RADIUS of the sphere that flies, in studs.
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
	    that was parried, ParryAll affects every live shot of the same volley (its GroupId), CannotParry
	    makes a parry window read as a held guard -- the shot is blocked, never parried. ParryResponse is
	    what a parry does to the shot: ExistingParry (it is destroyed and the thrower is staggered exactly
	    as a parried swing is), Destroy, Reflect (the parrier owns it, it flies in ReflectionDirection with
	    the two Reflected multipliers applied), or Reverse (the parrier owns it, it retraces its path).

	Does not own: flight, collision or parry mechanics (ProjectileSimulator), the motion math
	(ProjectileMotion), what a contact MEANS (DefenseSystem, DamageSystem), or the move schema around the
	block (MoveTypes).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Sanitize = require(ReplicatedStorage.Shared.Sanitize)

local ProjectileTypes = {}

export type SpreadPattern = "Single" | "Fan" | "Horizontal" | "Vertical" | "Radial"
export type SpawnDirection = "Facing" | "Anchor" | "Target"
export type CollisionBehavior = "Destroy" | "Bounce" | "Continue"
export type TargetSelection = "Nearest" | "Aim"
export type ParryBehavior = "ParryOne" | "ParryAll" | "CannotParry"
export type ParryResponse = "ExistingParry" | "Destroy" | "Reflect" | "Reverse"
export type ReflectionDirection = "ToOwner" | "ParrierFacing" | "Mirror"

export type ProjectileSpec = {
	Count: number,
	SpreadPattern: SpreadPattern,
	SpreadAngle: number,
	Spacing: number,
	Speed: number,
	LifetimeSeconds: number,
	MaxRange: number,
	Size: number,
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
}

-- Option lists, in the order the editor offers them.
ProjectileTypes.SpreadPatterns = { "Single", "Fan", "Horizontal", "Vertical", "Radial" } :: { SpreadPattern }
ProjectileTypes.SpawnDirections = { "Facing", "Anchor", "Target" } :: { SpawnDirection }
ProjectileTypes.CollisionBehaviors = { "Destroy", "Bounce", "Continue" } :: { CollisionBehavior }
ProjectileTypes.TargetSelections = { "Aim", "Nearest" } :: { TargetSelection }
ProjectileTypes.ParryBehaviors = { "ParryOne", "ParryAll", "CannotParry" } :: { ParryBehavior }
ProjectileTypes.ParryResponses = { "ExistingParry", "Destroy", "Reflect", "Reverse" } :: { ParryResponse }
ProjectileTypes.ReflectionDirections = { "ToOwner", "ParrierFacing", "Mirror" } :: { ReflectionDirection }

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
	Size = { Min = 0.1, Max = 16 },
	Gravity = { Min = -200, Max = 200 },
	Acceleration = { Min = -400, Max = 400 },
	MaxPierces = { Min = 1, Max = 64 },
	MaxBounces = { Min = 1, Max = 32 },
	HomingStrength = { Min = 0, Max = 1080 },
	HomingMaxAngle = { Min = 0, Max = 180 },
	HomingRange = { Min = 0, Max = 500 },
	ReflectedDamageMultiplier = { Min = 0, Max = 5 },
	ReflectedSpeedMultiplier = { Min = 0.1, Max = 5 },
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
	{ Name = "Size", Kind = "Number", Default = 1 },
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
} :: { Field }

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
	return spec :: ProjectileSpec, nil
end

-- How many shots a volley actually fires. Single is one whatever Count says (see this file's header).
function ProjectileTypes.ShotCount(spec: ProjectileSpec): number
	if spec.SpreadPattern == "Single" then
		return 1
	end
	return math.max(1, math.floor(spec.Count))
end

return ProjectileTypes
