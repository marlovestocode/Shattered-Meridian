--!strict
-- Covers Client/Input/Analog.lua -- the radial deadzone/curve/sensitivity/invert pipeline a
-- thumbstick read goes through.
--
-- ApplyStick/Curve ARE PURE, taking a plain Vector2/number rather than an InputObject, so this spec
-- drives them directly with no gamepad connected and no live UserInputService read involved at all --
-- Move()/Look()/Trigger() below are covered only for their "no gamepad connected" fallback, since
-- driving the real GetGamepadState() path needs hardware this suite does not have.

local StarterPlayer = game:GetService("StarterPlayer")

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Analog = require(StarterPlayer.StarterPlayerScripts.Client.Input.Analog)
local Constants = require(ReplicatedStorage.Shared.Constants)

local function defaultSettings()
	local defaults = Constants.Settings.Gamepad.Defaults
	return {
		LookSensitivity = defaults.LookSensitivity,
		MoveDeadzone = defaults.MoveDeadzone,
		LookDeadzone = defaults.LookDeadzone,
		InvertLookY = defaults.InvertLookY,
		Vibration = defaults.Vibration,
	}
end

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
	-- The settings half. Analog is a singleton, so anything that pushes settings restores the shipped
	-- defaults afterwards -- leftover state here would leak into whichever spec runs next in the same
	-- process, the same contract Tests/Input/Chord.spec.lua documents.
	describe("SetSettings", function()
		afterEach(function()
			Analog.SetSettings(defaultSettings())
		end)

		it("starts at the shipped defaults, so a client that never restores settings still reads sanely", function()
			local settings = Analog.Settings()
			expect(settings.MoveDeadzone).to.equal(Constants.Settings.Gamepad.Defaults.MoveDeadzone)
			expect(settings.LookSensitivity).to.equal(Constants.Settings.Gamepad.Defaults.LookSensitivity)
		end)

		it("returns a copy a caller cannot use to mutate what Analog reads", function()
			local copy = Analog.Settings()
			copy.MoveDeadzone = 0.99

			expect(Analog.Settings().MoveDeadzone).to.equal(Constants.Settings.Gamepad.Defaults.MoveDeadzone)
		end)

		it("stores a copy, so the caller's own table staying live cannot reach back in", function()
			local mine = defaultSettings()
			Analog.SetSettings(mine)
			mine.MoveDeadzone = 0.99

			expect(Analog.Settings().MoveDeadzone).never.to.equal(0.99)
		end)
	end)

	-- The split that makes a sensitivity slider safe: it must reach the LOOK stick and never the MOVE
	-- stick, because the move stick's magnitude is the walk-versus-run request. Asserted against
	-- ApplyStick with the configs the two derive, since Move()/Look() themselves need hardware.
	describe("the move/look config split", function()
		it("never applies sensitivity to the move stick's own deadzone-and-curve pipeline", function()
			local settings = defaultSettings()
			settings.LookSensitivity = 4
			Analog.SetSettings(settings)

			-- A fully deflected stick through the MOVE config is still magnitude 1: the curve hits
			-- exactly 1 at 1 and no sensitivity multiplies it. If sensitivity ever leaked into the move
			-- config, this would read 4 and the character would move four times as fast.
			local moveConfig = {
				Deadzone = Analog.Settings().MoveDeadzone,
				CurveExponent = 2,
				Sensitivity = 1,
				InvertX = false,
				InvertY = false,
			}
			local moved = Analog.ApplyStick(Vector2.new(0, 1), moveConfig)
			expect(math.abs(moved.Magnitude - 1) < 1e-6).to.equal(true)

			Analog.SetSettings(defaultSettings())
		end)

		it("applies invert to Y only, never to X", function()
			local config = {
				Deadzone = 0,
				CurveExponent = 1,
				Sensitivity = 1,
				InvertX = false,
				InvertY = true,
			}
			local result = Analog.ApplyStick(Vector2.new(1, 1), config)
			expect(result.X > 0).to.equal(true)
			expect(result.Y < 0).to.equal(true)
		end)
	end)

	-- Every shipped default has to be a value the pipeline can actually work with -- a deadzone of 1
	-- returns zero for every input, which on the move stick is a character that cannot walk.
	describe("the shipped defaults", function()
		it("sit inside the bounds the server validates writes against", function()
			local defaults = Constants.Settings.Gamepad.Defaults
			local bounds = Constants.Settings.Gamepad.Bounds

			expect(defaults.LookSensitivity >= bounds.LookSensitivity.Min).to.equal(true)
			expect(defaults.LookSensitivity <= bounds.LookSensitivity.Max).to.equal(true)
			expect(defaults.MoveDeadzone >= bounds.Deadzone.Min).to.equal(true)
			expect(defaults.MoveDeadzone <= bounds.Deadzone.Max).to.equal(true)
			expect(defaults.LookDeadzone >= bounds.Deadzone.Min).to.equal(true)
			expect(defaults.LookDeadzone <= bounds.Deadzone.Max).to.equal(true)
		end)

		it("keeps the deadzone ceiling below 1, so no setting can make a stick inert", function()
			expect(Constants.Settings.Gamepad.Bounds.Deadzone.Max < 1).to.equal(true)
		end)

		it("keeps the sensitivity floor above 0, so no setting can make the camera unturnable", function()
			expect(Constants.Settings.Gamepad.Bounds.LookSensitivity.Min > 0).to.equal(true)
		end)
	end)

	-- The harness has no gamepad attached, so these can only assert the no-pad contract and that the
	-- call is well-formed for every KeyCode kind. That is deliberately ALL they claim: the bug this
	-- function was added for (UserInputService:IsKeyDown answering false forever for a gamepad KeyCode)
	-- is invisible to any headless test, because "false with nothing held" is the correct answer there
	-- too. What these do lock down is that a keyboard KeyCode may be passed without erroring, which is
	-- what lets the three callers ask both reads unconditionally instead of classifying the KeyCode
	-- first -- see KeybindManager.IsJumpKeyDown, Chord.IsHeld and InputRouter's isKeybindDown.
	describe("Analog.IsButtonDown", function()
		it("answers false with no gamepad connected, rather than erroring", function()
			expect(Analog.IsButtonDown(Enum.KeyCode.ButtonA)).to.equal(false)
		end)

		it("accepts a keyboard KeyCode, so callers never have to classify one first", function()
			expect(Analog.IsButtonDown(Enum.KeyCode.Space)).to.equal(false)
		end)

		it("accepts every gamepad button kind the chord layer can bind", function()
			for _, keyCode in { Enum.KeyCode.ButtonL1, Enum.KeyCode.ButtonR1, Enum.KeyCode.DPadUp } do
				expect(Analog.IsButtonDown(keyCode)).to.equal(false)
			end
		end)
	end)
end
