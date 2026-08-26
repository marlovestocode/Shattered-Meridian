--!strict
--[[
	NameEntry.lua

	Owns: chargen screen 3 -- the only stage where the player CREATES rather than picks. Per the
	redesign's designer direction (docs/design/intro-redesign-handoff.md, this stage is undesigned in
	the Figma and extrapolated): the field renders as the name itself -- large, centred, serif, a
	single hairline underneath -- rather than as a bordered form input, so it does NOT reuse
	Components/TextField.lua (built around this UI's usual bordered-box look; a raw TextBox here is
	the same "bespoke control when the shared primitive doesn't fit" call Confirmation.lua's own
	CommitButton already makes). Roblox's native TextBox already draws a blinking caret when focused
	-- nothing custom needed for that part.

	Beneath the field, the identity line assembles live: "KAELEN / FIRMBORN -- Heirs of the
	Stonepath" (name and race upper-cased for that stamped-record look; the epithet stays normal
	case, matching the design's own example). The counter goes bronze and reads "MINIMUM 3" below
	the minimum length instead of just silently disabling Continue -- an actionable reason, not a
	mystery-disabled button. Suggest fills the field from Constants.CharacterCreation.DisplayName.
	SuggestedNames -- real, curated fantasy names, not placeholder text -- to cure blank-field
	paralysis, the biggest drop-off point in any chargen flow per the designer's own note. It writes
	straight into the same DisplayName Value a typed name would, so it "routes through the same
	server filter as typed input" by construction: nothing downstream can tell a suggestion from
	something the player typed themselves.

	Applies a light CLIENT-SIDE pre-check (length + no leading/trailing/consecutive space, counted in
	utf8 codepoints -- the OLD version of this file counted raw bytes, silently wrong for any
	multi-byte name; fixed here to match CharacterCreationSystem.ValidateDisplayName's own utf8.len
	convention) purely so Continue can give immediate feedback instead of a round trip just to learn
	the name was too short -- the exact same "convenience gate, never a substitute for server
	re-validation" contract BugReport/init.lua's own submitDisabled already establishes. The full
	charset/Denylist/moderation-filter check happens server-side ONLY
	(CharacterCreationSystem.ValidateDisplayName + TextService filtering at Finalize) -- this screen
	never re-implements that codepoint-level logic.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Constants = require(ReplicatedStorage.Shared.Constants)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Components.Label)
local Button = require(script.Parent.Parent.Parent.Components.Button)
local CreatorFrame = require(script.Parent.CreatorFrame)
local StepHeader = require(script.Parent.StepHeader)
local StepFooter = require(script.Parent.StepFooter)
local OnboardingTypes = require(script.Parent.Types)
local Inset = require(script.Parent.Parent.Parent.Components.Inset)

local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local OnChange = Fusion.OnChange

type Scope = Fusion.Scope<typeof(Fusion)>
type NameEntryProps = OnboardingTypes.NameEntryProps

local ChargenConfig = Constants.CharacterCreation
local Config = ChargenConfig.DisplayName

local function nameLength(name: string): number
	return utf8.len(name) or 0
end

local function isObviouslyInvalid(name: string): boolean
	local length = nameLength(name)
	if length < Config.MinLength or length > Config.MaxLength then
		return true
	end
	if name:sub(1, 1) == " " or name:sub(-1) == " " then
		return true
	end
	if string.find(name, "  ", 1, true) then
		return true
	end
	return false
end

local HEADER_SPEC: StepHeader.StepHeaderSpec = {
	Eyebrow = "CHARACTER CREATION -- STEP 3",
	Title = "What shall the world call you?",
}

local NAME_FIELD_HEIGHT = 48

