-- Loose script (not part of the Rojo-synced tree) executed by `run-in-roblox --script` at
-- plugin-level security against a place built from test.project.json. Requires TestEZ from
-- DevPackages, runs every spec under ServerScriptService.Tests, and error()s on any failure so
-- run-in-roblox's process exit code reflects pass/fail for CI.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- Load-check: nothing in this test place actually calls require() on CombatSystem.lua/
-- DevMenuSystem.lua/TrainingBotSystem.lua (no spec needs their behavior, only the pure logic
-- extracted into Server/Combat/), so a broken require() path inside them would otherwise go
-- unnoticed until someone opens Studio. Requiring (but never calling .Init() -- that needs a real
-- player/DataStore environment this headless place doesn't have) is enough to catch a syntax error
-- or bad require path, which is the class of mistake a structural refactor risks introducing.
local modulesToLoad = {
	ServerScriptService.Server.Systems.CombatSystem,
	ServerScriptService.Server.Systems.DevMenuSystem,
	ServerScriptService.Server.Systems.TrainingBotSystem,
	ServerScriptService.Server.Systems.BugReportSystem,
	ServerScriptService.Server.Systems.AdminActionSystem,
	ServerScriptService.Server.Systems.ModerationSystem,
	ServerScriptService.Server.Systems.PlayerDataSystem,
	ServerScriptService.Server.Systems.CharacterCreationSystem,
	ServerScriptService.Server.Systems.RespawnSystem,
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
