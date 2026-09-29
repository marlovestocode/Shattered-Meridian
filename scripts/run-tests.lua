-- Loose script (not part of the Rojo-synced tree) executed by `run-in-roblox --script` at
-- plugin-level security against a place built from test.project.json. Requires TestEZ from
-- DevPackages, runs every spec under ServerScriptService.Tests, and error()s on any failure so
-- run-in-roblox's process exit code reflects pass/fail for CI.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

-- Load-check: nothing in this test place actually calls require() on DevMenuSystem.lua (no spec
-- needs its behavior, only the pure logic extracted into Server/Combat/), so a broken require()
-- path inside it would otherwise go unnoticed until someone opens Studio. Requiring (but never
-- calling .Init() -- that needs a real player/DataStore environment this headless place doesn't
-- have) is enough to catch a syntax error or bad require path, which is the class of mistake a
-- structural refactor risks introducing. (PlayerDeathSystem.lua used to be listed here too; it has
-- had a dedicated spec since kill attribution landed -- Tests/Progression/PlayerDeathSystem.spec.lua.)
local modulesToLoad = {
	ServerScriptService.Server.Systems.DevMenuSystem,
	ServerScriptService.Server.Systems.BugReportSystem,
	ServerScriptService.Server.Systems.AdminActionSystem,
	ServerScriptService.Server.Systems.ModerationSystem,
	ServerScriptService.Server.Systems.PlayerDataSystem,
	ServerScriptService.Server.Systems.CharacterCreationSystem,
	ServerScriptService.Server.Systems.RespawnSystem,
	-- EmoteSystem.lua has no dedicated spec that requires it (only its pure/no-profile sibling
	-- EmoteUnlockService.lua does) -- same "nothing else would catch a broken require path" gap this
	-- list already exists to close for CombatSystem/DevMenuSystem/TrainingBotSystem above.
	ServerScriptService.Server.Systems.EmoteSystem,
	-- SettingsSystem.lua has no dedicated spec either -- same reasoning as EmoteSystem above; its own
	-- pure logic lives entirely in PlayerDataSystem's EncodeSettings/DecodeSettings, already covered.
	ServerScriptService.Server.Systems.SettingsSystem,
	-- MoveEditorSystem.lua's pure pieces are specced directly (Tests/MoveEditor/MoveEditorSystem.spec.lua
	-- for its entry notes, MoveRecordCodec.spec.lua for its records); its remotes are admin-gated and
	-- DataStore-backed, so this entry stays as the same cheap require insurance EmoteSystem's is.
	ServerScriptService.Server.Systems.MoveEditorSystem,
	-- ParkourSystem.lua's pure logic lives in Shared/Parkour/ParkourValidation.lua (specced directly),
	-- so this entry exists for the same reason SettingsSystem's does: nothing else in the suite would
	-- catch a broken require path or syntax error in the module that owns this feature's two remotes,
	-- its trust boundary and the Attributes the combat WalkSpeed resolver reads.
	ServerScriptService.Server.Systems.ParkourSystem,
	-- RunSystem.lua owns Humanoid.WalkSpeed and the run's stage ladder. Its pure arithmetic lives in
	-- Shared/Run/RunLadder.lua and is covered directly by Tests/Run/RunLadder.spec.lua, so nothing else
	-- in this place ever require()s the System itself -- the same gap every other entry in this list
	-- exists to close. A broken require path in the module that writes WalkSpeed would otherwise
	-- surface as "nobody can move" in a playtest rather than as a failing build.
	ServerScriptService.Server.Systems.RunSystem,
	-- LiveConsoleSystem.lua (the Live Admin Console's server half, F5) has no dedicated spec --
	-- same reasoning as DevMenuSystem/MoveEditorSystem above: its whole surface is auth-gated
	-- remote handling (Subscribe/Unsubscribe/the Stream flush loop), not pure logic with anything
	-- to extract, so nothing else in this suite would ever require() it and catch a broken require
	-- path. Its one pure dependency, Shared/Logger.lua's capture buffer, IS specced directly
	-- (Tests/Shared/Logger.spec.lua).
	ServerScriptService.Server.Systems.LiveConsoleSystem,
	-- BlimpSystem.lua owns the mount/interaction layer (Touched-driven contact tracking as of the
	-- player-launch-exploit fix, the fuel prompts, the drive tick) and pulls in two new requires that
	-- named-file specs never touch (Players and Server/Blimp/BlimpSafety) -- BlimpDrive.spec.lua/
	-- BlimpFuel.spec.lua/BlimpTagging.spec.lua/BlimpSafety.spec.lua all require the pure modules this
	-- System calls into directly, never the System itself, so nothing else in this suite would catch a
	-- broken require path or a bad service name here. Same gap every other entry in this list exists to
	-- close, for the module that would otherwise surface a typo as "the blimp doesn't do anything" in a
	-- playtest instead of a failing build.
	ServerScriptService.Server.Systems.BlimpSystem,
	-- VehicleManager.lua owns the registry scan, the spawn/despawn path and five admin-gated remotes.
	-- Its pure pieces ARE specced directly (Tests/Vehicle/VehicleCatalog.spec.lua and
	-- VehiclePlacement.spec.lua both require the modules it calls into, never the System itself), so
	-- this is the same gap every other entry in this list closes -- and a broken require path here
	-- would surface as "the Vehicles tab is empty" in a playtest rather than as a failing build.
	ServerScriptService.Server.Systems.VehicleManager,
}

