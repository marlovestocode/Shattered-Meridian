--!strict
--[[
	ArtSystem.lua

	Owns: a player's progress through the art trees -- which arts they have unlocked, how much
	mastery each has accrued, whether an unlock is currently earned, and the server-authoritative
	use path that charges Qi. This is the System that finally gives QiSystem a sink: Qi has had a
	Spend primitive and a tier-scaled ceiling since it landed, and until now nothing in the codebase
	called it.

	Does not own: the tree structure (ArtTreeManager), the move data an art is built on
	(MoveRegistryManager), the Qi resource itself (QiSystem owns the pool; this System only spends
	from it), the tier an unlock is gated on (TierSystem), or any tuning number (ArtConstants).

	UNLOCKED IS "HAS A MASTERY ENTRY". PlayerProfile.artMastery is a { [ArtId]: number } that has
	existed since the baseline schema, and presence of a key is what marks an art unlocked -- mastery
	0 means unlocked but never used. That avoids a second parallel "unlocked" field carrying the same
	fact. (This paragraph used to add that the whole System therefore needed no schema migration at
	all. That stopped being true when equipping landed: PlayerProfile.equippedArts is a genuinely new
	field with its own Migrations[3] entry -- see below. Unlocking still needs none.)

	EARNED, NEVER GRANTED. An unlock request is validated server-side against exactly the same
	CanUnlock rules the client uses to grey out a row -- the client's version is a rendering
	convenience with no authority. The three gates are the tree's faction, TierSystem's tier, and
	mastery on the prerequisite art, which is a gate on USE rather than time: you advance a tree by
	fighting with the form below it, the same fight-to-grow rule Meridian XP already follows.

	QI IS CHARGED BEFORE THE MOVE RESOLVES, and a refused spend refuses the whole use -- see UseArt.
	That ordering is what makes the cost real rather than cosmetic.

	EQUIPPING IS PERSISTED, AND IT IS WHAT MAKES AN ART REACHABLE. Unlocking an art earns it;
	equipping it to one of the ArtConstants.EquipSlotCount hotbar slots is what puts it under a key.
	Types.PlayerProfile.equippedArts holds that binding, so it survives a rejoin -- unlike
	Client/Combat/HotbarBindings.lua, the admin-local, session-scoped binding the Move Editor writes,
	which this replicates INTO on the client (CharacterMenuClient.lua) rather than replacing. The two
	coexist by the same last-write-wins rule that module already documents.

	CanUse vs. UseArt is a deliberate split, not a duplicate. CombatSystem asks CanUse before it
	commits a swing, so an art refused for a COMBAT reason (mid-attack, stunned, on cooldown) costs
	no Qi; UseArt is called only once the throw is actually happening, and re-checks everything
	itself rather than trusting that the caller asked first.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local ArtConstants = require(ReplicatedStorage.Shared.ArtConstants)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local RemoteHandler = require(ReplicatedStorage.Shared.RemoteHandler)
local PlayerDataSystem = require(script.Parent.PlayerDataSystem)
local QiSystem = require(script.Parent.QiSystem)
local TierSystem = require(script.Parent.TierSystem)
local ArtTreeManager = require(script.Parent.Parent.Managers.ArtTreeManager)

local logger = Logger.scope("ArtSystem")

local ArtSystem = {}

local artStateRemote: RemoteEvent? = nil
local requestRateLimiter = RateLimiter.New(ArtConstants.RequestMaxCallsPerSecond)

--
-- Reads
--

function ArtSystem.GetMastery(player: Player, artId: string): number
	local profile = PlayerDataSystem.GetProfile(player)
	if not profile then
		return 0
	end
	return profile.artMastery[artId] or 0
end

function ArtSystem.IsUnlocked(player: Player, artId: string): boolean
	local profile = PlayerDataSystem.GetProfile(player)
	if not profile then
		return false
	end
	return profile.artMastery[artId] ~= nil
end

-- Which art sits in each of this player's hotbar slots. Always a fresh table (GetProfile already
-- hands back a copy) so a caller can hold onto it without aliasing the live profile.
function ArtSystem.GetEquipped(player: Player): { [number]: string }
	local profile = PlayerDataSystem.GetProfile(player)
	if not profile then
		return {}
	end
	return profile.equippedArts
end

-- Whether `slot` is a real hotbar slot. Its own named check rather than an inline comparison because
-- both the equip path and the fire path need the identical bound, and a slot index arrives from a
-- client in both cases.
function ArtSystem.IsValidSlot(slot: number): boolean
	return typeof(slot) == "number" and slot == math.floor(slot) and slot >= 1 and slot <= ArtConstants.EquipSlotCount
end

-- Why `player` can't throw `artId` right now, or nil if they can. Deliberately does NOT spend
-- anything -- this is the question CombatSystem asks BEFORE committing a swing, so that a throw
-- refused for a combat reason (mid-attack, stunned, on cooldown) costs no Qi. UseArt below is the
-- one that charges, and it re-checks all of this itself rather than trusting that a caller asked
-- first.
function ArtSystem.CanUse(player: Player, artId: string): string?
	local move = ArtTreeManager.GetArt(artId)
	if not move then
		return "UnknownArt"
	end
	if not ArtSystem.IsUnlocked(player, artId) then
		return "NotUnlocked"
	end
	local art = move.Art :: MoveTypes.MoveArtBinding
	if art.QiCost > 0 and QiSystem.GetQi(player) < art.QiCost then
		return "NotEnoughQi"
	end
	return nil
end

-- Why `player` can't unlock `artId` right now, or nil if they can. Returns a REASON rather than a
-- bare boolean so the client can say "Tier 4 required" instead of greying a row out silently --
-- ui-ux-philosophy.md's stance on legible gating, and the same shape every other request handler in
-- this codebase already returns.
function ArtSystem.CanUnlock(player: Player, artId: string): string?
	local move = ArtTreeManager.GetArt(artId)
	if not move then
		return "UnknownArt"
	end
	local art = move.Art :: MoveTypes.MoveArtBinding

	if ArtSystem.IsUnlocked(player, artId) then
		return "AlreadyUnlocked"
	end

	local profile = PlayerDataSystem.GetProfile(player)
	if not profile then
		return "ProfileNotLoaded"
	end

	if not ArtTreeManager.IsTreeOpenTo(art.TreeId, profile.faction) then
		return "WrongFaction"
	end

	if TierSystem.GetTier(player) < art.RequiredTier then
		return "TierTooLow"
	end

	-- Node 1 is always an entry form, whatever was authored -- see MoveTypes.MoveArtBinding. This is
	-- what makes a tree impossible to author into being unreachable.
	if art.Node > 1 and art.Prerequisite ~= nil then
		if not ArtTreeManager.GetArt(art.Prerequisite) then
			-- A prerequisite pointing at a move that isn't an art (ArtTreeManager.AuditPrerequisites
			-- reports this at boot). Refuse rather than skip: a broken edit should cost an
			-- unreachable art, never a free one.
			return "BrokenPrerequisite"
		end
		if ArtSystem.GetMastery(player, art.Prerequisite) < ArtConstants.MasteryToUnlockNext then
			return "PrerequisiteNotMastered"
		end
	end

	return nil
