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
return function()
	describe("Logger console capture buffer", function()
		it("captures a call regardless of Enabled/IsStudio/Level/Scope -- unlisted scope, Trace level", function()
			local logger = Logger.scope("LoggerSpecTest_Capture")
			local before = Logger.GetBufferSnapshot()
			local baseline = if #before > 0 then before[#before].Sequence else 0

			logger:trace("LoggerSpecTest capture marker " .. tostring(os.clock()))

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
			for index = 1, capacity + 5 do
				logger:debug(`LoggerSpecTest eviction {marker} {index}`)
			end

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
