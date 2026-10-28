--!strict
--[[
	WorldPersistence.lua

	Owns: everything the World Architect keeps in DataStores -- world SLOTS (the Live world every server loads at boot,
	plus named drafts), each slot's last few saved GENERATIONS (its restorable snapshots), and the saved-template
	library.

	A SAVE NEVER DAMAGES THE PREVIOUS ONE. A slot's head key lists its generations; a save:
	  1. encodes the world into chunks (refusing, before any write, a world that needs too many);
	  2. reserves a new generation number on the head (UpdateAsync -- two admins saving at once get different numbers);
	  3. writes that generation's chunk keys;
	  4. only then appends the generation to the head (UpdateAsync again), pruning the oldest past GenerationsKept.
	A failure at 3 leaves the head pointing at the old generation; nothing that loads can see a half-written save. The
	chunks of a pruned or abandoned generation are removed best-effort (a leftover chunk is unreachable, never wrong).

	A LOAD IS ALL OR NOTHING AT THE CHUNK LEVEL (a missing chunk refuses the whole load) and PER RECORD below that: a
	record that fails validation is skipped and counted, so one corrupt part cannot cost an admin their world.

	TEMPLATES are one key each plus the shared index document (Systems/Support/AuthoredContentStore), the same layout
	as authored moves and bloodlines; every record goes back through ArchitectCodec.DecodeTemplate on load.

	THE STORE AND THE RETRY ARE ARGUMENTS, so Tests/WorldArchitect/WorldPersistence.spec.lua drives saves, failures part
	way through, pruning and loads against an in-memory store with no backoff waits.

	Keys: "Slots" (index, field "Names"); "Slot_<name>" (head); "Slot_<name>_G<gen>_C<i>" (chunks);
	"TemplateIndex" (field "Ids"); "Template_<id>".
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Schema = require(ReplicatedStorage.Shared.Schema)
local ArchitectCodec = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectCodec)
local ArchitectConstants = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectConstants)
local ArchitectTemplates = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectTemplates)
local AuthoredContentStore = require(script.Parent.Parent.Systems.Support.AuthoredContentStore)

type Template = ArchitectTemplates.Template

local Persistence = ArchitectConstants.Persistence

local WorldPersistence = {}

-- The four DataStore methods used; a real DataStore or a spec's table.
export type Store = {
	GetAsync: (self: any, key: string) -> any,
	SetAsync: (self: any, key: string, value: any) -> any,
	UpdateAsync: (self: any, key: string, transform: (any) -> any) -> any,
	RemoveAsync: (self: any, key: string) -> any,
}

export type Retry = (name: string, attempt: any) -> (boolean, any, string?)

export type Generation = {
	Gen: number,
	Chunks: number,
	SavedAt: number,
	SavedBy: string,
	Nodes: number,
	Strokes: number,
	Note: string,
}

export type SlotInfo = {
	Name: string,
	Generations: { Generation },
}

export type Persistence = {
	Store: Store,
	Retry: Retry,
	Templates: { [string]: Template },
}