local function NameEntry(scope: Scope, props: NameEntryProps): Frame
	local isFocused = scope:Value(false)

	local continueDisabled = scope:Computed(function(use)
		return isObviouslyInvalid(use(props.DisplayName))
	end)
	local footerHint = scope:Computed(function(use)
		return if isObviouslyInvalid(use(props.DisplayName))
			then `Enter at least {Config.MinLength} characters to continue`
			else ""
	end)
	local blockingReason = scope:Computed(function(use)
		local length = nameLength(use(props.DisplayName))
		return if length < Config.MinLength then "NAME REQUIRED" else ""
	end)

	local counterText = scope:Computed(function(use)
		local length = nameLength(use(props.DisplayName))
		return if length < Config.MinLength then `MINIMUM {Config.MinLength}` else `{length} / {Config.MaxLength}`
	end)
	local counterColor = scope:Computed(function(use)
		local length = nameLength(use(props.DisplayName))
		return if length < Config.MinLength then Tokens.Color.AccentSecondary else Tokens.Color.TextDisabled
	end)

	-- "KAELEN / FIRMBORN -- Heirs of the Stonepath" -- name and race upper-cased, epithet normal
	-- case, matching the design's own example exactly.
	local identityLine = scope:Computed(function(use)
		local name = use(props.DisplayName)
		local raceId = use(props.SelectedRaceId)
		if name == "" or raceId == nil then
			return ""
		end
		local epithet = ChargenConfig.RaceEpithets[raceId] or ""
		return `{string.upper(name)} / {string.upper(raceId)} -- {epithet}`
	end)

	local fieldHairlineColor = scope:Computed(function(use)
		return if use(isFocused) then Tokens.Color.AccentPrimary else Tokens.Border.Standard.Color
	end)
	local fieldHairlineTransparency = scope:Computed(function(use)
		return if use(isFocused) then 0 else Tokens.Border.Standard.Transparency
	end)

	local function suggestName(): ()
		local names = Config.SuggestedNames
		if #names == 0 then
			return
		end
		props.DisplayName:set(names[math.random(1, #names)])
	end

	local bodyColumn = scope:New "Frame" {
		Name = "NameColumn",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromOffset(480, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				Padding = UDim.new(0, Tokens.Space.M),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},

			scope:New "Frame" {
				Name = "NameField",
				Size = UDim2.new(1, 0, 0, NAME_FIELD_HEIGHT),
				BackgroundTransparency = 1,
				LayoutOrder = 1,

				[Children] = {
					scope:New "TextBox" {
						Name = "Input",
						Size = UDim2.fromScale(1, 1),
						BackgroundTransparency = 1,
						Text = props.DisplayName,
						PlaceholderText = "Unnamed",
						PlaceholderColor3 = Tokens.Color.TextDisabled,
						FontFace = Tokens.Type.Title.Face,
						TextSize = Tokens.Type.Title.Size,
						TextColor3 = Tokens.Color.TextPrimary,
						TextXAlignment = Enum.TextXAlignment.Center,
						ClearTextOnFocus = false,

						[OnEvent "Focused"] = function()
							isFocused:set(true)
						end,
						[OnEvent "FocusLost"] = function()
							isFocused:set(false)
						end,
						[OnChange "Text"] = function(newText: string)
							if #newText > Config.MaxLength then
								props.DisplayName:set(string.sub(newText, 1, Config.MaxLength))
								return
							end
							props.DisplayName:set(newText)
						end,
					},
					-- A raw Frame, not Divider.Plain -- that component's Tint is a plain (non-reactive)
					-- Tokens.Tint by design (every existing caller is a static token), and this is the
					-- one hairline in the redesign that needs to react live (brightening on focus).
					scope:New "Frame" {
						Name = "Hairline",
						AnchorPoint = Vector2.new(0, 1),
						Position = UDim2.fromScale(0, 1),
						Size = UDim2.new(1, 0, 0, 1),
						BackgroundColor3 = fieldHairlineColor,
						BackgroundTransparency = fieldHairlineTransparency,
						BorderSizePixel = 0,
					},
				},
			},

			Label(scope, {
				Text = identityLine,
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				TextXAlignment = Enum.TextXAlignment.Center,
				Size = UDim2.new(1, 0, 0, 16),
				LayoutOrder = 2,
			}),

			scope:New "Frame" {
				Name = "CounterRow",
				Size = UDim2.fromOffset(0, 14),
				AutomaticSize = Enum.AutomaticSize.X,
				BackgroundTransparency = 1,
				LayoutOrder = 3,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						VerticalAlignment = Enum.VerticalAlignment.Center,
						HorizontalAlignment = Enum.HorizontalAlignment.Center,
						Padding = UDim.new(0, Tokens.Space.S),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					Label(scope, {
						Text = counterText,
						Scale = "NumeralSmall",
						Color = counterColor,
						LayoutOrder = 1,
					}),
				},
			},

			Button(scope, {
				Text = "Suggest",
				Variant = "Secondary",
				Size = UDim2.fromOffset(120, 32),
				LayoutOrder = 4,
				OnActivated = suggestName,
			}),
		},
	} :: Frame

	return CreatorFrame(scope, {
		Stage = "NameEntry",
		StepRailNavigateRequested = props.StepRailNavigateRequested,
		BlockingReason = blockingReason,
		HeaderHeight = StepHeader.Height(HEADER_SPEC),
		HeaderContent = { StepHeader.New(scope, HEADER_SPEC) },
		BodyContent = {
			Inset(scope, { Top = Tokens.Space.XXXL }),
			bodyColumn,
		},
		FooterHint = footerHint,
		FooterButtons = {
			StepFooter.Back(scope, function()
				props.BackRequested:Fire()
			end),
			StepFooter.Continue(scope, continueDisabled, function()
				props.ContinueRequested:Fire()
			end),
		},
	}) :: Frame
end

return NameEntry
