--!strict
--[[
	VitalIcon.lua

	Owns: the icon-gauge primitive for the central Player Status hotbar (docs/ui-ux-philosophy.md)
	-- a dark, sharp-edged tile that fills bottom-up with a vital's current fraction and carries a
	glyph identifying which vital it is.

	Two glyph sources, same tile:
	- `IconAssetId` (optional): a real `rbxassetid://...` texture, once one exists. Roblox has no
	  SVG support at runtime -- `docs/design/icons/*.svg` are the genuine source art, exported to
	  PNG and uploaded through Studio to get this id. Pass it in and the procedural glyph switches
	  off automatically.
	- Procedural fallback (default, no asset id needed): built entirely from Frame/UIStroke
	  composition so the tile never shows a broken image before real assets exist.

	Sibling primitive to Bar.lua, not a replacement for it -- Bar.lua's horizontal fill still owns
	any non-hotbar meter (ability/cooldown, Meridian XP) per that file's own header. This owns the
	icon-tile form factor the hotbar introduced.

	"Bars should not simply fill. They should feel alive" (docs/ui-ux-philosophy.md's Player Status
	Display section) -- the fill's Size is driven by a scope:Spring over the real fraction rather
	than snapping instantly. Per that doc's Implementation Notes on the HUD sync rule, only the
	*decorative* fill animation uses the smoothed value; CriticalBelow/fillColor/strokeColor read
	the real, un-smoothed fraction so the accessibility-critical cue never lags behind actual state.

	Same accessibility contract as Bar.lua: color choices for critical state must not rely on color
	alone. Here that's the stroke thickening/recoloring plus the fill level itself (a positional
	cue) on top of the color shift -- and each vital's glyph shape is distinct, so they're tellable
	apart even with no color information at all.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local Meter = require(script.Parent.Parent.Meter)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type GlyphKind = "Cross" | "Spark" | "Ring" | "Diamond"

export type VitalIconProps = {
	Glyph: GlyphKind,
	Caption: string,
	Value: UsedAs<number>,
	Max: UsedAs<number>,
	FillColor: UsedAs<Color3>?,
	CriticalBelow: number?,
	LayoutOrder: number?,
	-- A real uploaded texture (see docs/design/icons/). Omit to use the procedural glyph.
	IconAssetId: string?,
	-- True for a vital with no owning System yet (Qi -- see HUD/init.lua's header) whose Value/Max
	-- are permanently placeholder numbers, never real data. Renders a flat, desaturated "not live"
	-- look (dimmed fill/background, TextDisabled glyph) instead of a full-looking, critical-capable
	-- gauge, matching AbilitySlot's existing "Locked" appearance for the same not-wired-yet state --
	-- otherwise this tile is visually indistinguishable from Health/Posture's real data, which risks
	-- a QA/playtester report of "Qi bar doesn't update" against a vital that was never wired.
	Muted: boolean?,
}

-- Sleeker/smaller pass: was 72/28/6. Kept in the same proportion (~0.39 glyph-to-tile,
-- ~0.083 stroke-to-tile) so the redraw is a clean scale-down, not a re-design.
local TILE_SIZE = 52
local GLYPH_SIZE = 22
local GLYPH_THICKNESS = 4

-- Spring tuning for the fill animation: snappy enough that the bar still reads as trustworthy
-- during a fast exchange, damped critically (no bounce/overshoot past 0%/100%, which would read
-- as a bug on a vitals gauge). Values live in Tokens.Motion.FillSpring now (see that table's
-- header) -- kept as local aliases so every call site below is unchanged.
local FILL_SPRING_SPEED = Tokens.Motion.FillSpring.Speed
local FILL_SPRING_DAMPING = Tokens.Motion.FillSpring.Damping

-- A plus-sign glyph -- two crossed bars, centered. Reads as "health" without needing an image
-- asset (docs/ui-ux-philosophy.md's Aesthetic direction: sharp edges, restrained ornamentation).
local function CrossGlyph(scope: Scope, color: UsedAs<Color3>): Frame
	return scope:New "Frame" {
		Name = "Glyph",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(GLYPH_SIZE, GLYPH_SIZE),
		BackgroundTransparency = 1,
		ZIndex = 3,

		[Children] = {
			scope:New "Frame" {
				Name = "Vertical",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(GLYPH_THICKNESS, GLYPH_SIZE),
				BackgroundColor3 = color,
				BorderSizePixel = 0,
				ZIndex = 3,
			},
			scope:New "Frame" {
				Name = "Horizontal",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(GLYPH_SIZE, GLYPH_THICKNESS),
				BackgroundColor3 = color,
				BorderSizePixel = 0,
				ZIndex = 3,
			},
		},
	} :: Frame
end

-- A four-point spark -- the Cross glyph rotated 45 degrees. Reads as "energy" and stays visually
-- distinct from the plus-sign Health glyph despite reusing its geometry (rotation is set directly
-- on the already-built instance -- a one-time static override, not a reactive binding, so a plain
-- property assignment is the right tool here rather than routing it back through Fusion).
local function SparkGlyph(scope: Scope, color: UsedAs<Color3>): Frame
	local glyph = CrossGlyph(scope, color)
	glyph.Rotation = 45
	return glyph
end

-- A ring outline (a square Frame with 50%-scale corner radius is a circle) -- reads as "endurance,
-- a renewing cycle", geometrically guaranteed to render correctly with no hand-tuned vertex math.
-- A reusable glyph in the palette; not currently assigned to any vital (it was Stamina's, since
-- removed) -- kept because it's a generic primitive a future vital can adopt, not Stamina-specific.
local function RingGlyph(scope: Scope, color: UsedAs<Color3>): Frame
	return scope:New "Frame" {
		Name = "Glyph",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(GLYPH_SIZE * 0.75, GLYPH_SIZE * 0.75),
		BackgroundTransparency = 1,
		ZIndex = 3,

		[Children] = {
			scope:New "UICorner" {
				CornerRadius = UDim.new(0.5, 0),
			},
			scope:New "UIStroke" {
				Color = color,
				Thickness = GLYPH_THICKNESS * 0.5,
			},
		},
	} :: Frame
end

-- A rotated-square (diamond) outline -- reads as "balance/equilibrium" for Posture, a silhouette
-- distinct from every other glyph so all four vitals are tellable apart at a glance without color.
local function DiamondGlyph(scope: Scope, color: UsedAs<Color3>): Frame
	return scope:New "Frame" {
		Name = "Glyph",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(GLYPH_SIZE * 0.7, GLYPH_SIZE * 0.7),
		Rotation = 45,
		BackgroundTransparency = 1,
		ZIndex = 3,

		[Children] = scope:New "UIStroke" {
			Color = color,
			Thickness = GLYPH_THICKNESS * 0.5,
		},
	} :: Frame
end

local GlyphRenderers: { [GlyphKind]: (Scope, UsedAs<Color3>) -> Frame } = {
	Cross = CrossGlyph,
	Spark = SparkGlyph,
	Ring = RingGlyph,
	Diamond = DiamondGlyph,
}

local VitalIcon = {}

function VitalIcon.new(scope: Scope, props: VitalIconProps): Frame
	local muted = props.Muted == true

	local meter = Meter.Compute(scope, props)
	local fraction = meter.Fraction
	-- Muted suppresses the critical treatment too -- a placeholder vital has no meaningful
	-- "critical" state to flag.
	local isCritical = scope:Computed(function(use)
		return not muted and use(meter.IsCritical)
	end)
	local fillColor = scope:Computed(function(use)
		if muted then
			return Tokens.Color.TextDisabled
		end
		return use(meter.FillColor)
	end)

	-- Decorative only -- smooths how the fill visually catches up to `fraction`. Every
	-- gameplay-relevant read below (critical threshold, fill/stroke color) stays on the real,
	-- un-smoothed `fraction` so the accessibility cue never desyncs from actual state.
	local animatedFraction = scope:Spring(fraction, FILL_SPRING_SPEED, FILL_SPRING_DAMPING)

	local strokeColor = scope:Computed(function(use)
		if muted then
			return Tokens.Color.TextDisabled
		end
		return if use(isCritical) then Tokens.Color.Danger else Tokens.Color.BorderSubtle
	end)

	local strokeThickness = scope:Computed(function(use)
		return if use(isCritical) then 2 else 1
	end)

	local glyphColor = if muted then Tokens.Color.TextDisabled else Tokens.Color.TextPrimary

	local glyph: Instance
	if props.IconAssetId ~= nil then
		glyph = scope:New "ImageLabel" {
			Name = "Icon",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0.66, 0.66),
			BackgroundTransparency = 1,
			Image = props.IconAssetId,
			ImageColor3 = glyphColor,
			ScaleType = Enum.ScaleType.Fit,
			ZIndex = 3,
		} :: ImageLabel
	else
		glyph = GlyphRenderers[props.Glyph](scope, glyphColor)
	end

	return scope:New "Frame" {
		Name = props.Caption .. "VitalIcon",
		LayoutOrder = props.LayoutOrder,
		Size = UDim2.fromOffset(TILE_SIZE, TILE_SIZE),
		BackgroundColor3 = Tokens.Color.Background,
		BorderSizePixel = 0,
		ClipsDescendants = true,

		[Children] = {
			scope:New "UICorner" {
				CornerRadius = Tokens.CornerRadius,
			},
			scope:New "UIStroke" {
				Color = strokeColor,
				Thickness = strokeThickness,
			},
			-- Forged-metal/dark-glass sheen (docs/ui-ux-philosophy.md's Base Palette: "Panels
			-- should feel like dark glass or forged metal") -- a faint top-to-bottom highlight,
			-- not a decorative flourish on top of the fill.
			scope:New "UIGradient" {
				Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Tokens.Color.TextPrimary),
					ColorSequenceKeypoint.new(1, Tokens.Color.Background),
				}),
				Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0.88),
					NumberSequenceKeypoint.new(0.5, 1),
					NumberSequenceKeypoint.new(1, 1),
				}),
				Rotation = 90,
			},
			scope:New "Frame" {
				Name = "Fill",
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.fromScale(0, 1),
				Size = scope:Computed(function(use)
					return UDim2.fromScale(1, use(animatedFraction))
				end),
				BackgroundColor3 = fillColor,
				-- Dimmed fill for a Muted (not-live-yet) vital -- see VitalIconProps.Muted's header.
				BackgroundTransparency = if muted then 0.5 else 0,
				BorderSizePixel = 0,
				ZIndex = 1,

				[Children] = scope:New "UICorner" {
					CornerRadius = Tokens.CornerRadius,
				},
			},
			-- Battle-wear accent: one faint diagonal scuff, not a decorative pile-on -- restrained
			-- per docs/ui-ux-philosophy.md's "minimal visual noise," but enough to read as forged
			-- and fought-with rather than factory-clean.
			scope:New "Frame" {
				Name = "Scratch",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.3),
				Size = UDim2.new(1.4, 0, 0, 1),
				Rotation = 18,
				BackgroundColor3 = Tokens.Color.TextPrimary,
				BackgroundTransparency = 0.82,
				BorderSizePixel = 0,
				ZIndex = 2,
			},
			glyph,
		},
	} :: Frame
end

return VitalIcon
