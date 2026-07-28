--!strict
local ServerScriptService = game:GetService("ServerScriptService")

local BugReportSystem = require(ServerScriptService.Server.Systems.BugReportSystem) :: any

-- Pure-logic surface only -- ComputeOpenCountDelta never touches the DataStore (Submit/UpdateStatus,
-- and the Init()-time seedOpenReportCount pass, all do -- Studio/live-server verification only per
-- this codebase's own headless-harness caveat, see reference_headless_test_workflow). Requiring this
-- module never calls BugReportSystem.Init(), so openReportCount stays at its freshly-required
-- default of 0 throughout this file, which is exactly the default GetOpenCount is exercised against.

return function()
	describe("BugReportSystem.GetOpenCount", function()
		it("defaults to 0 before Init() ever seeds it", function()
			expect(BugReportSystem.GetOpenCount()).to.equal(0)
		end)
	end)

	describe("BugReportSystem.ComputeOpenCountDelta", function()
		it("returns 0 for a same-status transition", function()
			expect(BugReportSystem.ComputeOpenCountDelta("Open", "Open")).to.equal(0)
			expect(BugReportSystem.ComputeOpenCountDelta("Resolved", "Resolved")).to.equal(0)
			expect(BugReportSystem.ComputeOpenCountDelta("Dismissed", "Dismissed")).to.equal(0)
		end)

		it("returns -1 when an Open report transitions away from Open", function()
			expect(BugReportSystem.ComputeOpenCountDelta("Open", "Resolved")).to.equal(-1)
			expect(BugReportSystem.ComputeOpenCountDelta("Open", "Dismissed")).to.equal(-1)
		end)

		it("returns +1 when a non-Open report transitions back to Open", function()
			expect(BugReportSystem.ComputeOpenCountDelta("Resolved", "Open")).to.equal(1)
			expect(BugReportSystem.ComputeOpenCountDelta("Dismissed", "Open")).to.equal(1)
		end)

		it("returns 0 for a transition between two non-Open statuses", function()
			expect(BugReportSystem.ComputeOpenCountDelta("Resolved", "Dismissed")).to.equal(0)
			expect(BugReportSystem.ComputeOpenCountDelta("Dismissed", "Resolved")).to.equal(0)
		end)
	end)
end
