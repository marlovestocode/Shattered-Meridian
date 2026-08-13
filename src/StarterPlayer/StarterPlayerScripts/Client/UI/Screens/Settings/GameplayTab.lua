--!strict
--[[
	Settings/GameplayTab.lua

	Owns: the Settings panel's Gameplay tab -- currently just the Autorun toggle, structured as its
	own file (rather than inlined into init.lua) specifically so the next non-keybind preference is a
	trivial addition here, not a reason to touch init.lua's own shell layout.

	Same "screen exposes state/signals, client module drives from outside" precedent as
	KeybindsTab.lua: this component owns no persistence of its own -- toggling calls
	props.OnAutorunToggled, and Client/Settings/SettingsClient.lua decides what actually happens
	(hand the flag to CombatClient.SetAutoSprint, persist it).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Toggle = require(script.Parent.Parent.Parent.Components.Toggle)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type GameplayTabProps = {
	Width: number,
	Height: number,
	Visible: UsedAs<boolean>,
	LayoutOrder: UsedAs<number>?,
	Autorun: Fusion.Value<boolean>,
	OnAutorunToggled: (enabled: boolean) -> (),
}

local function GameplayTab(scope: Scope, props: GameplayTabProps): Frame
	return scope:New "Frame" {
		Name = "GameplayTab",
		Size = UDim2.fromOffset(props.Width, props.Height),
		BackgroundTransparency = 1,
		Visible = props.Visible,
		LayoutOrder = props.LayoutOrder,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Left,
				Padding = UDim.new(0, Tokens.Space.S),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			Toggle(scope, {
				Label = "Autorun (sprint without holding Sprint)",
				Value = props.Autorun,
				OnChanged = props.OnAutorunToggled,
				LayoutOrder = 1,
			}),
		},
	} :: Frame
end

return GameplayTab
