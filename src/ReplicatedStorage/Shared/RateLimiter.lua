--!strict
--[[
	RateLimiter.lua

	Owns: a per-player-per-second call budget, one independent bucket set per RateLimiter.New()
	instance. Generic networking hygiene, not combat-specific -- belongs in Shared/ the same reason
	Logger.lua does (a small utility more than one system wants, without being one of the three
	canonical Shared files). A caller that owns more than one remote-budget category (e.g.
	CombatSystem.lua's combat-critical vs. utility split -- see performance-optimization.md's
	"combat-critical remotes... take priority... over cosmetic/UI-sync remotes, which should be
	throttled first") constructs one instance per category, so a burst against one category's
	budget can never exhaust another's.

	Does not own: what counts as a call, which remotes map to which instance, or what happens when
	a call is rejected -- callers decide all of that; this only tracks call volume per player
	against a fixed per-instance ceiling. Does not own deciding which actions should be exempt from
	limiting entirely (e.g. a "stop"/release action, where a dropped request could strand a player
	mid-state) -- a caller that wants an action unlimited simply never calls IsLimited for it,
	rather than this module special-casing specific actions it has no way to know about.
]]

local RateLimiter = {}
RateLimiter.__index = RateLimiter

type RateLimitState = {
	windowStart: number,
	count: number,
}

export type RateLimiterInstance = typeof(setmetatable(
	{} :: {
		maxPerSecond: number,
		buckets: { [Player]: RateLimitState },
	},
	RateLimiter
))

-- One independent per-player bucket set, capped at maxPerSecond calls/sec/player.
function RateLimiter.New(maxPerSecond: number): RateLimiterInstance
	return setmetatable({
		maxPerSecond = maxPerSecond,
		buckets = {},
	}, RateLimiter)
end

-- True if `player` has already used this instance's whole budget for the current 1-second window
-- (and does not consume a slot in that case); otherwise records this call and returns false.
function RateLimiter.IsLimited(self: RateLimiterInstance, player: Player): boolean
	local now = os.clock()
	local bucket = self.buckets[player]
	if not bucket or now - bucket.windowStart >= 1 then
		self.buckets[player] = { windowStart = now, count = 1 }
		return false
	end

	if bucket.count >= self.maxPerSecond then
		return true
	end

	bucket.count += 1
	return false
end

-- Drops `player`'s bucket -- call on PlayerRemoving so buckets don't accumulate for players who
-- have left, the same reason every per-player state table in this codebase clears its entry then.
function RateLimiter.Clear(self: RateLimiterInstance, player: Player): ()
	self.buckets[player] = nil
end

return RateLimiter
