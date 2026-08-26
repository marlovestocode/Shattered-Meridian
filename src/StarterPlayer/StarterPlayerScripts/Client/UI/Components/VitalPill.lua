--!strict
--[[
	VitalPill.lua

	Owns: the character menu's readout of one vital -- a small filled cell carrying the vital's name,
	its current value over its ceiling, and a hairline of that vital's own color along the bottom
	edge whose width IS the fraction.

	NOT a second VitalIcon. Components/VitalIcon.lua is the HOTBAR's form factor: a glyph tile sized
	and tuned to be read at a glance mid-fight, in peripheral vision, while something is hitting you.
	This is the menu's form factor: read deliberately, with the exact numbers spelled out, alongside
	the attributes that produce them. Same three vitals, same three canon colors (Tokens.VitalColor),
	two genuinely different reading situations -- which is the same split Components/TierBadge.lua's
	header already documents for the tier readout, and the reason CharacterTab doesn't just embed the
	hotbar's own tiles here.

	The bottom hairline is the only place the fraction appears. There is no track behind it: a
	full-width empty groove would imply this is a meter to watch, and in a menu the vital is a
	standing fact rather than something moving. The numerals carry the precision; the hairline only
	has to say "most of it" or "hardly any" from across the panel.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)
local Label = require(script.Parent.Label)
local TrackedLabel = require(script.Parent.TrackedLabel)
local Glow = require(script.Parent.Glow)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type VitalPillProps = {
	-- Static -- the three vitals are named in Tokens.VitalColor and never rename at runtime, which
	-- is what lets this render through TrackedLabel (read-once, see that file's header).
	Caption: string,
	Value: UsedAs<number>,
	Max: UsedAs<number>,
	Color: UsedAs<Color3>,
	Size: UsedAs<UDim2>?,
	Position: UsedAs<UDim2>?,
	LayoutOrder: UsedAs<number>?,
}

-- Grew with the 2026-08-20 type pass: NumeralLarge went 20 -> 22, so the old 52 put the numeral
-- hard against the caption above it.
local HEIGHT = 62
local PADDING_X = 11
local PADDING_Y = 9
local ACCENT_THICKNESS = 2
local ACCENT_GLOW_SPREAD = 6

local function VitalPill(scope: Scope, props: VitalPillProps): Frame
	local fraction = scope:Computed(function(use)
		local max = use(props.Max)
		if max <= 0 then
			return 0
		end
		return math.clamp(use(props.Value) / max, 0, 1)
	end)

	local accentSize = scope:Computed(function(use)
		return UDim2.new(use(fraction), 0, 0, ACCENT_THICKNESS)
	end)

	-- Floored, not rounded: a health value of 459.7 displayed as 460 beside a ceiling of 460 would
	-- read as full while the player is in fact one hit into a fight. The same call Screens/HUD and
	-- the old CharacterTab both already make for every replicated vital.
	local valueText = scope:Computed(function(use)
		return tostring(math.floor(use(props.Value)))
	end)
	local maxText = scope:Computed(function(use)
		return `/ {math.floor(use(props.Max))}`
	end)

	return scope:New "Frame" {
		Name = `VitalPill_{props.Caption}`,
		Size = props.Size or UDim2.new(1, 0, 0, HEIGHT),
		Position = props.Position,
		LayoutOrder = props.LayoutOrder,
		BackgroundColor3 = Tokens.Color.SurfaceElevated,
		BorderSizePixel = 0,
		-- The accent hairline runs to the cell's own edges and its glow spills past them; clipping
		-- keeps both inside the cell so a nearly-full vital's glow doesn't bleed onto its neighbour.
		ClipsDescendants = true,

		[Children] = {
			scope:New "UICorner" {
				CornerRadius = Tokens.Radius.Sharp,
			},
			-- Standard, not Hairline: three vitals side by side are three containers, and at 9% the
			-- divisions between them were invisible against the panel behind.
			scope:New "UIStroke" {
				Color = Tokens.Border.Standard.Color,
				Thickness = 1,
				Transparency = Tokens.Border.Standard.Transparency,
			},
			-- The text sits in its own inset child rather than under a UIPadding on the root, so the
			-- accent hairline below can still measure its width against the cell's TRUE width. Under
			-- a root-level padding a scale-sized accent would resolve against the padded box and a
			-- full vital's hairline would stop short of both edges.
			scope:New "Frame" {
				Name = "Content",
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				ZIndex = 3,

				[Children] = {
					scope:New "UIPadding" {
						PaddingTop = UDim.new(0, PADDING_Y),
						PaddingBottom = UDim.new(0, PADDING_Y),
						PaddingLeft = UDim.new(0, PADDING_X),
						PaddingRight = UDim.new(0, PADDING_X),
					},
					TrackedLabel(scope, {
						Text = string.upper(props.Caption),
						Scale = "Chip",
						Color = Tokens.Color.TextSecondary,
						AnchorPoint = Vector2.new(0, 0),
						Position = UDim2.fromScale(0, 0),
					}),
					Label(scope, {
						Text = valueText,
						Scale = "NumeralLarge",
						Color = props.Color,
						AnchorPoint = Vector2.new(0, 1),
						Position = UDim2.fromScale(0, 1),
						Size = UDim2.new(0.62, 0, 0, Tokens.Type.NumeralLarge.Size + 2),
					}),
					Label(scope, {
						Text = maxText,
						Scale = "NumeralSmall",
						Color = Tokens.Color.TextSecondary,
						AnchorPoint = Vector2.new(1, 1),
						-- Sat on the numeral's baseline rather than centred on its own box: the pair
						-- reads as one "460 / 460" run, which it stops doing the moment the smaller
						-- half floats.
						Position = UDim2.new(1, 0, 1, -3),
						Size = UDim2.new(0.38, 0, 0, Tokens.Type.NumeralSmall.Size + 2),
						TextXAlignment = Enum.TextXAlignment.Right,
					}),
				},
			},

			Glow(scope, {
				Color = props.Color,
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.fromScale(0, 1),
				Size = accentSize,
				Rings = 1,
				Spread = ACCENT_GLOW_SPREAD,
				Transparency = 0.55,
				ZIndex = 1,
			}),
			scope:New "Frame" {
				Name = "Accent",
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.fromScale(0, 1),
				Size = accentSize,
				BackgroundColor3 = props.Color,
				BorderSizePixel = 0,
				ZIndex = 2,
			},
		},
	} :: Frame
end

return VitalPill
