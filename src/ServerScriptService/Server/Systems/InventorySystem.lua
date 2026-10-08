--!strict
--[[
	InventorySystem.lua

	Owns: every player's inventory -- the ONE writer of Types.PlayerProfile.inventory. Weapons a player has
	taken up and gathered resources they are carrying are both entries in it; nothing else in the game keeps
	a private list of what a player holds. docs/design/inventory.md is the blueprint this implements
	(phase 1).

	SERVER-AUTHORITATIVE, INTENT-ONLY. The client is sent a full snapshot and can ask for two things: Discard,
	naming an item and an amount, and Sync, which only asks for the snapshot again (a client that booted after
	the profile loaded missed the first push). Every check -- the item exists, is discardable, is held in that
	quantity, the caller is not flooding the remote -- is made here regardless of what the client believes.
	There is no remote that carries a result, a count to set, or a slot to move something to.

	EVERY WRITE IS A PlayerDataSystem.Transform. That is what makes persistence free and correct: the dirty
	flag, the 180s autosave, the PlayerRemoving / BindToClose saves, the cross-server session lock and the
	WriteGeneration backstop all apply to an inventory change exactly as they do to a tier-up. This module
	owns no DataStore code and must never grow any.

	THE RULES ARE InventoryModel's, NOT THIS FILE'S. Stack sizes, slot limits, partial adds and the defensive
	decode are pure maths in Shared/Inventory/InventoryModel.lua, exercised headlessly. This file adds only
	what needs a Player: the profile, the remotes, the events and the roster check below.

	THE ROSTER CHECK. A weapon item ("Weapon/<id>") is only real while WeaponRoster knows the id, and Fists
	are never an item at all (they are always in hand -- WeaponInventorySystem's header). A held id that
	fails that check is an ORPHAN: kept in the record, invisible to every listing and every limit here.
	Deleting a player's weapon because a model was renamed in Studio cannot be undone; hiding it can.

	PARTIAL ADDS, NEVER SILENT LOSS. Add reports how many units went in. A gather is capped to what fits and
	a blimp unload only takes what there is room for, so a caller never has to guess where the remainder
	went.

	SNAPSHOTS ARE COALESCED. Many mutations in one frame (a deposit debits two resources, a pickup adds an
	item) push ONE snapshot, deferred to the end of the frame, with a monotonic Revision so a client can
	drop one that arrives out of order.

	Does not own: what an item is (ItemCatalog), the capacity arithmetic (InventoryModel), what is in a
	player's hand (WeaponInventorySystem), the carried-resource HUD readout (ResourceGatheringSystem, which
	listens to OnChanged), or how any of it is drawn (UI/Screens/Inventory).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CallbackList = require(ReplicatedStorage.Shared.CallbackList)
local InventoryConstants = require(ReplicatedStorage.Shared.Inventory.InventoryConstants)
local InventoryModel = require(ReplicatedStorage.Shared.Inventory.InventoryModel)
local ItemCatalog = require(ReplicatedStorage.Shared.Inventory.ItemCatalog)
local Logger = require(ReplicatedStorage.Shared.Logger)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local RemoteHandler = require(ReplicatedStorage.Shared.RemoteHandler)
local Types = require(ReplicatedStorage.Shared.Types)
local WeaponRoster = require(ReplicatedStorage.Shared.Combat.WeaponRoster)

local PlayerDataSystem = require(script.Parent.PlayerDataSystem)

local logger = Logger.scope("InventorySystem")

type ActionResult = InventoryConstants.ActionResult
type SnapshotPayload = InventoryConstants.SnapshotPayload

local InventorySystem = {}

-- Fired (player, itemId, newCount) after an item's count changed for any reason. SYNCHRONOUS, after the
-- profile write, so a subscriber reads the new truth.
local onChanged: CallbackList.CallbackList<Player, string, number> =
	CallbackList.New(logger, "InventorySystem.OnChanged")
-- Fired (player) once that player's inventory is readable (profile loaded). The catch-up edge for any
-- System that mirrors the inventory.
local onLoaded: CallbackList.CallbackList<Player> = CallbackList.New(logger, "InventorySystem.OnLoaded")

InventorySystem.OnChanged = onChanged
InventorySystem.OnLoaded = onLoaded

local started = false
local snapshotRemote: RemoteEvent? = nil
local actionLimiter = RateLimiter.New(InventoryConstants.Network.MaxActionsPerSecondPerPlayer)
local revisions: { [Player]: number } = {}
local pushPending: { [Player]: boolean } = {}

-- The item rules this server applies. Catalog first; then the weapon-only roster check described in the
-- header. Resolved at CALL time, so a roster that finishes starting after this module loads is honoured.
local function resolve(itemId: string): ItemCatalog.ItemDef?
	local def = ItemCatalog.Resolve(itemId)
	if def == nil then
		return nil
	end
	local weaponId = def.WeaponId
	if weaponId ~= nil and (weaponId == WeaponRoster.FISTS_ID or not WeaponRoster.Has(weaponId)) then
		return nil
	end
	return def
end

local function slotLimit(section: string): number
	local def = InventoryConstants.SectionById[section]
	return if def then def.Slots else 0
end

local context: InventoryModel.Context = {
	Resolve = resolve,
	SlotLimit = slotLimit,
}

-- Building blocks -----------------------------------------------------------------------------------

-- Whether `player` has a readable inventory.
function InventorySystem.IsLoaded(player: Player): boolean
	return PlayerDataSystem.IsLoaded(player)
end

-- A COPY of the player's inventory, or nil if their profile is not loaded. Reading never hands out the live
-- table, for the same reason PlayerDataSystem.GetProfile does not.
local function readState(player: Player): InventoryModel.State?
	local profile = PlayerDataSystem.GetProfile(player)
	if not profile then
		return nil
	end
	return profile.inventory
end

local function isWhole(value: number): boolean
	return value == value and value >= 1 and value == math.floor(value) and value < math.huge
end

-- Snapshots -----------------------------------------------------------------------------------------

-- The full picture the owning client renders: every section, its slot use against its limit, and its
-- recognised items in acquisition order. nil if the profile is not loaded. Does NOT advance the revision
-- (only a push does), so building one for a spec or a log is side-effect free.
function InventorySystem.BuildSnapshot(player: Player): SnapshotPayload?
	local state = readState(player)
	if not state then
		return nil
	end
	local sections: { InventoryConstants.SnapshotSection } = {}
	for _, section in InventoryConstants.Sections do
		local entries: { InventoryConstants.SnapshotEntry } = {}
		for _, itemId in InventoryModel.OwnedIds(state, context, section.Id) do
			table.insert(entries, { ItemId = itemId, Count = state.Items[itemId] })
		end
		table.insert(sections, {
			Id = section.Id,
			Used = InventoryModel.SlotsUsed(state, context, section.Id),
			Limit = section.Slots,
			Entries = entries,
		})
	end
	return { Revision = revisions[player] or 0, Sections = sections }
end

local function pushNow(player: Player): ()
	local remote = snapshotRemote
	if remote == nil or player.Parent == nil then
		return
	end
	local nextRevision = (revisions[player] or 0) + 1
	revisions[player] = nextRevision
	local snapshot = InventorySystem.BuildSnapshot(player)
	if snapshot then
		remote:FireClient(player, snapshot)
	end
end

-- Many changes in a frame, one push. Does nothing until Init has created the remote (a spec, or a call
-- during boot), so a mutation is never blocked on the network layer.
local function schedulePush(player: Player): ()
	if snapshotRemote == nil or pushPending[player] then
		return
	end
	pushPending[player] = true
	task.defer(function()
		pushPending[player] = nil
		pushNow(player)
	end)
end

-- Public API ----------------------------------------------------------------------------------------

function InventorySystem.Count(player: Player, itemId: string): number
	local state = readState(player)
	return if state then InventoryModel.Count(state, itemId) else 0
end

function InventorySystem.Has(player: Player, itemId: string): boolean
	return InventorySystem.Count(player, itemId) > 0
end

-- How many more units of `itemId` this player could take right now (their carry cap and section room both
-- applied). 0 for an unknown item or an unloaded profile.
function InventorySystem.RoomFor(player: Player, itemId: string): number
	local state = readState(player)
	return if state then InventoryModel.RoomFor(state, context, itemId) else 0
end

-- The ids this player holds that the server recognises, in acquisition order, optionally for one section.
function InventorySystem.OwnedIds(player: Player, section: string?): { string }
	local state = readState(player)
	return if state then InventoryModel.OwnedIds(state, context, section) else {}
end

-- Adds up to `count` units. Returns (added, reason): see InventoryModel.Add, plus "ProfileNotLoaded". A
-- return of 0 changed nothing and fired nothing.
function InventorySystem.Add(player: Player, itemId: string, count: number): (number, string?)
	local added = 0
	local reason: string? = nil
	local after = 0
	local applied = PlayerDataSystem.Transform(player, function(profile)
		added, reason = InventoryModel.Add(profile.inventory, context, itemId, count)
		after = InventoryModel.Count(profile.inventory, itemId)
	end)
	if not applied then
		return 0, "ProfileNotLoaded"
	end
	if added > 0 then
		schedulePush(player)
		onChanged:Fire(player, itemId, after)
	end
	return added, reason
end

-- Removes up to `count` units; returns how many were removed. Allowed on an orphan (an admin has to be
-- able to clear one). A return of 0 changed nothing and fired nothing.
function InventorySystem.Remove(player: Player, itemId: string, count: number): number
	local removed = 0
	local after = 0
	local applied = PlayerDataSystem.Transform(player, function(profile)
		removed = InventoryModel.Remove(profile.inventory, itemId, count)
		after = InventoryModel.Count(profile.inventory, itemId)
	end)
	if not applied then
		return 0
	end
	if removed > 0 then
		schedulePush(player)
		onChanged:Fire(player, itemId, after)
	end
	return removed
end

-- The player destroys some of what they hold. Every refusal is a reason CODE the client words. A request
-- for more than is held discards what there is rather than failing -- the player's intent was "get rid of
-- it", and a stale count on their screen is not a reason to make them click twice.
function InventorySystem.Discard(player: Player, itemId: string, count: number): ActionResult
	if
		typeof(itemId) ~= "string"
		or #itemId == 0
		or #itemId > InventoryConstants.MaxItemIdLength
		or typeof(count) ~= "number"
		or not isWhole(count)
	then
		return { Success = false, Reason = "BadRequest" }
	end
	if not PlayerDataSystem.IsLoaded(player) then
		return { Success = false, Reason = "ProfileNotLoaded" }
	end
	local def = resolve(itemId)
	if def == nil then
		return { Success = false, Reason = "UnknownItem" }
	end
	if not def.Discardable then
		return { Success = false, Reason = "NotDiscardable" }
	end
	local held = InventorySystem.Count(player, itemId)
	if held <= 0 then
		return { Success = false, Reason = "NotOwned" }
	end
	local removed = InventorySystem.Remove(player, itemId, math.min(count, held))
	if removed <= 0 then
		return { Success = false, Reason = "InternalError" }
	end
	logger:info("Item discarded", { player = player.Name, itemId = itemId, removed = removed })
	return { Success = true, Removed = removed }
end

-- Remote --------------------------------------------------------------------------------------------

local function handleAction(player: Player, action: unknown, itemId: unknown, count: unknown): ActionResult
	if actionLimiter:IsLimited(player) then
		return { Success = false, Reason = "RateLimited" }
	end
	if action == "Sync" then
		if not PlayerDataSystem.IsLoaded(player) then
			return { Success = false, Reason = "ProfileNotLoaded" }
		end
		schedulePush(player)
		return { Success = true }
	end
	if action ~= "Discard" or typeof(itemId) ~= "string" or typeof(count) ~= "number" then
		return { Success = false, Reason = "BadRequest" }
	end
	return InventorySystem.Discard(player, itemId, count)
end

local function onProfileLoaded(player: Player): ()
	onLoaded:Fire(player)
	schedulePush(player)
end

function InventorySystem.Init(): ()
	if started then
		return
	end
	started = true

	snapshotRemote = NetworkBridge.CreateRemoteEvent(InventoryConstants.RemoteNames.Snapshot)
	local actionRemote = NetworkBridge.CreateRemoteFunction(InventoryConstants.RemoteNames.Action)
	actionRemote.OnServerInvoke = RemoteHandler.WrapInvoke(
		logger,
		InventoryConstants.RemoteNames.Action,
		{ Success = false, Reason = "InternalError" } :: ActionResult,
		handleAction
	)

	-- The profile-loaded edge is PlayerDataSystem's own "safe to read" signal; a player whose profile
	-- finished loading before this Init ran is caught by the sweep below.
	PlayerDataSystem.OnProfileLoaded.Event:Connect(onProfileLoaded)
	for _, player in Players:GetPlayers() do
		if PlayerDataSystem.IsLoaded(player) then
			onProfileLoaded(player)
		end
	end

	PlayerLifecycle.BindAllPlayers({
		Scope = "InventorySystem",
		OnPlayerRemoving = function(player: Player)
			actionLimiter:Clear(player)
			revisions[player] = nil
			pushPending[player] = nil
		end,
	})

	logger:info("InventorySystem.Init() complete")
end

-- Spec-only, so one case cannot serve another its subscribers or revisions.
function InventorySystem.Reset(): ()
	onChanged:Clear()
	onLoaded:Clear()
	table.clear(revisions)
	table.clear(pushPending)
	snapshotRemote = nil
	started = false
end

return InventorySystem :: Types.SystemModule & typeof(InventorySystem)
