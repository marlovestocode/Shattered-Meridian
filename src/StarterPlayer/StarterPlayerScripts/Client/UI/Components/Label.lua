--!strict
--[[
	Label.lua

	Owns: text rendering against Tokens.lua's type scale -- every text surface picks one of the
	named scale steps (Display/Heading/Subheading/Body/Caption) rather than a one-off font size.

	TEXT CANNOT LEAVE ITS BOX (2026-08-20). A fixed-Size, non-wrapping TextLabel in Roblox does not
	clip: the glyphs simply keep drawing past the edge, and under TextXAlignment.Right they draw
	LEFTWARD out of the frame. That is not theoretical -- the character menu's Bloodlines row rendered
	"amberlane, gutterlight, stillwater_vein" straight out through the panel's left border and across
	the game world behind it. So any label that was given an explicit Size and is not wrapping now
	truncates with an ellipsis by default. This IS a behavior change for every existing caller, and
	deliberately so: a caller whose text no longer fits used to get an overflow bug that only showed
	up with real data, and now gets a visibly clipped string in the right place. Pass TextTruncate =
	Enum.TextTruncate.None to opt one label back out.

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
	-- Automatic on BOTH axes, from a ZERO base -- the mode this component could not express, and the
	-- one any label inside an AutomaticSize.X parent must use.
	--
	-- Omitting Size already gives AutomaticSize.XY, but from a base of `UDim2.fromScale(1, 0)`, and
	-- that scale-1 WIDTH is not neutral: AutomaticSize overrides the offset and leaves the scale, so
	-- the label resolves to `parent width + text width`. Inside a fixed-width parent that merely
	-- overhangs (usually invisibly, inside something that clips). Inside an AUTOMATICALLY-width-sized
	-- parent it is a feedback loop -- parent grows, so the child grows, so the parent grows -- which
	-- inflates until something clamps it, and what clamped it in practice was the viewport. That is
	-- exactly what happened to the hotbar's key legend on 2026-08-25: three short captions dragged a
	-- centred dock to full screen width, and through a second auto-sized ancestor, to full height too.
	--
	-- Strictly additive: every existing caller passes neither prop and keeps the original two branches
	-- verbatim.
	AutoWidth: boolean?,
	-- Overrides the automatic truncation described in this file's header. Omit for the default
	-- (AtEnd whenever a fixed Size is given and the label isn't wrapping); pass
	-- Enum.TextTruncate.None for a label that genuinely wants to overhang its box.
	TextTruncate: Enum.TextTruncate?,
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
	local wraps = props.TextWrapped or props.AutoHeight == true
	-- Only a fixed-width, single-line label can truncate meaningfully: an AutomaticSize label has no
	-- box to overflow, and a wrapping one already answers overflow by growing downward.
	local truncate = props.TextTruncate
		or (
			if props.Size ~= nil
					and not wraps
					and not props.AutoWidth
				then Enum.TextTruncate.AtEnd
				else Enum.TextTruncate.None
		)

	return scope:New "TextLabel" {
		Position = props.Position,
		AnchorPoint = props.AnchorPoint,
		Size = if props.AutoWidth then UDim2.fromOffset(0, 0) else (props.Size or UDim2.fromScale(1, 0)),
		AutomaticSize = if props.AutoWidth
			then Enum.AutomaticSize.XY
			elseif props.AutoHeight then Enum.AutomaticSize.Y
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
		TextWrapped = wraps,
		TextTruncate = truncate,
		LineHeight = props.LineHeight,
	} :: TextLabel
end

return Label
