--!strict
-- Covers Shared/Damage/FeedbackBatch.lua -- the Combat_Feedback wire shape. DamageSystem sends each player one
-- batch per frame; a client must see every entry, in order, and must still accept the old single-payload shape.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FeedbackBatch = require(ReplicatedStorage.Shared.Damage.FeedbackBatch)

local function entry(kind: string, damage: number): any
	return { Kind = kind, Role = "Attacker", Damage = damage, GuardDrain = 0, ComboStage = 1 }
end

return function()
	describe("FeedbackBatch.Unpack", function()
		it("returns a batch's entries in the order they were queued", function()
			local out = FeedbackBatch.Unpack({ entry("Clean", 10), entry("Blocked", 2), entry("Clean", 12) })
			expect(#out).to.equal(3)
			expect(out[1].Damage).to.equal(10)
			expect(out[2].Kind).to.equal("Blocked")
			expect(out[3].Damage).to.equal(12)
		end)

		it("treats a lone pre-batch payload as a batch of one", function()
			local out = FeedbackBatch.Unpack(entry("Clean", 7))
			expect(#out).to.equal(1)
			expect(out[1].Damage).to.equal(7)
		end)

		it("returns nothing for a non-table, and skips non-table entries", function()
			expect(#FeedbackBatch.Unpack(nil)).to.equal(0)
			expect(#FeedbackBatch.Unpack("Clean")).to.equal(0)
			local out = FeedbackBatch.Unpack({ entry("Clean", 1), 5 :: any, entry("Clean", 2) })
			expect(#out).to.equal(2)
		end)
	end)
end
