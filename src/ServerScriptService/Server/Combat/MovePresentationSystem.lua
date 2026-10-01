--!strict
--[[
	MovePresentationSystem.lua

	Owns: the client-facing CATALOGUE of per-move presentation -- MoveId -> MoveDefinition.Presentation for
	every move that authors one -- and the two remotes that carry it (MovePresentationTypes.Network).

	WHY IT EXISTS. The move registries are server-side and DataStore-backed; a client handed a MoveId by
	Attack_Started, Combat_Feedback or an Attack_Projectile launch cannot look the move up. Without this, a
	move's authored sound would have to ride every one of those payloads (and could never be preloaded
	ahead of the first hit that plays it -- MovePresentationTypes' header has the full comparison).

	WHAT IT SENDS. A Snapshot of the whole catalogue to a client that asks (Request, fired once by
	Client/FX/MovePresentationCatalog.lua at start, and again only if that client finds itself stale), and
	a Delta to every client whenever a move's EFFECTIVE block changes. Only moves with a block are in it --
	a game with no authored presentation sends an empty table once per join and nothing after. Deltas are
	coalesced per frame (a bulk edit of forty moves is one message) and diffed against what was last
	published, so a Preview that changed a move's damage and not its presentation sends nothing at all.

	WHICH MOVE A MoveId MEANS: a custom move over a Default one -- AttackCatalog's own lookup order, so the
	catalogue describes the move combat would actually throw.

	HOW IT HEARS ABOUT EDITS: MoveRegistryManager.OnChanged and DefaultMoveRegistry.OnChanged, which fire
	from the registries' own write functions -- so a Preview, a Save, a Delete, a Reset, a version restore,
	a bulk scale and the boot-time source/DataStore hydration all reach it through one seam, whichever
	System did the writing. Boot order does not matter: Init rebuilds from both registries, and anything
	written after that arrives as a change.

	PRESENTATION ONLY. Nothing here is read by a combat layer, and nothing a client sends is trusted beyond
	"please send me the snapshot" (rate-limited, no payload).

	Does not own: the schema or validation (MovePresentationTypes, MoveRegistryManager.Validate), the
	registries, or anything a client does with the catalogue (Client/FX/MovePresentation.lua).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Logger = require(ReplicatedStorage.Shared.Logger)
local MovePresentationTypes = require(ReplicatedStorage.Shared.Combat.MovePresentationTypes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)

local DefaultMoveRegistry = require(script.Parent.DefaultMoveRegistry)
local MoveRegistryManager = require(script.Parent.MoveRegistryManager)

type Presentation = MovePresentationTypes.Presentation
type CatalogMessage = MovePresentationTypes.CatalogMessage

local logger = Logger.scope("MovePresentationSystem")

local MovePresentationSystem = {}

local NETWORK = MovePresentationTypes.Network

local published: { [string]: Presentation } = {}
local digests: { [string]: string } = {}
local version = 0

local pending: { [string]: boolean } = {}
local flushScheduled = false

local catalogRemote: RemoteEvent? = nil
local limiter = RateLimiter.New(NETWORK.MaxRequestsPerSecond)
local unsubscribes: { () -> () } = {}
local initialized = false

-- The block combat's own lookup order would find for `moveId`, or nil.
local function effectivePresentation(moveId: string): Presentation?
	local move = MoveRegistryManager.Get(moveId) or DefaultMoveRegistry.Get(moveId)
	return if move then move.Presentation else nil
end

local function digestOf(presentation: Presentation): string
	local out: { string } = {}
	MoveTypes.DigestValue(out, presentation)
	return table.concat(out)
end

-- Recomputes the pending moves against what was last published. Returns the Delta to send, or nil when
-- nothing a client can see changed. Mutates the published state -- the caller must send what it returns.
local function collectDelta(): CatalogMessage?
	local upserts: { [string]: Presentation } = {}
	local removes: { string } = {}
	local any = false
	for moveId in pending do
		local presentation = effectivePresentation(moveId)
		if presentation then
			local digest = digestOf(presentation)
			if digests[moveId] ~= digest then
				digests[moveId] = digest
				published[moveId] = presentation
				upserts[moveId] = presentation
				any = true
			end
		elseif published[moveId] ~= nil then
			published[moveId] = nil
			digests[moveId] = nil
			table.insert(removes, moveId)
			any = true
		end
	end
	table.clear(pending)
	if not any then
		return nil
	end
	version += 1
	table.sort(removes)
	return {
		Kind = "Delta",
		Base = version - 1,
		Version = version,
		Entries = upserts,
		Removes = removes,
	}
end

local function flush(): ()
	flushScheduled = false
	local delta = collectDelta()
	if not delta then
		return
	end
	local remote = catalogRemote
	if remote then
		remote:FireAllClients(delta)
	end
	logger:debug("Catalogue delta", { version = delta.Version, removed = #(delta.Removes :: { string }) })
end

local function markChanged(moveId: string): ()
	pending[moveId] = true
	if not flushScheduled then
		flushScheduled = true
		-- One message per frame however many writes land in it (a bulk edit, the boot hydration).
		task.defer(flush)
	end
end

local function snapshot(): CatalogMessage
	return {
		Kind = "Snapshot",
		Version = version,
		Entries = published,
	}
end

local function onRequest(player: Player): ()
	if limiter:IsLimited(player) then
		return
	end
	local remote = catalogRemote
	if remote then
		remote:FireClient(player, snapshot())
	end
end

-- Rebuilds the whole catalogue from both registries. Used at Init; a change arriving later is a Delta.
local function rebuild(): ()
	table.clear(published)
	table.clear(digests)
	table.clear(pending)
	local seen: { [string]: boolean } = {}
	for _, move in MoveRegistryManager.List() do
		seen[move.MoveId] = true
		if move.Presentation then
			published[move.MoveId] = move.Presentation
			digests[move.MoveId] = digestOf(move.Presentation)
		end
	end
	for _, move in DefaultMoveRegistry.List() do
		if not seen[move.MoveId] and move.Presentation then
			published[move.MoveId] = move.Presentation
			digests[move.MoveId] = digestOf(move.Presentation)
		end
	end
end

function MovePresentationSystem.Init(): ()
	if initialized then
		return
	end
	initialized = true

	local remote = NetworkBridge.CreateRemoteEvent(NETWORK.RemoteNames.Catalog)
	catalogRemote = remote
	local request = NetworkBridge.CreateRemoteEvent(NETWORK.RemoteNames.Request)
	request.OnServerEvent:Connect(onRequest)
	Players.PlayerRemoving:Connect(function(player: Player)
		limiter:Clear(player)
	end)

	rebuild()
	table.insert(unsubscribes, MoveRegistryManager.OnChanged(markChanged))
	table.insert(unsubscribes, DefaultMoveRegistry.OnChanged(markChanged))
	logger:info("MovePresentationSystem initialized")
end

-- What a client asking now would be handed. Changes still pending this frame arrive as the next Delta,
-- whose Base is this snapshot's Version. Specs and diagnostics.
function MovePresentationSystem.Snapshot(): CatalogMessage
	return snapshot()
end

-- Spec-only: the next Delta the pending changes would produce, without scheduling or sending it.
function MovePresentationSystem.CollectDeltaForTesting(): CatalogMessage?
	return collectDelta()
end

-- Spec-only: marks a move changed without a registry write.
function MovePresentationSystem.MarkChangedForTesting(moveId: string): ()
	pending[moveId] = true
end

-- Spec-only: forget everything and stop listening.
function MovePresentationSystem.ResetForTesting(): ()
	for _, unsubscribe in unsubscribes do
		unsubscribe()
	end
	table.clear(unsubscribes)
	table.clear(published)
	table.clear(digests)
	table.clear(pending)
	version = 0
	flushScheduled = false
	catalogRemote = nil
	initialized = false
end

-- Spec-only: rebuild from the registries as Init would, without creating remotes.
function MovePresentationSystem.RebuildForTesting(): ()
	rebuild()
end

return MovePresentationSystem
