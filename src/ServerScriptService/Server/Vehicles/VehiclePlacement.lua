--!strict
--[[
	VehiclePlacement.lua

	Owns: the arithmetic that decides where a hull actually materialises -- how far in front of the
	requester it has to start given its own size, how its underside is seated above whatever the
	ground probe found, and flattening a requester's facing into a heading. Pure functions over
	CFrames and Vector3s: nothing here touches an Instance, casts a ray, or reads a service, which is
	what makes every rule below testable without a place file.

	SIZE IS AN INPUT TO THE OFFSET, NOT A CONSTANT, and that is the whole reason this file exists
	rather than the one line every other "spawn near me" admin tool in this codebase uses. Both of
	those (DevMenuSystem's handleSpawnDebugDummy and handleSpawnCoalDeposit) offset by a fixed number
	of studs, which is exactly right for a humanoid and a rock. A blimp is two hundred studs long. A
	fixed 6-stud offset does not spawn it in front of you, it spawns it AROUND you -- and the first
	physics step then resolves the interpenetration by throwing whichever of the two masses it likes
	less, which from the requester's seat reads as the spawn button killing them.

	THE RADIUS IS THE HORIZONTAL DIAGONAL, NOT THE FORWARD EXTENT. HorizontalRadius below takes half
	the XZ diagonal rather than half the depth along the heading, which over-reserves for a long hull
	spawned nose-on. That is deliberate and it is the cheap answer to a real problem: a Model's own
	bounding box is axis-aligned in ITS space, so the extent along an arbitrary world heading needs
	the full oriented projection, and getting that subtly wrong is a bug that only shows up for hulls
	at particular yaws. Reserving the circumscribing circle is never too small at any rotation, and
	the cost of being too large is a few studs of extra clear air.

	FLATTENYAW IS NOT COSMETIC. A requester's CFrame carries their camera pitch. Spawning a hull on
	that CFrame unmodified tilts it by however far they happened to be looking up, and an airship
	handed to the physics solver already banked forty degrees nose-down does not recover -- it dives.
	Every spawn goes through this, including a berth's own CFrame, since a builder can leave a pad
	fractionally tilted without ever noticing.

	Does not own: where the ground IS (Server/Systems/VehicleManager.lua casts the probe and hands the
	result down as a plain number), which berth was picked (Server/Vehicles/VehicleBerths.lua), or
	anything about the Model being placed.
]]

local VehiclePlacement = {}

-- Half the diagonal of the model's horizontal footprint -- the radius of the smallest upright
-- cylinder that contains it at ANY yaw. See this file's header on why the circumscribing circle beats
-- the exact oriented extent here.
function VehiclePlacement.HorizontalRadius(modelSize: Vector3): number
	return Vector2.new(modelSize.X, modelSize.Z).Magnitude * 0.5
end

-- `cframe` with its pitch and roll discarded, keeping only its position and its compass heading. A
-- LookVector that points straight up or straight down has no heading to keep, so the original
-- rotation is returned untouched rather than collapsing to an arbitrary one -- the honest answer, and
-- the same choice BlimpTagging.yawBetween makes for the same degenerate case.
function VehiclePlacement.FlattenYaw(cframe: CFrame): CFrame
	local look = cframe.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 1e-4 then
		return cframe
	end
	return CFrame.lookAt(cframe.Position, cframe.Position + flat.Unit)
end

-- Where a hull of `modelSize` should sit so that its nearest face clears `origin` by `gapStuds`,
-- placed along origin's own flattened heading and facing the same way. Facing the same way rather
-- than back at the requester: a vehicle is something you walk onto from behind, and a hull spun to
-- face you is one whose bow points at the wall you were standing against.
function VehiclePlacement.InFrontOf(origin: CFrame, modelSize: Vector3, gapStuds: number): CFrame
	local heading = VehiclePlacement.FlattenYaw(origin)
	local distance = VehiclePlacement.HorizontalRadius(modelSize) + gapStuds
	return heading * CFrame.new(0, 0, -distance)
end

-- `pivot` raised (or lowered) so the model's underside sits `clearanceStuds` above `groundY`.
--
-- A Model's pivot is not its base -- for a Blimp it is roughly the middle of the envelope, tens of
-- studs above the gondola -- so seating by "put the pivot at ground level" buries most of the hull.
-- Half the model's height is the offset from pivot to underside for a bounding box centred on the
-- pivot, which is what Model:GetBoundingBox returns and therefore what the caller measured.
function VehiclePlacement.SeatOnGround(
	pivot: CFrame,
	modelSize: Vector3,
	groundY: number,
	clearanceStuds: number
): CFrame
	local targetY = groundY + clearanceStuds + modelSize.Y * 0.5
	return pivot - pivot.Position + Vector3.new(pivot.Position.X, targetY, pivot.Position.Z)
end

-- Where a berth places a hull: the berth's own flattened heading, lifted so the hull sits
-- `clearanceStuds` above the berth part's TOP surface rather than its centre. The top surface,
-- because a berth is a pad a builder drew with some thickness and the deck is the face they can see.
function VehiclePlacement.AtBerth(
	berthCFrame: CFrame,
	berthSize: Vector3,
	modelSize: Vector3,
	clearanceStuds: number
): CFrame
	local heading = VehiclePlacement.FlattenYaw(berthCFrame)
	local deckY = berthCFrame.Position.Y + berthSize.Y * 0.5
	return VehiclePlacement.SeatOnGround(heading, modelSize, deckY, clearanceStuds)
end

return VehiclePlacement
