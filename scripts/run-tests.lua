-- Loose script (not part of the Rojo-synced tree) executed by `run-in-roblox --script` at
-- plugin-level security against a place built from test.project.json. Requires TestEZ from
-- DevPackages, runs every spec under ServerScriptService.Tests, and error()s on any failure so
-- run-in-roblox's process exit code reflects pass/fail for CI.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- Load-check: nothing in this test place actually calls require() on DevMenuSystem.lua (no spec
-- needs its behavior, only the pure logic extracted into Server/Combat/), so a broken require()
-- path inside it would otherwise go unnoticed until someone opens Studio. Requiring (but never
-- calling .Init() -- that needs a real player/DataStore environment this headless place doesn't
-- have) is enough to catch a syntax error or bad require path, which is the class of mistake a
-- structural refactor risks introducing. CombatSystem.lua/TrainingBotSystem.lua were removed
-- alongside the rest of the combat system; PlayerDeathSystem.lua (their replacement for player-death
-- detection -- see that module's own header) has no dedicated spec either, so it earns the same
-- load-check entry for the same reason.
local modulesToLoad = {
	ServerScriptService.Server.Systems.DevMenuSystem,
	ServerScriptService.Server.Systems.PlayerDeathSystem,
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
	-- MoveEditorSystem.lua has no dedicated spec (its pure logic lives in MoveRegistryManager.Validate
	-- and DefaultMoveRegistry, both already covered) and was not even MOUNTED in test.project.json
	-- until now -- so nothing anywhere caught a broken require path in the one module that owns the
	-- Move Editor's auth gate, DataStore encode/decode and every one of its twelve remotes. Adding it
	-- here is the same cheap insurance EmoteSystem/SettingsSystem above already take. A real spec for
	-- its encode/decode round trip still wants writing; that needs its file-local helpers exported
	-- first, the way BugReportSystem.ValidateCategory already is.
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
}
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
