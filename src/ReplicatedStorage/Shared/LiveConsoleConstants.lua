--!strict
--[[
	LiveConsoleConstants.lua

	Owns: the F5 Live Console's own transport tuning -- the bounded capture ring, the flush interval
	and batch shape, and the per-remote budgets.

	NOTE WHERE THIS LIVES AND WHY IT MATTERS: under Shared/, not Client/DevTools/. LiveConsoleSystem
	is deliberately built to keep working in a live server, and DebugConstants.lua's header already
	records the same rule for the same reason -- a constants module reachable from non-DevTools code
	must not sit in a subtree live.project.json omits, or the live build fails at require time.

	Does not own: the Logger capture level that decides what is emitted at all (Shared/Logger.lua), or
	the console UI itself.

	Lifted out of Constants.lua. Constants.LiveConsole re-exports this module, so every existing
	Constants.LiveConsole.X call site keeps working unchanged; new code should require this module
	directly.
]]

-- Live Admin Console (F5) -- whitelist-gated, same trust model as Constants.Debug.DevMenu/
-- Constants.MoveEditor above: every remote below is gated by LiveConsoleSystem.lua's own
-- checkLiveConsolePreconditions (AdminConfig.AuthorizedUserIds + a dedicated rate-limit bucket),
-- mirroring DevMenuSystem.lua's checkDevMenuPreconditions exactly. Unlike DevMenu/MoveEditor this
-- is NOT Studio-only tooling wrapped around Studio-only data -- it exists specifically to work in a
-- live server, where Shared/Logger.lua's own Output gate (RunService:IsStudio()) correctly stays
-- silent. See Logger.lua's own header for how its always-on capture buffer makes that safe.
local LiveConsoleConstants = {
	RemoteNames = {
		-- RemoteFunction, fired when the panel actually opens (not eagerly at boot) -- doubles as the
		-- authorization check AND fetches a fresh Logger.GetBufferSnapshot() at that exact moment, so
		-- the console never opens on a snapshot that went stale while the panel sat closed.
		Subscribe = "LiveConsole_Subscribe",
		-- Fire-and-forget (RemoteEvent, no response needed) -- tells the server the admin's console
		-- just closed, so the flush loop stops pushing to them. Same "SetEditorOpen" idiom
		-- Constants.MoveEditor.RemoteNames uses for its own open/close signal above; no
		-- precondition/rate-limit check on this one, matching RateLimiter.lua's own guidance that a
		-- "stop" action should never be blocked.
		Unsubscribe = "LiveConsole_Unsubscribe",
		-- Server -> subscribed clients only (never FireAllClients -- see LiveConsoleSystem.lua's own
		-- header for why a live log stream must never broadcast to non-admins). Payload: a batched
		-- array of Types.LogEntry, flushed on the interval below rather than once per captured entry.
		Stream = "LiveConsole_Stream",
	},
	-- How often LiveConsoleSystem.lua's flush loop pushes newly-captured entries to subscribers,
	-- regardless of how fast logs are actually arriving -- caps this feature at 4 pushes/sec/admin
	-- no matter the log volume, independent of Logger.lua's own per-message Output rate limit.
	StreamFlushIntervalSeconds = 0.25,
	-- Client-side render cap (Client/DevTools/LiveConsole/LiveConsoleClient.lua) -- oldest rendered lines are
	-- trimmed past this so a long-open console can't grow its own UI list unbounded. Kept small
	-- (not the server capture buffer's size) because appendEntries clones this many entries on every
	-- single log line while the panel is open, and nobody reads 1000 lines in a scrolling panel.
	ClientRenderCap = 200,
	-- Hard ceiling on how many entries a single Stream push may carry (LiveConsoleSystem.lua's
	-- pendingBatch). StreamFlushIntervalSeconds above caps how OFTEN this feature sends; nothing
	-- capped how BIG a send was, and the two are not the same protection. Log volume inside one
	-- 0.25s window is bounded only by how many distinct (scope, level, message) triples exist --
	-- Logger's own MaxRepeatsPerSecond is per-triple, and there are hundreds of them -- so a genuine
	-- incident (the exact moment an admin has the console open) is when the batch is largest, and an
	-- unbounded batch would make the one remote meant to help diagnose a struggling server the
	-- largest payload it sends. Past this count the oldest pending entries are dropped and the push
	-- carries a synthetic "N entries dropped" line, so the admin is told the feed is lossy rather
	-- than quietly shown a gap. Sized above ClientRenderCap so a full batch still fills the panel.
	StreamBatchCap = 300,
}

return LiveConsoleConstants
