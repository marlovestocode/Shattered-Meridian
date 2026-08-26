--!strict
--[[
	HitboxShapes.lua

	Owns: the closed vocabulary of hitbox SHAPES a Move Creation System move can be authored with,
	the shape-agnostic Dimensions bag every shape reads its measurements out of, and the three
	pure geometric answers every consumer needs about a (shape, dimensions) pair:

	  1. BoundingBox        -- the oriented box a broadphase overlap query should run (server).
	  2. ContainsPoint      -- the narrow-phase "is this actually inside the authored volume" test
	                           the broadphase result is filtered through (server).
	  3. BuildPreviewParts  -- a decomposition into ordinary Roblox primitives so the SAME volume can
	                           be drawn, part-for-part, in the editor's ViewportFrame and in
	                           HitboxResolver's own Studio/admin debug rendering.

	Those three living in one module is the whole point: a shape whose preview disagrees with its hit
	math is worse than no preview at all, and the only way to guarantee they agree is to derive both
	from one description. Adding a 13th shape means adding one SHAPE_SPECS entry plus one branch in
	each of those three functions -- nothing outside this file (not the validator, not the resolver,
	not the property editor) enumerates shapes by hand.

	Local space convention, identical to Types.HitboxAttackDefinition.Offset's own: the hitbox pose's
	origin is (0,0,0), FORWARD is -Z (Roblox's convention), up is +Y, right is +X. "Reach" shapes
	(Cone/Pyramid/Beam/Blade) grow FORWARD from the origin, so the origin is their apex/hilt and
	Length is literally how far in front of the attach point they extend; "centered" shapes
	(Box/Sphere/Cylinder/Capsule/Disc/Wedge/Slice/Arc) straddle the origin, so Offset alone positions
	them. Which convention a shape uses is stated in its own SHAPE_SPECS.Summary, because it's the
	one thing an author can't infer from the field names.

	Box and Sphere are deliberately special-cased by callers (see HitboxResolver.performSample):
	their bounding box IS their volume, so the broadphase result needs no narrow-phase filtering at
	all and the original GetPartBoundsInBox/GetPartBoundsInRadius queries every hand-authored attack
	has always used stay byte-identical. ContainsPoint still answers correctly for both -- callers
	skip it as an optimization, not because this module would get it wrong.

	Does not own: which shape a given move uses or whether its dimensions are legal for gameplay
	(MoveRegistryManager.Validate clamps against the per-field FIELD_SPECS bounds below), the timing
	of when a hitbox is live (HitboxResolver), or any notion of damage/targets. Pure geometry, no
	Roblox service calls, no state -- which is what lets it be required from the server resolver, the
	client editor UI, and a plain unit spec alike.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Sanitize = require(ReplicatedStorage.Shared.Sanitize)

local HitboxShapes = {}

-- Every shape an authored move may use. Box/Sphere are the two v1 shapes (every move authored
-- before this vocabulary existed is one of them); the other ten are additive and can only be
-- reached through the Move Editor's own shape picker.
export type ShapeId =
	"Box"
	| "Sphere"
	| "Cone"
	| "Cylinder"
	| "Capsule"
	| "Disc"
	| "Wedge"
	| "Pyramid"
	| "Arc"
	| "Beam"
	| "Blade"
	| "Slice"

-- The eight measurements every shape draws from. One flat bag rather than a per-shape variant type
-- for two concrete reasons: switching a draft's shape in the editor must never silently discard the
-- numbers the author already typed (they're still there when they switch back), and
-- MoveRegistryManager.Validate/MoveEditorSystem's DataStore encoder each stay one fixed-shape
-- table rather than twelve. A field a shape doesn't use is simply never read by it -- see
-- SHAPE_SPECS[shape].Fields for which ones each shape actually consumes, which is also exactly what
-- the property editor renders.
export type DimensionField =
	"Width"
	| "Height"
	| "Depth"
	| "Length"
	| "Thickness"
	| "Radius"
	| "InnerRadius"
	| "AngleDegrees"

export type Dimensions = {
	Width: number,
	Height: number,
	Depth: number,
	Length: number,
	Thickness: number,
	Radius: number,
	InnerRadius: number,
	AngleDegrees: number,
}

-- Per-field authoring bounds and step magnitudes -- the SINGLE source of truth for both the
-- validator's clamps (MoveRegistryManager) and the editor's NumericField Min/Max/Steps/Decimals, so
-- a value the UI lets an author type can never be one the server would silently clamp to something
-- else. Steps are positive magnitudes only, matching Components/NumericField.lua's own contract.
export type DimensionFieldSpec = {
	Field: DimensionField,
	Label: string,
	Unit: string,
	Min: number,
	Max: number,
	Steps: { number },
	Decimals: number,
	Default: number,
}

export type ShapeSpec = {
	Id: ShapeId,
	DisplayName: string,
	-- One line, shown under the shape picker -- says what the shape is FOR (which attack reads
	-- naturally as this volume) and, where it matters, whether it grows forward from the origin or
	-- straddles it. See this file's header on why that last part can't be inferred from field names.
	Summary: string,
	-- Which Dimensions fields this shape reads, in the order the property editor should render them.
	Fields: { DimensionField },
	-- Per-shape starting values, overlaid on FIELD_SPECS' own Default -- a Slice wants a much
	-- thinner default Thickness than a Blade does, and a Cone's useful default Length is nothing
	-- like a Beam's.
	Defaults: { [string]: number }?,
}

-- One local part of a shape's preview decomposition, in the hitbox's own local space. Consumed
-- identically by the editor viewport (which parents real Parts into a WorldModel) and by
-- HitboxResolver's debug renderer (which parents them into Workspace) -- neither knows or cares how
-- many parts a given shape decomposes into.
export type PreviewPart = {
	PartType: Enum.PartType,
	Size: Vector3,
	CFrame: CFrame,
}

local HALF_PI = math.pi / 2

-- How many slabs an approximated shape (Cone/Pyramid/Wedge/Blade/Arc) decomposes into for PREVIEW
-- purposes only -- the narrow-phase ContainsPoint math below is exact and never slices anything.
-- 12 is where the silhouette stops visibly stair-stepping at the editor viewport's own zoom range
-- without putting a meaningful part count into a panel that redraws on every field edit.
local PREVIEW_SLICES = 12

-- Floor for any preview part's own extent -- Roblox refuses to render a Part below 0.05 studs on an
-- axis, and an approximation slab (a Blade's tip slice, a Cone's apex slice) legitimately computes
-- smaller than that.
local MIN_PREVIEW_EXTENT = 0.05

local FIELD_SPECS: { [string]: DimensionFieldSpec } = {
	Width = {
		Field = "Width",
		Label = "Width",
		Unit = "studs",
		Min = 0.1,
		-- Raised from 40 (2026-08-12, "much larger hitboxes") alongside Height/Depth/Length/
		-- Radius/InnerRadius below -- see Constants.Combat.Hitboxes.MaxCandidateRadius's own
		-- comment, which was widened in lockstep: a shape authored past the OLD candidate-gathering
		-- radius would be geometrically correct but silently unable to ever overlap a target beyond
		-- it, which is a far more confusing failure than a low authoring cap.
		Max = 500,
		Steps = { 0.1, 5 },
		Decimals = 2,
		Default = 4,
	},
	Height = {
		Field = "Height",
		Label = "Height",
		Unit = "studs",
		Min = 0.1,
		Max = 500,
		Steps = { 0.1, 5 },
		Decimals = 2,
		Default = 4,
	},
	Depth = {
		Field = "Depth",
		Label = "Depth",
		Unit = "studs",
		Min = 0.1,
		Max = 500,
		Steps = { 0.1, 5 },
		Decimals = 2,
		Default = 4,
	},
	Length = {
		Field = "Length",
		Label = "Length",
		Unit = "studs",
		Min = 0.1,
		-- The single largest possible reach value (HitboxShapes.Reach) any shape can carry -- see
		-- Constants.Combat.Hitboxes.MaxCandidateRadius's own comment for why this number and that
		-- one move together.
		Max = 500,
		Steps = { 0.25, 10 },
		Decimals = 2,
		Default = 8,
	},
	Thickness = {
		Field = "Thickness",
		Label = "Thickness",
		Unit = "studs",
		-- Genuinely paper-thin at the floor -- a Slice authored at 0.02 studs is a real, usable
		-- "the blade passed through exactly this plane" hitbox, which is the whole point of that
		-- shape existing separately from a very flat Box.
		Min = 0.02,
		Max = 25,
		Steps = { 0.02, 1 },
		Decimals = 2,
		Default = 0.5,
	},
	Radius = {
		Field = "Radius",
		Label = "Radius",
		Unit = "studs",
		Min = 0.1,
		Max = 500,
		Steps = { 0.1, 5 },
		Decimals = 2,
		Default = 4,
	},
	InnerRadius = {
		Field = "InnerRadius",
		Label = "Inner Radius",
		Unit = "studs",
		-- 0 is meaningful and common (a solid Disc/Arc rather than a ring) -- unlike every other
		-- field here, whose 0 would mean "no volume at all." Mirrors Radius' own Max above -- the
		-- Sanitize cross-field invariant (InnerRadius strictly inside Radius) only means anything if
		-- both share the same ceiling.
		Min = 0,
		Max = 100,
		Steps = { 0.1, 5 },
		Decimals = 2,
		Default = 0,
	},
	AngleDegrees = {
		Field = "AngleDegrees",
		Label = "Angle",
		Unit = "degrees",
		Min = 1,
		Max = 360,
		Steps = { 1, 15 },
		Decimals = 0,
		Default = 60,
	},
}

-- Declaration order here IS the shape picker's own order -- Box/Sphere first (the two shapes that
-- predate this vocabulary and remain the sane default for most moves), then the rest grouped by
-- how they read: swept/directional first, then volumetric, then the flat ones.
local SHAPE_ORDER: { ShapeId } = {
	"Box",
	"Sphere",
	"Cone",
	"Arc",
	"Blade",
	"Slice",
	"Beam",
	"Cylinder",
	"Capsule",
	"Disc",
	"Wedge",
	"Pyramid",
}

local SHAPE_SPECS: { [string]: ShapeSpec } = {
	Box = {
		Id = "Box",
		DisplayName = "Box",
		Summary = "A plain oriented box centred on the offset. The original shape -- a good default for punches, kicks and most weapon swings.",
		Fields = { "Width", "Height", "Depth" },
		Defaults = { Width = 4, Height = 4, Depth = 4 },
	},
	Sphere = {
		Id = "Sphere",
		DisplayName = "Sphere",
		Summary = "A ball centred on the offset, ignoring facing entirely. Good for explosions, shockwaves and omnidirectional bursts.",
		Fields = { "Radius" },
		Defaults = { Radius = 4 },
	},
	Cone = {
		Id = "Cone",
		DisplayName = "Cone",
		Summary = "Widens forward from the offset -- apex at the attach point, circular base Length studs ahead. Breath weapons, shotgun-style bursts, palm blasts.",
		Fields = { "Length", "AngleDegrees" },
		Defaults = { Length = 12, AngleDegrees = 45 },
	},
	Arc = {
		Id = "Arc",
		DisplayName = "Arc",
		Summary = "A horizontal ring segment sweeping Angle degrees around the attacker, centred on their facing. The honest shape of a wide horizontal slash.",
		Fields = { "Radius", "InnerRadius", "Height", "AngleDegrees" },
		Defaults = { Radius = 9, InnerRadius = 2, Height = 5, AngleDegrees = 120 },
	},
	Blade = {
		Id = "Blade",
		DisplayName = "Blade",
		Summary = "A flat sword: extends Length forward, tapering from Height at the hilt to Width at the tip, Thickness studs thick. Thrusts and precise sword strikes.",
		Fields = { "Length", "Height", "Width", "Thickness" },
		Defaults = { Length = 7, Height = 2.5, Width = 0.6, Thickness = 0.35 },
	},
	Slice = {
		Id = "Slice",
		DisplayName = "Slice",
		Summary = "A paper-thin rectangular plane centred on the offset. Rotate it to define the exact plane a cut passes through -- nothing outside that plane is touched.",
		Fields = { "Width", "Height", "Thickness" },
		Defaults = { Width = 10, Height = 8, Thickness = 0.08 },
	},
	Beam = {
		Id = "Beam",
		DisplayName = "Beam",
		Summary = "A straight round shaft of constant Radius running Length studs forward from the offset. Lasers, piercing spears, sustained rays.",
		Fields = { "Length", "Radius" },
		Defaults = { Length = 20, Radius = 1.2 },
	},
	Cylinder = {
		Id = "Cylinder",
		DisplayName = "Cylinder",
		Summary = "A round pillar of Length centred on the offset along the facing axis. Rotate it upright for a column-shaped area attack.",
		Fields = { "Length", "Radius" },
		Defaults = { Length = 8, Radius = 3 },
	},
	Capsule = {
		Id = "Capsule",
		DisplayName = "Capsule",
		Summary = "A cylinder with rounded caps -- Length between the cap centres, plus Radius at each end. Matches how a limb or a thrown body actually sweeps.",
		Fields = { "Length", "Radius" },
		Defaults = { Length = 6, Radius = 2 },
	},
	Disc = {
		Id = "Disc",
		DisplayName = "Disc",
		Summary = "A flat circle (or ring, with an inner radius) facing forward, Thickness studs deep. Spinning throws, ground rings, expanding shockwave fronts.",
		Fields = { "Radius", "InnerRadius", "Thickness" },
		Defaults = { Radius = 6, InnerRadius = 0, Thickness = 0.4 },
	},
	Wedge = {
		Id = "Wedge",
		DisplayName = "Wedge",
		Summary = "A ramp centred on the offset: flat at the back, rising to full Height at the front edge. Uppercuts and rising slashes that should miss a crouched target behind them.",
		Fields = { "Width", "Height", "Depth" },
		Defaults = { Width = 5, Height = 6, Depth = 5 },
	},
	Pyramid = {
		Id = "Pyramid",
		DisplayName = "Pyramid",
		Summary = "Like a cone but rectangular: apex at the offset, widening to Width by Height at Length studs ahead. Broad forward smashes with a tight origin.",
		Fields = { "Length", "Width", "Height" },
		Defaults = { Length = 10, Width = 8, Height = 6 },
	},
}

-- Ordered spec list for the editor's shape picker -- built once at require time from SHAPE_ORDER so
-- a shape can never appear in the picker without a spec, or vice versa.
local ORDERED_SPECS: { ShapeSpec } = {}
for _, shapeId in ipairs(SHAPE_ORDER) do
	table.insert(ORDERED_SPECS, SHAPE_SPECS[shapeId])
end

-- Through Shared/Sanitize.ClampNumberOr rather than a bare math.clamp, which makes this
-- STRUCTURALLY NaN-safe instead of safe by call-site discipline. It was already safe in practice --
-- Sanitize's own `read` below checks for NaN before calling, and DefaultDimensions only ever passes
-- authored constants -- but this was the one clamp in the codebase with no guard of its own, and
-- "correct as long as nobody adds a third caller" is not a property worth relying on.
local function clampField(field: DimensionField, value: unknown): number
	local spec = FIELD_SPECS[field]
	return Sanitize.ClampNumberOr(value, spec.Min, spec.Max, spec.Default)
end

--
-- Public metadata
--

function HitboxShapes.IsShapeId(value: unknown): boolean
	return typeof(value) == "string" and SHAPE_SPECS[value :: string] ~= nil
end

function HitboxShapes.ListShapes(): { ShapeSpec }
	return ORDERED_SPECS
end

-- Falls back to Box's spec for an unknown id rather than erroring -- every caller here is either UI
-- rendering (which must not tear down a panel over a bad string) or a validator that has already
-- rejected the move for a different reason. The validator is what actually enforces the union.
function HitboxShapes.GetSpec(shape: ShapeId): ShapeSpec
	return SHAPE_SPECS[shape] or SHAPE_SPECS.Box
end

function HitboxShapes.GetFieldSpec(field: DimensionField): DimensionFieldSpec
	return FIELD_SPECS[field]
end

-- Which Dimensions fields this shape actually reads -- drives both the property editor's rendered
-- field list and, in the validator, which fields are worth reporting a range problem for.
function HitboxShapes.FieldsFor(shape: ShapeId): { DimensionField }
	return HitboxShapes.GetSpec(shape).Fields
end

function HitboxShapes.UsesField(shape: ShapeId, field: DimensionField): boolean
	for _, candidate in ipairs(HitboxShapes.FieldsFor(shape)) do
		if candidate == field then
			return true
		end
	end
	return false
end

-- A full, concrete Dimensions bag for a shape: every field populated (so no consumer ever nil-
-- checks one), with this shape's own Defaults overlaid on the global per-field defaults.
function HitboxShapes.DefaultDimensions(shape: ShapeId): Dimensions
	local overrides = HitboxShapes.GetSpec(shape).Defaults or {}
	local function pick(field: DimensionField): number
		return clampField(field, overrides[field] or FIELD_SPECS[field].Default)
	end
	return {
		Width = pick("Width"),
		Height = pick("Height"),
		Depth = pick("Depth"),
		Length = pick("Length"),
		Thickness = pick("Thickness"),
		Radius = pick("Radius"),
		InnerRadius = pick("InnerRadius"),
		AngleDegrees = pick("AngleDegrees"),
	}
end

-- Clamps an arbitrary (possibly partial, possibly hostile) dimensions table into a legal one,
-- filling anything missing or non-numeric from this shape's own defaults. The ONE normalization
-- every entry point shares -- MoveRegistryManager.Validate for a client/DataStore candidate, the
-- property editor for a live edit, this module's own tests -- so a Dimensions value that reached
-- any consumer is always in range on every field.
--
-- Also enforces the one CROSS-field invariant this vocabulary has: InnerRadius must stay strictly
-- inside Radius, otherwise a Disc/Arc has its hole punched out past its own rim and encloses
-- nothing at all, which reads as a silently dead hitbox rather than as an authoring mistake.
function HitboxShapes.Sanitize(shape: ShapeId, raw: unknown): Dimensions
	local defaults = HitboxShapes.DefaultDimensions(shape)
	local source: { [string]: unknown } = if typeof(raw) == "table" then raw :: { [string]: unknown } else {}

	local function read(field: DimensionField): number
		local value = source[field]
		if typeof(value) ~= "number" or value ~= value then
			-- Non-numeric, or NaN (which survives every comparison-based clamp) -- fall back rather
			-- than propagate a value that would poison the geometry math downstream.
			return defaults[field]
		end
		return clampField(field, value :: number)
	end

	local dimensions: Dimensions = {
		Width = read("Width"),
		Height = read("Height"),
		Depth = read("Depth"),
		Length = read("Length"),
		Thickness = read("Thickness"),
		Radius = read("Radius"),
		InnerRadius = read("InnerRadius"),
		AngleDegrees = read("AngleDegrees"),
	}

	if dimensions.InnerRadius >= dimensions.Radius then
		dimensions.InnerRadius = math.max(0, dimensions.Radius - FIELD_SPECS.InnerRadius.Steps[1])
	end

	return dimensions
end

--
-- Geometry -- AUTHORING-SIDE ONLY
--
-- This section used to also carry ContainsPoint (95 lines), BoundingRadius and IsExactBroadphase --
-- the narrow-phase half of resolving a hit, sitting in the module that resolves none.
--
-- The live narrow phase is Shared/HitboxEngine/HitboxGeometry.lua, which HitboxEngine's own sample
-- loop and CandidateGatherer's broadphase call. It is NOT simply a copy of what was here: it speaks
-- HitboxTypes.ShapeKind, which is SEVEN shapes, where this module's ShapeId is twelve. The five extra
-- ones are authoring vocabulary that MoveTypes.ENGINE_SHAPE_BY_MOVE_SHAPE maps down before anything
-- is ever resolved (Disc -> Cylinder, and Wedge/Blade/Slice/Pyramid -> their own Box bound). So the
-- twelve-shape containment test here could never have been asked about five of its own shapes by
-- anything live, and was not asked about the other seven either -- it had test callers and comment
-- mentions, and nothing else.
--
-- What remains is the vocabulary an AUTHOR needs -- how far a shape reaches, roughly how much space
-- it covers, its own extent box, and how to draw it. That is a genuinely different job from resolving
-- a hit, and it is why this module still exists beside HitboxGeometry rather than merging into it.
-- BoundingBox stays for that reason: it is the extent an author's preview gizmo is checked against
-- (see BuildPreviewParts), not a query anything runs.

-- The oriented box a broadphase Workspace:GetPartBoundsInBox should query for this shape, as
-- (size, localCentreOffset) -- the offset is non-identity for the "reach" shapes, whose volume sits
-- entirely in front of their own origin rather than straddling it. Always a conservative OVER-
-- estimate: it may include parts the narrow-phase then rejects, never exclude one it would accept.
function HitboxShapes.BoundingBox(shape: ShapeId, dimensions: Dimensions): (Vector3, CFrame)
	if shape == "Sphere" then
		local diameter = dimensions.Radius * 2
		return Vector3.new(diameter, diameter, diameter), CFrame.identity
	elseif shape == "Cone" then
		local baseDiameter = HitboxShapes.ConeBaseRadius(dimensions) * 2
		return Vector3.new(baseDiameter, baseDiameter, dimensions.Length), CFrame.new(0, 0, -dimensions.Length / 2)
	elseif shape == "Cylinder" then
		local diameter = dimensions.Radius * 2
		return Vector3.new(diameter, diameter, dimensions.Length), CFrame.identity
	elseif shape == "Capsule" then
		local diameter = dimensions.Radius * 2
		return Vector3.new(diameter, diameter, dimensions.Length + diameter), CFrame.identity
	elseif shape == "Disc" then
		local diameter = dimensions.Radius * 2
		return Vector3.new(diameter, diameter, dimensions.Thickness), CFrame.identity
	elseif shape == "Wedge" then
		return Vector3.new(dimensions.Width, dimensions.Height, dimensions.Depth), CFrame.identity
	elseif shape == "Pyramid" then
		return Vector3.new(dimensions.Width, dimensions.Height, dimensions.Length),
			CFrame.new(0, 0, -dimensions.Length / 2)
	elseif shape == "Arc" then
		-- Conservatively the FULL ring, not the swept sector -- an oriented box can't express a
		-- sector anyway, and the narrow-phase angle test is what actually trims it.
		local diameter = dimensions.Radius * 2
		return Vector3.new(diameter, dimensions.Height, diameter), CFrame.identity
	elseif shape == "Beam" then
		local diameter = dimensions.Radius * 2
		return Vector3.new(diameter, diameter, dimensions.Length), CFrame.new(0, 0, -dimensions.Length / 2)
	elseif shape == "Blade" then
		local breadth = math.max(dimensions.Height, dimensions.Width)
		return Vector3.new(dimensions.Thickness, breadth, dimensions.Length), CFrame.new(0, 0, -dimensions.Length / 2)
	elseif shape == "Slice" then
		return Vector3.new(dimensions.Width, dimensions.Height, dimensions.Thickness), CFrame.identity
	end
	-- Box, and the defensive fallback for anything the validator somehow let through.
	return Vector3.new(dimensions.Width, dimensions.Height, dimensions.Depth), CFrame.identity
end

-- The base radius a Cone's own Length/AngleDegrees imply -- AngleDegrees is the FULL apex angle
-- (what an author means by "a 45 degree cone"), so the half-angle is what drives the taper.
-- Exposed rather than file-local because the preview builder and the volume estimate both need the
-- same number, and disagreeing on it would show up as a preview that doesn't match the hitbox.
function HitboxShapes.ConeBaseRadius(dimensions: Dimensions): number
	local halfAngle = math.rad(math.clamp(dimensions.AngleDegrees, 1, 179) / 2)
	return dimensions.Length * math.tan(halfAngle)
end

-- How far in front of the origin the volume reaches, in studs -- the number an author actually
-- means by "how far does this move hit," and what MoveStats reports as the move's range.
function HitboxShapes.Reach(shape: ShapeId, dimensions: Dimensions): number
	if shape == "Sphere" then
		return dimensions.Radius
	elseif shape == "Cone" or shape == "Pyramid" or shape == "Beam" or shape == "Blade" then
		return dimensions.Length
	elseif shape == "Cylinder" then
		return dimensions.Length / 2
	elseif shape == "Capsule" then
		return dimensions.Length / 2 + dimensions.Radius
	elseif shape == "Disc" then
		return dimensions.Thickness / 2
	elseif shape == "Arc" then
		return dimensions.Radius
	elseif shape == "Wedge" then
		return dimensions.Depth / 2
	elseif shape == "Slice" then
		return dimensions.Thickness / 2
	end
	return dimensions.Depth / 2
end

-- Approximate enclosed volume in cubic studs -- a coverage number for the editor's stats readout
-- ("how much space does this actually cover"), never used for hit resolution. Approximate is
-- honest here: the Blade's taper is treated as a straight trapezoid and the Arc as a swept
-- annulus, both within a few percent of the real solid.
function HitboxShapes.ApproximateVolume(shape: ShapeId, dimensions: Dimensions): number
	if shape == "Sphere" then
		return (4 / 3) * math.pi * dimensions.Radius ^ 3
	elseif shape == "Cone" then
		local baseRadius = HitboxShapes.ConeBaseRadius(dimensions)
		return (1 / 3) * math.pi * baseRadius ^ 2 * dimensions.Length
	elseif shape == "Cylinder" or shape == "Beam" then
		return math.pi * dimensions.Radius ^ 2 * dimensions.Length
	elseif shape == "Capsule" then
		return math.pi * dimensions.Radius ^ 2 * dimensions.Length + (4 / 3) * math.pi * dimensions.Radius ^ 3
	elseif shape == "Disc" then
		return math.pi * (dimensions.Radius ^ 2 - dimensions.InnerRadius ^ 2) * dimensions.Thickness
	elseif shape == "Wedge" then
		return dimensions.Width * dimensions.Height * dimensions.Depth / 2
	elseif shape == "Pyramid" then
		return (1 / 3) * dimensions.Width * dimensions.Height * dimensions.Length
	elseif shape == "Arc" then
		local sweep = math.clamp(dimensions.AngleDegrees, 0, 360) / 360
		return math.pi * (dimensions.Radius ^ 2 - dimensions.InnerRadius ^ 2) * dimensions.Height * sweep
	elseif shape == "Blade" then
		return dimensions.Thickness * dimensions.Length * (dimensions.Height + dimensions.Width) / 2
	elseif shape == "Slice" then
		return dimensions.Width * dimensions.Height * dimensions.Thickness
	end
	return dimensions.Width * dimensions.Height * dimensions.Depth
end

--
-- Preview decomposition
--

-- Roblox's own PartType.Cylinder runs along its LOCAL X axis, not Z -- every cylindrical piece
-- below goes through this so that off-by-90-degrees mistake can only ever be made once.
local function cylinderAlongZ(radius: number, length: number, centre: CFrame): PreviewPart
	local diameter = math.max(radius * 2, MIN_PREVIEW_EXTENT)
	return {
		PartType = Enum.PartType.Cylinder,
		Size = Vector3.new(math.max(length, MIN_PREVIEW_EXTENT), diameter, diameter),
		CFrame = centre * CFrame.Angles(0, HALF_PI, 0),
	}
end

local function block(size: Vector3, centre: CFrame): PreviewPart
	return {
		PartType = Enum.PartType.Block,
		Size = Vector3.new(
			math.max(size.X, MIN_PREVIEW_EXTENT),
			math.max(size.Y, MIN_PREVIEW_EXTENT),
			math.max(size.Z, MIN_PREVIEW_EXTENT)
		),
		CFrame = centre,
	}
end

local function ball(radius: number, centre: CFrame): PreviewPart
	local diameter = math.max(radius * 2, MIN_PREVIEW_EXTENT)
	return {
		PartType = Enum.PartType.Ball,
		Size = Vector3.new(diameter, diameter, diameter),
		CFrame = centre,
	}
end

-- Decomposes a shape into ordinary Roblox primitives, positioned in the hitbox's own local space.
-- Shapes Roblox has no primitive for (Cone/Pyramid/Wedge/Blade/Arc) are approximated as a stack of
-- PREVIEW_SLICES slabs along their own sweep axis -- the same silhouette the exact ContainsPoint
-- math describes, drawn at a resolution that reads cleanly without flooding the viewport.
function HitboxShapes.BuildPreviewParts(shape: ShapeId, dimensions: Dimensions): { PreviewPart }
	if shape == "Sphere" then
		return { ball(dimensions.Radius, CFrame.identity) }
	elseif shape == "Cone" then
		local parts: { PreviewPart } = {}
		local sliceLength = dimensions.Length / PREVIEW_SLICES
		local baseRadius = HitboxShapes.ConeBaseRadius(dimensions)
		for index = 1, PREVIEW_SLICES do
			-- Radius sampled at each slab's own MIDPOINT so the stack neither over- nor
			-- under-shoots the true cone surface -- the same convention every approximated shape
			-- below uses.
			local midpoint = (index - 0.5) / PREVIEW_SLICES
			table.insert(
				parts,
				cylinderAlongZ(baseRadius * midpoint, sliceLength, CFrame.new(0, 0, -midpoint * dimensions.Length))
			)
		end
		return parts
	elseif shape == "Cylinder" then
		return { cylinderAlongZ(dimensions.Radius, dimensions.Length, CFrame.identity) }
	elseif shape == "Capsule" then
		local halfLength = dimensions.Length / 2
		return {
			cylinderAlongZ(dimensions.Radius, dimensions.Length, CFrame.identity),
			ball(dimensions.Radius, CFrame.new(0, 0, -halfLength)),
			ball(dimensions.Radius, CFrame.new(0, 0, halfLength)),
		}
	elseif shape == "Disc" then
		if dimensions.InnerRadius <= 0 then
			return { cylinderAlongZ(dimensions.Radius, dimensions.Thickness, CFrame.identity) }
		end
		-- A ring has no primitive either -- drawn as a band of blocks around the annulus, which
		-- reads as a ring far better than a solid disc would (and a solid disc would actively
		-- mislead, since the hole genuinely doesn't hit).
		local parts: { PreviewPart } = {}
		local midRadius = (dimensions.Radius + dimensions.InnerRadius) / 2
		local bandWidth = dimensions.Radius - dimensions.InnerRadius
		local segments = PREVIEW_SLICES * 2
		local segmentArc = 2 * math.pi / segments
		for index = 1, segments do
			local angle = (index - 0.5) * segmentArc
			local centre = CFrame.new(math.cos(angle) * midRadius, math.sin(angle) * midRadius, 0)
				* CFrame.Angles(0, 0, angle)
			table.insert(parts, block(Vector3.new(bandWidth, midRadius * segmentArc, dimensions.Thickness), centre))
		end
		return parts
	elseif shape == "Wedge" then
		local parts: { PreviewPart } = {}
		local sliceDepth = dimensions.Depth / PREVIEW_SLICES
		local halfDepth = dimensions.Depth / 2
		local halfHeight = dimensions.Height / 2
		for index = 1, PREVIEW_SLICES do
			-- index 1 is the FRONT slab (tallest) -- see ContainsPoint's own ramp, which rises
			-- toward the front face.
			local midpoint = (index - 0.5) / PREVIEW_SLICES
			local slabHeight = dimensions.Height * (1 - midpoint) + dimensions.Height / PREVIEW_SLICES
			slabHeight = math.min(slabHeight, dimensions.Height)
			local centreZ = -halfDepth + (index - 0.5) * sliceDepth
			table.insert(
				parts,
				block(
					Vector3.new(dimensions.Width, slabHeight, sliceDepth),
					CFrame.new(0, -halfHeight + slabHeight / 2, centreZ)
				)
			)
		end
		return parts
	elseif shape == "Pyramid" then
		local parts: { PreviewPart } = {}
		local sliceLength = dimensions.Length / PREVIEW_SLICES
		for index = 1, PREVIEW_SLICES do
			local midpoint = (index - 0.5) / PREVIEW_SLICES
			table.insert(
				parts,
				block(
					Vector3.new(dimensions.Width * midpoint, dimensions.Height * midpoint, sliceLength),
					CFrame.new(0, 0, -midpoint * dimensions.Length)
				)
			)
		end
		return parts
	elseif shape == "Arc" then
		local parts: { PreviewPart } = {}
		local sweep = math.clamp(dimensions.AngleDegrees, 1, 360)
		local segments = math.max(3, math.ceil(PREVIEW_SLICES * sweep / 120))
		local segmentArc = math.rad(sweep) / segments
		local midRadius = (dimensions.Radius + dimensions.InnerRadius) / 2
		local bandWidth = math.max(dimensions.Radius - dimensions.InnerRadius, MIN_PREVIEW_EXTENT)
		for index = 1, segments do
			-- Bearing measured from straight-ahead, matching ContainsPoint's own atan2(x, -z).
			local bearing = math.rad(-sweep / 2) + (index - 0.5) * segmentArc
			local centre = CFrame.new(math.sin(bearing) * midRadius, 0, -math.cos(bearing) * midRadius)
				* CFrame.Angles(0, bearing, 0)
			table.insert(parts, block(Vector3.new(midRadius * segmentArc, dimensions.Height, bandWidth), centre))
		end
		return parts
	elseif shape == "Beam" then
		return {
			cylinderAlongZ(dimensions.Radius, dimensions.Length, CFrame.new(0, 0, -dimensions.Length / 2)),
		}
	elseif shape == "Blade" then
		local parts: { PreviewPart } = {}
		local sliceLength = dimensions.Length / PREVIEW_SLICES
		for index = 1, PREVIEW_SLICES do
			local midpoint = (index - 0.5) / PREVIEW_SLICES
			local breadth = dimensions.Height + (dimensions.Width - dimensions.Height) * midpoint
			table.insert(
				parts,
				block(
					Vector3.new(dimensions.Thickness, breadth, sliceLength),
					CFrame.new(0, 0, -midpoint * dimensions.Length)
				)
			)
		end
		return parts
	elseif shape == "Slice" then
		return { block(Vector3.new(dimensions.Width, dimensions.Height, dimensions.Thickness), CFrame.identity) }
	end

	return { block(Vector3.new(dimensions.Width, dimensions.Height, dimensions.Depth), CFrame.identity) }
end

return HitboxShapes
