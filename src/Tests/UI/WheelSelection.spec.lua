--!strict
local StarterPlayer = game:GetService("StarterPlayer")

local WheelSelection = require(StarterPlayer.StarterPlayerScripts.Client.UI.Screens.EmoteWheel.WheelSelection)

-- WheelSelection is pure (no Instance/Fusion dependency -- see its own header), so every test here
-- is a plain math assertion, the same "no fixture/reset discipline needed" shape FlightMath.spec.lua
-- already establishes for its own pure module.

local function near(actual: number, expected: number, epsilon: number?): boolean
	return math.abs(actual - expected) < (epsilon or 1e-6)
end

return function()
	describe("WheelSelection.GetSelectedIndex", function()
		it("returns nil for a non-positive segment count", function()
			expect(WheelSelection.GetSelectedIndex(Vector2.new(0, 0), Vector2.new(10, 10), 0)).to.equal(nil)
			expect(WheelSelection.GetSelectedIndex(Vector2.new(0, 0), Vector2.new(10, 10), -3)).to.equal(nil)
		end)

		it("returns nil when the cursor sits exactly on center", function()
			local center = Vector2.new(400, 300)
			expect(WheelSelection.GetSelectedIndex(center, center, 8)).to.equal(nil)
		end)

		it("resolves segment 1 ('up') for a cursor directly above center, at 8 segments", function()
			local center = Vector2.new(400, 300)
			local cursor = center + Vector2.new(0, -100)
			expect(WheelSelection.GetSelectedIndex(center, cursor, 8)).to.equal(1)
		end)

		it("resolves clockwise ordering at 8 segments (directly right resolves to segment 3)", function()
			local center = Vector2.new(400, 300)
			local cursor = center + Vector2.new(100, 0)
			expect(WheelSelection.GetSelectedIndex(center, cursor, 8)).to.equal(3)
		end)

		it("resolves segment 1 ('up') at a small segment count (3), proving nothing is hardcoded to 8", function()
			local center = Vector2.new(0, 0)
			local cursor = Vector2.new(0, -50)
			expect(WheelSelection.GetSelectedIndex(center, cursor, 3)).to.equal(1)
		end)

		it("resolves the correct segment at a large segment count (12), proving nothing is hardcoded to 8", function()
			local center = Vector2.new(0, 0)
			local anglePerSegment = (2 * math.pi) / 12
			-- Segment 4 (0-based offset 3) sits 3 sectors clockwise from up.
			local angle = 3 * anglePerSegment
			local cursor = Vector2.new(50 * math.sin(angle), -50 * math.cos(angle))
			expect(WheelSelection.GetSelectedIndex(center, cursor, 12)).to.equal(4)
		end)

		it("wraps a cursor just short of the full turn back to segment 1", function()
			local center = Vector2.new(0, 0)
			local anglePerSegment = (2 * math.pi) / 8
			local angle = (2 * math.pi) - (anglePerSegment * 0.1)
			local cursor = Vector2.new(50 * math.sin(angle), -50 * math.cos(angle))
			expect(WheelSelection.GetSelectedIndex(center, cursor, 8)).to.equal(1)
		end)
	end)

	describe("WheelSelection.GetSegmentPosition", function()
		it("places segment 1 directly above center ('up'), regardless of segment count", function()
			local pos8 = WheelSelection.GetSegmentPosition(1, 8, 100)
			expect(near(pos8.X, 0)).to.equal(true)
			expect(near(pos8.Y, -100)).to.equal(true)

			local pos3 = WheelSelection.GetSegmentPosition(1, 3, 100)
			expect(near(pos3.X, 0)).to.equal(true)
			expect(near(pos3.Y, -100)).to.equal(true)
		end)

		it("places later segments clockwise as index increases, at 12 segments", function()
			local anglePerSegment = (2 * math.pi) / 12
			local pos = WheelSelection.GetSegmentPosition(4, 12, 50)
			local expectedAngle = 3 * anglePerSegment
			expect(near(pos.X, 50 * math.sin(expectedAngle))).to.equal(true)
			expect(near(pos.Y, -50 * math.cos(expectedAngle))).to.equal(true)
		end)

		it("returns zero for a non-positive segment count", function()
			local pos = WheelSelection.GetSegmentPosition(1, 0, 100)
			expect(pos).to.equal(Vector2.zero)
		end)

		it(
			"round-trips with GetSelectedIndex: the placed position for every segment resolves back to that segment",
			function()
				local segmentCount = 8
				for index = 1, segmentCount do
					local position = WheelSelection.GetSegmentPosition(index, segmentCount, 100)
					local resolved = WheelSelection.GetSelectedIndex(Vector2.zero, position, segmentCount)
					expect(resolved).to.equal(index)
				end
			end
		)
	end)
end
