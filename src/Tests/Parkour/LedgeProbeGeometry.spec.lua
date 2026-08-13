--!strict
-- Covers the spatial-query CONTRACT that Client/Parkour/EnvironmentProbe.probeLedge's ledge search is
-- built on, against the real engine.
--
-- WHY THIS SPEC EXISTS, and why it is not Instance-free like the rest of the parkour decision-layer
-- specs. The ledge face search uses Workspace:Spherecast rather than Workspace:Raycast, and it makes
-- three assumptions about what comes back that nothing else in the toolchain can check: selene does
-- not know Roblox's API surface, stylua does not care, and Luau's type checker cannot tell a real
-- WorldRoot method from a hallucinated one. The same class of failure has already cost this codebase a
-- playtest once -- see ParkourMotor.spec.lua's own header for the AlignOrientation.RelativeTo bug, and
-- note the failure MODE is identical here: probeLedge runs inside ParkourController's pcall, so a
-- method that does not exist would not crash anything, it would silently make ledge grabbing stop
-- working while the debug overlay cheerfully reported "ledge none".
--
-- The three assumptions, each asserted below:
--   1. Spherecast exists, takes (origin, radius, direction, params), and returns a RaycastResult.
--   2. Its Normal is the hit FACE's outward normal -- the value that becomes LedgeProbe.WallNormal and
--      therefore the axis ParkourMath.HangPosition backs the hang pose off along.
--   3. It hits geometry a ray down the same centre line MISSES. That is the entire reason it is here;
--      if the two ever agreed, the extra cast would be pure cost.
-- Plus one the engine taught this spec rather than the other way round: a sweep that starts already
-- overlapping geometry returns NIL, which is why the ray runs first and the sphere is the fallback.
--
-- Touches Workspace, so it cleans up after itself as rigorously as ParkourMotor.spec does.

local Workspace = game:GetService("Workspace")

local UP = Vector3.new(0, 1, 0)

-- A wall face on the -Z side of the origin, so its outward normal points back toward +Z -- the same
-- orientation ParkourMath.spec's own HangPosition cases use, kept identical on purpose so the two
-- specs describe one geometry rather than two.
local function makeWall(): BasePart
	local wall = Instance.new("Part")
	wall.Name = "LedgeProbeSpecWall"
	wall.Anchored = true
	wall.CanCollide = true
	wall.Size = Vector3.new(8, 12, 2)
	wall.CFrame = CFrame.new(0, 200, -6)
	wall.Parent = Workspace
	return wall
end

local function paramsFor(wall: BasePart): RaycastParams
	local params = RaycastParams.new()
	-- Include rather than Exclude: the test place has other specs' leftovers and the baseplate in it,
	-- and this spec is asserting facts about ONE part.
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { wall }
	params.RespectCanCollide = true
	return params
end

