--!strict
--[[
	CharacterTab.lua

	Owns: the character menu's first tab -- what this character IS MADE OF, as opposed to who they
	are (that's IdentityRail.lua, pinned to the left of every tab). Three vitals with their real
	ceilings, the conditions currently acting on them, the six-attribute block, and the derived
	figures those attributes actually produce.

	TWO SOURCES, AND THE SPLIT IS DELIBERATE. Condition fields (corruption, Qi deviation risk,
	faction standing) come from the Sheet prop -- Types.CharacterSheetPayload, fetched and pushed by
	Server/Systems/CharacterSheetSystem.lua. Everything that moves during a fight -- health, qi,
	posture, combat state, bounty flag -- comes from ClientState, which already carries it for the
	HUD. See CharacterSheetSystem.lua's own header for why the sheet deliberately does NOT restate
	the second group: two channels for one fact means the staler one wins whenever it happens to land
	last.

	THE DERIVED BLOCK SHOWS ONLY WHAT IS REAL, and that is why it is not the eight cells the design
	drew. "Atk Damage" and "Health Regen" were in the mockup; neither exists as a number anywhere in
	this codebase -- there is no Might-to-damage constant and no health regeneration system, so
	rendering either would be inventing a figure and attributing it to the server. What IS real gets
	shown: the three ceilings ClientState replicates, the Qi regeneration QiConstants genuinely
	derives from MeridianFlow, the guard pool and its regeneration from DefenseConstants, and the two
	standing numbers off the sheet. Those constants are Shared and are the same ones the systems
	themselves read, so this is reading the formula rather than guessing at its output -- the
	distinction ui-ux-philosophy.md's server-owns-truth rule actually turns on.

	RENDERS NOTHING IT WASN'T TOLD. A nil Sheet is a real state (the fetch hasn't answered yet, or
	the player's profile isn't loaded) and renders as an explicit dash rather than zeros -- a sheet
	showing 0 corruption and no attributes is indistinguishable from a real brand-new character.

	Does not own: fetching any of it (Client/CharacterMenu/CharacterMenuClient.lua drives the sheet
	fetch and writes the Value this reads), the hotbar's own vital tiles (Components/VitalIcon.lua is
	explicitly the HOTBAR's form factor -- see Components/VitalPill.lua's header on why the menu has
	its own), or the bloodline reroll (IdentityRail.lua, where the count it spends is).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Constants = require(ReplicatedStorage.Shared.Constants)
local QiConstants = require(ReplicatedStorage.Shared.QiConstants)
local QiDeviationConstants = require(ReplicatedStorage.Shared.QiDeviationConstants)
local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local Types = require(ReplicatedStorage.Shared.Types)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Components.Label)
local Bar = require(script.Parent.Parent.Parent.Components.Bar)
local Divider = require(script.Parent.Parent.Parent.Components.Divider)
local ScrollArea = require(script.Parent.Parent.Parent.Components.ScrollArea)
local SectionHeading = require(script.Parent.Parent.Parent.Components.SectionHeading)
local StatRow = require(script.Parent.Parent.Parent.Components.StatRow)
local StatusTag = require(script.Parent.Parent.Parent.Components.StatusTag)
local VitalPill = require(script.Parent.Parent.Parent.Components.VitalPill)
local ClientStateModule = require(script.Parent.Parent.Parent.State.ClientState)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type CharacterTabProps = {
	Width: number,
	Height: number,
	Visible: UsedAs<boolean>,
	LayoutOrder: number,
	Sheet: UsedAs<Types.CharacterSheetPayload?>,
	State: ClientStateModule.ClientState,
}

-- Row/cell heights all moved up with the 2026-08-20 type pass; the vertical rhythm here is sized
-- to the CURRENT scale, so a step that grows again wants these re-measured rather than trusted.
local VITAL_ROW_HEIGHT = 62
local VITAL_GAP = Tokens.Space.XS
local TAG_ROW_HEIGHT = 24
local ATTRIBUTE_ROW_HEIGHT = 52
local ATTRIBUTE_ABBREV_WIDTH = 42
local ATTRIBUTE_VALUE_WIDTH = 46
local ATTRIBUTE_BAR_HEIGHT = 3
local DERIVED_CELL_HEIGHT = 32
local DERIVED_CELL_GAP = Tokens.Space.XS

