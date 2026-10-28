--!strict
-- ArchitectTransform: snapping, pivots and multi-object operations, all pure.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ArchitectRecord = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectRecord)
local ArchitectTransform = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectTransform)

type NodeRecord = ArchitectRecord.NodeRecord

local function part(id: string, position: Vector3, size: Vector3?, orientation: Vector3?): NodeRecord
	local record = ArchitectRecord.Default("Part", "Structure", id)
	record.Position = position
	record.Size = size or Vector3.new(2, 2, 2)
	record.Orientation = orientation or Vector3.zero
	return record
end

local function near(a: Vector3, b: Vector3): boolean
	return (a - b).Magnitude < 1e-3
end

return function()
	describe("snapping", function()
		it("snaps to the step and leaves values alone at step 0", function()
			expect(ArchitectTransform.Snap(3.4, 1)).to.equal(3)
			expect(ArchitectTransform.Snap(3.6, 0.5)).to.equal(3.5)
			expect(ArchitectTransform.Snap(3.37, 0)).to.equal(3.37)
			expect(ArchitectTransform.SnapVector(Vector3.new(1.2, -2.7, 7.9), 2)).to.equal(Vector3.new(2, -2, 8))
		end)
	end)

	describe("bounds and pivot", function()
		it("bounds rotated parts by their real extent", function()
			local low, high =
				ArchitectTransform.Bounds({ part("a", Vector3.zero, Vector3.new(4, 2, 2), Vector3.new(0, 90, 0)) })
			assert(low and high, "bounds")
			expect(near(high - low, Vector3.new(2, 2, 4))).to.equal(true)
		end)

		it("pivots on the centre of the floor of the set", function()
			local pivot =
				ArchitectTransform.PivotOf({ part("a", Vector3.new(0, 1, 0)), part("b", Vector3.new(10, 5, 0)) })
			expect(near(pivot, Vector3.new(5, 0, 0))).to.equal(true)
		end)
	end)

	describe("set transforms", function()
		it("translating a set preserves every relative offset, including a group's pivot", function()
			local group = ArchitectRecord.Default("Group", nil, "g")
			group.Position = Vector3.new(1, 0, 1)
			local set = { group, part("a", Vector3.new(0, 1, 0)), part("b", Vector3.new(4, 1, 0)) }
			local moved = ArchitectTransform.Translate(set, Vector3.new(10, 0, -5))
			expect(near(moved[1].Position, Vector3.new(11, 0, -4))).to.equal(true)
			expect(near(moved[3].Position - moved[2].Position, Vector3.new(4, 0, 0))).to.equal(true)
			expect(near(set[2].Position, Vector3.new(0, 1, 0))).to.equal(true) -- inputs untouched
		end)

		it("rotating 90 degrees about a pivot turns positions and orientations together", function()
			local moved =
				ArchitectTransform.RotateAbout({ part("a", Vector3.new(4, 0, 0)) }, Vector3.zero, Vector3.yAxis, 90)
			expect(near(moved[1].Position, Vector3.new(0, 0, -4))).to.equal(true)
			expect(math.abs(moved[1].Orientation.Y - 90) < 1e-3).to.equal(true)
		end)

		it("uniform scale keeps the composition's shape about the pivot", function()
			local scaled =
				ArchitectTransform.ScaleSet({ part("a", Vector3.new(2, 1, 0), Vector3.new(2, 2, 2)) }, Vector3.zero, 2)
			expect(near(scaled[1].Position, Vector3.new(4, 2, 0))).to.equal(true)
			expect(near(scaled[1].Size, Vector3.new(4, 4, 4))).to.equal(true)
		end)

		it("ResizeFace grows one face and keeps the opposite face where it was", function()
			local record = part("a", Vector3.new(0, 0, 0), Vector3.new(4, 2, 2))
			local grown = ArchitectTransform.ResizeFace(record, "X", 1, 2, 0.05)
			expect(near(grown.Size, Vector3.new(6, 2, 2))).to.equal(true)
			expect(grown.Position.X - grown.Size.X / 2).to.equal(-2)
		end)

		it("StretchSet makes a set longer along one axis only, the opposite side fixed", function()
			-- A wall: a 16-long body and a coping on top, both aligned with X; stretched to double length from x = -8.
			local body = part("a", Vector3.new(0, 4, 0), Vector3.new(16, 7, 2))
			local coping = part("b", Vector3.new(0, 8, 0), Vector3.new(16, 1, 3))
			local stretched = ArchitectTransform.StretchSet({ body, coping }, "X", -8, 2, 0.05)
			expect(near(stretched[1].Size, Vector3.new(32, 7, 2))).to.equal(true)
			expect(near(stretched[2].Size, Vector3.new(32, 1, 3))).to.equal(true)
			expect(near(stretched[1].Position, Vector3.new(8, 4, 0))).to.equal(true)
			expect(near(stretched[2].Position, Vector3.new(8, 8, 0))).to.equal(true)
			local low = ArchitectTransform.Bounds(stretched)
			expect(math.abs((low :: Vector3).X + 8) < 1e-3).to.equal(true)
		end)

		it("StretchSet grows a turned part along the local axis that lines up with the stretch", function()
			-- A part turned 90 degrees: its local Z now runs along world X, so Z is what lengthens.
			local turned = part("a", Vector3.zero, Vector3.new(2, 2, 6), Vector3.new(0, 90, 0))
			local stretched = ArchitectTransform.StretchSet({ turned }, "X", -3, 1.5, 0.05)[1]
			expect(near(stretched.Size, Vector3.new(2, 2, 9))).to.equal(true)
			expect(math.abs(stretched.Orientation.Y - 90) < 1e-3).to.equal(true)
		end)

		it("ResizeFace never shrinks below the minimum", function()
			local shrunk =
				ArchitectTransform.ResizeFace(part("a", Vector3.zero, Vector3.new(4, 2, 2)), "X", -1, -100, 0.5)
			expect(shrunk.Size.X).to.equal(0.5)
		end)
	end)

	describe("arrange", function()
		it("aligns each item's minimum to the selection's", function()
			local items = { { part("a", Vector3.new(0, 1, 0)) }, { part("b", Vector3.new(0, 5, 0)) } }
			local aligned = ArchitectTransform.Align(items, "Y", "Min")
			for _, record in aligned do
				expect(math.abs(record.Position.Y - 1) < 1e-4).to.equal(true)
			end
		end)

		it("distributes centres evenly between the outermost items", function()
			local items = {
				{ part("a", Vector3.new(0, 0, 0)) },
				{ part("b", Vector3.new(1, 0, 0)) },
				{ part("c", Vector3.new(10, 0, 0)) },
			}
			local spread = ArchitectTransform.Distribute(items, "X")
			local xs: { number } = {}
			for _, record in spread do
				table.insert(xs, record.Position.X)
			end
			table.sort(xs)
			expect(xs[2]).to.equal(5)
			expect(#ArchitectTransform.Distribute({ items[1], items[2] }, "X")).to.equal(0)
		end)

		it("mirroring twice through the same plane is the identity", function()
			local record = part("a", Vector3.new(3, 2, 1), Vector3.new(2, 3, 4), Vector3.new(15, 40, -10))
			local twice =
				ArchitectTransform.Mirror(ArchitectTransform.Mirror(record, Vector3.zero, "X"), Vector3.zero, "X")
			expect(near(twice.Position, record.Position)).to.equal(true)
			local a, b = ArchitectRecord.CFrameOf(twice), ArchitectRecord.CFrameOf(record)
			expect(a.LookVector:Dot(b.LookVector) > 0.999).to.equal(true)
		end)

		it("mirror reflects position through the plane", function()
			local mirrored = ArchitectTransform.Mirror(part("a", Vector3.new(3, 0, 0)), Vector3.new(5, 0, 0), "X")
			expect(near(mirrored.Position, Vector3.new(7, 0, 0))).to.equal(true)
		end)

		it("array offsets are cumulative and exclude the original", function()
			local offsets = ArchitectTransform.ArrayOffsets(3, Vector3.new(8, 0, 0))
			expect(#offsets).to.equal(3)
			expect(offsets[3]).to.equal(Vector3.new(24, 0, 0))
		end)
	end)

	describe("surface placement", function()
		it("rests a part on a floor instead of half inside it", function()
			local frame = ArchitectTransform.SurfacePlacement(
				Vector3.new(0.3, 10, 0.7),
				Vector3.yAxis,
				Vector3.new(4, 2, 4),
				0,
				1
			)
			expect(near(frame.Position, Vector3.new(0, 11, 1))).to.equal(true)
		end)

		it("sets a part against a wall, the grid snapping only along the wall", function()
			local frame =
				ArchitectTransform.SurfacePlacement(Vector3.new(5, 3.4, 2.2), Vector3.xAxis, Vector3.new(4, 2, 1), 0, 1)
			expect(math.abs(frame.Position.X - 5.5) < 1e-3).to.equal(true)
			expect(frame.Position.Y).to.equal(3)
			expect(frame.Position.Z).to.equal(2)
		end)
	end)
end