end

--
-- Replication
--

local function buildStatePayload(player: Player): Types.ArtStatePayload
	local profile = PlayerDataSystem.GetProfile(player)
	local mastery: { [string]: number } = {}
	local equipped: { [number]: string } = {}
	if profile then
		for artId, value in pairs(profile.artMastery) do
			mastery[artId] = value
		end
		for slot, artId in pairs(profile.equippedArts) do
			equipped[slot] = artId
		end
	end
	return { Mastery = mastery, Equipped = equipped }
end

local function sendArtState(player: Player): ()
	if not artStateRemote then
		return
	end
	artStateRemote:FireClient(player, buildStatePayload(player))
end

--
-- Mutations
--

-- Unlocks `artId` for `player` if CanUnlock allows it. Returns nil on success, or the same reason
-- string CanUnlock produced -- so a caller never has to ask twice.
function ArtSystem.Unlock(player: Player, artId: string): string?
	local refusal = ArtSystem.CanUnlock(player, artId)
	if refusal then
		return refusal
	end

	local committed = PlayerDataSystem.Transform(player, function(profile)
		-- 0, not 1: unlocking is not using. Mastery is earned by fighting with the form.
		profile.artMastery[artId] = 0
	end)
	if not committed then
		return "ProfileNotLoaded"
	end

	logger:info("Art unlocked", { player = player.Name, artId = artId })
	sendArtState(player)
	return nil
