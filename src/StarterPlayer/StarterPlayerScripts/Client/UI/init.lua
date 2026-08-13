--!strict
--[[
	UI/init.lua

	Owns: the UI framework's single entry point -- creates the root Fusion scope, builds
	ClientState, and mounts every Screens surface (HUD, Menus, DeathFeed, CombatFeedback, DevMenu,
	BugReport) into the local player's PlayerGui. Called once from Main.client.lua, which now also
	gets back the handles client-side integration modules need (ClientState for read access,
	CombatFeedback's handle to drive lock-on/damage-number/posture-break presentation, DeathFeed's
	handle to drive the death-to-respawn overlay, DevMenu's handle to drive the whitelist-gated dev
	tooling panel, BugReport's handle to drive the player-facing report form) -- see
	Client/Combat/CombatClient.lua (both CombatFeedback and DeathFeed), Client/DevMenu/DevMenuClient.lua,
	and Client/BugReport/BugReportClient.lua. UI/init.lua itself still never sends or receives a
	remote; it only hands each mounted handle to the module that does.

	Nothing else in the UI tree should create its own root scope or mount directly into
	PlayerGui -- one entry point is what keeps teardown well-defined if this ever needs to unmount
	(e.g. hot-reloading in Studio), per ui-ux-philosophy.md's Framework section.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Logger = require(ReplicatedStorage.Shared.Logger)

local ClientStateModule = require(script.State.ClientState)
local HUD = require(script.Screens.HUD)
local Menus = require(script.Screens.Menus)
local DeathFeed = require(script.Screens.DeathFeed)
local CombatFeedbackModule = require(script.Screens.CombatFeedback)
local DevMenuModule = require(script.Screens.DevMenu)
local MoveEditorModule = require(script.Screens.MoveEditor)
local BugReportModule = require(script.Screens.BugReport)
local AnnouncementModule = require(script.Screens.Announcement)
local EmoteWheelModule = require(script.Screens.EmoteWheel)
local SettingsModule = require(script.Screens.Settings)

export type UIHandles = {
	ClientState: ClientStateModule.ClientState,
	CombatFeedback: CombatFeedbackModule.CombatFeedbackHandle,
	DeathFeed: DeathFeed.DeathFeedHandle,
	DevMenu: DevMenuModule.DevMenuHandle,
	MoveEditor: MoveEditorModule.MoveEditorHandle,
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

	-- Handle intentionally discarded: Menus owns its own open/closed state and drives it from its own
	-- M keybind, so nothing out here needs the handle. (This comment previously said the screen had
	-- "no keybind/driver yet" and nothing in it had real content -- both stopped being true when
	-- BountyMenu was wired to live BountySystem data; see Menus/init.lua's header for what IS still
	-- outstanding there, namely routing that key through Types.KeybindAction so it's rebindable.)
	-- clientState is passed through so CharacterTab/EmotesTab can read the HUD-wide fields they don't
	-- duplicate (see Menus/init.lua's header on that split).
	Menus.Mount(scope, playerGui, clientState)
	logger:debug("Menus mounted")

	local deathFeed = DeathFeed.Mount(scope, playerGui)
	logger:debug("DeathFeed mounted")

	local combatFeedback = CombatFeedbackModule.Mount(scope, playerGui)
	logger:debug("CombatFeedback mounted")

	local devMenu = DevMenuModule.Mount(scope, playerGui)
	logger:debug("DevMenu mounted")

	local moveEditor = MoveEditorModule.Mount(scope, playerGui)
	logger:debug("MoveEditor mounted")

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
		CombatFeedback = combatFeedback,
		DeathFeed = deathFeed,
		DevMenu = devMenu,
		MoveEditor = moveEditor,
		BugReport = bugReport,
		Announcement = announcement,
		EmoteWheel = emoteWheel,
		Settings = settings,
		Scope = scope,
	}
end

return UI
