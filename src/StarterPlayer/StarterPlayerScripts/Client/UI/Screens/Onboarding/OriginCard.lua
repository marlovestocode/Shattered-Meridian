--!strict
--[[
	OriginCard.lua

	Owns: one race's selectable card on the Origin screen (docs/design/intro-redesign-figma-spec.md
	section 4), extracted from RaceSelect.lua's old inline RaceCard (which roughly triples in size
	under this redesign). Progressive disclosure per the designer's own direction: unselected shows
	Name + Epithet + World line + Cost line only; the selected card additionally reveals the 6-up
	stat grid with the race's REAL starting numbers (Constants.CharacterCreation.RacePrefills), never
	the Figma's own fabricated stat blocks -- see CharacterCreationConstants' own RaceEpithets/
	RaceWorldLines/RaceCostLines comment for why. Archetype chips (BALANCED/DEFENDER/STRIKER/MYSTIC)
	are deliberately absent -- same source, "they promise a class system that doesn't exist."

	Single-column stack, not the Figma's 2x2 grid -- a deliberate deviation. Progressive disclosure
	means the selected card is meaningfully TALLER than the other three (it alone reveals the stat
	grid), and Roblox's UIGridLayout forces one uniform CellSize across every cell, with no per-row
	auto-height the way CSS grid gives the Figma for free. A single full-width column sidesteps the
	mismatch entirely -- each card is exactly as tall as its own content, with no cross-card height
	coupling to fake. RaceSelect.lua (the caller) owns the actual stacking.

	Selected-state wash reuses Tokens.Wash.AccentBloom (a flat 6%-opacity accent tint) rather than
	hand-building the spec's 145deg 7%->2% two-stop gradient -- the token already exists for exactly
	"the faint wash behind a selected surface" (see its own comment in Tokens.lua), and the two read
	as the same thing at this opacity.

	Picking a card is still the one place a race's default attribute block gets computed (base +
	RacePrefills) -- unchanged from the old RaceCard, see RaceSelect.lua's own header for why that
	stays a presentation-scoped reset rather than round-tripping through OnboardingClient.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Types = require(ReplicatedStorage.Shared.Types)
local Constants = require(ReplicatedStorage.Shared.Constants)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Components.Label)
local TrackedLabel = require(script.Parent.Parent.Parent.Components.TrackedLabel)
local Divider = require(script.Parent.Parent.Parent.Components.Divider)
local Bar = require(script.Parent.Parent.Parent.Components.Bar)
local Glow = require(script.Parent.Parent.Parent.Components.Glow)
local Inset = require(script.Parent.Parent.Parent.Components.Inset)

local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>

local Config = Constants.CharacterCreation

export type OriginCardProps = {
	RaceId: Types.RaceId,
	SelectedRaceId: Fusion.Value<Types.RaceId?>,
	Attributes: Fusion.Value<Types.AttributeBlock>,
	LayoutOrder: number,
}

-- Same reset RaceSelect.lua's old RaceCard performed -- see this file's header. Exported (this file
-- is a table, not a bare function, for the same reason as Components/Stepper.lua/VitalIcon.lua and
-- Screens/Onboarding/StepRail.lua) because Attributes.lua's own Reset control needs the identical
-- computation for its own second caller -- see that file's own use of
-- OriginCardModule.ComputeDefaultAttributes.
local function computeRaceDefaultAttributes(raceId: Types.RaceId): Types.AttributeBlock
	local budget = Config.AttributeBudget
	local prefill = Config.RacePrefills[raceId] or {}
	local block: { [string]: number } = {}
	for _, field in ipairs(Config.AttributeFields) do
		block[field] = budget.BaseValuePerAttribute + (prefill[field] or 0)
	end
	return block :: Types.AttributeBlock
end

local INDICATOR_SIZE = 16
local DOT_SIZE = 6