end

-- Binds `artId` to `slot` for `player`, or clears the slot when artId is nil. Returns nil on
-- success, a reason string otherwise.
--
-- Only an UNLOCKED art may be equipped -- the same "earned, never granted" rule Unlock enforces,
-- applied a second time here because equip is its own client-reachable entry point and must not
-- become a back door to holding an art the player never unlocked. Clearing a slot needs no such
-- check: removing something is always legal.
--
-- Last write wins, with no cross-slot conflict rejection: the same art in two slots is harmless
-- (just redundant), which is the identical contract Client/Combat/HotbarBindings.lua already
-- documents for the client-side binding this mirrors into.
function ArtSystem.Equip(player: Player, slot: number, artId: string?): string?
	if not ArtSystem.IsValidSlot(slot) then
		return "InvalidSlot"
	end
	if artId ~= nil and not ArtSystem.IsUnlocked(player, artId) then
		return "NotUnlocked"
	end

	local committed = PlayerDataSystem.Transform(player, function(profile)
		profile.equippedArts[slot] = artId
	end)
	if not committed then
		return "ProfileNotLoaded"
	end

	logger:info("Art equipped", { player = player.Name, slot = slot, artId = artId or "<cleared>" })
	sendArtState(player)
	return nil
end

-- Credits mastery for one confirmed use. Separate from UseArt so a future path that resolves an art
-- through some other route (a scripted encounter, a bloodline-granted cast) credits mastery the same
-- way rather than reimplementing the accrual rule.
function ArtSystem.RegisterUse(player: Player, artId: string): ()
	if not ArtSystem.IsUnlocked(player, artId) then
		return
	end
	local newMastery: number? = nil
	local committed = PlayerDataSystem.Transform(player, function(profile)
		local current = profile.artMastery[artId] or 0
		profile.artMastery[artId] = current + ArtConstants.MasteryPerUse
		newMastery = profile.artMastery[artId]
	end)
	if not committed then
		return
	end
	logger:debug("Art mastery gained", { player = player.Name, artId = artId, mastery = newMastery })
	sendArtState(player)
end

