--!strict
--[[
	HoverLabel.lua

	Owns: a small, text-only hover label for icon-only controls. It was written for the admin roster's
	ActionIcon (Kick/Ban/Mute/FlagSuspected/Overflow), whose accessible `Text` label rendered fully
	transparent for screen-reader/gamepad-nav purposes only, so a sighted mouse user never saw it on
	hover. ActionIcon.lua lost its last caller in the admin-panel rebuild and was deleted (2026-10-25 audit, A1): THIS
	COMPONENT HAS NO CALLER IN THE TREE TODAY. It is kept as the tooltip for the next icon-only control,
	and the anchor-wiring notes below describe how ActionIcon used it. It's deliberately a
	SCOPED-DOWN tooltip: a plain Surface tile with a Tokens.Border.Standard edge + Caption text,
	faded in with the same one-shot entrance convention StatusBanner/PostureBreakBanner already use
	(Tokens.Motion.FadeSpring). No rich styling, no elaborate transitions, no premium visual treatment.

	Does not own hover-tracking -- callers pass their own existing hover Value (a control's Selection.Active
	is the natural one) as Visible. This file never starts its own MouseEnter/MouseLeave listeners;
	reusing an existing Value is the whole point.

	Positioning: parented as a CHILD of the anchor control (this codebase has no shared overlay/root
	layer to parent a floating tooltip into, and building one would be exactly the kind of
	viewport-aware-positioning infrastructure the scoped-down version of this component was asked to
	skip).
	Anchored above the control's top edge (AnchorPoint (0, 1), a fixed gap up) per the "above the
	anchor point, not below" requirement. Horizontal placement is nudged so the label doesn't render
	off the left/right edge of the viewport: the caller supplies AnchorPosition/AnchorSize (the
	anchor's own AbsolutePosition/AbsoluteSize -- wired with Fusion.Out on the anchor, a real
	existing Fusion 0.3 API), this tile sizes itself to its
	own text via AutomaticSize, reports its resolved width back through [Out "AbsoluteSize"], and
	math.clamps that against workspace.CurrentCamera.ViewportSize. This is the "basic math.clamp
	against viewport bounds" version, not a fully general tooltip-positioning system.

	Measured reactively (AutomaticSize + Fusion.Out) rather than predicted up-front, which is a
	deliberate change from the original TextService:GetTextSize call. GetTextSize's third parameter
	is typed Enum.Font and CANNOT accept the Font (FontFace) datatype Tokens.Type now carries -- and
	its modern replacement, GetTextBoundsAsync, YIELDS, which is not safe here: this function runs
	inside a scope:New tree build. Measuring after the fact sidesteps both. The tradeoff is one frame
	of a mispositioned label on first hover, before AbsoluteSize populates; that's invisible in
	practice because the tile fades in over Tokens.Motion.FadeSpring anyway and starts fully
	transparent.

	Known gap, not a design deviation: because this UI runs every ScreenGui at the default
	ZIndexBehavior.Sibling, a label wide enough to spill sideways into a neighboring control that comes
	later in that row's child order can be painted over by that neighbor. Short text (Kick/Ban/Mute/Flag
	Suspected Cheater/overflow, the labels it was written for) makes this a rare edge case -- fixing it for good
	would need the same shared-overlay-layer or ZIndexBehavior.Global change this file's positioning
	section already ruled out as over-scope.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local Label = require(script.Parent.Label)
local Inset = require(script.Parent.Inset)
local Fade = require(script.Parent.Fade)

local Children = Fusion.Children
local Out = Fusion.Out

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type HoverLabelProps = {
	-- Reuses the caller's own hover state -- see this file's header.
	Visible: UsedAs<boolean>,
	-- Plain string, not reactive -- matching the (deleted) ActionIcon's own non-reactive Text.
	Text: string,
	-- The anchor's own AbsolutePosition/AbsoluteSize in screen space -- see this file's header on
	-- how an anchor wires these via Fusion.Out.
	AnchorPosition: UsedAs<Vector2>,
	AnchorSize: UsedAs<Vector2>,
}

local GAP = Tokens.Space.XS
local PADDING_X = Tokens.Space.S
local PADDING_Y = Tokens.Space.XS / 2
local EDGE_MARGIN = Tokens.Space.XS

local function HoverLabel(scope: Scope, props: HoverLabelProps): Frame
	-- Fed by [Out "AbsoluteSize"] on the tile below once AutomaticSize has resolved it -- see this
	-- file's header for why the width is measured rather than precomputed. Starts at zero, which
	-- reads as "centered on the anchor, unclamped" for the one frame before it populates.
	local measuredSize = scope:Value(Vector2.new(0, 0))

	-- Horizontal offset (pixels, relative to the anchor's own left edge) that keeps the label
	-- centered above the anchor while clamping its GLOBAL screen position to stay on-screen.
	local offsetX = scope:Computed(function(use)
		local anchorPosition = use(props.AnchorPosition)
		local anchorSize = use(props.AnchorSize)
		local labelWidth = use(measuredSize).X
		local camera = Workspace.CurrentCamera
		local viewportWidth = if camera then camera.ViewportSize.X else anchorPosition.X + anchorSize.X + labelWidth

		local desiredCenterX = anchorPosition.X + anchorSize.X / 2
		local halfLabel = labelWidth / 2
		local minCenterX = halfLabel + EDGE_MARGIN
		local maxCenterX = math.max(minCenterX, viewportWidth - halfLabel - EDGE_MARGIN)
		local clampedCenterX = math.clamp(desiredCenterX, minCenterX, maxCenterX)

		return (clampedCenterX - halfLabel) - anchorPosition.X
	end)

	-- Decorative fade-in only -- see Components/Fade.lua for the presence-is-instant split.
	local fade = Fade.New(scope, props.Visible)
	local contentTransparency = fade.Transparency

	-- The border composes the fade-in with Tokens.Border.Standard's own translucency (rather than
	-- drawing it fully opaque at rest) -- alpha-multiply the two so a fully-shown tooltip still gets
	-- the same hairline weight every other panel edge uses, and a hidden one still reaches fully
	-- transparent.
	local borderTransparency = scope:Computed(function(use)
		local standardAlpha = 1 - Tokens.Border.Standard.Transparency
		return 1 - use(fade.Alpha) * standardAlpha
	end)

	return scope:New "Frame" {
		Name = "HoverLabel",
		AnchorPoint = Vector2.new(0, 1),
		Position = scope:Computed(function(use)
			return UDim2.fromOffset(use(offsetX), -GAP)
		end),
		-- Zero size + AutomaticSize.XY: the tile is exactly its text plus UIPadding, and reports that
		-- resolved width back through [Out "AbsoluteSize"] for offsetX above.
		Size = UDim2.fromOffset(0, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
		Visible = props.Visible,
		BackgroundColor3 = Tokens.Color.Surface,
		BorderSizePixel = 0,
		ZIndex = 5,

		[Out "AbsoluteSize"] = measuredSize,

		[Children] = {
			scope:New "UICorner" {
				CornerRadius = Tokens.Radius.Sharp,
			},
			scope:New "UIStroke" {
				Color = Tokens.Border.Standard.Color,
				Thickness = 1,
				Transparency = borderTransparency,
			},
			Inset(scope, { X = PADDING_X, Y = PADDING_Y }),
			-- No Size prop -- Label.lua switches to AutomaticSize.XY when Size is nil, which is what
			-- drives the tile's own AutomaticSize above. Giving it a Size here would collapse both.
			Label(scope, {
				Text = props.Text,
				Scale = "Detail",
				Color = Tokens.Color.TextPrimary,
				TextTransparency = contentTransparency,
				TextXAlignment = Enum.TextXAlignment.Center,
				ZIndex = 6,
			}),
		},
	} :: Frame
end

return HoverLabel
