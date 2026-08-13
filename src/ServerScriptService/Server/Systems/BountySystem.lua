--!strict
--[[
	BountySystem.lua

	Owns: Notoriety bounties -- the server-placed mark that appears on a player who is on a kill
	streak, and the Meridian XP payout to whoever ends that streak. Part of
	software-architecture.md's meta-progression social/competitive systems, pairing with
	RivalrySystem.

	Does not own: rivalry standing between specific players (RivalrySystem), the Meridian XP grant
	itself (MeridianSystem.AwardMeridianXP is called here; this System never touches a profile or a
	DataStore directly), the tier a reward scales against (TierSystem.GetTier), or any tuning number
	(Shared/BountyConstants.lua owns every one -- see its own dynamic-tuning contract).

	SERVER-PLACED ONLY -- there is no placement remote, and adding one would be a design change, not
	a feature completion. BountyConstants.lua's header carries the full reasoning (it serves the
	"visible counter to a snowballing player" purpose player-initiated placement structurally can't,
	it has no collusion vector, and it needs no currency). The short version for anyone reading here
	first: the ONLY way a bounty comes into existence is registerKill below deciding a player's
	CURRENT streak crossed BountyConstants.NotorietyStreakThreshold, and the ONLY way one pays out is
	a GameplayEvents-confirmed kill of that exact player by someone else.

	CLAIM VERIFICATION. Unchanged in spirit from the contract docs/architecture/2026-08-audit.md
	section 3.1 established, and now structurally stronger: there is no claimer argument reachable
	from a client at all. ClaimBounty resolves its claimer from the server-confirmed `killer` of a
	real PvP kill and nothing else. The two public remotes are both read-only (a board query and a
	board broadcast) plus one targeted notification -- none of them accepts an identity, an amount,
	or a bounty id from the client.

	NO PLAYER REFERENCES OUTLIVE THE PLAYER. Both keyed tables hold live Player instances, and both
	are scrubbed in ClearPlayerReferences on Players.PlayerRemoving. A claimed bounty is REMOVED
	rather than kept with a claimedBy field -- that field was the audit's own section 3.6.2 retention
	finding, and a consumed bounty has nothing left to describe. The wire payload carries the
	claimer's name/UserId for display; nothing here retains the instance.

	IDEMPOTENT Init(). Init() disconnects anything a previous Init() connected before subscribing
	again. Every other System here connects once and never re-Inits in production, and that stays
	true -- but this System's own regression spec calls Init() repeatedly to get a clean state
	between cases, and with streak tracking a duplicated OnPlayerKilled subscription doesn't just
	waste work, it counts every kill twice and silently corrupts the thing under test.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Types = require(ReplicatedStorage.Shared.Types)
local BountyConstants = require(ReplicatedStorage.Shared.BountyConstants)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local Logger = require(ReplicatedStorage.Shared.Logger)
local GameplayEvents = require(ServerScriptService.Server.Events.GameplayEvents)
local MeridianSystem = require(script.Parent.MeridianSystem)
local TierSystem = require(script.Parent.TierSystem)

local logger = Logger.scope("BountySystem")

local BountySystem = {}

export type BountyState = {
	bountyId: string,
	target: Player,
	targetName: string,
	targetUserId: number,
	-- os.clock() at placement -- server-relative, used only for expiry. Deliberately not replicated:
	-- it means nothing on a client, which has no shared origin for it.
	placedAt: number,
	-- The streak that earned the mark, and the tier the target held when the reward was last
	-- recomputed. Both are re-read on every further kill (see refreshBounty) so a marked player who
	-- keeps winning becomes worth more, rather than being priced once and left stale.
	streak: number,
	targetTier: number,
	reward: number,
}

local activeBountyByTarget: { [Player]: BountyState } = {}
local killStreaks: { [Player]: number } = {}
local nextBountyId = 1
local lastExpirySweepAt = 0

local boardUpdatedRemote: RemoteEvent? = nil
local markedChangedRemote: RemoteEvent? = nil
local queryRateLimiter = RateLimiter.New(BountyConstants.QueryMaxCallsPerSecond)

-- Every connection this System owns, so Init() can tear down a previous Init()'s subscriptions --
-- see this file's header on why that matters here specifically.
local connections: { RBXScriptConnection } = {}

--
-- Pure reward math. Plain numbers in, one number out -- no Player, no profile -- so the real payout
-- curve is exercised headlessly by this System's spec rather than a reimplementation of it, the same
-- split TierSystem.ComputeTierForXP and QiSystem.ComputeMaxQi already use.
--

-- Meridian XP a claim on a target with this streak and tier pays out. Kills BELOW the threshold
-- contribute nothing (a bounty doesn't exist yet at that point), so the streak term counts only the
-- kills past it -- meaning a freshly-marked player is worth Base + tier, not Base + three kills.
function BountySystem.ComputeReward(streak: number, targetTier: number): number
	local safeStreak = if typeof(streak) == "number" and streak == streak then streak else 0
	local safeTier = if typeof(targetTier) == "number" and targetTier == targetTier then targetTier else 1
	local killsPastThreshold = math.max(0, math.floor(safeStreak) - BountyConstants.NotorietyStreakThreshold)
	local raw = BountyConstants.BaseReward
		+ (killsPastThreshold * BountyConstants.PerStreakKillReward)
		+ (math.max(1, math.floor(safeTier)) * BountyConstants.PerTargetTierReward)
	return math.min(BountyConstants.MaxReward, math.floor(raw))
end

--
-- Reads
--

function BountySystem.GetKillStreak(player: Player): number
	return killStreaks[player] or 0
end

function BountySystem.GetActiveBounty(player: Player): BountyState?
	return activeBountyByTarget[player]
end

function BountySystem.IsMarked(player: Player): boolean
	return activeBountyByTarget[player] ~= nil
end

-- Wire shape for one board row. Carries the target's NAME and UserId rather than the Player
-- instance, both because a remote can't usefully carry an instance to a client that may not have it
-- and because nothing client-side should be handed a reference it could retain.
local function toBoardEntry(state: BountyState): Types.BountyBoardEntry
	return {
		BountyId = state.bountyId,
		TargetName = state.targetName,
		TargetUserId = state.targetUserId,
		TargetTier = state.targetTier,
		Streak = state.streak,
		Reward = state.reward,
	}
end

-- Highest-reward first, so the board's top row is the biggest problem on the server -- the one piece
-- of ordering the UI should never have to decide for itself. Capped at
-- BountyConstants.MaxBoardEntries.
function BountySystem.ListActiveBounties(): { Types.BountyBoardEntry }
	local entries: { Types.BountyBoardEntry } = {}
	for _, state in pairs(activeBountyByTarget) do
		table.insert(entries, toBoardEntry(state))
	end
	table.sort(entries, function(a, b)
		if a.Reward == b.Reward then
			return a.BountyId < b.BountyId
		end
		return a.Reward > b.Reward
	end)
	while #entries > BountyConstants.MaxBoardEntries do
		table.remove(entries)
	end
	return entries
end

--
-- Replication
--

-- Broadcast to every client, but ONLY when the board actually changed -- a placement, a claim, or an
-- expiry. This is not the unfiltered per-event FireAllClients shape docs/architecture/2026-08-audit
-- .md's Tier 2.1 flagged on ParryWindowOpened (which fires on every parry attempt server-wide): a
-- board change happens at most once per streak-crossing or streak-ending kill, which is orders of
-- magnitude rarer, and the board is genuinely global information every player is meant to see. If a
-- relevance-filtering pass ever lands for 2.1, this does not need to be folded into it.
local function broadcastBoard(): ()
	if not boardUpdatedRemote then
		return
	end
	local payload: Types.BountyBoardUpdatePayload = { Entries = BountySystem.ListActiveBounties() }
	boardUpdatedRemote:FireAllClients(payload)
end

-- Targeted at the marked player alone. Being hunted is information the target needs and the rest of
-- the server already gets from the board broadcast -- but a client should never have to scan a
-- global list for its own name to discover its own state, and doing so would make "am I marked"
-- depend on the target happening to fit inside MaxBoardEntries.
local function sendMarkedState(player: Player, state: BountyState?): ()
	if not markedChangedRemote then
		return
	end
	local payload: Types.BountyMarkedPayload = {
		Marked = state ~= nil,
		Reward = if state then state.reward else nil,
		Streak = if state then state.streak else nil,
	}
	markedChangedRemote:FireClient(player, payload)
end

--
-- Placement / claim
--

local function placeBounty(target: Player, streak: number): BountyState
	local bountyId = string.format("bounty_%d", nextBountyId)
	nextBountyId += 1

	local targetTier = TierSystem.GetTier(target)
	local state: BountyState = {
		bountyId = bountyId,
		target = target,
		targetName = target.Name,
		targetUserId = target.UserId,
		placedAt = os.clock(),
		streak = streak,
		targetTier = targetTier,
		reward = BountySystem.ComputeReward(streak, targetTier),
	}
	activeBountyByTarget[target] = state

	logger:info("Notoriety bounty placed", {
		bountyId = bountyId,
		target = target.Name,
		streak = streak,
		targetTier = targetTier,
		reward = state.reward,
	})
	return state
end

-- Re-prices an existing bounty as its target keeps winning. Tier is re-read too, not just the
-- streak: a marked player can tier up mid-run (their own kills feed Meridian XP), and a reward
-- frozen at the tier they held when first marked would understate them from that point on.
local function refreshBounty(state: BountyState, streak: number): ()
	state.streak = streak
	state.targetTier = TierSystem.GetTier(state.target)
	state.reward = BountySystem.ComputeReward(streak, state.targetTier)
end

-- Removes `target`'s bounty, if any, and tells them they're clear. `reason` is for the log only.
-- Returns the removed state so a caller that needs its reward/streak can read them after removal.
local function clearBounty(target: Player, reason: string): BountyState?
	local state = activeBountyByTarget[target]
	if not state then
		return nil
	end
	activeBountyByTarget[target] = nil
	logger:info("Bounty cleared", { bountyId = state.bountyId, target = state.targetName, reason = reason })
	sendMarkedState(target, nil)
	return state
end

-- Pays `claimer` for ending `target`'s run. Returns the Meridian XP actually awarded, or nil if
-- there was no bounty to claim. The award goes through MeridianSystem.AwardMeridianXP -- the same
-- grant primitive every other XP source uses, so a bounty payout replicates, persists, and feeds
-- TierSystem's promotion check exactly like an ordinary kill's XP does, with no parallel path.
function BountySystem.ClaimBounty(target: Player, claimer: Player): number?
	local state = activeBountyByTarget[target]
	if not state then
		return nil
	end
	if claimer == target then
		-- Nothing in the kill path should produce this (CombatSystem doesn't attribute a suicide to
		-- the victim as killer), but a self-claim would be a free payout for dying, so it's refused
		-- here rather than trusted not to happen upstream.
		logger:warn("Self-claim refused", { bountyId = state.bountyId, target = target.Name })
		return nil
	end

	local reward = state.reward
	clearBounty(target, "claimed")

	local awarded = MeridianSystem.AwardMeridianXP(claimer, reward, "BountyClaim")
	logger:info("Bounty claimed", {
		bountyId = state.bountyId,
		target = target.Name,
		claimer = claimer.Name,
		reward = reward,
		awarded = awarded,
	})
	-- Reported even if AwardMeridianXP returned false (an unloaded claimer profile). The bounty is
	-- genuinely gone either way -- the target's run ended -- and leaving it on the board because the
	-- payout failed would let the next killer claim the same run twice.
	return reward
end

-- The whole Notoriety lifecycle for one confirmed death, in the order it has to happen. `killer` is
-- nil for a death CombatSystem did not attribute to anyone (a fall, the void) -- that case still
-- ends the victim's run and still clears any mark they were carrying, because the streak measures
-- staying alive while winning and they did not. Handling nil here rather than in Init()'s
-- subscription is what makes the unattributed path reachable from a headless spec.
--
-- Exported so the spec can drive kills directly with test doubles: GameplayEvents is a BindableEvent,
-- which deep-copies plain-table arguments across Fire(), so a double would arrive as a different
-- table than the one the spec holds and could never match as a table key. Real Player Instances
-- cross a BindableEvent by reference, so that is an artifact of the double, not of production.
function BountySystem.RegisterKill(killer: Player?, victim: Player): ()
	if killer == victim then
		-- Covers a self-kill. A nil killer can never equal a real victim, so the unattributed path
		-- below is unaffected by this guard.
		return
	end

	local boardChanged = false

	-- 1. Resolve the victim's own mark first, while it still exists -- paid out if someone earned it,
	--    simply dropped if nobody did.
	if killer ~= nil then
		if BountySystem.ClaimBounty(victim, killer) ~= nil then
			boardChanged = true
		end
	elseif clearBounty(victim, "died unattributed") ~= nil then
		boardChanged = true
	end

	-- 2. The victim's run is over regardless of whether they were marked.
	killStreaks[victim] = 0

	-- 3. The killer's run grows -- and may itself cross the threshold. A player who claims a bounty
	--    is, by that same kill, one step closer to carrying one.
	if killer ~= nil then
		local killerStreak = (killStreaks[killer] or 0) + 1
		killStreaks[killer] = killerStreak

		if killerStreak >= BountyConstants.NotorietyStreakThreshold then
			local existing = activeBountyByTarget[killer]
			if existing then
				refreshBounty(existing, killerStreak)
				sendMarkedState(killer, existing)
			else
				sendMarkedState(killer, placeBounty(killer, killerStreak))
			end
			boardChanged = true
		end
	end

	-- Only when the board genuinely changed -- a placement, a re-pricing, a claim, or a mark dropped.
	-- An ordinary kill between two unmarked players changes nothing anyone can see and must not cost
	-- a server-wide broadcast; that distinction is the whole reason this remote isn't the
	-- fire-on-every-event shape the audit's Tier 2.1 flagged (see broadcastBoard's own header).
	if boardChanged then
		broadcastBoard()
	end
end

-- Drops every reference to a departing player -- their own bounty and their streak. A player who
-- leaves while marked takes the bounty with them: it describes a run in progress, and a run ends
-- when the runner logs off. Exported (not local) so the spec can exercise it with a plain-table
-- double, the same reasoning RivalrySystem.ClearPlayerReferences documents for itself.
function BountySystem.ClearPlayerReferences(departingPlayer: Player): ()
	if activeBountyByTarget[departingPlayer] then
		activeBountyByTarget[departingPlayer] = nil
		logger:info("Bounty cleared", { target = departingPlayer.Name, reason = "target left" })
		broadcastBoard()
	end
	killStreaks[departingPlayer] = nil
	queryRateLimiter:Clear(departingPlayer)
end

-- Backstop for a marked player who stays online but stops fighting -- see
-- BountyConstants.ExpirySeconds. Rides the shared heartbeat rather than its own connection, and does
-- real work at most once per ExpirySweepIntervalSeconds.
local function onHeartbeatTick(): ()
	local now = os.clock()
	if now - lastExpirySweepAt < BountyConstants.ExpirySweepIntervalSeconds then
		return
	end
	lastExpirySweepAt = now

	local expired: { Player } = {}
	for target, state in pairs(activeBountyByTarget) do
		if now - state.placedAt >= BountyConstants.ExpirySeconds then
			table.insert(expired, target)
		end
	end
	if #expired == 0 then
		return
	end
	for _, target in ipairs(expired) do
		clearBounty(target, "expired")
		killStreaks[target] = 0
	end
	broadcastBoard()
end

-- Drops every bounty and streak this System is holding, without touching its remotes or
-- subscriptions. Split out of Init() rather than inlined there because it is genuinely two different
-- jobs -- "forget the current state" and "wire up to the world" -- and this System's regression spec
-- needs the first without the second: with no Init(), the remotes stay nil, sendMarkedState and
-- broadcastBoard take the nil guards they already carry for pre-Init calls, and the streak/placement/
-- claim logic is exercisable against plain-table Player doubles. It has to be that way round --
-- RemoteEvent:FireClient rejects anything that isn't a real Player Instance, so a spec that let the
-- replication path run at all could only ever test replication, never the rules.
function BountySystem.ResetState(): ()
	activeBountyByTarget = {}
	killStreaks = {}
	nextBountyId = 1
	lastExpirySweepAt = os.clock()
end

function BountySystem.Init(): ()
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)

	BountySystem.ResetState()

	boardUpdatedRemote = NetworkBridge.CreateRemoteEvent(BountyConstants.RemoteNames.BoardUpdated)
	markedChangedRemote = NetworkBridge.CreateRemoteEvent(BountyConstants.RemoteNames.MarkedChanged)

	local getActiveRemote = NetworkBridge.CreateRemoteFunction(BountyConstants.RemoteNames.GetActiveBounties)
	-- Takes no arguments at all -- there is nothing a client could pass that would be honored, which
	-- is the cheapest possible validation story for a public remote.
	getActiveRemote.OnServerInvoke = function(player: Player): { Types.BountyBoardEntry }
		if queryRateLimiter:IsLimited(player) then
			return {}
		end
		return BountySystem.ListActiveBounties()
	end

	table.insert(
		connections,
		GameplayEvents.OnPlayerKilled(function(victim: Player, killer: Player?)
			-- Both the attributed and unattributed cases live in RegisterKill -- see its header.
			BountySystem.RegisterKill(killer, victim)
		end)
	)

	table.insert(connections, Players.PlayerRemoving:Connect(BountySystem.ClearPlayerReferences))
	table.insert(connections, GameplayEvents.OnHeartbeatTick(onHeartbeatTick))

	logger:info("BountySystem.Init() complete", {
		streakThreshold = BountyConstants.NotorietyStreakThreshold,
	})
end

return BountySystem :: Types.SystemModule
