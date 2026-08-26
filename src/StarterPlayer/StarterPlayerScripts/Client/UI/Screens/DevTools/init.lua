--!strict
--[[
	UI/Screens/DevTools/init.lua

	Owns: the five admin-gated / Studio-only screens as ONE deferred bundle, and being the single
	require UI/init.lua makes to reach any of them.

	Why a bundle rather than five entries in UI/init.lua, which is where these lived: these five
	screens plus their five driving modules under Client/DevTools/ are roughly 18.5k lines of Luau
	that every player's client used to require, parse and closure-build at boot for panels only a
	whitelisted admin can ever open. Shared/Lazy.lua already deferred the MOUNT (and still does --
	every entry below is still a thunk, unchanged); what it cannot defer is the require graph
	itself, because a `require` is what produces the Mount function the thunk closes over. The only
	thing that removes that cost is not shipping the modules, and the only thing that lets a build
	config not ship them is having them behind one path. That path is this file plus
	Client/DevTools/init.lua -- see live.project.json, which omits exactly those two subtrees.

	So this file is deliberately thin: it mounts nothing itself and adds no behaviour. Each entry
	below is the identical Lazy.new(name, MountFn) UI/init.lua used to hold, moved verbatim so the
	deferral story (built on first Get(), logged then rather than at boot) reads the same as before.

	The consequence to know about, stated here rather than discovered: a place published from
	live.project.json has NO dev tooling for anybody, admins included -- F5's Live Console goes with
	the rest, even though Server/Systems/LiveConsoleSystem.lua's own header is explicit that it is
	built to keep working in a live server. That is the trade this split exists to make available,
	not one it makes for you: publish from default.project.json to keep admin tooling in a live
	place, from live.project.json to strip it. The server half is NOT symmetrical and must not be
	omitted either way -- MoveEditorSystem.Init/KitEditorSystem.Init are what hydrate the authored
	move, race-trait and bloodline registries from DataStore at boot, so a server without them
	boots with empty content registries. See Client/DevTools/init.lua's header.

	Does not own: authorization (each server System re-checks the whitelist on every request,
	regardless of whether the panel exists), or when a thunk is forced -- that stays with each
	screen's own driving module under Client/DevTools/.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Lazy = require(ReplicatedStorage.Shared.Lazy)
local Logger = require(ReplicatedStorage.Shared.Logger)

local DevMenuModule = require(script.DevMenu)
local MoveEditorModule = require(script.MoveEditor)
local KitEditorModule = require(script.KitEditor)
local LiveConsoleModule = require(script.LiveConsole)
local StorybookModule = require(script.Storybook)

type Scope = Fusion.Scope<typeof(Fusion)>

local DevToolScreens = {}

local logger = Logger.scope("DevToolScreens")

-- The shape UI/init.lua hands back on uiHandles.DevTools, and the shape
-- Client/DevTools/init.lua's own Start() consumes. Every field is a promise, never a panel --
-- Get() mounts on first call and returns the same handle forever after; IsResolved() asks whether
-- it has been mounted WITHOUT mounting it, which is what lets a stray server push for an unopened
-- panel be dropped.
export type DevToolScreens = {
	DevMenu: Lazy.Lazy<DevMenuModule.DevMenuHandle>,
	MoveEditor: Lazy.Lazy<MoveEditorModule.MoveEditorHandle>,
	-- Authors Race Trait and Bloodline content (Server/Managers/RaceManager.lua,
	-- Server/Managers/BloodlineManager.lua) -- the one screen here whose absence is felt by
	-- gameplay rather than only by tooling, since nothing else can populate those registries.
	KitEditor: Lazy.Lazy<KitEditorModule.KitEditorHandle>,
	LiveConsole: Lazy.Lazy<LiveConsoleModule.LiveConsoleHandle>,
	Storybook: Lazy.Lazy<StorybookModule.StorybookHandle>,
}

-- Called once from UI/init.lua, on ITS root scope -- this file never creates a scope of its own,
-- so the single-entry-point teardown contract in that file's header still covers every panel here.
function DevToolScreens.Mount(scope: Scope, playerGui: PlayerGui): DevToolScreens
	return {
		DevMenu = Lazy.new("DevMenu", function()
			local handle = DevMenuModule.Mount(scope, playerGui)
			logger:debug("DevMenu mounted (deferred until authorized)")
			return handle
		end),

		MoveEditor = Lazy.new("MoveEditor", function()
			local handle = MoveEditorModule.Mount(scope, playerGui)
			logger:debug("MoveEditor mounted (deferred until authorized)")
			return handle
		end),

		KitEditor = Lazy.new("KitEditor", function()
			local handle = KitEditorModule.Mount(scope, playerGui)
			logger:debug("KitEditor mounted (deferred until authorized)")
			return handle
		end),

		LiveConsole = Lazy.new("LiveConsole", function()
			local handle = LiveConsoleModule.Mount(scope, playerGui)
			logger:debug("LiveConsole mounted (deferred until first open)")
			return handle
		end),

		Storybook = Lazy.new("Storybook", function()
			local handle = StorybookModule.Mount(scope, playerGui)
			logger:debug("Storybook mounted (deferred until first open, Studio only)")
			return handle
		end),
	}
end

return DevToolScreens
