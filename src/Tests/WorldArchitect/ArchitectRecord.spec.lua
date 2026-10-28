--!strict
-- ArchitectRecord: what a World Architect node may be. Every client request and every stored record is decoded here,
-- so these are the cases a tampered client or a corrupted save would hit first.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ArchitectConstants = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectConstants)
local ArchitectRecord = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectRecord)

local Limits = ArchitectConstants.Limits

local function node(overrides: { [string]: any }?): { [string]: any }
	local raw: { [string]: any } = { Kind = "Part", Position = Vector3.new(10, 5, -3) }
	for key, value in overrides or {} do
		raw[key] = value
	end
	return raw
end

return function()
	describe("DecodeNew", function()
		it("builds a complete record with role defaults from a minimal node", function()
			local record = ArchitectRecord.DecodeNew(node({ Role = "Decor" }))
			assert(record, "expected a record")
			expect(record.Kind).to.equal("Part")
			expect(record.Position).to.equal(Vector3.new(10, 5, -3))
			expect(record.Role).to.equal("Decor")
			expect(record.CanCollide).to.equal(false)
			expect(record.CanQuery).to.equal(false)
			expect(record.Anchored).to.equal(true)
			expect(record.Id).to.equal("")
			expect(record.Rev).to.equal(0)
		end)

		it("keeps explicitly named flags over the role's defaults", function()
			local record = ArchitectRecord.DecodeNew(node({ Role = "Decor", CanCollide = true }))
			assert(record, "expected a record")
			expect(record.CanCollide).to.equal(true)
		end)

		it("refuses a node without a position", function()
			local record, reason = ArchitectRecord.DecodeNew({ Kind = "Part" })
			expect(record).to.equal(nil)
			expect(reason).to.equal("Position: required")
		end)

		it("refuses positions outside the world instead of clamping them", function()
			local far = Vector3.new(Limits.WorldExtent + 1, 0, 0)
			local record, reason = ArchitectRecord.DecodeNew(node({ Position = far }))
			expect(record).to.equal(nil)
			expect(reason).to.equal("OutOfBounds")
			expect(ArchitectRecord.DecodeNew(node({ Position = Vector3.new(0, Limits.MaxY + 1, 0) }))).to.equal(nil)
		end)

		it("refuses NaN and infinite components", function()
			expect(ArchitectRecord.DecodeNew(node({ Position = Vector3.new(0 / 0, 0, 0) }))).to.equal(nil)
			expect(ArchitectRecord.DecodeNew(node({ Size = Vector3.new(math.huge, 1, 1) }))).to.equal(nil)
			expect(ArchitectRecord.DecodeNew(node({ Orientation = Vector3.new(0, 0 / 0, 0) }))).to.equal(nil)
		end)

		it("clamps sizes into the part limits", function()
			local record = ArchitectRecord.DecodeNew(node({ Size = Vector3.new(0.001, 9999, 4) }))
			assert(record, "expected a record")
			-- Vector3 holds float32, so compare within its precision.
			expect(math.abs(record.Size.X - Limits.MinPartSize) < 1e-6).to.equal(true)
			expect(record.Size.Y).to.equal(Limits.MaxPartSize)
		end)

		it("refuses unknown kinds, roles, shapes and materials", function()
			expect(ArchitectRecord.DecodeNew(node({ Kind = "Script" }))).to.equal(nil)
			expect(ArchitectRecord.DecodeNew(node({ Role = "Admin" }))).to.equal(nil)
			expect(ArchitectRecord.DecodeNew(node({ Shape = "MeshPart" }))).to.equal(nil)
			expect(ArchitectRecord.DecodeNew(node({ Material = "Water" }))).to.equal(nil)
		end)

		it("ignores fields a node may not carry", function()
			local record =
				ArchitectRecord.DecodeNew(node({ ClassName = "Script", Source = "while true do end", Id = "x" }))
			assert(record, "expected a record")
			expect((record :: any).ClassName).to.equal(nil)
			expect((record :: any).Source).to.equal(nil)
			expect(record.Id).to.equal("")
		end)

		it("refuses tables with metatables", function()
			local raw = setmetatable(node(), {
				__index = function()
					return 1
				end,
			})
			expect(ArchitectRecord.DecodeNew(raw)).to.equal(nil)
		end)

		it("wraps orientation into -180..180", function()
			local record = ArchitectRecord.DecodeNew(node({ Orientation = Vector3.new(0, 270, -190) }))
			assert(record, "expected a record")
			expect(record.Orientation.Y).to.equal(-90)
			expect(record.Orientation.Z).to.equal(170)
		end)
	end)

	describe("IdShape", function()
		it("accepts short alphanumeric ids only", function()
			expect(ArchitectRecord.IdShape("n1a")).to.equal("n1a")
			expect((ArchitectRecord.IdShape("../Workspace"))).to.equal(nil)
			expect((ArchitectRecord.IdShape(""))).to.equal(nil)
			expect((ArchitectRecord.IdShape(string.rep("a", 17)))).to.equal(nil)
			expect((ArchitectRecord.IdShape(5))).to.equal(nil)
		end)
	end)

	describe("patches", function()
		it("Apply then Capture round-trips exactly the patched fields", function()
			local record = ArchitectRecord.Default("Part", "Structure", "n1")
			local patch = { Name = "Wall", Transparency = 0.5 }
			local before = ArchitectRecord.Capture(record, patch)
			local after = ArchitectRecord.Apply(record, patch)
			expect(after.Name).to.equal("Wall")
			expect(after.Transparency).to.equal(0.5)
			expect(record.Name).to.equal("Part")
			local restored = ArchitectRecord.Apply(after, before)
			expect(restored.Name).to.equal(record.Name)
			expect(restored.Transparency).to.equal(record.Transparency)
		end)

		it("never patches Id, Parent or Rev", function()
			local record = ArchitectRecord.Default("Part", "Structure", "n1")
			local after = ArchitectRecord.Apply(record, { Id = "n9", Parent = "n2", Rev = 99 } :: any)
			expect(after.Id).to.equal("n1")
			expect(after.Parent).to.equal(nil)
			expect(after.Rev).to.equal(0)
		end)

		it("IsNoop is true only when nothing would change", function()
			local record = ArchitectRecord.Default("Part", "Structure", "n1")
			expect(ArchitectRecord.IsNoop(record, { Name = "Part" })).to.equal(true)
			expect(ArchitectRecord.IsNoop(record, { Name = "Other" })).to.equal(false)
		end)

		it("WithCFrame and CFrameOf agree", function()
			local record = ArchitectRecord.Default("Part", "Structure", "n1")
			local frame = CFrame.new(3, 4, 5) * CFrame.fromOrientation(math.rad(10), math.rad(45), math.rad(-20))
			local placed = ArchitectRecord.WithCFrame(record, frame)
			local back = ArchitectRecord.CFrameOf(placed)
			expect((back.Position - frame.Position).Magnitude < 1e-4).to.equal(true)
			expect(back.LookVector:Dot(frame.LookVector) > 0.9999).to.equal(true)
			expect(back.UpVector:Dot(frame.UpVector) > 0.9999).to.equal(true)
		end)
	end)
end
