--!strict
--[[
	RaceSelect.lua

	Owns: chargen screen 1 -- CreatorFrame's rail/header/body/footer slots filled with the redesign's
	Origin screen (docs/design/intro-redesign-figma-spec.md section 4): a centred flourish header,
	one OriginCard.lua per Constants.CharacterCreation.RaceIds stacked in a single column (see
	OriginCard.lua's own header for why not the Figma's 2x2 grid), and the shared CONTINUE footer.
	The footer hint doubles as the blocking-reason slot (docs/design/intro-redesign-handoff.md Phase
	C): "Select an origin to continue" while nothing is chosen, empty once it is -- not the Figma's
	"Values persist into Act I" (there is no Act structure anywhere in this project).

	Does not own: attribute editing (Attributes.lua owns free reallocation within the budget), a
	race's default attribute block (OriginCard.lua computes that at the point of selection), or
	server-side validation -- CharacterCreationSystem.ValidateRaceId re-checks this choice regardless
	of what's selected here.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Types = require(ReplicatedStorage.Shared.Types)
local Constants = require(ReplicatedStorage.Shared.Constants)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Components.Label)
local Button = require(script.Parent.Parent.Parent.Components.Button)
local Divider = require(script.Parent.Parent.Parent.Components.Divider)
local CreatorFrame = require(script.Parent.CreatorFrame)
local OriginCard = require(script.Parent.OriginCard)
local OnboardingTypes = require(script.Parent.Types)

local Children = Fusion.Children
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type RaceSelectProps = OnboardingTypes.RaceSelectProps

local Config = Constants.CharacterCreation

-- UIPadding (32 top + 24 bottom) + 2 UIListLayout gaps (8 each) + flourish(6) + title(36) +
-- subtitle(36) -- spelled out per CreatorFrame.lua's own "no guessing" discipline.
local HEADER_HEIGHT = 32 + 24 + 8 * 2 + 6 + 36 + 36

local function Header(scope: Scope): Frame
	return scope:New "Frame" {
		Name = "Header",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,

		[Children] = {
			scope:New "UIPadding" {
				PaddingTop = UDim.new(0, Tokens.Space.XXL),
				PaddingBottom = UDim.new(0, Tokens.Space.XL),
				PaddingLeft = UDim.new(0, Tokens.Space.XXXL),
				PaddingRight = UDim.new(0, Tokens.Space.XXXL),
			},
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				Padding = UDim.new(0, Tokens.Space.S),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			Divider.Flourish(scope, {
				Size = UDim2.fromOffset(160, 6),
				LayoutOrder = 1,
			}),
			Label(scope, {
				Text = "What will you be?",
				Scale = "Title",
				TextXAlignment = Enum.TextXAlignment.Center,
				Size = UDim2.new(1, 0, 0, 36),
				LayoutOrder = 2,
			}),
			Label(scope, {
				Text = "Choose your origin. It shapes your beginning, not your end.",
				Scale = "Body",
				Color = Tokens.Color.TextSecondary,
				TextXAlignment = Enum.TextXAlignment.Center,
				TextWrapped = true,
				Size = UDim2.new(1, 0, 0, 36),
				LayoutOrder = 3,
			}),
		},
	} :: Frame
end

local function RaceSelect(scope: Scope, props: RaceSelectProps): Frame
	local continueDisabled = scope:Computed(function(use)
		return use(props.SelectedRaceId) == nil
	end)
	local footerHint = scope:Computed(function(use)
		return if use(continueDisabled) then "Select an origin to continue" else ""
	end)

	local cards: { Instance } = {}
	for index, raceId in ipairs(Config.RaceIds) do
		table.insert(
			cards,
			OriginCard.Mount(scope, {
				RaceId = raceId :: Types.RaceId,
				SelectedRaceId = props.SelectedRaceId,
				Attributes = props.Attributes,
				LayoutOrder = index,
			})
		)
	end

	return CreatorFrame(scope, {
		Stage = "RaceSelect",
		StepRailNavigateRequested = props.StepRailNavigateRequested,
		HeaderHeight = HEADER_HEIGHT,
		HeaderContent = { Header(scope) },
		BodyContent = {
			scope:New "UIPadding" {
				PaddingTop = UDim.new(0, Tokens.Space.L),
				PaddingBottom = UDim.new(0, Tokens.Space.L),
				PaddingLeft = UDim.new(0, Tokens.Space.XXL),
				PaddingRight = UDim.new(0, Tokens.Space.XXL),
			},
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				Padding = UDim.new(0, Tokens.Space.M),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			table.unpack(cards),
		},
		FooterHint = footerHint,
		FooterButtons = {
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

return RaceSelect
