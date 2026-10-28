--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FlightMath = require(ReplicatedStorage.Shared.FlightMath)

-- FlightMath is pure (no Instance/Constants dependency -- see its own header), so every test here
-- is a plain math assertion, no fixture/reset discipline needed (unlike HitboxTuning.spec.lua/
-- FlightTuning.spec.lua, which mutate real shared Constants tables).

local function near(actual: number, expected: number, epsilon: number?): boolean
	return math.abs(actual - expected) < (epsilon or 1e-6)
end

return function()
	describe("FlightMath.ComputeNextVelocity", function()
		it("accelerates toward the target direction, clamped by the per-frame max step", function()
			local result = FlightMath.ComputeNextVelocity(Vector3.zero, Vector3.new(1, 0, 0), 10, 5, 5, 1)
			-- gap=10, maxStep=acceleration*deltaTime=5 -- doesn't reach the target this frame.
			expect(near(result.X, 5)).to.equal(true)
			expect(near(result.Y, 0)).to.equal(true)
			expect(near(result.Z, 0)).to.equal(true)
		end)

		it("never overshoots the target even with a large deltaTime (e.g. a lag spike)", function()
			local result = FlightMath.ComputeNextVelocity(Vector3.zero, Vector3.new(1, 0, 0), 10, 100, 100, 1)
			expect(near(result.X, 10)).to.equal(true)
		end)

		it("normalizes a non-unit desiredDirection before scaling by maxSpeed", function()
			local result = FlightMath.ComputeNextVelocity(Vector3.zero, Vector3.new(2, 0, 0), 10, 1000, 1000, 1)
			-- Vector3.new(2,0,0) and Vector3.new(1,0,0) must produce the SAME target once normalized.
			expect(near(result.X, 10)).to.equal(true)
		end)

		it("decelerates toward zero when desiredDirection is (near-)zero", function()
			local result = FlightMath.ComputeNextVelocity(Vector3.new(10, 0, 0), Vector3.zero, 10, 5, 5, 1)
			expect(near(result.X, 5)).to.equal(true)
		end)

		it("treats a desiredDirection below the near-zero threshold as no direction", function()
			local result = FlightMath.ComputeNextVelocity(Vector3.new(10, 0, 0), Vector3.new(1e-5, 0, 0), 10, 5, 5, 1)
			expect(near(result.X, 5)).to.equal(true)
		end)

		it("integrates each axis independently", function()
			local result = FlightMath.ComputeNextVelocity(Vector3.new(0, 5, 0), Vector3.new(1, 0, 0), 10, 5, 5, 1)
			expect(near(result.X, 5)).to.equal(true)
			-- Y has no target contribution from desiredDirection's flat X-only input -- decelerates
			-- toward zero at the same rate.
			expect(near(result.Y, 0)).to.equal(true)
		end)
	end)

	describe("FlightMath.ComputeBankAngle", function()
		it("scales turn rate by sensitivity before clamping", function()
			local maxBank = math.rad(35)
			local result = FlightMath.ComputeBankAngle(0.1, maxBank, 2.5)
			expect(near(result, 0.25)).to.equal(true)
		end)

		it("clamps a large positive turn rate to +maxBankRadians", function()
			local maxBank = math.rad(35)
			local result = FlightMath.ComputeBankAngle(100, maxBank, 2.5)
			expect(near(result, maxBank)).to.equal(true)
		end)

		it("clamps a large negative turn rate to -maxBankRadians", function()
			local maxBank = math.rad(35)
			local result = FlightMath.ComputeBankAngle(-100, maxBank, 2.5)
			expect(near(result, -maxBank)).to.equal(true)
		end)

		it("returns zero for zero turn rate", function()
			expect(FlightMath.ComputeBankAngle(0, math.rad(35), 2.5)).to.equal(0)
		end)
	end)

	describe("FlightMath.ComputeHoverBobOffset", function()
		it("is zero at clock time zero regardless of amplitude", function()
			expect(FlightMath.ComputeHoverBobOffset(0, 0.35, 2.2)).to.equal(0)
		end)

		it("reaches peak amplitude at a quarter period", function()
			local amplitude = 0.35
			local period = 2.2
			local result = FlightMath.ComputeHoverBobOffset(period / 4, amplitude, period)
			expect(near(result, amplitude, 1e-4)).to.equal(true)
		end)

		it("returns zero for a non-positive period instead of dividing by zero", function()
			expect(FlightMath.ComputeHoverBobOffset(1, 0.35, 0)).to.equal(0)
			expect(FlightMath.ComputeHoverBobOffset(1, 0.35, -1)).to.equal(0)
		end)
	end)

	describe("FlightMath.EaseAlpha", function()
		it("is zero for zero deltaTime regardless of rate (no progress with no elapsed time)", function()
			expect(FlightMath.EaseAlpha(5, 0)).to.equal(0)
		end)

		it("approaches 1 asymptotically but never reaches it for a finite rate/deltaTime", function()
			local alpha = FlightMath.EaseAlpha(5, 1)
			expect(alpha > 0 and alpha < 1).to.equal(true)
		end)

		it("matches the closed-form 1 - e^(-rate*dt) exactly", function()
			local rate, dt = 3, 0.5
			expect(near(FlightMath.EaseAlpha(rate, dt), 1 - math.exp(-rate * dt))).to.equal(true)
		end)

		it("is zero for a zero rate (never eases, matching an ease-disabled slot)", function()
			expect(FlightMath.EaseAlpha(0, 1)).to.equal(0)
		end)
	end)

	describe("FlightMath.YawFromFlatDirection", function()
		it("returns nil for a near-zero flattened direction (straight up/down)", function()
			expect(FlightMath.YawFromFlatDirection(Vector3.new(0, 1, 0))).to.equal(nil)
		end)

		it("returns 0 for a direction pointing along -Z (Roblox's default forward)", function()
			local yaw = FlightMath.YawFromFlatDirection(Vector3.new(0, 0, -1))
			expect(yaw ~= nil).to.equal(true)
			expect(near(yaw :: number, 0)).to.equal(true)
		end)

		it(
			"returns -pi/2 for a direction pointing along +X (matches CFrame.Angles(0, yaw, 0)'s LookVector = (-sin(yaw), 0, -cos(yaw)) convention)",
			function()
				local yaw = FlightMath.YawFromFlatDirection(Vector3.new(1, 0, 0))
				expect(yaw ~= nil).to.equal(true)
				expect(near(yaw :: number, -math.pi / 2)).to.equal(true)
			end
		)

		it(
			"ignores the Y component -- a tilted-but-non-vertical direction yaws the same as its flattened XZ",
			function()
				local flat = FlightMath.YawFromFlatDirection(Vector3.new(1, 0, 0))
				local tilted = FlightMath.YawFromFlatDirection(Vector3.new(1, 5, 0))
				expect(flat ~= nil and tilted ~= nil).to.equal(true)
				expect(near(flat :: number, tilted :: number)).to.equal(true)
			end
		)
	end)

	describe("FlightMath.SpringAdvance", function()
		it("settles on its target", function()
			local value, velocity = 0, 0
			for _ = 1, 240 do
				value, velocity = FlightMath.SpringAdvance(value, velocity, 1, 10, 0.8, 1 / 60)
			end
			expect(value).to.be.near(1, 1e-3)
			expect(math.abs(velocity) < 1e-3).to.equal(true)
		end)

		it("gives the same curve at 30, 60, 144 and 240 fps", function()
			-- A sixth of a second is a whole number of frames at all four rates.
			local function valueAfter(fps: number): number
				local value, velocity = 0, 0
				for _ = 1, fps / 6 do
					value, velocity = FlightMath.SpringAdvance(value, velocity, 1, 10, 0.8, 1 / fps)
				end
				return value
			end
			local reference = valueAfter(240)
			for _, fps in { 30, 60, 144 } do
				expect(math.abs(valueAfter(fps) - reference) < 0.04).to.equal(true)
			end
		end)

		it("stays finite across a frame that took a full second", function()
			local value, velocity = FlightMath.SpringAdvance(0, 5, 1, 13, 0.55, 1)
			expect(math.abs(value) < 10).to.equal(true)
			expect(math.abs(velocity) < 100).to.equal(true)
		end)
	end)

	describe("FlightMath.SpringPeakFactor", function()
		it("predicts the peak of a spring kicked from rest", function()
			for _, damping in { 0.4, 0.55, 0.8, 1, 1.5 } do
				local factor = FlightMath.SpringPeakFactor(13, damping)
				local value, velocity, peak = 0, 2, 0
				for _ = 1, 480 do
					value, velocity = FlightMath.SpringAdvance(value, velocity, 0, 13, damping, 1 / 240)
					peak = math.max(peak, value)
				end
				-- Implicit Euler damps a little more than the analytic spring; within a tenth is the same landing.
				expect(math.abs(peak / 2 - factor) / factor < 0.1).to.equal(true)
			end
		end)
	end)
end
