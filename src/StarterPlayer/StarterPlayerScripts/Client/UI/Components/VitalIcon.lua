--!strict
--[[
	VitalIcon.lua

	Owns: the vital gauge in the central Player Status dock (docs/ui-ux-philosophy.md) -- a chamfered
	icon tile that washes bottom-up with the vital's current fraction, over a thin solid track that
	carries the precise reading.

	TWO SURFACES, TWO JOBS -- the 2026-08-25 hotbar rebuild's one structural change here, and it
	exists because the previous single-surface version had the two fighting each other. The tile used
	to be the gauge: an OPAQUE fill of the vital's own hue rising behind an icon painted in that same
	hue, which at a high fraction camouflaged the art against its own tile. That was patched once with
	a neutral medallion plate behind the icon (2026-07-24), which bought the legibility back and cost
	the tile its silhouette. The rebuild splits the two jobs instead of layering a third plate:
	  * The TILE says WHICH vital, and roughly how full -- so its fill is a translucent WASH the icon
	    reads cleanly through at any level, and the medallion plate is deleted rather than compensating.
	  * The TRACK beneath says exactly HOW MUCH -- a solid 4px bar, which is the shape an eye actually
	    measures a quantity with.
	Nothing about the ICON ART changed and nothing about it should: `IconAssetId` still takes the
	authored `docs/design/icons/*.svg` exports untinted (they carry their own deliberate colour
	grading), and the procedural Frame/UIStroke glyphs are the same shapes they always were.

	Two glyph sources, same tile:
	- `IconAssetId` (optional): a real `rbxassetid://...` texture. Roblox has no SVG support at
	  runtime -- `docs/design/icons/*.svg` are the genuine source art, exported to PNG and uploaded
	  through Studio to get this id. Pass it in and the procedural glyph switches off automatically.
	- Procedural fallback (default, no asset id needed): built entirely from Frame/UIStroke
	  composition so the tile never shows a broken image before real assets exist.

	Sibling primitive to Bar.lua, not a replacement for it -- Bar.lua's horizontal fill still owns any
	non-hotbar meter (ability/cooldown, Meridian XP) per that file's own header. This owns the
	icon-tile form factor the hotbar introduced.

	NO PER-FRAME DECORATIVE CUES ANY MORE -- a performance decision, taken on a measured frame-rate drop
	every time the player was hit. This gauge used to derive a damage flare, a border colour blend, a
	border transparency pulse and a gain bloom from the spring's lag (impact = smoothed - real, surge =
	real - smoothed). All of those rewrote their properties on EVERY frame the spring was moving -- seven
	or eight writes per gauge per frame, on a surface built from chamfered image layers, a UIStroke and a
	UIGradient -- and health and guard both move on every hit. Now the only thing that animates is the
	fill itself (the wash height and the track width, two writes a frame while it settles); the border
	and the wash only change when the critical state flips.

	Per that doc's Implementation Notes on the HUD sync rule, only the *decorative* interpolation uses
	the smoothed value; CriticalBelow/fillColor read the real, un-smoothed fraction so the
	accessibility-critical cue never lags behind actual state.

	Same accessibility contract as Bar.lua: critical state must not rely on color alone. Here that is
	the stroke thickening/recoloring plus the fill level itself (a positional cue) on top of the color
	shift -- and each vital's glyph shape is distinct, so all of them are tellable apart with no color
	information at all.

	Tile shape: the tile background, its border and the wash gauge all render via
	Client/UI/ChamferedSurface.lua's true cut-corner silhouette when available, falling back to the
	sharp-rect UICorner+UIStroke treatment automatically when it isn't (ChamferedSurface.IsAvailable()).
	The wash reuses the exact same Fill mask as the tile background rather than a plain rectangle:
	since its top edge moves with `fraction`, a plain rectangle would square off against the cut-corner
	silhouette at high fill levels -- most visible right where it matters most, a near-full Health tile.
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
	-- True for a vital with no owning System yet, whose Value/Max are permanently placeholder numbers
	-- rather than real data. Renders a flat, desaturated "not live" look instead of a full-looking,
	-- critical-capable gauge, matching AbilitySlot's "Locked" appearance for the same not-wired-yet
	-- state -- otherwise the tile is visually indistinguishable from a real vital's data, which risks
	-- a QA report of "the bar doesn't update" against one that was never wired at all.
	Muted: boolean?,
}

-- Was 52 before the rebuild. Smaller because the tile no longer has to carry the precise reading on
-- its own -- the track below does -- and a dock holding three of these plus five ability tiles plus
-- the tier module has to stay inside docs/ui-ux-philosophy.md's "out of the player's way."
local TILE_SIZE = 48
local GLYPH_SIZE = 20
local GLYPH_THICKNESS = 4
-- The precise-reading track. Deliberately thin: it is read as a LENGTH, and height beyond what makes
-- it visible only steals room from the tile above it.
local TRACK_HEIGHT = 4
local TRACK_GAP = 6

