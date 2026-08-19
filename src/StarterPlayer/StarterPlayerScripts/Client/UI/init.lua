--!strict
--[[
	UI/init.lua

	Owns: the UI framework's single entry point -- creates the root Fusion scope, builds
	ClientState, and mounts every Screens surface (HUD, Menus, DeathFeed, DevMenu, BugReport) into
	the local player's PlayerGui. Called once from Main.client.lua, which now also gets back the
	handles client-side integration modules need (ClientState for read access, DeathFeed's handle to
	drive the death-to-respawn overlay, DevMenu's handle to drive the whitelist-gated dev tooling
	panel, BugReport's handle to drive the player-facing report form) -- see
	Client/DevMenu/DevMenuClient.lua and Client/BugReport/BugReportClient.lua. UI/init.lua itself
	still never sends or receives a remote; it only hands each mounted handle to the module that does.

	ShiftLockEngaged: a plain Fusion.Value<boolean> on the root scope, not a Screen's own handle --
	Client/Camera/ShiftLockCamera.lua writes it on every engage/disengage transition and
	UI/Components/ShiftLockCrosshair.lua reads it to draw the crosshair. It used to live on the
	CombatFeedback screen's own handle (Client/UI/Screens/CombatFeedback/init.lua, removed alongside
	the rest of the combat system) purely because that screen happened to be the thing ShiftLockCamera
	was already being handed -- it never had anything to do with combat feedback itself, so it moved
	here instead of needing a new single-purpose screen just to hold one Value.

	Nothing else in the UI tree should create its own root scope or mount directly into
	PlayerGui -- one entry point is what keeps teardown well-defined if this ever needs to unmount
	(e.g. hot-reloading in Studio), per ui-ux-philosophy.md's Framework section.

	THREE SCREENS ARE NOT MOUNTED HERE -- Dev Menu, Move Editor and Live Console are handed out as
	Shared/Lazy.lua thunks instead, and only actually built the first time the module that drives each
	one decides this player has earned it. Between them they built roughly 257 Instances (105/143/9)
	on the synchronous boot path, for every player, the overwhelming majority of whom will never pass
	the admin check -- the largest boot-time and memory cost on the client, spent entirely on panels
	nobody can open. Deferring them was never about the mounting code; it was about how the handles
	are handed out, since Main.client.lua passes each screen's handle to its driving module and there
	is no handle to pass before the screen exists. A Lazy is what closes that: UIHandles still has a
	non-nil, fully-typed entry for each, so no caller learns a new nil case, and the entry is a promise
	rather than a panel.

	The mount itself is UNCHANGED and still happens on this file's own root scope -- a deferred screen
	is built later, not built differently, so the teardown story above still holds for all three.
	Nothing else about the boot order moves: DevMenuClient and MoveEditorClient were ALREADY doing
	their real work on their own thread behind a server authorization round trip (see their own
	headers), so the force point is one line further into work that was already deferred. Live Console
	is the one that binds input unconditionally, and it forces on the first open rather than on boot,
	which is the same open-time-not-boot-time gate LiveConsoleSystem's own Subscribe already keeps.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Lazy = require(ReplicatedStorage.Shared.Lazy)
local Logger = require(ReplicatedStorage.Shared.Logger)

local Children = Fusion.Children

local ClientStateModule = require(script.State.ClientState)
local HUD = require(script.Screens.HUD)
local Menus = require(script.Screens.Menus)
local DeathFeed = require(script.Screens.DeathFeed)
local CombatFeedbackModule = require(script.Screens.CombatFeedback)
local DevMenuModule = require(script.Screens.DevMenu)
local MoveEditorModule = require(script.Screens.MoveEditor)
local LiveConsoleModule = require(script.Screens.LiveConsole)
local BugReportModule = require(script.Screens.BugReport)
local AnnouncementModule = require(script.Screens.Announcement)
local EmoteWheelModule = require(script.Screens.EmoteWheel)
local SettingsModule = require(script.Screens.Settings)
local ShiftLockCrosshair = require(script.Components.ShiftLockCrosshair)

export type UIHandles = {
	ClientState: ClientStateModule.ClientState,
	-- See this file's header -- ShiftLockCamera.lua's own engaged flag, drawn by
	-- UI/Components/ShiftLockCrosshair.lua.
	ShiftLockEngaged: Fusion.Value<boolean>,
	DeathFeed: DeathFeed.DeathFeedHandle,
	-- Damage numbers and the outcome banner, driven by Client/Combat/CombatFeedbackClient.lua from
	-- the damage layer's Combat_Feedback event.
	CombatFeedback: CombatFeedbackModule.CombatFeedbackHandle,
	-- The three admin-gated screens, deferred -- see this file's header. Get() mounts on first call
	-- and returns the same handle forever after; IsResolved() asks whether it has been mounted
	-- WITHOUT mounting it, which is what lets a stray server push for an unopened panel be dropped.
	DevMenu: Lazy.Lazy<DevMenuModule.DevMenuHandle>,
	Menus: Menus.MenusHandle,
	MoveEditor: Lazy.Lazy<MoveEditorModule.MoveEditorHandle>,
	LiveConsole: Lazy.Lazy<LiveConsoleModule.LiveConsoleHandle>,
	BugReport: BugReportModule.BugReportHandle,
	Announcement: AnnouncementModule.AnnouncementHandle,
	EmoteWheel: EmoteWheelModule.EmoteWheelHandle,
	Settings: SettingsModule.SettingsHandle,
	-- The root Fusion scope Mount() created, exposed so a future re-Mount() (Studio hot-reload) has
	-- something to call :doCleanup() on before mounting a fresh tree -- see this file's header on
	-- why nothing else should ever create its own root scope. Previously created and discarded
	-- locally, which made teardown impossible despite the header's own claim that one entry point
	-- "keeps teardown well-defined."
	Scope: Fusion.Scope<typeof(Fusion)>,
}

local logger = Logger.scope("UI")

local UI = {}

function UI.Mount(): UIHandles
	local player = Players.LocalPlayer
	local playerGui = player.PlayerGui

	local scope = Fusion.scoped(Fusion)
	logger:debug("Root Fusion scope created")

	local clientState = ClientStateModule.new(scope)
	logger:debug("ClientState created")

	logger:debug("ClientState bootstrap start")
	ClientStateModule.Bootstrap(clientState)
	logger:debug("ClientState bootstrap end")

	HUD.Mount(scope, playerGui, clientState)
	logger:debug("HUD mounted")

	-- clientState is passed through so CharacterTab/EmotesTab can read the HUD-wide fields they don't
	-- duplicate (see Menus/init.lua's header on that split). The handle is returned below --
	-- Client/CharacterMenu/CharacterMenuClient.lua is what actually drives it (the M keybind, the
	-- sheet/catalogue fetches, Unlock/Equip), the same "screen exposes state, client module drives
	-- it" split every other Screens/ handle here already follows.
	local menus = Menus.Mount(scope, playerGui, clientState)
	logger:debug("Menus mounted")

	local deathFeed = DeathFeed.Mount(scope, playerGui)
	logger:debug("DeathFeed mounted")

	local combatFeedback = CombatFeedbackModule.Mount(scope, playerGui)
	logger:debug("CombatFeedback mounted")

	-- No longer part of a Screen's own handle -- see this file's header. A bare ScreenGui here (not
	-- a whole Screens/ module) since ShiftLockCrosshair is the only content it will ever hold.
	local shiftLockEngaged: Fusion.Value<boolean> = scope:Value(false)
	scope:New "ScreenGui" {
		Name = "ShiftLockCrosshair",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = playerGui,

		[Children] = ShiftLockCrosshair(scope, { Engaged = shiftLockEngaged }),
	}
	logger:debug("ShiftLockCrosshair mounted")

	-- DEFERRED, not mounted -- see this file's header. Each of these three closures runs at most once,
	-- the first time its own driving module forces it, and logs then rather than now so the boot log
	-- keeps saying something true about what this client has actually built.
	local devMenu = Lazy.new("DevMenu", function()
		local handle = DevMenuModule.Mount(scope, playerGui)
		logger:debug("DevMenu mounted (deferred until authorized)")
		return handle
	end)

	local moveEditor = Lazy.new("MoveEditor", function()
		local handle = MoveEditorModule.Mount(scope, playerGui)
		logger:debug("MoveEditor mounted (deferred until authorized)")
		return handle
	end)

	local liveConsole = Lazy.new("LiveConsole", function()
		local handle = LiveConsoleModule.Mount(scope, playerGui)
		logger:debug("LiveConsole mounted (deferred until first open)")
		return handle
	end)

	local bugReport = BugReportModule.Mount(scope, playerGui)
	logger:debug("BugReport mounted")

	local announcement = AnnouncementModule.Mount(scope, playerGui)
	logger:debug("Announcement mounted")

	local emoteWheel = EmoteWheelModule.Mount(scope, playerGui, clientState)
	logger:debug("EmoteWheel mounted")

	local settings = SettingsModule.Mount(scope, playerGui)
	logger:debug("Settings mounted")

	return {
		ClientState = clientState,
		ShiftLockEngaged = shiftLockEngaged,
		DeathFeed = deathFeed,
		CombatFeedback = combatFeedback,
		DevMenu = devMenu,
		Menus = menus,
		MoveEditor = moveEditor,
		LiveConsole = liveConsole,
		BugReport = bugReport,
		Announcement = announcement,
		EmoteWheel = emoteWheel,
		Settings = settings,
		Scope = scope,
	}
end

return UI
