--!strict
--[[
	FusionTuning.lua

	Owns: one switch on the Fusion package -- turning off its lifetime checker, which is a development aid
	and was costing a real amount of every frame and every state change.

	WHAT IT COSTS (2026-09-30). Every `use()` a Computed makes runs Fusion's checkLifetime.bOutlivesA, which
	asks whichLivesLonger(scopeA, a, scopeB, b) to work out whether the used object outlives the thing using
	it, purely so it can WARN about a scoping mistake. That answer is found by walking memory: a backward
	linear scan of the scope array when both live in one scope, and otherwise a breadth-first walk across
	both scopes and every scope nested inside them. This UI's scopes hold every Computed, Spring and
	Instance of every screen, so a single `use(clientState.Qi)` from another scope is a walk over thousands
	of entries. The measured result: one Qi push into ClientState cost ~9ms, and one character-sheet push
	~55ms, for what is about forty text bindings -- roughly a millisecond a binding, every time any state
	changes. It is also why the cost only ever grows as a session goes on (scopes are append-only).

	WHY THIS SWITCH AND NOT A BETTER CHECK. Fusion already has a mode for exactly this: whichLivesLonger
	returns "unsure" immediately when External.isTimeCritical() is true, and doCleanup pools a cleaned scope
	instead of poisoning it. Nothing in the package ever sets that flag outside its own scheduler (it is a
	private local with a getter and no setter), and Packages/ is wally-installed and gitignored, so the
	package cannot be edited. But every module reads the flag through the shared External table at CALL time,
	so replacing that one getter is enough -- and is undone by DebugConstants.FusionLifetimeChecks = true.

	WHAT YOU GIVE UP: the warnings ("the use()-d X may outlive the Y") and the use-after-cleanup poisoning of
	a destroyed scope. Both catch authoring mistakes, not runtime failures, and neither fires in a correct
	tree. Flip the constant on to hunt one.

	FAILS OPEN. If the package layout is not what this expects (a version bump moved External), it logs one
	warning and leaves Fusion exactly as it was -- slower, never broken.

	Does not own: Fusion, any scope, or any binding.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)

local logger = Logger.scope("FusionTuning")

local FusionTuning = {}

local applied = false

-- Finds the installed Fusion's External module without hard-coding its version: Packages/_Index holds one
-- folder per package named "<scope>_<name>@<version>".
local function findExternal(): ModuleScript?
	local packages = ReplicatedStorage:FindFirstChild("Packages")
	local index = if packages then packages:FindFirstChild("_Index") else nil
	if index == nil then
		return nil
	end
	for _, entry in index:GetChildren() do
		if string.sub(entry.Name, 1, 14) == "elttob_fusion@" then
			local fusion = entry:FindFirstChild("fusion")
			local external = if fusion then fusion:FindFirstChild("External") else nil
			if external and external:IsA("ModuleScript") then
				return external
			end
		end
	end
	return nil
end

-- Applies the tuning, once. Returns whether Fusion's lifetime checker is now off.
function FusionTuning.Apply(): boolean
	if applied then
		return true
	end
	if Constants.Debug.FusionLifetimeChecks then
		return false
	end
	local module = findExternal()
	if module == nil then
		logger:warn("Fusion's External module was not found; lifetime checks stay on")
		return false
	end
	local ok, external = pcall(require, module)
	if not ok or typeof(external) ~= "table" or typeof(external.isTimeCritical) ~= "function" then
		logger:warn("Fusion's External module has an unexpected shape; lifetime checks stay on")
		return false
	end
	external.isTimeCritical = function(): boolean
		return true
	end
	applied = true
	logger:info("Fusion lifetime checks off")
	return true
end

return FusionTuning
