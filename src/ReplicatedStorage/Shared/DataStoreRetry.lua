--!strict
--[[
	DataStoreRetry.lua

	Owns: the retry/backoff loop every DataStore call in this codebase goes through --
	exponential backoff, a capped attempt count, and structured logging on each failed attempt
	and on final exhaustion. This is engineering-standards.md's data-integrity rule in code:
	"treat DataStore failures as expected-but-rare events with explicit retry/backoff handling,
	not edge cases that can be ignored."

	Extracted from BugReportSystem.lua's and ModerationSystem.lua's own near-identical local
	`withRetry` helpers now that PlayerDataSystem.lua needs the exact same shape as a third
	caller -- both of those modules' own headers already flagged this precise threshold
	(BugReportSystem.lua: "a candidate for extraction into PlayerDataSystem's future DataStore
	layer later, not before"; ModerationSystem.lua: "a real candidate for extraction into a
	shared DataStore-retry utility once a third caller needs the same shape"). PlayerDataSystem
	is that later/third caller, so this module exists now and BugReportSystem.lua/
	ModerationSystem.lua's own `withRetry` locals have been changed to delegate to it (same
	function name, same call sites, same log lines -- only the implementation moved) rather than
	leaving three copies of one algorithm to drift out of sync. Belongs in ReplicatedStorage/
	Shared alongside RateLimiter.lua/Logger.lua/ChangeNotifier.lua -- generic infra, not
	persistence-specific -- so PlayerDataSystem depending on it (gameplay -> infra) never becomes
	infra depending on a System (which would invert software-architecture.md's dependency rule).

	Scoped() came later, and closes the second half of the same duplication. Attempt() removed the
	retry ALGORITHM from five Systems but left each of them a byte-identical three-line `withRetry`
	local binding the same logger and the same policy to it -- five copies of the binding instead of
	five copies of the loop. Scoped returns that binding, so a System's persistence layer is one line.

	Does not own: which DataStore/key/operation is being retried, what a caller does with a
	final failure (kick, reject-and-log, degrade), or logger scope naming -- callers pass their
	own already-scoped Logger instance so warn/error lines attribute to the calling System, not
	to "DataStoreRetry" itself.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Logger = require(ReplicatedStorage.Shared.Logger)

local DataStoreRetry = {}

export type RetryConfig = {
	MaxAttempts: number,
	BaseBackoffSeconds: number,
}

-- Runs `attempt` up to `config.MaxAttempts` times, waiting `BaseBackoffSeconds * 2^(n-1)` between
-- attempts (exponential backoff). Returns (true, result, nil) on the first successful attempt, or
-- (false, nil, "StorageError") once every attempt has failed. `logger` is the CALLER's own
-- Logger.scope(...) instance -- see this module's header for why it isn't opened here.
function DataStoreRetry.Attempt<T>(
	logger: Logger.LoggerScope,
	operationName: string,
	config: RetryConfig,
	attempt: () -> T
): (boolean, T?, string?)
	for attemptNumber = 1, config.MaxAttempts do
		local ok, resultOrError = pcall(attempt)
		if ok then
			return true, resultOrError :: T, nil
		end
		logger:warn(operationName .. " attempt failed", {
			attempt = attemptNumber,
			maxAttempts = config.MaxAttempts,
			errorMessage = tostring(resultOrError),
		})
		if attemptNumber < config.MaxAttempts then
			task.wait(config.BaseBackoffSeconds * (2 ^ (attemptNumber - 1)))
		end
	end
	logger:error(operationName .. " exhausted all retries", { maxAttempts = config.MaxAttempts })
	return false, nil, "StorageError"
end

-- Binds a logger and a policy to Attempt once, returning the `withRetry(operationName, attempt)`
-- helper every persisting System was otherwise writing out for itself.
--
-- Five Systems (BugReport, KitEditor, Moderation, MoveEditor, PlayerData) each held the identical
-- three-line local, differing only in which Constants table they read the same two numbers out of --
-- and those five tables held the identical pair of values too. Both halves collapse here:
-- Constants.Storage.RetryPolicy is the single policy, and this is the single binding.
--
-- Called ONCE per System, at module scope -- not per operation. The returned closure is what call
-- sites use, so there is no per-call allocation.
function DataStoreRetry.Scoped(
	logger: Logger.LoggerScope,
	config: RetryConfig
): <T>(operationName: string, attempt: () -> T) -> (boolean, T?, string?)
	return function<T>(operationName: string, attempt: () -> T): (boolean, T?, string?)
		return DataStoreRetry.Attempt(logger, operationName, config, attempt)
	end
end

return DataStoreRetry
