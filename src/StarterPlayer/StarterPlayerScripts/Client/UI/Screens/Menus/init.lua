--!strict
--[[
	Menus.lua

	Owns: the mounted root for every heavier, non-combat surface named in ui-ux-philosophy.md's
	Menus category -- inventory/equipment, bloodline/art trees, faction/hierarchy boards,
	lobby/loadout. Starts empty and hidden: each of those panels depends on a server System that's
	still an empty Init() (BloodlineManager, ArtTreeManager, FactionManager, PlayerDataSystem's
	inventory slice), so building their content now would mean fabricating data that doesn't
	exist. What's real here is the mount point and the open/closed state every future menu panel
	plugs into.

	Deliberately unreachable right now: IsOpen has no driver -- no Types.KeybindAction opens this
	screen and no client module ever sets IsOpen true. This is intentional, not a forgotten wiring
	step: with no menu panel having any real content to show yet (see above), wiring a keybind today
	would only ever open an empty gray box. Wire a keybind + a MenusClient.lua (mirroring
	DevMenuClient.lua's shape) once at least one panel here has real content to gate behind it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Panel = require(script.Parent.Parent.Components.Panel)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>

export type MenusHandle = {
	IsOpen: Fusion.Value<boolean>,
}

local Menus = {}

function Menus.Mount(scope: Scope, playerGui: PlayerGui): MenusHandle
	local isOpen = scope:Value(false)

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
		}),
	}

	return {
		IsOpen = isOpen,
	}
end

return Menus
