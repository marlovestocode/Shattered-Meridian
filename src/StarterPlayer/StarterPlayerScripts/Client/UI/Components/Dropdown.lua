--!strict
--[[
	Dropdown.lua

	Owns: a closed-set string enum selector -- the one form-control shape no screen in this codebase
	needed before the Move Creation System's PropertyEditor (MoveDefinition.Shape: "Box"|"Sphere").

	Expands INLINE below its own trigger row (growing this component's own AutomaticSize.Y) rather
	than an absolutely-positioned floating popover -- the same choice Screens/DevMenu/Sidebar.lua's
	own overflowRow already made, for the same reason its header documents: this UI's ScreenGuis all
	use ZIndexBehavior.Sibling, which makes a floating popover's stacking order fragile against
	sibling content. A caller placing this inside a ScrollingFrame (the only place it's used today)
	gets the expanding list scrolled into view for free, with no popover-clipping edge case to
	handle.

	Small, fixed option counts only (Shape has exactly two) -- no search/filter/virtualization, per
	this component's own scope; a future caller with a large option set should extend this
	deliberately rather than assume it already scales.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local Selection = require(script.Parent.Selection)
local Label = require(script.Parent.Label)

local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type DropdownOption = {
	Value: string,
	Text: string,
}

export type DropdownProps = {
	Options: { DropdownOption },
	Value: UsedAs<string>,
	OnChanged: (string) -> (),
	Label: string?,
	LayoutOrder: UsedAs<number>?,
}

local ROW_HEIGHT = Tokens.Control.RowHeight

local function optionRow(
	scope: Scope,
	props: DropdownProps,
	option: DropdownOption,
	isExpanded: Fusion.Value<boolean>
): TextButton
	-- Pointer-over AND gamepad-selection, OR-ed into the single boolean every visual Computed
	-- below already reads as `isHovering` -- see Components/Selection.lua for why the two stay
	-- separate rather than both writing one Value.
	local engagement = Selection.New(scope)
	local isHovering = engagement.Active
	local isSelected = scope:Computed(function(use)
		return use(props.Value) == option.Value
	end)

	local backgroundColor = scope:Computed(function(use)
		if use(isSelected) then
			return Tokens.Wash.AccentFill.Color
		end
		return if use(isHovering) then Tokens.Color.SurfaceElevated else Tokens.Color.Surface
	end)
	local backgroundTransparency = scope:Computed(function(use)
		return if use(isSelected) then Tokens.Wash.AccentFill.Transparency else 0
	end)
	local textColor = scope:Computed(function(use)
		return if use(isSelected) then Tokens.Color.AccentPrimaryBright else Tokens.Color.TextPrimary
	end)

	return scope:New "TextButton" {
		Name = option.Value,
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
		BackgroundColor3 = backgroundColor,
		BackgroundTransparency = backgroundTransparency,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = "",

		[OnEvent "SelectionGained"] = function()
			engagement.Selected:set(true)
		end,
		[OnEvent "SelectionLost"] = function()
			engagement.Selected:set(false)
		end,
		[OnEvent "MouseEnter"] = function()
			engagement.PointerOver:set(true)
		end,
		[OnEvent "MouseLeave"] = function()
			engagement.PointerOver:set(false)
		end,
		[OnEvent "Activated"] = function()
			props.OnChanged(option.Value)
			isExpanded:set(false)
		end,

		[Children] = {
			scope:New "UICorner" { CornerRadius = Tokens.Radius.Sharp },
			Label(scope, {
				Text = option.Text,
				Scale = "BodyLarge",
				Color = textColor,
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, Tokens.Space.S, 0.5, 0),
				Size = UDim2.new(1, -Tokens.Space.S * 2, 1, 0),
			}),
		},
	} :: TextButton
end

local DropdownModule = {}

function DropdownModule.Mount(scope: Scope, props: DropdownProps): Frame
	local isExpanded = scope:Value(false)

	local triggerText = scope:Computed(function(use)
		local currentValue = use(props.Value)
		for _, option in ipairs(props.Options) do
			if option.Value == currentValue then
				return option.Text
			end
		end
		return currentValue
	end)

	local chevron = scope:Computed(function(use)
		return if use(isExpanded) then "\226\150\180" else "\226\150\188" -- filled up/down triangle
	end)

	-- Brighter/elevated while expanded -- docs/ui-ux-philosophy.md's own Borders rule ("higher
	-- importance: brighter edge highlight"), the same "this is the active thing" signal Tab.lua's own
	-- Selected state and Sidebar.lua's nav accent bar already use elsewhere in the Move Editor.
	local triggerBackgroundColor = scope:Computed(function(use)
		return if use(isExpanded) then Tokens.Color.SurfaceElevated else Tokens.Color.Surface
	end)
	local triggerBorderColor = scope:Computed(function(use)
		return if use(isExpanded) then Tokens.Border.Lit.Color else Tokens.Border.Standard.Color
	end)
	local triggerBorderTransparency = scope:Computed(function(use)
		return if use(isExpanded) then Tokens.Border.Lit.Transparency else Tokens.Border.Standard.Transparency
	end)

	local optionRows: { Instance } = {}
	for _, option in ipairs(props.Options) do
		table.insert(optionRows, optionRow(scope, props, option, isExpanded))
	end

	local children: { Instance } = {
		scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Left,
			Padding = UDim.new(0, Tokens.Space.XS),
			SortOrder = Enum.SortOrder.LayoutOrder,
		},
	}

	if props.Label then
		table.insert(
			children,
			Label(scope, {
				Text = props.Label :: string,
				Scale = "Body",
				Color = Tokens.Color.TextPrimary,
				LayoutOrder = 1,
			})
		)
	end

	table.insert(
		children,
		scope:New "TextButton" {
			Name = "Trigger",
			Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
			BackgroundColor3 = triggerBackgroundColor,
			BorderSizePixel = 0,
			AutoButtonColor = false,
			Text = "",
			LayoutOrder = 2,

			[OnEvent "Activated"] = function()
				isExpanded:set(not peek(isExpanded))
			end,

			[Children] = {
				scope:New "UICorner" { CornerRadius = Tokens.Radius.Sharp },
				scope:New "UIStroke" {
					Color = triggerBorderColor,
					Thickness = 1,
					Transparency = triggerBorderTransparency,
				},
				Label(scope, {
					Text = triggerText,
					Scale = "BodyLarge",
					Color = Tokens.Color.TextPrimary,
					AnchorPoint = Vector2.new(0, 0.5),
					Position = UDim2.new(0, Tokens.Space.S, 0.5, 0),
					Size = UDim2.new(1, -Tokens.Space.XL, 1, 0),
				}),
				Label(scope, {
					Text = chevron,
					Scale = "Detail",
					Color = Tokens.Color.TextSecondary,
					AnchorPoint = Vector2.new(1, 0.5),
					Position = UDim2.new(1, -Tokens.Space.S, 0.5, 0),
				}),
			},
		}
	)

	table.insert(
		children,
		scope:New "Frame" {
			Name = "Options",
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Visible = isExpanded,
			LayoutOrder = 3,
			ClipsDescendants = true,

			[Children] = {
				scope:New "UIListLayout" {
					FillDirection = Enum.FillDirection.Vertical,
					HorizontalAlignment = Enum.HorizontalAlignment.Left,
					SortOrder = Enum.SortOrder.LayoutOrder,
				},
				table.unpack(optionRows),
			},
		}
	)

	return scope:New "Frame" {
		Name = "Dropdown",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = props.LayoutOrder,

		[Children] = children,
	} :: Frame
end

return DropdownModule