local function SelectionIndicator(scope: Scope, isSelected: Fusion.Computed<boolean>): Frame
	-- "fade-in .2s" (spec) -- the dot's own appearance, not the ring's, which is a plain color swap.
	local dotTransparency = scope:Spring(
		scope:Computed(function(use)
			return if use(isSelected) then 0 else 1
		end),
		Tokens.Motion.FadeSpring.Speed,
		Tokens.Motion.FadeSpring.Damping
	)

	return scope:New "Frame" {
		Name = "SelectionIndicator",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(INDICATOR_SIZE, INDICATOR_SIZE),
		BackgroundTransparency = 1,

		[Children] = {
			scope:New "UICorner" {
				CornerRadius = UDim.new(0.5, 0),
			},
			scope:New "UIStroke" {
				Color = scope:Computed(function(use)
					return if use(isSelected) then Tokens.Color.AccentPrimary else Tokens.Color.TextDisabled
				end),
				Thickness = 1,
			},
			Glow(scope, {
				Color = Tokens.Color.AccentPrimary,
				Visible = isSelected,
				CornerRadius = UDim.new(0.5, 0),
				Spread = 6,
				Rings = 2,
				Transparency = 0.5,
			}),
			scope:New "Frame" {
				Name = "Dot",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(DOT_SIZE, DOT_SIZE),
				BackgroundColor3 = Tokens.Color.AccentPrimary,
				BackgroundTransparency = dotTransparency,
				BorderSizePixel = 0,

				[Children] = scope:New "UICorner" {
					CornerRadius = UDim.new(0.5, 0),
				},
			},
		},
	} :: Frame
end

local function StatCell(
	scope: Scope,
	field: string,
	attributes: Fusion.Value<Types.AttributeBlock>,
	layoutOrder: number
): Frame
	local value = scope:Computed(function(use)
		return (use(attributes) :: any)[field] :: number
	end)
	local valueText = scope:Computed(function(use)
		return tostring(use(value))
	end)
	local color = Tokens.AttributeColor[field]

	return scope:New "Frame" {
		Name = field,
		Size = UDim2.new(1, 0, 0, 28),
		BackgroundTransparency = 1,
		LayoutOrder = layoutOrder,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				Padding = UDim.new(0, 2),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			scope:New "Frame" {
				Name = "Header",
				Size = UDim2.new(1, 0, 0, 12),
				BackgroundTransparency = 1,
				LayoutOrder = 1,

				[Children] = {
					TrackedLabel(scope, {
						Text = Config.AttributeAbbreviations[field] or field,
						Scale = "Abbrev",
						Color = Tokens.Color.TextDisabled,
					}),
					Label(scope, {
						Text = valueText,
						Scale = "NumeralSmall",
						Color = color,
						AnchorPoint = Vector2.new(1, 0),
						Position = UDim2.fromScale(1, 0),
						TextXAlignment = Enum.TextXAlignment.Right,
					}),
				},
			},
			Bar(scope, {
				Value = value,
				Max = Config.AttributeBudget.MaxPerAttribute,
				Size = UDim2.new(1, 0, 0, 2),
				FillColor = color,
				LayoutOrder = 2,
			}),
		},
	} :: Frame
end

local function StatGrid(
	scope: Scope,
	attributes: Fusion.Value<Types.AttributeBlock>,
	isSelected: Fusion.Computed<boolean>
): Frame
	local cells: { Instance } = {}
	for index, field in ipairs(Config.AttributeFields) do
		table.insert(cells, StatCell(scope, field, attributes, index))
	end

	return scope:New "Frame" {
		Name = "StatGrid",
		-- UDim2.fromScale(1, 0), not fromOffset(0, 0) -- AutomaticSize.Y only frees the HEIGHT; the
		-- width still comes from whatever Size.X says, and fromOffset's Scale.X of 0 pinned this (and
		-- every sibling frame below with the same mistake) to a literal zero-width frame, which is
		-- why every card's text rendered clipped to a sliver instead of the panel's real width.
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Visible = isSelected,
		ClipsDescendants = true,
		LayoutOrder = 5,

		[Children] = {
			scope:New "UIGridLayout" {
				CellSize = UDim2.new(1 / 3, -Tokens.Space.M, 0, 28),
				CellPadding = UDim2.fromOffset(Tokens.Space.M, Tokens.Space.S),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			table.unpack(cells),
		},
	} :: Frame
end

local OriginCardModule = {}
OriginCardModule.ComputeDefaultAttributes = computeRaceDefaultAttributes

