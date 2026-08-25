--!strict
--[[
	StorybookClient.lua

	Owns: whether the component Storybook exists on this client at all, and the one key that toggles it.

	IT DECLINES TO DO ANYTHING OUTSIDE STUDIO, and that is the whole module. Start() returns before
	binding input if RunService:IsStudio() is false or Constants.Debug.Storybook.Enabled is off, so on a
	live client: F7 is never claimed, the Lazy is never forced, and the several hundred Instances that
	gallery builds are never built. That is a stronger guarantee than the three admin screens get --
	they bind for anyone and gate the CONTENTS server-side -- and it is the right one here for a reason
	those three don't share: an authoring reference has no player-facing behaviour to gate, so there is
	nothing lost by it not existing, and a component gallery is not a thing to hand a player at all.

	THE KEY IS RAW, not a Types.KeybindAction -- see Constants.Debug.Storybook.ToggleKeyCode's own
	comment for why (and for the F5/F6/F8 collision check it had to pass to earn F7).

	Deliberately thin. The Storybook has no server state, no remotes and nothing to drive -- unlike
	every other Client/*Client.lua module here, which exists to feed a screen the things the server
	owns. So this module is only the two things a screen genuinely cannot do for itself: decide whether
	it should exist, and hold the key that opens it. Everything else is in the screen.
]]

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Lazy = require(ReplicatedStorage.Shared.Lazy)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)

local StorybookModule = require(script.Parent.Parent.UI.Screens.Storybook)
local Chrome = require(script.Parent.Parent.UI.Shell.Chrome)

local peek = Fusion.peek

local logger = Logger.scope("StorybookClient")

local Config = Constants.Debug.Storybook

local StorybookClient = {}

-- `storybook` is a Lazy rather than a mounted handle for the same reason the three admin screens' are
-- (Client/UI/init.lua's header) -- except that here the force point is stricter still: the gate below
-- means most clients never reach the first Get() at all.
function StorybookClient.Start(storybook: Lazy.Lazy<StorybookModule.StorybookHandle>, chrome: Chrome.ChromeHandle): ()
	if not Config.Enabled then
		logger:debug("Storybook disabled by Constants.Debug.Storybook.Enabled")
		return
	end
	if not RunService:IsStudio() then
		-- Not a warning. This is the shipped path for every real player, and the log line exists only
		-- so a Studio session that somehow lands here can tell "gated off" from "key not working".
		logger:debug("Storybook not available outside Studio")
		return
	end

	local bound = false

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if input.KeyCode ~= Config.ToggleKeyCode then
			return
		end

		-- Forces the mount on the FIRST press, not at boot -- and reads open/closed back off the handle
		-- rather than tracking it here, which is safe in a way LiveConsoleClient's own `isOpen` field
		-- is not: there, a close had to be able to run without mounting a panel (it unsubscribes); here
		-- a close does nothing but set a flag, so there is no state to keep in step outside the handle.
		local handle = storybook:Get()
		if not bound then
			-- ADOPTED, and bound on the first force rather than at Start for the same reason
			-- LiveConsoleClient's is: there is no handle.IsOpen until the panel exists, and a panel
			-- that does not exist cannot be open. The flag is this module's own because Get() is
			-- idempotent but BindEscape is not -- two binds would mean two entries and two Escapes.
			bound = true
			chrome:BindEscape("Storybook", handle.IsOpen, function()
				handle.IsOpen:set(false)
				logger:debug("Storybook closed on Escape")
			end)
		end
		local nowOpen = not peek(handle.IsOpen)
		handle.IsOpen:set(nowOpen)
		logger:debug("Storybook toggled", { open = nowOpen })
	end)

	logger:info("StorybookClient started", { key = Config.ToggleKeyCode.Name })
end

return StorybookClient
