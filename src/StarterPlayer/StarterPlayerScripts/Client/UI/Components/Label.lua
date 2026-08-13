--!strict
--[[
	Label.lua

	Owns: text rendering against Tokens.lua's type scale -- every text surface picks one of the
	named scale steps (Display/Heading/Subheading/Body/Caption) rather than a one-off font size.

	AutoHeight (2026-08-12) closes this component's one long-standing hole: it had no fixed-WIDTH,
	automatic-HEIGHT mode. Passing a Size switched AutomaticSize off entirely, so every caller with
	genuinely wrapped prose had to hand-count a pixel height and accept that a third line clipped --
	a tradeoff Section.lua's, PropertyEditor.lua's and HitboxEditor.lua's own headers each separately
	documented as accepted, across eight call sites at 30 or 32px. It is no longer accepted; those
	call sites now pass AutoHeight and let the text decide its own height.

	Both new props are strictly additive, and the proof matters because ~25 screens render through
	this file. Every pre-existing caller passes neither:
	  * props.AutoHeight is nil, so the AutomaticSize expression falls through to its original two
	    branches verbatim (Size given => None, else XY);
	  * `props.TextWrapped or props.AutoHeight == true` evaluates to `props.TextWrapped or false`,
	    which is exactly what the line said before;
	  * LineHeight = nil means the key is absent from the props table by Lua semantics, so
	    scope:New never touches the property and the instance keeps Roblox's own default of 1.
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
	-- Fixed WIDTH, automatic HEIGHT -- the mode this component never had (see file header). Pass a
	-- Size whose X is real and whose Y is ignored (`UDim2.new(1, 0, 0, 0)`) and the label grows
	-- downward to fit however many lines its text actually wraps to, instead of clipping at a
	-- hand-counted pixel height. Implies TextWrapped, since an auto-height label that doesn't wrap is
	-- just a one-line label the default already renders -- so a caller passing AutoHeight need not
	-- also pass TextWrapped.
	--
	-- Requires a parent that can resolve this label's WIDTH without first consulting its height: a
	-- fixed-offset or scale-sized Frame, or a UIListLayout child inside one. Inside an
	-- AutomaticSize.X parent the constraint is circular and Roblox collapses the height to zero --
	-- a platform limitation this prop cannot paper over, so don't reach for it there.
	AutoHeight: boolean?,
	-- Line spacing multiplier for wrapped prose -- Tokens.Leading.Prose, effectively always paired
	-- with AutoHeight above. Omit entirely for single-line text (see that token's own header on why
	-- leading lives in its own table rather than on Tokens.Type).
	LineHeight: UsedAs<number>?,
	-- Omit for the common case of an always-shown label. Roblox's own GuiObject.Visible default is
	-- true, so a caller that wants a reactively hidden/shown label MUST pass this explicitly -- there
	-- used to be no way to do that at all (this prop didn't exist, so a caller passing one anyway had
	-- it silently dropped, leaving the label permanently visible regardless of what it computed).
	Visible: UsedAs<boolean>?,
}

local function Label(scope: Scope, props: LabelProps): TextLabel
	local scaleStep = Tokens.Type[props.Scale or "Body"]

	return scope:New "TextLabel" {
		Position = props.Position,
		AnchorPoint = props.AnchorPoint,
		Size = props.Size or UDim2.fromScale(1, 0),
		AutomaticSize = if props.AutoHeight
			then Enum.AutomaticSize.Y
			elseif props.Size then Enum.AutomaticSize.None
			else Enum.AutomaticSize.XY,
		LayoutOrder = props.LayoutOrder,
		ZIndex = props.ZIndex,
		Visible = props.Visible,
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
		TextWrapped = props.TextWrapped or props.AutoHeight == true,
		LineHeight = props.LineHeight,
	} :: TextLabel
end

return Label
