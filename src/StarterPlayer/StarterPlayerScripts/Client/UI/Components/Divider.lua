--!strict
--[[
	Divider.lua

	Owns: the 1px hairline rule used throughout the redesign's chrome -- step-rail connectors, card
	insets, row separators, header/footer seams, and the Origin screen's centred flourish. A 1px rule
	appears in >=5 distinct places in the Figma spec (docs/design/intro-redesign-figma-spec.md section
	3) and was hand-rolled at each call site before this; one primitive now, three shapes:

	- Plain: a flat rule at one Tint's color+transparency. The common case (card insets, row seams,
	  header/footer borders, the step rail's inter-step connector).
	- Gradient: the same rule but fading to fully transparent at one end via a UIGradient Transparency
	  NumberSequence -- see the Fade prop's own comment for why this only needs to range 0-1 rather
	  than re-encode the Tint's own Transparency a second time.
	- Flourish: the Origin header's centrepiece -- two mirrored Gradient rules meeting a small
	  45-degree-rotated diamond outline at the centre. The one non-hairline shape in this file, built
	  from Plain/Gradient rather than duplicating their geometry.

	Does not own: the step rail's own numbered-box geometry (Screens/Onboarding/StepRail.lua) or any
	panel border (Panel.lua's own UIStroke) -- this is for a rule that stands alone as its own
	Instance, not an edge of a container.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>
type Tint = Tokens.Tint

local Divider = {}

export type DividerPlainProps = {
	Size: UsedAs<UDim2>?,
	Position: UsedAs<UDim2>?,
	AnchorPoint: UsedAs<Vector2>?,
	LayoutOrder: UsedAs<number>?,
	Tint: Tint?,
}

function Divider.Plain(scope: Scope, props: DividerPlainProps): Frame
	local tint = props.Tint or Tokens.Border.Standard
	return scope:New "Frame" {
		Name = "Divider",
		Position = props.Position,
		AnchorPoint = props.AnchorPoint,
		Size = props.Size or UDim2.new(1, 0, 0, 1),
		LayoutOrder = props.LayoutOrder,
		BackgroundColor3 = tint.Color,
		BackgroundTransparency = tint.Transparency,
		BorderSizePixel = 0,
	} :: Frame
end

export type DividerGradientProps = {
	Size: UsedAs<UDim2>?,
	Position: UsedAs<UDim2>?,
	AnchorPoint: UsedAs<Vector2>?,
	LayoutOrder: UsedAs<number>?,
	Tint: Tint?,
	-- "In": transparent at this Frame's own local start (t=0), full Tint brightness at its local end
	-- (t=1) -- the default, matching the common case of a rule growing OUT of a heading. "Out" is the
	-- mirror (bright at t=0, transparent at t=1), used by Flourish's trailing rule below.
	Fade: ("In" | "Out")?,
}

-- UIGradient.Transparency ADDS to the Frame's own BackgroundTransparency rather than replacing it
-- (confirmed precedent: VitalIcon.lua's sheenGradient, which layers a 0.88-1 ramp on top of that
-- tile's own opaque background) -- so this only ever needs to range 0 (no extra transparency; the
-- Tint's own brightness shows through) to 1 (fully hidden regardless of Tint), never re-derive or
-- re-encode the Tint's Transparency value a second time.
function Divider.Gradient(scope: Scope, props: DividerGradientProps): Frame
	local tint = props.Tint or Tokens.Border.Lit
	local fadeOut = props.Fade == "Out"

	local transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, if fadeOut then 0 else 1),
		NumberSequenceKeypoint.new(1, if fadeOut then 1 else 0),
	})

	return scope:New "Frame" {
		Name = "Divider",
		Position = props.Position,
		AnchorPoint = props.AnchorPoint,
		Size = props.Size or UDim2.new(1, 0, 0, 1),
		LayoutOrder = props.LayoutOrder,
		BackgroundColor3 = tint.Color,
		BackgroundTransparency = tint.Transparency,
		BorderSizePixel = 0,

		[Children] = scope:New "UIGradient" {
			Transparency = transparency,
		},
	} :: Frame
end

export type DividerFlourishProps = {
	Size: UsedAs<UDim2>?,
	Position: UsedAs<UDim2>?,
	AnchorPoint: UsedAs<Vector2>?,
	LayoutOrder: UsedAs<number>?,
	RuleTint: Tint?,
	DiamondColor: UsedAs<Color3>?,
}

local DIAMOND_SIZE = 6
local DIAMOND_STROKE_THICKNESS = 1 -- the design calls for 0.8px; 1 is Roblox's real minimum.
local RULE_GAP = Tokens.Space.XS -- clearance either side of the diamond before each rule starts.

-- Each rule spans half the container minus half the diamond and its clearance gap, so the two rules
-- plus the diamond plus its two gaps always sum to exactly the container's own width -- the same
-- "anchor a fraction, correct with an offset" trick Geometry.lua's header documents for
-- CornerBracket's own corner anchoring, used here instead of a UIListLayout because Roblox's layout
-- has no flex-grow to make two siblings share leftover space around a fixed-size middle.
local RULE_SIZE = UDim2.new(0.5, -(DIAMOND_SIZE / 2 + RULE_GAP), 0, 1)

function Divider.Flourish(scope: Scope, props: DividerFlourishProps): Frame
	local ruleTint = props.RuleTint or Tokens.Border.Lit
	local diamondColor: UsedAs<Color3> = props.DiamondColor or Tokens.Color.AccentPrimary

	return scope:New "Frame" {
		Name = "DividerFlourish",
		Position = props.Position,
		AnchorPoint = props.AnchorPoint,
		Size = props.Size or UDim2.new(1, 0, 0, DIAMOND_SIZE),
		BackgroundTransparency = 1,
		LayoutOrder = props.LayoutOrder,

		[Children] = {
			Divider.Gradient(scope, {
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.fromScale(0, 0.5),
				Size = RULE_SIZE,
				Tint = ruleTint,
				-- Fade = "In" (default): transparent at the outer/far edge, full brightness at the
				-- edge nearest the diamond.
			}),
			scope:New "Frame" {
				Name = "Diamond",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(DIAMOND_SIZE, DIAMOND_SIZE),
				Rotation = 45,
				BackgroundTransparency = 1,

				[Children] = scope:New "UIStroke" {
					Color = diamondColor,
					Thickness = DIAMOND_STROKE_THICKNESS,
				},
			},
			Divider.Gradient(scope, {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.fromScale(1, 0.5),
				Size = RULE_SIZE,
				Tint = ruleTint,
				Fade = "Out", -- mirror of the leading rule: bright near the diamond, fading outward.
			}),
		},
	} :: Frame
end

return Divider