return function()
	describe("Workspace:Spherecast -- the ledge face search's contract", function()
		it("exists as a WorldRoot method", function()
			-- Cheapest possible statement of the failure this spec is really guarding: if this line is
			-- ever red, ledge grabbing is dead in production and nothing else would have said so.
			expect(typeof(Workspace.Spherecast)).to.equal("function")
		end)

		it("returns the face's outward normal, not the sweep direction", function()
			local wall = makeWall()
			local params = paramsFor(wall)

			local result = Workspace:Spherecast(Vector3.new(0, 200, 0), 0.7, Vector3.new(0, 0, -1) * 6, params)
			expect(result).never.to.equal(nil)
			assert(result, "spherecast returned nil")
			expect(result.Instance).to.equal(wall)
			-- +Z: pointing back out of the wall at the caster. probeLedge hands this straight to
			-- ParkourMath.HangPosition as the axis to back the hang pose off along, and a normal pointing
			-- the other way would bury the character inside the wall they meant to hang on.
			expect(result.Normal.Z > 0.9).to.equal(true)
			expect(math.abs(result.Normal.Y) < 0.1).to.equal(true)

			wall:Destroy()
		end)

		it("catches a wall the equivalent ray sails past -- the whole reason the sweep is used", function()
			-- The player-facing case: reaching for the corner of a ledge with the root's centre line just
			-- outside the geometry. A ray reports open air; a sphere of the shipped radius does not.
			local wall = makeWall()
			local params = paramsFor(wall)

			-- The wall spans X in [-4, 4]. Start just past its edge so the centre line misses entirely.
			local origin = Vector3.new(4.4, 200, 0)
			local direction = Vector3.new(0, 0, -1) * 6

			expect(Workspace:Raycast(origin, direction, params)).to.equal(nil)
			expect(Workspace:Spherecast(origin, 0.7, direction, params)).never.to.equal(nil)

			wall:Destroy()
		end)

		it("returns NIL, not a distance-zero hit, when the sweep starts inside geometry", function()
			-- Written expecting a distance-zero hit; the engine says otherwise, and the difference is the
			-- reason tryLedgeDirection casts a ray BEFORE the sphere rather than after it. A sweep that
			-- reported zero distance could be detected and recovered from; one that reports nothing is
			-- indistinguishable from open air, so it cannot be the primary instrument.
			local wall = makeWall()
			local params = paramsFor(wall)

			expect(Workspace:Spherecast(wall.Position, 0.7, Vector3.new(0, 0, -1) * 6, params)).to.equal(nil)

			wall:Destroy()
		end)

		it("goes blind against a wall the character is pressed against -- where the ray still sees", function()
			-- The consequence of the case above, in the geometry that actually occurs: a head closer to the
			-- face than the sphere's own radius. This is not an exotic pose, it is what hugging a wall
			-- looks like, and it is precisely the situation the original single ray handled perfectly. If
			-- the probe ever goes back to leading with the sphere, THIS is the grab that silently stops
			-- working -- so the two casts are asserted to disagree here rather than left to be rediscovered
			-- in a playtest.
			local wall = makeWall()
			local params = paramsFor(wall)

			-- Wall front face is at Z = -5; sit the origin 0.4 studs off it, inside a 0.7 sphere's reach.
			local origin = Vector3.new(0, 200, -4.6)
			local direction = Vector3.new(0, 0, -1) * 6

			expect(Workspace:Spherecast(origin, 0.7, direction, params)).to.equal(nil)
			local rayHit = Workspace:Raycast(origin, direction, params)
			expect(rayHit).never.to.equal(nil)
			assert(rayHit, "raycast returned nil")
			expect(rayHit.Normal.Z > 0.9).to.equal(true)

			wall:Destroy()
		end)

		it("finds the lip above the face where the downward scan expects it", function()
			-- The second half of probeLedge, and the reason the scan origin is nudged past the face by a
			-- fixed 0.3 studs: a scan dropped exactly ON the face's plane is a coin flip between landing on
			-- the top surface and skimming down the front of it.
			local wall = makeWall()
			local params = paramsFor(wall)

			local faceHit = Workspace:Spherecast(Vector3.new(0, 200, 0), 0.7, Vector3.new(0, 0, -1) * 6, params)
			assert(faceHit, "spherecast returned nil")

			local forward = Vector3.new(0, 0, -1)
			local scanOrigin = Vector3.new(faceHit.Position.X, 210, faceHit.Position.Z) + forward * 0.3
			local lipHit = Workspace:Raycast(scanOrigin, Vector3.new(0, -12, 0), params)
			expect(lipHit).never.to.equal(nil)
			assert(lipHit, "lip scan returned nil")
			-- Top of a 12-tall part centred at Y=200.
			expect(math.abs(lipHit.Position.Y - 206) < 0.1).to.equal(true)
			expect(lipHit.Normal:Dot(UP) > 0.9).to.equal(true)

			wall:Destroy()
		end)
	end)
end
