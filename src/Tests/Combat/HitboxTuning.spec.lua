--!strict
local ServerScriptService = game:GetService("ServerScriptService")

local HitboxTuning = require(ServerScriptService.Server.Combat.HitboxTuning) :: any
local LiveTuningContract = require(ServerScriptService.Tests.TestHelpers.LiveTuningContract)

-- HitboxTuning mutates the REAL, shared Constants.Combat.Weapons tables (that is the whole point
-- of this module -- see its own header) -- and TestEZ runs every spec file in one Lua VM/session,
-- so a leaked mutation here would silently change combat behavior for any other spec that happens
-- to read the same stage afterward. Every test that mutates something resets it back inline before
-- returning, rather than relying on an afterEach hook, so this stays correct regardless of hook
-- support/ordering -- see TestHelpers/LiveTuningContract.lua's own header for the shared
-- "mutate+assert, then guarantee the reset still runs" wrapper this file's AdjustField tests use.

return function()
	describe("HitboxTuning.ListStages", function()
		it("returns at least one Basic stage and exactly one Finisher per weapon", function()
			local stages = HitboxTuning.ListStages()
			local counts: { [string]: number } = {}
			for _, info in ipairs(stages) do
				local key = info.WeaponId .. ":" .. info.Category
				counts[key] = (counts[key] or 0) + 1
			end
			expect(counts["Primary:Basic"]).to.be.ok()
			expect(counts["Primary:Basic"] > 0).to.equal(true)
			expect(counts["Secondary:Basic"]).to.be.ok()
			expect(counts["Secondary:Basic"] > 0).to.equal(true)
			expect(counts["Primary:Finisher"]).to.equal(1)
			expect(counts["Secondary:Finisher"]).to.equal(1)
		end)

		it("every stage reports positive timing fields", function()
			for _, info in ipairs(HitboxTuning.ListStages()) do
				expect(info.WindupSeconds > 0).to.equal(true)
				expect(info.ActiveSeconds > 0).to.equal(true)
				expect(info.RecoverySeconds > 0).to.equal(true)
			end
		end)
	end)

	describe("HitboxTuning.AdjustField", function()
		it("mutates the live stage and returns the updated value", function()
			local before = HitboxTuning.ListStages()
			local originalWindup: number? = nil
			for _, info in ipairs(before) do
				if info.WeaponId == "Primary" and info.Category == "Basic" and info.StageIndex == 1 then
					originalWindup = info.WindupSeconds
				end
			end
			expect(originalWindup).to.be.ok()
			local baseline = originalWindup :: number

			LiveTuningContract.withRestore(function()
				local result = HitboxTuning.AdjustField("Primary", "Basic", 1, "WindupSeconds", 0.05)
				expect(result).to.be.ok()
				-- Same floating-point operands/order as the module's own `current + delta`, so this
				-- is bit-identical, not merely close -- no fuzzy-match matcher needed.
				expect(result.WindupSeconds).to.equal(baseline + 0.05)
			end, function()
				HitboxTuning.ResetStage("Primary", "Basic", 1)
			end)
		end)

		it("persists the mutation for a later ListStages call (proves the live-reference claim)", function()
			LiveTuningContract.withRestore(function()
				HitboxTuning.AdjustField("Primary", "Basic", 1, "ActiveSeconds", 0.2)
				local after = HitboxTuning.ListStages()
				local found = false
				for _, info in ipairs(after) do
					if info.WeaponId == "Primary" and info.Category == "Basic" and info.StageIndex == 1 then
						found = true
						expect(info.ActiveSeconds >= 0.2).to.equal(true)
					end
				end
				expect(found).to.equal(true)
			end, function()
				HitboxTuning.ResetStage("Primary", "Basic", 1)
			end)
		end)

		it("clamps a huge negative delta to the sanity floor instead of zero/negative", function()
			LiveTuningContract.withRestore(function()
				local result = HitboxTuning.AdjustField("Primary", "Basic", 1, "WindupSeconds", -999)
				expect(result).to.be.ok()
				expect(result.WindupSeconds).to.equal(0.01)
			end, function()
				HitboxTuning.ResetStage("Primary", "Basic", 1)
			end)
		end)

		it("clamps a huge positive delta to the sanity ceiling instead of an unbounded stall", function()
			LiveTuningContract.withRestore(function()
				local result = HitboxTuning.AdjustField("Primary", "Basic", 1, "WindupSeconds", 999)
				expect(result).to.be.ok()
				expect(result.WindupSeconds).to.equal(5)
			end, function()
				HitboxTuning.ResetStage("Primary", "Basic", 1)
			end)
		end)

		it("returns nil for an out-of-range Basic stage index", function()
			expect(HitboxTuning.AdjustField("Primary", "Basic", 999, "WindupSeconds", 0.01)).to.equal(nil)
		end)

		it("returns nil for a non-zero Finisher stage index (Finisher is a single stage, not an array)", function()
			expect(HitboxTuning.AdjustField("Primary", "Finisher", 1, "WindupSeconds", 0.01)).to.equal(nil)
		end)

		it("adjusts the Finisher stage at its own sentinel index 0", function()
			LiveTuningContract.withRestore(function()
				local result = HitboxTuning.AdjustField("Primary", "Finisher", 0, "RecoverySeconds", 0.01)
				expect(result).to.be.ok()
				expect(result.Category).to.equal("Finisher")
			end, function()
				HitboxTuning.ResetStage("Primary", "Finisher", 0)
			end)
		end)
	end)

	describe("HitboxTuning.ResetStage", function()
		it("restores the captured file default after a mutation", function()
			local before = HitboxTuning.ListStages()
			local original: number? = nil
			for _, info in ipairs(before) do
				if info.WeaponId == "Primary" and info.Category == "Basic" and info.StageIndex == 2 then
					original = info.WindupSeconds
				end
			end
			expect(original).to.be.ok()

			HitboxTuning.AdjustField("Primary", "Basic", 2, "WindupSeconds", 1)
			local restored = HitboxTuning.ResetStage("Primary", "Basic", 2)
			expect(restored).to.be.ok()
			expect(restored.WindupSeconds).to.equal(original)
		end)

		it("returns nil for an invalid stage reference", function()
			expect(HitboxTuning.ResetStage("Primary", "Basic", 999)).to.equal(nil)
		end)
	end)
end
