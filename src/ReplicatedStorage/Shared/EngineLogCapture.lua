--!strict
--[[
	EngineLogCapture.lua

	Owns: feeding Roblox's own engine-level output (LogService) into Shared/Logger.lua's console
	capture buffer, tagged Source = "Engine" -- script errors, deprecation warnings, and any raw
	print()/warn() call anywhere in this VM that Logger.lua's own emit() never sees directly (it
	only sees calls that go through Logger.scope(...):info/warn/etc). This is what lets the Live
	Admin Console (Server/Systems/LiveConsoleSystem.lua, Client/DevTools/LiveConsole/LiveConsoleClient.lua)
	show genuine live-server errors even though Logger.lua's own structured logging never prints
	outside Studio by design -- LogService.MessageOut fires regardless of IsStudio, which is exactly
	why this module hooks LogService instead of Logger.lua's own print/warn calls.

	Runs once per VM (Main.server.lua calls Init() for the server's own connection, Main.client.lua
	calls it again for each client's own) -- each side only ever sees its OWN Output, which is the
	correct scope: a server has no way to see a client's local Output, and this module doesn't try
	to bridge that. "My Client" in the console UI is exactly this VM-local capture, nothing more.

	Dedup (two layers, see onMessageOut below): LogService.MessageOut echoes every print()/warn()
	call made in this VM, INCLUDING Logger.lua's own (whenever its Enabled+IsStudio gate lets one
	through) -- without a way to recognize those, every one of THIS module's own lines would be
	captured twice: once directly by Logger.lua's own captureEntry, once again here via the echo.
	Logger.IsSuppressingOwnOutput() covers the live case (true for the exact duration of Logger's
	own print/warn call); a prefix check on Logger.lua's own distinctive "[t=<seconds>]..." line
	format covers GetLogHistory()'s seed pass below, which replays lines that were never a live
	MessageOut firing and so never had that flag up.

	Does not own: what the console does with a captured line (LiveConsoleSystem.lua/
	LiveConsoleClient.lua), or Logger.lua's own App-sourced capture path (emit()/captureEntry) --
	this module only ever calls Logger.CaptureEngineEntry, never reaches into Logger's internals.
]]

local LogService = game:GetService("LogService")

local Logger = require(script.Parent.Logger)

local logger = Logger.scope("EngineLogCapture")

local EngineLogCapture = {}

local connected = false

local function messageTypeToLevel(messageType: Enum.MessageType): Logger.LogLevel
	if messageType == Enum.MessageType.MessageError then
		return "Error"
	elseif messageType == Enum.MessageType.MessageWarning then
		return "Warn"
	end
	-- MessageOutput (a plain print) and MessageInfo both read as ordinary informational output --
	-- neither is a problem the console needs to visually distinguish from the other.
	return "Info"
end

local function onMessageOut(message: string, messageType: Enum.MessageType): ()
	if Logger.IsSuppressingOwnOutput() then
		return
	end
	-- Belt-and-suspenders against the flag above -- see this file's own header on why the seed pass
	-- below needs a second dedup layer. Logger.lua's formatLine always starts a line
	-- "[t=<seconds>]...", a prefix nothing else in this codebase produces.
	if message:sub(1, 3) == "[t=" then
		return
	end
	Logger.CaptureEngineEntry(messageTypeToLevel(messageType), message)
end

-- Idempotent -- Main.server.lua/Main.client.lua each call this once at boot, but a defensive
-- second call (e.g. a future module requiring this one directly) must never double-connect.
function EngineLogCapture.Init(): ()
	if connected then
		return
	end
	connected = true

	-- Seed from whatever this VM already logged before this module got a chance to connect (a
	-- boot-time script error especially) -- GetLogHistory returns every line still retained since
	-- this VM started, oldest first.
	for _, entry in ipairs(LogService:GetLogHistory()) do
		onMessageOut(entry.message, entry.messageType)
	end

	LogService.MessageOut:Connect(onMessageOut)

	logger:info("EngineLogCapture connected")
end

return EngineLogCapture
