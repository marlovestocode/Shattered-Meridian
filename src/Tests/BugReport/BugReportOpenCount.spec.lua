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

	-- ComputeOpenCountAfterDelta/ResolveMigratedOpenCount are the pure UpdateAsync merge functions
	-- persistOpenCountDelta/seedOpenReportCount's migration path pass straight into UpdateAsync's
	-- callback (see BugReportSystem.lua's own header on OPEN_COUNT_KEY for why a single persisted
	-- counter replaced a full OrderedDataStore page-walk on every server boot). Exercised directly
	-- against plain `old` values here -- exactly what UpdateAsync would hand the real callback -- the
	-- same "requiring this module never calls Init()" no-DataStore contract every other describe block
	-- in this file already relies on.
	describe("BugReportSystem.ComputeOpenCountAfterDelta", function()
		it("adds a positive delta to a never-written key (nil old value)", function()
			expect(BugReportSystem.ComputeOpenCountAfterDelta(nil, 1)).to.equal(1)
		end)

		it("adds a delta on top of an existing persisted count", function()
			expect(BugReportSystem.ComputeOpenCountAfterDelta(5, 1)).to.equal(6)
			expect(BugReportSystem.ComputeOpenCountAfterDelta(5, -1)).to.equal(4)
		end)

		it("clamps at 0 rather than ever going negative", function()
			expect(BugReportSystem.ComputeOpenCountAfterDelta(0, -1)).to.equal(0)
			expect(BugReportSystem.ComputeOpenCountAfterDelta(nil, -1)).to.equal(0)
		end)

		it("treats a corrupt (non-number) persisted value as 0 rather than propagating it", function()
			expect(BugReportSystem.ComputeOpenCountAfterDelta("not a number", 3)).to.equal(3)
			expect(BugReportSystem.ComputeOpenCountAfterDelta({}, 3)).to.equal(3)
		end)
	end)

	describe("BugReportSystem.ResolveMigratedOpenCount", function()
		it("adopts the migration walk's count when nothing was persisted yet", function()
			expect(BugReportSystem.ResolveMigratedOpenCount(nil, 42)).to.equal(42)
		end)

		it("prefers an already-persisted number over the walk's result -- the race-safety case", function()
			-- Another server's migration (or a real Submit/UpdateStatus delta) already landed while
			-- this walk was still running -- must NOT be stomped by this walk's own (possibly stale)
			-- count, or two servers racing the same first-boot migration could disagree forever.
			expect(BugReportSystem.ResolveMigratedOpenCount(7, 42)).to.equal(7)
		end)

		it("treats a corrupt (non-number) persisted value as absent, adopting the walk's count", function()
			expect(BugReportSystem.ResolveMigratedOpenCount("corrupt", 42)).to.equal(42)
		end)
	end)
end
