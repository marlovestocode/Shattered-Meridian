--!strict
--[[
	AuthoredMoveLibrary.lua

	Owns: the moves that ship IN THE GAME'S SOURCE -- the ModuleScripts under Server/Combat/AuthoredMoves/
	that the Move Editor's Studio-only "Write to source" produces -- loaded into the live registries at
	boot, and the record of which moves came from there.

	  AuthoredMoves/Moves/<id>.lua      a custom move's whole record -> MoveRegistryManager
	  AuthoredMoves/Overrides/<id>.lua  a Default move's retune       -> DefaultMoveRegistry.SetShipped

	WHY IT EXISTS. The DataStore is the live-server authoring path, and it is per-universe state: a move
	saved there is invisible to git, to review and to every other place. A move written to source is
	ordinary game content -- diffed, reviewed, shipped with the build, the same in every server.

	GAMEPLAY CONTENT, SO IT LOADS FROM Main.server.lua, NOT FROM AN ADMIN SYSTEM. Main calls Load
	immediately after MoveRegistryManager.Init and WeaponRoster.Start and before any combat Init, so a
	server boots with its shipped moves whether or not MoveEditorSystem is present.

	PRECEDENCE. built constants -> shipped override -> DataStore override, for a Default move (the shipped
	layer is part of what DefaultMoveRegistry.GetBuilt returns). For a custom move, the DataStore record
	with the same id wins: MoveEditorSystem loads it after this, and it is the newer live edit.

	NEVER FATAL. Each file is required in a pcall and decoded and validated like any stored record; one
	that fails is logged and skipped. A broken file costs that one move, never the boot.

	Record format: exactly MoveRecordCodec's (Server/Systems/Support/MoveRecordCodec.lua), so a shipped
	move is decoded -- and, after a future schema change, upgraded -- by the same code as a stored one.

	Does not own: writing the files (MoveEditorSystem + Support/MoveSourceWriter + scripts/move-writer.py),
	validation (MoveRegistryManager.Validate), or the override layer itself (DefaultMoveRegistry).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Logger = require(ReplicatedStorage.Shared.Logger)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

local DefaultMoveRegistry = require(script.Parent.DefaultMoveRegistry)
local MoveRegistryManager = require(script.Parent.MoveRegistryManager)
local MoveRecordCodec = require(script.Parent.Parent.Systems.Support.MoveRecordCodec)

local AuthoredMoveLibrary = {}

local logger = Logger.scope("AuthoredMoveLibrary")

-- Custom moves as they ship, by id -- what a custom move's "saved" state is when no DataStore record
-- overrides it.
local shippedMoves: { [string]: MoveTypes.MoveDefinition } = {}

local function requireRecord(module: ModuleScript): { [string]: any }?
	local ok, result = pcall(require, module)
	if not ok then
		logger:warn(
			"A shipped move file failed to load; skipped",
			{ file = module:GetFullName(), error = tostring(result) }
		)
		return nil
	end
	if typeof(result) ~= "table" then
		logger:warn("A shipped move file did not return a table; skipped", { file = module:GetFullName() })
		return nil
	end
	return result :: { [string]: any }
end

local function modulesIn(folder: Instance?): { ModuleScript }
	local modules: { ModuleScript } = {}
	if folder then
		for _, child in folder:GetChildren() do
			if child:IsA("ModuleScript") then
				table.insert(modules, child)
			end
		end
		-- Name order, so the boot log -- and which of two files claiming one id wins -- never depends on
		-- the order Rojo happened to create them in.
		table.sort(modules, function(a, b)
			return a.Name < b.Name
		end)
	end
	return modules
end

local function loadMoves(folder: Instance?): number
	local loaded = 0
	for _, module in modulesIn(folder) do
		local record = requireRecord(module)
		if not record then
			continue
		end
		local candidate = MoveRecordCodec.Decode(record)
		if not candidate then
			logger:warn("A shipped move file is not a move record; skipped", { file = module.Name })
			continue
		end
		local validated, reason = MoveRegistryManager.Validate(candidate)
		if not validated then
			logger:warn("A shipped move is not a valid move; skipped", { file = module.Name, reason = reason })
			continue
		end
		MoveRegistryManager.Upsert(validated)
		shippedMoves[validated.MoveId] = MoveTypes.Clone(validated)
		loaded += 1
	end
	return loaded
end

local function loadOverrides(folder: Instance?): number
	local loaded = 0
	for _, module in modulesIn(folder) do
		local record = requireRecord(module)
		if not record then
			continue
		end
		local moveId = record.MoveId
		local built = if typeof(moveId) == "string" then DefaultMoveRegistry.GetBuilt(moveId) else nil
		if not built then
			logger:warn("A shipped override names no weapon move; skipped", { file = module.Name })
			continue
		end
		local candidate = MoveRecordCodec.DecodeOverride(built, record)
		local applied, reason = DefaultMoveRegistry.SetShipped(moveId :: string, candidate)
		if not applied then
			logger:warn("A shipped override is not valid; skipped", { file = module.Name, reason = reason })
			continue
		end
		loaded += 1
	end
	return loaded
end

-- Loads everything under `root` (a folder holding Moves and Overrides). The seam the spec drives with a
-- fixture folder; production calls Load.
function AuthoredMoveLibrary.LoadFrom(root: Instance?): ()
	local moves = loadMoves(if root then root:FindFirstChild("Moves") else nil)
	local overrides = loadOverrides(if root then root:FindFirstChild("Overrides") else nil)
	logger:info("Shipped moves loaded", { moves = moves, overrides = overrides })
end

-- Assumes MoveRegistryManager.Init and WeaponRoster.Start have run (Main.server's boot order).
function AuthoredMoveLibrary.Load(): ()
	AuthoredMoveLibrary.LoadFrom(script.Parent:FindFirstChild("AuthoredMoves"))
end

-- Whether a move ships in source -- a custom move file or a Default move's override file.
function AuthoredMoveLibrary.IsShipped(moveId: string): boolean
	return shippedMoves[moveId] ~= nil or DefaultMoveRegistry.IsShipped(moveId)
end

-- A custom move as it ships, or nil.
function AuthoredMoveLibrary.GetShippedMove(moveId: string): MoveTypes.MoveDefinition?
	local move = shippedMoves[moveId]
	return if move then MoveTypes.Clone(move) else nil
end

-- Records that a custom move was just written to source (`move`) or removed from it (nil) -- the Move
-- Editor's Studio remotes, so this session agrees with the files without a restart.
function AuthoredMoveLibrary.MarkShippedMove(moveId: string, move: MoveTypes.MoveDefinition?): ()
	shippedMoves[moveId] = if move then MoveTypes.Clone(move) else nil
end

-- Spec-only.
function AuthoredMoveLibrary.Reset(): ()
	table.clear(shippedMoves)
end

return AuthoredMoveLibrary
