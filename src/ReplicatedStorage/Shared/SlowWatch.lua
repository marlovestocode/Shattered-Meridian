--!strict
--[[
	SlowWatch.lua

	Owns: one narrow job -- making an event handler's cost visible. `SlowWatch.Handler(logger, label, fn)`
	returns `fn` wrapped so that every call (a) carries a MicroProfiler label, and (b) logs ONE warning
	through `logger` if it took longer than a budget, naming the label and the milliseconds.

	WHY (2026-09-30). The realm's Qi upkeep fired a chain of deferred handlers ten times a second, and the
	frame-rate counter (Client/Diagnostics/FpsCounter.lua) did not show them: its `scripts` figure is
	Stats.HeartbeatTimeMs, which covers the Heartbeat job only, and a handler resumed from a BindableEvent,
	a RemoteEvent or a signal runs in the scheduler's deferred-thread pass -- a ~60ms burst that read as
	"scripts 0.5ms" on the screen while every frame hitched. The capture that found it could say WHICH
	scheduler job the time was in, but not which handler, because a Luau function carries no label of its
	own. A handler that is wrapped here does: its label nests under the burst in the MicroProfiler
	(Ctrl+Alt+F6), and a slow one says so in the Output window with no capture needed.

	WHAT TO WRAP. The handlers of anything that fires at a steady rate or in a burst (a per-tick event, a
	remote a System pushes on a timer): those are the ones whose cost multiplies. Not every handler -- the
	label and two os.clock reads are cheap but not free, and a handler that fires once a session has
	nothing to hide.

	THE WARNING IS RATE-LIMITED BY THE LOGGER, not here (Logger's own per-scope/level/message bucket), so a
	handler that is slow on every call warns a few times, not ten a second. The budget is the caller's:
	pass one, or take DEFAULT_BUDGET_SECONDS (half a 60Hz frame -- a handler that costs that much is a
	hitch by itself).

	Does not own: what a handler does, or any timing other than wall-clock around one call. Not a
	profiler -- it attributes a cost to a handler, not a line inside it.
]]

local Logger = require(script.Parent.Logger)

local SlowWatch = {}

-- Half a frame at 60Hz: a single handler spending this much is a visible hitch on its own.
SlowWatch.DEFAULT_BUDGET_SECONDS = 1 / 120

-- `fn` wrapped with a profiler label and a slow-call warning. `fn` must not yield: the label is closed
-- when it returns, and a yield would leave it open across an unrelated thread's work. Returns nothing --
-- an event handler's return value is discarded, and saying so keeps the wrapper allocation-free.
function SlowWatch.Handler<Args...>(
	logger: Logger.LoggerScope,
	label: string,
	fn: (Args...) -> (),
	budgetSeconds: number?
): (Args...) -> ()
	local budget = budgetSeconds or SlowWatch.DEFAULT_BUDGET_SECONDS
	return function(...: Args...): ()
		debug.profilebegin(label)
		local startedAt = os.clock()
		fn(...)
		local elapsed = os.clock() - startedAt
		debug.profileend()
		if elapsed >= budget then
			logger:warn("Slow handler", {
				label = label,
				milliseconds = math.floor(elapsed * 1000 + 0.5),
				budgetMilliseconds = math.floor(budget * 1000 + 0.5),
			})
		end
	end
end

return SlowWatch
