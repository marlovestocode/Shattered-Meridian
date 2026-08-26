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
local CreatorFrame = require(script.Parent.CreatorFrame)
local StepHeader = require(script.Parent.StepHeader)
local StepFooter = require(script.Parent.StepFooter)
local OriginCard = require(script.Parent.OriginCard)
local OnboardingTypes = require(script.Parent.Types)
local Inset = require(script.Parent.Parent.Parent.Components.Inset)

type Scope = Fusion.Scope<typeof(Fusion)>
type RaceSelectProps = OnboardingTypes.RaceSelectProps

local Config = Constants.CharacterCreation

local HEADER_SPEC: StepHeader.StepHeaderSpec = {
	Flourish = true,
	Title = "What will you be?",
	Subtitle = "Choose your origin. It shapes your beginning, not your end.",
}

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
		HeaderHeight = StepHeader.Height(HEADER_SPEC),
		HeaderContent = { StepHeader.New(scope, HEADER_SPEC) },
		BodyContent = {
			Inset(scope, { X = Tokens.Space.XXL, Y = Tokens.Space.L }),
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				Padding = UDim.new(0, Tokens.Space.M),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			table.unpack(cards),
		},
		FooterHint = footerHint,
		FooterButtons = {
			StepFooter.Continue(scope, continueDisabled, function()
				props.ContinueRequested:Fire()
			end),
		},
	}) :: Frame
end

return RaceSelect
