--!strict
--[[
	BugReportClient.lua

	Owns: the local player's bug-report UX -- keybind toggle (resolved through
	Client/Input/KeybindManager.lua, same as CombatClient.lua/DevMenuClient.lua) and translating the
	BugReport screen's SubmitRequested signal into a BugReport_Submit RemoteFunction call. Unlike
	DevMenuClient.lua, this module runs for EVERY player -- there is no whitelist gate here; any
	player may open and submit this form.

	Does not own: submission validation (BugReportSystem.lua re-validates category/description
	server-side regardless of what this screen sent), or the form itself
	(UI/Screens/BugReport/init.lua) -- this module only drives that screen's handle from outside,
	the same "screen exposes state/signals, client module drives from outside" pattern
	DevMenuClient.lua already uses.
]]

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local Logger = require(ReplicatedStorage.Shared.Logger)

local BugReportModule = require(script.Parent.Parent.UI.Screens.BugReport)
local KeybindManager = require(script.Parent.Parent.Input.KeybindManager)
local RemoteInvoker = require(script.Parent.Parent.Network.RemoteInvoker)
local Chrome = require(script.Parent.Parent.UI.Shell.Chrome)

type BugReportHandle = BugReportModule.BugReportHandle

local peek = Fusion.peek

local logger = Logger.scope("BugReportClient")

local CONFIRMATION_CLEAR_DELAY = Constants.BugReport.ConfirmationClearDelaySeconds

local BugReportClient = {}

-- Same "InvokeServer errored or not, land on a message string" set of translations
-- DevMenuClient.describeResult-family functions already use, one per BugReportSubmitResult.Reason.
local function describeSubmitResult(result: Types.BugReportSubmitResult): string
	if result.Success then
		return "Report submitted. Thank you!"
	end
	if result.Reason == "CooldownActive" then
		return "You can submit another report again shortly."
	elseif result.Reason == "RateLimited" then
		return "Too many requests -- try again in a moment."
	elseif result.Reason == "InvalidCategory" then
		return "Please choose a category."
	elseif result.Reason == "TooShort" then
		return `Description is too short (min {Constants.BugReport.DescriptionMinLength} characters).`
	elseif result.Reason == "TooLong" then
		return `Description is too long (max {Constants.BugReport.DescriptionMaxLength} characters).`
	elseif result.Reason == "FilterFailed" then
		return "Couldn't process your text -- please try again."
	end
	return "Failed: " .. (result.Reason or "Unknown")
end

-- Same stale-timer guard DevMenuClient.setStatus uses -- a generation counter so a later message
-- can't be clobbered by an earlier one's delayed clear.
local statusGeneration = 0

local function setStatus(handle: BugReportHandle, message: string): ()
	statusGeneration += 1
	local generation = statusGeneration
	handle.StatusText:set(message)
	task.delay(CONFIRMATION_CLEAR_DELAY, function()
		if statusGeneration == generation then
			handle.StatusText:set("")
		end
	end)
end

function BugReportClient.Start(handle: BugReportHandle, chrome: Chrome.ChromeHandle): ()
	logger:info("BugReportClient.Start called")

	-- ADOPTED: this form had no Escape at all. The plan asked for a "is a TextBox focused?" check
	-- here first, so that Escape gives up on the description field before it throws the whole report
	-- away -- that check is real and it lives in Shell/Chrome.lua instead, because it is one rule
	-- about what Escape means rather than one form's quirk, and every other panel with a field in it
	-- (the move editor's name box, the dev menu's target field) needs the same answer.
	chrome:BindEscape("BugReport", handle.IsOpen, function()
		handle.IsOpen:set(false)
		logger:debug("Bug report form closed on Escape")
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if KeybindManager.Matches("OpenBugReport", input) then
			local nowOpen = not peek(handle.IsOpen)
			handle.IsOpen:set(nowOpen)
			logger:debug("Bug report form toggled", { open = nowOpen })
		end
	end)

	handle.SubmitRequested:Connect(function(category: string, description: string)
		logger:debug("SubmitRequested received", { category = category })
		handle.IsSubmitting:set(true)
		setStatus(handle, "Submitting...")

		local submitRemote = NetworkBridge.GetRemoteFunction(Constants.BugReport.RemoteNames.Submit)
		local ok, resultOrError = RemoteInvoker.Invoke(submitRemote, category, description)

		handle.IsSubmitting:set(false)

		if not ok then
			logger:error("Submit request errored", { errorMessage = tostring(resultOrError) })
			setStatus(handle, "Failed: request error")
			return
		end

		local result = resultOrError :: Types.BugReportSubmitResult
		logger:debug("Submit result received", { success = result.Success, reason = result.Reason })
		setStatus(handle, describeSubmitResult(result))

		if result.Success then
			handle.IsOpen:set(false)
		end
	end)

	logger:debug("BugReportClient bindings connected")
end

return BugReportClient
