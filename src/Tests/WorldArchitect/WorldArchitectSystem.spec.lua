--!strict
-- WorldArchitectSystem end to end, through the composed Endpoint handlers a real remote calls (auth, rate limit,
-- pcall, the handler): authorization, tampering, the world rules, history, templates, generation, the optimiser,
-- terrain, persistence, and the Instances that come out the other side.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local ArchitectConstants = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectConstants)
local AdminConfig = require(ServerScriptService.Server.Config.AdminConfig)
local WorldArchitectSystem = require(ServerScriptService.Server.Systems.WorldArchitectSystem)
local FakeDataStore = require(ServerScriptService.Tests.TestHelpers.FakeDataStore)

local adminId = next(AdminConfig.AuthorizedUserIds)
assert(adminId ~= nil, "AdminConfig.AuthorizedUserIds must not be empty for this spec")

local playerCount = 0
-- A fresh fake player per call: rate-limit buckets are per player, so cases never starve each other.
local function admin(): any
	playerCount += 1
	return { UserId = adminId, Name = `Admin{playerCount}` }
end

local function stranger(): any
	return { UserId = -42, Name = "Stranger" }
end

type Env = {
	Container: Folder,
	Store: any,
	Pushes: { any },
	Call: (key: string, player: any, ...any) -> any,
	Root: () -> Instance,
}

local function env(options: { Terrain: Terrain?, Store: any? }?): Env
	if WorldArchitectSystem.Remotes.Edit == nil then
		WorldArchitectSystem.Init()
	end
	local container = Instance.new("Folder")
	container.Name = "WorldArchitectSpec"
	container.Parent = Workspace
	local store = (options and options.Store) or FakeDataStore.New()
	local pushes = {}
	WorldArchitectSystem.ConfigureForTesting({
		Store = store,
		Retry = FakeDataStore.NoRetry,
		Container = container,
		Terrain = options and options.Terrain,
		Push = function(_player: any, payload: any)
			table.insert(pushes, payload)
		end,
		LoadNow = true,
	})
	return {
		Container = container,
		Store = store,
		Pushes = pushes,
		Call = function(key: string, player: any, ...: any): any
			return WorldArchitectSystem.Remotes[key].Handle(player, ...)
		end,
		Root = function(): Instance
			return container:FindFirstChild(ArchitectConstants.RootFolderName) :: Instance
		end,
	}
end

local function block(position: Vector3, extra: { [string]: any }?): { [string]: any }
	local node: { [string]: any } = { Kind = "Part", Position = position, Size = Vector3.new(4, 1, 4), Name = "Block" }
	for key, value in extra or {} do
		node[key] = value
	end
	return node
end

local function createOne(e: Env, player: any, position: Vector3, extra: { [string]: any }?): string
	local result = e.Call("Edit", player, { Kind = "Create", Nodes = { { Ref = "a", Node = block(position, extra) } } })
	assert(result.Success, `create failed: {tostring(result.Reason)}`)
	return result.Created[1]
end

local function record(id: string): any
	return WorldArchitectSystem.State().Records[id]
end

