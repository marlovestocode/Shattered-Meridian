--!strict
--[[
	WorldMaterializer.lua

	Owns: the Instances of the managed world -- the `Workspace.ArchitectWorld` folder and everything the World Architect
	built under it -- kept equal to WorldState by applying each delta.

	ONLY ITS OWN INSTANCES. It creates the folder, and it destroys and rewrites only Instances it made itself (tracked by
	id in `instances`). If a place already contains a folder of that name, the folder is reused but anything already in it
	is left alone: nothing authored in Studio is ever touched by this module. That, plus every request addressing nodes
	by server-issued id, is the whole of why the original map is protected by construction.

	SERVER-OWNED PHYSICS. An unanchored built part keeps the server as its network owner, so no client can move it.

	DIFFS, NOT REBUILDS. A delta's upserts are written onto the existing Instance (recreated only when a shape change
	needs another class); removes destroy exactly those ids. Parenting is a second pass, so a group and its children
	arriving in one delta land in the right order whatever order the delta lists them in.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ArchitectBuild = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectBuild)
local ArchitectConstants = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectConstants)
local ArchitectRecord = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectRecord)

type NodeRecord = ArchitectRecord.NodeRecord

local WorldMaterializer = {}

export type Materializer = {
	Root: Folder,
	Instances: { [string]: Instance },
}

function WorldMaterializer.New(container: Instance): Materializer
	local existing = container:FindFirstChild(ArchitectConstants.RootFolderName)
	local root: Folder
	if existing and existing:IsA("Folder") then
		root = existing
	else
		root = Instance.new("Folder")
		root.Name = ArchitectConstants.RootFolderName
		root.Parent = container
	end
	return { Root = root, Instances = {} }
end

-- Brings the Instances in line with a WorldState delta.
function WorldMaterializer.Apply(materializer: Materializer, upserts: { NodeRecord }, removes: { string }): ()
	local instances = materializer.Instances
	for _, id in removes do
		local instance = instances[id]
		if instance then
			instances[id] = nil
			-- Children that survive (re-parented in this same delta) are moved out first by the parent pass below; a
			-- removed group's own children are always removed with it (WorldState refuses orphans).
			for _, child in instance:GetChildren() do
				local childId = child:GetAttribute(ArchitectConstants.IdAttribute)
				if childId and instances[childId :: string] == child then
					child.Parent = materializer.Root
				end
			end
			instance:Destroy()
		end
	end
	for _, record in upserts do
		local instance: Instance? = instances[record.Id]
		if instance and instance.ClassName ~= ArchitectBuild.ClassOf(record) then
			for _, child in instance:GetChildren() do
				child.Parent = materializer.Root
			end
			instance:Destroy()
			instance = nil
		end
		if instance then
			ArchitectBuild.Write(instance, record)
		else
			instances[record.Id] = ArchitectBuild.Make(record)
		end
	end
	for _, record in upserts do
		local instance = instances[record.Id]
		local parent = if record.Parent then instances[record.Parent] else nil
		instance.Parent = parent or materializer.Root
	end
	-- A model's pivot is reset by parenting children into it; write group pivots again once the tree is settled.
	for _, record in upserts do
		if record.Kind == "Group" then
			(instances[record.Id] :: Model).WorldPivot = ArchitectRecord.CFrameOf(record)
		elseif not record.Anchored then
			-- An unanchored part would otherwise be handed to whichever client is nearest, and an exploiting client
			-- can move what it owns. The server keeps every built part. pcall: only legal once the part is in
			-- Workspace (a spec's detached container is not).
			local part = instances[record.Id] :: BasePart
			pcall(function()
				part:SetNetworkOwner(nil)
			end)
		end
	end
end

function WorldMaterializer.InstanceOf(materializer: Materializer, id: string): Instance?
	return materializer.Instances[id]
end

return WorldMaterializer