function OriginCardModule.Mount(scope: Scope, props: OriginCardProps): TextButton
	local isSelected = scope:Computed(function(use)
		return use(props.SelectedRaceId) == props.RaceId
	end)

	local backgroundColor = scope:Computed(function(use)
		return if use(isSelected) then Tokens.Wash.AccentBloom.Color else Tokens.Wash.CardResting.Color
	end)
	local backgroundTransparency = scope:Computed(function(use)
		return if use(isSelected) then Tokens.Wash.AccentBloom.Transparency else Tokens.Wash.CardResting.Transparency
	end)
	local borderColor = scope:Computed(function(use)
		return if use(isSelected) then Tokens.Border.Accent.Color else Tokens.Border.Hairline.Color
	end)
	local borderTransparency = scope:Computed(function(use)
		return if use(isSelected) then Tokens.Border.Accent.Transparency else Tokens.Border.Hairline.Transparency
	end)
	local nameColor = scope:Computed(function(use)
		return if use(isSelected) then Tokens.Color.TextPrimary else Tokens.Color.TextSecondary
	end)

	return scope:New "TextButton" {
		Name = props.RaceId .. "Card",
		LayoutOrder = props.LayoutOrder,
		-- See StatGrid's comment above -- fromOffset(0, 0) pins width to 0, not "auto".
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = backgroundColor,
		BackgroundTransparency = backgroundTransparency,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = "",

		[OnEvent "Activated"] = function()
			-- Re-selecting the already-selected race is a no-op, not a reset -- see RaceSelect.lua's
			-- own header on the allocation-wipe bug this guard fixed.
			if peek(props.SelectedRaceId) == props.RaceId then
				return
			end
			props.SelectedRaceId:set(props.RaceId)
			props.Attributes:set(computeRaceDefaultAttributes(props.RaceId))
		end,

		[Children] = {
			scope:New "UICorner" {
				CornerRadius = Tokens.Radius.Hairline,
			},
			scope:New "UIStroke" {
				Color = borderColor,
				Transparency = borderTransparency,
				Thickness = 1,
			},
			Glow(scope, {
				Color = Tokens.Color.AccentPrimary,
				Visible = isSelected,
				CornerRadius = Tokens.Radius.Hairline,
				Spread = 40,
				Transparency = 0.94,
			}),
			scope:New "Frame" {
				Name = "Content",
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				ZIndex = 2,

				[Children] = {
					Inset(scope, { X = Tokens.Space.XL, Y = Tokens.Space.L }),
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Vertical,
						Padding = UDim.new(0, Tokens.Space.M),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},

					scope:New "Frame" {
						Name = "HeaderRow",
						Size = UDim2.fromScale(1, 0),
						AutomaticSize = Enum.AutomaticSize.Y,
						BackgroundTransparency = 1,
						LayoutOrder = 1,

						[Children] = {
							scope:New "Frame" {
								Name = "NameColumn",
								Size = UDim2.new(1, -(INDICATOR_SIZE + Tokens.Space.S), 0, 0),
								AutomaticSize = Enum.AutomaticSize.Y,
								BackgroundTransparency = 1,

								[Children] = {
									scope:New "UIListLayout" {
										FillDirection = Enum.FillDirection.Vertical,
										Padding = UDim.new(0, 2),
										SortOrder = Enum.SortOrder.LayoutOrder,
									},
									Label(scope, {
										Text = props.RaceId,
										Scale = "CardTitle",
										Color = nameColor,
										LayoutOrder = 1,
									}),
									Label(scope, {
										Text = Config.RaceEpithets[props.RaceId] or "",
										Scale = "Detail",
										Color = Tokens.Color.TextDisabled,
										LayoutOrder = 2,
									}),
								},
							},
							SelectionIndicator(scope, isSelected),
						},
					},

					Divider.Plain(scope, {
						Tint = Tokens.Border.Hairline, -- spec's `var(--border)`, not the bolder --border-mid.
						LayoutOrder = 2,
					}),

					-- Fixed heights, not AutomaticSize -- Label.lua ties AutomaticSize to "was Size
					-- passed at all" (XY or None, no Y-only option), so a wrapped label needs an
					-- explicit height budget the same way Screens/Announcement/init.lua's own
					-- TextWrapped caller already does; exact wrap point depends on the card's real
					-- width (RaceSelect.lua's layout), so these sizes are generous enough for the
					-- longest of the four WorldLines/CostLines at two lines each.
					Label(scope, {
						Text = Config.RaceWorldLines[props.RaceId] or "",
						Scale = "Body",
						Color = Tokens.Color.TextSecondary,
						TextWrapped = true,
						Size = UDim2.new(1, 0, 0, 36),
						LayoutOrder = 3,
					}),

					Label(scope, {
						Text = Config.RaceCostLines[props.RaceId] or "",
						Scale = "DetailEmphasis",
						Color = Tokens.Color.TextDisabled,
						TextWrapped = true,
						Size = UDim2.new(1, 0, 0, 32),
						LayoutOrder = 4,
					}),

					StatGrid(scope, props.Attributes, isSelected),
				},
			},
		},
	} :: TextButton
end

return OriginCardModule
