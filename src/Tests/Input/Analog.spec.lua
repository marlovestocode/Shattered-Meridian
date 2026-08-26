--!strict
-- Covers Client/Input/Analog.lua -- the radial deadzone/curve/sensitivity/invert pipeline a
-- thumbstick read goes through.
--
-- ApplyStick/Curve ARE PURE, taking a plain Vector2/number rather than an InputObject, so this spec
-- drives them directly with no gamepad connected and no live UserInputService read involved at all --
-- Move()/Look()/Trigger() below are covered only for their "no gamepad connected" fallback, since
-- driving the real GetGamepadState() path needs hardware this suite does not have.

local StarterPlayer = game:GetService("StarterPlayer")

local Analog = require(StarterPlayer.StarterPlayerScripts.Client.Input.Analog)

return function()
	describe("Curve", function()
		it("is exactly 0 at input 0 and exactly 1 at input 1", function()
			expect(Analog.Curve(0)).to.equal(0)
			expect(Analog.Curve(1)).to.equal(1)
		end)

		it("is monotonic across the whole input range", function()
			local previous = -1
			for i = 0, 20 do
				local value = Analog.Curve(i / 20)
				expect(value >= previous).to.equal(true)
				previous = value
			end
		end)

		it("honours an explicit exponent", function()
			expect(Analog.Curve(0.5, 3)).to.be.near(0.125, 1e-9)
		end)
	end)

	describe("ApplyStick", function()
		local LINEAR = { Deadzone = 0.2, CurveExponent = 1, Sensitivity = 1, InvertX = false, InvertY = false }

		it("zeroes a centred stick", function()
			expect(Analog.ApplyStick(Vector2.zero, LINEAR)).to.equal(Vector2.zero)
		end)

		it("zeroes input entirely inside the deadzone", function()
			local result = Analog.ApplyStick(Vector2.new(0.1, 0.1), LINEAR)
			expect(result).to.equal(Vector2.zero)
		end)

		it("admits a diagonal at the radial threshold a naive per-axis deadzone would reject", function()
			-- Each axis alone (0.15) is below the 0.2 deadzone a per-axis test would apply
			-- independently to X and Y, but the combined radial magnitude (~0.212) clears it -- the
			-- whole reason this module tests magnitude once instead of two independent axis tests.
			local raw = Vector2.new(0.15, 0.15)
			expect(math.abs(raw.X) < LINEAR.Deadzone).to.equal(true)
			expect(math.abs(raw.Y) < LINEAR.Deadzone).to.equal(true)
			expect(raw.Magnitude > LINEAR.Deadzone).to.equal(true)

			local result = Analog.ApplyStick(raw, LINEAR)
			expect(result.Magnitude > 0).to.equal(true)
		end)

		it("flips only Y when InvertY is set", function()
			local config = { Deadzone = 0, CurveExponent = 1, Sensitivity = 1, InvertX = false, InvertY = true }
			local result = Analog.ApplyStick(Vector2.new(0.5, 0.5), config)
			expect(result.X > 0).to.equal(true)
			expect(result.Y < 0).to.equal(true)
		end)

		it("flips only X when InvertX is set", function()
			local config = { Deadzone = 0, CurveExponent = 1, Sensitivity = 1, InvertX = true, InvertY = false }
			local result = Analog.ApplyStick(Vector2.new(0.5, 0.5), config)
			expect(result.X < 0).to.equal(true)
			expect(result.Y > 0).to.equal(true)
		end)

		it("scales a full deflection by sensitivity", function()
			local config = { Deadzone = 0, CurveExponent = 1, Sensitivity = 2, InvertX = false, InvertY = false }
			local result = Analog.ApplyStick(Vector2.new(1, 0), config)
			expect(result.X).to.be.near(2, 1e-9)
		end)
	end)

	describe("Move/Look/Trigger with no gamepad connected", function()
		it("return the same zero answer a centred, undeadzoned stick would", function()
			expect(Analog.Move()).to.equal(Vector2.zero)
			expect(Analog.Look()).to.equal(Vector2.zero)
		end)

		it("returns 0 for either trigger", function()
			expect(Analog.Trigger("Left")).to.equal(0)
			expect(Analog.Trigger("Right")).to.equal(0)
		end)
	end)
end
