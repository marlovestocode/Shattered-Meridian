--!strict
--[[
	QiSystem.lua

	Owns: the live Qi resource -- current/max Qi per player, passive regen, and the Spend/Refund API
	future ability systems (ArtSystem) will call to pay a technique's cost. This is a new System,
	not yet reflected in the shared shattered-meridian-studio skill's software-architecture.md
	ownership map -- ClientState.lua's own header already documented that Qi/MaxQi were render-only
	defaults because "no System owns the Qi resource yet"; this is that System. Distinct from
	QiDeviationSystem (still a stub), which owns deviation risk/trigger/consequence and is expected
	to read Qi state through this module's public API rather than duplicating it.

	Does not own: Max Qi/regen TUNING NUMBERS -- Shared/QiConstants.lua owns every one of those, see
	that file's own header for the "edit data, not code" contract this System is built around.
	Does not own Deviation risk/consequence (QiDeviationSystem), Tier-up validation (TierSystem), or
	canonical persistence (PlayerDataSystem). Qi itself is deliberately NOT persisted -- same as
	Health/Posture, it's live combat/session state, rebuilt fresh at Max on every profile load
	rather than a permanent-progression number (meridianXp is the permanent one; see
	MeridianSystem.lua).

	Qi type: derived from PlayerProfile.faction, read live through PlayerDataSystem on every call,
	never cached -- see QiConstants.DefaultQiType's own header for why "Unbound" is the correct
	fallback for a player with no assigned faction yet, and why this automatically starts reflecting
	a real faction assignment the moment FactionManager exists, with no change needed here.

	Load timing: seeded from PlayerDataSystem.OnProfileLoaded, not Players.PlayerAdded -- a profile
	can still be mid-load (or not yet requested) when PlayerAdded fires (PlayerDataSystem.lua's own
	header), so computing a real Max Qi at that point would either block or silently use a fallback
	that's wrong for players who log in with real tier/attribute data. Also walks already-loaded
	profiles at Init() (the same defensive "GetPlayers() loop at Init()" pattern PlayerDataSystem.lua
	documents for itself) to cover a profile that finished loading before QiSystem.Init() ran.

	Replication: Progression_QiUpdated fires immediately on any Spend/Refund (an ability's Qi cost
	should feel instant), and at most once every QiConstants.PassiveSyncIntervalSeconds for pure
	passive regen -- docs/architecture/2026-08-audit.md's Tier 2.2 flagged CombatSystem's own
	per-tick passive-vitals sync as a performance problem; this System is built to not repeat it
	rather than needing the same fix retrofitted later.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Types = require(ReplicatedStorage.Shared.Types)
local Constants = require(ReplicatedStorage.Shared.Constants)
local QiConstants = require(ReplicatedStorage.Shared.QiConstants)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local GameplayEvents = require(ServerScriptService.Server.Events.GameplayEvents)
local PlayerDataSystem = require(script.Parent.PlayerDataSystem)

local logger = Logger.scope("QiSystem")

local QiSystem = {}

export type ConflictLevel = "None" | "Risky" | "Severe"

type QiState = {
	current: number,
	max: number,
	-- Cached alongside max rather than re-derived from a live profile read every Heartbeat tick --
	-- see resolveQiParams/QiSystem.RefreshFromProfile's own header for why.
	regenPerSecond: number,
	lastSyncedCurrent: number,
	lastSyncAt: number,
}

local qiStates: { [Player]: QiState } = {}
local qiUpdatedRemote: RemoteEvent? = nil

-- Pure formula, exported specifically so this System's regression tests can exercise the actual Qi
-- curve headlessly (plain numbers in, no Player/profile needed) -- the same "extract the pure math
-- so it's TestEZ-coverable" split Shared/FlightMath.lua already established in this codebase, just
-- kept as an exported function here rather than promoted to its own Shared module, since QiSystem is
-- its only caller today.
function QiSystem.ComputeMaxQi(tier: number, meridianFlow: number): number
	local clampedTier = math.clamp(math.floor(tier), 1, QiConstants.MaxTierDefined)
	local baseForTier = QiConstants.MaxQiByTier[clampedTier] or QiConstants.MaxQiByTier[1]
	local meridianFlowDelta = meridianFlow - QiConstants.BaselineMeridianFlow
	return math.max(1, baseForTier + (meridianFlowDelta * QiConstants.MaxQiPerMeridianFlowPoint))
end

-- Pure formula -- see QiSystem.ComputeMaxQi's own header for why this is exported.
function QiSystem.ComputeRegenPerSecond(meridianFlow: number): number
	local meridianFlowDelta = meridianFlow - QiConstants.BaselineMeridianFlow
	return math.max(
		0,
		QiConstants.BaseRegenPerSecond + (meridianFlowDelta * QiConstants.RegenPerSecondPerMeridianFlowPoint)
	)
end

-- Reads the player's live tier + MeridianFlow attribute through PlayerDataSystem and derives both
-- max Qi and passive regen rate from the SAME profile read -- one GetProfile call, not two. Callers
-- cache both results on QiState rather than calling this from a per-tick hot path: GetProfile is not
-- a cheap accessor (PlayerDataSystem.GetProfile:585-591 returns CopyProfile, a full deep copy -- 9
-- heap tables per call by design, see that module's own header), and max/regen only ever change on a
-- tier-up or attribute reallocation, not every frame. See QiSystem.RefreshFromProfile's own header
-- for where recompute actually happens.
local function resolveQiParams(player: Player): (number, number)
	local profile = PlayerDataSystem.GetProfile(player)
	if not profile then
		return QiConstants.MaxQiByTier[1] or 100, QiConstants.BaseRegenPerSecond
	end
	local meridianFlow = if profile.attributes
		then profile.attributes.MeridianFlow
		else QiConstants.BaselineMeridianFlow
	return QiSystem.ComputeMaxQi(profile.tier, meridianFlow), QiSystem.ComputeRegenPerSecond(meridianFlow)
end

-- Live, never-cached Qi type for `player` -- see this file's header for the fallback contract.
function QiSystem.GetQiType(player: Player): Types.Faction
	local profile = PlayerDataSystem.GetProfile(player)
	if profile and profile.faction then
		return profile.faction
	end
	return QiConstants.DefaultQiType
end

-- Symmetric lookup against QiConstants.ConflictMatrix -- sorts the two types alphabetically so
-- "Celestial,Demonic" and "Demonic,Celestial" hit the same entry without the data table needing
-- both orderings written out. A type against itself is always "None".
function QiSystem.CheckQiConflict(typeA: Types.Faction, typeB: Types.Faction): ConflictLevel
	if typeA == typeB then
		return "None"
	end
	local ordered = if typeA < typeB then typeA .. "," .. typeB else typeB .. "," .. typeA
	return QiConstants.ConflictMatrix[ordered] or "None"
end

function QiSystem.GetQi(player: Player): number
	local state = qiStates[player]
	return if state then state.current else 0
end

function QiSystem.GetMaxQi(player: Player): number
	local state = qiStates[player]
	return if state then state.max else 0
end

local function sendQiUpdate(player: Player, state: QiState, now: number): ()
	if not qiUpdatedRemote then
		return
	end
	local payload: Types.QiUpdatePayload = {
		Qi = state.current,
		MaxQi = state.max,
	}
	qiUpdatedRemote:FireClient(player, payload)
	state.lastSyncedCurrent = state.current
	state.lastSyncAt = now
end

-- Spends `amount` Qi if the player has enough; returns false and spends nothing otherwise. The
-- narrow, server-authoritative primitive every future ability cost (ArtSystem) is expected to call
-- through -- never let a client claim it already paid a Qi cost.
function QiSystem.Spend(player: Player, amount: number, reason: string?): boolean
	if typeof(amount) ~= "number" or amount <= 0 then
		return false
	end
	local state = qiStates[player]
	if not state or state.current < amount then
		return false
	end

	state.current -= amount
	logger:debug("Qi spent", { player = player.Name, amount = amount, reason = reason, remaining = state.current })
	sendQiUpdate(player, state, os.clock())
	return true
end

-- Refunds `amount` Qi, clamped to max -- for a cancelled/refunded ability cost, never for granting
-- Qi beyond what a matching Spend already took.
function QiSystem.Refund(player: Player, amount: number): ()
	if typeof(amount) ~= "number" or amount <= 0 then
		return
	end
	local state = qiStates[player]
	if not state then
		return
	end
	state.current = math.min(state.max, state.current + amount)
	sendQiUpdate(player, state, os.clock())
end

-- Recomputes max Qi and passive regen rate from the player's current profile and caches both on
-- QiState. This is the ONE place either value is ever recomputed after seeding -- called from
-- onProfileLoaded (below) and, as of TierSystem landing, from this module's own
-- GameplayEvents.OnTierChanged subscription in Init(); a future attribute-reallocation screen
-- (Constants.CharacterCreation.AttributeBudget's anticipated Attunement pass) is the remaining
-- caller this was written for. Deliberately NOT called from onHeartbeatTick: it used to be
-- (indirectly, via the old refreshMaxQi + a second resolveRegenPerSecond call), which meant every
-- player paid a full 9-table PlayerDataSystem.GetProfile deep copy TWICE, every Heartbeat tick, to
-- notice a change that in practice only a tier-up produces -- at 30 players and 60Hz that was
-- ~32,000 heap-table allocations/sec, sustained, on the server's single Heartbeat, purely to read
-- two scalars that change rarely. Safe to call for a player QiSystem hasn't seeded yet -- it's a
-- silent no-op via the qiStates lookup below, same guard QiSystem.Spend/Refund already use.
function QiSystem.RefreshFromProfile(player: Player): ()
	local state = qiStates[player]
	if not state then
		return
	end
	local newMax, newRegenPerSecond = resolveQiParams(player)
	state.regenPerSecond = newRegenPerSecond
	if newMax == state.max then
		return
	end
	-- A tier-up (or future attribute reallocation) that raises Max Qi only tops the player up to the
	-- new ceiling if they were already at their old one -- a player mid-spend-down doesn't get a
	-- free refill just because their cap moved.
	local wasFull = state.current >= state.max
	state.max = newMax
	state.current = if wasFull then newMax else math.min(state.current, newMax)
end

local function onHeartbeatTick(deltaTime: number): ()
	local now = os.clock()
	for player, state in pairs(qiStates) do
		if state.current < state.max then
			state.current = math.min(state.max, state.current + (state.regenPerSecond * deltaTime))
		end

		if
			now - state.lastSyncAt >= QiConstants.PassiveSyncIntervalSeconds
			and state.current ~= state.lastSyncedCurrent
		then
			sendQiUpdate(player, state, now)
		end
	end
end

local function onProfileLoaded(player: Player): ()
	if qiStates[player] then
		-- Already seeded (the Init()-time defensive loop below can race a live OnProfileLoaded fire
		-- for a profile that finishes loading between that loop running and this connection being
		-- made) -- never double-seed, which would stomp any Qi already spent/regenerated this session.
		return
	end
	local max, regenPerSecond = resolveQiParams(player)
	qiStates[player] = {
		current = max,
		max = max,
		regenPerSecond = regenPerSecond,
		lastSyncedCurrent = max,
		lastSyncAt = os.clock(),
	}
	logger:debug("Qi state seeded", { player = player.Name, max = max, regenPerSecond = regenPerSecond })
end

local function onPlayerRemoving(player: Player): ()
	qiStates[player] = nil
end

function QiSystem.Init(): ()
	qiStates = {}

	qiUpdatedRemote = NetworkBridge.CreateRemoteEvent(Constants.Qi.RemoteNames.QiUpdated)

	PlayerDataSystem.OnProfileLoaded.Event:Connect(onProfileLoaded)
	PlayerLifecycle.BindAllPlayers({ Scope = "QiSystem", OnPlayerRemoving = onPlayerRemoving })

	-- Defensive pass for any profile that already finished loading before this Init() ran -- same
	-- reasoning as PlayerDataSystem.Init()'s own GetPlayers() loop (Studio Team Create / a slow
	-- server boot where PlayerDataSystem, which boots earlier, already loaded someone).
	for _, player in ipairs(Players:GetPlayers()) do
		if PlayerDataSystem.IsLoaded(player) then
			onProfileLoaded(player)
		end
	end

	-- A tier-up raises the Max Qi ceiling (QiConstants.MaxQiByTier) -- this is the hook
	-- RefreshFromProfile was written for and documents itself as waiting on, now that TierSystem is
	-- more than a stub. Subscribing here rather than letting TierSystem call into this module keeps
	-- the dependency inverted the way GameplayEvents exists to allow; TierSystem knows nothing about
	-- Qi. Safe despite QiSystem.Init() running BEFORE TierSystem.Init(): GameplayEvents has no boot
	-- order (its own header), so connecting to a signal whose publisher hasn't booted yet is exactly
	-- the supported case.
	GameplayEvents.OnTierChanged(function(player: Player)
		QiSystem.RefreshFromProfile(player)
	end)

	GameplayEvents.OnHeartbeatTick(onHeartbeatTick)

	logger:info("QiSystem.Init() complete")
end

return QiSystem :: Types.SystemModule
