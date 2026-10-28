--!strict
-- WorldPersistence against an in-memory store: a save never damages the previous one, a failure part-way leaves the
-- slot exactly as it was, old generations are pruned with their chunks, and a load is all-or-nothing per chunk.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local ArchitectConstants = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectConstants)
local ArchitectRecord = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectRecord)
local StarterTemplates = require(ReplicatedStorage.Shared.WorldArchitect.StarterTemplates)
local WorldPersistence = require(ServerScriptService.Server.WorldArchitect.WorldPersistence)
local FakeDataStore = require(ServerScriptService.Tests.TestHelpers.FakeDataStore)

local Persistence = ArchitectConstants.Persistence

local function doc(count: number, name: string?): any
	local records = {}
	for index = 1, count do
		local record = ArchitectRecord.Default("Part", "Structure", `n{index}`)
		record.Position = Vector3.new(index, 1, 0)
		record.Name = name or "Part"
		table.insert(records, record)
	end
	return { NextId = count + 1, Records = records, Strokes = {} }
end

local function setup(): (any, WorldPersistence.Persistence)
	local store = FakeDataStore.New()
	return store, WorldPersistence.New(store :: any, FakeDataStore.NoRetry)
end

return function()
	it("saves and loads a world", function()
		local _, persistence = setup()
		local generation = WorldPersistence.Save(persistence, "Live", doc(5), "Admin", "first")
		assert(generation, "saved")
		expect(generation.Gen).to.equal(1)
		local report = WorldPersistence.Load(persistence, "Live", nil)
		assert(report.Doc, `loaded: {tostring(report.Reason)}`)
		expect(#report.Doc.Records).to.equal(5)
		expect(report.Doc.NextId).to.equal(6)
	end)

	it("a chunk write failure leaves the previous save loadable and unlisted chunks cleaned", function()
		local store, persistence = setup()
		assert(WorldPersistence.Save(persistence, "Live", doc(3, "Old"), "Admin", nil), "first save")
		store.FailWhen(function(method: string, key: string)
			return method == "SetAsync" and string.find(key, "_G2_C1", 1, true) ~= nil
		end)
		local failed, reason = WorldPersistence.Save(persistence, "Live", doc(4, "New"), "Admin", nil)
		expect(failed).to.equal(nil)
		expect(reason).to.equal("StorageError")
		store.FailWhen(nil)
		local report = WorldPersistence.Load(persistence, "Live", nil)
		assert(report.Doc, "previous save still loads")
		expect(#report.Doc.Records).to.equal(3)
		expect(report.Doc.Records[1].Name).to.equal("Old")
		local generations = WorldPersistence.Generations(persistence, "Live") :: { any }
		expect(#generations).to.equal(1)
	end)

	it("a failed head commit leaves the previous save current", function()
		local store, persistence = setup()
		assert(WorldPersistence.Save(persistence, "Draft", doc(2), "Admin", nil), "first save")
		local updates = 0
		store.FailWhen(function(method: string, key: string)
			if method == "UpdateAsync" and key == "Slot_Draft" then
				updates += 1
				return updates == 2 -- the reserve succeeds, the commit fails
			end
			return false
		end)
		expect((WorldPersistence.Save(persistence, "Draft", doc(9), "Admin", nil))).to.equal(nil)
		store.FailWhen(nil)
		local report = WorldPersistence.Load(persistence, "Draft", nil)
		assert(report.Doc, "loads")
		expect(#report.Doc.Records).to.equal(2)
		expect(FakeDataStore.KeyCount(store, "Slot_Draft_G2_")).to.equal(0)
	end)

	it("keeps the newest generations, prunes older ones with their chunks, and restores a snapshot", function()
		local store, persistence = setup()
		for index = 1, Persistence.GenerationsKept + 2 do
			assert(WorldPersistence.Save(persistence, "Live", doc(index), "Admin", `save {index}`), "save")
		end
		local generations = WorldPersistence.Generations(persistence, "Live") :: { any }
		expect(#generations).to.equal(Persistence.GenerationsKept)
		expect(generations[1].Gen).to.equal(3)
		expect(FakeDataStore.KeyCount(store, "Slot_Live_G1_")).to.equal(0)
		expect(FakeDataStore.KeyCount(store, "Slot_Live_G2_")).to.equal(0)
		local snapshot = WorldPersistence.Load(persistence, "Live", 4)
		assert(snapshot.Doc, "snapshot loads")
		expect(#snapshot.Doc.Records).to.equal(4)
		expect(WorldPersistence.Load(persistence, "Live", 1).Reason).to.equal("NoSuchGeneration")
	end)

	it("refuses a load with a missing chunk instead of loading part of a world", function()
		local store, persistence = setup()
		assert(WorldPersistence.Save(persistence, "Live", doc(3), "Admin", nil), "save")
		store.Data["Slot_Live_G1_C1"] = nil
		local report = WorldPersistence.Load(persistence, "Live", nil)
		expect(report.Doc).to.equal(nil)
		expect(report.Reason).to.equal("MissingChunk")
	end)

	it("reports an empty slot and lists saved slots", function()
		local _, persistence = setup()
		expect(WorldPersistence.Load(persistence, "Nothing", nil).Reason).to.equal("EmptySlot")
		assert(WorldPersistence.Save(persistence, "Live", doc(1), "Admin", nil), "live")
		assert(WorldPersistence.Save(persistence, "Courtyard", doc(1), "Admin", nil), "draft")
		local slots = WorldPersistence.ListSlots(persistence) :: { any }
		expect(#slots).to.equal(2)
		expect(slots[1].Name).to.equal("Courtyard")
	end)

	it("never deletes the Live slot, and deletes a draft's keys", function()
		local store, persistence = setup()
		assert(WorldPersistence.Save(persistence, "Draft", doc(2), "Admin", nil), "draft")
		expect((WorldPersistence.DeleteSlot(persistence, "Live"))).to.equal(false)
		expect((WorldPersistence.DeleteSlot(persistence, "Draft"))).to.equal(true)
		expect(FakeDataStore.KeyCount(store, "Slot_Draft")).to.equal(0)
	end)

	it("refuses slot names that could escape their key", function()
		expect((WorldPersistence.SlotNameShape("Live"))).to.equal("Live")
		expect((WorldPersistence.SlotNameShape("a/b"))).to.equal(nil)
		expect((WorldPersistence.SlotNameShape(""))).to.equal(nil)
		expect((WorldPersistence.SlotNameShape(string.rep("a", Persistence.MaxSlotNameLength + 1)))).to.equal(nil)
	end)

	it("saves, reloads and deletes templates; a corrupted template is refused on load", function()
		local store, persistence = setup()
		local source = StarterTemplates.Get("sm.dress.crates")
		assert(source, "crates")
		local copy = table.clone(source)
		copy.Id = "tcopy"
		copy.Builtin = false
		assert(WorldPersistence.SaveTemplate(persistence, copy), "saved template")
		local fresh = WorldPersistence.New(store :: any, FakeDataStore.NoRetry)
		local loaded, refused = WorldPersistence.LoadTemplates(fresh)
		expect(loaded).to.equal(1)
		expect(refused).to.equal(0)
		expect(fresh.Templates.tcopy.Name).to.equal(source.Name)

		store.Data["Template_tcopy"] = '{"V":1,"Name":"","Nodes":[]}'
		local again = WorldPersistence.New(store :: any, FakeDataStore.NoRetry)
		local loadedBad, refusedBad = WorldPersistence.LoadTemplates(again)
		expect(loadedBad).to.equal(0)
		expect(refusedBad).to.equal(1)

		assert(WorldPersistence.DeleteTemplate(persistence, "tcopy"), "deleted")
		expect(store.Data["Template_tcopy"]).to.equal(nil)
	end)
end
