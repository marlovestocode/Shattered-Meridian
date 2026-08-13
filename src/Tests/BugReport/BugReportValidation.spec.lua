--!strict
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BugReportSystem = require(ServerScriptService.Server.Systems.BugReportSystem) :: any
local Constants = require(ReplicatedStorage.Shared.Constants)

-- Pure-logic surface only -- ValidateCategory/ValidateDescription/IsValidStatus never touch the
-- DataStore (Submit/ListReports/UpdateStatus do, and are Studio/live-server playtest-only per this
-- codebase's own headless-harness caveat -- see reference_headless_test_workflow). Requiring this
-- module never calls BugReportSystem.Init(), so mainStore/orderedStore stay nil throughout this
-- file, which is exactly why none of these three functions may depend on either.

return function()
	describe("BugReportSystem.ValidateCategory", function()
		for _, category in ipairs(Constants.BugReport.Categories) do
			it(`accepts the known category "{category}"`, function()
				expect(BugReportSystem.ValidateCategory(category)).to.equal(category)
			end)
		end

		it("rejects an unknown string", function()
			expect(BugReportSystem.ValidateCategory("NotACategory")).to.equal(nil)
		end)

		it("rejects a non-string value", function()
			expect(BugReportSystem.ValidateCategory(42)).to.equal(nil)
			expect(BugReportSystem.ValidateCategory(nil)).to.equal(nil)
			expect(BugReportSystem.ValidateCategory(true)).to.equal(nil)
		end)
	end)

	describe("BugReportSystem.ValidateDescription", function()
		it("rejects a non-string value", function()
			local trimmed, reason = BugReportSystem.ValidateDescription(42)
			expect(trimmed).to.equal(nil)
			expect(reason).to.equal("InvalidType")
		end)

		it("rejects a description shorter than the minimum length", function()
			local tooShort = string.rep("a", Constants.BugReport.DescriptionMinLength - 1)
			local trimmed, reason = BugReportSystem.ValidateDescription(tooShort)
			expect(trimmed).to.equal(nil)
			expect(reason).to.equal("TooShort")
		end)

		it("accepts a description exactly at the minimum length", function()
			local exact = string.rep("a", Constants.BugReport.DescriptionMinLength)
			local trimmed, reason = BugReportSystem.ValidateDescription(exact)
			expect(reason).to.equal(nil)
			expect(trimmed).to.equal(exact)
		end)

		it("rejects a description longer than the maximum length", function()
			local tooLong = string.rep("a", Constants.BugReport.DescriptionMaxLength + 1)
			local trimmed, reason = BugReportSystem.ValidateDescription(tooLong)
			expect(trimmed).to.equal(nil)
			expect(reason).to.equal("TooLong")
		end)

		it("accepts a description exactly at the maximum length", function()
			local exact = string.rep("a", Constants.BugReport.DescriptionMaxLength)
			local trimmed, reason = BugReportSystem.ValidateDescription(exact)
			expect(reason).to.equal(nil)
			expect(trimmed).to.equal(exact)
		end)

		it("trims surrounding whitespace before measuring/returning length", function()
			local padded = "   " .. string.rep("a", Constants.BugReport.DescriptionMinLength) .. "   "
			local trimmed, reason = BugReportSystem.ValidateDescription(padded)
			expect(reason).to.equal(nil)
			expect(trimmed).to.equal(string.rep("a", Constants.BugReport.DescriptionMinLength))
		end)

		it("measures length AFTER trimming (padding alone can't satisfy the minimum)", function()
			local onlyWhitespacePadding = "  " .. string.rep("a", Constants.BugReport.DescriptionMinLength - 1) .. "  "
			local trimmed, reason = BugReportSystem.ValidateDescription(onlyWhitespacePadding)
			expect(trimmed).to.equal(nil)
			expect(reason).to.equal("TooShort")
		end)
	end)

	describe("BugReportSystem.IsValidStatus", function()
		it("accepts every known status", function()
			for _, status in ipairs(Constants.BugReport.Statuses) do
				expect(BugReportSystem.IsValidStatus(status)).to.equal(true)
			end
		end)

		it("rejects an unknown string", function()
			expect(BugReportSystem.IsValidStatus("Closed")).to.equal(false)
		end)

		it("rejects a non-string value", function()
			expect(BugReportSystem.IsValidStatus(1)).to.equal(false)
			expect(BugReportSystem.IsValidStatus(nil)).to.equal(false)
		end)

		-- Documents a deliberate design choice (see BugReportSystem.lua's own header comment on
		-- IsValidStatus): every status may transition to every other status -- an open graph, not a
		-- restricted state machine like CombatSystem's ACTION_GATES. This is the closest thing to
		-- "status transition" coverage available without a live DataStore (UpdateStatus itself is
		-- Studio-only).
		it("has no restricted transition graph -- every known status is independently valid as a target", function()
			for _, _from in ipairs(Constants.BugReport.Statuses) do
				for _, to in ipairs(Constants.BugReport.Statuses) do
					expect(BugReportSystem.IsValidStatus(to)).to.equal(true)
				end
			end
		end)
	end)

	describe("BugReportSystem.IsValidPriority", function()
		it("accepts every known priority", function()
			for _, priority in ipairs(Constants.BugReport.Priorities) do
				expect(BugReportSystem.IsValidPriority(priority)).to.equal(true)
			end
		end)

		it("rejects an unknown string", function()
			expect(BugReportSystem.IsValidPriority("Critical")).to.equal(false)
		end)

		it("rejects a non-string value", function()
			expect(BugReportSystem.IsValidPriority(1)).to.equal(false)
			expect(BugReportSystem.IsValidPriority(nil)).to.equal(false)
		end)
	end)

	describe("BugReportSystem.ComputeOpenCountDelta", function()
		it("treats InProgress the same as Resolved/Dismissed -- any non-Open status", function()
			expect(BugReportSystem.ComputeOpenCountDelta("Open", "InProgress")).to.equal(-1)
			expect(BugReportSystem.ComputeOpenCountDelta("InProgress", "Open")).to.equal(1)
			expect(BugReportSystem.ComputeOpenCountDelta("InProgress", "Resolved")).to.equal(0)
		end)
	end)
end
