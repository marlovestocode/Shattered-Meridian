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

-- Only the UNTRACKED steps of Tokens.Type are namable here. The tracked ones (Micro/Eyebrow/Action/
-- Chip/Abbrev) carry a Tracking value that a single TextLabel physically cannot render -- Roblox has
-- no letter-spacing -- so they belong to Components/TrackedLabel.lua and are deliberately absent
-- from this union. Under --!strict that makes "tracked step passed to Label" a compile error rather
-- than a label that silently loses its tracking.
export type LabelScale =
	"Title"
	| "Heading"
	| "CardTitle"
	| "SerifInline"
	| "BodyLarge"
	| "Body"
	| "Detail"
	| "DetailEmphasis"
	| "NumeralLarge"
	| "Numeral"
	| "NumeralSmall"

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
	-- Wraps text across multiple lines instead of overflowing past Size's width -- off by default
	-- (matches every existing caller's fixed-width, single-line text), for the first caller with
	-- genuinely free-form, potentially-long text (Client/UI/Screens/Announcement/init.lua's admin-
	-- authored message).
	TextWrapped: boolean?,
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
		-- FontFace, not Font -- Tokens.Type carries a Font datatype now so the scale can express
		-- real weights and italic. Setting both properties on one instance is order-dependent, so
		-- this file sets exactly one.
		FontFace = scaleStep.Face,
		TextSize = scaleStep.Size,
		TextColor3 = props.Color or Tokens.Color.TextPrimary,
		TextTransparency = props.TextTransparency,
		TextStrokeColor3 = props.StrokeColor3,
		TextStrokeTransparency = props.StrokeTransparency,
		TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left,
		TextWrapped = props.TextWrapped or false,
	} :: TextLabel
end

return Label
