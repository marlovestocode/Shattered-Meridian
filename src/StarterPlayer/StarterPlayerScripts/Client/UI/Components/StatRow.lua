--!strict
--[[
	StatRow.lua

	Owns: the "caption on the left, number on the right" line -- the single most repeated shape in
	the character menu. It appeared as a hand-rolled two-Label Frame in CharacterTab (statLine),
	again in the identity rail's standing list, and again as the derived-stat grid's cells, with the
	three copies disagreeing about row height, label color and value scale.

	Two variants, and they are genuinely different objects rather than a styling toggle:

	- "Hairline" (default): a bare line closed by a 1px rule underneath. Used where rows stack into a
	  continuous list and the rule is what separates them -- the rule IS the row's only chrome.
	- "Framed": a small filled, bordered cell. Used where rows sit in a grid, where a shared bottom
	  rule would read as an accidental table edge instead of a separator.

	The caption is a plain string, not reactive: every call site names a fixed quantity ("Max Qi",
	"Rerolls left") and the thing that moves is the value beside it. Keeping it non-reactive is what
	lets a future caller render it through TrackedLabel without hitting that component's
	read-once limitation.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local Label = require(script.Parent.Label)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type StatRowProps = {
	-- Fixed caption -- see file header on why this one is not reactive.
	Caption: string,
	Value: UsedAs<string>,
	-- Defaults to "Hairline". See file header.
	Variant: ("Hairline" | "Framed")?,
	CaptionColor: UsedAs<Color3>?,
	ValueColor: UsedAs<Color3>?,
	Size: UsedAs<UDim2>?,
	LayoutOrder: UsedAs<number>?,
	Visible: UsedAs<boolean>?,
}

-- Both grew with the 2026-08-20 type pass (Detail 11 -> 12, Numeral 13 -> 14): a row sized to the
-- old step left the new one touching its own rule.
local HAIRLINE_HEIGHT = 28
local FRAMED_HEIGHT = 32
local FRAMED_PADDING_X = 10

local function StatRow(scope: Scope, props: StatRowProps): Frame
	local framed = props.Variant == "Framed"
	-- A framed cell is a CONTAINER and takes the panel-edge tint; a hairline row's rule is a
	-- separator between two things in one list and stays at the fainter inset tint. Same 1px, two
	-- different jobs -- the user asked for containers that are actually visible as containers
	-- (2026-08-20), and a grid of cells outlined at 9% was not one.
	local border = if framed then Tokens.Border.Standard else Tokens.Border.Hairline

	local children: { Instance } = {
		Label(scope, {
			Text = props.Caption,
			Scale = "Detail",
			Color = props.CaptionColor or Tokens.Color.TextSecondary,
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.fromScale(0, 0.5),
			-- Stops a long caption from running underneath the value on the right. The reserved
			-- width is the value column's own share; a caption that would overflow it truncates
			-- rather than colliding.
			Size = UDim2.fromScale(0.65, 1),
		}),
		Label(scope, {
			Text = props.Value,
			Scale = "Numeral",
			Color = props.ValueColor or Tokens.Color.TextPrimary,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.fromScale(1, 0.5),
			Size = UDim2.fromScale(0.35, 1),
			TextXAlignment = Enum.TextXAlignment.Right,
		}),
	}

	if framed then
		table.insert(
			children,
			scope:New "UIPadding" {
				PaddingLeft = UDim.new(0, FRAMED_PADDING_X),
				PaddingRight = UDim.new(0, FRAMED_PADDING_X),
			}
		)
		table.insert(
			children,
			scope:New "UIStroke" {
				Color = border.Color,
				Thickness = 1,
				Transparency = border.Transparency,
			}
		)
	else
		-- The separating rule. Drawn as this row's own bottom edge rather than as a sibling between
		-- rows, so a caller can hide one row (Visible = false) without leaving an orphaned rule
		-- behind it -- which is exactly what a shared sibling divider would do.
		table.insert(
			children,
			scope:New "Frame" {
				Name = "Rule",
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.fromScale(0, 1),
				Size = UDim2.new(1, 0, 0, Tokens.Control.DividerThickness),
				BackgroundColor3 = border.Color,
				BackgroundTransparency = border.Transparency,
				BorderSizePixel = 0,
			}
		)
	end

	return scope:New "Frame" {
		Name = `StatRow_{props.Caption}`,
		Size = props.Size or UDim2.new(1, 0, 0, if framed then FRAMED_HEIGHT else HAIRLINE_HEIGHT),
		LayoutOrder = props.LayoutOrder,
		Visible = props.Visible,
		BackgroundColor3 = Tokens.Color.SurfaceElevated,
		BackgroundTransparency = if framed then 0 else 1,
		BorderSizePixel = 0,

		[Children] = children,
	} :: Frame
end

return StatRow
