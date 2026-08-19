--!strict
--[[
	CharacterTab.lua

	Owns: the character menu's first tab -- who this character IS. Identity (chosen name, race and
	its epithet, faction), standing on the tier ladder with live progress toward the next rung, the
	six-attribute block, and the standing/condition numbers nothing else in the game surfaces
	(corruption, Qi deviation risk, faction standing, bloodlines, ascension, and whether the player
	is currently carrying a Notoriety bounty).

	TWO SOURCES, AND THE SPLIT IS DELIBERATE. Identity/standing fields come from the Sheet prop
	(Types.CharacterSheetPayload, fetched and pushed by Server/Systems/CharacterSheetSystem.lua);
	everything that moves during a fight -- tier, Meridian XP, Qi -- comes from ClientState, which
	already carries it for the HUD. See CharacterSheetSystem.lua's own header for why the sheet
	deliberately does NOT restate the second group: two channels for one fact means the staler one
	wins whenever it happens to land last, and tier/XP update on every kill where the sheet updates
	only on a profile-level change.

	RENDERS NOTHING IT WASN'T TOLD. A nil Sheet is a real state (the fetch hasn't answered yet, or
	the player's profile isn't loaded) and renders as an explicit "not loaded" line rather than
	zeros -- a character sheet showing 0 corruption and no race is indistinguishable from a real
	brand-new character, which is exactly the confusion ui-ux-philosophy.md's server-owns-truth rule
	exists to prevent.

	Does not own: fetching any of it (Client/CharacterMenu/CharacterMenuClient.lua drives the sheet
	fetch and writes the Value this reads), or the hotbar's own tier badge -- Components/TierBadge.lua
	is explicitly the HOTBAR's fixed-width readout (see its header), so this tab renders the same two
	server-sent numbers in its own full-width layout rather than embedding a component sized for a
	different surface.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Panel = require(script.Parent.Parent.Parent.Components.Panel)
local Label = require(script.Parent.Parent.Parent.Components.Label)
local Bar = require(script.Parent.Parent.Parent.Components.Bar)
local ScrollArea = require(script.Parent.Parent.Parent.Components.ScrollArea)
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

local ATTRIBUTE_ROW_HEIGHT = 34
local METER_HEIGHT = 6
local ATTRIBUTE_BAR_HEIGHT = 4

-- One "label on the left, value on the right" line -- the shape every standing/condition row in
-- this tab uses. Value is reactive; the caption never is.
local function statLine(scope: Scope, caption: string, value: UsedAs<string>, layoutOrder: number): Frame
	return scope:New "Frame" {
		Name = caption,
		Size = UDim2.new(1, 0, 0, 20),
		BackgroundTransparency = 1,
		LayoutOrder = layoutOrder,

		[Children] = {
			Label(scope, {
				Text = caption,
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.fromScale(0, 0.5),
			}),
			Label(scope, {
				Text = value,
				Scale = "Numeral",
				Color = Tokens.Color.TextPrimary,
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.fromScale(1, 0.5),
				TextXAlignment = Enum.TextXAlignment.Right,
			}),
		},
	} :: Frame
end

-- One attribute: three-letter abbreviation, full name, the number, a bar against the creation-time
-- ceiling, and the plain-language effect line. Every string here comes from
-- Constants.CharacterCreation rather than being retyped, so this tab can never disagree with the
-- chargen screens about what an attribute is called or what it does.
local function attributeRow(
	scope: Scope,
	field: string,
	sheet: UsedAs<Types.CharacterSheetPayload?>,
	layoutOrder: number
): Frame
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
				Color = Tokens.AttributeColor[field],
				AnchorPoint = Vector2.new(0, 0),
				Position = UDim2.fromOffset(0, 0),
			}),
			Label(scope, {
				Text = field,
				Scale = "Body",
				Color = Tokens.Color.TextPrimary,
				AnchorPoint = Vector2.new(0, 0),
				Position = UDim2.fromOffset(40, 0),
			}),
			Label(scope, {
				Text = Constants.CharacterCreation.AttributeEffects[field] or "",
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.new(0, 40, 1, 0),
			}),
			Label(scope, {
				Text = valueText,
				Scale = "Numeral",
				Color = Tokens.Color.TextPrimary,
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.fromScale(1, 0),
				TextXAlignment = Enum.TextXAlignment.Right,
			}),
			-- Measured against the creation-time ceiling, which is the only ceiling that exists today
			-- (Constants.CharacterCreation.AttributeBudget's own comment anticipates a later tier-up
			-- grant raising it -- when that lands this bar's Max is the one place to change).
			Bar(scope, {
				Value = value,
				Max = Constants.CharacterCreation.AttributeBudget.MaxPerAttribute,
				FillColor = Tokens.AttributeColor[field],
				AnchorPoint = Vector2.new(1, 1),
				Position = UDim2.new(1, 0, 1, -2),
				Size = UDim2.fromOffset(120, ATTRIBUTE_BAR_HEIGHT),
			}),
		},
	} :: Frame
