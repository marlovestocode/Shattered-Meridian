--!strict
--[[
	ModalScreen.lua

	Owns: the ScreenGui > centered elevated Panel shell every top-level admin/menu screen in this UI
	mounts itself into -- DevMenu, LiveConsole, MoveEditor, BugReport, Menus (the Character Menu), and
	Settings all hand-built the identical six-property ScreenGui plus the identical AnchorPoint/
	Position/Elevated/CornerAccent Panel plus the identical Tokens.Space.L UIPadding/Tokens.Space.M
	vertical UIListLayout wrapper before this existed -- ~15 lines duplicated six times, per the
	structure audit that found it (2026-08-19).

	Callers pass their own Header/Body/Footer (or equivalent) as Children; this component owns
	everything OUTSIDE that content, never what's inside it. Returns the Root Panel Instance, not the
	ScreenGui, because two of the six callers (BugReport/Menus) need it afterward for their own
	gamepad-focus `GuiService.SelectedObject:IsDescendantOf(root)` check -- the ScreenGui itself is
	never referenced again by any caller once mounted.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local Panel = require(script.Parent.Panel)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type ModalScreenProps = {
	Name: string,
	Size: UsedAs<UDim2>,
	-- BugReport.lua's Root is the one caller sized by content (fromOffset(WIDTH, 0) + AutomaticSize.Y)
	-- rather than a fixed (width, height) -- every other caller omits this.
	AutomaticSize: Enum.AutomaticSize?,
	IsOpen: UsedAs<boolean>,
	Children: UsedAs<{ any }>?,
}

local function ModalScreen(scope: Scope, playerGui: PlayerGui, props: ModalScreenProps): Frame
	local root = Panel(scope, {
		Name = "Root",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = props.Size,
		AutomaticSize = props.AutomaticSize,
		Elevated = true,
		CornerAccent = true,

		Children = {
			scope:New "UIPadding" {
				PaddingTop = UDim.new(0, Tokens.Space.L),
				PaddingBottom = UDim.new(0, Tokens.Space.L),
				PaddingLeft = UDim.new(0, Tokens.Space.L),
				PaddingRight = UDim.new(0, Tokens.Space.L),
			},
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Left,
				Padding = UDim.new(0, Tokens.Space.M),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			props.Children,
		},
	})

	scope:New "ScreenGui" {
		Name = props.Name,
		ResetOnSpawn = false,
		Enabled = props.IsOpen,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = playerGui,

		[Children] = root,
	}

	return root :: Frame
end

return ModalScreen
