--!strict
--[[
	MovePresentationCatalog.lua

	Owns: this client's copy of the per-move presentation catalogue (MoveId -> MoveDefinition.Presentation)
	that Server/Combat/MovePresentationSystem.lua replicates, and keeping every asset id it references
	preloaded -- including ids a Move Editor Preview adds mid-session.

	VERSIONED. The versioning rules are MovePresentationTypes.ApplyCatalogMessage's (pure, specced). What
	this module adds is the one reaction to "Stale": ask for a Snapshot again, at most once per
	RESYNC_SECONDS and never while one is already on its way. The first ask is at Start; the answer
	arrives on the same ordered remote as every Delta, so a Delta sent before the Snapshot was taken is
	"Ignored" and one sent after applies on top of it.

	PRELOADING. The boot pass (Client/Loading/AssetPreloader.BuildManifest) includes whatever this module
	already holds, but the catalogue usually arrives just after that pass -- so every Applied message
	hands the asset ids this client has not preloaded yet to the preloader it was started with
	(AssetPreloader.PreloadLabelled, injected by Main.client to keep the require graph one-way). Each id
	is labelled "MovePresentation.<MoveId>.<Moment>.<Field>", so a failure names the move and the moment.

	Does not own: what a cue does (Client/FX/MovePresentation.lua), the wire contract
	(Shared/Combat/MovePresentationTypes.lua) or the preload call itself (AssetPreloader).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Logger = require(ReplicatedStorage.Shared.Logger)
local MovePresentationTypes = require(ReplicatedStorage.Shared.Combat.MovePresentationTypes)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)

type Presentation = MovePresentationTypes.Presentation

export type PreloadEntry = {
	AssetId: string,
	Kind: MovePresentationTypes.AssetKind,
	Label: string,
}

local logger = Logger.scope("MovePresentationCatalog")

local MovePresentationCatalog = {}

-- A stale client asks again no more often than this.
local RESYNC_SECONDS = 2

local state: MovePresentationTypes.CatalogState = { Version = 0, Entries = {} }
local preloaded: { [string]: boolean } = {}
local listeners: { (moveIds: { string }) -> () } = {}
local preloader: (({ PreloadEntry }) -> ())? = nil
local awaitingSnapshot = false
local lastRequestAt = -math.huge
local started = false

-- Every asset `moveId`'s block references, as labelled preload entries.
local function entriesFor(moveId: string, presentation: Presentation): { PreloadEntry }
	local entries: { PreloadEntry } = {}
	for _, ref in MovePresentationTypes.AssetRefs(presentation) do
		table.insert(entries, {
			AssetId = ref.AssetId,
			Kind = ref.Kind,
			Label = `MovePresentation.{moveId}.{ref.Moment}.{ref.Field}`,
		})
	end
	return entries
end

-- Every asset the catalogue references right now. AssetPreloader.BuildManifest's category.
function MovePresentationCatalog.GetPreloadEntries(): { PreloadEntry }
	local entries: { PreloadEntry } = {}
	for moveId, presentation in state.Entries do
		for _, entry in entriesFor(moveId, presentation) do
			table.insert(entries, entry)
		end
	end
	return entries
end

-- The block for `moveId`, or nil (not authored, or not known yet -- both mean "defaults").
function MovePresentationCatalog.Get(moveId: string): Presentation?
	return state.Entries[moveId]
end

function MovePresentationCatalog.Version(): number
	return state.Version
end

-- Called with the MoveIds whose block changed, after every Applied message. Returns the unsubscribe.
function MovePresentationCatalog.OnChanged(listener: (moveIds: { string }) -> ()): () -> ()
	table.insert(listeners, listener)
	return function()
		local index = table.find(listeners, listener)
		if index then
			table.remove(listeners, index)
		end
	end
end

local function request(): ()
	local now = os.clock()
	if awaitingSnapshot and now - lastRequestAt < RESYNC_SECONDS then
		return
	end
	awaitingSnapshot = true
	lastRequestAt = now
	NetworkBridge.GetRemoteEvent(MovePresentationTypes.Network.RemoteNames.Request):FireServer()
end

local function preloadChanged(moveIds: { string }): ()
	local fresh: { PreloadEntry } = {}
	for _, moveId in moveIds do
		local presentation = state.Entries[moveId]
		if presentation then
			for _, entry in entriesFor(moveId, presentation) do
				if not preloaded[entry.AssetId] then
					preloaded[entry.AssetId] = true
					table.insert(fresh, entry)
				end
			end
		end
	end
	if #fresh > 0 and preloader then
		(preloader :: ({ PreloadEntry }) -> ())(fresh)
	end
end

-- Applies one message and reacts to it. Exposed for specs (no remote needed).
function MovePresentationCatalog.Apply(message: MovePresentationTypes.CatalogMessage): MovePresentationTypes.ApplyResult
	local result, changed = MovePresentationTypes.ApplyCatalogMessage(state, message)
	if result == "Stale" then
		logger:debug("Catalogue delta for a version this client does not hold; resyncing", {
			held = state.Version,
			base = message.Base,
		})
		if started then
			request()
		end
		return result
	end
	if result ~= "Applied" then
		return result
	end
	if message.Kind == "Snapshot" then
		awaitingSnapshot = false
	end
	preloadChanged(changed)
	for _, listener in listeners do
		task.spawn(listener, changed)
	end
	return result
end

-- `preload` is AssetPreloader.PreloadLabelled -- see this file's header.
function MovePresentationCatalog.Start(preload: ({ PreloadEntry }) -> ()): ()
	if started then
		return
	end
	started = true
	preloader = preload
	-- Whatever the boot pass already covered is not handed over twice.
	for _, entry in MovePresentationCatalog.GetPreloadEntries() do
		preloaded[entry.AssetId] = true
	end
	NetworkBridge.GetRemoteEvent(MovePresentationTypes.Network.RemoteNames.Catalog).OnClientEvent
		:Connect(function(raw: unknown)
			if typeof(raw) == "table" then
				MovePresentationCatalog.Apply(raw :: MovePresentationTypes.CatalogMessage)
			end
		end)
	request()
	logger:debug("MovePresentationCatalog started")
end

-- Spec-only: back to an empty, unstarted catalogue.
function MovePresentationCatalog.ResetForTesting(): ()
	state = { Version = 0, Entries = {} }
	table.clear(preloaded)
	awaitingSnapshot = false
	lastRequestAt = -math.huge
end

return MovePresentationCatalog
