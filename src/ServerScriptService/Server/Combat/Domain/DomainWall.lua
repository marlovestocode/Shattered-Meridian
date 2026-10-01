--!strict
--[[
	DomainWall.lua

	Owns: the PHYSICAL boundary a BoundaryCollision realm raises -- invisible anchored segments every body
	collides with, both ways. Built when the realm is established, destroyed when its law lifts.

	WHY PARTS AT ALL, when DomainSystem already enforces Barred edges: that enforcement is a correction a
	player can feel land (a body set back inside the line), which is right for a per-person, per-direction
	rule but wrong for a sealed arena. A collidable wall is simulated by every client for its own body, so
	a sealed realm feels like a wall and needs no correction at all. The price is that it is total: it
	cannot tell a member from a stranger, which is exactly what "sealed" means (DomainTypes' header).

	SHAPE. A Box is its four faces. A Cylinder, and a Sphere (walled as the cylinder that circumscribes it
	-- a curved shell of parts would be hundreds of wedges for no gameplay difference, since nobody walks
	over a realm's roof), is a ring of DomainConstants.Wall.Segments vertical slabs. No roof, no floor:
	the ground is the floor, and a leap over a realm's rim still meets the rule-based enforcement.

	CanQuery = false, so no raycast or hitbox broadphase ever sees a segment -- projectiles meet a realm's
	edge through the barrier slot (HitboxEngine.SetProjectileBarrier), never through geometry.

	Only a Fixed realm is walled; a FollowOwner realm moves every frame and a wall that followed it would be
	a physics body shoving everyone it swept past.

	Does not own: the geometry math (DomainGeometry), when a wall exists (DomainSystem), or any rule.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local DomainConstants = require(ReplicatedStorage.Shared.Domain.DomainConstants)
local DomainGeometry = require(ReplicatedStorage.Shared.Domain.DomainGeometry)

local DomainWall = {}

local WALL = DomainConstants.Wall

local function folder(): Folder
	local existing = Workspace:FindFirstChild(WALL.FolderName)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = WALL.FolderName
	created.Parent = Workspace
	return created
end

local function segment(parent: Instance, size: Vector3, cframe: CFrame): ()
	local part = Instance.new("Part")
	part.Name = "Segment"
	part.Anchored = true
	part.CanCollide = true
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = size
	part.CFrame = cframe
	part.Parent = parent
end

-- Raises the wall for `boundary`, named for realm `id`. Returns the Model holding it (destroy it to drop the
-- wall).
function DomainWall.Build(id: string, boundary: DomainGeometry.Boundary): Model
	local model = Instance.new("Model")
	model.Name = `Domain_{id}`
	local thickness = WALL.ThicknessStuds
	local height = boundary.Height
	local base = CFrame.new(boundary.Center) * CFrame.Angles(0, boundary.Yaw, 0)

	if boundary.Shape == "Box" then
		local width = boundary.Radius * 2 + thickness * 2
		local reach = boundary.Radius + thickness / 2
		for index = 0, 3 do
			local face = base * CFrame.Angles(0, index * math.pi / 2, 0) * CFrame.new(0, 0, -reach)
			segment(model, Vector3.new(width, height, thickness), face)
		end
	else
		local count = WALL.Segments
		-- Each slab spans its arc's chord plus a little, so neighbours overlap and leave no gap to squeeze by.
		local chord = 2 * (boundary.Radius + thickness) * math.sin(math.pi / count) + thickness
		local reach = boundary.Radius + thickness / 2
		for index = 0, count - 1 do
			local face = base * CFrame.Angles(0, index * 2 * math.pi / count, 0) * CFrame.new(0, 0, -reach)
			segment(model, Vector3.new(chord, height, thickness), face)
		end
	end

	model.Parent = folder()
	return model
end

return DomainWall
