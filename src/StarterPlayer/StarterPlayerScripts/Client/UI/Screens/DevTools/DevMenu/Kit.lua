--!strict
--[[
	DevMenu/Kit.lua

	Owns: the admin panel's layout vocabulary -- a bronze heading, a line of prose, a scrolling page, a
	row of equal buttons, a segmented choice, a labelled meter, a fact row. Every tab and both rails are
	lists of these, the way the Move Editor's tabs are lists of Fields calls, so the whole panel has
	one rhythm: heading, spacing, controls -- never a bordered card inside the panel's own border
	(ScreenFrame's header, and the first thing the old panel's Section-card stack got wrong).

	BUTTONS COME IN HOLDERS. Components/Button has no Visible of its own, and half the buttons here
	appear only for some targets (Kick is meaningless on yourself) -- so Kit.Button always returns a
	sized holder carrying Visible, with the button filling it.

	Does not own: the components themselves (Components/*) or anything a control does.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Constants = require(ReplicatedStorage.Shared.Constants)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local ArmedButtonComponent = require(script.Parent.Parent.Parent.Parent.Components.ArmedButton)
local Bar = require(script.Parent.Parent.Parent.Parent.Components.Bar)
local ButtonComponent = require(script.Parent.Parent.Parent.Parent.Components.Button)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local ScrollArea = require(script.Parent.Parent.Parent.Parent.Components.ScrollArea)
local SectionHeading = require(script.Parent.Parent.Parent.Parent.Components.SectionHeading)
local Stack = require(script.Parent.Parent.Parent.Parent.Components.Stack)
local StatRow = require(script.Parent.Parent.Parent.Parent.Components.StatRow)
local Tab = require(script.Parent.Parent.Parent.Parent.Components.Tab)

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

local Kit = {}

Kit.ButtonHeight = Tokens.Control.StepButtonSize
Kit.StatHeight = 26

-- The width of one of `count` equal cells in a row whose gap is Tokens.Space.S.
function Kit.Cell(count: number, height: number?): UDim2
	local gap = Tokens.Space.S
	return UDim2.new(1 / count, -gap * (count - 1) / count, 0, height or Kit.ButtonHeight)
end

function Kit.Heading(scope: Scope, text: string, order: number, visible: UsedAs<boolean>?, note: UsedAs<string>?): Frame
	return SectionHeading(scope, { Text = text, Note = note, LayoutOrder = order, Visible = visible })
end

-- One wrapped paragraph. Disabled colour by default: prose here explains, it is never the fact itself.
function Kit.Prose(
	scope: Scope,
	text: UsedAs<string>,
	order: number,
	visible: UsedAs<boolean>?,
	color: UsedAs<Color3>?
): Instance
	return Label(scope, {
		Text = text,
		Scale = "Detail",
		Color = color or Tokens.Color.TextDisabled,
		Size = UDim2.fromScale(1, 0),
		AutoHeight = true,
		TextWrapped = true,
		LineHeight = Tokens.Leading.Prose,
		LayoutOrder = order,
		Visible = visible,
	})
end

-- One tab's scrolling page: every tab is mounted up front and toggles its own Visible, so a tab keeps
-- its scroll position across a switch.
function Kit.Page(scope: Scope, name: string, visible: UsedAs<boolean>, children: { Instance }): ScrollingFrame
	local content: { Instance } = {
		scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, Tokens.Space.M),
		},
		scope:New "UIPadding" {
			PaddingTop = UDim.new(0, Tokens.Space.M),
			PaddingLeft = UDim.new(0, Tokens.Space.L),
			-- Clears the scroll bar, and lets the last control breathe above the footer band.
			PaddingRight = UDim.new(0, Tokens.Space.L),
			PaddingBottom = UDim.new(0, Tokens.Space.XL),
		},
	}
	for _, child in children do
		table.insert(content, child)
	end
	return ScrollArea(scope, {
		Name = name,
		Size = UDim2.fromScale(1, 1),
		Visible = visible,
		Children = content,
	})
end

-- A fixed-height horizontal run.
function Kit.Row(scope: Scope, order: number, children: { Instance }, visible: UsedAs<boolean>?, height: number?): Frame
	return Stack.Row(scope, {
		Size = UDim2.new(1, 0, 0, height or Kit.ButtonHeight),
		Gap = Tokens.Space.S,
		AlignY = Enum.VerticalAlignment.Center,
		LayoutOrder = order,
		Visible = visible,
		Children = children,
	})
end

-- A vertical group that sizes to its content -- for a block that shows or hides as one.
function Kit.Group(scope: Scope, order: number, children: { Instance }, visible: UsedAs<boolean>?, gap: number?): Frame
	return Stack.New(scope, {
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Gap = gap or Tokens.Space.M,
		LayoutOrder = order,
		Visible = visible,
		Children = children,
	})
end

-- Wraps a component that has no Visible of its own.
function Kit.Holder(scope: Scope, name: string, order: number, child: Instance, visible: UsedAs<boolean>?): Frame
	return scope:New "Frame" {
		Name = name,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = order,
		Visible = visible,
		[Fusion.Children] = child,
	} :: Frame
end

export type ButtonSpec = {
	Text: UsedAs<string>,
	Order: number,
	-- Defaults to the full width.
	Size: UDim2?,
	Disabled: UsedAs<boolean>?,
	Visible: UsedAs<boolean>?,
	OnActivated: () -> (),
}

-- The legacy button path (Variant nil) throughout: text and Disabled here are usually live, and a
-- Variant button reads its props once (Components/Button.lua).
function Kit.Button(scope: Scope, spec: ButtonSpec): Frame
	return scope:New "Frame" {
		Name = "Button",
		Size = spec.Size or UDim2.new(1, 0, 0, Kit.ButtonHeight),
		BackgroundTransparency = 1,
		LayoutOrder = spec.Order,
		Visible = spec.Visible,
		[Fusion.Children] = ButtonComponent(scope, {
			Text = spec.Text,
			Size = UDim2.fromScale(1, 1),
			Disabled = spec.Disabled,
			OnActivated = spec.OnActivated,
		}),
	} :: Frame
end

export type ArmedSpec = {
	Idle: UsedAs<string>,
	Armed: string,
	Order: number,
	Size: UDim2?,
	Disabled: UsedAs<boolean>?,
	Visible: UsedAs<boolean>?,
	OnConfirm: () -> (),
}

-- A two-press button for anything irreversible -- Components/ArmedButton on the panel's own window.
function Kit.Armed(scope: Scope, spec: ArmedSpec): Frame
	return ArmedButtonComponent(scope, {
		Idle = spec.Idle,
		Armed = spec.Armed,
		WindowSeconds = Constants.Debug.DevMenu.ConfirmWindowSeconds,
		Size = spec.Size or UDim2.new(1, 0, 0, Kit.ButtonHeight),
		LayoutOrder = spec.Order,
		Disabled = spec.Disabled,
		Visible = spec.Visible,
		OnConfirm = spec.OnConfirm,
	})
end

export type Option = { Value: string, Text: string }

export type SegmentedSpec = {
	Options: { Option },
	Selected: UsedAs<string?>,
	OnPick: (value: string) -> (),
	Order: number,
	Visible: UsedAs<boolean>?,
}

-- A row of mutually exclusive chips, one per option, equal widths.
function Kit.Segmented(scope: Scope, spec: SegmentedSpec): Frame
	local cells: { Instance } = {}
	for index, option in spec.Options do
		table.insert(
			cells,
			Tab(scope, {
				Text = option.Text,
				Selected = scope:Computed(function(use)
					return use(spec.Selected) == option.Value
				end),
				Size = Kit.Cell(#spec.Options),
				LayoutOrder = index,
				OnActivated = function()
					spec.OnPick(option.Value)
				end,
			})
		)
	end
	return Kit.Row(scope, spec.Order, cells, spec.Visible)
end

export type MeterSpec = {
	Caption: string,
	Value: UsedAs<number>,
	Max: UsedAs<number>,
	-- The right-aligned readout ("123 / 500").
	Text: UsedAs<string>,
	Color: Color3,
	CriticalBelow: number?,
	Order: number,
	Visible: UsedAs<boolean>?,
}

local METER_BAR_HEIGHT = 6

-- A caption and a readout over a thin bar -- a vital, a guard pool, progress through a tier.
function Kit.Meter(scope: Scope, spec: MeterSpec): Frame
	return Stack.New(scope, {
		Name = `Meter_{spec.Caption}`,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Gap = Tokens.Space.XS,
		LayoutOrder = spec.Order,
		Visible = spec.Visible,
		Children = {
			scope:New "Frame" {
				Name = "Caption",
				Size = UDim2.new(1, 0, 0, Tokens.Type.Detail.Size + Tokens.Space.XS),
				BackgroundTransparency = 1,
				LayoutOrder = 1,
				[Fusion.Children] = {
					Label(scope, {
						Text = spec.Caption,
						Scale = "Detail",
						Color = Tokens.Color.TextSecondary,
						Size = UDim2.fromScale(0.5, 1),
					}),
					Label(scope, {
						Text = spec.Text,
						Scale = "NumeralSmall",
						Color = Tokens.Color.TextPrimary,
						AnchorPoint = Vector2.new(1, 0),
						Position = UDim2.fromScale(1, 0),
						Size = UDim2.fromScale(0.5, 1),
						TextXAlignment = Enum.TextXAlignment.Right,
					}),
				},
			},
			Bar(scope, {
				Value = spec.Value,
				Max = spec.Max,
				FillColor = spec.Color,
				FillColorSecondary = spec.Color,
				CriticalBelow = spec.CriticalBelow,
				Size = UDim2.new(1, 0, 0, METER_BAR_HEIGHT),
				LayoutOrder = 2,
			}),
		},
	})
end

-- One caption/value fact.
function Kit.Stat(
	scope: Scope,
	caption: string,
	value: UsedAs<string>,
	order: number,
	visible: UsedAs<boolean>?,
	valueColor: UsedAs<Color3>?
): Frame
	return StatRow(scope, {
		Caption = caption,
		Value = value,
		ValueColor = valueColor,
		Size = UDim2.new(1, 0, 0, Kit.StatHeight),
		LayoutOrder = order,
		Visible = visible,
	})
end

-- Two cells side by side, each half the width, top-aligned.
function Kit.Pair(scope: Scope, order: number, left: Instance, right: Instance, visible: UsedAs<boolean>?): Frame
	local function cell(cellOrder: number, child: Instance): Frame
		return scope:New "Frame" {
			Name = "Cell",
			Size = UDim2.new(0.5, -Tokens.Space.M / 2, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = cellOrder,
			[Fusion.Children] = child,
		} :: Frame
	end
	return Stack.Row(scope, {
		Name = "Pair",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Gap = Tokens.Space.M,
		AlignY = Enum.VerticalAlignment.Top,
		Visible = visible,
		LayoutOrder = order,
		Children = { cell(1, left), cell(2, right) },
	})
end

return Kit
