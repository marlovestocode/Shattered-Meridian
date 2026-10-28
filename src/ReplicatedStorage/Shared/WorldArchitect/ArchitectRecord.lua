--!strict
--[[
	ArchitectRecord.lua

	Owns: what one World Architect node IS -- a Part or a Group, as plain data -- and the Schema shapes that turn
	untrusted data (a remote argument, a decoded DataStore chunk, a template) into one.

	A RECORD, NEVER AN INSTANCE. The server's WorldState holds these, the materializer turns them into Parts and Models,
	the codec persists them, the client mirrors them. No code path ever reads a property back off a live Instance and
	trusts it, so a client cannot smuggle a class, a script or a property this file does not name into the world.

	EVERY RECORD CARRIES EVERY FIELD. A Group uses Position/Orientation as its pivot and ignores the part fields; keeping
	one shape means the codec, the history and the patch path have no per-kind branches to get wrong.

	ORIENTATION IS ROBLOX'S: degrees, applied Y then X then Z (BasePart.Orientation / CFrame.fromOrientation). Positions
	outside the world bounds are REFUSED, never clamped -- a clamp would silently move what the admin placed. Sizes and
	appearance numbers clamp, the same "hard-reject on structure, clamp on numbers" rule Schema documents.

	ROLE DEFAULTS. A role says what gameplay may rely on a part for (ArchitectConstants.Roles). A new node's physics
	flags come from its role unless the request names them; the optimizer later reads the role to decide what it may
	propose.

	Does not own: limits (ArchitectConstants), where a node may be (WorldState's protected zones), or transform maths
	(ArchitectTransform).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Schema = require(ReplicatedStorage.Shared.Schema)
local ArchitectConstants = require(script.Parent.ArchitectConstants)

local Limits = ArchitectConstants.Limits

local ArchitectRecord = {}

export type Kind = "Part" | "Group"

export type NodeRecord = {
	Id: string,
	Kind: Kind,
	-- The Group this node sits in, or nil at the root of the managed world.
	Parent: string?,
	Name: string,
	Position: Vector3,
	Orientation: Vector3,
	Size: Vector3,
	Shape: string,
	Color: Color3,
	Material: string,
	Transparency: number,
	Reflectance: number,
	Anchored: boolean,
	CanCollide: boolean,
	CanTouch: boolean,
	CanQuery: boolean,
	CastShadow: boolean,
	Role: string,
	-- A locked node refuses every edit until it is unlocked.
	Locked: boolean,
	-- The template a node was placed from, for usage reports. Informational only.
	Template: string?,
	-- Server-assigned; bumped on every change. What concurrent edits and undo are checked against.
	Rev: number,
}

-- The fields an edit may change. Id, Kind, Parent, Template and Rev are never patched: parenting is Group/Ungroup's.
ArchitectRecord.PatchFields = table.freeze({
	"Name",
	"Position",
	"Orientation",
	"Size",
	"Shape",
	"Color",
	"Material",
	"Transparency",
	"Reflectance",
	"Anchored",
	"CanCollide",
	"CanTouch",
	"CanQuery",
	"CastShadow",
	"Role",
	"Locked",
})

type RoleFlags = {
	Anchored: boolean,
	CanCollide: boolean,
	CanTouch: boolean,
	CanQuery: boolean,
	CastShadow: boolean,
}

local ROLE_FLAGS: { [string]: RoleFlags } = {
	-- Touch is off for everything by default: nothing a builder makes has a Touched handler, and an enabled CanTouch
	-- costs the physics broadphase a touch pair for every body that brushes it.
	Structure = { Anchored = true, CanCollide = true, CanTouch = false, CanQuery = true, CastShadow = true },
	Walkable = { Anchored = true, CanCollide = true, CanTouch = false, CanQuery = true, CastShadow = true },
	Decor = { Anchored = true, CanCollide = false, CanTouch = false, CanQuery = false, CastShadow = true },
	Barrier = { Anchored = true, CanCollide = true, CanTouch = false, CanQuery = true, CastShadow = false },
}

function ArchitectRecord.RoleFlags(role: string): RoleFlags
	return ROLE_FLAGS[role] or ROLE_FLAGS.Structure
end

-- A complete record with every field at its default. `id` may be "" for a node the server has not numbered yet.
function ArchitectRecord.Default(kind: Kind, role: string?, id: string?): NodeRecord
	local flags = ArchitectRecord.RoleFlags(role or "Structure")
	return {
		Id = id or "",
		Kind = kind,
		Parent = nil,
		Name = if kind == "Group" then "Group" else "Part",
		Position = Vector3.zero,
		Orientation = Vector3.zero,
		Size = if kind == "Group" then Vector3.one else Vector3.new(4, 1, 4),
		Shape = "Block",
		Color = Color3.fromRGB(99, 95, 98),
		Material = "Slate",
		Transparency = 0,
		Reflectance = 0,
		Anchored = flags.Anchored,
		CanCollide = flags.CanCollide,
		CanTouch = flags.CanTouch,
		CanQuery = flags.CanQuery,
		CastShadow = flags.CastShadow,
		Role = role or "Structure",
		Locked = false,
		Template = nil,
		Rev = 0,
	}
end

function ArchitectRecord.Clone(record: NodeRecord): NodeRecord
	return table.clone(record)
end

function ArchitectRecord.CFrameOf(record: NodeRecord): CFrame
	local o = record.Orientation
	return CFrame.new(record.Position) * CFrame.fromOrientation(math.rad(o.X), math.rad(o.Y), math.rad(o.Z))
end

-- Orientation in Roblox's degrees for a CFrame's rotation, rounded so a round trip through the codec is stable.
function ArchitectRecord.OrientationOf(cframe: CFrame): Vector3
	local x, y, z = cframe:ToOrientation()
	local function round(radians: number): number
		local degrees = math.deg(radians)
		return math.round(degrees * 1000) / 1000
	end
	return Vector3.new(round(x), round(y), round(z))
end

-- A copy of `record` placed at `cframe`.
function ArchitectRecord.WithCFrame(record: NodeRecord, cframe: CFrame): NodeRecord
	local copy = table.clone(record)
	copy.Position = cframe.Position
	copy.Orientation = ArchitectRecord.OrientationOf(cframe)
	return copy
end

-- A copy of `record` with `patch` applied. The patch is assumed decoded (PatchShape).
function ArchitectRecord.Apply(record: NodeRecord, patch: { [string]: any }): NodeRecord
	local copy = table.clone(record) :: any
	for _, field in ArchitectRecord.PatchFields do
		local value = patch[field]
		if value ~= nil then
			copy[field] = value
		end
	end
	return copy :: NodeRecord
end

-- The same fields a patch covers, as a patch: what `record` holds for each field `patch` names. The inverse of Apply.
function ArchitectRecord.Capture(record: NodeRecord, patch: { [string]: any }): { [string]: any }
	local before: { [string]: any } = {}
	for _, field in ArchitectRecord.PatchFields do
		if patch[field] ~= nil then
			before[field] = (record :: any)[field]
		end
	end
	return before
end

-- True when every patched field already equals the record's own value.
function ArchitectRecord.IsNoop(record: NodeRecord, patch: { [string]: any }): boolean
	for _, field in ArchitectRecord.PatchFields do
		local value = patch[field]
		if value ~= nil and value ~= (record :: any)[field] then
			return false
		end
	end
	return true
end

--
-- Shapes
--

local number = Schema.Number(-1e7, 1e7)

-- A component that is a real, finite number. Schema.Number refuses NaN but CLAMPS infinity, and an infinite size
-- clamped to the part limit is a part nobody asked for -- so infinity is refused here before it can be clamped.
local function finite(n: number): number?
	if math.abs(n) == math.huge then
		return nil
	end
	return (number(n))
end

local function vector(raw: unknown): (Vector3?, string?)
	if not Schema.IsVector3(raw) then
		return nil, "expected Vector3"
	end
	local v = raw :: Vector3
	local x, y, z = finite(v.X), finite(v.Y), finite(v.Z)
	if x == nil or y == nil or z == nil then
		return nil, "non-finite component"
	end
	return Vector3.new(x, y, z), nil
end

ArchitectRecord.PositionShape = Schema.WithReason(
	"OutOfBounds",
	Schema.Custom(function(raw: unknown): (Vector3?, string?)
		local v, reason = vector(raw)
		if v == nil then
			return nil, reason
		end
		if
			math.abs(v.X) > Limits.WorldExtent
			or math.abs(v.Z) > Limits.WorldExtent
			or v.Y < Limits.MinY
			or v.Y > Limits.MaxY
		then
			return nil, "outside world bounds"
		end
		return v, nil
	end)
)

ArchitectRecord.OrientationShape = Schema.Custom(function(raw: unknown): (Vector3?, string?)
	local v, reason = vector(raw)
	if v == nil then
		return nil, reason
	end
	local function wrap(degrees: number): number
		return ((degrees + 180) % 360) - 180
	end
	return Vector3.new(wrap(v.X), wrap(v.Y), wrap(v.Z)), nil
end)

ArchitectRecord.SizeShape = Schema.Custom(function(raw: unknown): (Vector3?, string?)
	local v, reason = vector(raw)
	if v == nil then
		return nil, reason
	end
	local function clamp(n: number): number
		return math.clamp(n, Limits.MinPartSize, Limits.MaxPartSize)
	end
	return Vector3.new(clamp(v.X), clamp(v.Y), clamp(v.Z)), nil
end)

ArchitectRecord.ColorShape = Schema.Custom(function(raw: unknown): (Color3?, string?)
	if typeof(raw) ~= "Color3" then
		return nil, "expected Color3"
	end
	local c = raw :: Color3
	local unit = Schema.Number(0, 1)
	local r = (unit(c.R))
	local g = (unit(c.G))
	local b = (unit(c.B))
	if r == nil or g == nil or b == nil then
		return nil, "non-finite colour"
	end
	return Color3.new(r, g, b), nil
end)

ArchitectRecord.NameShape = Schema.Default(Schema.String(Limits.MaxNameLength), "Part")
ArchitectRecord.RoleShape = Schema.Enum(ArchitectConstants.Roles)
ArchitectRecord.ShapeShape = Schema.Enum(ArchitectConstants.Shapes)
ArchitectRecord.MaterialShape = Schema.Enum(ArchitectConstants.Materials)
-- A server-issued id: short, alphanumeric. Never a path, never an Instance.
ArchitectRecord.IdShape = Schema.Custom(function(raw: unknown): (string?, string?)
	if not Schema.IsString(raw) then
		return nil, "expected id"
	end
	local id = raw :: string
	if #id < 1 or #id > 16 or string.find(id, "[^%w]") then
		return nil, "malformed id"
	end
	return id, nil
end)

-- Every editable field, all optional. What an Update names.
ArchitectRecord.PatchShape = Schema.Record({
	{ "Name", Schema.Optional(Schema.String(Limits.MaxNameLength)) },
	{ "Position", Schema.Optional(ArchitectRecord.PositionShape) },
	{ "Orientation", Schema.Optional(ArchitectRecord.OrientationShape) },
	{ "Size", Schema.Optional(ArchitectRecord.SizeShape) },
	{ "Shape", Schema.Optional(ArchitectRecord.ShapeShape) },
	{ "Color", Schema.Optional(ArchitectRecord.ColorShape) },
	{ "Material", Schema.Optional(ArchitectRecord.MaterialShape) },
	{ "Transparency", Schema.Optional(Schema.Number(0, 1)) },
	{ "Reflectance", Schema.Optional(Schema.Number(0, 1)) },
	{ "Anchored", Schema.Optional(Schema.Boolean) },
	{ "CanCollide", Schema.Optional(Schema.Boolean) },
	{ "CanTouch", Schema.Optional(Schema.Boolean) },
	{ "CanQuery", Schema.Optional(Schema.Boolean) },
	{ "CastShadow", Schema.Optional(Schema.Boolean) },
	{ "Role", Schema.Optional(ArchitectRecord.RoleShape) },
	{ "Locked", Schema.Optional(Schema.Boolean) },
})

local KindShape = Schema.Enum({ "Part", "Group" })

-- A node as a client proposes it (no Id, Parent or Rev -- those are the server's), decoded into a complete record
-- whose unnamed physics flags follow its role. Position is required: there is no sensible default place to build.
function ArchitectRecord.DecodeNew(raw: unknown): (NodeRecord?, string?)
	if not Schema.IsTable(raw) then
		return nil, "expected node"
	end
	local source = raw :: { [string]: unknown }
	local kind, kindReason = KindShape(source.Kind)
	if kind == nil then
		return nil, `Kind: {tostring(kindReason)}`
	end
	local role = "Structure"
	if source.Role ~= nil then
		local decodedRole = ArchitectRecord.RoleShape(source.Role)
		if decodedRole == nil then
			return nil, "Role: unknown role"
		end
		role = decodedRole
	end
	local patch, reason = Schema.Decode(ArchitectRecord.PatchShape, raw)
	if patch == nil then
		return nil, reason
	end
	if patch.Position == nil then
		return nil, "Position: required"
	end
	local record = ArchitectRecord.Apply(ArchitectRecord.Default(kind :: Kind, role), patch)
	local template = source.Template
	if Schema.IsString(template) and #(template :: string) <= 40 then
		record.Template = template :: string
	end
	return record, nil
end

return ArchitectRecord
