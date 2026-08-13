--!strict
--[[
	EmoteUnlockService.lua

	Owns: which emotes a player has unlocked, and the two ways an emote becomes unlocked beyond the
	"Default" set every profile starts with -- a direct grant (GrantEmote, for a future
	AchievementSystem/quest system/live-ops tool to call) and a random draw from a named pool
	(RollEmote, for the same future callers, plus a DevMenu-triggered test roll in a later phase --
	see this file's own RollEmote header for why its signature stays fully generic today).

	Persists exclusively through PlayerDataSystem.Transform/GetProfile (Types.PlayerProfile.
	unlockedEmoteIds) -- never a DataStore call of its own, per PlayerDataSystem.lua's "one
	serialized entry point per player's data" rule. Network-agnostic: this module creates no
	Remotes and knows nothing about RemoteEvents/RemoteFunctions -- Server/Systems/EmoteSystem.lua is
	the only caller/requirer, the same "pure service, one gated caller" split MoveRegistryManager.lua
	(pure) / MoveEditorSystem.lua (auth/IO/persistence, the only mutating caller) already establish
	for the Move Creation System.

	Every function that doesn't genuinely need a live Player is exported as a pure, Player-free
	helper (ComputeGrantOutcome/ComputeEligibleRollIds) specifically so TestEZ can exercise the
	idempotent-grant and pool-exhaustion logic directly, without a live DataStore-backed profile --
	the same "pure core, Player-keyed wrapper" split PlayerDataSystem.ApplyMutation/
	CombatSystem's own precondition checks already use for the identical reason.

	Does not own: whether a request to PLAY an already-unlocked emote is currently legal (combat
	state, movement lock, cooldown -- all Server/Systems/EmoteSystem.lua), or any Remote/RemoteEvent
	of its own.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Types = require(ReplicatedStorage.Shared.Types)
local EmoteConstants = require(ReplicatedStorage.Shared.EmoteConstants)
local EmoteRegistry = require(ReplicatedStorage.Shared.Emotes.EmoteRegistry)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerDataSystem = require(script.Parent.PlayerDataSystem)

local logger = Logger.scope("EmoteUnlockService")

local EmoteUnlockService = {}

-- Fired (player: Player, emoteId: string) on every SUCCESSFUL GrantEmote -- see GrantEmote's own
-- comment for why this exists (letting EmoteSystem push Emote_UnlockedUpdated regardless of which
-- System actually called GrantEmote/RollEmote). Same "raw BindableEvent field, callers use
-- .Event:Connect" shape PlayerDataSystem.OnProfileLoaded already establishes -- this is a single,
-- narrowly-scoped signal owned entirely by this module, not a candidate for GameplayEvents.lua's
-- cross-System registry (GameplayEvents.lua's own header: reserved for signals genuinely crossing
-- module boundaries this codebase wants centrally typed, not every BindableEvent a System exposes).
EmoteUnlockService.OnEmoteGranted = Instance.new("BindableEvent")

--
-- Pure logic -- no Player, no PlayerDataSystem call. Exported specifically for TestEZ coverage; see
-- this file's header.
--

-- Whether granting `emoteId` onto a profile already holding `unlockedEmoteIds` should succeed --
-- unknown emote id and already-owned are the two rejection reasons GrantEmote below can surface to
-- its caller, both computed here so a spec can exercise them without a live profile.
function EmoteUnlockService.ComputeGrantOutcome(
	unlockedEmoteIds: { [Types.EmoteId]: true },
	emoteId: string
): (boolean, string?)
	if not EmoteRegistry.Exists(emoteId) then
		return false, "UnknownEmote"
	end
	if unlockedEmoteIds[emoteId] then
		return false, "AlreadyOwned"
	end
	return true, nil
end

-- Every id in `pool` the given `unlockedEmoteIds` set does NOT already contain, filtered to ids that
-- still exist in the live registry (defensive: a pool naming a since-retired emote should never
-- surface it as rollable). A nil/empty pool returns an empty list rather than erroring -- RollEmote's
-- own "UnknownPool"/"PoolEmpty" distinction is made by its caller inspecting the pool itself, not by
-- this function.
function EmoteUnlockService.ComputeEligibleRollIds(
	pool: { string }?,
	unlockedEmoteIds: { [Types.EmoteId]: true }
): { string }
	local eligible: { string } = {}
	if not pool then
		return eligible
	end
	for _, id in pool do
		if EmoteRegistry.Exists(id) and not unlockedEmoteIds[id] then
			table.insert(eligible, id)
		end
	end
	return eligible
end

--
-- Player-keyed wrappers -- Studio/live-server verification only, the same already-accepted gap
-- PlayerDataSystem.spec.lua/MeridianSystem.spec.lua document for their own Player-keyed surfaces
-- (a genuinely loaded profile requires a live Player and a real DataStore round trip).
--

function EmoteUnlockService.HasUnlocked(player: Player, emoteId: string): boolean
	local profile = PlayerDataSystem.GetProfile(player)
	return profile ~= nil and profile.unlockedEmoteIds[emoteId] == true
end

function EmoteUnlockService.GetUnlockedIds(player: Player): { Types.EmoteId }
	local profile = PlayerDataSystem.GetProfile(player)
	if not profile then
		return {}
	end
	local ids: { Types.EmoteId } = {}
	for id in profile.unlockedEmoteIds do
		table.insert(ids, id)
	end
	return ids
end

-- Idempotent: granting an already-owned emote is a no-op that reports "AlreadyOwned" rather than an
-- error -- a future caller (AchievementSystem re-checking a milestone, a quest re-firing its reward
-- step) should never need to pre-check HasUnlocked itself before calling this. `source` is carried
-- for logging/auditing only; this function does not validate that `source.Type` actually matches
-- emoteId's own EmoteDefinition.Unlock -- see this file's own header on staying agnostic to WHICH
-- caller grants WHICH type, the same way CombatSystem.ApplyServerDamage doesn't validate its own
-- caller's reason for dealing damage.
function EmoteUnlockService.GrantEmote(
	player: Player,
	emoteId: string,
	source: Types.EmoteUnlockRequirement
): (boolean, string?)
	if not EmoteRegistry.Exists(emoteId) then
		return false, "UnknownEmote"
	end

	local granted = false
	local reason: string? = nil
	local transformed = PlayerDataSystem.Transform(player, function(profile)
		local ok, computedReason = EmoteUnlockService.ComputeGrantOutcome(profile.unlockedEmoteIds, emoteId)
		if ok then
			profile.unlockedEmoteIds[emoteId] = true
			granted = true
		else
			reason = computedReason
		end
	end)

	if not transformed then
		return false, "ProfileNotLoaded"
	end

	if granted then
		logger:info("Emote granted", { player = player.Name, emoteId = emoteId, sourceType = source.Type })
		-- EmoteSystem.lua is the only subscriber -- it pushes Emote_UnlockedUpdated for `player` so a
		-- grant from ANY future caller (AchievementSystem, a quest system, a live-ops tool) reaches
		-- the client immediately, without EmoteSystem needing to know which System just called
		-- GrantEmote. Fired only on a genuine grant, never for "AlreadyOwned"/"UnknownEmote" -- there
		-- is nothing new for the client to learn in either of those cases.
		EmoteUnlockService.OnEmoteGranted:Fire(player, emoteId)
	end
	return granted, reason
end

-- Picks a uniformly random NOT-yet-owned emote from EmoteConstants.RollPools[poolId] and grants it.
-- Kept fully generic (no DevMenu-specific assumptions in its signature or behavior) -- a future
-- AchievementSystem/QuestSystem must be able to call the exact same function a later DevMenu-side
-- test-roll trigger will, per this pass's own scope (that trigger is phase 2; RollEmote itself is
-- server-internal-only until then -- there is no client-facing remote for it).
function EmoteUnlockService.RollEmote(
	player: Player,
	poolId: string,
	source: Types.EmoteUnlockRequirement
): (boolean, string?, string?)
	local pool = EmoteConstants.RollPools[poolId]
	if not pool then
		return false, nil, "UnknownPool"
	end
	if #pool == 0 then
		return false, nil, "PoolEmpty"
	end

	local profile = PlayerDataSystem.GetProfile(player)
	if not profile then
		return false, nil, "ProfileNotLoaded"
	end

	local eligible = EmoteUnlockService.ComputeEligibleRollIds(pool, profile.unlockedEmoteIds)
	if #eligible == 0 then
		return false, nil, "AllOwned"
	end

	local chosenId = eligible[math.random(1, #eligible)]
	local granted, grantReason = EmoteUnlockService.GrantEmote(player, chosenId, source)
	if not granted then
		-- Not reachable in practice -- Transform never yields, so nothing can unlock `chosenId` for
		-- this player between the eligibility check above and this call -- but surfaced rather than
		-- assumed impossible, per this codebase's own defensive-decode philosophy.
		return false, nil, grantReason
	end

	logger:info("Emote rolled", { player = player.Name, poolId = poolId, emoteId = chosenId })
	return true, chosenId, nil
end

-- Ensures every EmoteRegistry entry with Unlock.Type == "Default" is present in `player`'s
-- unlockedEmoteIds -- handles an OLDER profile that predates a newly-authored Default emote (a
-- brand-new profile already gets the full set from PlayerDataSystem.CreateDefaultProfile, so this is
-- a no-op write for them). Connected to PlayerDataSystem.OnProfileLoaded in Init() below, the same
-- join-time hook MeridianSystem/RivalrySystem already use for their own "push starting state" work.
local function backfillDefaultUnlocks(player: Player): ()
	local defaults = EmoteRegistry.GetDefaultUnlockedIds()
	PlayerDataSystem.Transform(player, function(profile)
		for id in defaults do
			if not profile.unlockedEmoteIds[id] then
				profile.unlockedEmoteIds[id] = true
			end
		end
	end)
end

function EmoteUnlockService.Init(): ()
	PlayerDataSystem.OnProfileLoaded.Event:Connect(backfillDefaultUnlocks)

	-- Defensive: anyone already connected (and already profile-loaded) when this System boots --
	-- same Studio Team Create / slow-boot coverage PlayerDataSystem.Init()'s own defensive loop
	-- documents for itself.
	for _, player in Players:GetPlayers() do
		if PlayerDataSystem.IsLoaded(player) then
			backfillDefaultUnlocks(player)
		end
	end

	logger:info("EmoteUnlockService.Init() complete")
end

return EmoteUnlockService :: Types.SystemModule
