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

	Usage:
		local Logger = require(ReplicatedStorage.Shared.Logger)
		local logger = Logger.scope("CombatSystem")
		logger:info("Attack request accepted", { player = player.Name, action = "BasicAttack" })
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)

local Logger = {}

export type LogLevel = "Trace" | "Debug" | "Info" | "Warn" | "Error" | "Off"
export type LogFields = { [string]: unknown }

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
local rateLimitBuckets: { [string]: RateLimitBucket } = {}

local function isRateLimited(key: string): boolean
	local maxPerSecond = Constants.Debug.Logging.MaxRepeatsPerSecond
	if not maxPerSecond or maxPerSecond <= 0 then
		return false
	end

	local now = os.clock()
	local bucket = rateLimitBuckets[key]
	if not bucket or now - bucket.windowStart >= 1 then
		rateLimitBuckets[key] = { windowStart = now, count = 1 }
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
-- Emission
--

local function emit(scopeName: string, level: LogLevel, message: string, fields: LogFields?): ()
	-- Whole body pcall-wrapped: per this module's header, a bad `fields` value (or literally
	-- anything else going wrong here) must never throw into the caller's actual gameplay code.
	pcall(function()
		local config = Constants.Debug.Logging
		if not config.Enabled then
			return
		end
		if not RunService:IsStudio() then
			return
		end

		local configuredRank = LEVEL_RANK[config.Level] or LEVEL_RANK.Off
		local levelRank = LEVEL_RANK[level] or LEVEL_RANK.Off
		if levelRank < configuredRank then
			return
		end

		if config.Scopes[scopeName] ~= true then
			return
		end

		local rateLimitKey = scopeName .. "\0" .. level .. "\0" .. message
		if isRateLimited(rateLimitKey) then
			return
		end

		local line = formatLine(scopeName, level, message, fields)
		if levelRank >= LEVEL_RANK.Warn then
			warn(line)
		else
			print(line)
		end
	end)
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
