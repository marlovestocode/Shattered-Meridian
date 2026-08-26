--!strict
--[[
	HoverLabel.lua

	Owns: a small, text-only hover label for icon-only controls -- ActionIcon.lua's Kick/Ban/Mute/
	FlagSuspected/Overflow buttons already carry a real accessible `Text` label (see that file's own
	header) that renders fully transparent for screen-reader/gamepad-nav purposes only. Nothing ever
	showed that text to a sighted mouse user on hover -- this is the fix, and it's deliberately a
	SCOPED-DOWN tooltip: a plain Surface tile with a Tokens.Border.Standard edge + Caption text,
	faded in with the same one-shot entrance convention StatusBanner/PostureBreakBanner already use
	(Tokens.Motion.FadeSpring). No rich styling, no elaborate transitions, no premium visual treatment.

	Does not own hover-tracking -- callers pass their own existing hover Value (e.g. ActionIcon.lua's
	isHovering) as Visible. This file never starts its own MouseEnter/MouseLeave listeners; reusing
	an existing Value is the whole point (ActionIcon.lua already had isHovering going unused outside
	its own background/border color Computeds).

	Positioning: parented as a CHILD of the anchor control (this codebase has no shared overlay/root
	layer to parent a floating tooltip into, and building one would be exactly the kind of
	viewport-aware-positioning infrastructure the scoped-down version of this component was asked to
	skip -- see ActionIcon.lua's own header for the same tradeoff made for its overflow reveal).
	Anchored above the control's top edge (AnchorPoint (0, 1), a fixed gap up) per the "above the
	anchor point, not below" requirement. Horizontal placement is nudged so the label doesn't render
	off the left/right edge of the viewport: the caller supplies AnchorPosition/AnchorSize (the
	anchor's own AbsolutePosition/AbsoluteSize -- wired via Fusion.Out in ActionIcon.lua, a real
	existing Fusion 0.3 API this codebase just hadn't needed before), this tile sizes itself to its
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
	ZIndexBehavior.Sibling (see ActionIcon.lua's header for the same constraint), a label wide enough
	to spill sideways into a neighboring ActionIcon that comes later in that row's child order can be
	painted over by that neighbor. Every current caller's text (Kick/Ban/Mute/Flag Suspected Cheater/
	overflow) is short enough that this is a rare edge case, not a common one -- fixing it for good
	would need the same shared-overlay-layer or ZIndexBehavior.Global change this file's positioning
	section already ruled out as over-scope.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local Label = require(script.Parent.Label)
local Inset = require(script.Parent.Inset)

local Children = Fusion.Children
local Out = Fusion.Out

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type HoverLabelProps = {
	-- Reuses the caller's own hover state -- see this file's header.
	Visible: UsedAs<boolean>,
	-- Plain string, not reactive -- matches ActionIconProps.Text's own (non-reactive) shape, the
	-- only current caller.
	Text: string,
	-- The anchor's own AbsolutePosition/AbsoluteSize in screen space -- see this file's header on
	-- how ActionIcon.lua wires these via Fusion.Out.
	AnchorPosition: UsedAs<Vector2>,
	AnchorSize: UsedAs<Vector2>,
}

local GAP = Tokens.Space.XS
local PADDING_X = Tokens.Space.S
local PADDING_Y = Tokens.Space.XS / 2
local EDGE_MARGIN = Tokens.Space.XS

local FADE_SPRING_SPEED = Tokens.Motion.FadeSpring.Speed
local FADE_SPRING_DAMPING = Tokens.Motion.FadeSpring.Damping

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

	-- Decorative fade-in only -- Visible below stays an instant, unsmoothed boolean gate (same
	-- split StatusBanner uses: presence is instant, the border/text transparency is what eases).
	local fadeIn = scope:Spring(
		scope:Computed(function(use)
			return if use(props.Visible) then 1 else 0
		end),
		FADE_SPRING_SPEED,
		FADE_SPRING_DAMPING
	)

	local contentTransparency = scope:Computed(function(use)
		return 1 - use(fadeIn)
	end)

	-- The border composes the fade-in with Tokens.Border.Standard's own translucency (rather than
	-- drawing it fully opaque at rest) -- alpha-multiply the two so a fully-shown tooltip still gets
	-- the same hairline weight every other panel edge uses, and a hidden one still reaches fully
	-- transparent.
	local borderTransparency = scope:Computed(function(use)
		local standardAlpha = 1 - Tokens.Border.Standard.Transparency
		return 1 - use(fadeIn) * standardAlpha
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
