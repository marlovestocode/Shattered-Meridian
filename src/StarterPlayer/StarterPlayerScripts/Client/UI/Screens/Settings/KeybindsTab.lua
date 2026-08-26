--!strict
--[[
	Settings/KeybindsTab.lua

	Owns: the Settings panel's Keybinds tab -- a Keyboard/Gamepad sub-tab strip, one scrollable row
	per rebindable Types.KeybindAction (label + current key + Rebind/Cancel button), and the "Reset
	to Defaults" button for whichever sub-tab is currently selected. Both device columns mount up
	front and toggle via Visible rather than re-mounting on sub-tab clicks -- the same idiom
	Screens/DevMenu/ContentArea.lua's own `tabContent` already established.

	Follows Screens/DevMenu/init.lua's "screen exposes state/signals, client module drives from
	outside" precedent: this component owns no binding STATE and takes no rebind action of its own.
	Every row's displayed key comes from props.KeyboardBindings/GamepadBindings (owned and written by
	Client/Settings/SettingsClient.lua), and clicking Rebind/Reset only ever calls the matching prop
	callback -- the driver decides what actually happens (listening for the next InputBegan,
	persisting the change, updating those same Bindings Values).

	The one thing it does reach into KeybindManager for is Describe -- a pure "how is this binding
	spelled" formatter over a Types.Keybind it was already handed, with no read of live state and no
	side effect. It used to be a private formatKeybind here, along with the MouseButton1 -> "Mouse 1"
	label map, which stopped being tenable the moment a second surface printed a key
	(Components/KeyLegend.lua under the hotbar): how an input is spelled is a fact about
	KeybindManager's own data, not about this tab, and two copies of it would drift the first time a
	new input type needed a friendly name.

	REBINDABLE_ACTIONS is computed once, off Constants.Keybinds.Defaults (a complete map of every
	currently-known KeybindAction, per KeybindManager.lua's own header) filtered by the same
	HotbarSlot*-prefix exclusion Server/Systems/SettingsSystem.lua enforces server-side -- a future
	action that ACTION_DISPLAY_ORDER/ACTION_LABELS below haven't been updated for yet still appears
	(sorted alphabetically, appended after the hand-ordered ones), just without a friendly label.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Types = require(ReplicatedStorage.Shared.Types)
local Constants = require(ReplicatedStorage.Shared.Constants)

local KeybindManager = require(script.Parent.Parent.Parent.Parent.Input.KeybindManager)
local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Components.Label)
local Button = require(script.Parent.Parent.Parent.Components.Button)
local Tab = require(script.Parent.Parent.Parent.Components.Tab)
local ScrollArea = require(script.Parent.Parent.Parent.Components.ScrollArea)

local Children = Fusion.Children
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>
type ListeningState = { Device: Types.KeybindDevice, Action: Types.KeybindAction }

export type KeybindsTabProps = {
	Width: number,
	Height: number,
	Visible: UsedAs<boolean>,
	LayoutOrder: UsedAs<number>?,
	KeyboardBindings: Fusion.Value<{ [string]: Types.Keybind }>,
	GamepadBindings: Fusion.Value<{ [string]: Types.Keybind }>,
	ListeningFor: Fusion.Value<ListeningState?>,
	OnRebindClicked: (device: Types.KeybindDevice, action: Types.KeybindAction) -> (),
	OnResetClicked: (device: Types.KeybindDevice) -> (),
}

-- Manual display order for the actions players see/use most; see file header for how an action
-- absent from this list is still reachable.
local ACTION_DISPLAY_ORDER = {
	"BasicAttack",
	"HeavyAttack",
	"Block",
	"Feint",
	"LockOn",
	"Dash",
	"Slide",
	"Sprint",
	"SwapWeapon",
	"ShiftLock",
	"EmoteWheel",
	"OpenBugReport",
	"OpenMoveEditor",
	"DevMenuToggle",
	"OpenDevConsole",
	"SettingsToggle",
}

local ACTION_LABELS: { [string]: string } = {
	BasicAttack = "Basic Attack",
	HeavyAttack = "Heavy Attack",
	Block = "Block / Parry",
	Feint = "Feint",
	LockOn = "Lock On",
	Dash = "Dash",
	Slide = "Slide",
	Sprint = "Sprint",
	SwapWeapon = "Swap Weapon",
	ShiftLock = "Shift Lock Camera",
	EmoteWheel = "Emote Wheel",
	OpenBugReport = "Report a Bug",
	OpenMoveEditor = "Move Editor",
	DevMenuToggle = "Dev Menu",
	OpenDevConsole = "Developer Console",
	SettingsToggle = "Settings",
}

-- Same rule Server/Systems/SettingsSystem.lua's own isRebindableAction enforces server-side --
-- hotbar slots stay fixed and never appear in this list, per a name-prefix check rather than a
-- hardcoded list so it stays correct as more hotbar-adjacent actions get added.
local function isRebindableAction(action: string): boolean
	return not string.match(action, "^HotbarSlot")
end

local function computeRebindableActions(): { Types.KeybindAction }
	local seen: { [string]: boolean } = {}
	local ordered: { Types.KeybindAction } = {}
	for _, action in ACTION_DISPLAY_ORDER do
		if Constants.Keybinds.Defaults[action :: Types.KeybindAction] and isRebindableAction(action) then
			table.insert(ordered, action :: Types.KeybindAction)
			seen[action] = true
		end
	end

	local rest: { Types.KeybindAction } = {}
	for action in Constants.Keybinds.Defaults do
		if not seen[action] and isRebindableAction(action) then
			table.insert(rest, action)
		end
	end
	table.sort(rest)
	for _, action in rest do
		table.insert(ordered, action)
	end

	return ordered
end

local REBINDABLE_ACTIONS = computeRebindableActions()

local ROW_HEIGHT = Tokens.Control.RowHeight
local SUB_TAB_HEIGHT = 32

local function KeybindRow(
	scope: Scope,
	device: Types.KeybindDevice,
	action: Types.KeybindAction,
	layoutOrder: number,
	bindings: Fusion.Value<{ [string]: Types.Keybind }>,
	listeningFor: Fusion.Value<ListeningState?>,
	onRebindClicked: (Types.KeybindDevice, Types.KeybindAction) -> ()
): Frame
	local isListening = scope:Computed(function(use)
		local listening = use(listeningFor)
		return listening ~= nil and listening.Device == device and listening.Action == action
	end)

	local keyText = scope:Computed(function(use)
		if use(isListening) then
			return "Press a key..."
		end
		return KeybindManager.Describe(use(bindings)[action])
	end)

	local buttonText = scope:Computed(function(use)
		return if use(isListening) then "Cancel" else "Rebind"
	end)

	return scope:New "Frame" {
		Name = action,
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
		BackgroundTransparency = 1,
		LayoutOrder = layoutOrder,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Horizontal,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0, Tokens.Space.S),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			Label(scope, {
				Text = ACTION_LABELS[action] or action,
				Scale = "Body",
				Size = UDim2.new(0.5, -Tokens.Space.S, 1, 0),
				LayoutOrder = 1,
			}),
			Label(scope, {
				Text = keyText,
				Scale = "Body",
				Color = Tokens.Color.TextSecondary,
				Size = UDim2.new(0.25, -Tokens.Space.S, 1, 0),
				LayoutOrder = 2,
			}),
			Button(scope, {
				Text = buttonText,
				Size = UDim2.new(0.25, 0, 0, Tokens.Control.StepButtonSize),
				LayoutOrder = 3,
				OnActivated = function()
					onRebindClicked(device, action)
				end,
			}),
		},
	} :: Frame
