--!strict
--[[
	Logger.lua

	Owns: Studio-only structured diagnostic logging -- Constants.Debug.Logging is the single
	on/off switch and filter config; this module is the thing that actually reads it and decides
	whether/how to print. Not gameplay logic, not a replacement for CombatFeedback/ClientState (this
	never touches game state, never fires a remote, never affects a single validation or damage
	decision anywhere it's called from) -- purely an observability aid for reading Studio Output
	while diagnosing why input/remotes/validation/hit-detection are or aren't firing.

	Production safety (engineering-standards.md's "fail safely in production" + this module's own
	explicit mandate): a log call only ever actually prints when BOTH `RunService:IsStudio()` is
	true AND `Constants.Debug.Logging.Enabled` is true -- "unless explicitly enabled" in this
	module's spec means Enabled is a required additional gate alongside IsStudio, not a way to force
	logging on in a live server. There is no live-server override in this repo, by design: a
	published server should never have this module printing to its log, regardless of Constants.

	Does not own: what gets logged where -- every call site (CombatSystem, CombatClient,
	NetworkBridge, ClientState, UI, ...) decides its own messages/fields/levels. This module only
	owns formatting, filtering, and making sure a bad `fields` value can never throw into the
	caller (pcall-wrapped end to end) or flood Output (per-message rate limiting).

	Also owns (2026-08-17, the Live Admin Console): an always-on, per-VM capture buffer -- the
	server has its own, each client has its own -- that records every entry passed to emit() (and
	every raw engine line Shared/EngineLogCapture.lua feeds in via CaptureEngineEntry), regardless
	of Enabled/IsStudio/Level/Scope above. This is a DELIBERATE, narrow exception to this module's
	own production-safety contract, and it is safe precisely because of what it does NOT change:
	the print()/warn() path above -- the only thing that can ever put a line in front of someone
	who isn't explicitly asking for it -- keeps its exact original gate, untouched. The buffer is
	inert data sitting in this VM's own memory until Server/Systems/LiveConsoleSystem.lua's
	Subscribe handler (whitelist-gated the same way every other admin action in this codebase is)
	hands a snapshot of it to an authorized admin's own client on request. "Never prints to Output
	outside Studio" and "is capturable by a whitelisted admin regardless of Studio" are different
	properties; this module still only ever does the first when Enabled+IsStudio hold, same as
	before. See GetBufferSnapshot/OnEntry/CaptureEngineEntry below.

	Usage:
		local Logger = require(ReplicatedStorage.Shared.Logger)
		local logger = Logger.scope("CombatSystem")
		logger:info("Attack request accepted", { player = player.Name, action = "BasicAttack" })
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
-- LogTypes.lua is a leaf module (no requires of its own) purely so Types.lua can pull LogEntry in
-- for LiveConsoleSubscribeResult without closing a Types -> Logger -> Constants -> Types cycle --
-- see that module's own header. Re-exported below so every existing `Logger.LogEntry` etc. call
-- site is unaffected.
local LogTypes = require(ReplicatedStorage.Shared.LogTypes)

local Logger = {}

export type LogLevel = LogTypes.LogLevel
export type LogFields = LogTypes.LogFields
export type LogSource = LogTypes.LogSource
export type LogEntry = LogTypes.LogEntry

export type LoggerScope = {
	trace: (self: LoggerScope, message: string, fields: LogFields?) -> (),
	debug: (self: LoggerScope, message: string, fields: LogFields?) -> (),
	info: (self: LoggerScope, message: string, fields: LogFields?) -> (),
	warn: (self: LoggerScope, message: string, fields: LogFields?) -> (),
	error: (self: LoggerScope, message: string, fields: LogFields?) -> (),
}

-- Keyed by plain string (not LogLevel) since Constants.Debug.Logging.Level is authored as an
-- untyped string literal in Constants.lua -- the `or LEVEL_RANK.Off` fallback at each lookup site
-- is what actually guards against a typo'd/invalid configured level, not the key type.
local LEVEL_RANK: { [string]: number } = {
	Trace = 1,
	Debug = 2,
	Info = 3,
	Warn = 4,
	Error = 5,
	Off = 6,
}

local SIDE = if RunService:IsServer() then "Server" else "Client"

--
-- Rate limiting: at most Constants.Debug.Logging.MaxRepeatsPerSecond emissions per second for a
-- given (scope, level, message) triple -- deliberately keyed off the static message text, not the
-- dynamic field values, so e.g. "vitals payload received" logged every tick with different numbers
-- is still recognized as the same repeating log and gets capped. Bounded memory: the number of
-- distinct (scope, level, message) triples is bounded by the number of logger call sites in source,
-- not by runtime event volume.
--

type RateLimitBucket = { windowStart: number, count: number }
-- Nested scope -> level -> message rather than one table keyed by a `scope\0level\0message` string.
-- The triple identifies the same bucket either way, but the flat key had to be BUILT on every single
-- log call before the bucket could be looked up -- a fresh string concatenation, and therefore a heap
-- allocation plus an interning hash, at all ~380 logger:debug/:info call sites in src/, including the
-- ones inside per-frame loops, and including in a live server where nothing was ever going to print.
-- Three table indexes cost nothing and allocate nothing on the steady-state path (the two inner
-- tables are created once per distinct call site, which is bounded by source, exactly as the flat
-- keys were). This is the same reason emitBody exists as a named function instead of a closure -- see
-- its own comment below.
local rateLimitBuckets: { [string]: { [string]: { [string]: RateLimitBucket } } } = {}

local function isRateLimited(scopeName: string, level: LogLevel, message: string): boolean
	local maxPerSecond = Constants.Debug.Logging.MaxRepeatsPerSecond
	if not maxPerSecond or maxPerSecond <= 0 then
		return false
	end

	local byLevel = rateLimitBuckets[scopeName]
	if not byLevel then
		byLevel = {}
		rateLimitBuckets[scopeName] = byLevel
	end
	local byMessage = byLevel[level]
	if not byMessage then
		byMessage = {}
		byLevel[level] = byMessage
	end

	local now = os.clock()
	local bucket = byMessage[message]
	if not bucket or now - bucket.windowStart >= 1 then
		byMessage[message] = { windowStart = now, count = 1 }
		return false
	end

	if bucket.count >= maxPerSecond then
		return true
	end

	bucket.count += 1
	return false
end

--
-- Formatting -- never throws (wrapped by the caller in emit()), regardless of what's in `fields`.
--

local function safeStringifyValue(value: unknown): string
	local ok, result = pcall(function()
		if typeof(value) == "string" then
			return string.format("%q", value)
		end
		return tostring(value)
	end)
	if ok then
		return result
	end
	return "<unstringifiable>"
end

local function buildFieldsSuffix(fields: LogFields?): string
	if not fields then
		return ""
	end

	local keys = {}
	for key in pairs(fields) do
		table.insert(keys, key)
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)

	local parts = {}
	for _, key in ipairs(keys) do
		table.insert(parts, `{tostring(key)}={safeStringifyValue(fields[key])}`)
	end

	if #parts == 0 then
		return ""
	end
	return " " .. table.concat(parts, " ")
end

local function formatLine(scopeName: string, level: LogLevel, message: string, fields: LogFields?): string
	local fieldsSuffix = ""
	local ok, result = pcall(buildFieldsSuffix, fields)
	if ok then
		fieldsSuffix = result
	else
		fieldsSuffix = " <fields-error>"
	end
	return string.format("[t=%.3f][%s][%s][%s] %s%s", os.clock(), SIDE, scopeName, level, message, fieldsSuffix)
end

--
-- Console capture buffer -- see this module's own header for what this is and why it's safe.
-- Preallocated circular buffer (fixed capacity, wrapping write index) rather than table.insert/
-- table.remove(1) -- O(1) per entry regardless of capacity, which matters because every
-- logger:info/debug/etc call site in the whole codebase now pays this cost unconditionally,
-- including in live production where it previously paid nothing past the `config.Enabled` check.
--

local CONSOLE_BUFFER_CAPACITY = math.max(1, Constants.Debug.Logging.ConsoleBufferSize)
local consoleBuffer: { [number]: LogEntry } = table.create(CONSOLE_BUFFER_CAPACITY)
local consoleSequence = 0

-- Keyed by a fresh throwaway table (not a name/counter) purely as a unique, unforgeable token to
-- disconnect by -- same idiom a :Connect() RBXScriptConnection object serves elsewhere, just
-- without pulling in a real Connection type for what is otherwise a plain callback list.
local entryListeners: { [{}]: (LogEntry) -> () } = {}

-- THE CAPTURE FLOOR, and the single most-read value in this module -- emitBody below compares
-- against it on every one of the ~981 logger: call sites in src/, so it is held as a plain upvalue
-- rather than re-indexed out of Constants per call.
--
-- Two levels, not one. Constants.Debug.Logging.CaptureLevel is the IDLE floor: what a server records
-- when nobody is watching, which is almost always. SetCaptureLevel below is what raises it, and
-- Server/Systems/LiveConsoleSystem.lua is the only caller -- it drops the floor to Trace on the first
-- admin subscribing and restores the idle level when the last one leaves. So the expensive path (a
-- LogEntry table, an os.time(), a ring write, a fan-out to every listener) is paid for debug-level
-- lines only while somebody is actually reading them, and the rest of the time a logger:debug costs
-- one compare and a return.
--
-- What this trades away, stated plainly: the ring no longer holds Trace/Debug history from BEFORE an
-- admin opened the console. Subscribe's snapshot goes back 1000 entries as it always did, but the
-- older ones are Info and above. Everything from the moment of subscribing is complete.
local idleCaptureLevel: LogLevel = Constants.Debug.Logging.CaptureLevel :: LogLevel
local captureLevelRank = LEVEL_RANK[idleCaptureLevel] or LEVEL_RANK.Off

local function oldestCapturedSequence(): number
	return math.max(1, consoleSequence - CONSOLE_BUFFER_CAPACITY + 1)
end

-- Shared insertion point for both emit() (App-sourced) and CaptureEngineEntry (Engine-sourced)
-- below -- funneling both through here is what keeps Sequence a single gapless counter and both
-- sources visible to the same GetBufferSnapshot/OnEntry readers.
local function captureEntry(
	scopeName: string,
	level: LogLevel,
	message: string,
	fields: LogFields?,
	source: LogSource
): ()
	consoleSequence += 1
	local entry: LogEntry = {
		Sequence = consoleSequence,
		TimestampUnix = os.time(),
		Side = SIDE,
		Scope = scopeName,
		Level = level,
		Message = message,
		Fields = fields,
		Source = source,
	}
	local slot = ((consoleSequence - 1) % CONSOLE_BUFFER_CAPACITY) + 1
	consoleBuffer[slot] = entry

	-- Individually pcall-wrapped so one bad listener can never stop the rest from hearing about
	-- this entry -- matches this module's own "never throws into the caller" discipline, applied
	-- one layer further out since a listener is foreign code, not this module's own.
	for _, listener in pairs(entryListeners) do
		pcall(listener, entry)
	end
end

-- Every captured entry newer than `sinceSequence` (or the whole live buffer if omitted, or older
-- than what's still retained), oldest first. O(capacity) worst case -- fine since this only ever
-- runs on demand (LiveConsoleSystem.lua's Subscribe handler), never per-frame.
function Logger.GetBufferSnapshot(sinceSequence: number?): { LogEntry }
	local result: { LogEntry } = {}
	local startSequence = math.max(oldestCapturedSequence(), (sinceSequence or 0) + 1)
	for sequence = startSequence, consoleSequence do
		local slot = ((sequence - 1) % CONSOLE_BUFFER_CAPACITY) + 1
		local entry = consoleBuffer[slot]
		if entry and entry.Sequence == sequence then
			table.insert(result, entry)
		end
	end
	return result
end

-- Registers a listener fired once per newly captured entry (App and Engine alike). Returns a
-- disconnect function. Server/Systems/LiveConsoleSystem.lua is this function's one caller today,
-- registered once at its own Init().
function Logger.OnEntry(callback: (LogEntry) -> ()): () -> ()
	local token = {}
	entryListeners[token] = callback
	return function()
		entryListeners[token] = nil
	end
end

-- Narrow ingestion path for Shared/EngineLogCapture.lua's LogService.MessageOut hook -- kept
-- separate from emit() so a raw engine line (no scope, no fields, just a level + text Roblox
-- already decided) never has to fake either to share the pipe, while still landing in the exact
-- same Sequence-ordered buffer/listener fan-out real app logs use.
--
-- Rate-limited on the same (scope, level, message) triple emit() uses, under the fixed "Engine"
-- scope. This path used to reach captureEntry with no cap at all, which meant Constants.Debug.
-- Raises or restores the capture floor described above. Only Server/Systems/LiveConsoleSystem.lua
-- calls this, and only off its own subscriberCount edges; anything else calling it would be quietly
-- deciding what an admin gets to see, which belongs with the System that knows whether one is
-- looking. Passing nil restores Constants.Debug.Logging.CaptureLevel, so a caller never has to
-- remember what the idle level was.
function Logger.SetCaptureLevel(level: LogLevel?): ()
	local resolved: LogLevel = level or idleCaptureLevel
	captureLevelRank = LEVEL_RANK[resolved] or LEVEL_RANK.Off
end

-- The floor currently in force, not the idle one -- exposed for the Live Console's own status line
-- and for specs, which need to assert the raise/restore edges without reaching into an upvalue.
-- Whether an entry at `level` would be captured right now -- for a caller whose log line is expensive to build
-- (Server/Combat/CombatTrace.lua builds a field table per combat event), so it can skip the work entirely while
-- nobody is watching. The cheap answer to the question emitBody asks first.
function Logger.IsCapturing(level: LogLevel): boolean
	return (LEVEL_RANK[level] or LEVEL_RANK.Off) >= captureLevelRank
end

function Logger.GetCaptureLevel(): LogLevel
	for level, rank in pairs(LEVEL_RANK) do
		if rank == captureLevelRank then
			return level :: LogLevel
		end
	end
	return "Off" :: LogLevel
end

-- Logging.MaxRepeatsPerSecond -- documented as protecting "the always-on console capture buffer" --
-- protected it only from THIS codebase's own log sites, and not at all from the engine's. A single
-- engine warning repeating every frame (a physics/asset/script warning in a loop, none of which this
-- codebase controls) would evict the entire 1000-entry ring within seconds and, with an admin
-- subscribed, be forwarded verbatim to their client on every flush -- so the one situation where an
-- admin most needs the Live Console is the one where the engine's own noise had already destroyed
-- the buffer they wanted to read. Deliberately NOT gated on CaptureLevel: Roblox decides these
-- levels, and an engine line arriving at all is already evidence of something worth keeping.
function Logger.CaptureEngineEntry(level: LogLevel, message: string): ()
	if isRateLimited("Engine", level, message) then
		return
	end
	captureEntry("Engine", level, message, nil, "Engine")
end

-- True for exactly the duration of the print()/warn() call inside emit() below. Roblox's own
-- LogService.MessageOut echoes every print/warn back to any listener -- EngineLogCapture.lua's own
-- hook checks this before treating a MessageOut line as genuine external engine output, so a
-- Studio session with logging enabled never double-captures this module's own lines (once here via
-- captureEntry, once again via the LogService echo).
local suppressingOwnOutput = false
function Logger.IsSuppressingOwnOutput(): boolean
	return suppressingOwnOutput
end

--
-- Emission
--

-- Split from emit() below purely so pcall can be called as pcall(emitBody, ...) instead of
-- pcall(function() ... end) -- the latter allocates a fresh closure (capturing scopeName/level/
-- message/fields) on every single logger:info/debug/etc call site in the codebase; passing emitBody
-- as a plain function value plus its args to pcall allocates nothing extra. Behavior is unchanged --
-- still whole-body pcall-wrapped so a bad `fields` value (or anything else going wrong here) can
-- never throw into the caller's actual gameplay code.
local function emitBody(scopeName: string, level: LogLevel, message: string, fields: LogFields?): ()
	local levelRank = LEVEL_RANK[level] or LEVEL_RANK.Off

	-- THE FIRST GATE, and deliberately the cheapest thing in this function: one upvalue read and a
	-- comparison, above the rate limiter, above captureEntry, and above even resolving `config`.
	-- Everything past this line allocates something (a bucket table, a LogEntry, a listener fan-out),
	-- and in a live server the capture buffer is the ONLY consumer of any of it -- so a level the
	-- buffer has been told not to record must cost nothing rather than being allocated and then
	-- discarded downstream. See captureLevelRank above for the idle/raised split, and
	-- Constants.Debug.Logging.CaptureLevel for why this is a separate knob from `Level` below.
	if levelRank < captureLevelRank then
		return
	end

	local config = Constants.Debug.Logging

	-- Shared by both destinations below (the always-on buffer AND Output) so a log site that
	-- fires every frame can't flood either one, even at Trace, even outside Studio.
	if isRateLimited(scopeName, level, message) then
		return
	end

	-- Captured independent of Enabled/IsStudio/Level/Scope below -- see this module's own header
	-- for why. This is the one line in emit() that runs in a live server; everything below it only
	-- runs in Studio with logging enabled, exactly as before.
	captureEntry(scopeName, level, message, fields, "App")

	if not config.Enabled then
		return
	end
	if not RunService:IsStudio() then
		return
	end

	local configuredRank = LEVEL_RANK[config.Level] or LEVEL_RANK.Off
	if levelRank < configuredRank then
		return
	end

	if config.Scopes[scopeName] ~= true then
		return
	end

	local line = formatLine(scopeName, level, message, fields)
	suppressingOwnOutput = true
	if levelRank >= LEVEL_RANK.Warn then
		warn(line)
	else
		print(line)
	end
	suppressingOwnOutput = false
end

local function emit(scopeName: string, level: LogLevel, message: string, fields: LogFields?): ()
	pcall(emitBody, scopeName, level, message, fields)
end

-- Returns a scoped logger bound to `name` (one of Constants.Debug.Logging.Scopes' keys, though an
-- unlisted name is valid too -- it just won't pass the scope filter until added there). Cheap to
-- call once per module at require-time; each scope is a small table of closures, not a shared
-- metatable, since this only ever happens a handful of times per Lua VM (once per instrumented
-- module), not per log call.
function Logger.scope(name: string): LoggerScope
	local self = {} :: LoggerScope
	self.trace = function(_self, message, fields)
		emit(name, "Trace", message, fields)
	end
	self.debug = function(_self, message, fields)
		emit(name, "Debug", message, fields)
	end
	self.info = function(_self, message, fields)
		emit(name, "Info", message, fields)
	end
	self.warn = function(_self, message, fields)
		emit(name, "Warn", message, fields)
	end
	self.error = function(_self, message, fields)
		emit(name, "Error", message, fields)
	end
	return self
end

return Logger
