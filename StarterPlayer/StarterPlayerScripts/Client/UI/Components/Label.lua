--!strict
--[[
	Label.lua

	Owns: text rendering against Tokens.lua's type scale -- every text surface picks one of the
	named scale steps (Display/Heading/Subheading/Body/Caption) rather than a one-off font size.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type LabelScale = "Display" | "Heading" | "Subheading" | "Body" | "Caption"

export type LabelProps = {
	Text: UsedAs<string>,
	Scale: LabelScale?,
	Color: UsedAs<Color3>?,
	Position: UsedAs<UDim2>?,
	AnchorPoint: UsedAs<Vector2>?,
	Size: UsedAs<UDim2>?,
	LayoutOrder: UsedAs<number>?,
	TextXAlignment: Enum.TextXAlignment?,
	ZIndex: UsedAs<number>?,
	-- Decorative-only fade (e.g. a combat feedback entry easing in/out). Never gameplay-relevant on
	-- its own -- callers driving a real state change still gate visibility separately.
	TextTransparency: UsedAs<number>?,
	-- Native TextLabel outline (distinct from a UIStroke, which borders a Frame) -- for combat text
	-- that needs to stay readable over a busy background per ui-ux-philosophy.md's Combat Text
	-- section ("should never require reading effort").
	StrokeColor3: UsedAs<Color3>?,
	StrokeTransparency: UsedAs<number>?,
}

local function Label(scope: Scope, props: LabelProps): TextLabel
	local scaleStep = Tokens.Type[props.Scale or "Body"]

	return scope:New "TextLabel" {
		Position = props.Position,
		AnchorPoint = props.AnchorPoint,
		Size = props.Size or UDim2.fromScale(1, 0),
		AutomaticSize = if props.Size then Enum.AutomaticSize.None else Enum.AutomaticSize.XY,
		LayoutOrder = props.LayoutOrder,
		ZIndex = props.ZIndex,
		BackgroundTransparency = 1,
		Text = props.Text,
		Font = scaleStep.Font,
		TextSize = scaleStep.Size,
		TextColor3 = props.Color or Tokens.Color.TextPrimary,
		TextTransparency = props.TextTransparency,
		TextStrokeColor3 = props.StrokeColor3,
		TextStrokeTransparency = props.StrokeTransparency,
		TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left,
	} :: TextLabel
end

return Label
