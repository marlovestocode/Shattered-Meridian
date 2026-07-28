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

	Tile shape (2026-07-23 polish pass, same one that gave AbilitySlot.lua its cut-corner tiles --
	see that file's header): the tile's own background/border, AND the fill gauge itself, now render
	via Client/UI/ChamferedSurface.lua's true cut-corner silhouette when available, replacing
	UICorner+UIStroke -- falls back to the prior sharp-rect treatment automatically when it isn't
	(ChamferedSurface.IsAvailable()). The fill gauge reuses the exact same Fill mask as the tile's own
	background rather than a plain rectangle: since the gauge's top edge moves with `fraction`, a
	plain rectangle would square off against the now-cut-corner tile silhouette at high fill levels
	(most visible right where it matters most -- a near-full Health bar). Reusing the full 4-corner
	mask means the gauge's own top corners get the same restrained chamfer nibble as everything else
	in this HUD instead of visibly bleeding past the tile's real edge.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local Meter = require(script.Parent.Parent.Meter)
local ChamferedSurface = require(script.Parent.Parent.ChamferedSurface)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>
type StrokeWeight = ChamferedSurface.StrokeWeight

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

-- Exposed so a sibling layout (Screens/HUD/init.lua's vitals/ability-slot divider) can size itself
-- off the real tile height instead of duplicating this number -- see that file's own comment.
VitalIcon.TILE_SIZE = TILE_SIZE

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

	-- Non-critical default was Tokens.Color.BorderSubtle (RGB 45,55,68) -- the same low-contrast
	-- token HUD/init.lua's Divider turned out to be nearly invisible against this panel's own
	-- dark Surface/SurfaceElevated tones (2026-07-23 in-game screenshot review, same root cause).
	-- BorderAccent is the steel-blue metallic-border token already used by the corner
	-- brackets/frame elsewhere in this HUD, so a vital's default border now actually reads as a
	-- deliberate forged edge instead of disappearing into the panel -- Critical still escalates to
	-- Danger red on top of it, unchanged.
	local strokeColor = scope:Computed(function(use)
		if muted then
			return Tokens.Color.TextDisabled
		end
		return if use(isCritical) then Tokens.Color.Danger else Tokens.Color.AccentPrimary
	end)

	local strokeThickness = scope:Computed(function(use)
		return if use(isCritical) then 2 else 1
	end)
	-- Chamfered-mode sibling of strokeThickness above -- see AbilitySlot.lua's identical strokeWeight
	-- computed for why this is a separate hard-switch value rather than deriving one from the other.
	local strokeWeight: UsedAs<StrokeWeight> = scope:Computed(function(use)
		return if use(isCritical) then "Thick" else "Thin"
	end)

	local glyphColor = if muted then Tokens.Color.TextDisabled else Tokens.Color.TextPrimary
	local isChamfered = ChamferedSurface.IsAvailable()
	local hasRealIcon = props.IconAssetId ~= nil

	local glyph: Instance
	if hasRealIcon then
		-- Real icon art (docs/design/icons/*.svg) carries its own deliberate color grading
		-- (Health's crimson blade, Qi's frost-blue shard, Posture's amber shield) -- unlike the
		-- flat-color procedural glyphs below, it must NOT be re-tinted by glyphColor: that was
		-- multiplying the whole image by TextDisabled (a near-monochrome dark gray) whenever
		-- Muted, crushing the art's own internal gradient/glow contrast into a flat grey blob
		-- (2026-07-24 in-game screenshot review -- read as "the icon barely reads, looks odd"
		-- against the tile's same-hue fill). Muted now dims via ImageTransparency instead, which
		-- fades the art evenly without desaturating it. Slightly larger than before (0.66 -> 0.78)
		-- since real art can afford more presence than the thin procedural line-glyphs could.
		glyph = scope:New "ImageLabel" {
			Name = "Icon",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0.78, 0.78),
			BackgroundTransparency = 1,
			Image = props.IconAssetId,
			ImageColor3 = Color3.new(1, 1, 1),
			ImageTransparency = if muted then 0.45 else 0,
			ScaleType = Enum.ScaleType.Fit,
			ZIndex = 3,
		} :: ImageLabel
	else
		glyph = GlyphRenderers[props.Glyph](scope, glyphColor)
	end

	-- Forged-metal/dark-glass sheen (docs/ui-ux-philosophy.md's Base Palette: "Panels should feel
	-- like dark glass or forged metal") -- a faint top-to-bottom highlight, not a decorative flourish
	-- on top of the fill. Unchanged from before this pass except for where it's attached -- see
	-- AbilitySlot.lua's identical glowGradient comment for why (chamfered mode's root Frame has no
	-- background of its own left to modify).
	local sheenGradient = scope:New "UIGradient" {
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
	}

	-- Dimmed fill for a Muted (not-live-yet) vital -- see VitalIconProps.Muted's header.
	local fillTransparency = if muted then 0.5 else 0
	local fillSize = scope:Computed(function(use)
		return UDim2.fromScale(1, use(animatedFraction))
	end)

	local children: { Instance } = {}

	if isChamfered then
		local tileFill = ChamferedSurface.Fill(scope, {
			FillColor = Tokens.Color.Background,
			ZIndex = 0,
			Children = sheenGradient,
		})
		local stroke = ChamferedSurface.Stroke(scope, {
			Color = strokeColor,
			Weight = strokeWeight,
			ZIndex = 5,
		})
		-- See this file's header on why the fill gauge reuses the same chamfered mask as the tile
		-- background instead of a plain rectangle.
		local fillGauge = ChamferedSurface.Fill(scope, {
			FillColor = fillColor,
			FillTransparency = fillTransparency,
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = fillSize,
			ZIndex = 1,
		})
		if tileFill and stroke and fillGauge then
			table.insert(children, tileFill)
			table.insert(children, fillGauge)
			table.insert(children, stroke)
		else
			-- ChamferedSurface.IsAvailable() said yes but a bake somehow came back nil anyway --
			-- treat it the same as unavailable rather than rendering a tile with a missing layer.
			isChamfered = false
		end
	end

	if not isChamfered then
		table.insert(
			children,
			scope:New "UICorner" {
				CornerRadius = Tokens.Radius.Sharp,
			}
		)
		table.insert(
			children,
			scope:New "UIStroke" {
				Color = strokeColor,
				Thickness = strokeThickness,
			}
		)
		table.insert(children, sheenGradient)
		table.insert(
			children,
			scope:New "Frame" {
				Name = "Fill",
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.fromScale(0, 1),
				Size = fillSize,
				BackgroundColor3 = fillColor,
				BackgroundTransparency = fillTransparency,
				BorderSizePixel = 0,
				ZIndex = 1,

				[Children] = scope:New "UICorner" {
					CornerRadius = Tokens.Radius.Sharp,
				},
			} :: Frame
		)
	end

	-- Neutral dark medallion behind real icon art only (2026-07-24 design review) -- the fill gauge
	-- underneath is the SAME hue as the icon itself (Tokens.VitalColor.Health/Qi/Posture on a Health/Qi/
	-- Posture-colored glyph), so at a high fill fraction the icon was nearly camouflaged against its
	-- own tile. A fixed near-black backdrop (Tokens.Color.Background, independent of FillColor/
	-- fraction) gives the art a consistent dark canvas to pop off of regardless of vital state.
	-- Procedural line-glyphs don't need this -- they're thin enough to already read fine directly on
	-- the fill.
	if hasRealIcon then
		local iconBacking = if isChamfered
			then ChamferedSurface.Fill(scope, {
				FillColor = Tokens.Color.Background,
				FillTransparency = 0.1,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(0.86, 0.86),
				ZIndex = 2,
			})
			else scope:New "Frame" {
				Name = "IconBacking",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(0.86, 0.86),
				BackgroundColor3 = Tokens.Color.Background,
				BackgroundTransparency = 0.1,
				BorderSizePixel = 0,
				ZIndex = 2,

				[Children] = scope:New "UICorner" {
					CornerRadius = Tokens.Radius.Sharp,
				},
			} :: Frame
		if iconBacking then
			table.insert(children, iconBacking)
		end
	end

	-- The battle-wear diagonal scuff accent that used to render here (2026-07-23 design review: read
	-- as "weird lines through the icon" once the chamfered tile shape made the tile geometry itself
	-- read as more deliberate/precise -- removed rather than softened further per that feedback).
	table.insert(children, glyph)

	return scope:New "Frame" {
		Name = props.Caption .. "VitalIcon",
		LayoutOrder = props.LayoutOrder,
		BackgroundColor3 = Tokens.Color.Background,
		Size = UDim2.fromOffset(TILE_SIZE, TILE_SIZE),
		-- Chamfered mode paints its own background via an ImageLabel child instead (see `children`
		-- above), so this root Frame's own background must stay fully transparent -- otherwise its
		-- plain rectangular corners would show through underneath the chamfered silhouette's cut
		-- corners.
		BackgroundTransparency = if isChamfered then 1 else 0,
		BorderSizePixel = 0,
		ClipsDescendants = true,

		[Children] = children,
	} :: Frame
end

return VitalIcon