return function()
	local active: Env? = nil
	afterEach(function()
		if active then
			active.Container:Destroy()
			active = nil
		end
	end)
	local function fresh(options: { Terrain: Terrain?, Store: any? }?): Env
		if active then
			active.Container:Destroy()
		end
		active = env(options)
		return active :: Env
	end

	describe("authorization and tampering", function()
		it("refuses every remote to a player off the whitelist", function()
			local e = fresh()
			for _, key in { "Open", "Edit", "Undo", "Template", "World", "Analyze", "Preview", "Terrain" } do
				local result = e.Call(key, stranger(), { Kind = "List" })
				expect(result.Success).to.equal(false)
				expect(result.Reason).to.equal("NotAuthorized")
			end
			expect(WorldArchitectSystem.State().Count).to.equal(0)
		end)

		it("rate-limits a flood of requests", function()
			local e = fresh()
			local player = admin()
			local limited = false
			for _ = 1, ArchitectConstants.RateLimits.Read + 10 do
				local result = e.Call("Page", player, 1)
				if result.Reason == "RateLimited" then
					limited = true
				end
			end
			expect(limited).to.equal(true)
		end)

		it("answers malformed requests with a reason and changes nothing", function()
			local e = fresh()
			local player = admin()
			for _, request in
				{
					"not a table",
					{ Kind = "Explode" },
					{ Kind = "Create", Nodes = "x" },
					{ Kind = "Create", Nodes = { { Ref = "a", Node = { Kind = "Script", Position = Vector3.zero } } } },
					{ Kind = "Update", Changes = { { Id = "../../Workspace", Rev = 1, Patch = {} } } },
					{ Kind = "Delete", Targets = { { Id = "nzzz", Rev = 1 } } },
					{ Kind = "PlaceTemplate", TemplateId = "sm.nope", Position = Vector3.zero },
				}
			do
				local result = e.Call("Edit", player, request)
				expect(result.Success).to.equal(false)
				expect(type(result.Reason)).to.equal("string")
			end
			expect(WorldArchitectSystem.State().Count).to.equal(0)
		end)

		it("cannot address anything outside the managed folder", function()
			local e = fresh()
			local outsider = Instance.new("Part")
			outsider.Name = "MapPiece"
			outsider.Parent = e.Container
			local result = e.Call("Edit", admin(), {
				Kind = "Update",
				Changes = { { Id = outsider.Name, Rev = 0, Patch = { Transparency = 1 } } },
			})
			expect(result.Success).to.equal(false)
			expect(outsider.Transparency).to.equal(0)
		end)

		it("refuses building into a spawn", function()
			local e = fresh()
			local spawn = Instance.new("SpawnLocation")
			spawn.Anchored = true
			spawn.Size = Vector3.new(8, 1, 8)
			spawn.Position = Vector3.new(200, 0, 200)
			spawn.Parent = e.Container
			e.Call("Open", admin()) -- re-reads the zones
			local result = e.Call(
				"Edit",
				admin(),
				{ Kind = "Create", Nodes = { { Ref = "a", Node = block(Vector3.new(200, 2, 200)) } } }
			)
			expect(result.Reason).to.equal("ProtectedArea")
		end)
	end)

	describe("editing", function()
		it("creates a node, materialises it under the managed folder and pushes a delta", function()
			local e = fresh()
			local player = admin()
			e.Call("Open", player)
			local id = createOne(e, player, Vector3.new(10, 5, 10), { Role = "Decor" })
			local instance = WorldArchitectSystem.InstanceOf(id)
			assert(instance and instance:IsA("BasePart"), "a part was built")
			expect(instance:IsDescendantOf(e.Root())).to.equal(true)
			expect(instance.CanCollide).to.equal(false)
			expect(instance:GetAttribute(ArchitectConstants.IdAttribute)).to.equal(id)
			local last = e.Pushes[#e.Pushes]
			expect(last.Upserts[1].Id).to.equal(id)
		end)

		it("refuses a stale update from a second admin", function()
			local e = fresh()
			local first, second = admin(), admin()
			local id = createOne(e, first, Vector3.new(0, 5, 0))
			local rev = record(id).Rev
			local ok = e.Call(
				"Edit",
				first,
				{ Kind = "Update", Changes = { { Id = id, Rev = rev, Patch = { Name = "Mine" } } } }
			)
			expect(ok.Success).to.equal(true)
			local stale = e.Call(
				"Edit",
				second,
				{ Kind = "Update", Changes = { { Id = id, Rev = rev, Patch = { Name = "Theirs" } } } }
			)
			expect(stale.Reason).to.equal("StaleNode")
			expect(record(id).Name).to.equal("Mine")
		end)

		it("undo and redo a delete; undo refuses after another admin's change", function()
			local e = fresh()
			local first, second = admin(), admin()
			local id = createOne(e, first, Vector3.new(0, 5, 0))
			local deleted = e.Call("Edit", first, { Kind = "Delete", Targets = { { Id = id, Rev = record(id).Rev } } })
			expect(deleted.Success).to.equal(true)
			expect(WorldArchitectSystem.InstanceOf(id)).to.equal(nil)
			expect(e.Call("Undo", first).Success).to.equal(true)
			expect(record(id) ~= nil).to.equal(true)
			expect(WorldArchitectSystem.InstanceOf(id) ~= nil).to.equal(true)
			expect(e.Call("Redo", first).Success).to.equal(true)
			expect(record(id)).to.equal(nil)
			expect(e.Call("Undo", first).Success).to.equal(true)

			-- the other admin changes it; the first admin's next undo (of their create) must not clobber that
			e.Call(
				"Edit",
				second,
				{ Kind = "Update", Changes = { { Id = id, Rev = record(id).Rev, Patch = { Name = "Changed" } } } }
			)
			local conflict = e.Call("Undo", first)
			expect(conflict.Success).to.equal(false)
			expect(conflict.Reason).to.equal("UndoConflict")
			expect(record(id).Name).to.equal("Changed")
		end)

		it("undoes a chain of the admin's own edits in order (create, edit, edit)", function()
			local e = fresh()
			local player = admin()
			local id = createOne(e, player, Vector3.new(0, 5, 0))
			e.Call(
				"Edit",
				player,
				{ Kind = "Update", Changes = { { Id = id, Rev = record(id).Rev, Patch = { Name = "One" } } } }
			)
			e.Call(
				"Edit",
				player,
				{ Kind = "Update", Changes = { { Id = id, Rev = record(id).Rev, Patch = { Name = "Two" } } } }
			)
			expect(e.Call("Undo", player).Success).to.equal(true)
			expect(record(id).Name).to.equal("One")
			expect(e.Call("Undo", player).Success).to.equal(true)
			expect(record(id).Name).to.equal("Block")
			expect(e.Call("Redo", player).Success).to.equal(true)
			expect(e.Call("Redo", player).Success).to.equal(true)
			expect(record(id).Name).to.equal("Two")
			expect(e.Call("Undo", player).Success).to.equal(true)
			expect(e.Call("Undo", player).Success).to.equal(true)
			expect(e.Call("Undo", player).Success).to.equal(true)
			expect(record(id)).to.equal(nil)
		end)

		it("groups, ungroups and refuses nested targets", function()
			local e = fresh()
			local player = admin()
			local a = createOne(e, player, Vector3.new(0, 5, 0))
			local b = createOne(e, player, Vector3.new(10, 5, 0))
			local grouped = e.Call("Edit", player, {
				Kind = "Group",
				Targets = { { Id = a, Rev = record(a).Rev }, { Id = b, Rev = record(b).Rev } },
				Name = "Pair",
			})
			assert(grouped.Success, tostring(grouped.Reason))
			local groupId = grouped.Created[1]
			expect(record(a).Parent).to.equal(groupId)
			local model = WorldArchitectSystem.InstanceOf(groupId)
			assert(model and model:IsA("Model"), "group is a Model")
			expect(WorldArchitectSystem.InstanceOf(a).Parent).to.equal(model)
			local nested = e.Call("Edit", player, {
				Kind = "Group",
				Targets = { { Id = groupId, Rev = record(groupId).Rev }, { Id = a, Rev = record(a).Rev } },
			})
			expect(nested.Reason).to.equal("NestedTargets")
			local ungrouped =
				e.Call("Edit", player, { Kind = "Ungroup", Target = { Id = groupId, Rev = record(groupId).Rev } })
			expect(ungrouped.Success).to.equal(true)
			expect(record(a).Parent).to.equal(nil)
			expect(record(groupId)).to.equal(nil)
		end)

		it("places a built-in template as one group", function()
			local e = fresh()
			local result = e.Call("Edit", admin(), {
				Kind = "PlaceTemplate",
				TemplateId = "sm.pavilion.square.celestial",
				Position = Vector3.new(50, 0, 50),
				Yaw = 90,
			})
			assert(result.Success, tostring(result.Reason))
			local root = record(result.Created[1])
			expect(root.Kind).to.equal("Group")
			expect(root.Template).to.equal("sm.pavilion.square.celestial")
			expect(WorldArchitectSystem.State().Count > 4).to.equal(true)
		end)
	end)

	describe("templates", function()
		it("saves a selection as a template, places it, and deletes it", function()
			local e = fresh()
			local player = admin()
			local a = createOne(e, player, Vector3.new(0, 5, 0))
			local saved = e.Call(
				"Template",
				player,
				{ Kind = "Save", Name = "Slab", Category = "Tests", Targets = { { Id = a, Rev = record(a).Rev } } }
			)
			assert(saved.Success, tostring(saved.Reason))
			local templateId = saved.Template.Id
			local placed = e.Call(
				"Edit",
				player,
				{ Kind = "PlaceTemplate", TemplateId = templateId, Position = Vector3.new(30, 0, 0) }
			)
			expect(placed.Success).to.equal(true)
			expect(e.Call("Template", player, { Kind = "Delete", Id = templateId }).Success).to.equal(true)
			expect(e.Call("Template", player, { Kind = "Get", Id = templateId }).Success).to.equal(false)
		end)

		it("refuses renaming or deleting a built-in", function()
			local e = fresh()
			expect(e.Call("Template", admin(), { Kind = "Delete", Id = "sm.pavilion.square.celestial" }).Success).to.equal(
				false
			)
			expect(
				e.Call("Template", admin(), { Kind = "Rename", Id = "sm.pavilion.square.celestial", Name = "Mine" }).Success
			).to.equal(false)
		end)
	end)

	describe("generation", function()
		local config = {
			Type = "Ruins",
			Seed = 77,
			Center = Vector3.new(1000, 0, 1000),
			AreaX = 120,
			AreaZ = 120,
			Spacing = 6,
			Density = 0.5,
			FollowGround = false,
		}

		it("previews without building anything, then commits exactly the previewed layout", function()
			local e = fresh()
			local player = admin()
			local preview = e.Call("Preview", player, config)
			assert(preview.Success, tostring(preview.Reason))
			expect(#preview.Placements > 0).to.equal(true)
			expect(WorldArchitectSystem.State().Count).to.equal(0)
			local committed = e.Call("Edit", player, { Kind = "Generate", Config = config })
			assert(committed.Success, tostring(committed.Reason))
			expect(committed.Placed).to.equal(#preview.Placements)
			expect(WorldArchitectSystem.State().Count).to.equal(preview.NodeCount)
			expect(e.Call("Undo", player).Success).to.equal(true)
			expect(WorldArchitectSystem.State().Count).to.equal(0)
		end)

		it("refuses an invalid config", function()
			local e = fresh()
			expect(e.Call("Preview", admin(), { Type = "Castle" }).Success).to.equal(false)
		end)
	end)

	describe("optimizer", function()
		it("applies safe changes as one undoable edit and never touches Structure collision", function()
			local e = fresh()
			local player = admin()
			local decor =
				createOne(e, player, Vector3.new(0, 5, 0), { Role = "Decor", CanCollide = true, Anchored = false })
			local wall = createOne(e, player, Vector3.new(20, 5, 0), { Role = "Structure", CanTouch = true })
			local analysis = e.Call("Analyze", admin())
			expect(analysis.Report.SafeChanges > 0).to.equal(true)
			local applied = e.Call("Edit", player, { Kind = "Optimize", IncludeDestructive = false })
			assert(applied.Success, tostring(applied.Reason))
			expect(record(decor).Anchored).to.equal(true)
			expect(record(decor).CanCollide).to.equal(false)
			expect(record(wall).CanCollide).to.equal(true)
			expect(record(wall).CanTouch).to.equal(false)
			expect(e.Call("Undo", player).Success).to.equal(true)
			expect(record(decor).CanCollide).to.equal(true)
			expect(record(wall).CanTouch).to.equal(true)
		end)
	end)

	describe("persistence", function()
		it("publishes to Live, and a new server loads it at boot", function()
			local e = fresh()
			local player = admin()
			createOne(e, player, Vector3.new(0, 5, 0))
			createOne(e, player, Vector3.new(8, 5, 0))
			local saved = e.Call("World", player, { Kind = "Save", Slot = "Live" })
			assert(saved.Success, tostring(saved.Reason))
			expect(saved.Status.Unpublished).to.equal(false)

			local reboot = fresh({ Store = e.Store })
			expect(WorldArchitectSystem.State().Count).to.equal(2)
			expect(#reboot.Root():GetChildren()).to.equal(2)
		end)

		it("loading a draft autosaves the working world first, and the draft replaces it", function()
			local e = fresh()
			local player = admin()
			createOne(e, player, Vector3.new(0, 5, 0))
			assert(e.Call("World", player, { Kind = "Save", Slot = "Draft" }).Success, "draft saved")
			createOne(e, player, Vector3.new(30, 5, 0))
			local loaded = e.Call("World", player, { Kind = "Load", Slot = "Draft" })
			assert(loaded.Success, tostring(loaded.Reason))
			expect(WorldArchitectSystem.State().Count).to.equal(1)
			-- A different admin: World is the heavy category (two a second), and this one has spent its budget.
			local slots = e.Call("World", admin(), { Kind = "ListSlots" })
			local names: { [string]: boolean } = {}
			for _, slot in slots.Slots do
				names[slot.Name] = true
			end
			expect(names.Autosave).to.equal(true)
		end)

		it("a failing store reports the failure and changes nothing", function()
			local e = fresh()
			local player = admin()
			createOne(e, player, Vector3.new(0, 5, 0))
			e.Store.FailWhen(function()
				return true
			end)
			local saved = e.Call("World", player, { Kind = "Save", Slot = "Live" })
			expect(saved.Success).to.equal(false)
			expect(saved.Reason).to.equal("StorageError")
			local loaded = e.Call("World", player, { Kind = "Load", Slot = "Live" })
			expect(loaded.Success).to.equal(false)
			expect(WorldArchitectSystem.State().Count).to.equal(1)
			e.Store.FailWhen(nil)
		end)

		it("refuses slot names that are not plain words", function()
			local e = fresh()
			expect(e.Call("World", admin(), { Kind = "Save", Slot = "../Live" }).Success).to.equal(false)
		end)
	end)

	describe("terrain", function()
		it("applies a stroke and undo restores the voxels exactly", function()
			local terrain = Workspace:FindFirstChildOfClass("Terrain")
			if terrain == nil then
				return
			end
			local e = fresh({ Terrain = terrain })
			local player = admin()
			local center = Vector3.new(6000, -300, 6000)
			local region = Region3.new(center - Vector3.new(12, 12, 12), center + Vector3.new(12, 12, 12))
				:ExpandToGrid(4)
			local _, before = terrain:ReadVoxels(region, 4)
			local stroke = e.Call(
				"Terrain",
				player,
				{ Mode = "Add", Center = center, Radius = 6, Strength = 1, Material = "Rock" }
			)
			assert(stroke.Success, tostring(stroke.Reason))
			local _, during = terrain:ReadVoxels(region, 4)
			local changed = false
			for x = 1, during.Size.X do
				for y = 1, during.Size.Y do
					for z = 1, during.Size.Z do
						if during[x][y][z] ~= before[x][y][z] then
							changed = true
						end
					end
				end
			end
			expect(changed).to.equal(true)
			expect(e.Call("Undo", player).Success).to.equal(true)
			local _, after = terrain:ReadVoxels(region, 4)
			for x = 1, after.Size.X do
				for y = 1, after.Size.Y do
					for z = 1, after.Size.Z do
						expect(after[x][y][z]).to.equal(before[x][y][z])
					end
				end
			end
		end)

		it("refuses a stroke without a terrain or into a spawn", function()
			local e = fresh()
			local result = e.Call(
				"Terrain",
				admin(),
				{ Mode = "Add", Center = Vector3.new(0, 0, 0), Radius = 4, Strength = 1, Material = "Rock" }
			)
			expect(result.Success).to.equal(false)
		end)
	end)
end
