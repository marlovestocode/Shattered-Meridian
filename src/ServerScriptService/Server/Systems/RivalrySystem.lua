--!strict
--[[
	RivalrySystem.lua

	Owns: player-vs-player rivalry tracking, part of software-architecture.md's meta-progression
	social/competitive systems pairing with BountySystem.
	Does not own: bounty placement/claim state -- that's BountySystem. This System owns rivalry
	standing between specific players, fed by PvP outcomes from CombatSystem
	(progression-systems.md: "standing changes should primarily come from PvP outcomes ... not
	passive activity").

	Tables are keyed directly by the Player instance (never tostring(player)) and scrubbed on
	Players.PlayerRemoving -- docs/architecture/2026-08-audit.md section 3.2 flagged the prior
	tostring-keyed, never-cleared shape as the same unbounded-reference-leak class CombatSystem's
	own clearRecentOpponentReferencesTo already fixed elsewhere in this codebase. Keying by the live
	Player instance is what makes an O(this player's own opponent count) cleanup possible instead of
	a full-table scan or a parallel string-to-Player index.

	Query surface: GetTopRivals/GetStandingAgainst below are the client-facing read-only remotes that
	make this System's data actually reachable by a player, not just an internal leaderboard --
	nothing else in this codebase consumed RivalrySystem.GetTopPlayers()/GetRivalryStanding() before
	this pass.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Types = require(ReplicatedStorage.Shared.Types)
local Constants = require(ReplicatedStorage.Shared.Constants)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)

local Logger = require(ReplicatedStorage.Shared.Logger)
local GameplayEvents = require(ServerScriptService.Server.Events.GameplayEvents)

local logger = Logger.scope("RivalrySystem")

local RivalrySystem = {}

export type RivalLeaderboardEntry = {
	Name: string,
	UserId: number,
	Score: number,
}

-- rivalryStandings[winner][loser] = winner's standing against loser. Nested by Player instance
-- (not a single "winner|loser" string key) so a departing player's entries can be dropped in
-- O(their own opponent count) on PlayerRemoving -- see this file's own header.
local rivalryStandings: { [Player]: { [Player]: number } } = {}
local playerScores: { [Player]: number } = {}

local queryRateLimiter = RateLimiter.New(Constants.Rivalry.QueryMaxCallsPerSecond)

local function ensureScoreEntry(player: Player): ()
	if playerScores[player] == nil then
		playerScores[player] = 0
	end
end

local function getStanding(winner: Player, loser: Player): number
	local winnerTable = rivalryStandings[winner]
	if not winnerTable then
		return 0
	end
	return winnerTable[loser] or 0
end

local function setStanding(winner: Player, loser: Player, value: number): ()
	local winnerTable = rivalryStandings[winner]
	if not winnerTable then
		winnerTable = {}
		rivalryStandings[winner] = winnerTable
	end
	winnerTable[loser] = value
end

function RivalrySystem.GetRivalryStanding(winner: Player, loser: Player): number
	ensureScoreEntry(winner)
	ensureScoreEntry(loser)

	return getStanding(winner, loser)
end

function RivalrySystem.RegisterPvPKill(winner: Player, loser: Player): ()
	if winner == loser then
		return
	end

	ensureScoreEntry(winner)
	ensureScoreEntry(loser)

	local winnerVsLoser = getStanding(winner, loser) + 1
	local loserVsWinner = getStanding(loser, winner) - 1
	setStanding(winner, loser, winnerVsLoser)
	setStanding(loser, winner, loserVsWinner)

	playerScores[winner] = (playerScores[winner] or 0) + 1
	playerScores[loser] = (playerScores[loser] or 0) - 1

	logger:info("PvP rivalry updated", {
		winner = winner.Name,
		loser = loser.Name,
		winnerStanding = winnerVsLoser,
		loserStanding = loserVsWinner,
	})
end

function RivalrySystem.GetTopPlayers(limit: number?): { Player }
	local orderedEntries = {}

	for player, score in pairs(playerScores) do
		orderedEntries[#orderedEntries + 1] = { player = player, score = score }
	end

	-- tostring(player) tie-break (not player.UserId) -- kept identical to the prior implementation
	-- deliberately: this System's own regression tests exercise it with plain-table test doubles
	-- (no real Player, no UserId field), the same "fake Player" pattern other Systems' specs use, so
	-- the tie-break must stay safe against a value that isn't a real Player instance.
	table.sort(orderedEntries, function(a, b)
		if a.score == b.score then
			return tostring(a.player) < tostring(b.player)
		end
		return a.score > b.score
	end)

	local output: { Player } = {}
	local resolvedLimit = if typeof(limit) == "number" then math.floor(limit) else nil
	if typeof(limit) == "number" and resolvedLimit <= 0 then
		return output
	end

	local cap = if typeof(resolvedLimit) == "number" then resolvedLimit else #orderedEntries
	for index = 1, math.min(cap, #orderedEntries) do
		output[#output + 1] = orderedEntries[index].player
	end

	return output
end

-- Drops every table entry keyed by or nested under the departing player -- both the O(1) top-level
-- rivalryStandings[player]/playerScores[player] entries AND the reverse relationship (this player as
-- someone else's LOSER key inside their winner-table), so no other player's table retains a
-- reference to someone who has left. Exported (not a local) so this System's own regression tests
-- can exercise it directly with a plain-table test double, the same "the narrow primitive stays
-- unit-testable" reasoning BountySystem.ClaimBounty's own header documents -- Players.PlayerRemoving
-- only ever fires for a real Player instance, which a headless spec has no way to construct.
function RivalrySystem.ClearPlayerReferences(departingPlayer: Player): ()
	rivalryStandings[departingPlayer] = nil
	playerScores[departingPlayer] = nil

	for _, opponentTable in pairs(rivalryStandings) do
		opponentTable[departingPlayer] = nil
	end

	queryRateLimiter:Clear(departingPlayer)
end

function RivalrySystem.Init(): ()
	rivalryStandings = {}
	playerScores = {}

	GameplayEvents.OnPlayerKilled(function(victim: Player, killer: Player?)
		if killer ~= nil then
			RivalrySystem.RegisterPvPKill(killer, victim)
		end
	end)

	Players.PlayerRemoving:Connect(RivalrySystem.ClearPlayerReferences)

	local getTopRivalsRemote = NetworkBridge.CreateRemoteFunction(Constants.Rivalry.RemoteNames.GetTopRivals)
	getTopRivalsRemote.OnServerInvoke = function(player: Player, rawLimit: unknown): { RivalLeaderboardEntry }
		if queryRateLimiter:IsLimited(player) then
			return {}
		end

		local limit = if typeof(rawLimit) == "number" then rawLimit else Constants.Rivalry.DefaultLeaderboardLimit
		local topPlayers = RivalrySystem.GetTopPlayers(limit)

		local result: { RivalLeaderboardEntry } = {}
		for _, topPlayer in ipairs(topPlayers) do
			result[#result + 1] = {
				Name = topPlayer.Name,
				UserId = topPlayer.UserId,
				Score = playerScores[topPlayer] or 0,
			}
		end
		return result
	end

	local getStandingRemote = NetworkBridge.CreateRemoteFunction(Constants.Rivalry.RemoteNames.GetStandingAgainst)
	getStandingRemote.OnServerInvoke = function(player: Player, rawTargetUserId: unknown): number?
		if queryRateLimiter:IsLimited(player) then
			return nil
		end
		if typeof(rawTargetUserId) ~= "number" then
			return nil
		end

		local target = Players:GetPlayerByUserId(rawTargetUserId)
		if not target or target == player then
			return nil
		end

		return RivalrySystem.GetRivalryStanding(player, target)
	end

	logger:info("RivalrySystem.Init() complete")
end

return RivalrySystem :: Types.SystemModule
