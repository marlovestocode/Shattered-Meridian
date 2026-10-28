--!strict
local ServerScriptService = game:GetService("ServerScriptService")

local ContentRegistry = require(ServerScriptService.Server.Data.ContentRegistry)
local DefaultMoveRegistry = require(ServerScriptService.Server.Combat.DefaultMoveRegistry)
local MoveContent = require(ServerScriptService.Server.Combat.MoveContent)
local MoveRegistryManager = require(ServerScriptService.Server.Combat.MoveRegistryManager)

type Item = { Id: string, From: string }

-- A layer over a plain table, with a change signal, for the generic cases.
local function tableLayer(name: string, items: { [string]: Item })
	local listeners: { (string) -> () } = {}
	return {
		Name = name,
		Get = function(id: string): Item?
			return items[id]
		end,
		List = function(): { Item }
			local out = {}
			local ids = {}
			for id in items do
				table.insert(ids, id)
			end
			table.sort(ids)
			for _, id in ids do
				table.insert(out, items[id])
			end
			return out
		end,
		OnChanged = function(listener: (string) -> ()): () -> ()
			table.insert(listeners, listener)
			return function()
				local index = table.find(listeners, listener)
				if index then
					table.remove(listeners, index)
				end
			end
		end,
		Fire = function(id: string)
			for _, listener in table.clone(listeners) do
				listener(id)
			end
		end,
	}
end

return function()
	describe("ContentRegistry", function()
		local high = tableLayer("High", {
			a = { Id = "a", From = "High" },
		})
		local low = tableLayer("Low", {
			a = { Id = "a", From = "Low" },
			b = { Id = "b", From = "Low" },
		})
		local registry = ContentRegistry.New({
			Kind = "Spec",
			IdOf = function(item: Item): string
				return item.Id
			end,
			Layers = { high :: any, low :: any },
		})

		it("resolves an id from the highest layer that has it, and names the layer", function()
			local item, layer = registry.Resolve("a")
			expect((item :: Item).From).to.equal("High")
			expect(layer).to.equal("High")
			local lower, lowerLayer = registry.Resolve("b")
			expect((lower :: Item).From).to.equal("Low")
			expect(lowerLayer).to.equal("Low")
			expect(registry.Get("missing")).to.equal(nil)
		end)

		it("lists each id once, from its winning layer, highest layer first", function()
			local entries = registry.ListWithLayer()
			expect(#entries).to.equal(2)
			expect(entries[1].Item.Id).to.equal("a")
			expect(entries[1].Layer).to.equal("High")
			expect(entries[2].Item.Id).to.equal("b")
			expect(entries[2].Layer).to.equal("Low")
		end)

		it("fans every layer's change signal into one, and disconnects", function()
			local heard = {}
			local disconnect = registry.OnChanged(function(id)
				table.insert(heard, id)
			end)
			high.Fire("a")
			low.Fire("b")
			disconnect()
			high.Fire("a")
			expect(table.concat(heard, ",")).to.equal("a,b")
			registry.Destroy()
		end)
	end)

	describe("MoveContent", function()
		it(
			"answers every move id exactly as `MoveRegistryManager.Get(id) or DefaultMoveRegistry.Get(id)` did",
			function()
				local ids = {}
				for _, move in DefaultMoveRegistry.List() do
					ids[move.MoveId] = true
				end
				for _, move in MoveRegistryManager.List() do
					ids[move.MoveId] = true
				end
				ids["not-a-move"] = true
				local checked = 0
				for id in ids do
					local old = MoveRegistryManager.Get(id) or DefaultMoveRegistry.Get(id)
					local new, layer = MoveContent.Resolve(id)
					expect(new == nil).to.equal(old == nil)
					if old and new then
						expect(new.MoveId).to.equal(old.MoveId)
						expect(layer).to.equal(if MoveRegistryManager.Get(id) then "Custom" else "Default")
					end
					checked += 1
				end
				expect(checked > 1).to.equal(true)
			end
		)

		it("lists the same set of ids the two registries merged by hand did", function()
			local old: { [string]: boolean } = {}
			for _, move in MoveRegistryManager.List() do
				old[move.MoveId] = true
			end
			for _, move in DefaultMoveRegistry.List() do
				old[move.MoveId] = true
			end
			local count = 0
			for _, move in MoveContent.List() do
				expect(old[move.MoveId]).to.equal(true)
				count += 1
			end
			local expected = 0
			for _ in old do
				expected += 1
			end
			expect(count).to.equal(expected)
		end)
	end)
end
