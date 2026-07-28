--!strict
--[[
	UI/init.lua

	Owns: the UI framework's single entry point -- creates the root Fusion scope, builds
	ClientState, and mounts every Screens surface (HUD, Menus, DeathFeed, CombatFeedback, DevMenu,
	BugReport) into the local player's PlayerGui. Called once from Main.client.lua, which now also
	gets back the handles client-side integration modules need (ClientState for read access,
	CombatFeedback's handle to drive lock-on/damage-number/posture-break presentation, DevMenu's
	handle to drive the whitelist-gated dev tooling panel, BugReport's handle to drive the
	player-facing report form) -- see Client/Combat/CombatClient.lua, Client/DevMenu/DevMenuClient.lua,
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
local BugReportModule = require(script.Screens.BugReport)
local AnnouncementModule = require(script.Screens.Announcement)

export type UIHandles = {
	ClientState: ClientStateModule.ClientState,
	CombatFeedback: CombatFeedbackModule.CombatFeedbackHandle,
	DevMenu: DevMenuModule.DevMenuHandle,
	BugReport: BugReportModule.BugReportHandle,
	Announcement: AnnouncementModule.AnnouncementHandle,
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

	-- Handle intentionally discarded -- see Menus/init.lua's header for why this screen has no
	-- keybind/driver yet (nothing in it has real content to show until at least one Menus panel is
	-- backed by a real System).
	Menus.Mount(scope, playerGui)
	logger:debug("Menus mounted")

	DeathFeed.Mount(scope, playerGui)
	logger:debug("DeathFeed mounted")

	local combatFeedback = CombatFeedbackModule.Mount(scope, playerGui)
	logger:debug("CombatFeedback mounted")

	local devMenu = DevMenuModule.Mount(scope, playerGui)
	logger:debug("DevMenu mounted")

	local bugReport = BugReportModule.Mount(scope, playerGui)
	logger:debug("BugReport mounted")

	local announcement = AnnouncementModule.Mount(scope, playerGui)
	logger:debug("Announcement mounted")

	return {
		ClientState = clientState,
		CombatFeedback = combatFeedback,
		DevMenu = devMenu,
		BugReport = bugReport,
		Announcement = announcement,
		Scope = scope,
	}
end

return UI
