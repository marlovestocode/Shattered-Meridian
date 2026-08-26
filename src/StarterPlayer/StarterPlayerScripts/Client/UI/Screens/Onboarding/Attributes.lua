--!strict
--[[
	Attributes.lua

	Owns: chargen screen 2 -- CreatorFrame's slots filled with the redesign's Attributes screen
	(docs/design/intro-redesign-figma-spec.md section 5): a header (eyebrow/title/origin line on the
	left, a live points readout + Reset on the right), a pip rail (one pip per point in the shared
	18-point pool), and one stat row per Constants.CharacterCreation.AttributeFields, each a
	Components/Bar.lua gradient+glow track and a Components/Stepper.lua control. No points dial and
	no per-row tick marks -- both cut by user decision, 2026-07-25: the dial triple-encoded one
	integer already covered by this header's readout AND the pip rail, and the ticks implied a
	10-step scale over a real range that corresponds to nothing (5-20 pre-rebalance, 10-20/11 values
	now -- see AttributeFloors' own comment in Constants.lua for the interim point-pool rebalance).
	The pip rail survived the same decision -- it wasn't named in it, and unlike the dial it isn't
	redundant (granular per-point state vs. one aggregate number).

	Every stepper click mutates the shared Attributes Fusion.Value directly and clamps itself to the
	race-aware floor (Constants.CharacterCreation.AttributeFloors) AND the remaining budget -- a
	presentation-scoped convenience so the player can never even ATTEMPT an invalid allocation from
	this screen, never a substitute for CharacterCreationSystem.ValidateAttributeBlock's own
	server-side re-check at Finalize time.

	Does not own: race selection (RaceSelect.lua/OriginCard.lua own computing a race's default
	block -- Reset here calls OriginCard.ComputeDefaultAttributes, the same function, rather than
	re-deriving it) or the actual commit (Confirmation.lua/OnboardingClient.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Types = require(ReplicatedStorage.Shared.Types)
local Constants = require(ReplicatedStorage.Shared.Constants)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Components.Label)
local TrackedLabel = require(script.Parent.Parent.Parent.Components.TrackedLabel)
local Button = require(script.Parent.Parent.Parent.Components.Button)
local Divider = require(script.Parent.Parent.Parent.Components.Divider)
local Bar = require(script.Parent.Parent.Parent.Components.Bar)
local Stepper = require(script.Parent.Parent.Parent.Components.Stepper)
local CreatorFrame = require(script.Parent.CreatorFrame)
local OriginCard = require(script.Parent.OriginCard)
local OnboardingTypes = require(script.Parent.Types)
local Inset = require(script.Parent.Parent.Parent.Components.Inset)

local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type AttributesProps = OnboardingTypes.AttributesProps

-- Narrower than AttributesProps -- just what one row actually reads. AttributesProps satisfies this
-- structurally (it has both fields plus more), so Attributes() below passes its own full props
-- straight through; Confirmation.lua's read-only sheet builds this shape directly instead of
-- fabricating unused ContinueRequested/BackRequested events just to satisfy a wider type.
export type AttributeRowProps = {
	SelectedRaceId: Fusion.Value<Types.RaceId?>,
	Attributes: Fusion.Value<Types.AttributeBlock>,
	-- Omit the Stepper and widen Track into the space it would have used -- Confirmation.lua's "your
	-- sheet" reuse of this row (docs/design/intro-redesign-handoff.md's designer direction: "Reuse
	-- the Attributes row component with the steppers removed").
	ReadOnly: boolean?,
}

local Config = Constants.CharacterCreation
local Budget = Config.AttributeBudget

local function sumAttributes(block: Types.AttributeBlock): number
	local sum = 0
	for _, field in ipairs(Config.AttributeFields) do
		sum += (block :: any)[field]
	end
	return sum
end

--
-- Row layout budget -- flex-1 doesn't exist in Roblox, so Track's width is `1 - everything else`,
-- spelled out here rather than guessed (CreatorFrame.lua's own "no guessing" discipline).
--

local ABBREV_WIDTH = 32
local NAME_WIDTH = 144
local DESC_WIDTH = 208
local ROW_GAP = Tokens.Space.M
local TRACK_RESERVED_WIDTH = ABBREV_WIDTH
	+ ROW_GAP
	+ NAME_WIDTH
	+ ROW_GAP
	+ DESC_WIDTH
	+ ROW_GAP
	+ Stepper.WIDTH
	+ ROW_GAP
-- ReadOnly rows swap the Stepper for a plain right-aligned number, so Track reclaims the difference.
local READONLY_VALUE_WIDTH = 48
local TRACK_RESERVED_WIDTH_READONLY = ABBREV_WIDTH
	+ ROW_GAP
	+ NAME_WIDTH
	+ ROW_GAP
	+ DESC_WIDTH
	+ ROW_GAP
	+ READONLY_VALUE_WIDTH
	+ ROW_GAP
local ROW_HEIGHT = 56

--
-- Pip rail -- one pip per point in the shared BonusPoolTotal pool. Collapses to a single segmented
-- (well, plain -- see below) bar under ~600px viewport width (docs/design/intro-redesign-handoff.md's
-- mobile pass: "eighteen 14x4px pips... fail on a phone... the pip rail collapses to one segmented
-- bar"). Viewport width is tracked reactively (unlike Tokens.lua's IS_TOUCH) because it's a real,
-- live-changing number a desktop player can actually resize past the breakpoint mid-session, not a
-- stable per-session platform fact.
--

local PIP_WIDTH, PIP_HEIGHT = 14, 4
local PIP_RAIL_HEIGHT = 36
local PIP_RAIL_COLLAPSE_WIDTH = 600

local function PipRail(scope: Scope, spent: Fusion.Computed<number>): Frame
	-- Guarded, not assumed -- Client/Intro/IntroCamera.lua treats CurrentCamera as possibly nil for
	-- the same reason. Falls back to sitting exactly at the collapse threshold
	-- (isCollapsed's strict "<" reads that as "not collapsed"), the same desktop-first default this
	-- screen already renders with before any real ViewportSize is known.
	local camera = Workspace.CurrentCamera
	local viewportWidth = scope:Value(if camera then camera.ViewportSize.X else PIP_RAIL_COLLAPSE_WIDTH)
	if camera then
		table.insert(
			scope,
			camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
				viewportWidth:set(camera.ViewportSize.X)
			end)
		)
	end
	local isCollapsed = scope:Computed(function(use)
		return use(viewportWidth) < PIP_RAIL_COLLAPSE_WIDTH
	end)
	local isExpanded = scope:Computed(function(use)
		return not use(isCollapsed)
	end)

	local pips: { Instance } = {}
	for index = 1, Budget.BonusPoolTotal do
		local isSpent = scope:Computed(function(use)
			return index <= use(spent)
		end)
		table.insert(
			pips,
			scope:New "Frame" {
				Name = "Pip" .. index,
				Size = UDim2.fromOffset(PIP_WIDTH, PIP_HEIGHT),
				LayoutOrder = index,
				BackgroundColor3 = scope:Computed(function(use)
					return if use(isSpent) then Tokens.Color.AccentPrimary else Tokens.Wash.Tick.Color
				end),
				BackgroundTransparency = scope:Computed(function(use)
					return if use(isSpent) then 0 else Tokens.Wash.Tick.Transparency
				end),
				BorderSizePixel = 0,

				[Children] = scope:New "UICorner" {
					CornerRadius = Tokens.Radius.Hairline,
				},
			}
		)
	end

	local spentText = scope:Computed(function(use)
		return `{use(spent)} of {Budget.BonusPoolTotal} spent`
	end)

	return scope:New "Frame" {
		Name = "PipRail",
		Size = UDim2.new(1, 0, 0, PIP_RAIL_HEIGHT),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.85, -- spec: "background rgba(0,0,0,0.15)".
		BorderSizePixel = 0,

		[Children] = {
			Inset(scope, { X = Tokens.Space.XXXL }),
			scope:New "Frame" {
				Name = "Pips",
				Size = UDim2.new(1, -160, 1, 0),
				BackgroundTransparency = 1,
				Visible = isExpanded,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						VerticalAlignment = Enum.VerticalAlignment.Center,
						Wraps = true,
						Padding = UDim.new(0, Tokens.Space.XS),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					table.unpack(pips),
				},
			},
			-- The collapsed fallback -- one plain Bar (its own gradient fill already reads as
			-- "segmented" per-hue at a glance) standing in for all 18 pips at once.
			scope:New "Frame" {
				Name = "CollapsedBar",
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.fromScale(0, 0.5),
				Size = UDim2.new(1, -160, 0, PIP_HEIGHT * 2),
				BackgroundTransparency = 1,
				Visible = isCollapsed,

				[Children] = Bar(scope, {
					Value = spent,
					Max = Budget.BonusPoolTotal,
					Size = UDim2.fromScale(1, 1),
					FillColor = Tokens.Color.AccentPrimary,
					Glow = true,
				}),
			},
			Label(scope, {
				Text = spentText,
				Scale = "NumeralSmall",
				Color = Tokens.Color.TextDisabled,
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.fromScale(1, 0.5),
				Size = UDim2.fromOffset(140, PIP_RAIL_HEIGHT),
				TextXAlignment = Enum.TextXAlignment.Right,
			}),
		},
	} :: Frame
end

--
-- Top header band -- eyebrow/title/origin line on the left, points readout + Reset on the right.
--

-- UIPadding (28 top + 28 bottom) + 2 gaps (Space.XS=4 each) + eyebrow(9) + title(22) + origin
-- line(11).
local TOP_HEADER_HEIGHT = 28 + 28 + 4 * 2 + 9 + 22 + 11
local HEADER_HEIGHT = TOP_HEADER_HEIGHT + PIP_RAIL_HEIGHT

local function Header(scope: Scope, props: AttributesProps, remaining: Fusion.Computed<number>): Frame
	local originRaceName = scope:Computed(function(use)
		return use(props.SelectedRaceId) or ""
	end)
	local originEpithetText = scope:Computed(function(use)
		local raceId = use(props.SelectedRaceId)
		return if raceId then `-- {Config.RaceEpithets[raceId] or ""}` else ""
	end)
	local remainingText = scope:Computed(function(use)
		return `{use(remaining)} / {Budget.BonusPoolTotal} left`
	end)

	local function resetToDefault(): ()
		local raceId = peek(props.SelectedRaceId)
		if not raceId then
			return
		end
		props.Attributes:set(OriginCard.ComputeDefaultAttributes(raceId))
	end

	return scope:New "Frame" {
		Name = "TopHeader",
		Size = UDim2.new(1, 0, 0, TOP_HEADER_HEIGHT),
		BackgroundTransparency = 1,

		[Children] = {
			Inset(scope, { X = Tokens.Space.XXXL, Y = Tokens.Space.XXL }),
			scope:New "Frame" {
				Name = "Left",
				Size = UDim2.new(1, -160, 1, 0),
				BackgroundTransparency = 1,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Vertical,
						Padding = UDim.new(0, Tokens.Space.XS),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					TrackedLabel(scope, {
						Text = "CHARACTER CREATION -- STEP 2",
						Scale = "Eyebrow",
						Color = Tokens.Color.TextDisabled,
						LayoutOrder = 1,
					}),
					Label(scope, {
						Text = "Allocate Your Attributes",
						Scale = "Heading",
						LayoutOrder = 2,
					}),
					scope:New "Frame" {
						Name = "OriginLine",
						Size = UDim2.fromOffset(0, 14),
						AutomaticSize = Enum.AutomaticSize.X,
						BackgroundTransparency = 1,
						LayoutOrder = 3,

						[Children] = {
							scope:New "UIListLayout" {
								FillDirection = Enum.FillDirection.Horizontal,
								VerticalAlignment = Enum.VerticalAlignment.Center,
								Padding = UDim.new(0, Tokens.Space.XS),
								SortOrder = Enum.SortOrder.LayoutOrder,
							},
							Label(scope, {
								Text = "Origin:",
								Scale = "Detail",
								Color = Tokens.Color.TextDisabled,
								LayoutOrder = 1,
							}),
							Label(scope, {
								Text = originRaceName,
								Scale = "SerifInline",
								Color = Tokens.Color.AccentPrimary,
								LayoutOrder = 2,
							}),
							Label(scope, {
								Text = originEpithetText,
								Scale = "Detail",
								Color = Tokens.Color.TextDisabled,
								LayoutOrder = 3,
							}),
						},
					},
				},
			},
			scope:New "Frame" {
				Name = "Right",
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.fromScale(1, 0.5),
				Size = UDim2.fromOffset(0, 0),
				AutomaticSize = Enum.AutomaticSize.XY,
				BackgroundTransparency = 1,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Vertical,
						HorizontalAlignment = Enum.HorizontalAlignment.Right,
						Padding = UDim.new(0, 2),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					TrackedLabel(scope, {
						Text = "POINTS",
						Scale = "Micro",
						Color = Tokens.Color.TextDisabled,
						LayoutOrder = 1,
					}),
					Label(scope, {
						Text = remainingText,
						Scale = "Numeral",
						Color = Tokens.Color.TextPrimary,
						TextXAlignment = Enum.TextXAlignment.Right,
						LayoutOrder = 2,
					}),
					Button(scope, {
						Text = "Reset",
						Variant = "Secondary",
						Size = UDim2.fromOffset(60, 22),
						LayoutOrder = 3,
						OnActivated = resetToDefault,
					}),
				},
			},
		},
	} :: Frame
end

--
-- Stat rows.
--

local function AttributeRow(scope: Scope, field: string, props: AttributeRowProps, layoutOrder: number): Frame
	local readOnly = props.ReadOnly == true
	local trackReservedWidth = if readOnly then TRACK_RESERVED_WIDTH_READONLY else TRACK_RESERVED_WIDTH

	local value = scope:Computed(function(use)
		return (use(props.Attributes) :: any)[field] :: number
	end)
	local color = Tokens.AttributeColor[field]
	local isHovering = scope:Value(false)

	local trailingControl: Instance
	if readOnly then
		trailingControl = Label(scope, {
			Text = scope:Computed(function(use)
				return tostring(use(value))
			end),
			Scale = "Numeral",
			Color = Tokens.Color.TextPrimary,
			Size = UDim2.fromOffset(READONLY_VALUE_WIDTH, 24),
			TextXAlignment = Enum.TextXAlignment.Right,
			LayoutOrder = 5,
		})
	else
		local function commit(newValue: number): ()
			local current = peek(props.Attributes)
			local currentValue = (current :: any)[field] :: number
			local delta = newValue - currentValue
			if delta > 0 and sumAttributes(current) + delta > Budget.TotalBudget then
				-- No remaining points left to spend -- refuse the increment rather than letting the
				-- player overspend the pool (Confirmation can't commit until this reads exactly 0
				-- remaining, so overspending here would just be a dead end).
				return
			end
			local updated = table.clone(current :: any)
			updated[field] = newValue
			props.Attributes:set(updated :: Types.AttributeBlock)
		end

		local floor = scope:Computed(function(use)
			local raceId = use(props.SelectedRaceId)
			return if raceId then Config.AttributeFloors[raceId][field] else Budget.MinPerAttribute
		end)

		trailingControl = Stepper.Mount(scope, {
			Value = value,
			Min = floor,
			Max = Budget.MaxPerAttribute,
			LayoutOrder = 5,
			OnChanged = function(newValue: number)
				local currentFloor = peek(floor)
				commit(math.clamp(newValue, currentFloor, Budget.MaxPerAttribute))
			end,
		})
	end

	return scope:New "Frame" {
		Name = field,
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
		BackgroundTransparency = 1,
		LayoutOrder = layoutOrder,

		[OnEvent "MouseEnter"] = function()
			isHovering:set(true)
		end,
		[OnEvent "MouseLeave"] = function()
			isHovering:set(false)
		end,

		[Children] = {
			-- "border-left: 2px solid transparent (lights to the attribute color on hover)". A direct
			-- sibling of Content below rather than a child of it -- Content owns the horizontal
			-- UIListLayout for the five real cells, and a UIListLayout arranges EVERY GuiObject sibling
			-- under it, not just its "intended" list items. Absolutely-positioned decoration like this
			-- accent bar and the Divider below must therefore live outside that layout's reach, one
			-- level up, or the layout would force them into the horizontal flow as oversized flex items.
			scope:New "Frame" {
				Name = "HoverAccent",
				Size = UDim2.new(0, 2, 1, 0),
				BackgroundColor3 = color,
				BackgroundTransparency = scope:Computed(function(use)
					return if use(isHovering) then 0 else 1
				end),
				BorderSizePixel = 0,
			},
			-- "separated by a 1px var(--border) rule inset margin-left/right: 24px" -- see HoverAccent's
			-- comment above for why this must also sit outside Content's UIListLayout: at nearly full
			-- row width, it would otherwise be forced into the horizontal flow as its own flex item and
			-- push every real cell off the visible row (the bug this structure fixes).
			Divider.Plain(scope, {
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.new(0, Tokens.Space.XL, 1, 0),
				Size = UDim2.new(1, -Tokens.Space.XL * 2, 0, 1),
			}),
			scope:New "Frame" {
				Name = "Content",
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,

				[Children] = {
					Inset(scope, { X = Tokens.Space.XXL }),
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						VerticalAlignment = Enum.VerticalAlignment.Center,
						Padding = UDim.new(0, ROW_GAP),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					TrackedLabel(scope, {
						Text = Config.AttributeAbbreviations[field] or field,
						Scale = "Abbrev",
						Color = color,
						Size = UDim2.fromOffset(ABBREV_WIDTH, 16),
						LayoutOrder = 1,
					}),
					Label(scope, {
						-- The DISPLAY name, never the field key (Constants.AttributeDisplayNames). This
						-- screen and the character menu have to agree about what an attribute is called,
						-- and rendering the raw key here is how they stopped agreeing.
						Text = Config.AttributeDisplayNames[field] or field,
						Scale = "BodyLarge",
						Size = UDim2.fromOffset(NAME_WIDTH, 20),
						LayoutOrder = 2,
					}),
					Bar(scope, {
						Value = value,
						Max = Budget.MaxPerAttribute,
						Size = UDim2.new(1, -trackReservedWidth, 0, 3),
						FillColor = color,
						FillColorSecondary = color,
						Glow = true,
						LayoutOrder = 3,
					}),
					Label(scope, {
						Text = Config.AttributeEffects[field] or "",
						Scale = "Detail",
						Color = Tokens.Color.TextDisabled,
						TextWrapped = true,
						Size = UDim2.fromOffset(DESC_WIDTH, 32),
						LayoutOrder = 4,
					}),
					trailingControl,
				},
			},
		},
	} :: Frame
end

-- A table, not a bare function -- Confirmation.lua's read-only "sheet" reuses AttributeRow directly
-- (AttributesModule.Row) rather than duplicating this file's row-building logic, per the designer's
-- own "reuse the Attributes row component" direction. See Components/Stepper.lua/VitalIcon.lua and
-- Screens/Onboarding/StepRail.lua/OriginCard.lua for the identical precedent.
local AttributesModule = {}
AttributesModule.Row = AttributeRow

function AttributesModule.Mount(scope: Scope, props: AttributesProps): Frame
	local remaining = scope:Computed(function(use)
		return Budget.TotalBudget - sumAttributes(use(props.Attributes))
	end)
	local spent = scope:Computed(function(use)
		return Budget.BonusPoolTotal - use(remaining)
	end)
	local continueDisabled = scope:Computed(function(use)
		return use(remaining) ~= 0
	end)
	local footerHint = scope:Computed(function(use)
		local left = use(remaining)
		return if left > 0 then `{left} point{if left == 1 then "" else "s"} unspent` else ""
	end)
	local blockingReason = scope:Computed(function(use)
		local left = use(remaining)
		return if left > 0 then `{left} LEFT` else ""
	end)

	local headerContent = scope:New "Frame" {
		Name = "Header",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			Header(scope, props, remaining),
			PipRail(scope, spent),
		},
	} :: Frame

	local rows: { Instance } = {}
	for index, field in ipairs(Config.AttributeFields) do
		table.insert(rows, AttributeRow(scope, field, props, index))
	end

	return CreatorFrame(scope, {
		Stage = "Attributes",
		StepRailNavigateRequested = props.StepRailNavigateRequested,
		BlockingReason = blockingReason,
		HeaderHeight = HEADER_HEIGHT,
		HeaderContent = { headerContent },
		-- UIListLayout, no UIPadding -- unlike RaceSelect.lua's own BodyContent, rows want zero gap and
		-- zero horizontal inset: each AttributeRow already pads itself (Space.XXL) and carries its own
		-- bottom Divider as the seam between rows, so stacking them flush (Padding = 0, the default)
		-- reads as one continuous sheet, matching CreatorFrame.lua's own "bands sit flush" language.
		BodyContent = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			table.unpack(rows),
		},
		FooterHint = footerHint,
		FooterButtons = {
			Button(scope, {
				Text = "Back",
				Variant = "Secondary",
				Size = UDim2.fromOffset(120, Tokens.Control.RowHeight),
				OnActivated = function()
					props.BackRequested:Fire()
				end,
			}),
			Button(scope, {
				Text = "Continue",
				Variant = "Primary",
				Size = UDim2.fromOffset(160, Tokens.Control.RowHeight),
				Disabled = continueDisabled,
				OnActivated = function()
					if peek(continueDisabled) then
						return
					end
					props.ContinueRequested:Fire()
				end,
			}),
		},
	}) :: Frame
end

return AttributesModule