-- How translucent the tile's own wash is at rest. Deliberately far short of opaque -- see this file's
-- header on the two-surface split: the icon has to stay readable through it at every level, which is
-- what let the medallion plate that used to sit between them be deleted.
local WASH_TRANSPARENCY = 0.72
local MUTED_WASH_TRANSPARENCY = 0.9

-- Spring tuning for the fill: snappy enough that the gauge still reads as trustworthy during a fast
-- exchange, damped critically (no bounce/overshoot past 0%/100%, which would read as a bug on a
-- vitals gauge). Values live in Tokens.Motion.FillSpring.
local FILL_SPRING_SPEED = Tokens.Motion.FillSpring.Speed
local FILL_SPRING_DAMPING = Tokens.Motion.FillSpring.Damping

-- The tile border's resting transparency.
local STROKE_RESTING_TRANSPARENCY = 0.35
local MUTED_STROKE_TRANSPARENCY = 0.4

-- A plus-sign glyph -- two crossed bars, centered. Reads as "health" without needing an image asset
-- (docs/ui-ux-philosophy.md's Aesthetic direction: sharp edges, restrained ornamentation).
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
-- distinct from the plus-sign Health glyph despite reusing its geometry (rotation is set directly on
-- the already-built instance -- a one-time static override, not a reactive binding, so a plain
-- property assignment is the right tool here rather than routing it back through Fusion).
local function SparkGlyph(scope: Scope, color: UsedAs<Color3>): Frame
	local glyph = CrossGlyph(scope, color)
	glyph.Rotation = 45
	return glyph
end

-- A ring outline (a square Frame with 50%-scale corner radius is a circle) -- reads as "endurance, a
-- renewing cycle", geometrically guaranteed to render correctly with no hand-tuned vertex math. A
-- reusable glyph in the palette; not currently assigned to any vital (it was Stamina's, since
-- removed) -- kept because it is a generic primitive a future vital can adopt, not Stamina-specific.
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

-- Exposed so a sibling layout can size itself off the real numbers instead of duplicating them.
-- TILE_SIZE is the square tile alone; GAUGE_HEIGHT is the whole column including the track and the
-- gap above it, which is what a row sharing this gauge's height actually has to match.
VitalIcon.TILE_SIZE = TILE_SIZE
VitalIcon.GAUGE_HEIGHT = TILE_SIZE + TRACK_GAP + TRACK_HEIGHT

function VitalIcon.new(scope: Scope, props: VitalIconProps): Frame
	local muted = props.Muted == true

	local meter = Meter.Compute(scope, props)
	local fraction = meter.Fraction
	-- Muted suppresses the critical treatment too -- a placeholder vital has no meaningful "critical"
	-- state to flag.
	local isCritical = scope:Computed(function(use)
		return not muted and use(meter.IsCritical)
	end)
	local fillColor = scope:Computed(function(use)
		if muted then
			return Tokens.Color.TextDisabled
		end
		return use(meter.FillColor)
	end)

	-- Decorative only -- smooths how the gauge catches up to `fraction`, and is now the ONLY thing on
	-- this gauge that changes per frame (see this file's header). Every gameplay-relevant read (critical
	-- threshold, fill color) stays on the real, un-smoothed `fraction` so the accessibility cue never
	-- desyncs from actual state.
	local animatedFraction = scope:Spring(fraction, FILL_SPRING_SPEED, FILL_SPRING_DAMPING)

	-- A flat neutral border is nearly invisible against this dock's dark surface tones, so a vital's
	-- resting border is the same metallic violet the frame and corner accents already use -- it reads
	-- as a deliberate forged edge rather than disappearing. Critical escalates to Danger red. Reads
	-- only isCritical, so it recomputes on the critical edge and never per frame.
	local strokeColor = scope:Computed(function(use)
		if muted then
			return Tokens.Color.TextDisabled
		end
		return if use(isCritical) then Tokens.Color.Danger else Tokens.Color.AccentPrimary
	end)

	local strokeTransparency = if muted then MUTED_STROKE_TRANSPARENCY else STROKE_RESTING_TRANSPARENCY

	local strokeThickness = scope:Computed(function(use)
		return if use(isCritical) then 2 else 1
	end)
	-- Chamfered-mode sibling of strokeThickness above: ChamferedSurface's border is a baked-width
	-- image, not a live UIStroke.Thickness, so it swaps between two pre-baked widths instead.
	local strokeWeight: UsedAs<StrokeWeight> = scope:Computed(function(use)
		return if use(isCritical) then "Thick" else "Thin"
	end)

	local glyphColor = if muted then Tokens.Color.TextDisabled else Tokens.Color.TextPrimary
	local isChamfered = ChamferedSurface.IsAvailable()
	local hasRealIcon = props.IconAssetId ~= nil

	local glyph: Instance
	if hasRealIcon then
		-- Real icon art (docs/design/icons/*.svg) carries its own deliberate color grading (Health's
		-- crimson blade, Qi's frost-blue shard, Posture's amber shield) -- unlike the flat-color
		-- procedural glyphs above it must NOT be re-tinted, which would multiply the art by a flat
		-- token colour and crush its internal gradient contrast into a grey blob. Muted dims via
		-- ImageTransparency instead, which fades the art evenly without desaturating it.
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

	-- Forged-metal/dark-glass sheen (docs/ui-ux-philosophy.md's Base Palette: "Panels should feel like
	-- dark glass or forged metal") -- a faint top-to-bottom highlight, not a decorative flourish on
	-- top of the fill. Static by construction: it describes the tile's MATERIAL, not its state, so it
	-- must never be rebuilt on a value change.
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

	local washTransparency = if muted then MUTED_WASH_TRANSPARENCY else WASH_TRANSPARENCY
	local washSize = scope:Computed(function(use)
		return UDim2.fromScale(1, use(animatedFraction))
	end)

	local tileChildren: { Instance } = {}

	if isChamfered then
		local tileFill = ChamferedSurface.Fill(scope, {
			FillColor = Tokens.Color.Background,
			ZIndex = 0,
			Children = sheenGradient,
		})
		-- See this file's header on why the wash reuses the same chamfered mask as the tile background
		-- instead of a plain rectangle.
		local wash = ChamferedSurface.Fill(scope, {
			FillColor = fillColor,
			FillTransparency = washTransparency,
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = washSize,
			ZIndex = 1,
		})
		local stroke = ChamferedSurface.Stroke(scope, {
			Color = strokeColor,
			Transparency = strokeTransparency,
			Weight = strokeWeight,
			ZIndex = 5,
		})
		local layers = ChamferedSurface.AllLayers({ tileFill, wash, stroke })
		if layers then
			tileChildren = layers
		else
			isChamfered = false
		end
	end

	if not isChamfered then
		table.insert(
			tileChildren,
			scope:New "UICorner" {
				CornerRadius = Tokens.Radius.Sharp,
			}
		)
		table.insert(
			tileChildren,
			scope:New "UIStroke" {
				Color = strokeColor,
				Thickness = strokeThickness,
				Transparency = strokeTransparency,
			}
		)
		table.insert(tileChildren, sheenGradient)
		table.insert(
			tileChildren,
			scope:New "Frame" {
				Name = "Wash",
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.fromScale(0, 1),
				Size = washSize,
				BackgroundColor3 = fillColor,
				BackgroundTransparency = washTransparency,
				BorderSizePixel = 0,
				ZIndex = 1,
			} :: Frame
		)
	end

	table.insert(tileChildren, glyph)

	local tile = scope:New "Frame" {
		Name = "Tile",
		LayoutOrder = 1,
		BackgroundColor3 = Tokens.Color.Background,
		Size = UDim2.fromOffset(TILE_SIZE, TILE_SIZE),
		-- Chamfered mode paints its own background via an ImageLabel child instead, so this Frame's
		-- own background must stay fully transparent -- otherwise its plain rectangular corners would
		-- show through underneath the chamfered silhouette's cut corners.
		BackgroundTransparency = if isChamfered then 1 else 0,
		BorderSizePixel = 0,
		ClipsDescendants = true,

		[Children] = tileChildren,
	} :: Frame

	-- The precise reading. Deliberately NOT Components/Bar.lua: that primitive runs its own
	-- Meter.Compute and its own un-sprung fill, and this track has to move on the SAME smoothed
	-- fraction as the wash above it -- otherwise the two halves of one gauge visibly disagree for the
	-- third of a second after every hit. Four Instances is the right price for that.
	local track = scope:New "Frame" {
		Name = "Track",
		LayoutOrder = 2,
		Size = UDim2.fromOffset(TILE_SIZE, TRACK_HEIGHT),
		BackgroundColor3 = Tokens.Color.Background,
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
		ClipsDescendants = true,

		[Children] = {
			scope:New "UICorner" {
				CornerRadius = Tokens.Radius.Hairline,
			},
			scope:New "Frame" {
				Name = "Fill",
				Size = scope:Computed(function(use)
					return UDim2.fromScale(use(animatedFraction), 1)
				end),
				BackgroundColor3 = fillColor,
				BackgroundTransparency = if muted then 0.5 else 0,
				BorderSizePixel = 0,

				[Children] = scope:New "UICorner" {
					CornerRadius = Tokens.Radius.Hairline,
				},
			},
		},
	} :: Frame

	return scope:New "Frame" {
		Name = props.Caption .. "VitalIcon",
		LayoutOrder = props.LayoutOrder,
		Size = UDim2.fromOffset(TILE_SIZE, VitalIcon.GAUGE_HEIGHT),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				Padding = UDim.new(0, TRACK_GAP),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			tile,
			track,
		},
	} :: Frame
end

return VitalIcon