-- Deviation risk is a plain 0-100 meter whose top is QiDeviationConstants.TriggerThreshold (see
-- that constant's own comment). These two cuts turn it into the three words a player can act on --
-- there is no server-side banding to mirror, so the thresholds live here, beside the only surface
-- that renders them, rather than being invented as a shared constant with one consumer.
local DEVIATION_RISING_FRACTION = 0.25
local DEVIATION_CRITICAL_FRACTION = 0.6

-- One attribute row: three-letter abbreviation, full name, the plain-language effect line, the
-- number, and a track measured against the creation-time ceiling. Every string comes from
-- Constants.CharacterCreation rather than being retyped, so this tab can never disagree with the
-- chargen screens about what an attribute is called or what it does.
local function attributeRow(
	scope: Scope,
	field: string,
	sheet: UsedAs<Types.CharacterSheetPayload?>,
	layoutOrder: number
): Frame
	local color = Tokens.AttributeColor[field]

	local value = scope:Computed(function(use)
		local current = use(sheet)
		if not current or not current.Attributes then
			return 0
		end
		return (current.Attributes :: any)[field] :: number
	end)
	local valueText = scope:Computed(function(use)
		local current = use(sheet)
		if not current or not current.Attributes then
			return "--"
		end
		return tostring(use(value))
	end)

	return scope:New "Frame" {
		Name = field,
		Size = UDim2.new(1, 0, 0, ATTRIBUTE_ROW_HEIGHT),
		BackgroundTransparency = 1,
		LayoutOrder = layoutOrder,

		[Children] = {
			Label(scope, {
				Text = Constants.CharacterCreation.AttributeAbbreviations[field] or field,
				Scale = "NumeralSmall",
				Color = color,
				AnchorPoint = Vector2.new(0, 0),
				Position = UDim2.fromOffset(0, 10),
				Size = UDim2.fromOffset(ATTRIBUTE_ABBREV_WIDTH, 16),
			}),

			-- Name, effect line and track share one column so the track always spans exactly the
			-- text above it, whatever the row's real width turns out to be.
			scope:New "Frame" {
				Name = "Body",
				Position = UDim2.fromOffset(ATTRIBUTE_ABBREV_WIDTH, 0),
				Size = UDim2.new(1, -(ATTRIBUTE_ABBREV_WIDTH + ATTRIBUTE_VALUE_WIDTH + Tokens.Space.M), 1, 0),
				BackgroundTransparency = 1,

				[Children] = {
					Label(scope, {
						-- The DISPLAY name, never the field key -- see Constants.AttributeDisplayNames
						-- for why the two differ for exactly one attribute.
						Text = Constants.CharacterCreation.AttributeDisplayNames[field] or field,
						Scale = "Body",
						AnchorPoint = Vector2.new(0, 0),
						Position = UDim2.fromOffset(0, 8),
						Size = UDim2.new(0.52, 0, 0, 18),
					}),
					Label(scope, {
						Text = Constants.CharacterCreation.AttributeEffects[field] or "",
						Scale = "Detail",
						Color = Tokens.Color.TextSecondary,
						AnchorPoint = Vector2.new(1, 0),
						Position = UDim2.new(1, 0, 0, 9),
						Size = UDim2.new(0.48, 0, 0, 16),
						TextXAlignment = Enum.TextXAlignment.Right,
					}),
					-- Measured against the creation-time ceiling, which is the only ceiling that
					-- exists today (Constants.CharacterCreation.AttributeBudget's own comment
					-- anticipates a later tier-up grant raising it -- when that lands this Max is the
					-- one place to change).
					Bar(scope, {
						Value = value,
						Max = Constants.CharacterCreation.AttributeBudget.MaxPerAttribute,
						FillColor = color,
						-- Same hue at both stops: the design's own single-hue alpha ramp rather than
						-- a two-color blend (see Bar.lua's FillColorSecondary comment).
						FillColorSecondary = color,
						Glow = true,
						AnchorPoint = Vector2.new(0, 0),
						Position = UDim2.fromOffset(0, 35),
						Size = UDim2.new(1, 0, 0, ATTRIBUTE_BAR_HEIGHT),
					}),
				},
			},

			Label(scope, {
				Text = valueText,
				Scale = "Numeral",
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, 0, 0, 8),
				Size = UDim2.fromOffset(ATTRIBUTE_VALUE_WIDTH, 18),
				TextXAlignment = Enum.TextXAlignment.Right,
			}),

			scope:New "Frame" {
				Name = "Rule",
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.fromScale(0, 1),
				Size = UDim2.new(1, 0, 0, Tokens.Control.DividerThickness),
				BackgroundColor3 = Tokens.Border.Hairline.Color,
				BackgroundTransparency = Tokens.Border.Hairline.Transparency,
				BorderSizePixel = 0,
			},
		},
	} :: Frame
end

local function CharacterTab(scope: Scope, props: CharacterTabProps): Frame
	local sheet = props.Sheet
	local state = props.State

	local isLoaded = scope:Computed(function(use)
		return use(sheet) ~= nil
	end)

	-- Conditions. Each is a chip rather than a row because none of them is a quantity the player
	-- compares against another -- they are states, and a state either applies or doesn't.
	local combatText = scope:Computed(function(use)
		return if use(state.InCombat) then "In combat" else "At rest"
	end)
	local combatColor = scope:Computed(function(use)
		return if use(state.InCombat) then Tokens.Color.Danger else Tokens.Color.TextSecondary
	end)

	local corruptionText = scope:Computed(function(use)
		local current = use(sheet)
		return if current then `Corruption {current.Corruption}` else "Corruption --"
	end)
	local corruptionColor = scope:Computed(function(use)
		local current = use(sheet)
		if not current or current.Corruption <= 0 then
			return Tokens.Color.TextSecondary
		end
		return Tokens.Color.Warning
	end)

	local deviationFraction = scope:Computed(function(use)
		local current = use(sheet)
		if not current then
			return 0
		end
		return current.QiDeviationRisk / QiDeviationConstants.TriggerThreshold
	end)
	local deviationText = scope:Computed(function(use)
		if not use(sheet) then
			return "Deviation --"
		end
		local fraction = use(deviationFraction)
		if fraction >= DEVIATION_CRITICAL_FRACTION then
			return "Deviation critical"
		elseif fraction >= DEVIATION_RISING_FRACTION then
			return "Deviation rising"
		end
		return "Deviation low"
	end)
	local deviationColor = scope:Computed(function(use)
		local fraction = use(deviationFraction)
		if fraction >= DEVIATION_CRITICAL_FRACTION then
			return Tokens.Color.Danger
		elseif fraction >= DEVIATION_RISING_FRACTION then
			return Tokens.Color.Warning
		end
		return Tokens.VitalColor.Qi
	end)

	local attributeTotalText = scope:Computed(function(use)
		local current = use(sheet)
		if not current or not current.Attributes then
			return "-- allocated"
		end
		local total = 0
		for _, field in ipairs(Constants.CharacterCreation.AttributeFields) do
			total += ((current.Attributes :: any)[field] :: number) or 0
		end
		return `{total} allocated`
	end)

	-- Derived figures. See this file's header on why these eight and not the design's eight.
	local maxHealthText = scope:Computed(function(use)
		return tostring(math.floor(use(state.MaxHealth)))
	end)
	local maxQiText = scope:Computed(function(use)
		return tostring(math.floor(use(state.MaxQi)))
	end)
	local maxPostureText = scope:Computed(function(use)
		return tostring(math.floor(use(state.MaxPosture)))
	end)
	-- QiConstants' own formula, read rather than re-derived: base regen plus the per-point
	-- MeridianFlow bonus measured off that constant's declared baseline. This is the same expression
	-- Server/Systems/QiSystem.lua evaluates, which is what makes showing it here a readout instead of
	-- a guess.
	local qiRegenText = scope:Computed(function(use)
		local current = use(sheet)
		if not current or not current.Attributes then
			return "--"
		end
		local meridianFlow = ((current.Attributes :: any).MeridianFlow :: number) or QiConstants.BaselineMeridianFlow
		local regen = QiConstants.BaseRegenPerSecond
			+ (meridianFlow - QiConstants.BaselineMeridianFlow) * QiConstants.RegenPerSecondPerMeridianFlowPoint
		return string.format("%.1f /s", regen)
	end)
	local deviationRiskText = scope:Computed(function(use)
		local current = use(sheet)
		if not current then
			return "--"
		end
		return `{current.QiDeviationRisk} / {QiDeviationConstants.TriggerThreshold}`
	end)
	local factionStandingText = scope:Computed(function(use)
		local current = use(sheet)
		return if current then tostring(current.FactionStanding) else "--"
	end)

	local attributeChildren: { Instance } = {}
	-- Iterates the canonical field list rather than hand-listing six names -- the same rule
	-- Constants.CharacterCreation.AttributeFields' own header states for the chargen screens, so a
	-- seventh attribute would appear here without this file being touched.
	for index, field in ipairs(Constants.CharacterCreation.AttributeFields) do
		table.insert(attributeChildren, attributeRow(scope, field, sheet, index))
	end

	local attributeBlock = scope:New "Frame" {
		Name = "Attributes",
		Size = UDim2.new(1, 0, 0, ATTRIBUTE_ROW_HEIGHT * #Constants.CharacterCreation.AttributeFields),
		BackgroundTransparency = 1,
		LayoutOrder = 5,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			attributeChildren,
		},
	}

	local derivedCells: { { Caption: string, Value: UsedAs<string> } } = {
		{ Caption = "Max health", Value = maxHealthText },
		{ Caption = "Max qi", Value = maxQiText },
		{ Caption = "Qi regen", Value = qiRegenText },
		{ Caption = "Max posture", Value = maxPostureText },
		{ Caption = "Guard pool", Value = tostring(DefenseConstants.Guard.Max) },
		{ Caption = "Guard regen", Value = `{DefenseConstants.Guard.RegenPerSecond} /s` },
		{ Caption = "Deviation risk", Value = deviationRiskText },
		{ Caption = "Faction standing", Value = factionStandingText },
	}

	local derivedChildren: { Instance } = {
		scope:New "UIGridLayout" {
			CellSize = UDim2.new(0.5, -DERIVED_CELL_GAP / 2, 0, DERIVED_CELL_HEIGHT),
			CellPadding = UDim2.fromOffset(DERIVED_CELL_GAP, DERIVED_CELL_GAP),
			SortOrder = Enum.SortOrder.LayoutOrder,
		},
	}
	for index, cell in ipairs(derivedCells) do
		table.insert(
			derivedChildren,
			StatRow(scope, {
				Caption = cell.Caption,
				Value = cell.Value,
				Variant = "Framed",
				LayoutOrder = index,
			})
		)
	end

	local derivedRows = math.ceil(#derivedCells / 2)

	return scope:New "Frame" {
		Name = "CharacterTab",
		Size = UDim2.fromOffset(props.Width, props.Height),
		BackgroundTransparency = 1,
		Visible = props.Visible,
		LayoutOrder = props.LayoutOrder,

		[Children] = {
			ScrollArea(scope, {
				Name = "Body",
				Size = UDim2.fromScale(1, 1),

				Children = {
					scope:New "UIPadding" {
						PaddingRight = UDim.new(0, Tokens.Space.S),
					},
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Vertical,
						HorizontalAlignment = Enum.HorizontalAlignment.Left,
						Padding = UDim.new(0, Tokens.Space.M),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},

					-- Stated once, above everything, instead of every block independently explaining
					-- its own dashes. Inside the layout rather than floating over it: a UIListLayout
					-- skips non-visible children entirely, so this costs no space once the sheet
					-- arrives.
					Label(scope, {
						Text = "Waiting for your profile to load...",
						Scale = "Detail",
						Color = Tokens.Color.TextSecondary,
						Size = UDim2.new(1, 0, 0, 18),
						LayoutOrder = 0,
						Visible = scope:Computed(function(use)
							return not use(isLoaded)
						end),
					}),

					scope:New "Frame" {
						Name = "Vitals",
						Size = UDim2.new(1, 0, 0, VITAL_ROW_HEIGHT),
						BackgroundTransparency = 1,
						LayoutOrder = 1,

						[Children] = {
							scope:New "UIListLayout" {
								FillDirection = Enum.FillDirection.Horizontal,
								Padding = UDim.new(0, VITAL_GAP),
								SortOrder = Enum.SortOrder.LayoutOrder,
							},
							VitalPill(scope, {
								Caption = "Health",
								Value = state.Health,
								Max = state.MaxHealth,
								Color = Tokens.VitalColor.Health,
								-- Thirds of the row minus each cell's share of the two gaps between
								-- them, so the run ends flush with the column's right edge.
								Size = UDim2.new(1 / 3, -VITAL_GAP * 2 / 3, 1, 0),
								LayoutOrder = 1,
							}),
							VitalPill(scope, {
								Caption = "Qi",
								Value = state.Qi,
								Max = state.MaxQi,
								Color = Tokens.VitalColor.Qi,
								Size = UDim2.new(1 / 3, -VITAL_GAP * 2 / 3, 1, 0),
								LayoutOrder = 2,
							}),
							VitalPill(scope, {
								Caption = "Posture",
								Value = state.Posture,
								Max = state.MaxPosture,
								Color = Tokens.VitalColor.Posture,
								Size = UDim2.new(1 / 3, -VITAL_GAP * 2 / 3, 1, 0),
								LayoutOrder = 3,
							}),
						},
					},

					scope:New "Frame" {
						Name = "Conditions",
						Size = UDim2.new(1, 0, 0, TAG_ROW_HEIGHT),
						BackgroundTransparency = 1,
						LayoutOrder = 2,

						[Children] = {
							scope:New "UIListLayout" {
								FillDirection = Enum.FillDirection.Horizontal,
								VerticalAlignment = Enum.VerticalAlignment.Center,
								Padding = UDim.new(0, Tokens.Space.XS),
								SortOrder = Enum.SortOrder.LayoutOrder,
							},
							StatusTag(scope, { Label = combatText, Color = combatColor, LayoutOrder = 1 }),
							StatusTag(scope, {
								Label = corruptionText,
								Color = corruptionColor,
								LayoutOrder = 2,
							}),
							StatusTag(scope, { Label = deviationText, Color = deviationColor, LayoutOrder = 3 }),
							-- Only present while it's true: an "unmarked" chip would be a permanent
							-- reminder of a state that is the normal one, and the rail already carries
							-- the standing answer under Notoriety.
							StatusTag(scope, {
								Label = "Marked",
								Color = Tokens.Color.Danger,
								Tracked = true,
								LayoutOrder = 4,
								Visible = state.BountyMarked,
							}),
						},
					},

					Divider.Gradient(scope, {
						Fade = "Both",
						Tint = Tokens.Border.Standard,
						Size = UDim2.new(1, 0, 0, Tokens.Control.DividerThickness),
						LayoutOrder = 3,
					}),

					SectionHeading(scope, {
						Text = "Attributes",
						Note = attributeTotalText,
						LayoutOrder = 4,
					}),
					attributeBlock,

					SectionHeading(scope, {
						Text = "Derived Stats",
						LayoutOrder = 6,
					}),
					scope:New "Frame" {
						Name = "Derived",
						Size = UDim2.new(
							1,
							0,
							0,
							derivedRows * DERIVED_CELL_HEIGHT + (derivedRows - 1) * DERIVED_CELL_GAP
						),
						BackgroundTransparency = 1,
						LayoutOrder = 7,

						[Children] = derivedChildren,
					},
				},
			}),
		},
	} :: Frame
end

return CharacterTab
