--!strict
-- Covers the Move Editor's version history -- MoveEditorSystem.AppendVersion (UpdateAsync's transform)
-- and MoveEditorSystem.SummarizeChange (the line each version shows). Both pure; the remotes around them
-- are DataStore-backed, which this harness cannot stand up.

local ServerScriptService = game:GetService("ServerScriptService")

local MoveEditorSystem = require(ServerScriptService.Server.Systems.MoveEditorSystem)

local function entry(tag: number): any
	return { SavedAt = 1000 + tag, AdminName = "Spec", AdminUserId = 1, Record = { Damage = tag } }
end

return function()
	describe("MoveEditorSystem.AppendVersion", function()
		it("starts a missing document at version 1", function()
			local doc = MoveEditorSystem.AppendVersion(nil, entry(1), 10)
			expect(#doc.Versions).to.equal(1)
			expect(doc.Versions[1].Version).to.equal(1)
			expect(doc.Versions[1].Record.Damage).to.equal(1)
			expect(doc.Versions[1].AdminName).to.equal("Spec")
		end)

		it("numbers each version one past the highest kept, newest last", function()
			local doc: any = nil
			for tag = 1, 3 do
				doc = MoveEditorSystem.AppendVersion(doc, entry(tag), 10)
			end
			expect(doc.Versions[3].Version).to.equal(3)
			expect(doc.Versions[3].Record.Damage).to.equal(3)
		end)

		it("trims the oldest past its depth, and keeps counting up", function()
			local doc: any = nil
			for tag = 1, 7 do
				doc = MoveEditorSystem.AppendVersion(doc, entry(tag), 3)
			end
			expect(#doc.Versions).to.equal(3)
			expect(doc.Versions[1].Version).to.equal(5)
			expect(doc.Versions[3].Version).to.equal(7)
		end)

		it("survives a corrupt document, dropping only the entries it cannot read", function()
			expect(MoveEditorSystem.AppendVersion("junk", entry(1), 10).Versions[1].Version).to.equal(1)
			expect(MoveEditorSystem.AppendVersion({ Versions = "junk" }, entry(1), 10).Versions[1].Version).to.equal(1)
			local mixed = {
				Versions = { { Version = 4, Record = {} }, "junk", { Version = "five", Record = {} }, { Version = 6 } },
			}
			local doc = MoveEditorSystem.AppendVersion(mixed, entry(9), 10)
			expect(#doc.Versions).to.equal(2)
			expect(doc.Versions[2].Version).to.equal(5)
		end)

		it("does not mutate the document it was handed", function()
			local original =
				{ Versions = { { Version = 1, SavedAt = 1, AdminName = "A", AdminUserId = 1, Record = {} } } }
			MoveEditorSystem.AppendVersion(original, entry(2), 10)
			expect(#original.Versions).to.equal(1)
		end)
	end)

	describe("MoveEditorSystem.SummarizeChange", function()
		local base = {
			MoveId = "m",
			Author = "A",
			UpdatedAt = 1,
			WindupSeconds = 0.3,
			Damage = 10,
			Shape = "Box",
			Dimensions = { Width = 4, Height = 5 },
		}

		it("names what changed, old to new, in a stable order", function()
			local after = table.clone(base)
			after.WindupSeconds = 0.26
			after.Damage = 12
			expect(MoveEditorSystem.SummarizeChange(base, after)).to.equal("Damage 10->12, WindupSeconds 0.30->0.26")
		end)

		it("reaches into nested blocks and ignores identity stamps", function()
			local after = table.clone(base)
			after.Dimensions = { Width = 6, Height = 5 }
			after.Author = "B"
			after.UpdatedAt = 99
			expect(MoveEditorSystem.SummarizeChange(base, after)).to.equal("Dimensions.Width 4->6")
		end)

		it("says so when a block is added", function()
			local after = table.clone(base)
			after.Knockback = { UpVelocity = 20 }
			expect(MoveEditorSystem.SummarizeChange(base, after)).to.equal("Knockback.UpVelocity none->20")
		end)

		it("caps the list and counts the rest", function()
			local after = {
				WindupSeconds = 1,
				Damage = 1,
				Shape = "Sphere",
				Dimensions = { Width = 1, Height = 1 },
				Cooldown = 3,
			}
			local summary = MoveEditorSystem.SummarizeChange(base, after)
			expect(string.find(summary, "+2 more", 1, true) ~= nil).to.equal(true)
		end)

		it("describes the oldest kept version and an unchanged re-save", function()
			expect(MoveEditorSystem.SummarizeChange(nil, base)).to.equal("The oldest version kept.")
			expect(MoveEditorSystem.SummarizeChange(base, table.clone(base))).to.equal(
				"No authored change (saved again as it was)."
			)
		end)
	end)
end