end

local function buildDeviceRows(
	scope: Scope,
	device: Types.KeybindDevice,
	bindings: Fusion.Value<{ [string]: Types.Keybind }>,
	listeningFor: Fusion.Value<ListeningState?>,
	isSelected: UsedAs<boolean>,
	scrollSize: UDim2,
	onRebindClicked: (Types.KeybindDevice, Types.KeybindAction) -> ()
): ScrollingFrame
	local rows: { Instance } = {}
	for index, action in REBINDABLE_ACTIONS do
		table.insert(rows, KeybindRow(scope, device, action, index, bindings, listeningFor, onRebindClicked))
	end

	return ScrollArea(scope, {
		Name = device .. "Rows",
		Size = scrollSize,
		LayoutOrder = 2,
		Visible = isSelected,

		Children = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Left,
				Padding = UDim.new(0, Tokens.Space.XS),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			table.unpack(rows),
		},
	})
end

local function KeybindsTab(scope: Scope, props: KeybindsTabProps): Frame
	local selectedDevice = scope:Value("Keyboard" :: Types.KeybindDevice)

	local scrollHeight = props.Height - SUB_TAB_HEIGHT - Tokens.Control.RowHeight - Tokens.Space.S * 2
	local scrollSize = UDim2.new(1, 0, 0, scrollHeight)

	local keyboardTabButton = Tab(scope, {
		Text = "Keyboard",
		Size = UDim2.new(0.5, -Tokens.Space.XS, 0, SUB_TAB_HEIGHT),
		LayoutOrder = 1,
		Selected = scope:Computed(function(use)
			return use(selectedDevice) == "Keyboard"
		end),
		OnActivated = function()
			selectedDevice:set("Keyboard")
		end,
	})
	local gamepadTabButton = Tab(scope, {
		Text = "Gamepad",
		Size = UDim2.new(0.5, -Tokens.Space.XS, 0, SUB_TAB_HEIGHT),
		LayoutOrder = 2,
		Selected = scope:Computed(function(use)
			return use(selectedDevice) == "Gamepad"
		end),
		OnActivated = function()
			selectedDevice:set("Gamepad")
		end,
	})

	local keyboardSelected = scope:Computed(function(use)
		return use(selectedDevice) == "Keyboard"
	end)
	local gamepadSelected = scope:Computed(function(use)
		return use(selectedDevice) == "Gamepad"
	end)

	local keyboardRows = buildDeviceRows(
		scope,
		"Keyboard",
		props.KeyboardBindings,
		props.ListeningFor,
		keyboardSelected,
		scrollSize,
		props.OnRebindClicked
	)
	local gamepadRows = buildDeviceRows(
		scope,
		"Gamepad",
		props.GamepadBindings,
		props.ListeningFor,
		gamepadSelected,
		scrollSize,
		props.OnRebindClicked
	)

	local resetButton = Button(scope, {
		Text = "Reset to Defaults",
		Size = UDim2.new(1, 0, 0, Tokens.Control.RowHeight),
		LayoutOrder = 3,
		OnActivated = function()
			props.OnResetClicked(peek(selectedDevice))
		end,
	})

	return scope:New "Frame" {
		Name = "KeybindsTab",
		Size = UDim2.fromOffset(props.Width, props.Height),
		BackgroundTransparency = 1,
		Visible = props.Visible,
		LayoutOrder = props.LayoutOrder,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Left,
				Padding = UDim.new(0, Tokens.Space.S),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			scope:New "Frame" {
				Name = "DeviceTabStrip",
				Size = UDim2.new(1, 0, 0, SUB_TAB_HEIGHT),
				BackgroundTransparency = 1,
				LayoutOrder = 1,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						Padding = UDim.new(0, Tokens.Space.S),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					keyboardTabButton,
					gamepadTabButton,
				},
			},
			keyboardRows,
			gamepadRows,
			resetButton,
		},
	} :: Frame
end

return KeybindsTab
