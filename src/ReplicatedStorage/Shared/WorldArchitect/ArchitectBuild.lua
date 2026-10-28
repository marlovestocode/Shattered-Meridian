--!strict
--[[
	ArchitectBuild.lua

	Owns: turning one World Architect record into the Instance it describes, and writing a record's properties onto an
	existing one. The server's WorldMaterializer builds the real world with it; the editor builds its previews (ghosts,
	the asset browser's viewport) with it, so a preview is the same part the commit will make.

	THE ONLY CLASSES EVER MADE: Part (Block, Ball, Cylinder), WedgePart, CornerWedgePart, and Model for a Group. The
	class follows from the record's Shape -- there is no field a record could carry that names a class.

	PROPERTY ORDER MATTERS ONCE: CanCollide before CanQuery, because the engine refuses CanQuery = false on a part that
	still collides; writing them the other way round would silently leave a non-colliding Decor part queryable.
]]

local ArchitectConstants = require(script.Parent.ArchitectConstants)
local ArchitectRecord = require(script.Parent.ArchitectRecord)

type NodeRecord = ArchitectRecord.NodeRecord

local ArchitectBuild = {}

local PART_SHAPE: { [string]: Enum.PartType } = {
	Block = Enum.PartType.Block,
	Ball = Enum.PartType.Ball,
	Cylinder = Enum.PartType.Cylinder,
}

-- The class a record's shape needs.
function ArchitectBuild.ClassOf(record: NodeRecord): string
	if record.Kind == "Group" then
		return "Model"
	elseif record.Shape == "Wedge" then
		return "WedgePart"
	elseif record.Shape == "CornerWedge" then
		return "CornerWedgePart"
	end
	return "Part"
end

local function material(name: string): Enum.Material
	local ok, value = pcall(function()
		return (Enum.Material :: any)[name]
	end)
	return if ok and value then value else Enum.Material.Slate
end

-- Writes `record` onto `instance` (whose class must be ClassOf(record)). Parent is the caller's.
function ArchitectBuild.Write(instance: Instance, record: NodeRecord): ()
	instance.Name = record.Name
	instance:SetAttribute(ArchitectConstants.IdAttribute, record.Id)
	if record.Kind == "Group" then
		local model = instance :: Model
		model.WorldPivot = ArchitectRecord.CFrameOf(record)
		return
	end
	instance:SetAttribute(ArchitectConstants.RoleAttribute, record.Role)
	local part = instance :: BasePart
	local shape = PART_SHAPE[record.Shape]
	if shape and part:IsA("Part") then
		(part :: Part).Shape = shape
	end
	part.Size = record.Size
	part.CFrame = ArchitectRecord.CFrameOf(record)
	part.Color = record.Color
	part.Material = material(record.Material)
	part.Transparency = record.Transparency
	part.Reflectance = record.Reflectance
	part.Anchored = record.Anchored
	part.CanCollide = record.CanCollide
	part.CanQuery = record.CanQuery
	part.CanTouch = record.CanTouch
	part.CastShadow = record.CastShadow
	part.Locked = record.Locked
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
end

function ArchitectBuild.Make(record: NodeRecord): Instance
	local instance = Instance.new(ArchitectBuild.ClassOf(record))
	ArchitectBuild.Write(instance, record)
	return instance
end

-- A set of records built as one detached Model, parents honoured where the parent is in the set. For previews.
function ArchitectBuild.Assemble(records: { NodeRecord }, name: string): Model
	local root = Instance.new("Model")
	root.Name = name
	local built: { [string]: Instance } = {}
	for _, record in records do
		built[record.Id] = ArchitectBuild.Make(record)
	end
	for _, record in records do
		local instance = built[record.Id]
		local parent = if record.Parent then built[record.Parent] else nil
		instance.Parent = parent or root
	end
	return root
end

return ArchitectBuild