end

local function CharacterTab(scope: Scope, props: CharacterTabProps): Frame
	local sheet = props.Sheet
	local state = props.State

	local isLoaded = scope:Computed(function(use)
		return use(sheet) ~= nil
	end)

	local nameText = scope:Computed(function(use)
		local current = use(sheet)
		if not current then
			return "Character"
		end
		-- displayName is nil exactly when raceId is nil (Types.PlayerProfile's own contract) -- a
		-- player who somehow reaches this menu without finishing chargen sees the honest gap, not an
		-- invented name.
		return current.DisplayName or "Unnamed"
	end)

	local epithetText = scope:Computed(function(use)
		local current = use(sheet)
		if not current or not current.RaceId then
			return "No origin recorded"
		end
		return Constants.CharacterCreation.RaceEpithets[current.RaceId] or current.RaceId
	end)

	local originText = scope:Computed(function(use)
		local current = use(sheet)
		if not current then
			return "Sheet not loaded"
		end
		local race = current.RaceId or "Unknown race"
		-- nil faction is the normal state, not an error: FactionManager is still a stub, and
		-- ArtConstants' open trees exist precisely so an unaligned player still has somewhere to go.
		local faction = current.Faction or "Unaligned"
		return `{race}  |  {faction}`
	end)

	local tierText = scope:Computed(function(use)
		return `Tier {use(state.Tier)}  --  {use(state.TierName)}`
	end)

	-- XP INTO the current tier over that tier's own span, exactly the presentation split
	-- Types.TierUpdatePayload documents (server owns tier identity, client fills the bar) -- which is
	-- what makes this move on every kill instead of only on a promotion.
	local tierProgress = scope:Computed(function(use)
		local floor = use(state.TierFloorXP)
		return math.max(use(state.MeridianXP) - floor, 0)
	end)
	local tierSpan = scope:Computed(function(use)
		local next_ = use(state.TierNextXP)
		if next_ == nil then
			return 1
		end
		return math.max(next_ - use(state.TierFloorXP), 1)
	end)
	local tierProgressText = scope:Computed(function(use)
		local next_ = use(state.TierNextXP)
		if next_ == nil then
			-- Top of the ladder -- see TierBadge.lua's own header on why "full" is the honest read of a
			-- tier with nothing left to earn.
			return `{use(state.MeridianXP)} Meridian XP  --  ladder complete`
		end
		return `{use(tierProgress)} / {use(tierSpan)} into this tier`
	end)

	local identityCard = Panel(scope, {
		Name = "Identity",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Elevated = true,
		CornerAccent = true,
		LayoutOrder = 1,

		Children = {
			scope:New "UIPadding" {
				PaddingTop = UDim.new(0, Tokens.Space.M),
				PaddingBottom = UDim.new(0, Tokens.Space.M),
				PaddingLeft = UDim.new(0, Tokens.Space.M),
				PaddingRight = UDim.new(0, Tokens.Space.M),
			},
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Left,
				Padding = UDim.new(0, Tokens.Space.XS),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			Label(scope, {
				Text = nameText,
				Scale = "Heading",
				LayoutOrder = 1,
			}),
			Label(scope, {
				Text = epithetText,
				Scale = "SerifInline",
				Color = Tokens.Color.AccentSecondary,
				LayoutOrder = 2,
			}),
			Label(scope, {
				Text = originText,
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				LayoutOrder = 3,
			}),
			scope:New "Frame" {
				Name = "TierRow",
				Size = UDim2.new(1, 0, 0, Tokens.Space.M),
				BackgroundTransparency = 1,
				LayoutOrder = 4,
			},
			Label(scope, {
				Text = tierText,
				Scale = "BodyLarge",
				Color = Tokens.Color.AccentPrimaryBright,
				LayoutOrder = 5,
			}),
			Bar(scope, {
				Value = tierProgress,
				Max = tierSpan,
				FillColor = Tokens.Color.AccentPrimary,
				Size = UDim2.new(1, 0, 0, METER_HEIGHT),
				LayoutOrder = 6,
			}),
			Label(scope, {
				Text = tierProgressText,
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				LayoutOrder = 7,
			}),
		},
	})

	local attributeChildren: { any } = {
		scope:New "UIPadding" {
			PaddingTop = UDim.new(0, Tokens.Space.M),
			PaddingBottom = UDim.new(0, Tokens.Space.M),
			PaddingLeft = UDim.new(0, Tokens.Space.M),
			PaddingRight = UDim.new(0, Tokens.Space.M),
		},
		scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Left,
			Padding = UDim.new(0, Tokens.Space.S),
			SortOrder = Enum.SortOrder.LayoutOrder,
		},
		Label(scope, {
			Text = "Attributes",
			Scale = "CardTitle",
			LayoutOrder = 1,
		}),
	}
	-- Iterates the canonical field list rather than hand-listing six names -- the same rule
	-- Constants.CharacterCreation.AttributeFields' own header states for the chargen screens, so a
	-- seventh attribute would appear here without this file being touched.
	for index, field in ipairs(Constants.CharacterCreation.AttributeFields) do
		table.insert(attributeChildren, attributeRow(scope, field, sheet, index + 1))
	end

	local attributesCard = Panel(scope, {
		Name = "Attributes",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 2,
		Children = attributeChildren,
	})

	local qiText = scope:Computed(function(use)
		return `{math.floor(use(state.Qi))} / {math.floor(use(state.MaxQi))}`
	end)
	local corruptionText = scope:Computed(function(use)
		local current = use(sheet)
		return if current then tostring(current.Corruption) else "--"
	end)
	local deviationText = scope:Computed(function(use)
		local current = use(sheet)
		return if current then tostring(current.QiDeviationRisk) else "--"
	end)
	local standingText = scope:Computed(function(use)
		local current = use(sheet)
		return if current then tostring(current.FactionStanding) else "--"
	end)
	local ascendedText = scope:Computed(function(use)
		local current = use(sheet)
		if not current then
			return "--"
		end
		return if current.HasAscended then "Yes" else "Not yet"
	end)
	local bloodlineText = scope:Computed(function(use)
		local current = use(sheet)
		if not current then
			return "--"
		end
		if #current.BloodlineIds == 0 then
			-- BloodlineManager is still an empty Init(), so this is the state every player is in --
			-- worded as "none awakened" rather than "none" so it reads as a stage of progression rather
			-- than a missing feature.
			return "None awakened"
		end
		return table.concat(current.BloodlineIds, ", ")
	end)
	local notorietyText = scope:Computed(function(use)
		if not use(state.BountyMarked) then
			return "Unmarked"
		end
		local reward = use(state.BountyReward)
		local streak = use(state.BountyStreak)
		return `Marked  --  {reward or 0} XP, {streak or 0} streak`
	end)

	local standingCard = Panel(scope, {
		Name = "Standing",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 3,

		Children = {
			scope:New "UIPadding" {
				PaddingTop = UDim.new(0, Tokens.Space.M),
				PaddingBottom = UDim.new(0, Tokens.Space.M),
				PaddingLeft = UDim.new(0, Tokens.Space.M),
				PaddingRight = UDim.new(0, Tokens.Space.M),
			},
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Left,
				Padding = UDim.new(0, Tokens.Space.XS),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			Label(scope, {
				Text = "Standing",
				Scale = "CardTitle",
				LayoutOrder = 1,
			}),
			-- Qi sits in this card rather than with the vitals on the HUD because THIS is where it's
			-- decision-relevant: it's what every art in the next tab is priced in.
			statLine(scope, "Qi", qiText, 2),
			statLine(scope, "Corruption", corruptionText, 3),
			statLine(scope, "Qi deviation risk", deviationText, 4),
			statLine(scope, "Faction standing", standingText, 5),
			statLine(scope, "Bloodlines", bloodlineText, 6),
			statLine(scope, "Ascended", ascendedText, 7),
			statLine(scope, "Notoriety", notorietyText, 8),
		},
	})

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
						Padding = UDim.new(0, Tokens.Space.S),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					-- Stated once, above the cards, instead of every card independently explaining its
					-- own dashes -- one line saying WHY everything reads "--" is more useful than six
					-- that don't. Inside the layout rather than floating over it: a UIListLayout skips
					-- non-visible children entirely, so this costs no space once the sheet arrives.
					Label(scope, {
						Text = "Waiting for your profile to load...",
						Scale = "Detail",
						Color = Tokens.Color.TextSecondary,
						Size = UDim2.new(1, 0, 0, 20),
						LayoutOrder = 0,
						Visible = scope:Computed(function(use)
							return not use(isLoaded)
						end),
					}),
					identityCard,
					attributesCard,
					standingCard,
				},
			}),
		},
	} :: Frame
end

return CharacterTab
