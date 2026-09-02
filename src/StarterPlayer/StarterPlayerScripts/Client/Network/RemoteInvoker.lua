--!strict
--[[
	RemoteInvoker.lua

	Owns: the pcall boundary around RemoteFunction:InvokeServer(...) -- the same
	"pcall(function() return remote:InvokeServer(...) end)" block hand-duplicated across
	DevMenuClient.invokeAndReport, BugReportClient.lua's own submit call, and four separate blocks in
	CharacterMenuClient.lua.

	TWO ENTRY POINTS, because there are two genuinely different call shapes. Invoke/InvokeAndReport
	take a resolved RemoteFunction; CallAndReport takes a closure, for the caller that must keep
	NetworkBridge.GetRemoteFunction's own assert inside the protected region. See CallAndReport's own
	comment -- collapsing the two would quietly convert a logged lookup failure into a thrown one.

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

-- The half both entry points below share: turn a (ok, result) pair into a status line, logging the
-- failure under `label` so a reader can tell WHICH request died without every caller keeping its own
-- logger scope for the purpose.
local function report(
	setStatus: (string) -> (),
	label: string,
	ok: boolean,
	resultOrError: unknown,
	describe: (unknown) -> string,
	errorStatus: string?
): ()
	if not ok then
		logger:error("Remote invoke errored", { remote = label, errorMessage = tostring(resultOrError) })
		setStatus(errorStatus or "Failed: request error")
		return
	end
	setStatus(describe(resultOrError))
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
	report(setStatus, remote.Name, ok, resultOrError, describe, errorStatus)
end

-- Same shape, for a call site that hands over a CLOSURE instead of a remote and its arguments.
--
-- Not redundant with InvokeAndReport above, and the difference is load-bearing rather than stylistic:
-- NetworkBridge.GetRemoteFunction ASSERTS when a remote fails to resolve, so a caller that looks the
-- remote up inside its own closure is protecting the LOOKUP as well as the invoke. Hoisting that
-- lookup out to pass a RemoteFunction here would move the assert outside the pcall and turn a logged
-- failure into a thrown one. Client/DevTools/DevMenu/DevMenuClient.lua's own invokeAndReport is the
-- caller this exists for -- thirty-nine call sites, most of which resolve their remote inline.
function RemoteInvoker.CallAndReport(
	setStatus: (string) -> (),
	label: string,
	call: () -> unknown,
	describe: (unknown) -> string,
	errorStatus: string?
): ()
	local ok, resultOrError = pcall(call)
	report(setStatus, label, ok, resultOrError, describe, errorStatus)
end

return RemoteInvoker
