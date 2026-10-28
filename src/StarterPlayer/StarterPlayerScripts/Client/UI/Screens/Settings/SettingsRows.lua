--!strict
--[[
	Settings/SettingsRows.lua

	Owns: the two row shapes the Settings tabs share -- a small section heading, and a labelled row holding a Stepper with its
	hint under it. ControllerTab and GameplayTab each carried a byte-identical copy of both (they had said a third tab would be
	the moment to share). It lives beside the tabs, not in Components/, so it stays a contract between the Settings tabs only.

	Toggle.lua already draws its own label/hint pair, so NumberRow exists only for the numeric rows, which have no such
	component.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Components.Label)
local Stepper = require(script.Parent.Parent.Parent.Components.Stepper)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

local SettingsRows = {}

function SettingsRows.SectionLabel(scope: Scope, text: string, layoutOrder: number): Frame
	return scope:New "Frame" {
		Name = "SectionLabel",
		Size = UDim2.new(1, 0, 0, 22),
		BackgroundTransparency = 1,
		LayoutOrder = layoutOrder,

		[Children] = Label(scope, {
			Text = text,
			Scale = "Detail",
			Color = Tokens.Color.TextSecondary,
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
		}),
	} :: Frame
end

-- A labelled row holding a Stepper on the right. Toggle.lua already draws its own label/hint pair, so
-- this exists only for the numeric rows, which have no such component.
function SettingsRows.NumberRow(
	scope: Scope,
	label: string,
	hint: string,
	value: UsedAs<number>,
	min: number,
	max: number,
	step: number,
	format: (number) -> string,
	onChanged: (number) -> (),
	layoutOrder: number
): Frame
	return scope:New "Frame" {
		Name = `Row_{label}`,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = layoutOrder,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				Padding = UDim.new(0, 2),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			-- The label and the control share a row; the hint sits under both, full width, the same
			-- reading order Toggle.lua establishes for its own hint.
			scope:New "Frame" {
				Name = "Control",
				Size = UDim2.new(1, 0, 0, 32),
				BackgroundTransparency = 1,
				LayoutOrder = 1,

				[Children] = {
					Label(scope, {
						Text = label,
						Scale = "Body",
						Color = Tokens.Color.TextPrimary,
						AnchorPoint = Vector2.new(0, 0.5),
						Position = UDim2.fromScale(0, 0.5),
					}),
					-- Stepper, like Dropdown, exports a MODULE with a .Mount rather than being directly
					-- callable (Toggle/Label are plain functions) -- see Components/Stepper.lua's own
					-- StepperModule, which also carries the WIDTH the Onboarding screen budgets against.
					Stepper.Mount(scope, {
						Value = value,
						Min = min,
						Max = max,
						Step = step,
						FormatValue = format,
						OnChanged = onChanged,
						AnchorPoint = Vector2.new(1, 0.5),
						Position = UDim2.fromScale(1, 0.5),
					}),
				},
			},
			Label(scope, {
				Text = hint,
				Scale = "Detail",
				Color = Tokens.Color.TextSecondary,
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				TextWrapped = true,
				TextXAlignment = Enum.TextXAlignment.Left,
				LayoutOrder = 2,
			}),
		},
	} :: Frame
end

return SettingsRows
