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

	describe("WheelSelection.CursorFromStick", function()
		-- The gamepad half of the wheel. Every assertion here is about the ONE thing this conversion
		-- exists to guarantee: that a stick pushed in a direction resolves to the segment drawn in that
		-- same direction, through the identical GetSelectedIndex the mouse already goes through.
		local CENTER = Vector2.new(400, 300)
		local DEAD_ZONE = 92
		local THRESHOLD = 0.35

		it("returns the centre itself for a stick inside the threshold", function()
			local resting = WheelSelection.CursorFromStick(CENTER, Vector2.new(0.1, 0.2), DEAD_ZONE, THRESHOLD)
			expect(resting).to.equal(CENTER)
			-- Which is exactly what makes 'nothing selected' a real state on a gamepad too.
			expect(WheelSelection.GetSelectedIndex(CENTER, resting, 8, DEAD_ZONE)).to.equal(nil)
		end)

		it("places the cursor outside the dead zone for a stick past the threshold", function()
			local cursor = WheelSelection.CursorFromStick(CENTER, Vector2.new(0, 1), DEAD_ZONE, THRESHOLD)
			expect((cursor - CENTER).Magnitude > DEAD_ZONE).to.equal(true)
		end)

		it("flips the stick's Y so 'stick up' resolves to segment 1, not the segment opposite it", function()
			-- A thumbstick reports +Y as up; screen space has +Y going down. Without the flip this is
			-- segment 5 (straight down at 8 segments) and the whole wheel reads as inverted.
			local cursor = WheelSelection.CursorFromStick(CENTER, Vector2.new(0, 1), DEAD_ZONE, THRESHOLD)
			expect(WheelSelection.GetSelectedIndex(CENTER, cursor, 8, DEAD_ZONE)).to.equal(1)
		end)

		it("resolves right on the stick to the same segment right of centre resolves to", function()
			local cursor = WheelSelection.CursorFromStick(CENTER, Vector2.new(1, 0), DEAD_ZONE, THRESHOLD)
			local mouse = CENTER + Vector2.new(100, 0)
			expect(WheelSelection.GetSelectedIndex(CENTER, cursor, 8, DEAD_ZONE)).to.equal(
				WheelSelection.GetSelectedIndex(CENTER, mouse, 8, DEAD_ZONE)
			)
		end)

		it("agrees with GetSegmentPosition for every segment of the wheel", function()
			-- The round trip that actually matters: push the stick at a drawn segment, get that segment.
			local segmentCount = 8
			for index = 1, segmentCount do
				local drawn = WheelSelection.GetSegmentPosition(index, segmentCount, 1)
				-- GetSegmentPosition is in screen space (+Y down); a stick is +Y up, so it is handed the
				-- same direction with Y flipped back.
				local stick = Vector2.new(drawn.X, -drawn.Y)
				local cursor = WheelSelection.CursorFromStick(CENTER, stick, DEAD_ZONE, THRESHOLD)
				expect(WheelSelection.GetSelectedIndex(CENTER, cursor, segmentCount, DEAD_ZONE)).to.equal(index)
			end
		end)

		it("is unaffected by how hard the stick is pushed, once past the threshold", function()
			local light = WheelSelection.CursorFromStick(CENTER, Vector2.new(0.4, 0.4), DEAD_ZONE, THRESHOLD)
			local hard = WheelSelection.CursorFromStick(CENTER, Vector2.new(1, 1), DEAD_ZONE, THRESHOLD)
			expect(near((light - CENTER).Magnitude, (hard - CENTER).Magnitude)).to.equal(true)
			expect(WheelSelection.GetSelectedIndex(CENTER, light, 8, DEAD_ZONE)).to.equal(
				WheelSelection.GetSelectedIndex(CENTER, hard, 8, DEAD_ZONE)
			)
		end)
	end)
end
