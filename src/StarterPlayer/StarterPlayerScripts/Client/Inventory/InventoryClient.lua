--!strict
--[[
	InventoryClient.lua

	Owns: the local player's inventory UX -- the open/close keybind (KeybindManager.Matches("InventoryToggle",
	...), the same pattern CharacterMenuClient/SettingsClient use), Escape through Chrome, feeding the
	server's snapshots into the screen, and turning a confirmed Discard into a request and the server's
	answer into a status line.

	THE SERVER IS THE ONLY SOURCE OF WHAT THE PLAYER HOLDS. A snapshot is the whole inventory, so applying one
	is a replace, never a merge, and a discard changes nothing on screen until the next snapshot says so --
	there is no optimistic write to roll back. An out-of-order snapshot (older Revision than the last applied)
	is dropped: remotes of one kind arrive in order in practice, but a stale replace would silently resurrect
	items the player just discarded, so the cheap guard is kept.

	A SYNC ON START. The server pushes when the profile loads, which can be before this module connects its
	listener. Asking once (Inventory_Action "Sync") makes the first snapshot arrive regardless of boot order.

	Does not own: whether a discard is allowed (InventorySystem re-checks everything), the panel itself
	(UI/Screens/Inventory/init.lua), or any item's meaning (Shared/Inventory/ItemCatalog).
]]

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Logger = require(ReplicatedStorage.Shared.Logger)
local InventoryConstants = require(ReplicatedStorage.Shared.Inventory.InventoryConstants)
local ItemCatalog = require(ReplicatedStorage.Shared.Inventory.ItemCatalog)

local InventoryScreen = require(script.Parent.Parent.UI.Screens.Inventory)
local KeybindManager = require(script.Parent.Parent.Input.KeybindManager)
local RemoteInvoker = require(script.Parent.Parent.Network.RemoteInvoker)
local Chrome = require(script.Parent.Parent.UI.Shell.Chrome)

type InventoryHandle = InventoryScreen.InventoryHandle
type SnapshotPayload = InventoryConstants.SnapshotPayload
type ActionResult = InventoryConstants.ActionResult

local peek = Fusion.peek

local logger = Logger.scope("InventoryClient")

local STATUS_CLEAR_DELAY = 4

local InventoryClient = {}

-- Reason CODE -> the sentence a player reads. An unknown code falls through to itself rather than to a blank
-- status, so a new server-side refusal is visible instead of silent.
function InventoryClient.DescribeFailure(reason: string?): string
	if reason == "NotDiscardable" then
		return "That can't be discarded."
	elseif reason == "NotOwned" then
		return "You no longer hold that."
	elseif reason == "UnknownItem" then
		return "That item isn't recognised."
	elseif reason == "ProfileNotLoaded" then
		return "Your profile is still loading."
	elseif reason == "RateLimited" then
		return "Too many requests -- try again in a moment."
	end
	return "Failed: " .. (reason or "Unknown")
end

-- Whether `payload` is shaped like a snapshot. A Types annotation is not enforced across a remote, and a
-- malformed section should be dropped rather than reaching the screen's Computeds.
function InventoryClient.IsValidSnapshot(payload: unknown): boolean
	if typeof(payload) ~= "table" then
		return false
	end
	local candidate = payload :: { [string]: any }
	if typeof(candidate.Revision) ~= "number" or typeof(candidate.Sections) ~= "table" then
		return false
	end
	for _, section in candidate.Sections :: { any } do
		if typeof(section) ~= "table" then
			return false
		end
		local row = section :: { [string]: any }
		if
			typeof(row.Id) ~= "string"
			or typeof(row.Used) ~= "number"
			or typeof(row.Limit) ~= "number"
			or typeof(row.Entries) ~= "table"
		then
			return false
		end
		for _, entry in row.Entries :: { any } do
			if typeof(entry) ~= "table" then
				return false
			end
			local item = entry :: { [string]: any }
			if typeof(item.ItemId) ~= "string" or typeof(item.Count) ~= "number" then
				return false
			end
		end
	end
	return true
end

local statusGeneration = 0

local function setStatus(handle: InventoryHandle, message: string): ()
	statusGeneration += 1
	local generation = statusGeneration
	handle.StatusText:set(message)
	task.delay(STATUS_CLEAR_DELAY, function()
		-- Only the LATEST message clears itself -- see CharacterMenuClient.setStatus.
		if statusGeneration == generation then
			handle.StatusText:set("")
		end
	end)
end

function InventoryClient.Start(handle: InventoryHandle, chrome: Chrome.ChromeHandle): ()
	logger:info("InventoryClient.Start called")

	chrome:BindEscape("Inventory", handle.IsOpen, function()
		handle.IsOpen:set(false)
		logger:debug("Inventory closed on Escape")
	end)

	local snapshotRemote = NetworkBridge.GetRemoteEvent(InventoryConstants.RemoteNames.Snapshot)
	local actionRemote = NetworkBridge.GetRemoteFunction(InventoryConstants.RemoteNames.Action)

	local lastRevision = -1
	snapshotRemote.OnClientEvent:Connect(function(payload: unknown)
		if not InventoryClient.IsValidSnapshot(payload) then
			logger:warn("Malformed Inventory_Snapshot ignored", { payload = tostring(payload) })
			return
		end
		local snapshot = payload :: SnapshotPayload
		if snapshot.Revision <= lastRevision then
			return
		end
		lastRevision = snapshot.Revision
		handle.SetSnapshot(snapshot)
	end)

	-- A Discard the player confirmed. The screen already armed it (two presses), so this sends at once.
	handle.DiscardRequested:Connect(function(itemId: string, count: number)
		task.spawn(function()
			local ok, result = RemoteInvoker.Invoke(actionRemote, "Discard", itemId, count)
			if not ok then
				logger:warn("Discard failed", { itemId = itemId, error = tostring(result) })
				setStatus(handle, "Couldn't reach the server.")
				return
			end
			local action = result :: ActionResult
			if typeof(action) ~= "table" or not action.Success then
				local reason = if typeof(action) == "table" then action.Reason else nil
				setStatus(handle, InventoryClient.DescribeFailure(reason))
				return
			end
			local def = ItemCatalog.Resolve(itemId)
			local name = if def then def.DisplayName else itemId
			setStatus(handle, `Discarded {action.Removed or count} {name}.`)
		end)
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if KeybindManager.Matches("InventoryToggle", input) then
			local nowOpen = not peek(handle.IsOpen)
			handle.IsOpen:set(nowOpen)
			logger:debug("Inventory toggled", { open = nowOpen })
		end
	end)

	-- Ask for the snapshot once, ahead of any open -- see this file's header.
	task.spawn(function()
		local ok, result = RemoteInvoker.Invoke(actionRemote, "Sync", "", 0)
		if not ok then
			logger:warn("Inventory sync failed", { error = tostring(result) })
			return
		end
		local action = result :: ActionResult
		if typeof(action) == "table" and not action.Success then
			-- "ProfileNotLoaded" is ordinary this early; the server pushes when the profile arrives.
			logger:debug("Inventory sync declined", { reason = tostring(action.Reason) })
		end
	end)

	logger:debug("InventoryClient bindings connected")
end

return InventoryClient
