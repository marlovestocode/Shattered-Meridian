--!strict
--[[
	BugReport/init.lua

	Owns: the player-facing bug report form -- category (segmented Tab row, not a native dropdown:
	a dropdown is awkward to navigate with a gamepad, where a small fixed set of discrete buttons is
	much easier) + free-text description (Components/TextField.lua, the first TextBox anywhere in
	this codebase), Submit/Cancel, and a status line. Unlike DevMenu/init.lua this is NOT
	whitelist-gated -- every player gets this screen; Client/BugReport/BugReportClient.lua is the
	module that decides when it opens and what happens on submit.

	Follows DevMenu/init.lua's "screen exposes state/signals, client module drives from outside"
	precedent: BugReportClient.lua doesn't exist yet at the moment this mounts (UI/init.lua mounts
	every Screen before Main.client.lua boots any client integration module), so Submit fires a
	BindableEvent (SubmitRequested) rather than taking a callback prop. The close/cancel buttons are
	the one exception, exactly like DevMenu's own close button: IsOpen is already a Fusion.Value
	owned by this same Mount call, so closing just sets it directly.

	Gamepad navigation is NOT this screen's business any more. It used to be: twenty-one
	NextSelectionUp/Down/Left/Right assignments wired imperatively here, plus this file's own
	Observer over GuiService.SelectedObject, on the argument that a small fixed field order beats a
	spatial guess. Both are gone -- Components/ModalScreen.lua now puts every panel in a
	Shell/Focus.lua group, which derives the same graph from where the controls actually ARE and
	keeps deriving it as they move. What that argument missed is that the hand-wired version was
	only correct for the exact eleven controls it named: adding a twelfth changed nothing and warned
	about nothing, it just left the new control unreachable. The one thing worth keeping was the
	landing spot, which is now the FocusDefault prop below.

	Does not own: submission validation (BugReportSystem.lua re-validates everything server-side
	regardless of what this screen shows), or whether the local player currently sees this menu open
	(BugReportClient.lua's keybind toggle).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Tokens)
local ModalScreen = require(script.Parent.Parent.Components.ModalScreen)
local Label = require(script.Parent.Parent.Components.Label)
local Button = require(script.Parent.Parent.Components.Button)
local Tab = require(script.Parent.Parent.Components.Tab)
local TextField = require(script.Parent.Parent.Components.TextField)

local Children = Fusion.Children
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>

-- Kept as plain strings here (not a Types.BugReportCategory import) -- same "screen stays decoupled
-- from Types.lua, fires a raw string, the client driver interprets it" precedent DevMenu/init.lua's
-- own SpawnBotRequested (a raw preset-name string) already established.
local CATEGORIES = { "Bug", "Exploit", "Suggestion", "Other" }
local DESCRIPTION_MAX_LENGTH = 1000

export type BugReportHandle = {
	IsOpen: Fusion.Value<boolean>,
	StatusText: Fusion.Value<string>,
	-- Driven from OUTSIDE by BugReportClient.lua while a submission is in flight -- disables the
	-- Submit button and shows "Submitting..." so a slow DataStore round trip can't be double-fired.
	IsSubmitting: Fusion.Value<boolean>,
	-- Fires (category, trimmedDescription) -- category is one of CATEGORIES above.
	SubmitRequested: RBXScriptSignal<(string, string)>,
}

local ROOT_WIDTH = 480

local function BugReport(scope: Scope, playerGui: PlayerGui): BugReportHandle
	local isOpen = scope:Value(false)
	local statusText = scope:Value("")
	local isSubmitting = scope:Value(false)
	local selectedCategory = scope:Value(CATEGORIES[1])
	local descriptionText = scope:Value("")

	local submitRequestedEvent = Instance.new("BindableEvent")

	local characterCountText = scope:Computed(function(use)
		return `{#use(descriptionText)} / {DESCRIPTION_MAX_LENGTH}`
	end)

	local submitButtonText = scope:Computed(function(use)
		return if use(isSubmitting) then "Submitting..." else "Submit"
	end)

	-- Client-side-only convenience gate (never a substitute for BugReportSystem.Submit's own
	-- server-side re-validation) -- disables Submit while empty/submitting so a player gets
	-- immediate feedback instead of a round trip just to learn the description was blank.
	local submitDisabled = scope:Computed(function(use)
		return use(isSubmitting) or #use(descriptionText) == 0
	end)

	local function close(): ()
		isOpen:set(false)
	end

	-- Named locals (not inline anonymous children) for every control the gamepad-nav wiring block
	-- below needs to reference -- NextSelectionUp/Down/Left/Right assignments require every target
	-- to already exist, including forward references (e.g. the first category button's
	-- NextSelectionDown points at the description TextBox, built later in this same function).
	local closeButton = Button(scope, {
		Text = "X",
		Size = UDim2.fromOffset(28, 28),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		OnActivated = close,
	})

	local categoryButtons: { TextButton } = {}
	for index, category in ipairs(CATEGORIES) do
		local categoryButton = Tab(scope, {
			Text = category,
			Size = UDim2.new(1 / 4, -Tokens.Space.XS, 0, Tokens.Control.RowHeight),
			LayoutOrder = index,
			Selected = scope:Computed(function(use)
				return use(selectedCategory) == category
			end),
			OnActivated = function()
				selectedCategory:set(category)
			end,
		})
		categoryButtons[index] = categoryButton
	end

	local descriptionField = TextField(scope, {
		Text = descriptionText,
		PlaceholderText = "Describe what happened, and how to reproduce it if you can...",
		Multiline = true,
		MaxLength = DESCRIPTION_MAX_LENGTH,
		Size = UDim2.new(1, 0, 0, 140),
	})

	local submitButton = Button(scope, {
		Text = submitButtonText,
		Size = UDim2.new(0.5, -Tokens.Space.XS, 0, Tokens.Control.RowHeight),
		LayoutOrder = 1,
		Disabled = submitDisabled,
		OnActivated = function()
			if peek(submitDisabled) then
				return
			end
			submitRequestedEvent:Fire(peek(selectedCategory), peek(descriptionText))
		end,
	})

	local cancelButton = Button(scope, {
		Text = "Cancel",
		Size = UDim2.new(0.5, -Tokens.Space.XS, 0, Tokens.Control.RowHeight),
		LayoutOrder = 2,
		OnActivated = close,
	})

	-- Not held: the only thing this screen used the returned Root for was its own
	-- GuiService.SelectedObject bookkeeping, which Shell/Focus.lua now owns.
	ModalScreen(scope, playerGui, {
		Name = "BugReport",
		Size = UDim2.fromOffset(ROOT_WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		IsOpen = isOpen,
		-- The first category button rather than the derived first-in-reading-order control, which
		-- would be the close "X" -- opening a form with focus on its own dismiss button is a worse
		-- landing spot than the first real field. This is exactly the case Focus.Group's Default
		-- exists for.
		FocusDefault = categoryButtons[1],

		Children = {
			scope:New "Frame" {
				Name = "Header",
				Size = UDim2.new(1, 0, 0, 36),
				BackgroundTransparency = 1,
				LayoutOrder = 1,

				[Children] = {
					Label(scope, {
						Text = "Report an Issue",
						Scale = "Heading",
						AnchorPoint = Vector2.new(0, 0.5),
						Position = UDim2.fromScale(0, 0.5),
					}),
					closeButton,
				},
			},

			scope:New "Frame" {
				Name = "CategorySection",
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				LayoutOrder = 2,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Vertical,
						HorizontalAlignment = Enum.HorizontalAlignment.Left,
						Padding = UDim.new(0, Tokens.Space.S),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					-- "Category" titles this section's own button row -- a section title, not an
					-- inline row label (docs/design/intro-redesign-handoff.md Phase F's Subheading
					-- sweep), so it takes the serif CardTitle rather than BodyLarge.
					Label(scope, { Text = "Category", Scale = "CardTitle", LayoutOrder = 1 }),
					scope:New "Frame" {
						Name = "CategoryRow",
						Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
						BackgroundTransparency = 1,
						LayoutOrder = 2,

						[Children] = {
							scope:New "UIListLayout" {
								FillDirection = Enum.FillDirection.Horizontal,
								Padding = UDim.new(0, Tokens.Space.S),
								SortOrder = Enum.SortOrder.LayoutOrder,
							},
							table.unpack(categoryButtons),
						},
					},
				},
			},

			scope:New "Frame" {
				Name = "DescriptionSection",
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				LayoutOrder = 3,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Vertical,
						HorizontalAlignment = Enum.HorizontalAlignment.Left,
						Padding = UDim.new(0, Tokens.Space.XS),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					scope:New "Frame" {
						Name = "DescriptionHeaderRow",
						Size = UDim2.new(1, 0, 0, 20),
						BackgroundTransparency = 1,
						LayoutOrder = 1,

						[Children] = {
							-- Same section-title judgment as "Category" above.
							Label(scope, {
								Text = "Description",
								Scale = "CardTitle",
								AnchorPoint = Vector2.new(0, 0.5),
								Position = UDim2.fromScale(0, 0.5),
							}),
							Label(scope, {
								Text = characterCountText,
								Scale = "Detail",
								Color = Tokens.Color.TextSecondary,
								AnchorPoint = Vector2.new(1, 0.5),
								Position = UDim2.fromScale(1, 0.5),
								TextXAlignment = Enum.TextXAlignment.Right,
							}),
						},
					},
					descriptionField,
				},
			},

			scope:New "Frame" {
				Name = "Footer",
				Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
				BackgroundTransparency = 1,
				LayoutOrder = 4,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						Padding = UDim.new(0, Tokens.Space.S),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					submitButton,
					cancelButton,
				},
			},

			Label(scope, {
				Text = statusText,
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				Size = UDim2.new(1, 0, 0, 20),
				LayoutOrder = 5,
			}),
		},
	})

	return {
		IsOpen = isOpen,
		StatusText = statusText,
		IsSubmitting = isSubmitting,
		SubmitRequested = submitRequestedEvent.Event,
	}
end

return { Mount = BugReport }
