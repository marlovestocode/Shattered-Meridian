--!strict
--[[
	Menus.lua

	Owns: the mounted root for every heavier, non-combat surface named in ui-ux-philosophy.md's
	Menus category -- inventory/equipment, bloodline/art trees, faction/hierarchy boards,
	lobby/loadout. Most of those panels still depend on a server System that's an empty Init()
	(BloodlineManager, ArtTreeManager, FactionManager, PlayerDataSystem's inventory slice), so
	building their content would still mean fabricating data that doesn't exist. What's real here is
	the mount point, the open/closed state every future panel plugs into, and -- as of BountySystem
	going live -- one panel with genuine server data behind it.

	Reachable via the M key (the InputBegan handler below). This file's header previously described
	the screen as "deliberately unreachable... IsOpen has no driver," which had stopped being true:
	the keybind below already existed, and the stated reason for keeping it unreachable (no panel had
	real content, so opening it would show an empty gray box) no longer holds now that BountyMenu
	renders live Notoriety bounties. The remaining shortcut is that this is still a raw
	UserInputService listener rather than a Types.KeybindAction routed through a MenusClient.lua --
	that IS still worth doing (it's what makes the key rebindable, like every other real action), and
	it's the next step here, not a settled decision.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Panel = require(script.Parent.Parent.Components.Panel)
local BountyMenu = require(script.BountyMenu)

local Children = Fusion.Children
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>

export type MenusHandle = {
	IsOpen: Fusion.Value<boolean>,
}

local Menus = {}

function Menus.Mount(scope: Scope, playerGui: PlayerGui): MenusHandle
	local isOpen = scope:Value(false)
	local function toggleMenu(): ()
		isOpen:set(not peek(isOpen))
	end

	UserInputService.InputBegan:Connect(function(inputObject, gameProcessedEvent)
		if gameProcessedEvent then
			return
		end

		if inputObject.KeyCode == Enum.KeyCode.M then
			toggleMenu()
		end
	end)

	local bountyMenu = BountyMenu.Mount(scope, 380, 420)

	scope:New "ScreenGui" {
		Name = "Menus",
		ResetOnSpawn = false,
		Enabled = isOpen,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = playerGui,

		-- Panel's default (non-Elevated, non-CornerAccent) shape is exactly this surface/border/
		-- corner-radius contract, so this composes it instead of hand-rolling the same three
		-- instances every other Screen already gets from Components/Panel.lua.
		[Children] = Panel(scope, {
			Name = "Root",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0.7, 0.8),
			Children = {
				bountyMenu,
			},
		}),
	}

	return {
		IsOpen = isOpen,
	}
end

return Menus
