--!strict
-- Covers Shared/Boat/BoatSailLadder.lua -- this layer's binding of Shared/Vessel/VesselSpeedLadder.lua,
-- and the shape of BoatConstants.SailStates itself.
--
-- The BEHAVIOUR of a ladder (saturate rather than wrap, find the neutral rung, reject a malformed delta)
-- is the shared module's and is already pinned by src/Tests/Blimp/BlimpSpeedLadder.spec.lua against the
-- other binding of it. What is asserted here is the part that is this layer's own: that a boat's rig has
-- a furled rung, that its rungs run in order, and that the binding really is live rather than a table
-- somebody forgot to pass.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BoatConstants = require(ReplicatedStorage.Shared.Boat.BoatConstants)
local BoatSailLadder = require(ReplicatedStorage.Shared.Boat.BoatSailLadder)

return function()
	describe("the binding", function()
		it("reads the rungs a builder actually authored", function()
			expect(BoatSailLadder.Count()).to.equal(#BoatConstants.SailStates)
		end)

		it("is a DIFFERENT ladder from the blimp's, which is the whole reason it is a factory", function()
			-- Cheap, and it is the assertion that would have caught a copy-paste binding pointed at
			-- BlimpConstants.SpeedStates -- which would produce a boat whose gauge drew eight engine
			-- orders and whose server furled on a rung nobody could see.
			local BlimpSpeedLadder = require(ReplicatedStorage.Shared.Blimp.BlimpSpeedLadder)
			expect(BoatSailLadder.Count() ~= BlimpSpeedLadder.Count()).to.equal(true)
			expect(BoatSailLadder.At(BoatSailLadder.Count()).Label).to.equal("FULL SAIL")
		end)
	end)

	describe("the rig", function()
		it("has a furled rung, and it is the neutral one", function()
			expect(BoatSailLadder.ThrottleAt(BoatSailLadder.NeutralIndex())).to.equal(0)
			expect(BoatSailLadder.At(BoatSailLadder.NeutralIndex()).Label).to.equal("FURLED")
		end)

		it("has canvas both sides of furled -- backed sails are the escape hatch", function()
			local neutral = BoatSailLadder.NeutralIndex()
			expect(neutral > 1).to.equal(true)
			expect(neutral < BoatSailLadder.Count()).to.equal(true)
		end)

		it("runs strictly in order from backed to full", function()
			for index = 2, BoatSailLadder.Count() do
				expect(BoatSailLadder.ThrottleAt(index) > BoatSailLadder.ThrottleAt(index - 1)).to.equal(true)
			end
		end)

		it("bounds its ends at -1 and 1", function()
			expect(BoatSailLadder.ThrottleAt(1)).to.equal(-1)
			expect(BoatSailLadder.ThrottleAt(BoatSailLadder.Count())).to.equal(1)
		end)

		it("gives every rung an id and a label a gauge can print", function()
			for index = 1, BoatSailLadder.Count() do
				local rung = BoatSailLadder.At(index)
				expect(type(rung.Id)).to.equal("string")
				expect(#rung.Id > 0).to.equal(true)
				expect(type(rung.Label)).to.equal("string")
				expect(#rung.Label > 0).to.equal(true)
			end
		end)

		it("is shorter than the blimp's telegraph, deliberately", function()
			-- A boat's speed is already continuously modulated by the wind and by her heading, so a fine
			-- sail ladder would be a second continuous control shadowing one the player already has. See
			-- BoatConstants.SailStates' own header.
			expect(BoatSailLadder.Count() <= 6).to.equal(true)
		end)
	end)

	describe("Shift", function()
		it("furls her outright on a delta of 0 -- the panic press", function()
			expect(BoatSailLadder.Shift(BoatSailLadder.Count(), 0)).to.equal(BoatSailLadder.NeutralIndex())
			expect(BoatSailLadder.Shift(1, 0)).to.equal(BoatSailLadder.NeutralIndex())
		end)

		it("saturates at full sail rather than wrapping round to backed", function()
			local top = BoatSailLadder.Count()
			expect(BoatSailLadder.Shift(top, 1)).to.equal(top)
			expect(BoatSailLadder.Shift(1, -1)).to.equal(1)
		end)
	end)
end
