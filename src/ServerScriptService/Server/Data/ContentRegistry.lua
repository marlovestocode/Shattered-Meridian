--!strict
--[[
	ContentRegistry.lua

	Owns: resolving one kind of content (moves today) across ORDERED LAYERS, where a higher layer's entry for an id hides every
	lower layer's entry for the same id. `ContentRegistry.New{ Kind, IdOf, Layers }` returns a registry with `Get`, `Resolve`
	(item and the layer it came from), `List`, `ListWithLayer` and `OnChanged` (every layer's change signal, fanned in).

	WHY (coworking plan F9, W16). Every place that needed "the move combat would actually throw" wrote the precedence out by hand
	-- `MoveRegistryManager.Get(id) or DefaultMoveRegistry.Get(id)` in AttackCatalog, MovePresentationSystem and the Move Editor, and
	a `seen` table merging the two Lists in three more. Each copy was right; the risk was the next one getting the order wrong, or
	a third layer arriving and only some copies learning about it. The layer order is now stated once, per kind, where it is bound.

	THE LAYER MODEL, per kind, read from source on 2026-10-27 (docs/architecture/2026-10-27-content-layers.md has the detail):
	  * Moves: Custom (MoveRegistryManager: DataStore records, plus moves shipped in Server/Combat/AuthoredMoves) over Default
	    (DefaultMoveRegistry, which itself folds shipped files and DataStore overrides over the built weapon roster). Bound in
	    Server/Combat/MoveContent.lua.
	  * Race traits and bloodlines are ONE table each (RaceManager, BloodlineManager): the canon roster is seeded into it and an
	    authored record overwrites in place. There is no lower layer to fall back to, so they are not bound here -- binding a
	    one-layer registry would add a wrapper and change nothing.

	A foundation assembles the parts that exist: every layer keeps its own storage, persistence, validation, cloning and change
	signal. This module never stores an item, never writes one (Upsert/Delete stay on the layer that owns them), and never touches
	a DataStore.

	Does not own: which layer an edit goes to (the editor decides), or what an item is.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CallbackList = require(ReplicatedStorage.Shared.CallbackList)
local Logger = require(ReplicatedStorage.Shared.Logger)

local logger = Logger.scope("ContentRegistry")

local ContentRegistry = {}

export type Layer<T> = {
	Name: string,
	Get: (id: string) -> T?,
	List: () -> { T },
	-- Fires with an id whenever what Get returns for it may have changed. Optional for a layer that never changes after boot.
	OnChanged: ((listener: (id: string) -> ()) -> () -> ())?,
}

export type Spec<T> = {
	Kind: string,
	IdOf: (item: T) -> string,
	-- Highest precedence first.
	Layers: { Layer<T> },
}

export type Entry<T> = { Item: T, Layer: string }

export type Registry<T> = {
	Kind: string,
	Get: (id: string) -> T?,
	Resolve: (id: string) -> (T?, string?),
	List: () -> { T },
	ListWithLayer: () -> { Entry<T> },
	OnChanged: (listener: (id: string) -> ()) -> () -> (),
	-- Disconnects the fan-in from every layer (specs).
	Destroy: () -> (),
}

function ContentRegistry.New<T>(spec: Spec<T>): Registry<T>
	assert(#spec.Layers > 0, `ContentRegistry.New("{spec.Kind}"): at least one layer`)
	local registry = {} :: Registry<T>
	registry.Kind = spec.Kind

	function registry.Resolve(id: string): (T?, string?)
		for _, layer in spec.Layers do
			local item = layer.Get(id)
			if item ~= nil then
				return item, layer.Name
			end
		end
		return nil, nil
	end

	function registry.Get(id: string): T?
		return (registry.Resolve(id))
	end

	-- Highest layer's items first, each id once, from the layer that wins it.
	function registry.ListWithLayer(): { Entry<T> }
		local seen: { [string]: boolean } = {}
		local entries: { Entry<T> } = {}
		for _, layer in spec.Layers do
			for _, item in layer.List() do
				local id = spec.IdOf(item)
				if not seen[id] then
					seen[id] = true
					table.insert(entries, { Item = item, Layer = layer.Name })
				end
			end
		end
		return entries
	end

	function registry.List(): { T }
		local items: { T } = {}
		for _, entry in registry.ListWithLayer() do
			table.insert(items, entry.Item)
		end
		return items
	end

	-- Lazily fanned in: no layer is subscribed to until someone listens, so binding a registry at require time costs nothing.
	local changed = CallbackList.New(logger, `{spec.Kind}Content.OnChanged`)
	local upstream: { () -> () } = {}
	local function connectUpstream(): ()
		if #upstream > 0 then
			return
		end
		for _, layer in spec.Layers do
			if layer.OnChanged then
				table.insert(
					upstream,
					layer.OnChanged(function(id: string)
						changed:Fire(id)
					end)
				)
			end
		end
	end

	function registry.OnChanged(listener: (id: string) -> ()): () -> ()
		connectUpstream()
		return changed:Connect(listener)
	end

	function registry.Destroy(): ()
		for _, disconnect in upstream do
			disconnect()
		end
		table.clear(upstream)
		changed:Clear()
	end

	return registry
end

return ContentRegistry
