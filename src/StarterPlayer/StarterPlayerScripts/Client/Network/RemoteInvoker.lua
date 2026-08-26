--!strict
--[[
	RemoteInvoker.lua

	Owns: the pcall boundary around RemoteFunction:InvokeServer(...) -- the same
	"pcall(function() return remote:InvokeServer(...) end)" block hand-duplicated across
	DevMenuClient.invokeAndReport, BugReportClient.lua's own submit call, and four separate blocks in
	CharacterMenuClient.lua.

	Does not own: interpreting the result. This never guesses "Success" out of an arbitrary table --
	every System's Result shape is bespoke (extra fields like EmoteId/Field/Report/GuardEnabled beyond
	Success/Reason), so callers keep their own hand-written describe* translation function. Also does
	not own RemoteEvent Fire/listen -- no pcall boundary is needed there, and does not own task.spawn
	scheduling -- callers that need the invoke off the calling thread still wrap this themselves,
	exactly as CharacterMenuClient.lua's existing task.spawn(function() ... end) blocks already do.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Logger = require(ReplicatedStorage.Shared.Logger)

local RemoteInvoker = {}

local logger = Logger.scope("RemoteInvoker")

-- Invokes `remote` with the given arguments inside a pcall. Returns (true, Result...) on success,
-- or (false, errorMessage) if the invoke threw (a timeout, a disconnected remote, etc.).
function RemoteInvoker.Invoke<Result...>(remote: RemoteFunction, ...: any): (boolean, Result...)
	-- pcall'd against the method value directly rather than through a closure -- `remote.InvokeServer`
	-- is a plain function taking the remote as its first argument, so this passes the same arguments
	-- with no per-call allocation. The closure form this replaced built one on every invoke.
	return pcall(remote.InvokeServer, remote, ...)
end

-- Convenience wrapper matching invokeAndReport's existing shape (invoke -> describe -> set status)
-- so migrating a call site already using that pattern is a rename, not a rewrite. `args` is a list
-- since RemoteInvoker.Invoke's `...` can't be threaded through a second function boundary as a
-- variadic and stay typed. On a pcall failure, reports `errorStatus` if given, otherwise the same
-- "Failed: request error" text every existing caller already used.
function RemoteInvoker.InvokeAndReport(
	setStatus: (string) -> (),
	remote: RemoteFunction,
	args: { any },
	describe: (unknown) -> string,
	errorStatus: string?
): ()
	local ok, resultOrError = RemoteInvoker.Invoke(remote, table.unpack(args))
	if not ok then
		logger:error("Remote invoke errored", { remote = remote.Name, errorMessage = tostring(resultOrError) })
		setStatus(errorStatus or "Failed: request error")
		return
	end
	setStatus(describe(resultOrError))
end

return RemoteInvoker
