--!strict
--[[
	MoveRecordCodec.lua

	Owns: turning a MoveDefinition into a DataStore record and a stored record back into a candidate for
	MoveRegistryManager.Validate -- including UPGRADING every record written before the 2026-09-29
	rebuild, which is the only place the old schema's vocabulary is still spoken.

	A record IS the wire shape (MoveTypes.ToWire) plus the identity stamps and a SchemaVersion. One
	encoding for both is deliberate: the old design encoded the wire and the record separately, and the
	record encoder twice forgot a newly added field, so a move worked live and vanished on the next boot.

	DECODE NEVER TRUSTS. It only reshapes; Validate still decides what the numbers mean, exactly as it
	does for a network payload.

	UPGRADING v1/v2 (Constants.MoveEditor.SchemaVersion 1 and 2). What carries over, and how:
	  * Geometry. The old twelve shapes map onto the engine's seven the way the old projection already
	    mapped them at swing time -- so an upgraded move hits exactly as it did yesterday, it just stops
	    pretending to be a shape the engine never ran. Disc became the Cylinder it always was; Wedge,
	    Blade, Slice and Pyramid become the Box that bounds them. A v1 record's Size/Radius become
	    Dimensions. The old Depth is the engine's Length.
	  * Rotation. OffsetRotationX/Y/Z (pitch, yaw, roll degrees) become OffsetPitch/Yaw/Roll.
	  * Animation. A blank AnimationId falls back to the first enabled clip of the old timeline, so a
	    move authored only through the timeline keeps its clip.
	  * Knockback keeps its two velocities and StartsAirCombo; Grab, Art, PowerLevel, Feintable and
	    identity pass through untouched.
	What does not, because nothing ever ran it: Movement, Projectile, ObjectStun, Slam, ArcDegrees, the
	timeline itself, and Knockback.RagdollSeconds. Decode reports which of those a record actually had,
	so the loader can log "this move lost its projectile" rather than dropping it in silence.

	Nothing rewrites a stored record on load. It is re-written in the new shape the next time an admin
	saves it.

	Pure: no DataStore, no registry, no clock. Server/Systems/MoveEditorSystem.lua owns the I/O.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

local MoveRecordCodec = {}

local SCHEMA_VERSION = Constants.MoveEditor.SchemaVersion

export type Record = { [string]: any }

-- Fields a pre-rebuild record could carry that no longer exist, checked so Decode can say which a given
-- record lost.
local RETIRED_FIELDS = { "Movement", "Projectile", "ObjectStun", "Slam", "ArcDegrees" }

-- The old twelve-shape vocabulary onto the engine's seven -- the same mapping the old
-- MoveTypes.ToEngineAttackDefinition applied at every swing, so an upgraded move is not a gameplay
-- change.
local LEGACY_SHAPE: { [string]: MoveTypes.MoveShape } = {
	Box = "Box",
	Sphere = "Sphere",
	Cone = "Cone",
	Arc = "Arc",
	Beam = "Beam",
	Cylinder = "Cylinder",
	Capsule = "Capsule",
	Disc = "Cylinder",
	Wedge = "Box",
	Blade = "Box",
	Slice = "Box",
	Pyramid = "Box",
}

local function numberOr(value: unknown, fallback: number): number
	return if typeof(value) == "number" then value :: number else fallback
end

-- The old eight-field bag (Width/Height/Depth/Length/Thickness/Radius/InnerRadius/AngleDegrees),
-- reconstructed from a v1 record's Size/Radius when it has none, projected per AUTHORED shape.
local function legacyDimensions(record: Record, legacyShape: string): MoveTypes.MoveDimensions
	local source: { [string]: any } = if typeof(record.Dimensions) == "table" then record.Dimensions else {}
	if typeof(record.Dimensions) ~= "table" then
		-- A stored v1 Size is a plain {X, Y, Z} table (JSON carries no Vector3); a live one is a Vector3.
		-- Both index the same way.
		local size = record.Size
		if typeof(size) == "table" or typeof(size) == "Vector3" then
			source = { Width = size.X, Height = size.Y, Depth = size.Z }
		end
		if typeof(record.Radius) == "number" then
			source.Radius = record.Radius
		end
	end

	local out = HitboxTypes.DefaultDimensions()
	local function read(field: string): number
		return numberOr(source[field], (out :: any)[field] or 0)
	end

	if legacyShape == "Box" or legacyShape == "Wedge" then
		out.Width, out.Height, out.Length = read("Width"), read("Height"), numberOr(source.Depth, out.Length)
	elseif legacyShape == "Sphere" then
		out.Radius = read("Radius")
	elseif legacyShape == "Cone" then
		out.Length, out.AngleDegrees = read("Length"), read("AngleDegrees")
	elseif legacyShape == "Arc" then
		out.Radius, out.InnerRadius = read("Radius"), read("InnerRadius")
		out.Height, out.AngleDegrees = read("Height"), read("AngleDegrees")
	elseif legacyShape == "Beam" or legacyShape == "Cylinder" or legacyShape == "Capsule" then
		out.Length, out.Radius = read("Length"), read("Radius")
	elseif legacyShape == "Disc" then
		-- Thickness IS the cylinder's length; an authored ring becomes a filled disc -- larger, never
		-- smaller, so a hit that landed still lands.
		out.Radius, out.Length = read("Radius"), numberOr(source.Thickness, out.Length)
	elseif legacyShape == "Blade" then
		-- A tapering blade in a box that cannot taper: the widest measurement in each axis.
		out.Width = math.max(read("Width"), numberOr(source.Thickness, 0))
		out.Height, out.Length = read("Height"), read("Length")
	elseif legacyShape == "Slice" then
		out.Width, out.Height, out.Length = read("Width"), read("Height"), numberOr(source.Thickness, out.Length)
	elseif legacyShape == "Pyramid" then
		out.Width, out.Height, out.Length = read("Width"), read("Height"), read("Length")
	end
	return out
end

-- The first enabled clip's id from the old timeline, or "" -- see this file's header.
local function legacyClipId(record: Record): string
	if typeof(record.AnimationId) == "string" and record.AnimationId ~= "" then
		return record.AnimationId
	end
	if typeof(record.Animations) ~= "table" then
		return ""
	end
	for _, clip in ipairs(record.Animations) do
		if typeof(clip) == "table" and clip.Enabled ~= false and typeof(clip.AnimationId) == "string" then
			if clip.AnimationId ~= "" then
				return clip.AnimationId
			end
		end
	end
	return ""
end

-- Upgrades a pre-v3 record (or override record) into the v3 wire shape. Only the fields the record
-- actually carries are written, so an override record -- which never carried identity -- stays one.
local function upgradeLegacy(record: Record): (Record, { string })
	local dropped: { string } = {}
	for _, field in RETIRED_FIELDS do
		if record[field] ~= nil then
			table.insert(dropped, field)
		end
	end
	if typeof(record.Animations) == "table" and #record.Animations > 1 then
		table.insert(dropped, "Animations")
	end
	if typeof(record.Knockback) == "table" and numberOr(record.Knockback.RagdollSeconds, 0) > 0 then
		table.insert(dropped, "Knockback.RagdollSeconds")
	end

	local upgraded: Record = {}
	for _, field in
		{
			"MoveId",
			"DisplayName",
			"Description",
			"Category",
			"Author",
			"CreatedAt",
			"UpdatedAt",
			"OffsetX",
			"OffsetY",
			"OffsetZ",
			"WindupSeconds",
			"ActiveSeconds",
			"RecoverySeconds",
			"Cooldown",
			"Damage",
			"PostureDamage",
			"MaxTargets",
			"PowerLevel",
			"Feintable",
			"Grab",
			"Art",
		}
	do
		upgraded[field] = record[field]
	end

	local geometryAuthored = record.Shape ~= nil or record.Dimensions ~= nil or record.Size ~= nil
	if geometryAuthored then
		local legacyShape = if typeof(record.Shape) == "string" then record.Shape else "Box"
		local shape = LEGACY_SHAPE[legacyShape]
		if shape then
			upgraded.Shape = shape
			upgraded.Dimensions = legacyDimensions(record, legacyShape)
		else
			-- Not a shape either vocabulary knows. Passed through so Validate rejects it by name, rather
			-- than guessed at here.
			upgraded.Shape = record.Shape
		end
	end

	upgraded.OffsetPitch = record.OffsetRotationX
	upgraded.OffsetYaw = record.OffsetRotationY
	upgraded.OffsetRoll = record.OffsetRotationZ

	if record.AnimationId ~= nil or record.Animations ~= nil then
		upgraded.AnimationId = legacyClipId(record)
	end

	if typeof(record.Knockback) == "table" then
		upgraded.Knockback = {
			UpVelocity = record.Knockback.UpVelocity,
			HorizontalVelocity = record.Knockback.HorizontalVelocity,
			StartsAirCombo = record.Knockback.StartsAirCombo == true,
		}
	end

	return upgraded, dropped
end

-- Encoding ------------------------------------------------------------------------------------------

-- A custom move's full record: the wire shape, its identity stamps and the schema version.
function MoveRecordCodec.Encode(move: MoveTypes.MoveDefinition): Record
	local record = MoveTypes.ToWire(move)
	record.SchemaVersion = SCHEMA_VERSION
	record.Author = move.Author
	record.CreatedAt = move.CreatedAt
	record.UpdatedAt = move.UpdatedAt
	return record
end

-- A Default move's override record. The whole wire shape is written -- DefaultMoveRegistry.ApplyEdit
-- takes only the overridable fields from it, so carrying the rest costs a few bytes and saves keeping a
-- second, narrower field list in step with Override.
function MoveRecordCodec.EncodeOverride(move: MoveTypes.MoveDefinition): Record
	local record = MoveTypes.ToWire(move)
	record.SchemaVersion = SCHEMA_VERSION
	return record
end

-- Decoding ------------------------------------------------------------------------------------------

-- A stored custom-move record as a Validate candidate, plus the retired fields it lost in the upgrade
-- (always empty for a v3 record). nil for anything that is not even table-shaped.
function MoveRecordCodec.Decode(raw: unknown): (Record?, { string })
	if typeof(raw) ~= "table" then
		return nil, {}
	end
	local record = raw :: Record
	local version = numberOr(record.SchemaVersion, 1)
	if version >= 3 then
		local candidate = table.clone(record)
		candidate.SchemaVersion = nil
		return candidate, {}
	end
	return upgradeLegacy(record)
end

-- A stored override record as a candidate for DefaultMoveRegistry.ApplyEdit: the move as built, with
-- whatever the record carries laid over it. Starting from the built move is what lets an old override
-- that only ever stored some fields (no rotation, say) still produce a whole candidate.
function MoveRecordCodec.DecodeOverride(built: MoveTypes.MoveDefinition, raw: unknown): (Record?, { string })
	if typeof(raw) ~= "table" then
		return nil, {}
	end
	local record = raw :: Record
	local overlay: Record
	local dropped: { string } = {}
	if numberOr(record.SchemaVersion, 1) >= 3 then
		overlay = record
	else
		overlay, dropped = upgradeLegacy(record)
	end

	local candidate = MoveTypes.ToWire(built)
	for key, value in pairs(overlay) do
		if key ~= "SchemaVersion" and value ~= nil then
			candidate[key] = value
		end
	end
	return candidate, dropped
end

return MoveRecordCodec
