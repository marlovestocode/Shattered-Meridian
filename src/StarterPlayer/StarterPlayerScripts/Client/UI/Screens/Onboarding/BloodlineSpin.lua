--!strict
--[[
	BloodlineSpin.lua

	Owns: the onboarding creator's bloodline roll -- a reveal card for whatever was drawn, a Spin
	button, the remaining-reroll count, and the Continue that ends the intro.

	AN EPILOGUE, NOT A STEP. This screen carries no StepRail (so it does not use CreatorFrame.lua the
	way the four numbered stages do), for the same reason Cinematic.lua doesn't: the rail is
	deliberately "3 steps + a seal" per that module's own header, and Confirmation IS the seal. The
	character is already committed by the time this appears -- the rail has nothing left to say, and
	adding a sixth entry would reopen a flow the seal just closed.

	IT RUNS AFTER THE COMMIT, and that ordering is forced rather than chosen. BloodlineSystem.Spin
	refuses with "NoRaceChosen" unless the profile already has a raceId, and the creator does not
	write one until CharacterCreation_Finalize succeeds at Confirmation -- so a spin offered any
	earlier would refuse for every player, every time. See Client/Intro/IntroClient.lua for where it
	sits in the sequence.

	THE FIRST ROLL IS FREE AND THE BUTTON SAYS SO. "Spin" becomes "Reroll" once something has been
	drawn, and the reroll count is shown next to it rather than only discovered by pressing --
	spending a limited resource should never be something a player learns about after the fact. When
	the count hits zero the button disables rather than disappearing, so the reason the action is gone
	stays legible.

	CONTINUE IS ALWAYS AVAILABLE, including before the first spin. A player who wants no bloodline at
	all (or who hits the "nothing authored yet" refusal -- see BloodlineSystem.Spin's own
	NoBloodlinesAvailable branch, which is every player until bloodline content exists) must never be
	trapped on the last screen of the intro by a button that cannot succeed.

	Does not own: the roll itself or its odds (BloodlineSystem, server-side -- the client sends no
	seed and gets no say), or when this stage is shown (Client/Onboarding/OnboardingClient.lua, the
	only thing that ever writes handle.Stage). Same "screen exposes state/signals, client module
	drives from outside" split every other screen in this folder follows.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Panel = require(script.Parent.Parent.Parent.Components.Panel)
local Label = require(script.Parent.Parent.Parent.Components.Label)
local Button = require(script.Parent.Parent.Parent.Components.Button)
local Divider = require(script.Parent.Parent.Parent.Components.Divider)
local OnboardingTypes = require(script.Parent.Types)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>

local PANEL_SIZE = UDim2.fromOffset(520, 420)
local CARD_HEIGHT = 168

local function BloodlineSpin(scope: Scope, props: OnboardingTypes.BloodlineSpinProps): Frame
	local hasResult = scope:Computed(function(use)
		return use(props.ResultName) ~= ""
	end)

	-- "Spin" until something has been drawn, then "Reroll" -- the label is what tells a player the
	-- second press costs something the first one didn't.
	local spinLabel = scope:Computed(function(use)
		return if use(hasResult) then "Reroll" else "Spin"
	end)

	local canSpin = scope:Computed(function(use)
		if use(props.IsSpinning) then
			return false
		end
		-- The first roll is free, so it is available regardless of the reroll count -- see the header.
		return not use(hasResult) or use(props.RerollsRemaining) > 0
	end)

	local rerollText = scope:Computed(function(use)
		local remaining = use(props.RerollsRemaining)
		if not use(hasResult) then
			return `First roll is free · {remaining} rerolls after`
		end
		if remaining == 1 then
			return "1 reroll left"
		end
		return `{remaining} rerolls left`
	end)

	return Panel(scope, {
		Name = "BloodlineSpin",
		Size = PANEL_SIZE,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Elevated = true,
		CornerAccent = true,

		Children = {
			scope:New "UIPadding" {
				PaddingTop = UDim.new(0, Tokens.Space.L),
				PaddingBottom = UDim.new(0, Tokens.Space.L),
				PaddingLeft = UDim.new(0, Tokens.Space.L),
				PaddingRight = UDim.new(0, Tokens.Space.L),
			},
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				Padding = UDim.new(0, Tokens.Space.M),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},

			Label(scope, {
				Text = "Your Blood",
				Scale = "Heading",
				Color = Tokens.Color.TextPrimary,
				Size = UDim2.new(1, 0, 0, Tokens.Type.Heading.Size + Tokens.Space.XS),
				TextXAlignment = Enum.TextXAlignment.Center,
				LayoutOrder = 1,
			}),
			Label(scope, {
				Text = "What runs in you was never chosen. Roll, and see what answers.",
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				AutoHeight = true,
				LineHeight = Tokens.Leading.Prose,
				Size = UDim2.fromScale(1, 0),
				TextXAlignment = Enum.TextXAlignment.Center,
				LayoutOrder = 2,
			}),
			Divider.Plain(scope, { LayoutOrder = 3 }),

			-- The reveal card. Mounted always, at a fixed height, rather than appearing on the first
			-- roll: a card that pops into existence would reflow everything below it (the buttons)
			-- out from under the cursor at the exact moment a player is clicking Spin again.
			scope:New "Frame" {
				Name = "ResultCard",
				Size = UDim2.new(1, 0, 0, CARD_HEIGHT),
				BackgroundColor3 = Tokens.Wash.Inset.Color,
				BackgroundTransparency = Tokens.Wash.Inset.Transparency,
				BorderSizePixel = 0,
				LayoutOrder = 4,

				[Children] = {
					scope:New "UICorner" { CornerRadius = Tokens.Radius.Sharp },
					scope:New "UIStroke" {
						Color = Tokens.Border.Standard.Color,
						Thickness = 1,
						Transparency = Tokens.Border.Standard.Transparency,
					},
					scope:New "UIPadding" {
						PaddingTop = UDim.new(0, Tokens.Space.M),
						PaddingBottom = UDim.new(0, Tokens.Space.M),
						PaddingLeft = UDim.new(0, Tokens.Space.M),
						PaddingRight = UDim.new(0, Tokens.Space.M),
					},
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Vertical,
						HorizontalAlignment = Enum.HorizontalAlignment.Center,
						VerticalAlignment = Enum.VerticalAlignment.Center,
						Padding = UDim.new(0, Tokens.Space.XS),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},

					-- The empty state IS a label, not a hidden card -- an empty bordered box reads as
					-- something failing to load.
					Label(scope, {
						Text = scope:Computed(function(use)
							return if use(hasResult) then "" else "Nothing yet."
						end),
						Scale = "Body",
						Color = Tokens.Color.TextDisabled,
						Size = UDim2.new(1, 0, 0, Tokens.Type.Body.Size + Tokens.Space.XS),
						TextXAlignment = Enum.TextXAlignment.Center,
						Visible = scope:Computed(function(use)
							return not use(hasResult)
						end),
						LayoutOrder = 1,
					}),
					Label(scope, {
						Text = props.ResultRarity,
						Scale = "Detail",
						Color = Tokens.Color.AccentSecondary,
						Size = UDim2.new(1, 0, 0, Tokens.Type.Detail.Size + Tokens.Space.XS),
						TextXAlignment = Enum.TextXAlignment.Center,
						Visible = hasResult,
						LayoutOrder = 2,
					}),
					Label(scope, {
						Text = props.ResultName,
						Scale = "Heading",
						Color = Tokens.Color.AccentPrimaryBright,
						Size = UDim2.new(1, 0, 0, Tokens.Type.Heading.Size + Tokens.Space.XS),
						TextXAlignment = Enum.TextXAlignment.Center,
						Visible = hasResult,
						LayoutOrder = 3,
					}),
					Label(scope, {
						Text = props.ResultFlavor,
						Scale = "Detail",
						Color = Tokens.Color.TextSecondary,
						AutoHeight = true,
						LineHeight = Tokens.Leading.Prose,
						Size = UDim2.fromScale(1, 0),
						TextXAlignment = Enum.TextXAlignment.Center,
						Visible = hasResult,
						LayoutOrder = 4,
					}),
				},
			},

			Label(scope, {
				Text = rerollText,
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				Size = UDim2.new(1, 0, 0, Tokens.Type.Detail.Size + Tokens.Space.XS),
				TextXAlignment = Enum.TextXAlignment.Center,
				LayoutOrder = 5,
			}),
			-- Refusals land here (including the one every player sees until bloodline content is
			-- authored). Always mounted so a message appearing never reflows the buttons.
			Label(scope, {
				Text = props.StatusText,
				Scale = "Detail",
				Color = Tokens.Color.Warning,
				Size = UDim2.new(1, 0, 0, Tokens.Type.Detail.Size + Tokens.Space.XS),
				TextXAlignment = Enum.TextXAlignment.Center,
				LayoutOrder = 6,
			}),

			scope:New "Frame" {
				Name = "Actions",
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				BackgroundTransparency = 1,
				LayoutOrder = 7,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						HorizontalAlignment = Enum.HorizontalAlignment.Center,
						VerticalAlignment = Enum.VerticalAlignment.Center,
						Padding = UDim.new(0, Tokens.Space.S),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					Button(scope, {
						Text = spinLabel,
						Variant = "Primary",
						Size = UDim2.fromOffset(150, Tokens.Control.RowHeight),
						Disabled = scope:Computed(function(use)
							return not use(canSpin)
						end),
						LayoutOrder = 1,
						OnActivated = function()
							props.SpinRequested:Fire()
						end,
					}),
					Button(scope, {
						Text = "Continue",
						Size = UDim2.fromOffset(150, Tokens.Control.RowHeight),
						LayoutOrder = 2,
						OnActivated = function()
							props.ContinueRequested:Fire()
						end,
					}),
				},
			},
		},
	})
end

return BloodlineSpin
