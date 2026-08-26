--!strict
--[[
	TokenPage.lua

	Owns: the Storybook page that renders Tokens.lua as something you can look at -- the whole type
	ramp at real size, every color swatch on the ground it will actually sit on, the border and wash
	tints at their real transparencies, and the spacing steps as measured bars.

	WHY THIS IS THE FIRST PAGE. Three separate readability passes over the character menu were made
	by reading hex triplets and font sizes in a table and imagining the result. The second one raised
	Tokens.Color.TextDisabled because it was computed to be near 2:1 against Surface -- a number
	nobody could see until a screenshot came back. A page that shows the ramp and the palette at real
	size turns that from arithmetic into a glance.

	The type ramp is split in two on purpose, and the split is not cosmetic: Tokens.Type's tracked
	steps (Micro/Eyebrow/Action/Chip/Abbrev) carry a Tracking value that a single TextLabel physically
	cannot render, so they go through Components/TrackedLabel.lua and the rest go through
	Components/Label.lua. Those two components take deliberately disjoint scale unions -- see either
	header -- so the two lists here are hand-written rather than derived from one loop over
	Tokens.Type. A loop would have to cast, and the cast would be exactly the mistake the disjoint
	unions exist to make impossible.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local TrackedLabel = require(script.Parent.Parent.Parent.Parent.Components.TrackedLabel)
local Stack = require(script.Parent.Parent.Parent.Parent.Components.Stack)
local Inset = require(script.Parent.Parent.Parent.Parent.Components.Inset)

local Specimen = require(script.Parent.Specimen)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type LabelScale = Label.LabelScale
type TrackedScale = TrackedLabel.TrackedScale

local SAMPLE = "Shattered Meridian 0123"
local ROW_HEIGHT = 34
local SWATCH_SIZE = 34
local NAME_WIDTH = 132

-- Every untracked step, in ramp order rather than table order -- the point of a ramp is to be read
-- top to bottom as a scale.
local PROSE_STEPS: { LabelScale } = {
	"Title",
	"Heading",
	"CardTitle",
	"BodyLarge",
	"Body",
	"SerifInline",
	"Detail",
	"DetailEmphasis",
	"NumeralLarge",
	"Numeral",
	"NumeralSmall",
}

local TRACKED_STEPS: { TrackedScale } = { "Micro", "Eyebrow", "Action", "Chip", "Abbrev" }

-- One ramp row: the step's name and pixel size on the left, the specimen itself on the right.
local function typeRow(scope: Scope, name: string, specimen: Instance, layoutOrder: number): Frame
	local step = Tokens.Type[name]
	return Stack.Row(scope, {
		Name = `Type_{name}`,
		Gap = Tokens.Space.M,
		Size = UDim2.new(1, 0, 0, math.max(ROW_HEIGHT, step.Size + 12)),
		AlignY = Enum.VerticalAlignment.Center,
		LayoutOrder = layoutOrder,
		Children = {
			Label(scope, {
				Text = `{name}  {step.Size}`,
				Scale = "NumeralSmall",
				Color = Tokens.Color.TextDisabled,
				Size = UDim2.fromOffset(NAME_WIDTH, 18),
				LayoutOrder = 1,
			}),
			specimen,
		},
	})
end

-- One color swatch: the chip, the token name, and its RGB -- because "which of these two violets is
-- AccentPrimary" is a question this page should answer without a trip back to Tokens.lua.
local function swatch(scope: Scope, name: string, color: Color3, transparency: number?, layoutOrder: number): Frame
	return Stack.Row(scope, {
		Name = `Swatch_{name}`,
		Gap = Tokens.Space.S,
		Size = UDim2.fromOffset(210, SWATCH_SIZE),
		AlignY = Enum.VerticalAlignment.Center,
		LayoutOrder = layoutOrder,
		Children = {
			scope:New "Frame" {
				Name = "Chip",
				Size = UDim2.fromOffset(SWATCH_SIZE, SWATCH_SIZE),
				LayoutOrder = 1,
				BackgroundColor3 = color,
				BackgroundTransparency = transparency or 0,
				BorderSizePixel = 0,

				[Children] = scope:New "UIStroke" {
					Color = Tokens.Border.Hairline.Color,
					Thickness = 1,
					Transparency = Tokens.Border.Hairline.Transparency,
				},
			},
			Stack.New(scope, {
				Gap = 0,
				Size = UDim2.fromOffset(160, SWATCH_SIZE),
				AlignY = Enum.VerticalAlignment.Center,
				LayoutOrder = 2,
				Children = {
					Label(scope, {
						Text = name,
						Scale = "Detail",
						Size = UDim2.new(1, 0, 0, 17),
						LayoutOrder = 1,
					}),
					Label(scope, {
						Text = string.format(
							"%d %d %d%s",
							math.round(color.R * 255),
							math.round(color.G * 255),
							math.round(color.B * 255),
							if transparency then string.format("  @%.2f", 1 - transparency) else ""
						),
						Scale = "NumeralSmall",
						Color = Tokens.Color.TextDisabled,
						Size = UDim2.new(1, 0, 0, 15),
						LayoutOrder = 2,
					}),
				},
			}),
		},
	})
end

-- One spacing step, drawn at its literal width so the ramp is measurable rather than described.
local function spacingRow(scope: Scope, name: string, size: number, layoutOrder: number): Frame
	return Stack.Row(scope, {
		Name = `Space_{name}`,
		Gap = Tokens.Space.M,
		Size = UDim2.new(1, 0, 0, 24),
		AlignY = Enum.VerticalAlignment.Center,
		LayoutOrder = layoutOrder,
		Children = {
			Label(scope, {
				Text = `{name}  {size}`,
				Scale = "NumeralSmall",
				Color = Tokens.Color.TextDisabled,
				Size = UDim2.fromOffset(72, 18),
				LayoutOrder = 1,
			}),
			scope:New "Frame" {
				Name = "Bar",
				Size = UDim2.fromOffset(size, 12),
				LayoutOrder = 2,
				BackgroundColor3 = Tokens.Color.AccentSecondary,
				BorderSizePixel = 0,
			},
		},
	})
end

local function TokenPage(scope: Scope, layoutOrder: number, visible: Fusion.UsedAs<boolean>, width: number): Frame
	local proseRows: { Instance } = {}
	for index, step in ipairs(PROSE_STEPS) do
		table.insert(
			proseRows,
			typeRow(
				scope,
				step,
				Label(scope, {
					Text = SAMPLE,
					Scale = step,
					Size = UDim2.new(1, -(NAME_WIDTH + Tokens.Space.M), 0, Tokens.Type[step].Size + 8),
					LayoutOrder = 2,
				}),
				index
			)
		)
	end

	local trackedRows: { Instance } = {}
	for index, step in ipairs(TRACKED_STEPS) do
		table.insert(
			trackedRows,
			typeRow(
				scope,
				step,
				TrackedLabel(scope, {
					Text = "SHATTERED MERIDIAN",
					Scale = step,
					LayoutOrder = 2,
				}),
				index
			)
		)
	end

	local coreSwatches: { Instance } = {}
	local coreOrder = {
		"Background",
		"Surface",
		"SurfaceElevated",
		"AccentPrimary",
		"AccentPrimaryBright",
		"AccentSecondary",
		"TextPrimary",
		"TextSecondary",
		"TextDisabled",
		"Danger",
		"Warning",
		"Positive",
	}
	for index, name in ipairs(coreOrder) do
		table.insert(coreSwatches, swatch(scope, name, (Tokens.Color :: any)[name], nil, index))
	end

	local vitalSwatches: { Instance } = {}
	local vitalIndex = 0
	for name, color in pairs(Tokens.VitalColor) do
		vitalIndex += 1
		table.insert(vitalSwatches, swatch(scope, name, color, nil, vitalIndex))
	end

	local tintSwatches: { Instance } = {}
	local tintIndex = 0
	for name, tint in pairs(Tokens.Border) do
		tintIndex += 1
		table.insert(tintSwatches, swatch(scope, `Border.{name}`, tint.Color, tint.Transparency, tintIndex))
	end
	for name, tint in pairs(Tokens.Wash) do
		tintIndex += 1
		table.insert(tintSwatches, swatch(scope, `Wash.{name}`, tint.Color, tint.Transparency, tintIndex))
	end

	local spacingRows: { Instance } = {}
	local spacingOrder = { "XS", "S", "M", "L", "XL", "XXL", "XXXL" }
	for index, name in ipairs(spacingOrder) do
		table.insert(spacingRows, spacingRow(scope, name, (Tokens.Space :: any)[name], index))
	end

	local proseHeight = 0
	for _, step in ipairs(PROSE_STEPS) do
		proseHeight += math.max(ROW_HEIGHT, Tokens.Type[step].Size + 12) + Tokens.Space.XS
	end
	local trackedHeight = 0
	for _, step in ipairs(TRACKED_STEPS) do
		trackedHeight += math.max(ROW_HEIGHT, Tokens.Type[step].Size + 12) + Tokens.Space.XS
	end

	return Stack.New(scope, {
		Name = "TokenPage",
		Gap = Tokens.Space.L,
		Size = UDim2.fromOffset(width, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = layoutOrder,
		Visible = visible,
		Children = {
			Specimen(scope, {
				Title = "Type Scale",
				Note = "Serif for the world, sans for instruction, mono for every numeral.",
				Height = proseHeight + Tokens.Space.M,
				Direction = "Vertical",
				Gap = Tokens.Space.XS,
				AlignY = Enum.VerticalAlignment.Top,
				LayoutOrder = 1,
				Children = proseRows,
			}),
			Specimen(scope, {
				Title = "Tracked Caps",
				Note = "Rendered one TextLabel per character -- the only way this engine expresses letter-spacing.",
				Height = trackedHeight + Tokens.Space.M,
				Direction = "Vertical",
				Gap = Tokens.Space.XS,
				AlignY = Enum.VerticalAlignment.Top,
				LayoutOrder = 2,
				Children = trackedRows,
			}),
			Specimen(scope, {
				Title = "Palette",
				Height = 3 * (SWATCH_SIZE + Tokens.Space.S) + Tokens.Space.M,
				Direction = "Horizontal",
				Gap = Tokens.Space.S,
				AlignY = Enum.VerticalAlignment.Top,
				LayoutOrder = 3,
				Children = {
					Stack.Row(scope, {
						Gap = Tokens.Space.S,
						Wraps = true,
						Size = UDim2.fromScale(1, 1),
						Children = coreSwatches,
					}),
				},
			}),
			Specimen(scope, {
				Title = "Vitals",
				Note = "Deliberately distinct from the chrome -- telling these three apart is the whole job.",
				Height = SWATCH_SIZE + Tokens.Space.M,
				LayoutOrder = 4,
				Children = vitalSwatches,
			}),
			Specimen(scope, {
				Title = "Borders & Washes",
				Note = "Drawn at their real transparency, over the same ground they are used on.",
				Height = 4 * (SWATCH_SIZE + Tokens.Space.S) + Tokens.Space.M,
				Direction = "Horizontal",
				Gap = Tokens.Space.S,
				AlignY = Enum.VerticalAlignment.Top,
				LayoutOrder = 5,
				Children = {
					Stack.Row(scope, {
						Gap = Tokens.Space.S,
						Wraps = true,
						Size = UDim2.fromScale(1, 1),
						Children = tintSwatches,
					}),
				},
			}),
			Specimen(scope, {
				Title = "Spacing",
				Height = #spacingOrder * (24 + Tokens.Space.XS) + Tokens.Space.M,
				Direction = "Vertical",
				Gap = Tokens.Space.XS,
				AlignY = Enum.VerticalAlignment.Top,
				LayoutOrder = 6,
				Children = spacingRows,
			}),
			-- Motion has no specimen yet, and saying so here is more useful than leaving a gap someone
			-- has to notice. Tokens.Motion is tuned and has almost no consumers in the menus -- that is
			-- Tier 3 of docs/architecture/2026-08-20-ui-velocity-plan.md, and this page is where its
			-- presets will be playable once Components/Transition.lua exists.
			Stack.New(scope, {
				Size = UDim2.new(1, 0, 0, 40),
				LayoutOrder = 7,
				Children = {
					Inset(scope, { Y = Tokens.Space.S }),
					Label(scope, {
						Text = "Motion presets are not shown here yet -- see the UI velocity plan, Tier 3.",
						Scale = "Detail",
						Color = Tokens.Color.TextDisabled,
						Size = UDim2.new(1, 0, 0, 20),
					}),
				},
			}),
		},
	})
end

return TokenPage
