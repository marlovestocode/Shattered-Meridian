--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataStoreRetry = require(ReplicatedStorage.Shared.DataStoreRetry)
local Logger = require(ReplicatedStorage.Shared.Logger)

-- BaseBackoffSeconds is kept tiny (0.01) throughout -- the retry LOOP's correctness is what's
-- under test, not real DataStore backoff timing (BugReportSystem.lua/ModerationSystem.lua/
-- PlayerDataSystem.lua's own Constants tables own the real production values), so there's no
-- reason for this spec file to actually wait out a realistic exponential backoff.

return function()
	local logger = Logger.scope("DataStoreRetryTest")

	describe("DataStoreRetry.Attempt", function()
		it("returns the result on the first successful attempt without retrying", function()
			local calls = 0
			local ok, result, reason = DataStoreRetry.Attempt(logger, "test op", {
				MaxAttempts = 3,
				BaseBackoffSeconds = 0.01,
			}, function()
				calls += 1
				return "value"
			end)

			expect(ok).to.equal(true)
			expect(result).to.equal("value")
			expect(reason).to.equal(nil)
			expect(calls).to.equal(1)
		end)

		it("retries after a failed attempt and succeeds once the operation stops throwing", function()
			local calls = 0
			local ok, result = DataStoreRetry.Attempt(logger, "test op", {
				MaxAttempts = 3,
				BaseBackoffSeconds = 0.01,
			}, function()
				calls += 1
				if calls < 2 then
					error("simulated transient failure")
				end
				return "recovered"
			end)

			expect(ok).to.equal(true)
			expect(result).to.equal("recovered")
			expect(calls).to.equal(2)
		end)

		it("exhausts every attempt and returns a StorageError when the operation always throws", function()
			local calls = 0
			local ok, result, reason = DataStoreRetry.Attempt(logger, "test op", {
				MaxAttempts = 3,
				BaseBackoffSeconds = 0.01,
			}, function()
				calls += 1
				error("always fails")
			end)

			expect(ok).to.equal(false)
			expect(result).to.equal(nil)
			expect(reason).to.equal("StorageError")
			expect(calls).to.equal(3)
		end)

		it("never calls the operation more than MaxAttempts times", function()
			local calls = 0
			DataStoreRetry.Attempt(logger, "test op", {
				MaxAttempts = 1,
				BaseBackoffSeconds = 0.01,
			}, function()
				calls += 1
				error("fails")
			end)

			expect(calls).to.equal(1)
		end)
	end)
end
