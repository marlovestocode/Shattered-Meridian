--!strict
-- Covers Shared/Blimp/BlimpSpeedLadder.lua -- the engine telegraph's own rules.
--
-- Two kinds of assertion live here and they are deliberately different in character. The SHAPE tests
-- read the live BlimpConstants.SpeedStates and assert invariants that must hold for any ladder anyone
-- ever authors (a neutral rung exists, throttles are ordered, the ends saturate) -- those are the ones
-- that must survive a retune. The one VALUE test pins the ladder's ends to -1 and 1, because a ladder
-- whose extremes are not full astern and full ahead means BlimpConstants.Drive's own ReverseSpeed and
-- CruiseSpeed have stopped being reachable at all, which is a mistuning rather than a retune.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BlimpConstants = require(ReplicatedStorage.Shared.Blimp.BlimpConstants)
local BlimpSpeedLadder = require(ReplicatedStorage.Shared.Blimp.BlimpSpeedLadder)

return function()
	describe("the shipped ladder", function()
		it("has at least one rung either side of neutral", function()
			-- A ladder with no astern rung cannot back out of a mooring, and one with no ahead rung is
			-- not a vehicle. Both are silent failures at runtime -- the key simply does nothing.
			local neutral = BlimpSpeedLadder.NeutralIndex()
			expect(neutral > 1).to.equal(true)
			expect(neutral < BlimpSpeedLadder.Count()).to.equal(true)
		end)

		it("puts neutral on the rung whose throttle is actually zero", function()
			expect(BlimpSpeedLadder.ThrottleAt(BlimpSpeedLadder.NeutralIndex())).to.equal(0)
		end)

		it("orders its throttles strictly astern to ahead", function()
			-- Not merely tidy: the gauge draws rungs left to right in array order and the needle maps a
			-- signed speed fraction onto that same track, so an out-of-order rung produces a needle
			-- that walks backwards through it.
			for index = 2, BlimpSpeedLadder.Count() do
				local previous = BlimpSpeedLadder.ThrottleAt(index - 1)
				local current = BlimpSpeedLadder.ThrottleAt(index)
				expect(current > previous).to.equal(true)
			end
		end)

		it("reaches full astern and full ahead at its two ends", function()
			expect(BlimpSpeedLadder.ThrottleAt(1)).to.equal(-1)
			expect(BlimpSpeedLadder.ThrottleAt(BlimpSpeedLadder.Count())).to.equal(1)
		end)

		it("gives every rung a distinct id and a label", function()
			local seen: { [string]: boolean } = {}
			for index = 1, BlimpSpeedLadder.Count() do
				local rung = BlimpSpeedLadder.At(index)
				expect(seen[rung.Id]).to.never.be.ok()
				seen[rung.Id] = true
				expect(#rung.Label > 0).to.equal(true)
			end
		end)
	end)

	describe("Clamp", function()
		it("bounds either end into the real ladder", function()
			expect(BlimpSpeedLadder.Clamp(0)).to.equal(1)
			expect(BlimpSpeedLadder.Clamp(-50)).to.equal(1)
			expect(BlimpSpeedLadder.Clamp(BlimpSpeedLadder.Count() + 9)).to.equal(BlimpSpeedLadder.Count())
		end)

		it("floors a fractional index", function()
			expect(BlimpSpeedLadder.Clamp(2.9)).to.equal(2)
		end)

		it("resolves NaN to neutral rather than propagating it", function()
			-- math.clamp passes NaN straight through, which would index the array with nil and take the
			-- whole flight tick down. Reachable from arithmetic on a malformed remote payload.
			expect(BlimpSpeedLadder.Clamp(0 / 0)).to.equal(BlimpSpeedLadder.NeutralIndex())
		end)
	end)

	describe("Shift", function()
		it("moves one rung at a time", function()
			local neutral = BlimpSpeedLadder.NeutralIndex()
			expect(BlimpSpeedLadder.Shift(neutral, 1)).to.equal(neutral + 1)
			expect(BlimpSpeedLadder.Shift(neutral, -1)).to.equal(neutral - 1)
		end)

		it("saturates at the top rather than wrapping to full astern", function()
			-- The whole reason Shift saturates: a pilot tapping up past flank must not land on full
			-- astern, which on a loaded hull over a mountain is not a UI annoyance.
			local top = BlimpSpeedLadder.Count()
			expect(BlimpSpeedLadder.Shift(top, 1)).to.equal(top)
			expect(BlimpSpeedLadder.Shift(top, 5)).to.equal(top)
		end)

		it("saturates at the bottom", function()
			expect(BlimpSpeedLadder.Shift(1, -1)).to.equal(1)
		end)

		it("treats a zero delta as All Stop from anywhere", function()
			expect(BlimpSpeedLadder.Shift(1, 0)).to.equal(BlimpSpeedLadder.NeutralIndex())
			expect(BlimpSpeedLadder.Shift(BlimpSpeedLadder.Count(), 0)).to.equal(BlimpSpeedLadder.NeutralIndex())
		end)
	end)

	describe("SanitizeDelta", function()
		it("accepts the three real presses", function()
			expect(BlimpSpeedLadder.SanitizeDelta(1)).to.equal(1)
			expect(BlimpSpeedLadder.SanitizeDelta(-1)).to.equal(-1)
			expect(BlimpSpeedLadder.SanitizeDelta(0)).to.equal(0)
		end)

		it("clamps a batched or dishonest jump down to one rung", function()
			expect(BlimpSpeedLadder.SanitizeDelta(7)).to.equal(1)
			expect(BlimpSpeedLadder.SanitizeDelta(-7)).to.equal(-1)
		end)

		it("rejects a non-number and a non-finite number", function()
			-- nil rather than 0, because 0 is a meaningful value here (All Stop) and cannot double as
			-- the failure signal.
			expect(BlimpSpeedLadder.SanitizeDelta("up")).to.never.be.ok()
			expect(BlimpSpeedLadder.SanitizeDelta(nil)).to.never.be.ok()
			expect(BlimpSpeedLadder.SanitizeDelta(0 / 0)).to.never.be.ok()
			expect(BlimpSpeedLadder.SanitizeDelta(math.huge)).to.never.be.ok()
		end)
	end)

	describe("agreement with the constants table", function()
		it("reports the same rung count the gauge will draw", function()
			-- Client/UI/Components/SpeedLadder.lua sizes each block as 1/Count of the track. If these
			-- two ever disagreed the gauge would draw a ladder the server does not believe in.
			expect(BlimpSpeedLadder.Count()).to.equal(#BlimpConstants.SpeedStates)
		end)
	end)
end