-- The server-authoritative "may this player throw this art right now, and charge them for it" gate.
-- Returns nil if the use is allowed AND paid for; a reason string otherwise, in which case nothing
-- has been spent.
--
-- Order matters and is the whole point: the unlock check comes first (never charge for something
-- that was going to be refused anyway), then Qi is spent, and only a SUCCESSFUL spend credits
-- mastery. QiSystem.Spend is itself all-or-nothing -- it deducts nothing when the pool is short --
-- so there is no partial-payment state to unwind.
--
-- Does NOT throw the move. The caller (CombatSystem's custom-move path) owns execution; this System
-- owns permission and cost. Keeping those separate is what stops ArtSystem from needing to know
-- anything about hitboxes.
function ArtSystem.UseArt(player: Player, artId: string): string?
	local move = ArtTreeManager.GetArt(artId)
	if not move then
		return "UnknownArt"
	end
	if not ArtSystem.IsUnlocked(player, artId) then
		return "NotUnlocked"
	end

	local art = move.Art :: MoveTypes.MoveArtBinding
	if art.QiCost > 0 and not QiSystem.Spend(player, art.QiCost, `Art:{artId}`) then
		return "NotEnoughQi"
	end

	ArtSystem.RegisterUse(player, artId)
	return nil
end

--
-- Remotes
--

local function handleGetCatalogue(player: Player): Types.ArtCatalogueResult
	if requestRateLimiter:IsLimited(player) then
		return { Success = false, Reason = "RateLimited" }
	end

	local trees: { Types.ArtCatalogueTree } = {}
	for _, tree in ipairs(ArtTreeManager.GetTrees()) do
		local arts: { Types.ArtCatalogueEntry } = {}
		for _, move in ipairs(ArtTreeManager.GetArtsInTree(tree.TreeId)) do
			local art = move.Art :: MoveTypes.MoveArtBinding
			table.insert(arts, {
				ArtId = move.MoveId,
				DisplayName = move.DisplayName,
				Node = art.Node,
				QiCost = art.QiCost,
				RequiredTier = art.RequiredTier,
				Prerequisite = art.Prerequisite,
				Unlocked = ArtSystem.IsUnlocked(player, move.MoveId),
				-- The refusal reason travels with the row so the UI never has to re-derive the rules
				-- -- and so the client's rendering can't drift from the server's actual gate.
				LockedReason = ArtSystem.CanUnlock(player, move.MoveId),
			})
		end
		table.insert(trees, {
			TreeId = tree.TreeId,
			DisplayName = tree.DisplayName,
			Faction = tree.Faction,
			Description = tree.Description,
			Arts = arts,
		})
	end

	return { Success = true, Trees = trees }
end

local function handleUnlockArt(player: Player, rawArtId: unknown): Types.ArtActionResult
	if requestRateLimiter:IsLimited(player) then
		return { Success = false, Reason = "RateLimited" }
	end
	if typeof(rawArtId) ~= "string" then
		return { Success = false, Reason = "InvalidArtId" }
	end

	local refusal = ArtSystem.Unlock(player, rawArtId :: string)
	if refusal then
		return { Success = false, Reason = refusal }
	end
	return { Success = true }
end

local function handleEquipArt(player: Player, rawSlot: unknown, rawArtId: unknown): Types.ArtActionResult
	if requestRateLimiter:IsLimited(player) then
		return { Success = false, Reason = "RateLimited" }
	end
	if typeof(rawSlot) ~= "number" then
		return { Success = false, Reason = "InvalidSlot" }
	end
	-- nil is the legitimate "clear this slot" payload; anything else non-string is malformed.
	if rawArtId ~= nil and typeof(rawArtId) ~= "string" then
		return { Success = false, Reason = "InvalidArtId" }
	end

	local refusal = ArtSystem.Equip(player, rawSlot :: number, rawArtId :: string?)
	if refusal then
		return { Success = false, Reason = refusal }
	end
	return { Success = true }
end

local function onProfileLoaded(player: Player): ()
	sendArtState(player)
end

function ArtSystem.Init(): ()
	artStateRemote = NetworkBridge.CreateRemoteEvent(ArtConstants.RemoteNames.ArtStateUpdated)

	local catalogueRemote = NetworkBridge.CreateRemoteFunction(ArtConstants.RemoteNames.GetArtCatalogue)
	catalogueRemote.OnServerInvoke = RemoteHandler.WrapInvoke(
		logger,
		"GetArtCatalogue",
		{ Success = false, Reason = "InternalError" } :: Types.ArtCatalogueResult,
		handleGetCatalogue
	)

	local unlockRemote = NetworkBridge.CreateRemoteFunction(ArtConstants.RemoteNames.UnlockArt)
	unlockRemote.OnServerInvoke = RemoteHandler.WrapInvoke(
		logger,
		"UnlockArt",
		{ Success = false, Reason = "InternalError" } :: Types.ArtActionResult,
		handleUnlockArt
	)

	-- A RemoteFunction, not a fire-and-forget RemoteEvent, for the same reason UnlockArt is one: the
	-- panel has to be able to say WHY an equip was refused. A silently-ignored equip would leave the
	-- client showing an art in a slot the server never accepted.
	local equipRemote = NetworkBridge.CreateRemoteFunction(ArtConstants.RemoteNames.EquipArt)
	equipRemote.OnServerInvoke = RemoteHandler.WrapInvoke(
		logger,
		"EquipArt",
		{ Success = false, Reason = "InternalError" } :: Types.ArtActionResult,
		handleEquipArt
	)

	PlayerDataSystem.OnProfileLoaded.Event:Connect(onProfileLoaded)
	PlayerLifecycle.BindAllPlayers({
		Scope = "ArtSystem",
		OnPlayerRemoving = function(player: Player)
			requestRateLimiter:Clear(player)
		end,
	})

	-- Defensive pass for a profile that loaded before this Init() ran -- same reasoning
	-- QiSystem.Init() and TierSystem.Init() both document for their own GetPlayers() loops.
	for _, player in ipairs(Players:GetPlayers()) do
		if PlayerDataSystem.IsLoaded(player) then
			onProfileLoaded(player)
		end
	end

	logger:info("ArtSystem.Init() complete")
end

return ArtSystem :: Types.SystemModule
