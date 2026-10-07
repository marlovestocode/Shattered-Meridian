--!strict
--[[
	HitboxTypes.lua

	Owns: the hitbox engine's data vocabulary -- what an attack IS as far as this engine is concerned
	(AttackDefinition), what it answers with (HitReport), and the sanitisers that guarantee neither
	ever carries a number the geometry math can't survive.

	A FRESH SCHEMA, not an authored move (MoveTypes.MoveDefinition) or a CombatConstants stage
	(Types.HitboxAttackDefinition). Those carry damage, posture, knockback, clips and editor metadata,
	because a "move" is the whole gameplay package. This engine resolves geometry and reports contacts;
	it has no opinion on any of that, and reusing a type that carries it would make the engine look
	like it did. What is here is the complete set of things you need to know to answer
	"who is inside this volume right now," and nothing else.

	THE DOMAIN-AGNOSTIC LAYERING, which is the reason ComboStage and PowerLevel are plain numbers:
	this engine never learns what Qi, a cultivation Tier, a combo counter or even a Player is. It is
	handed two numbers by whatever calls it and it scales a volume with them. That is the same
	discipline Server/Combat/ObjectStunResolver.lua keeps (opaque string keys, never a Player), and it
	is what lets a bot, a dummy and a player go through one code path -- and what lets the progression
	layer change what "power" means without touching a line of geometry.

	LOCAL SPACE CONVENTION -- the one the Move Editor authors in too, since its schema IS this module's
	vocabulary (MoveTypes): origin is (0,0,0), FORWARD is -Z, up is +Y, right is +X.
	  * REACH shapes (Cone, Beam) grow forward FROM the origin -- the origin is their apex/base and
	    Length is literally how far in front of the attach point they extend.
	  * CENTRED shapes (Box, Sphere, Cylinder, Capsule, Arc) straddle the origin, so Offset alone
	    positions them.
	Which convention a shape follows is the one thing you cannot infer from the field names, so it is
	restated in SHAPE_FIELDS below.

	Does not own: the geometry itself (HitboxGeometry.lua), when a hitbox is live
	(Server/Combat/HitboxEngine/AttackStateMachine.lua), or what a contact MEANS -- there is
	deliberately no damage, knockback, blocking or status field anywhere in this file. The projectile
	block's contact record (ProjectileTypes.ProjectileContact) carries a shot's authored parry answers
	and reflected damage scale as OPAQUE PASSTHROUGH, the way ComboStage and PowerLevel are: the engine
	stamps them on the report and never reads them; the defence and damage layers do.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProjectileTypes = require(ReplicatedStorage.Shared.HitboxEngine.ProjectileTypes)
local Sanitize = require(ReplicatedStorage.Shared.Sanitize)

local HitboxTypes = {}

-- The shape vocabulary. Every entry has an exact analytic containment test (HitboxGeometry.ContainsPoint)
-- and a meaningfully different silhouette in play. The 2026-09-29 rebuild cut the old editor's twelve to the
-- seven the engine could test; the engine has since learned the five it had dropped (Wedge, Pyramid, a
-- standing Pillar standing in for Disc, Crescent for Blade/Slice) plus Ellipsoid, Hemisphere, Frustum and
-- Cross -- fifteen in all, and the editor authors in exactly this list (MoveTypes.Shapes).
export type ShapeKind =
	"Box"
	| "Sphere"
	| "Capsule"
	| "Cone"
	| "Cylinder"
	| "Arc"
	| "Beam"
	| "Ellipsoid"
	| "Hemisphere"
	| "Frustum"
	| "Pyramid"
	| "Wedge"
	| "Crescent"
	| "Cross"
	| "Pillar"

-- Where on the attacker the hitbox's local space is anchored. Resolved against the LIVE part every
-- sample, never baked at swing start -- see AttackDefinition.Offset.
export type AttachmentPoint = "Root" | "RightHand" | "LeftHand" | "Weapon"

-- One flat measurement bag shared by every shape, rather than a per-shape variant: it keeps the
-- sanitiser, the scaler and the geometry dispatcher each one fixed-shape table instead of seven, and a
-- field a shape doesn't use is simply never read by it.
export type Dimensions = {
	Width: number,
	Height: number,
	Length: number,
	Radius: number,
	InnerRadius: number,
	AngleDegrees: number,
}

-- How a hitbox grows with the caller's two numbers.
--
-- Evaluated ONCE when the Active window opens, unless ChargeSeconds > 0, in which case it is
-- re-evaluated every sample so the volume grows while the attack is held. Once-per-swing is the
-- default because a hitbox that silently changes size mid-active-window is unreadable to the player
-- being hit by it: they cannot learn a range that is different on frame 3 than on frame 1. A charge
-- attack is the exception that earns it, because the growth is something the ATTACKER visibly chose.
export type ScalingProfile = {
	-- Indexed by the ComboStage passed to RequestAttack. Out-of-range stages clamp to the ends rather
	-- than erroring -- a caller whose combo counter runs past what an attack authored multipliers for
	-- should get that attack's biggest (or smallest) size, not a crash mid-swing.
	ComboStageMultipliers: { number },
	-- Scale added per unit of PowerLevel: the factor is (1 + PowerMultiplierPerUnit * PowerLevel).
	-- Additive-then-multiplied rather than exponential so a caller feeding a large power number gets
	-- a large hitbox rather than an astronomical one.
	PowerMultiplierPerUnit: number,
	-- Hard ceiling on the COMBINED multiplier. The one number standing between a progression system
	-- that grants more power than anyone modelled and a hitbox the size of the map.
	MaxScaleMultiplier: number,
	-- 0 disables charging entirely (fixed size, evaluated once). Above 0, the volume lerps from the
	-- base scale to ChargedScaleMultiplier over this many seconds of Active time.
	ChargeSeconds: number,
	-- Multiplier reached at full charge. Only read when ChargeSeconds > 0.
	ChargedScaleMultiplier: number,
}

export type AttackDefinition = {
	DebugName: string,
	Shape: ShapeKind,
	BaseDimensions: Dimensions,
	Scaling: ScalingProfile,
	-- Pose in the attachment part's LOCAL space, composed against that part's live CFrame at every
	-- single sample. Never baked into a world CFrame at swing start: a baked pose is a hitbox floating
	-- where the attacker used to be, which is precisely the "hitbox that doesn't stay on the body"
	-- failure this engine exists to not have.
	Offset: CFrame,
	AttachmentPart: AttachmentPoint,
	WindupSeconds: number,
	ActiveSeconds: number,
	RecoverySeconds: number,
	MaxTargetsPerSwing: number?,
	-- When true the engine sets the RootControlLocked Humanoid Attribute for the Active window. See
	-- HitboxEngineConstants.RootControlLockedAttribute -- that Attribute is the whole contract with
	-- the parkour framework.
	LocksMovement: boolean,
	-- When true the attacker is held through the WINDUP too: the movement lock is taken as the swing begins
	-- rather than when the Active window opens. On its own it is released as Active begins (a committed
	-- wind-up that then lets the strike carry); with LocksMovement as well the one lock simply runs the whole
	-- swing. Optional: absent is false.
	LocksWindup: boolean?,
	-- When true AND Shape == "Box", the engine reads Width/Height/Length for this swing off the
	-- resolved AttachmentPart's own live Size every time the Active window opens, instead of off
	-- BaseDimensions -- BaseDimensions.Radius/InnerRadius/AngleDegrees (unused by Box) still flow
	-- through untouched, and ComboStage/PowerLevel scaling still applies on top of the part's size
	-- exactly as it would on top of BaseDimensions. This is what lets a weapon swing's hitbox BE the
	-- equipped weapon's own Blade part -- see HitboxEngine.resolveAttachmentPart's "Weapon" case --
	-- rather than a hand-typed box guessed to roughly match it. Ignored (never read) for any other
	-- Shape, and harmless when AttachmentPart resolved to something other than a Blade (a bare fist,
	-- say): the swing simply hits with THAT part's own size, which degrades gracefully rather than
	-- erroring. Default false, so every attack authored before this field existed keeps using its own
	-- BaseDimensions exactly as before.
	SizeFromAttachmentPart: boolean?,
	-- Only read when SizeFromAttachmentPart is true: the resolved part's live Size is multiplied by
	-- this (default 1, i.e. no change) before ComboStage/PowerLevel scaling runs on top. This is what
	-- lets Shared/Combat/WeaponRoster.lua's WeaponReach Attribute keep meaning something once a weapon
	-- swing's box comes from the Blade part itself rather than from hand-typed studs -- see
	-- Types.HitboxAttackDefinition.SizeMultiplier's own header for the full chain. Ignored whenever
	-- SizeFromAttachmentPart is false, same as BaseDimensions already scales by hand in that case.
	SizeMultiplier: number?,
	-- When true the swing runs its whole lifecycle -- windup, active, recovery, movement locks, feint, clip
	-- sync -- and samples NO volume: nothing on the body is ever tested for contacts, Shape and
	-- BaseDimensions are unread, and no debug volume is drawn. It is how a move whose effect is delivered
	-- somewhere else (a realm: Server/Combat/Domain) is a real, cancellable swing without also throwing a
	-- hitbox in front of the caster. Optional: absent is false, so every attack authored before it existed
	-- samples exactly as it did. Ignored when Projectile is present (a volley has no body volume either).
	Volumeless: boolean?,
	-- Present = this attack is DELIVERED BY PROJECTILE (ProjectileTypes' header). The swing's lifecycle is
	-- unchanged -- windup, active, recovery, movement lock -- but when the Active window opens the engine
	-- launches the volley instead of sampling Shape/BaseDimensions on the body, and those two are unread.
	-- Offset and AttachmentPart still say where it starts: the spawn point is anchor.CFrame * Offset.
	Projectile: ProjectileTypes.ProjectileSpec?,
}

-- What the engine answers with. Everything a consumer needs to decide what a contact MEANS, and
-- nothing that presumes an answer.
export type HitReport = {
	Attacker: Model,
	Target: Model,
	TargetPart: BasePart,
	Shape: ShapeKind,
	-- The LIVE, post-scaling dimensions this contact was found with -- not the definition's base
	-- values. A consumer computing knockback from hitbox size, or a log explaining why a hit landed,
	-- needs the volume that actually caught the target, which at combo stage 4 is not the authored one.
	Dimensions: Dimensions,
	ContactPosition: Vector3,
	-- Carried straight through from RequestAttack, untouched. The engine scales with them and never
	-- interprets them; a consumer that DOES know what they mean (a damage layer reading combo stage
	-- for scaling) gets them back without having to have kept its own record of the swing.
	ComboStage: number,
	PowerLevel: number,
	-- The engine's own clock at the SUBSTEP the contact was found, which on a subdivided frame is
	-- earlier than the Heartbeat that reported it. Consumers ordering events (who parried first) need
	-- the substep time, not the frame time.
	SampleTime: number,
	-- The originating AttackDefinition's DebugName, copied through unchanged. NOT new data -- the
	-- engine already reads it for its own hit/swing logging -- only a new place already-known data is
	-- exposed, and the same kind of opaque passthrough ComboStage and PowerLevel already are.
	--
	-- It is here because a consumer that wants to know WHICH attack landed has no other way to ask:
	-- nothing else on this record is a stable per-move key. The engine still never learns what a
	-- "move" is; it just stops discarding a string it was already carrying.
	DebugName: string,
	-- Present exactly when a projectile made this contact rather than a volume on the attacker's body
	-- (ProjectileTypes.ProjectileContact). Absent on every swing's report, so every consumer that predates
	-- projectiles reads a report exactly as it always did.
	Projectile: ProjectileTypes.ProjectileContact?,
}

-- Per-field bounds. Upper bounds are generous -- this is a "no NaN, no negative, nothing absurd"
-- guard, not a balance pass. Judging whether a 40-stud sphere is GOOD is a design question no engine
-- can answer; refusing to hand math.huge to a bounding-box query is one it must.
local FIELD_BOUNDS: { [string]: { Min: number, Max: number, Default: number } } = {
	Width = { Min = 0, Max = 512, Default = 4 },
	Height = { Min = 0, Max = 512, Default = 4 },
	Length = { Min = 0, Max = 512, Default = 4 },
	Radius = { Min = 0, Max = 256, Default = 2 },
	InnerRadius = { Min = 0, Max = 256, Default = 0 },
	AngleDegrees = { Min = 0, Max = 360, Default = 90 },
}

local FIELD_ORDER = { "Width", "Height", "Length", "Radius", "InnerRadius", "AngleDegrees" }

-- Which fields each shape actually reads, and which space convention it uses. Documentation with a
-- runtime consumer: HitboxEngine logs it when a definition is refused, so an author who sized a Cone
-- by setting Width is told the field is ignored rather than left wondering why nothing changed.
local SHAPE_FIELDS: { [ShapeKind]: { Convention: string, Fields: { string } } } = {
	Box = { Convention = "centred", Fields = { "Width", "Height", "Length" } },
	Sphere = { Convention = "centred", Fields = { "Radius" } },
	Capsule = { Convention = "centred", Fields = { "Radius", "Length" } },
	Cylinder = { Convention = "centred", Fields = { "Radius", "Length" } },
	Arc = { Convention = "centred", Fields = { "Radius", "InnerRadius", "Height", "AngleDegrees" } },
	Cone = { Convention = "reach", Fields = { "Length", "AngleDegrees" } },
	Beam = { Convention = "reach", Fields = { "Radius", "Length" } },
	-- Width/Height/Length are FULL axis lengths, as a Box's are.
	Ellipsoid = { Convention = "centred", Fields = { "Width", "Height", "Length" } },
	-- A dome: its flat face is on the origin plane and it bulges forward.
	Hemisphere = { Convention = "reach", Fields = { "Radius" } },
	-- A cone cut short: InnerRadius at the origin widening (or narrowing) to Radius at Length.
	Frustum = { Convention = "reach", Fields = { "Radius", "InnerRadius", "Length" } },
	-- Apex at the origin, a Width x Height rectangle at Length.
	Pyramid = { Convention = "reach", Fields = { "Width", "Height", "Length" } },
	-- Apex edge at the origin widening sideways only: Height stays constant, Width is reached at Length.
	Wedge = { Convention = "reach", Fields = { "Width", "Height", "Length" } },
	-- A flat sickle: the outer disc (Radius) minus a bite (InnerRadius) centred Length behind the origin.
	Crescent = { Convention = "centred", Fields = { "Radius", "InnerRadius", "Length", "Height" } },
	-- Two bars crossing at the origin: Width across, Length along, Radius the half-thickness of both.
	Cross = { Convention = "centred", Fields = { "Width", "Length", "Height", "Radius" } },
	-- An upright cylinder (axis Y), where Cylinder lies along the facing.
	Pillar = { Convention = "centred", Fields = { "Radius", "Height" } },
}

-- Every shape, in the order an editor should offer them: the seven the engine began with, then the
-- additions grouped by what they are for. A shape added to SHAPE_FIELDS and left out of this list is
-- caught by MoveTypes.spec, which pins the two together.
HitboxTypes.ShapeOrder = {
	"Box",
	"Sphere",
	"Capsule",
	"Cylinder",
	"Cone",
	"Beam",
	"Arc",
	"Ellipsoid",
	"Hemisphere",
	"Frustum",
	"Pyramid",
	"Wedge",
	"Crescent",
	"Cross",
	"Pillar",
} :: { ShapeKind }

-- Whether a shape's origin is its centre ("centred") or its base ("reach") -- the one thing the field
-- names do not say. Read by the editor's plot and the placement math.
function HitboxTypes.ConventionOf(shape: ShapeKind): string
	local entry = SHAPE_FIELDS[shape]
	return if entry then entry.Convention else "centred"
end

function HitboxTypes.IsShapeKind(value: unknown): boolean
	return typeof(value) == "string" and SHAPE_FIELDS[value :: ShapeKind] ~= nil
end

function HitboxTypes.FieldsFor(shape: ShapeKind): { string }
	local entry = SHAPE_FIELDS[shape]
	return if entry then entry.Fields else SHAPE_FIELDS.Box.Fields
end

-- Starting points ------------------------------------------------------------------------------------------
--
-- A shape and a size an author reaches for by NAME ("a slash", "a thrust") rather than by choosing a shape
-- and then guessing its numbers. The editor's "Start from" menu applies one: it writes Shape, the
-- dimensions below and the forward offset, and touches nothing else -- timing, damage and the rest of the
-- move are the author's. Every entry is inside Constants.MoveEditor.Limits (MoveTypes.spec pins that), and
-- OffsetZ puts a centred shape in front of the body and leaves a reach shape on its origin, since a reach
-- shape already grows forward from it.
export type Preset = {
	Id: string,
	Label: string,
	-- One line on what it is for, shown under the menu.
	Note: string,
	Shape: ShapeKind,
	Dimensions: { [string]: number },
	-- Studs along the facing (negative is forward), written to the move's Offset Z.
	OffsetZ: number,
}

HitboxTypes.Presets = {
	{
		Id = "Fist",
		Label = "Fist -- a short box",
		Note = "One target, in front of the hand. The default for a basic strike.",
		Shape = "Box",
		Dimensions = { Width = 4, Height = 5, Length = 5 },
		OffsetZ = -3,
	},
	{
		Id = "Jab",
		Label = "Jab -- a narrow reach",
		Note = "A thin, quick poke that beats a wide swing at range.",
		Shape = "Capsule",
		Dimensions = { Radius = 1.25, Length = 5 },
		OffsetZ = -3.5,
	},
	{
		Id = "Thrust",
		Label = "Thrust -- a long line",
		Note = "A spear or rapier: very narrow, a long way out from the origin.",
		Shape = "Beam",
		Dimensions = { Radius = 1.25, Length = 11 },
		OffsetZ = 0,
	},
	{
		Id = "Slash",
		Label = "Slash -- a flat wedge",
		Note = "A blade cut: widens with distance, stays one height.",
		Shape = "Wedge",
		Dimensions = { Width = 10, Height = 5, Length = 7 },
		OffsetZ = 0,
	},
	{
		Id = "Sweep",
		Label = "Sweep -- a wide arc",
		Note = "A horizontal sweep across the front. Hits what a Slash would miss at the sides.",
		Shape = "Arc",
		Dimensions = { Radius = 8, InnerRadius = 1, Height = 5, AngleDegrees = 150 },
		OffsetZ = 0,
	},
	{
		Id = "Spin",
		Label = "Spin -- a full ring",
		Note = "All the way round the body, close in.",
		Shape = "Arc",
		Dimensions = { Radius = 8, InnerRadius = 0, Height = 5, AngleDegrees = 360 },
		OffsetZ = 0,
	},
	{
		Id = "Cleave",
		Label = "Cleave -- a crescent",
		Note = "A moon-shaped cut: strongest dead ahead, thin at the horns.",
		Shape = "Crescent",
		Dimensions = { Radius = 7, InnerRadius = 6, Length = 3, Height = 4 },
		OffsetZ = -2,
	},
	{
		Id = "Smash",
		Label = "Smash -- an upright pillar",
		Note = "A slam straight down on a spot in front -- tall, round, no sweep.",
		Shape = "Pillar",
		Dimensions = { Radius = 5, Height = 7 },
		OffsetZ = -5,
	},
	{
		Id = "Dome",
		Label = "Dome -- a forward blast",
		Note = "A half-sphere pushed out in front: a shockwave with no back to it.",
		Shape = "Hemisphere",
		Dimensions = { Radius = 9 },
		OffsetZ = 0,
	},
	{
		Id = "Breath",
		Label = "Breath -- a cone",
		Note = "Narrow at the mouth, wide at the far end.",
		Shape = "Cone",
		Dimensions = { Length = 13, AngleDegrees = 50 },
		OffsetZ = 0,
	},
	{
		Id = "Funnel",
		Label = "Funnel -- a cut cone",
		Note = "A cone with its tip taken off: already wide at the origin, wider at the end.",
		Shape = "Frustum",
		Dimensions = { Radius = 7, InnerRadius = 2, Length = 11 },
		OffsetZ = 0,
	},
	{
		Id = "Lance",
		Label = "Lance -- a pyramid",
		Note = "A point at the origin opening into a square face -- a charge or a drill.",
		Shape = "Pyramid",
		Dimensions = { Width = 4, Height = 4, Length = 10 },
		OffsetZ = 0,
	},
	{
		Id = "Burst",
		Label = "Burst -- a cross",
		Note = "Two bars through the body: reaches out front, back and both sides, not the corners.",
		Shape = "Cross",
		Dimensions = { Width = 14, Length = 14, Height = 4, Radius = 1.5 },
		OffsetZ = 0,
	},
	{
		Id = "Egg",
		Label = "Egg -- a stretched ellipsoid",
		Note = "A rounded volume longer than it is wide; kinder at the edges than a Box.",
		Shape = "Ellipsoid",
		Dimensions = { Width = 4, Height = 5, Length = 8 },
		OffsetZ = -3,
	},
} :: { Preset }

-- Looks a preset up by id, or nil. The editor applies it; nothing else reads Presets.
function HitboxTypes.PresetById(id: string): Preset?
	for _, preset in HitboxTypes.Presets do
		if preset.Id == id then
			return preset
		end
	end
	return nil
end

-- Sanitisation -------------------------------------------------------------------------------------
--
-- The numeric clamp is Shared/Sanitize.ClampNumberOr. This module used to spell its own comparisons
-- as "not (value >= min)" rather than "value < min" so a NaN would fail the test instead of passing
-- it -- the same guard Sanitize reaches by checking `value ~= value` explicitly, and one of five
-- independent rediscoveries of that trap across this codebase. The reason it matters is unchanged:
-- a NaN that reaches the geometry does not error, it makes every containment test silently return
-- false, producing an attack that swings and never hits anything.

-- The per-field bounds this module actually clamps against, exposed read-only. The Move Editor's own
-- authoring caps (Constants.MoveEditor.Limits.Dimensions) sit inside these, so nothing an author can
-- type is ever clamped a second time here.
function HitboxTypes.FieldBounds(): { [string]: { Min: number, Max: number, Default: number } }
	return FIELD_BOUNDS
end

function HitboxTypes.DefaultDimensions(): Dimensions
	return {
		Width = FIELD_BOUNDS.Width.Default,
		Height = FIELD_BOUNDS.Height.Default,
		Length = FIELD_BOUNDS.Length.Default,
		Radius = FIELD_BOUNDS.Radius.Default,
		InnerRadius = FIELD_BOUNDS.InnerRadius.Default,
		AngleDegrees = FIELD_BOUNDS.AngleDegrees.Default,
	}
end

function HitboxTypes.SanitizeDimensions(raw: unknown): Dimensions
	local source: { [string]: unknown } = if typeof(raw) == "table" then raw :: any else {}
	local result = {} :: any
	for _, field in FIELD_ORDER do
		local bounds = FIELD_BOUNDS[field]
		result[field] = Sanitize.ClampNumberOr(source[field], bounds.Min, bounds.Max, bounds.Default)
	end
	-- Enforced after the per-field pass, because it is a relationship between two already-valid
	-- numbers rather than a bound on either. An Arc whose hub is wider than its rim has an inside-out
	-- annulus: the radial test can never be satisfied, so the hitbox exists and hits nobody.
	if result.InnerRadius > result.Radius then
		result.InnerRadius = result.Radius
	end
	return result :: Dimensions
end

function HitboxTypes.SanitizeScaling(raw: unknown): ScalingProfile
	local source: { [string]: unknown } = if typeof(raw) == "table" then raw :: any else {}

	local multipliers: { number } = {}
	local rawMultipliers = source.ComboStageMultipliers
	if typeof(rawMultipliers) == "table" then
		for _, entry in ipairs(rawMultipliers :: { unknown }) do
			table.insert(multipliers, Sanitize.ClampNumberOr(entry, 0, 64, 1))
		end
	end
	-- An empty table is not an error -- it is how an attack says "combo stage does not change my
	-- size." A single 1.0 makes that explicit downstream so the evaluator never has to special-case
	-- an empty list.
	if #multipliers == 0 then
		multipliers = { 1 }
	end

	return {
		ComboStageMultipliers = multipliers,
		PowerMultiplierPerUnit = Sanitize.ClampNumberOr(source.PowerMultiplierPerUnit, 0, 16, 0),
		-- Floored at 1: a ceiling below the base size would shrink every hitbox using this profile
		-- even at combo stage 1 with zero power, which no author setting a "maximum" means.
		MaxScaleMultiplier = Sanitize.ClampNumberOr(source.MaxScaleMultiplier, 1, 64, 4),
		ChargeSeconds = Sanitize.ClampNumberOr(source.ChargeSeconds, 0, 30, 0),
		ChargedScaleMultiplier = Sanitize.ClampNumberOr(source.ChargedScaleMultiplier, 0, 64, 1),
	}
end

-- Normalises a caller's definition into one the engine can run without re-checking anything. Returns
-- (definition, problems) -- `problems` is a list of human-readable notes about what was corrected,
-- never a failure: a mis-authored attack that swings at a clamped size is better than one that
-- errors inside a Heartbeat loop, and the notes are what turn "why is this hitbox small" into a
-- log line. HitboxEngine surfaces them when Debug.Enabled.
function HitboxTypes.SanitizeDefinition(raw: unknown): (AttackDefinition, { string })
	local source: { [string]: unknown } = if typeof(raw) == "table" then raw :: any else {}
	local problems: { string } = {}

	local shape: ShapeKind = "Box"
	if HitboxTypes.IsShapeKind(source.Shape) then
		shape = source.Shape :: ShapeKind
	else
		table.insert(problems, `Shape {tostring(source.Shape)} is not a ShapeKind; defaulted to Box`)
	end

	local attachment: AttachmentPoint = "Root"
	local rawAttachment = source.AttachmentPart
	if
		rawAttachment == "Root"
		or rawAttachment == "RightHand"
		or rawAttachment == "LeftHand"
		or rawAttachment == "Weapon"
	then
		attachment = rawAttachment :: AttachmentPoint
	elseif rawAttachment ~= nil then
		table.insert(problems, `AttachmentPart {tostring(rawAttachment)} is not valid; defaulted to Root`)
	end

	local dimensions = HitboxTypes.SanitizeDimensions(source.BaseDimensions)
	local entry = SHAPE_FIELDS[shape]
	for _, field in FIELD_ORDER do
		if not table.find(entry.Fields, field) then
			continue
		end
		local bounds = FIELD_BOUNDS[field]
		-- Only worth a note when the author supplied something the sanitiser had to replace; a field
		-- simply left unset taking its default is ordinary.
		local supplied = if typeof(source.BaseDimensions) == "table" then (source.BaseDimensions :: any)[field] else nil
		if supplied ~= nil and supplied ~= dimensions[field :: any] then
			table.insert(
				problems,
				`BaseDimensions.{field} {tostring(supplied)} clamped to {dimensions[field :: any]} `
					.. `(bounds {bounds.Min}..{bounds.Max})`
			)
		end
	end

	-- An attack with no Active window can never hit anything, which is almost always a typo rather
	-- than an intent. Noted, not corrected: an author who genuinely wants a pure-animation entry in
	-- the same pipeline is entitled to one, and inventing an active window they didn't ask for would
	-- be the engine deciding gameplay.
	local activeSeconds = Sanitize.ClampNumberOr(source.ActiveSeconds, 0, 30, 0.1)
	if activeSeconds <= 0 then
		table.insert(problems, "ActiveSeconds is 0; this attack can never report a hit")
	end

	local maxTargets: number? = nil
	if source.MaxTargetsPerSwing ~= nil then
		maxTargets = Sanitize.ClampNumberOr(source.MaxTargetsPerSwing, 1, 128, 1)
	end

	-- Through the same gate an authored move's block passed (MoveRegistryManager.Validate), so a caller
	-- that skipped it still cannot hand the flight a NaN. A block that fails it is not dropped -- that
	-- would turn a projectile into an invisible melee swing -- but replaced with the defaults and noted.
	local projectile: ProjectileTypes.ProjectileSpec? = nil
	if source.Projectile ~= nil then
		local spec, reason = ProjectileTypes.Validate(source.Projectile)
		if spec then
			projectile = spec
		else
			projectile = ProjectileTypes.Defaults()
			table.insert(problems, `Projectile block rejected ({reason}); flying the defaults`)
		end
	end

	return {
		DebugName = if typeof(source.DebugName) == "string" then source.DebugName :: string else "UnnamedAttack",
		Shape = shape,
		BaseDimensions = dimensions,
		Scaling = HitboxTypes.SanitizeScaling(source.Scaling),
		Offset = if typeof(source.Offset) == "CFrame" then source.Offset :: CFrame else CFrame.identity,
		AttachmentPart = attachment,
		WindupSeconds = Sanitize.ClampNumberOr(source.WindupSeconds, 0, 30, 0),
		ActiveSeconds = activeSeconds,
		RecoverySeconds = Sanitize.ClampNumberOr(source.RecoverySeconds, 0, 30, 0),
		MaxTargetsPerSwing = maxTargets,
		LocksMovement = source.LocksMovement == true,
		LocksWindup = source.LocksWindup == true,
		SizeFromAttachmentPart = source.SizeFromAttachmentPart == true,
		-- Same floor as HitboxEngineConstants.MinScaleMultiplier and the same reasoning: a zero or
		-- negative multiplier would collapse or invert the box, so a mis-authored value is clamped to
		-- merely small rather than broken. 16 is generous the same way FIELD_BOUNDS' own uppers are --
		-- a "no NaN, no negative, nothing absurd" guard, not a balance pass.
		SizeMultiplier = Sanitize.ClampNumberOr(source.SizeMultiplier, 0.05, 16, 1),
		Volumeless = source.Volumeless == true,
		Projectile = projectile,
	},
		problems
end

return HitboxTypes
