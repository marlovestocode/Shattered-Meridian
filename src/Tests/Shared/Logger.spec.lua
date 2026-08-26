--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Logger = require(ReplicatedStorage.Shared.Logger)
local Constants = require(ReplicatedStorage.Shared.Constants)

-- Logger is a module-level singleton (require() caches it), so its capture buffer/Sequence counter
-- persist across every spec file this whole TestEZ run touches -- these tests never assume the
-- buffer starts empty or Sequence starts at 0. Each scope name below is unique to this file so no
-- other spec's own logging can be mistaken for this file's own entries, and every captured message
-- is unique per call (a literal, or a marker-suffixed string) so Logger's own rate limiter (keyed
-- off the exact scope+level+message triple, MaxRepeatsPerSecond) never silently drops one.
--
-- The capture FLOOR is also process-wide (Logger.SetCaptureLevel), and its idle value is
-- Constants.Debug.Logging.CaptureLevel = "Info". Any test below that logs beneath Info has to raise
-- it and put it back, or it leaks a raised floor into every later spec file in the run.
return function()
	-- Runs `body` with the capture floor at Trace, restoring the idle level afterwards even if the
	-- body throws -- the floor is a module-level singleton shared with every other spec in this run.
	local function withTraceCapture(body: () -> ()): ()
		Logger.SetCaptureLevel("Trace")
		local ok, err = pcall(body)
		Logger.SetCaptureLevel(nil)
		if not ok then
			error(err, 0)
		end
	end

	describe("Logger console capture buffer", function()
		it("captures a call regardless of Enabled/IsStudio/Level/Scope -- unlisted scope, Trace level", function()
			local logger = Logger.scope("LoggerSpecTest_Capture")
			local before = Logger.GetBufferSnapshot()
			local baseline = if #before > 0 then before[#before].Sequence else 0

			-- Enabled/IsStudio/Level/Scope are still all irrelevant to capture, which is what this
			-- test is about. The capture FLOOR is the one gate that is not in that list -- it is what
			-- makes a live server stop paying for debug lines nobody is reading -- so a Trace call
			-- has to raise it first. See Logger.SetCaptureLevel.
			withTraceCapture(function()
				logger:trace("LoggerSpecTest capture marker " .. tostring(os.clock()))
			end)

			local captured = Logger.GetBufferSnapshot(baseline)
			expect(#captured).to.equal(1)
			expect(captured[1].Scope).to.equal("LoggerSpecTest_Capture")
			expect(captured[1].Level).to.equal("Trace")
			expect(captured[1].Source).to.equal("App")
		end)

		it("Sequence increases monotonically and GetBufferSnapshot(since) excludes it and everything older", function()
			local logger = Logger.scope("LoggerSpecTest_Sequence")
			local marker = tostring(os.clock())

			logger:info("LoggerSpecTest sequence first " .. marker)
			local afterFirst = Logger.GetBufferSnapshot()
			local firstSequence = afterFirst[#afterFirst].Sequence

			logger:info("LoggerSpecTest sequence second " .. marker)

			local sinceFirst = Logger.GetBufferSnapshot(firstSequence)
			expect(#sinceFirst).to.equal(1)
			expect(sinceFirst[1].Message).to.equal("LoggerSpecTest sequence second " .. marker)
			expect(sinceFirst[1].Sequence > firstSequence).to.equal(true)
		end)

		it("OnEntry fires once per captured entry, and the returned disconnect stops it", function()
			local logger = Logger.scope("LoggerSpecTest_OnEntry")
			local received = {}
			local disconnect = Logger.OnEntry(function(entry: Logger.LogEntry)
				if entry.Scope == "LoggerSpecTest_OnEntry" then
					table.insert(received, entry)
				end
			end)

			logger:info("LoggerSpecTest OnEntry first")
			disconnect()
			logger:info("LoggerSpecTest OnEntry second")

			expect(#received).to.equal(1)
			expect(received[1].Message).to.equal("LoggerSpecTest OnEntry first")
		end)

		it("evicts the oldest entries once total captures exceed the configured buffer capacity", function()
			local capacity = Constants.Debug.Logging.ConsoleBufferSize
			local logger = Logger.scope("LoggerSpecTest_Eviction")
			local marker = tostring(os.clock())

			-- Pushing MORE than the whole buffer's capacity from this one scope alone guarantees the
			-- last `capacity` of these pushes exactly fill the entire (shared, cross-scope) buffer,
			-- displacing every entry from any other scope/spec -- so the assertions below can be
			-- exact, not just "no more than capacity survived".
			withTraceCapture(function()
				for index = 1, capacity + 5 do
					logger:debug(`LoggerSpecTest eviction {marker} {index}`)
				end
			end)

			local ownEntries = {}
			for _, entry in ipairs(Logger.GetBufferSnapshot()) do
				if entry.Scope == "LoggerSpecTest_Eviction" then
					table.insert(ownEntries, entry)
				end
			end

			expect(#ownEntries).to.equal(capacity)
			expect(ownEntries[1].Message).to.equal(`LoggerSpecTest eviction {marker} 6`)
			expect(ownEntries[#ownEntries].Message).to.equal(`LoggerSpecTest eviction {marker} {capacity + 5}`)
		end)

		it("drops everything below the capture floor, and records it again once the floor is lowered", function()
			local logger = Logger.scope("LoggerSpecTest_Floor")
			local marker = tostring(os.clock())

			local before = Logger.GetBufferSnapshot()
			local baseline = if #before > 0 then before[#before].Sequence else 0

			-- At the idle floor ("Info"), a debug line costs one compare and a return -- nothing
			-- reaches the ring. This is the whole point of the knob: ~981 logger: call sites in src/
			-- stop allocating a LogEntry, an os.time() and a listener fan-out apiece on a live server
			-- where no admin is watching.
			logger:debug("LoggerSpecTest floor suppressed " .. marker)
			expect(#Logger.GetBufferSnapshot(baseline)).to.equal(0)

			-- Raised, which is what Server/Systems/LiveConsoleSystem.lua does the moment an admin
			-- console actually opens.
			withTraceCapture(function()
				logger:debug("LoggerSpecTest floor captured " .. marker)
			end)

			local captured = Logger.GetBufferSnapshot(baseline)
			expect(#captured).to.equal(1)
			expect(captured[1].Message).to.equal("LoggerSpecTest floor captured " .. marker)

			-- And restored -- a console that closes must not leave the server recording at Trace.
			expect(Logger.GetCaptureLevel()).to.equal(Constants.Debug.Logging.CaptureLevel)

			logger:debug("LoggerSpecTest floor suppressed again " .. marker)
			expect(#Logger.GetBufferSnapshot(baseline)).to.equal(1)
		end)

		it("captures a Warn at the idle floor with no raise -- the floor gates Trace/Debug, not problems", function()
			local logger = Logger.scope("LoggerSpecTest_FloorWarn")
			local before = Logger.GetBufferSnapshot()
			local baseline = if #before > 0 then before[#before].Sequence else 0

			logger:warn("LoggerSpecTest floor warn " .. tostring(os.clock()))

			local captured = Logger.GetBufferSnapshot(baseline)
			expect(#captured).to.equal(1)
			expect(captured[1].Level).to.equal("Warn")
		end)

		it("CaptureEngineEntry lands in the same buffer, tagged Source = Engine and Scope = Engine", function()
			local before = Logger.GetBufferSnapshot()
			local baseline = if #before > 0 then before[#before].Sequence else 0
			local marker = "LoggerSpecTest engine marker " .. tostring(os.clock())

			Logger.CaptureEngineEntry("Warn", marker)

			local captured = Logger.GetBufferSnapshot(baseline)
			expect(#captured).to.equal(1)
			expect(captured[1].Source).to.equal("Engine")
			expect(captured[1].Scope).to.equal("Engine")
			expect(captured[1].Level).to.equal("Warn")
			expect(captured[1].Message).to.equal(marker)
		end)
	end)
end
