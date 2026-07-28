--!strict
--[[
	Glow.lua

	Owns: the ONLY sanctioned substitute for CSS box-shadow blur/spread in this UI (docs/design/
	intro-redesign-handoff.md's "Roblox can't express these" table) -- Roblox has no blur/shadow
	property at all, so a soft halo is faked with N concentric Frames, each carrying a UIStroke at an
	increasing size and transparency. The CONTINUE button's `box-shadow 0 0 24px rgba(154,136,200,0.2)`
	and the selection dot's `box-shadow 0 0 6px var(--qi)` (docs/design/intro-redesign-figma-spec.md)
	are both this component at different Rings/Spread/Transparency settings, not two different
	techniques.

	At Rings = 1 this degenerates to one ring at the full Spread offset and the base Transparency --
	deliberately still "wide" (the full spread, not a fractional one) and "translucent" (the un-faded
	base alpha, not faded toward invisible) -- the right answer for a small bar/dot glow that doesn't
	need a multi-ring falloff to read as soft.

	Does not own: the target's own fill/border -- a caller composes this alongside its normal
	Panel/Button/Frame, typically as an earlier sibling or lower ZIndex within the SAME parent. Per
	the handoff's own ZIndexBehavior.Sibling warning: ZIndex only orders siblings under one parent, so
	a later sibling under a DIFFERENT parent still paints over this regardless of ZIndex.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type GlowProps = {
	Color: UsedAs<Color3>,
	-- The glowing shape's own size/position -- matches whatever target this Glow sits behind (a
	-- button, a selection dot, a card). Each ring grows outward from this by its own offset; this
	-- root Frame itself never paints anything.
	Size: UsedAs<UDim2>?,
	Position: UsedAs<UDim2>?,
	AnchorPoint: UsedAs<Vector2>?,
	LayoutOrder: UsedAs<number>?,
	ZIndex: number?,
	-- Omit for an always-shown glow. A caller whose target has its own enabled/disabled state (e.g.
	-- Button.lua's Primary variant, which has no shadow while Disabled) drives this instead of
	-- conditionally building the Glow instance at all, so the glow can react live to a state that
	-- changes after construction.
	Visible: UsedAs<boolean>?,
	-- Ring count. More rings buys a smoother falloff at the cost of more Instances; 1 is a
	-- deliberately-supported floor (see file header), not a degenerate edge case to special-case away.
	Rings: number?,
	-- Outward offset in pixels of the OUTERMOST ring from Size, on every edge. Inner rings scale
	-- linearly between 0 and this. Default (24) matches the Continue button's own spec'd blur radius.
	Spread: number?,
	-- Transparency of the INNERMOST (smallest, brightest) ring. Outer rings interpolate from this
	-- toward 1 (fully invisible) at the outermost ring. Default (0.8) matches the Continue button's
	-- own spec'd 20% opacity. Reactive (UsedAs, not a plain number) -- Button.lua's Primary variant
	-- needs to brighten this live on hover; every existing caller already passes a static number,
	-- which still satisfies UsedAs<number> unchanged.
	Transparency: UsedAs<number>?,
	StrokeThickness: number?,
	-- Applied to every ring via UICorner. Defaults to this UI's usual square corner -- pass
	-- UDim.new(0.5, 0) to glow a circular target (e.g. the origin card's selection dot) instead of a
	-- rectangular one.
	CornerRadius: UDim?,
}

local DEFAULT_RINGS = 4
local DEFAULT_SPREAD = 24
local DEFAULT_TRANSPARENCY = 0.8
local DEFAULT_STROKE_THICKNESS = 1

local function Glow(scope: Scope, props: GlowProps): Frame
	local ringCount = props.Rings or DEFAULT_RINGS
	local spread = props.Spread or DEFAULT_SPREAD
	local baseTransparency: UsedAs<number> = if props.Transparency == nil
		then DEFAULT_TRANSPARENCY
		else props.Transparency
	local strokeThickness = props.StrokeThickness or DEFAULT_STROKE_THICKNESS
	local cornerRadius = props.CornerRadius or Tokens.Radius.Sharp

	local rings: { Instance } = {}
	for index = 1, ringCount do
		-- Size ramp uses the full 1..ringCount range (ring 1 sits closest to the target edge, the
		-- last ring reaches the full Spread) -- see file header for why ringCount == 1 must still
		-- reach the full Spread rather than a fractional one.
		local offset = spread * (index / ringCount)
		-- Transparency ramp is 0-indexed and guards against dividing by zero at ringCount == 1, so
		-- ring 1 always renders at exactly baseTransparency (never pre-faded) regardless of how many
		-- rings follow it. A Computed, not a plain number, since baseTransparency can itself now be
		-- reactive -- see this file's own Transparency prop comment.
		local fadeFraction = if ringCount <= 1 then 0 else (index - 1) / (ringCount - 1)
		local ringTransparency = scope:Computed(function(use)
			local base = use(baseTransparency)
			return base + (1 - base) * fadeFraction
		end)

		table.insert(
			rings,
			scope:New "Frame" {
				Name = "Ring" .. index,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.new(1, offset * 2, 1, offset * 2),
				BackgroundTransparency = 1,

				[Children] = {
					scope:New "UICorner" {
						CornerRadius = cornerRadius,
					},
					scope:New "UIStroke" {
						Color = props.Color,
						Thickness = strokeThickness,
						Transparency = ringTransparency,
					},
				},
			} :: Frame
		)
	end

	return scope:New "Frame" {
		Name = "Glow",
		Position = props.Position,
		AnchorPoint = props.AnchorPoint,
		Size = props.Size or UDim2.fromScale(1, 1),
		LayoutOrder = props.LayoutOrder,
		ZIndex = props.ZIndex,
		Visible = if props.Visible == nil then true else props.Visible,
		BackgroundTransparency = 1,

		[Children] = rings,
	} :: Frame
end

return Glow
