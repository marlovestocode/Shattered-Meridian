--!strict
--[[
	Settings/GameplayTab.lua

	Owns: the Settings panel's Gameplay tab -- the Autorun toggle, the sprint hold/toggle mode, and
	the Parkour System's own preferences (master switch, camera effects, and each individual movement
	assist).

	Same "screen exposes state/signals, client module drives from outside" precedent as KeybindsTab.lua:
	this component owns no persistence and no behavior of its own. Flipping anything calls the matching
	OnXChanged prop, and Client/Settings/SettingsClient.lua decides what actually happens (push it to
	the owning client module, fire the persistence remote).

	Scrolls, unlike the single-toggle version this replaces. Ten controls do not fit the panel's fixed
	content height, and growing the panel to fit would push it past a comfortable size on smaller
	screens -- a scrolling body is the change that keeps adding an eleventh preference a one-line edit
	here rather than a re-layout of the whole panel.

	The assists are presented as their own labelled group with an explanatory line, deliberately: they
	are the settings most likely to be misread as "cheats" or as difficulty options, and
	docs/ui-ux-philosophy.md's guidance on explaining consequence at the point of the control applies
	more here than anywhere else in this panel.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Types = require(ReplicatedStorage.Shared.Types)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Dropdown = require(script.Parent.Parent.Parent.Components.Dropdown)
local Label = require(script.Parent.Parent.Parent.Components.Label)
local Toggle = require(script.Parent.Parent.Parent.Components.Toggle)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

-- Which Types.ParkourSettings field each assist toggle writes. Keyed rather than hand-wired per row
-- so adding a preference is one entry in the list below, not a new prop, a new signal and a new
-- handler in three files.
export type ParkourToggleField =
	"Enabled"
	| "CameraEffects"
	| "CoyoteTime"
	| "JumpBuffer"
	| "AutoVault"
	| "LedgeAssist"
	| "StepAssist"

-- Which Types.ComfortSettings field each camera-comfort toggle writes. Its own union rather than more
-- members on ParkourToggleField above, because the two write different sub-tables through different
-- remotes -- letting one field name stand for both would make a typo in either list silently route to
-- the wrong handler.
export type ComfortToggleField = "CameraShake" | "FieldOfViewEffects" | "VehicleCameraMotion"

export type GameplayTabProps = {
	Width: number,
	Height: number,
	Visible: UsedAs<boolean>,
	LayoutOrder: UsedAs<number>?,
	Autorun: Fusion.Value<boolean>,
	OnAutorunToggled: (enabled: boolean) -> (),
	-- The live Parkour preference block, written from outside by SettingsClient after it restores the
	-- persisted settings. One Value for the whole table rather than one per field, so the screen never
	-- holds a partially-updated view of it.
	Parkour: Fusion.Value<Types.ParkourSettings>,
	OnParkourToggled: (field: ParkourToggleField, enabled: boolean) -> (),
	-- The live camera-comfort block, written from outside by SettingsClient. Same one-Value-for-the-
	-- whole-table shape and same reasoning as Parkour above.
	Comfort: Fusion.Value<Types.ComfortSettings>,
	OnComfortToggled: (field: ComfortToggleField, enabled: boolean) -> (),
	OnSprintModeChanged: (mode: Types.SprintMode) -> (),
}

local ROW_SPACING = Tokens.Space.S

-- The assist rows, in display order. Each is a field name, its label, and the one-line explanation of
-- what turning it ON does -- see the file header for why these specifically carry explanations.
local ASSIST_ROWS: { { Field: ParkourToggleField, Label: string, Hint: string } } = {
	{
		Field = "CoyoteTime",
		Label = "Coyote time",
		Hint = "Lets a jump still count for a moment after you run off an edge.",
	},
	{
		Field = "JumpBuffer",
		Label = "Jump buffering",
		Hint = "A jump pressed just before you land fires the moment you touch down.",
	},
	{
		Field = "AutoVault",
		Label = "Automatic vaulting",
		Hint = "Vault and hop obstacles automatically when running at them.",
	},
	{
		Field = "LedgeAssist",
		Label = "Ledge assist",
		Hint = "Automatically catch a ledge you fall past within reach.",
	},
	{
		Field = "StepAssist",
		Label = "Small obstacle smoothing",
		Hint = "Ignore kerb-height clutter instead of interrupting your run for it.",
	},
}

local SPRINT_MODE_OPTIONS: { Dropdown.DropdownOption } = {
	{ Value = "Hold", Text = "Hold to sprint" },
	{ Value = "Toggle", Text = "Toggle sprint" },
}

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

local function GameplayTab(scope: Scope, props: GameplayTabProps): ScrollingFrame
	-- One Computed per field, derived from the single Parkour Value -- so the screen re-renders from
	-- one source of truth rather than from seven independently-written Values that could disagree.
	local function fieldValue(field: ParkourToggleField): UsedAs<boolean>
		return scope:Computed(function(use)
			return (use(props.Parkour) :: { [string]: any })[field] == true
		end)
	end

	-- Sibling to fieldValue above, against the Comfort block. Separate rather than generic over both
	-- tables so each stays type-checked against its own field union.
	local function comfortValue(field: ComfortToggleField): UsedAs<boolean>
		return scope:Computed(function(use)
			return (use(props.Comfort) :: { [string]: any })[field] == true
		end)
	end

	local sprintMode = scope:Computed(function(use)
		return use(props.Parkour).SprintMode :: string
	end)

	local rows: { Instance } = {
		scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Left,
			Padding = UDim.new(0, ROW_SPACING),
			SortOrder = Enum.SortOrder.LayoutOrder,
		},

		sectionLabel(scope, "MOVEMENT", 1),
		Toggle(scope, {
			Label = "Parkour movement",
			Value = fieldValue("Enabled"),
			OnChanged = function(enabled: boolean)
				props.OnParkourToggled("Enabled", enabled)
			end,
			Hint = "Vaulting, sliding, wall-running, ledge climbing and rolling. Turning this off falls back to standard movement.",
			LayoutOrder = 2,
		}),
		Toggle(scope, {
			Label = "Autorun (sprint without holding Sprint)",
			Value = props.Autorun,
			OnChanged = props.OnAutorunToggled,
			LayoutOrder = 3,
		}),
		-- Dropdown is the one component in this folder that exports a MODULE with a .Mount rather than
		-- being directly callable (Toggle/Label are plain functions) -- see Components/Dropdown.lua's
		-- own DropdownModule.
		Dropdown.Mount(scope, {
			Label = "Sprint",
			Options = SPRINT_MODE_OPTIONS,
			Value = sprintMode,
			OnChanged = function(value: string)
				props.OnSprintModeChanged(value :: Types.SprintMode)
			end,
			LayoutOrder = 4,
		}),

		sectionLabel(scope, "CAMERA", 5),
		Toggle(scope, {
			Label = "Movement camera effects",
			Value = fieldValue("CameraEffects"),
			OnChanged = function(enabled: boolean)
				props.OnParkourToggled("CameraEffects", enabled)
			end,
			Hint = "Speed zoom, slide framing, wall-run lean and landing dips.",
			LayoutOrder = 6,
		}),
		-- Combat's camera motion, kept as its own two rows rather than folded into the parkour toggle
		-- above: a player who turns parkour's camera work off has said something about traversal, not
		-- about being hit, and before these existed there was no way to say the second thing at all.
		-- Both are worded as what they DO rather than as an accessibility label, so they read as
		-- ordinary options to everyone -- the hint carries the reason for anyone looking for it.
		Toggle(scope, {
			Label = "Combat camera shake",
			Value = comfortValue("CameraShake"),
			OnChanged = function(enabled: boolean)
				props.OnComfortToggled("CameraShake", enabled)
			end,
			Hint = "The camera kick on hits, parries and posture breaks. Turn this off if camera motion is uncomfortable -- nothing about combat itself changes.",
			LayoutOrder = 7,
		}),
		Toggle(scope, {
			Label = "Impact field-of-view punches",
			Value = comfortValue("FieldOfViewEffects"),
			OnChanged = function(enabled: boolean)
				props.OnComfortToggled("FieldOfViewEffects", enabled)
			end,
			Hint = "The short zoom that punctuates an impact. The gradual speed zoom while running is unaffected.",
			LayoutOrder = 8,
		}),
		-- Its own row rather than a third meaning for the shake toggle above, on the same reasoning that
		-- separated combat's two rows from parkour's: riding a blimp is a different situation from being
		-- hit, and a player has every reason to want one and not the other. The hint says what stays on,
		-- because "off" here is a partial answer by design -- see Types.ComfortSettings.
		Toggle(scope, {
			Label = "Airship camera lean",
			Value = comfortValue("VehicleCameraMotion"),
			OnChanged = function(enabled: boolean)
				props.OnComfortToggled("VehicleCameraMotion", enabled)
			end,
			Hint = "The roll and sway the view takes on while riding a blimp. Off keeps the sense of speed -- the pull-back and the drift under acceleration stay -- and only levels the horizon.",
			LayoutOrder = 9,
		}),

		sectionLabel(scope, "MOVEMENT ASSISTS", 10),
	}

	for index, row in ASSIST_ROWS do
		local field = row.Field
		table.insert(
			rows,
			Toggle(scope, {
				Label = row.Label,
				Value = fieldValue(field),
				OnChanged = function(enabled: boolean)
					props.OnParkourToggled(field, enabled)
				end,
				Hint = row.Hint,
				LayoutOrder = 9 + index,
			})
		)
	end

	return scope:New "ScrollingFrame" {
		Name = "GameplayTab",
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

return GameplayTab
