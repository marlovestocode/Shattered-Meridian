--!strict
--[[
	IdentityRail.lua

	Owns: the character menu's fixed left column -- the one part of the screen that does NOT change
	when you switch tabs. The portrait plate, the character's name and race epithet, their race and
	faction as chips, where they stand on the Meridian ladder, and the standing figures that describe
	the character rather than any one system (bloodlines and rerolls, faction standing, ascension,
	whether they are currently carrying a bounty).

	WHY A RAIL AND NOT A TAB. Everything here answers "who is this" -- which is the question the
	player is holding in their head while they read ANY of the four tabs. An art's tier gate means
	nothing without your tier beside it; a bounty's reward means nothing without knowing whether the
	marked player is you. Putting identity in a tab would make every cross-reference a tab switch, so
	it is pinned instead and the tabs carry only what is genuinely tab-specific.

	TWO SOURCES, AND THE SPLIT IS THE SAME ONE CharacterTab HOLDS. Identity and standing come from
	the Sheet prop (Types.CharacterSheetPayload, pushed by Server/Systems/CharacterSheetSystem.lua);
	tier, Meridian XP and the bounty flags come from ClientState, which already carries them for the
	HUD and updates on every kill where the sheet only updates on a profile-level change. See
	CharacterSheetSystem.lua's header for why the sheet deliberately does not restate the second
	group.

	RENDERS NOTHING IT WASN'T TOLD. A nil Sheet is a real state -- the fetch hasn't answered, or the
	profile isn't loaded -- and every field it feeds reads as an explicit dash rather than a zero. A
	sheet showing 0 corruption and no race is indistinguishable from a real brand-new character,
	which is exactly the confusion ui-ux-philosophy.md's server-owns-truth rule exists to prevent.

	Does not own: the reroll round trip. The button here fires the OnRerollBloodline prop, which
	Screens/Menus/init.lua turns into a signal for Client/CharacterMenu/CharacterMenuClient.lua to
	send -- the same boundary every tab in this screen holds.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Components.Label)
local Button = require(script.Parent.Parent.Parent.Components.Button)
local Divider = require(script.Parent.Parent.Parent.Components.Divider)
local ScrollArea = require(script.Parent.Parent.Parent.Components.ScrollArea)
local SectionHeading = require(script.Parent.Parent.Parent.Components.SectionHeading)
local SegmentMeter = require(script.Parent.Parent.Parent.Components.SegmentMeter)
local StatRow = require(script.Parent.Parent.Parent.Components.StatRow)
local StatusTag = require(script.Parent.Parent.Parent.Components.StatusTag)
local CharacterPortrait = require(script.Parent.Parent.Parent.Components.CharacterPortrait)
local ClientStateModule = require(script.Parent.Parent.Parent.State.ClientState)
local Inset = require(script.Parent.Parent.Parent.Components.Inset)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type IdentityRailProps = {
	Width: number,
	Height: number,
	-- Its place in the body row. The rail used to be positioned absolutely at the body's origin; it
	-- is now the first item of a Components/Stack.lua row, and a Stack sorts by LayoutOrder rather
	-- than by child order on purpose (see that module's own SortOrder comment).
	LayoutOrder: UsedAs<number>?,
	Sheet: UsedAs<Types.CharacterSheetPayload?>,
	State: ClientStateModule.ClientState,
	-- Live per-art mastery (the Art_StateUpdated map Screens/Menus/init.lua holds). Read here only
	-- to count how many arts this character has taken -- the rail never renders an art by name.
	Mastery: UsedAs<{ [string]: number }>,
	OnRerollBloodline: () -> (),
}

local PADDING = Tokens.Space.L
local TIER_ROW_HEIGHT = 36
local TAG_ROW_HEIGHT = 24
-- The portrait plate's height as a fraction of its width. See CharacterPortrait.lua's own
-- Width/Height comment for why this is not 1.
local PORTRAIT_ASPECT = 0.78

-- Tier is rendered as a Roman numeral, not an Arabic one. The ladder is a rank rather than a count
-- -- "Tier III, Opened Vein" is a title the way "Sealed Vein" is, and a Roman numeral is the one
-- typographic cue that says rank rather than quantity without spending a word on it. Covers the
-- ladder's real depth (QiConstants.MaxTierDefined is 9); anything past that falls back to the
-- Arabic number rather than inventing notation, so a future ladder extension degrades legibly
-- instead of rendering blank.
local ROMAN_NUMERALS = { "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX" }

local function romanNumeral(tier: number): string
	return ROMAN_NUMERALS[tier] or tostring(tier)
end

local function IdentityRail(scope: Scope, props: IdentityRailProps): Frame
	local sheet = props.Sheet
	local state = props.State
	local portraitWidth = props.Width - PADDING * 2
	-- Guarded rather than assumed: this module is constructed by a headless smoke test where
	-- Players.LocalPlayer is nil, and CharacterPortrait treats a nil UserId as "draw the fallback"
	-- rather than as an error.
	local localPlayer = Players.LocalPlayer
	local portraitUserId = if localPlayer then localPlayer.UserId else nil

	local nameText = scope:Computed(function(use)
		local current = use(sheet)
		if not current then
			return "..."
		end
		-- DisplayName is nil exactly when RaceId is nil (Types.PlayerProfile's own contract) -- a
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

	local raceText = scope:Computed(function(use)
		local current = use(sheet)
		return if current and current.RaceId then current.RaceId else "Unknown"
	end)

	-- A nil faction is the normal state, not an error: FactionManager is still a stub, and
	-- ArtConstants' open trees exist precisely so an unaligned player still has somewhere to go.
	local factionText = scope:Computed(function(use)
		local current = use(sheet)
		return if current and current.Faction then current.Faction else "Unaligned"
	end)

	local tierNumeral = scope:Computed(function(use)
		return romanNumeral(use(state.Tier))
	end)

	-- XP INTO the current tier over that tier's own span, exactly the presentation split
	-- Types.TierUpdatePayload documents (server owns tier identity, client fills the meter) -- which
	-- is what makes this move on every kill instead of only on a promotion.
	local tierProgress = scope:Computed(function(use)
		return math.max(use(state.MeridianXP) - use(state.TierFloorXP), 0)
	end)
	local tierSpan = scope:Computed(function(use)
		local next_ = use(state.TierNextXP)
		if next_ == nil then
			return 1
		end
		return math.max(next_ - use(state.TierFloorXP), 1)
	end)
	local tierRatioText = scope:Computed(function(use)
		if use(state.TierNextXP) == nil then
			return "MAX"
		end
		return `{use(tierProgress)} / {use(tierSpan)}`
	end)
	local tierFootnote = scope:Computed(function(use)
		if use(state.TierNextXP) == nil then
			-- Top of the ladder -- see TierBadge.lua's own header on why "full" is the honest read of
			-- a tier with nothing left to earn.
			return `{use(state.MeridianXP)} Meridian XP -- ladder complete`
		end
		return `{use(tierProgress)} Meridian XP into this tier`
	end)

	local artsMasteredText = scope:Computed(function(use)
		local count = 0
		for _ in pairs(use(props.Mastery)) do
			count += 1
		end
		return tostring(count)
	end)

	-- THE COUNT GOES IN THE ROW, THE NAMES GO UNDERNEATH. This used to concatenate every bloodline id
	-- into the row's own value cell, which is a fixed-width, right-aligned, single-line box -- and
	-- three ids ("amberlane, gutterlight, stillwater_vein") do not fit in a 244px rail. A non-wrapping
	-- TextLabel in Roblox does not clip, so the run drew leftward straight out through the panel
	-- border and across the game world behind it. Components/Label.lua now truncates by default,
	-- which stops the bleed -- but an ellipsis in a 60px cell is not a readable answer either, so the
	-- names get a wrapped line of their own where they have the whole column's width to use.
	local bloodlineCountText = scope:Computed(function(use)
		local current = use(sheet)
		if not current then
			return "--"
		end
		local count = #current.BloodlineIds
		-- Worded as a stage of progression rather than a missing feature: BloodlineSystem.Awaken is
		-- real and fires off GameplayEvents.OnPlayerKilled, so zero is a genuine "not yet".
		return if count == 0 then "None" else tostring(count)
	end)
	local bloodlineNames = scope:Computed(function(use)
		local current = use(sheet)
		if not current or #current.BloodlineIds == 0 then
			return ""
		end
		return table.concat(current.BloodlineIds, ", ")
	end)
	local hasBloodlines = scope:Computed(function(use)
		return use(bloodlineNames) ~= ""
	end)

	-- Read off the profile rather than tallied locally -- the server is what charges a reroll, so
	-- anything counted here could only ever drift from what it will actually allow.
	local rerollsRemaining = scope:Computed(function(use)
		local current = use(sheet)
		return if current then current.BloodlineRerolls else 0
	end)
	local rerollsText = scope:Computed(function(use)
		return if use(sheet) then tostring(use(rerollsRemaining)) else "--"
	end)
	local rerollDisabled = scope:Computed(function(use)
		return use(sheet) == nil or use(rerollsRemaining) <= 0
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
	local notorietyText = scope:Computed(function(use)
		if not use(state.BountyMarked) then
			return "Unmarked"
		end
		return `{use(state.BountyReward) or 0} XP`
	end)
	local notorietyColor = scope:Computed(function(use)
		return if use(state.BountyMarked) then Tokens.Color.Danger else Tokens.Color.TextPrimary
	end)

	return scope:New "Frame" {
		Name = "IdentityRail",
		Size = UDim2.fromOffset(props.Width, props.Height),
		LayoutOrder = props.LayoutOrder,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		-- The rail is the narrowest column in the menu and carries the longest server-authored
		-- strings (character names, bloodline id lists). Label.lua truncates rather than overflowing
		-- now, but this is the structural backstop: nothing in this column can paint outside it, so a
		-- future row that forgets to size itself cannot escape into the panel border or the world
		-- behind it.
		ClipsDescendants = true,

		[Children] = {
			-- The column rule, drawn as this rail's own right edge rather than as a sibling between
			-- the rail and the tab body -- one owner for the seam, so it can never end up drawn twice
			-- or drawn at a height that disagrees with the column beside it.
			scope:New "Frame" {
				Name = "ColumnRule",
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.fromScale(1, 0),
				Size = UDim2.new(0, Tokens.Control.DividerThickness, 1, 0),
				BackgroundColor3 = Tokens.Border.Standard.Color,
				BackgroundTransparency = Tokens.Border.Standard.Transparency,
				BorderSizePixel = 0,
				ZIndex = 2,
			},

			ScrollArea(scope, {
				Name = "RailBody",
				Size = UDim2.fromScale(1, 1),

				Children = {
					Inset(scope, PADDING),
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Vertical,
						HorizontalAlignment = Enum.HorizontalAlignment.Left,
						Padding = UDim.new(0, Tokens.Space.S),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},

					CharacterPortrait(scope, {
						-- Full rail content width -- the plate is the widest thing in the column and
						-- everything below aligns to its edges -- but deliberately shorter than it is
						-- wide, so the tier block below still clears the fold on open. See that
						-- component's own Width/Height comment.
						Width = portraitWidth,
						Height = math.round(portraitWidth * PORTRAIT_ASPECT),
						UserId = portraitUserId,
						LayoutOrder = 1,
					}),

					Label(scope, {
						Text = nameText,
						Scale = "CardTitle",
						LayoutOrder = 2,
						Size = UDim2.new(1, 0, 0, 22),
					}),
					Label(scope, {
						Text = epithetText,
						Scale = "Body",
						Color = Tokens.Color.AccentSecondary,
						LayoutOrder = 3,
						Size = UDim2.new(1, 0, 0, 18),
					}),

					scope:New "Frame" {
						Name = "OriginTags",
						Size = UDim2.new(1, 0, 0, TAG_ROW_HEIGHT),
						BackgroundTransparency = 1,
						LayoutOrder = 4,

						[Children] = {
							scope:New "UIListLayout" {
								FillDirection = Enum.FillDirection.Horizontal,
								VerticalAlignment = Enum.VerticalAlignment.Center,
								Padding = UDim.new(0, Tokens.Space.XS),
								SortOrder = Enum.SortOrder.LayoutOrder,
							},
							StatusTag(scope, {
								Label = raceText,
								Color = Tokens.Color.AccentPrimary,
								LayoutOrder = 1,
							}),
							StatusTag(scope, {
								Label = factionText,
								LayoutOrder = 2,
							}),
						},
					},

					Divider.Gradient(scope, {
						Fade = "Both",
						Tint = Tokens.Border.Standard,
						Size = UDim2.new(1, 0, 0, Tokens.Control.DividerThickness),
						LayoutOrder = 5,
					}),

					SectionHeading(scope, {
						Text = "Meridian Tier",
						Note = tierRatioText,
						NoteColor = Tokens.Color.TextDisabled,
						LayoutOrder = 6,
					}),
					scope:New "Frame" {
						Name = "TierRow",
						Size = UDim2.new(1, 0, 0, TIER_ROW_HEIGHT),
						BackgroundTransparency = 1,
						LayoutOrder = 7,

						[Children] = {
							Label(scope, {
								Text = tierNumeral,
								Scale = "NumeralLarge",
								AnchorPoint = Vector2.new(0, 1),
								Position = UDim2.fromScale(0, 1),
								Size = UDim2.fromOffset(38, Tokens.Type.NumeralLarge.Size + 2),
							}),
							Label(scope, {
								Text = state.TierName,
								Scale = "Body",
								Color = Tokens.Color.TextSecondary,
								AnchorPoint = Vector2.new(0, 1),
								-- Sat on the numeral's own baseline rather than centred beside it, so
								-- the rank and its name read as one line instead of two stacked ones.
								Position = UDim2.new(0, 42, 1, -3),
								Size = UDim2.new(1, -42, 0, 18),
							}),
						},
					},
					SegmentMeter(scope, {
						Value = tierProgress,
						Max = tierSpan,
						LayoutOrder = 8,
					}),
					Label(scope, {
						Text = tierFootnote,
						Scale = "Detail",
						-- TextSecondary, not TextDisabled: this line is telling the player something,
						-- not showing them a control they cannot use.
						Color = Tokens.Color.TextSecondary,
						LayoutOrder = 9,
						Size = UDim2.new(1, 0, 0, 16),
					}),

					Divider.Gradient(scope, {
						Fade = "Both",
						Tint = Tokens.Border.Standard,
						Size = UDim2.new(1, 0, 0, Tokens.Control.DividerThickness),
						LayoutOrder = 10,
					}),

					SectionHeading(scope, {
						Text = "Standing",
						LayoutOrder = 11,
					}),
					StatRow(scope, { Caption = "Arts mastered", Value = artsMasteredText, LayoutOrder = 12 }),
					StatRow(scope, { Caption = "Bloodlines", Value = bloodlineCountText, LayoutOrder = 13 }),
					-- Hidden entirely when there are none: a UIListLayout skips non-visible children,
					-- so an unawakened character pays no vertical space for an empty line.
					Label(scope, {
						Text = bloodlineNames,
						Scale = "Detail",
						Color = Tokens.Color.AccentPrimaryBright,
						AutoHeight = true,
						LineHeight = Tokens.Leading.Prose,
						Size = UDim2.fromScale(1, 0),
						LayoutOrder = 14,
						Visible = hasBloodlines,
					}),
					StatRow(scope, { Caption = "Rerolls left", Value = rerollsText, LayoutOrder = 15 }),
					StatRow(scope, { Caption = "Faction standing", Value = standingText, LayoutOrder = 16 }),
					StatRow(scope, { Caption = "Ascended", Value = ascendedText, LayoutOrder = 17 }),
					StatRow(scope, {
						Caption = "Notoriety",
						Value = notorietyText,
						ValueColor = notorietyColor,
						LayoutOrder = 18,
					}),

					-- Directly under the count it spends, rather than in a footer -- the number and
					-- the warning are both readable without moving your eyes. Rerolling REPLACES the
					-- bloodline you hold and everything ground into its stage ladder, which is not
					-- recoverable and is exactly the kind of thing a player should be told before
					-- pressing rather than after.
					Label(scope, {
						Text = "A reroll replaces the blood you carry, and every stage earned in it.",
						Scale = "Detail",
						Color = Tokens.Color.TextSecondary,
						AutoHeight = true,
						LineHeight = Tokens.Leading.Prose,
						Size = UDim2.fromScale(1, 0),
						LayoutOrder = 19,
					}),
					Button(scope, {
						Text = "Reroll Bloodline",
						Variant = "Secondary",
						Size = UDim2.new(1, 0, 0, Tokens.Control.StepButtonSize),
						LayoutOrder = 20,
						-- Disabled rather than hidden at zero: a control that vanishes takes the
						-- reason it is gone with it, and "Rerolls left: 0" three rows above is that
						-- reason.
						Disabled = rerollDisabled,
						OnActivated = props.OnRerollBloodline,
					}),
				},
			}),
		},
	} :: Frame
end

return IdentityRail