-- CLIENT-side load-checks, same reasoning as the server list above and added for the same class of
-- gap: nothing in this place ever require()d the client's UI tree, so a broken require path, a syntax
-- error, or a signature change in the largest UI surface on the client (UI/init.lua and the
-- admin-gated screen drivers Client/DevTools/init.lua hands deferred handles to) surfaced only when
-- someone opened Studio.
-- Requiring is enough and is all that is safe: Mount()/Start() need a real LocalPlayer and PlayerGui
-- that this headless server place does not have, and every one of these modules is written so its
-- top-level body touches neither.
local clientModulesToLoad = {
	StarterPlayer.StarterPlayerScripts.Client.UI,
	-- The whole dev-tooling subtree behind one entry. Requiring Client.DevTools pulls in all five
	-- driver modules AND Screens/DevTools, which is exactly the coverage the five separate entries
	-- here used to give -- including the one added after KitEditorClient was found with NO inbound
	-- require anywhere (nothing started it, so its keybind never bound and the Kit Editor -- the only
	-- thing that authors Race Trait and Bloodline content -- was unreachable, leaving BloodlineManager's
	-- registry permanently empty). Reachability itself is still the boot wiring's job, not this list's.
	--
	-- This list requires by PATH, so it is also the check that the bundle exists at all: test.project.json
	-- ships it, live.project.json deliberately does not, and this place is built from the former.
	StarterPlayer.StarterPlayerScripts.Client.DevTools,
	-- The sole writer of Client/Combat/HotbarBindings.lua now that the Move Editor stopped being a
	-- second one -- see that module's own header. A broken require here would silently leave every
	-- player's hotbar empty.
	StarterPlayer.StarterPlayerScripts.Client.CharacterMenu.CharacterMenuClient,
	-- The camera/movement/input modules whose character binding moved onto
	-- Shared/PlayerLifecycle.lua. Nothing in this place drives a real character, so their BEHAVIOUR
	-- still needs a playtest -- but a broken require path or a bad call shape in the shared binder
	-- would previously have gone unnoticed here, and these entries close that.
	StarterPlayer.StarterPlayerScripts.Client.Camera.ShiftLockCamera,
	StarterPlayer.StarterPlayerScripts.Client.Camera.FlightCamera,
	StarterPlayer.StarterPlayerScripts.Client.Flight.FlightController,
	StarterPlayer.StarterPlayerScripts.Client.Emotes.EmoteController,
	StarterPlayer.StarterPlayerScripts.Client.FX.CameraOffsetComposer,
	StarterPlayer.StarterPlayerScripts.Client.Combat.AttackInputClient,
	StarterPlayer.StarterPlayerScripts.Client.Combat.GrabInputClient,
	StarterPlayer.StarterPlayerScripts.Client.Combat.CombatFeedbackClient,
	StarterPlayer.StarterPlayerScripts.Client.Defense.DefenseClient,
	StarterPlayer.StarterPlayerScripts.Client.Movement.RunController,
	StarterPlayer.StarterPlayerScripts.Client.Parkour.ParkourController,
	-- EmoteController was already on this list; the module that DRIVES it was not, which left the half
	-- a player actually touches (the wheel's input, its selection, its confirm) with no inbound
	-- require anywhere in this place at all.
	--
	-- BE CLEAR ABOUT WHAT THIS DOES AND DOES NOT CATCH, because this entry was added on the back of a
	-- bug it would NOT have caught: an undefined global inside openWheel, which loads fine and throws
	-- only when a player presses the key. `selene src/` is what catches that class and did; this list
	-- catches the require-path/syntax class, exactly like every other entry above. Both gates, not one.
	StarterPlayer.StarterPlayerScripts.Client.Emotes.EmoteWheelClient,
	-- The two blimp client modules, for the same reason and the same gap: nothing in this place
	-- requires either, so their require paths and top-level bodies were only ever exercised by opening
	-- Studio. BlimpController is the largest client module in that feature; FurnacePromptClient owns
	-- the furnace's custom prompt, whose whole job is to be the only thing drawn at that station now
	-- that the stock ProximityPrompt UI is turned off there (Style = Custom, set server-side) -- a
	-- broken require in it would leave a furnace with no visible prompt at all.
	StarterPlayer.StarterPlayerScripts.Client.Blimp.BlimpController,
	StarterPlayer.StarterPlayerScripts.Client.Blimp.FurnacePromptClient,
}
for _, moduleScript in ipairs(clientModulesToLoad) do
	table.insert(modulesToLoad, moduleScript)
end
for _, moduleScript in ipairs(modulesToLoad) do
	local ok, errorMessage = pcall(require, moduleScript)
	if not ok then
		error(string.format("Failed to require %s: %s", moduleScript:GetFullName(), tostring(errorMessage)))
	end
end
print(string.format("Load-check: %d module(s) required successfully", #modulesToLoad))

-- WaitForChild, not direct indexing: run-in-roblox has been observed (twice, intermittently)
-- erroring here with "DevPackages is not a valid member of ReplicatedStorage" even though
-- test.project.json's tree unconditionally includes it and the load-check above already proves
-- the DataModel is otherwise populated -- a load-order race in how run-in-roblox's own plugin
-- opens/executes against the built place, not a missing file. A bounded wait turns that race into
-- a real (if slower) success instead of a flaky hard failure; the timeout still fails loudly if
-- DevPackages genuinely never shows up.
local devPackages = ReplicatedStorage:WaitForChild("DevPackages", 10)
if not devPackages then
	error("ReplicatedStorage.DevPackages did not appear within 10 seconds")
end
local TestEZ = require(devPackages:WaitForChild("TestEZ"))

local results = TestEZ.TestBootstrap:run({ ServerScriptService.Tests }, TestEZ.Reporters.TextReporter)

if results.failureCount > 0 then
	error(string.format("TestEZ: %d failure(s), %d success(es)", results.failureCount, results.successCount))
end

print(string.format("TestEZ: all %d test(s) passed", results.successCount))
