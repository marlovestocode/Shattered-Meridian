--!strict
--[[
	Client/DevTools/init.lua

	Owns: starting the dev-tool client modules, and being the single require Main.client.lua
	makes to reach any of them.

	The pair of this and UI/Screens/DevTools/init.lua is the whole of the dev-tooling build seam --
	see that file's header for why the seam exists (Shared/Lazy.lua already defers the mount; only
	not shipping the modules removes the require-graph cost) and for the trade a live.project.json
	build makes. Everything below is the same call, in the same order, Main.client.lua used to make
	inline; nothing about when each module does its real work has changed, because each already
	returned immediately and did that work behind its own server authorization round trip.

	THE SERVER HALF IS NOT SYMMETRICAL AND MUST NOT BE OMITTED FROM A LIVE BUILD. It is tempting to
	read the four admin-gated Systems under Server/Systems/ as the mirror of this folder and strip
	them the same way. They are not: MoveEditorSystem.Init runs loadPersistedMoves/
	loadDefaultMoveOverrides, and KitEditorSystem.Init runs the equivalent for Race Traits and
	Bloodlines -- those are the ONLY things that hydrate MoveRegistryManager, RaceManager and
	BloodlineManager from DataStore at boot. A server booted without them has empty content
	registries and degrades quietly (no error, no missing move -- just a move that was never there),
	which is exactly the failure mode this codebase's "trace the runtime call path, don't trust the
	header comment" rule exists to catch. They also cost a player nothing: server modules never
	replicate. So they stay in Server/Systems/ where the boot order is legible, and this folder has
	no server counterpart on purpose.

	Client/Flight/ is the other half of the same correction, in the other direction:
	FlightController/FlightPhysics used to live under Client/DevTools/DevMenu/ and are NOT dev tooling -- an
	admin can grant flight to a NON-admin, whose own client must drive the movement, so they run
	unconditionally for every player (see FlightController.lua's own header). They moved out to
	Client/Flight/ rather than into this folder, and Main.client.lua still starts them directly.

	Does not own: authorization (every server System re-checks the whitelist per request), or the
	panels themselves (UI/Screens/DevTools/).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Logger = require(ReplicatedStorage.Shared.Logger)

local DevToolScreens = require(script.Parent.UI.Screens.DevTools)
local Chrome = require(script.Parent.UI.Shell.Chrome)

local DevMenuClient = require(script.DevMenu.DevMenuClient)
local MoveEditorClient = require(script.MoveEditor.MoveEditorClient)
local KitEditorClient = require(script.KitEditor.KitEditorClient)
local LiveConsoleClient = require(script.LiveConsole.LiveConsoleClient)
local StorybookClient = require(script.Storybook.StorybookClient)
local PingProbe = require(script.PingProbe)

local DevTools = {}

local logger = Logger.scope("DevTools")

-- Called once from Main.client.lua, after UI.Mount(). Order below is Main.client.lua's own former
-- order and is documented rather than load-bearing: each of these five binds its key and then waits
-- on a server answer, and none reads state another one writes.
function DevTools.Start(screens: DevToolScreens.DevToolScreens, chrome: Chrome.ChromeHandle): ()
	logger:debug("DevMenuClient start")
	DevMenuClient.Start(screens.DevMenu, chrome)

	logger:debug("MoveEditorClient start")
	MoveEditorClient.Start(screens.MoveEditor, chrome)

	-- Had NO CALLER AT ALL until Main.client.lua gained one: nothing required
	-- Client/DevTools/KitEditor/KitEditorClient.lua, so its OpenKitEditor keybind never bound and the Kit
	-- Editor was unreachable -- which mattered beyond the panel, since it is the only thing that
	-- authors Race Trait and Bloodline content.
	logger:debug("KitEditorClient start")
	KitEditorClient.Start(screens.KitEditor, chrome)

	-- Unlike the two above, this one binds its input unconditionally rather than behind a
	-- boot-time authorization answer -- the real gate is server-side, on Subscribe, fired only once
	-- the panel actually opens. See LiveConsoleClient.lua's own header.
	logger:debug("LiveConsoleClient start")
	LiveConsoleClient.Start(screens.LiveConsole, chrome)

	-- Usually does NOTHING: StorybookClient.Start returns immediately outside Studio, so even in a
	-- build that ships this folder no key is bound and the gallery is never built on a live client.
	-- The gate stays with the module that owns the reason for it rather than becoming an IsStudio
	-- check here.
	logger:debug("StorybookClient start")
	StorybookClient.Start(screens.Storybook, chrome)
	-- Studio-only and passive, like the Storybook: logs what GetNetworkPing means (Shared/PingReading).
	logger:debug("PingProbe start")
	PingProbe.Start()

	logger:debug("DevTools start end")
end

return DevTools
