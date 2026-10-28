--!strict
--[[
	VesselWorldEntry.lua

	Owns: the "a tagged hull is sitting outside the world" wait. `VesselWorldEntry.New(logger)` returns a watcher; a vehicle System
	calls `watcher.DeferUntilInWorld(model, register)` at the top of its register function -- it answers true (and arranges for
	`register(model)` to run once the model enters Workspace) when the model is not in the world yet, false when it is -- and
	`watcher.Cancel(model)` from its unregister.

	WHY. BlimpSystem and BoatSystem held the same pendingWorldEntry table, the same cancel and the same AncestryChanged watch
	(coworking plan W15). A model outside Workspace is the normal state of a VehicleManager template, and the whole point is that
	it stays untouched until a clone stands in the world. Watched rather than dropped, so a builder who parks a tagged hull outside
	Workspace and drags it in at runtime still gets a vehicle. Keyed by model, so a re-tag cannot stack a second listener.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Logger = require(ReplicatedStorage.Shared.Logger)

local VesselWorldEntry = {}

export type Watcher = {
	DeferUntilInWorld: (model: Model, register: (model: Model) -> ()) -> boolean,
	Cancel: (model: Model) -> (),
}

function VesselWorldEntry.New(logger: Logger.LoggerScope): Watcher
	local pending: { [Model]: RBXScriptConnection } = {}
	local watcher = {} :: Watcher

	function watcher.Cancel(model: Model): ()
		local connection = pending[model]
		if connection then
			connection:Disconnect()
			pending[model] = nil
		end
	end

	function watcher.DeferUntilInWorld(model: Model, register: (model: Model) -> ()): boolean
		if model:IsDescendantOf(Workspace) then
			watcher.Cancel(model)
			return false
		end
		if not pending[model] then
			logger:info("Tagged model is not in the world -- not registering it until it is", {
				model = model:GetFullName(),
			})
			pending[model] = model.AncestryChanged:Connect(function()
				if model:IsDescendantOf(Workspace) then
					watcher.Cancel(model)
					register(model)
				end
			end)
		end
		return true
	end

	return watcher
end

-- Destroys every descendant of `model` whose Name is in `ownedNames` (a System's own welds, drive constraints and prompts)
-- and returns how many it removed, so the caller can say something when it was not zero -- a hull arriving pre-loaded with its
-- own System's furniture, from a registration that ran on it before it was placed, is worth one log line, not silence.
function VesselWorldEntry.ClearInherited(model: Model, ownedNames: { [string]: boolean }): number
	local removed = 0
	for _, descendant in model:GetDescendants() do
		if ownedNames[descendant.Name] then
			descendant:Destroy()
			removed += 1
		end
	end
	return removed
end

return VesselWorldEntry
