--!strict
--[[
	Settings/ControllerTab.lua

	Owns: the Settings panel's Controller tab -- how the two thumbsticks are READ. Look sensitivity,
	the two deadzones, invert-Y, and the vibration switch.

	Same "screen exposes state/signals, client module drives from outside" precedent as
	GameplayTab.lua and KeybindsTab.lua: this component owns no persistence and no behavior. Changing
	anything calls the matching OnXChanged prop and Client/Settings/SettingsClient.lua decides what
	happens (push it into Client/Input/Analog.lua, fire the persistence remote).

	WHICH BUTTON DOES WHAT IS NOT HERE -- that is the Keybinds tab's gamepad sub-tab, which already
	exists and already persists through Types.PlayerSettings.GamepadKeybinds. This tab is the other
	half of "controller settings": the analog half, which had no home at all before it. Splitting them
	this way means neither tab has to explain that it only covers part of the pad.

	TWO SEPARATE DEADZONE ROWS, which is the one choice here most likely to be read as clutter. It is
	not: the two sticks fail differently. A worn LEFT stick that drifts walks the character across the
	map on its own, while a worn RIGHT stick merely turns the camera -- and a single shared row would
	force a player with one bad stick to blunt the good one to fix it. Controllers wear asymmetrically
	(the left stick takes far more use in this game), so this is the common case rather than the
	exotic one.

	NO SENSITIVITY ROW FOR THE LEFT STICK, deliberately, and its absence is load-bearing: that stick's
	magnitude IS the walk-versus-run request that reaches Humanoid.MoveDirection, so a "sensitivity"
	slider on it would silently retune movement speed while claiming to be about aim feel. See
	Client/Input/Analog.lua's header for the same split stated from the reading side.

	Every numeric row is a Stepper rather than a slider: this panel must be operable ON A CONTROLLER
	by a player whose stick is currently misconfigured, which is the whole reason they are here. A
	slider needs an analog drag to set -- exactly the input that may be broken -- while a Stepper's
	two buttons are reachable with the D-pad and A. A settings screen that requires a working stick to
	fix a broken stick is a trap.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Components.Label)
local Stepper = require(script.Parent.Parent.Parent.Components.Stepper)
local Toggle = require(script.Parent.Parent.Parent.Components.Toggle)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

-- Which Types.GamepadSettings field each row writes. Its own union for the same reason
-- GameplayTab.lua keeps ParkourToggleField and ComfortToggleField separate: these write a different
-- sub-table through a different remote, and letting one field name stand for several groups would
-- make a typo route silently to the wrong handler.
export type GamepadNumberField = "LookSensitivity" | "MoveDeadzone" | "LookDeadzone"
export type GamepadToggleField = "InvertLookY" | "Vibration"

export type ControllerTabProps = {
	Width: number,
	Height: number,
	Visible: UsedAs<boolean>,
	LayoutOrder: UsedAs<number>?,
	-- The live gamepad block, written from outside by SettingsClient after it restores the persisted
	-- settings. One Value for the whole table rather than one per field, so the screen never holds a
	-- partially-updated view of it -- same shape and same reasoning as GameplayTab's Parkour prop.
	Gamepad: Fusion.Value<Types.GamepadSettings>,
	OnGamepadNumberChanged: (field: GamepadNumberField, value: number) -> (),
	OnGamepadToggled: (field: GamepadToggleField, enabled: boolean) -> (),
}

local ROW_SPACING = Tokens.Space.S

-- Step sizes. Both are the coarsest value that still lets a player land on a setting they like --
-- a finer step just means more presses to cross the same range on a device whose only input here is
-- a button.
local SENSITIVITY_STEP = 0.25
local DEADZONE_STEP = 0.05

-- The readout formats. Sensitivity reads as a multiplier ("1.00x") because that is what it is; a
-- deadzone reads as a percentage of stick travel because "0.20" means nothing to a player and "20%"
-- means exactly the right thing. Both exist because a fractional Step accumulates floating-point
-- error that tostring would put on screen -- see Components/Stepper.lua's FormatValue prop.
local function formatSensitivity(value: number): string
	return string.format("%.2fx", value)
end

local function formatDeadzone(value: number): string
	return string.format("%d%%", math.round(value * 100))
end

-- The numeric rows, in display order. Data rather than three hand-wired blocks, so adding a fourth
-- knob is one entry here -- the same shape GameplayTab.lua's ASSIST_ROWS uses.
local NUMBER_ROWS: {
	{
		Field: GamepadNumberField,
		Label: string,
		Hint: string,
		Step: number,
		Format: (number) -> string,
		Bounds: string,
	}
} =
	{
		{
			Field = "LookSensitivity",
			Label = "Look sensitivity",
			Hint = "How fast the right stick turns the camera. Affects aim only -- movement speed is unchanged.",
			Step = SENSITIVITY_STEP,
			Format = formatSensitivity,
			Bounds = "LookSensitivity",
		},
		{
			Field = "MoveDeadzone",
			Label = "Movement stick deadzone",
			Hint = "How far the left stick must move before the character does. Raise this if you drift while standing still.",
			Step = DEADZONE_STEP,
			Format = formatDeadzone,
			Bounds = "Deadzone",
		},
		{
			Field = "LookDeadzone",
			Label = "Camera stick deadzone",
			Hint = "How far the right stick must move before the camera does. Raise this if the view drifts on its own.",
			Step = DEADZONE_STEP,
			Format = formatDeadzone,
			Bounds = "Deadzone",
		},
	}

-- Copied from GameplayTab.lua rather than shared, and that is a deliberate line to hold: it is eight
-- lines of tab-local layout, and hoisting it into Components/ would make it a shared contract that
-- both tabs then have to agree about forever. If a third tab wants one, that is the moment it earns
-- a component.
local function sectionLabel(scope: Scope, text: string, layoutOrder: number): Frame
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
local function numberRow(
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

local function ControllerTab(scope: Scope, props: ControllerTabProps): ScrollingFrame
	-- One Computed per field off the single Gamepad Value, so the screen re-renders from one source
	-- of truth rather than from five independently-written Values that could disagree. Same shape as
	-- GameplayTab.fieldValue.
	local function numberValue(field: GamepadNumberField): UsedAs<number>
		return scope:Computed(function(use)
			return (use(props.Gamepad) :: { [string]: any })[field] :: number
		end)
	end

	local function toggleValue(field: GamepadToggleField): UsedAs<boolean>
		return scope:Computed(function(use)
			return (use(props.Gamepad) :: { [string]: any })[field] == true
		end)
	end

	local rows: { Instance } = {
		scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Left,
			Padding = UDim.new(0, ROW_SPACING),
			SortOrder = Enum.SortOrder.LayoutOrder,
		},

		sectionLabel(scope, "STICKS", 1),
	}

	for index, row in NUMBER_ROWS do
		local field = row.Field
		local bounds = (Constants.Settings.Gamepad.Bounds :: { [string]: any })[row.Bounds]
		table.insert(
			rows,
			numberRow(
				scope,
				row.Label,
				row.Hint,
				numberValue(field),
				bounds.Min,
				bounds.Max,
				row.Step,
				row.Format,
				function(value: number)
					props.OnGamepadNumberChanged(field, value)
				end,
				1 + index
			)
		)
	end

	table.insert(
		rows,
		Toggle(scope, {
			Label = "Invert camera Y axis",
			Value = toggleValue("InvertLookY"),
			OnChanged = function(enabled: boolean)
				props.OnGamepadToggled("InvertLookY", enabled)
			end,
			Hint = "Push the right stick down to look up.",
			LayoutOrder = 2 + #NUMBER_ROWS,
		})
	)

	table.insert(rows, sectionLabel(scope, "FEEDBACK", 3 + #NUMBER_ROWS))
	table.insert(
		rows,
		Toggle(scope, {
			Label = "Controller vibration",
			Value = toggleValue("Vibration"),
			OnChanged = function(enabled: boolean)
				props.OnGamepadToggled("Vibration", enabled)
			end,
			-- Says plainly that nothing reads this yet rather than implying a feature that is not
			-- there. The setting is persisted and validated now so the schema does not need a second
			-- bump when haptics land -- see Types.GamepadSettings.Vibration.
			Hint = "Rumble on impacts. Reserved -- no effect until controller haptics ship.",
			LayoutOrder = 4 + #NUMBER_ROWS,
		})
	)

	return scope:New "ScrollingFrame" {
		Name = "ControllerTab",
		Size = UDim2.fromOffset(props.Width, props.Height),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Visible = props.Visible,
		LayoutOrder = props.LayoutOrder,
		-- Height is driven by the UIListLayout's own measured content, so a new row never needs this
		-- number maintained by hand.
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollBarThickness = 4,
		ScrollingDirection = Enum.ScrollingDirection.Y,

		[Children] = rows,
	} :: ScrollingFrame
end

return ControllerTab
