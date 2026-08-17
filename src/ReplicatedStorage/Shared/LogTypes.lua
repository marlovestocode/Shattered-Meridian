--!strict
--[[
	LogTypes.lua

	Owns: the shape of one captured log entry -- LogEntry, LogLevel, LogSource, LogFields -- as a
	genuinely leaf module with NO requires of its own, the same "leaf module" contract
	Shared/AnimationTimeline.lua already established (see Types.lua's own header comment on why that
	property is what makes pulling a type into Types.lua safe).

	Exists because Types.lua needs LogEntry for LiveConsoleSubscribeResult.Snapshot -- a genuine
	network-boundary type, squarely inside Types.lua's own charter -- but Shared/Logger.lua cannot be
	that source directly: Logger requires Constants, and Constants requires Types, so Types requiring
	Logger would close a three-module cycle (Types -> Logger -> Constants -> Types). Splitting these
	four TYPES out of Logger.lua into a dependency-free module breaks that cycle without moving any
	runtime behaviour -- Logger.lua re-exports every one of them as its own (`Logger.LogEntry` etc.
	still resolve everywhere they already did) and remains the only module that actually reads or
	writes a LogEntry.
]]

local LogTypes = {}

export type LogLevel = "Trace" | "Debug" | "Info" | "Warn" | "Error" | "Off"
export type LogFields = { [string]: unknown }

-- "App" is anything captured through Logger.emit() (a real logger:info/debug/etc call site).
-- "Engine" is a raw LogService line Shared/EngineLogCapture.lua fed in via CaptureEngineEntry --
-- Roblox's own script errors/warnings/prints, with no Scope/Fields of their own.
export type LogSource = "App" | "Engine"

-- One entry in the console capture buffer (Shared/Logger.lua). Sequence is a gapless, monotonically
-- increasing counter shared by every entry this VM has ever captured (App and Engine alike) -- the
-- ordering key GetBufferSnapshot's `sinceSequence` cursor and LiveConsoleSystem.lua's stream
-- batching both rely on.
export type LogEntry = {
	Sequence: number,
	TimestampUnix: number,
	Side: "Server" | "Client",
	Scope: string,
	Level: LogLevel,
	Message: string,
	Fields: LogFields?,
	Source: LogSource,
}

return LogTypes
