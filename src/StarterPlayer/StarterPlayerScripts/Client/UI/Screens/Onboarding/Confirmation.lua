--!strict
--[[
	Confirmation.lua

	Owns: chargen screen 4 -- a VOW, not a receipt, per the redesign's designer direction
	(docs/design/intro-redesign-handoff.md). The character is composed as one statement ("KAELEN, of
	the Firmborn -- Heirs of the Stonepath") rather than seven equal-weight rows; the six attributes
	are shown via Attributes.Row reused directly with ReadOnly = true ("reads as YOUR sheet," per the
	same direction) instead of a second, duplicate row-rendering implementation.

	Three labeled escape hatches (Change origin / Retune attributes / Rename) replace the old single
	generic BACK -- fixing your origin from Confirmation used to be three sequential Back presses.
	Each fires StepRailNavigateRequested directly (the same signal the step rail's own clickable-
	completed-steps use) rather than a dedicated BackRequested event -- see Types.lua's own
	ConfirmationProps comment for why that field was retired entirely rather than kept alongside these.

	A bronze permanence line states outright that this choice cannot be undone -- nothing anywhere in
	this flow said so before this pass, despite CharacterCreationSystem gating purely on
	`profile.raceId == nil` with no re-spec path anywhere in the codebase.

	Success beat: everything except the bare name lives inside one CanvasGroup, whose
	GroupTransparency springs to 1 the instant props.IsSucceeding flips true (set by
	OnboardingClient.lua the moment Finalize resolves Success = true) -- "fracture-out everything
	except the name, hold it alone in the void." The character's actual teleport already happened
	server-side before the client ever sees Success = true (CharacterCreationSystem.lua's own
	failure-handling contract), so this beat never needs to race it; it's purely the client holding
	the reveal a moment longer before OnboardingClient.lua tears the whole screen down.

	Does not own the actual CharacterCreation_Finalize call, retry loop, held-input detection, or the
	auto-jump-after-repeated-failures logic -- OnboardingClient.lua owns all four; this screen only
	renders StatusText/IsSubmitting/IsSucceeding/HoldProgress and displays whatever RaceSelect/
	Attributes/NameEntry already collected.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Constants = require(ReplicatedStorage.Shared.Constants)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Components.Label)
local Button = require(script.Parent.Parent.Parent.Components.Button)
local Divider = require(script.Parent.Parent.Parent.Components.Divider)
local Glow = require(script.Parent.Parent.Parent.Components.Glow)
local CreatorFrame = require(script.Parent.CreatorFrame)
local StepHeader = require(script.Parent.StepHeader)
local Attributes = require(script.Parent.Attributes)
local OnboardingTypes = require(script.Parent.Types)
local Inset = require(script.Parent.Parent.Parent.Components.Inset)

local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type ConfirmationProps = OnboardingTypes.ConfirmationProps

local Config = Constants.CharacterCreation

-- No step number in the eyebrow -- StepRail.lua's own header: Confirmation is the lit seal, not
-- "step 4".
local HEADER_SPEC: StepHeader.StepHeaderSpec = {
	Eyebrow = "CHARACTER CREATION",
	Title = "Before You Begin",
}

local function EscapeHatch(
	scope: Scope,
	text: string,
	target: OnboardingTypes.Stage,
	props: ConfirmationProps,
	layoutOrder: number
): TextButton
	return Button(scope, {
		Text = text,
		Variant = "Secondary",
		Size = UDim2.fromOffset(150, 32),
		LayoutOrder = layoutOrder,
		OnActivated = function()
			props.StepRailNavigateRequested:Fire(target)
		end,
	})
end

local COMMIT_BUTTON_SIZE = UDim2.fromOffset(220, 44)

local function CommitButton(scope: Scope, props: ConfirmationProps): TextButton
	local commitActive = scope:Computed(function(use)
		return not use(props.IsSubmitting) and not use(props.IsSucceeding)
	end)
	local labelText = scope:Computed(function(use)
		return if use(props.IsSubmitting) then "SUBMITTING..." else "HOLD TO CONFIRM"
	end)
	local fillSize = scope:Computed(function(use)
		return UDim2.fromScale(use(props.HoldProgress), 1)
	end)

	return scope:New "TextButton" {
		Name = "CommitButton",
		Size = COMMIT_BUTTON_SIZE,
		BackgroundColor3 = Tokens.Color.AccentPrimary,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = "",
		Active = commitActive,
		ClipsDescendants = true,

		-- GuiObject.InputBegan/InputEnded rather than UserInputService: these only fire for input
		-- actually over this button, which IS the hit-testing the global listener lacked. MouseLeave
		-- covers dragging off the button while still holding. See Types.lua's own
		-- CommitPointerHeld comment for the hazard this closed.
		[OnEvent "InputBegan"] = function(input: InputObject)
			if peek(props.IsSubmitting) or peek(props.IsSucceeding) then
				return
			end
			if
				input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
			then
				props.CommitPointerHeld:set(true)
			end
		end,
		[OnEvent "InputEnded"] = function(input: InputObject)
			if
				input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
			then
				props.CommitPointerHeld:set(false)
			end
		end,
		[OnEvent "MouseLeave"] = function()
			props.CommitPointerHeld:set(false)
		end,

		[Children] = {
			scope:New "UICorner" {
				CornerRadius = Tokens.Radius.Sharp,
			},
			scope:New "UIStroke" {
				Color = Tokens.Color.AccentPrimary,
				Thickness = 1,
			},
			Glow(scope, {
				Color = Tokens.Color.AccentPrimary,
				Visible = commitActive,
				ZIndex = 0,
			}),
			-- Progress renders INSIDE the button rather than as a separate bar above it, so the thing
			-- filling up and the thing being pressed are the same object.
			scope:New "Frame" {
				Name = "HoldFill",
				Size = fillSize,
				BackgroundColor3 = Tokens.Color.AccentPrimaryBright,
				BackgroundTransparency = 0.6,
				BorderSizePixel = 0,
				ZIndex = 1,
			},
			-- Plain Label, not TrackedLabel -- this is the one piece of button text in the redesign
			-- that must switch content live (HOLD TO CONFIRM / SUBMITTING...), which TrackedLabel
			-- can't do (see that file's own header). Authored already-uppercase so it still reads as
			-- tracked-caps-adjacent even without real letter-spacing.
			Label(scope, {
				Text = labelText,
				Scale = "Action",
				Color = Tokens.Color.Surface,
				TextXAlignment = Enum.TextXAlignment.Center,
				Size = UDim2.fromScale(1, 1),
				ZIndex = 2,
			}),
		},
	} :: TextButton
end

local function Confirmation(scope: Scope, props: ConfirmationProps): Frame
	local nameText = scope:Computed(function(use)
		local name = use(props.DisplayName)
		return if name == "" then "Unnamed" else name
	end)
	local lineageText = scope:Computed(function(use)
		local raceId = use(props.SelectedRaceId)
		if raceId == nil then
			return ""
		end
		local epithet = Config.RaceEpithets[raceId] or ""
		return `of the {raceId} -- {epithet}.`
	end)

	-- Springs to 1 (fully hidden) the instant IsSucceeding flips true -- see file header.
	local fracture = scope:Spring(
		scope:Computed(function(use)
			return if use(props.IsSucceeding) then 1 else 0
		end),
		Tokens.Motion.FadeSpring.Speed,
		Tokens.Motion.FadeSpring.Damping
	)

	local rows: { Instance } = {}
	for index, field in ipairs(Config.AttributeFields) do
		table.insert(
			rows,
			Attributes.Row(scope, field, {
				SelectedRaceId = props.SelectedRaceId,
				Attributes = props.Attributes,
				ReadOnly = true,
			}, index)
		)
	end

	local bodyColumn = scope:New "Frame" {
		Name = "VowColumn",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromOffset(560, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				Padding = UDim.new(0, Tokens.Space.S),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},

			-- The one thing that survives the success beat -- outside the CanvasGroup below.
			Label(scope, {
				Text = nameText,
				Scale = "Heading",
				Color = Tokens.Color.TextPrimary,
				TextXAlignment = Enum.TextXAlignment.Center,
				Size = UDim2.new(1, 0, 0, 30),
				LayoutOrder = 1,
			}),

			scope:New "CanvasGroup" {
				Name = "Fractureable",
				-- UDim2.fromScale(1, 0), not fromOffset(0, 0) -- AutomaticSize.Y only frees the height;
				-- fromOffset's Scale.X of 0 pinned this whole subtree (and Sheet below) to zero width,
				-- clipping every wrapped label inside it to a sliver.
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				GroupTransparency = fracture,
				LayoutOrder = 2,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Vertical,
						HorizontalAlignment = Enum.HorizontalAlignment.Center,
						Padding = UDim.new(0, Tokens.Space.L),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},

					Label(scope, {
						Text = lineageText,
						Scale = "Body",
						Color = Tokens.Color.TextSecondary,
						TextXAlignment = Enum.TextXAlignment.Center,
						Size = UDim2.new(1, 0, 0, 20),
						LayoutOrder = 1,
					}),

					scope:New "Frame" {
						Name = "EscapeHatches",
						Size = UDim2.fromOffset(0, 32),
						AutomaticSize = Enum.AutomaticSize.X,
						BackgroundTransparency = 1,
						LayoutOrder = 2,

						[Children] = {
							scope:New "UIListLayout" {
								FillDirection = Enum.FillDirection.Horizontal,
								Padding = UDim.new(0, Tokens.Space.S),
								SortOrder = Enum.SortOrder.LayoutOrder,
							},
							EscapeHatch(scope, "Change origin", "RaceSelect", props, 1),
							EscapeHatch(scope, "Retune attributes", "Attributes", props, 2),
							EscapeHatch(scope, "Rename", "NameEntry", props, 3),
						},
					},

					Divider.Plain(scope, {
						Size = UDim2.new(1, 0, 0, 1),
						LayoutOrder = 3,
					}),

					scope:New "Frame" {
						Name = "Sheet",
						Size = UDim2.fromScale(1, 0),
						AutomaticSize = Enum.AutomaticSize.Y,
						BackgroundTransparency = 1,
						LayoutOrder = 4,

						[Children] = {
							scope:New "UIListLayout" {
								FillDirection = Enum.FillDirection.Vertical,
								SortOrder = Enum.SortOrder.LayoutOrder,
							},
							table.unpack(rows),
						},
					},

					-- Empty StatusText renders as blank -- same "nothing to show, show nothing"
					-- contract this screen's own StatusText has always used.
					Label(scope, {
						Text = props.StatusText,
						Scale = "Detail",
						Color = Tokens.Color.Danger,
						TextWrapped = true,
						TextXAlignment = Enum.TextXAlignment.Center,
						Size = UDim2.new(1, 0, 0, 20),
						LayoutOrder = 5,
					}),

					-- The permanence line -- see file header. Bronze (AccentSecondary), matching
					-- docs/ui-ux-philosophy.md's violet-is-live/bronze-is-permanent split.
					Label(scope, {
						Text = "This choice is permanent. There is no path back once you confirm.",
						Scale = "Detail",
						Color = Tokens.Color.AccentSecondary,
						TextXAlignment = Enum.TextXAlignment.Center,
						Size = UDim2.new(1, 0, 0, 16),
						LayoutOrder = 6,
					}),
				},
			},
		},
	} :: Frame

	return CreatorFrame(scope, {
		Stage = "Confirmation",
		StepRailNavigateRequested = props.StepRailNavigateRequested,
		HeaderHeight = StepHeader.Height(HEADER_SPEC),
		HeaderContent = { StepHeader.New(scope, HEADER_SPEC) },
		BodyContent = {
			Inset(scope, { Top = Tokens.Space.XXL }),
			bodyColumn,
		},
		FooterHint = "",
		FooterButtons = { CommitButton(scope, props) },
	}) :: Frame
end

return Confirmation