local SLOT_INDEX_KEY = "Slots"
-- PERSISTED FIELD NAMES -- the readers below must match these literals (AuthoredContentStore's own warning).
local SLOT_INDEX_FIELD = "Names"
local TEMPLATE_INDEX_KEY = "TemplateIndex"
local TEMPLATE_INDEX_FIELD = "Ids"

-- Slot names: letters, digits, spaces, dashes, underscores; bounded. They become part of a key.
WorldPersistence.SlotNameShape = Schema.Custom(function(raw: unknown): (string?, string?)
	if not Schema.IsString(raw) then
		return nil, "expected slot name"
	end
	local name = raw :: string
	if #name < 1 or #name > Persistence.MaxSlotNameLength or string.find(name, "[^%w _%-]") then
		return nil, "InvalidSlotName"
	end
	return name, nil
end)

function WorldPersistence.New(store: Store, retry: Retry): Persistence
	return { Store = store, Retry = retry, Templates = {} }
end

local function headKey(slot: string): string
	return `Slot_{slot}`
end

local function chunkKey(slot: string, gen: number, index: number): string
	return `Slot_{slot}_G{gen}_C{index}`
end

local function decodeGeneration(raw: unknown): Generation?
	if not Schema.IsTable(raw) then
		return nil
	end
	local g = raw :: { [string]: any }
	local gen = Schema.NumberOr(g.Gen, 0)
	local chunks = Schema.NumberOr(g.Chunks, 0)
	if gen < 1 or chunks < 1 or chunks > Persistence.MaxChunks then
		return nil
	end
	return {
		Gen = math.floor(gen),
		Chunks = math.floor(chunks),
		SavedAt = Schema.NumberOr(g.SavedAt, 0),
		SavedBy = Schema.StringOr(g.SavedBy, "?"),
		Nodes = Schema.NumberOr(g.Nodes, 0),
		Strokes = Schema.NumberOr(g.Strokes, 0),
		Note = Schema.StringOr(g.Note, ""),
	}
end

local function decodeHead(raw: unknown): ({ Generation }, number)
	local generations: { Generation } = {}
	local nextGen = 1
	if Schema.IsTable(raw) then
		local head = raw :: { [string]: any }
		if Schema.IsTable(head.Generations) then
			for _, entry in ipairs(head.Generations :: { unknown }) do
				local generation = decodeGeneration(entry)
				if generation then
					table.insert(generations, generation)
				end
			end
		end
		nextGen = math.max(math.floor(Schema.NumberOr(head.NextGen, 1)), 1)
		for _, generation in generations do
			nextGen = math.max(nextGen, generation.Gen + 1)
		end
	end
	return generations, nextGen
end

local function encodeHead(generations: { Generation }, nextGen: number): { [string]: any }
	return { Generations = generations, NextGen = nextGen }
end

local function removeChunks(persistence: Persistence, slot: string, generation: Generation): ()
	for index = 1, generation.Chunks do
		persistence.Retry("WorldArchitect RemoveChunk", function()
			persistence.Store:RemoveAsync(chunkKey(slot, generation.Gen, index))
		end)
	end
end

-- Saves `doc` as a new generation of `slot`. Returns the generation, or nil and a reason (with the slot's previous
-- generations untouched).
function WorldPersistence.Save(
	persistence: Persistence,
	slot: string,
	doc: ArchitectCodec.WorldDoc,
	savedBy: string,
	note: string?
): (Generation?, string?)
	local chunks, encodeReason = ArchitectCodec.EncodeWorld(doc)
	if chunks == nil then
		return nil, encodeReason
	end
	local store = persistence.Store

	local reserved: number? = nil
	local reserveOk = persistence.Retry("WorldArchitect ReserveGeneration", function()
		store:UpdateAsync(headKey(slot), function(old: unknown)
			local generations, nextGen = decodeHead(old)
			reserved = nextGen
			return encodeHead(generations, nextGen + 1)
		end)
	end)
	if not reserveOk or reserved == nil then
		return nil, "StorageError"
	end
	local gen = reserved :: number

	local generation: Generation = {
		Gen = gen,
		Chunks = #chunks,
		SavedAt = os.time(),
		SavedBy = savedBy,
		Nodes = #doc.Records,
		Strokes = #doc.Strokes,
		Note = string.sub(note or "", 1, 80),
	}
	for index, chunk in chunks do
		local ok = persistence.Retry("WorldArchitect WriteChunk", function()
			store:SetAsync(chunkKey(slot, gen, index), chunk)
		end)
		if not ok then
			-- Abandon the generation; the head never lists it. Clean what landed.
			removeChunks(persistence, slot, { Gen = gen, Chunks = index - 1 } :: any)
			return nil, "StorageError"
		end
	end

	local pruned: { Generation } = {}
	local commitOk = persistence.Retry("WorldArchitect CommitGeneration", function()
		store:UpdateAsync(headKey(slot), function(old: unknown)
			local generations, nextGen = decodeHead(old)
			table.insert(generations, generation)
			table.sort(generations, function(a, b)
				return a.Gen < b.Gen
			end)
			table.clear(pruned)
			while #generations > Persistence.GenerationsKept do
				table.insert(pruned, table.remove(generations, 1) :: Generation)
			end
			return encodeHead(generations, math.max(nextGen, gen + 1))
		end)
	end)
	if not commitOk then
		removeChunks(persistence, slot, generation)
		return nil, "StorageError"
	end
	for _, old in pruned do
		removeChunks(persistence, slot, old)
	end
	AuthoredContentStore.AddToIndex(
		persistence.Retry :: any,
		"WorldArchitect",
		store :: any,
		SLOT_INDEX_KEY,
		SLOT_INDEX_FIELD,
		slot
	)
	return generation, nil
end

function WorldPersistence.Generations(persistence: Persistence, slot: string): ({ Generation }?, string?)
	local ok, raw = persistence.Retry("WorldArchitect ReadHead", function()
		return persistence.Store:GetAsync(headKey(slot))
	end)
	if not ok then
		return nil, "StorageError"
	end
	local generations = decodeHead(raw)
	return generations, nil
end

-- Loads `slot` at generation `gen` (its newest when nil). `Doc` is nil with a Reason when nothing may be loaded.
function WorldPersistence.Load(persistence: Persistence, slot: string, gen: number?): ArchitectCodec.DecodeReport
	local generations, reason = WorldPersistence.Generations(persistence, slot)
	if generations == nil then
		return { Doc = nil, Reason = reason, Skipped = 0 }
	end
	if #generations == 0 then
		return { Doc = nil, Reason = "EmptySlot", Skipped = 0 }
	end
	local chosen: Generation? = nil
	for _, generation in generations do
		if gen == nil or generation.Gen == gen then
			chosen = generation
		end
	end
	if chosen == nil then
		return { Doc = nil, Reason = "NoSuchGeneration", Skipped = 0 }
	end
	local raws: { unknown } = {}
	for index = 1, chosen.Chunks do
		local ok, raw = persistence.Retry("WorldArchitect ReadChunk", function()
			return persistence.Store:GetAsync(chunkKey(slot, chosen.Gen, index))
		end)
		if not ok then
			return { Doc = nil, Reason = "StorageError", Skipped = 0 }
		end
		if raw == nil then
			return { Doc = nil, Reason = "MissingChunk", Skipped = 0 }
		end
		table.insert(raws, raw)
	end
	return ArchitectCodec.DecodeWorld(raws)
end

function WorldPersistence.ListSlots(persistence: Persistence): ({ SlotInfo }?, string?)
	local ok, raw = persistence.Retry("WorldArchitect ReadSlotIndex", function()
		return persistence.Store:GetAsync(SLOT_INDEX_KEY)
	end)
	if not ok then
		return nil, "StorageError"
	end
	local names: { string } = {}
	if Schema.IsTable(raw) and Schema.IsTable((raw :: any)[SLOT_INDEX_FIELD]) then
		for _, name in ipairs((raw :: any)[SLOT_INDEX_FIELD]) do
			if WorldPersistence.SlotNameShape(name) and #names < Persistence.MaxSlots then
				table.insert(names, name)
			end
		end
	end
	table.sort(names)
	local out: { SlotInfo } = {}
	for _, name in names do
		local generations = WorldPersistence.Generations(persistence, name)
		table.insert(out, { Name = name, Generations = generations or {} })
	end
	return out, nil
end

function WorldPersistence.DeleteSlot(persistence: Persistence, slot: string): (boolean, string?)
	if slot == Persistence.LiveSlot then
		return false, "CannotDeleteLive"
	end
	local generations = WorldPersistence.Generations(persistence, slot)
	if generations == nil then
		return false, "StorageError"
	end
	local removed = AuthoredContentStore.RemoveFromIndex(
		persistence.Retry :: any,
		"WorldArchitect",
		persistence.Store :: any,
		SLOT_INDEX_KEY,
		SLOT_INDEX_FIELD,
		slot
	)
	if not removed then
		return false, "StorageError"
	end
	persistence.Retry("WorldArchitect RemoveHead", function()
		persistence.Store:RemoveAsync(headKey(slot))
	end)
	for _, generation in generations do
		removeChunks(persistence, slot, generation)
	end
	return true, nil
end

--
-- Templates
--

local function templateKey(id: string): string
	return `Template_{id}`
end

-- Reads every saved template into the in-memory library. Returns how many loaded and how many were refused.
function WorldPersistence.LoadTemplates(persistence: Persistence): (number, number)
	local ok, raw = persistence.Retry("WorldArchitect ReadTemplateIndex", function()
		return persistence.Store:GetAsync(TEMPLATE_INDEX_KEY)
	end)
	if not ok or not Schema.IsTable(raw) or not Schema.IsTable((raw :: any)[TEMPLATE_INDEX_FIELD]) then
		return 0, 0
	end
	local loaded, refused = 0, 0
	for _, id in ipairs((raw :: any)[TEMPLATE_INDEX_FIELD]) do
		if Schema.IsString(id) then
			local getOk, record = persistence.Retry("WorldArchitect ReadTemplate", function()
				return persistence.Store:GetAsync(templateKey(id))
			end)
			local template = if getOk and record ~= nil then ArchitectCodec.DecodeTemplate(record, id) else nil
			if template then
				persistence.Templates[id] = template
				loaded += 1
			else
				refused += 1
			end
		end
	end
	return loaded, refused
end

function WorldPersistence.SaveTemplate(persistence: Persistence, template: Template): (boolean, string?)
	local ok = persistence.Retry("WorldArchitect WriteTemplate", function()
		persistence.Store:SetAsync(templateKey(template.Id), ArchitectCodec.EncodeTemplate(template))
	end)
	if not ok then
		return false, "StorageError"
	end
	local indexed = AuthoredContentStore.AddToIndex(
		persistence.Retry :: any,
		"WorldArchitect",
		persistence.Store :: any,
		TEMPLATE_INDEX_KEY,
		TEMPLATE_INDEX_FIELD,
		template.Id
	)
	if not indexed then
		return false, "StorageError"
	end
	persistence.Templates[template.Id] = template
	return true, nil
end

function WorldPersistence.DeleteTemplate(persistence: Persistence, id: string): (boolean, string?)
	local removed = AuthoredContentStore.RemoveFromIndex(
		persistence.Retry :: any,
		"WorldArchitect",
		persistence.Store :: any,
		TEMPLATE_INDEX_KEY,
		TEMPLATE_INDEX_FIELD,
		id
	)
	if not removed then
		return false, "StorageError"
	end
	persistence.Retry("WorldArchitect RemoveTemplate", function()
		persistence.Store:RemoveAsync(templateKey(id))
	end)
	persistence.Templates[id] = nil
	return true, nil
end

return WorldPersistence
