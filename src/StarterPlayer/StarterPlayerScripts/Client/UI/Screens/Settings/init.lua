--!strict
--[[
	Settings/init.lua

	Owns: the Settings panel's thin root -- the banded frame (Components/ScreenFrame.lua) wrapped
	around the two tab sub-modules, plus IsOpen and every piece of state the two tab sub-modules
	(KeybindsTab.lua/GameplayTab.lua) render from. Follows Screens/DevTools/DevMenu/init.lua's "screen exposes
	state/signals, client module drives from outside" precedent exactly: Client/Settings/
	SettingsClient.lua doesn't exist yet at the moment this mounts (UI/init.lua mounts every Screen
	before Main.client.lua boots any client integration module), so every action that has a real
	effect (a rebind capture, a reset, an Autorun flip) fires a BindableEvent instead of taking a
	callback prop, and every piece of DISPLAYED state (KeyboardBindings/GamepadBindings/Autorun) is a
	Fusion.Value owned by this Mount call but written to exclusively from outside by SettingsClient --
	this module never calls KeybindManager or NetworkBridge itself. The close button is the one
	exception, exactly like DevMenu's own: IsOpen is already a Fusion.Value owned here, so closing
	just sets it directly.

	Both tabs mount up front and toggle via each one's own Visible prop rather than re-mounting on
	tab clicks -- same idiom KeybindsTab.lua's own device sub-tabs already use.

	WEARS THE CHARACTER MENU'S FRAME as of the ScreenFrame extraction, and loses three things in the
	trade: the 36px header band whose only content was the word "Settings" (the tab strip is already
	the loudest thing on the panel, and this screen's identity moved to the footer wordmark), the
	free-floating close button that used to sit in that header, and the bare status Label at the
	bottom of the content stack -- which was the one piece of chrome most clearly in the wrong place,
	since an answer to "did that rebind take" was rendering INSIDE the scrolling column it was
	answering about. See ScreenFrame.lua's own header for the rest of the argument.

	Does not own: what a rebind/reset/toggle actually DOES (SettingsClient.lua), or whether the local
	player currently sees this panel open (SettingsClient's own keybind toggle).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Types = require(ReplicatedStorage.Shared.Types)

local Tokens = require(script.Parent.Parent.Tokens)
local ScreenFrame = require(script.Parent.Parent.Components.ScreenFrame)
local Stack = require(script.Parent.Parent.Components.Stack)
local Inset = require(script.Parent.Parent.Components.Inset)
local KeybindsTab = require(script.KeybindsTab)
local GameplayTab = require(script.GameplayTab)

type Scope = Fusion.Scope<typeof(Fusion)>

export type SettingsTabName = "Keybinds" | "Gameplay"

export type SettingsHandle = {
	IsOpen: Fusion.Value<boolean>,
	StatusText: Fusion.Value<string>,
	-- Owned and written by SettingsClient.lua (KeybindManager.GetAll()/GetAllGamepad(), refreshed
	-- after every successful rebind/reset) -- see KeybindsTab.lua's own header for why this screen
	-- never reads KeybindManager directly.
	KeyboardBindings: Fusion.Value<{ [string]: Types.Keybind }>,
	GamepadBindings: Fusion.Value<{ [string]: Types.Keybind }>,
	Autorun: Fusion.Value<boolean>,
	-- The Parkour System's persisted preference block, written from outside by SettingsClient exactly
	-- like KeyboardBindings/Autorun above. One Value for the whole table rather than one per field --
	-- see GameplayTab.lua's own note for why the tab derives its rows from a single source.
	Parkour: Fusion.Value<Types.ParkourSettings>,
	-- The camera-comfort accessibility block, written from outside by SettingsClient exactly like
	-- Parkour above, and one Value for the whole table for the same reason.
	Comfort: Fusion.Value<Types.ComfortSettings>,
	-- Non-nil while SettingsClient is mid-capture for one specific row (listening for the next
	-- InputBegan after that row's Rebind button was clicked) -- lets KeybindsTab.lua show "Press a
	-- key..."/"Cancel" on exactly that row and nowhere else.
	ListeningFor: Fusion.Value<{ Device: Types.KeybindDevice, Action: Types.KeybindAction }?>,
	-- Fires (device, action) -- a row's Rebind/Cancel button was clicked.
	RebindClicked: RBXScriptSignal<(Types.KeybindDevice, Types.KeybindAction)>,
	-- Fires (device) -- the "Reset to Defaults" button was clicked for whichever device sub-tab is
	-- currently selected.
	ResetKeybindsClicked: RBXScriptSignal<Types.KeybindDevice>,
	-- Fires (enabled) -- the Autorun toggle was flipped.
	AutorunToggled: RBXScriptSignal<boolean>,
	-- Fires (field, enabled) -- one of the Parkour boolean preferences was flipped. A single signal
	-- carrying the field name rather than one signal per preference, mirroring the single
	-- Settings_UpdateParkour remote behind it (see that constant's own header for the reasoning, and
	-- for the validation that makes the field name safe to send).
	ParkourToggled: RBXScriptSignal<(string, boolean)>,
	-- Fires (field, enabled) -- one of the camera-comfort toggles was flipped. Same single-signal-with-
	-- a-field-name shape as ParkourToggled above, behind the same kind of single remote.
	ComfortToggled: RBXScriptSignal<(string, boolean)>,
	-- Fires (mode) -- the sprint hold/toggle dropdown changed.
	SprintModeChanged: RBXScriptSignal<Types.SprintMode>,
}

local ROOT_WIDTH = 480
local ROOT_HEIGHT = 520

local TAB_NAMES: { string } = { "Keybinds", "Gameplay" }

-- The band heights are ScreenFrame's own and are no longer restated here. What is left is the tab
-- modules' own budget: both take an explicit pixel Width/Height, so the body's inset still has to be
-- subtracted by hand -- see Screens/Menus/init.lua's identical pair for why that subtraction is the
-- honest kind (an inset this file writes) rather than the kind that guesses a sibling's height.
local BODY_WIDTH, BODY_HEIGHT = ScreenFrame.BodySize(ROOT_WIDTH, ROOT_HEIGHT)
local CONTENT_WIDTH = BODY_WIDTH - Tokens.Space.L * 2
local CONTENT_HEIGHT = BODY_HEIGHT - Tokens.Space.M - Tokens.Space.L

local function Settings(scope: Scope, playerGui: PlayerGui): SettingsHandle
	local isOpen = scope:Value(false)
	local statusText = scope:Value("")
	local keyboardBindings = scope:Value({} :: { [string]: Types.Keybind })
	local gamepadBindings = scope:Value({} :: { [string]: Types.Keybind })
	local autorun = scope:Value(false)
	-- Seeded with every field present and off, NOT with the shipped defaults: SettingsClient
	-- overwrites this with the player's real persisted block before the panel can be opened, and
	-- seeding with plausible-looking defaults here would mean a failed settings fetch renders as
	-- "everything is on" instead of as the obviously-unpopulated state it actually is. Every field is
	-- present so GameplayTab's own per-field Computeds never index a nil table.
	local parkour = scope:Value({
		Enabled = false,
		CameraEffects = false,
		CoyoteTime = false,
		JumpBuffer = false,
		AutoVault = false,
		LedgeAssist = false,
		StepAssist = false,
		SprintMode = "Hold" :: Types.SprintMode,
	} :: Types.ParkourSettings)
	-- Seeded all-off for exactly the reason the parkour block above is, and it matters slightly more
	-- here: "on" is the shipped state for both of these, so seeding them true would make an
	-- unpopulated panel indistinguishable from a correctly-loaded one.
	local comfort = scope:Value({
		CameraShake = false,
		FieldOfViewEffects = false,
	} :: Types.ComfortSettings)
	local listeningFor = scope:Value(nil :: { Device: Types.KeybindDevice, Action: Types.KeybindAction }?)
	local tabs = ScreenFrame.NewTabState(scope, TAB_NAMES)

	local rebindClickedEvent = Instance.new("BindableEvent")
	local resetKeybindsClickedEvent = Instance.new("BindableEvent")
	local autorunToggledEvent = Instance.new("BindableEvent")
	local parkourToggledEvent = Instance.new("BindableEvent")
	local sprintModeChangedEvent = Instance.new("BindableEvent")
	local comfortToggledEvent = Instance.new("BindableEvent")

	local keybindsTabContent = KeybindsTab(scope, {
		Width = CONTENT_WIDTH,
		Height = CONTENT_HEIGHT,
		Visible = tabs.Selected["Keybinds"],
		LayoutOrder = 3,
		KeyboardBindings = keyboardBindings,
		GamepadBindings = gamepadBindings,
		ListeningFor = listeningFor,
		OnRebindClicked = function(device: Types.KeybindDevice, action: Types.KeybindAction)
			rebindClickedEvent:Fire(device, action)
		end,
		OnResetClicked = function(device: Types.KeybindDevice)
			resetKeybindsClickedEvent:Fire(device)
		end,
	})

	local gameplayTabContent = GameplayTab(scope, {
		Width = CONTENT_WIDTH,
		Height = CONTENT_HEIGHT,
		Visible = tabs.Selected["Gameplay"],
		LayoutOrder = 3,
		Autorun = autorun,
		OnAutorunToggled = function(enabled: boolean)
			autorunToggledEvent:Fire(enabled)
		end,
		Parkour = parkour,
		OnParkourToggled = function(field: GameplayTab.ParkourToggleField, enabled: boolean)
			parkourToggledEvent:Fire(field, enabled)
		end,
		Comfort = comfort,
		OnComfortToggled = function(field: GameplayTab.ComfortToggleField, enabled: boolean)
			comfortToggledEvent:Fire(field, enabled)
		end,
		OnSprintModeChanged = function(mode: Types.SprintMode)
			sprintModeChangedEvent:Fire(mode)
		end,
	})

	ScreenFrame.Mount(scope, playerGui, {
		Name = "Settings",
		Size = UDim2.fromOffset(ROOT_WIDTH, ROOT_HEIGHT),
		IsOpen = isOpen,
		-- Opted in alongside the character menu rather than left at ModalScreen's default: this is the
		-- other panel a player READS (a rebind list is a table of small text scanned row by row), and
		-- the two of them scaling differently on the same monitor would read as a bug rather than as
		-- two independent decisions.
		AutoScale = true,
		Tabs = tabs,
		-- Where the deleted header band's word went -- see this file's header.
		Wordmark = "SETTINGS",
		StatusText = statusText,
		OnClose = function()
			isOpen:set(false)
		end,

		Body = Stack.New(scope, {
			Name = "Body",
			Children = {
				Inset(scope, { Top = Tokens.Space.M, Bottom = Tokens.Space.L, X = Tokens.Space.L }),
				-- Exactly one is Visible at a time, so the Stack has one child to place -- same shape
				-- the character menu's own tab column uses.
				keybindsTabContent,
				gameplayTabContent,
			},
		}),
	})

	return {
		IsOpen = isOpen,
		StatusText = statusText,
		KeyboardBindings = keyboardBindings,
		GamepadBindings = gamepadBindings,
		Autorun = autorun,
		Parkour = parkour,
		Comfort = comfort,
		ListeningFor = listeningFor,
		RebindClicked = rebindClickedEvent.Event,
		ResetKeybindsClicked = resetKeybindsClickedEvent.Event,
		AutorunToggled = autorunToggledEvent.Event,
		ParkourToggled = parkourToggledEvent.Event,
		ComfortToggled = comfortToggledEvent.Event,
		SprintModeChanged = sprintModeChangedEvent.Event,
	}
end

return { Mount = Settings }
