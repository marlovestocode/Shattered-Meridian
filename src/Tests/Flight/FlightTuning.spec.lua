--!strict
local ServerScriptService = game:GetService("ServerScriptService")

local FlightTuning = require(ServerScriptService.Server.DevMenu.FlightTuning) :: any
local LiveTuningContract = require(ServerScriptService.Tests.TestHelpers.LiveTuningContract)

-- FlightTuning mutates the REAL, shared Constants.Flight table (that is the whole point of this
-- module -- see its own header) -- and TestEZ runs every spec file in one Lua VM/session, so a
-- leaked mutation here would silently change flight feel for any other spec that happens to read
-- Constants.Flight afterward. Every test that mutates something resets it back inline before
-- returning, rather than relying on an afterEach hook, same discipline as HitboxTuning.spec.lua --
-- see TestHelpers/LiveTuningContract.lua's own header for the shared "mutate+assert, then
-- guarantee the reset still runs" wrapper this file's SetField tests use.

return function()
	describe("FlightTuning.ListFields", function()
		it("returns every curated tunable field with a positive value", function()
			local fields = FlightTuning.ListFields()
			expect(#fields > 0).to.equal(true)
			for _, info in ipairs(fields) do
				expect(info.DisplayName ~= "").to.equal(true)
				expect(info.Value > 0).to.equal(true)
			end
		end)

		it("includes CruiseSpeed", function()
			local found = false
			for _, info in ipairs(FlightTuning.ListFields()) do
				if info.Field == "CruiseSpeed" then
					found = true
				end
			end
			expect(found).to.equal(true)
		end)
	end)

	describe("FlightTuning.ListFields bounds", function()
		it("carries each field's clamp and a file default inside it", function()
			for _, info in ipairs(FlightTuning.ListFields()) do
				expect(info.Min < info.Max).to.equal(true)
				expect(info.Default >= info.Min and info.Default <= info.Max).to.equal(true)
			end
		end)
	end)

	describe("FlightTuning.SetField", function()
		it("writes the absolute value and returns it", function()
			LiveTuningContract.withRestore(function()
				local result = FlightTuning.SetField("CruiseSpeed", 120)
				expect(result).to.be.ok()
				expect(result.Value).to.equal(120)
			end, function()
				FlightTuning.ResetField("CruiseSpeed")
			end)
		end)

		it("persists the mutation for a later ListFields call (proves the live-reference claim)", function()
			LiveTuningContract.withRestore(function()
				FlightTuning.SetField("Acceleration", 77)
				local found = false
				for _, info in ipairs(FlightTuning.ListFields()) do
					if info.Field == "Acceleration" then
						found = true
						expect(info.Value).to.equal(77)
					end
				end
				expect(found).to.equal(true)
			end, function()
				FlightTuning.ResetField("Acceleration")
			end)
		end)

		it("clamps to the field's sanity ceiling instead of an unbounded value", function()
			LiveTuningContract.withRestore(function()
				local result = FlightTuning.SetField("MaxBankAngleDegrees", 999)
				expect(result).to.be.ok()
				expect(result.Value).to.equal(89)
			end, function()
				FlightTuning.ResetField("MaxBankAngleDegrees")
			end)
		end)

		it("clamps to the field's sanity floor instead of zero/negative", function()
			LiveTuningContract.withRestore(function()
				local result = FlightTuning.SetField("MaxBankAngleDegrees", -999)
				expect(result).to.be.ok()
				expect(result.Value).to.equal(0)
			end, function()
				FlightTuning.ResetField("MaxBankAngleDegrees")
			end)
		end)

		it("refuses NaN and infinity rather than poisoning the shared table", function()
			expect(FlightTuning.SetField("CruiseSpeed", 0 / 0)).to.equal(nil)
			expect(FlightTuning.SetField("CruiseSpeed", math.huge)).to.equal(nil)
		end)

		it("returns nil for a field name outside the curated set", function()
			expect(FlightTuning.SetField("DefaultCollideMode", 1)).to.equal(nil)
		end)
	end)

	describe("FlightTuning.ResetField", function()
		it("restores the captured file default after a mutation", function()
			local original: number? = nil
			for _, info in ipairs(FlightTuning.ListFields()) do
				if info.Field == "BoostSpeedMultiplier" then
					original = info.Value
				end
			end
			expect(original).to.be.ok()

			FlightTuning.SetField("BoostSpeedMultiplier", 4)
			local restored = FlightTuning.ResetField("BoostSpeedMultiplier")
			expect(restored).to.be.ok()
			expect(restored.Value).to.equal(original)
		end)

		it("returns nil for a field name outside the curated set", function()
			expect(FlightTuning.ResetField("AnimationIds")).to.equal(nil)
		end)
	end)
end
