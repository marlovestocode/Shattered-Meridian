--!strict
--[[
	PlayerStateSystem.lua

	Owns: the "send this player everything about their own state again" request, and the registry of who can answer it. Each
	System that owns a slice of a player's own state (Qi, Meridian XP, tier, emotes, bounty mark, engagement, character sheet,
	art state, inventory, weapon selection) registers a SNAPSHOT: a function that re-sends that slice to one player through the
	slice's OWN existing remote and payload. A client fires PlayerState_Replay once its listeners are connected; every snapshot
	runs for it.

	WHY (coworking plan F4, W7). Each slice solved "a client that was not listening yet missed the push" on its own: some with a
	pull RemoteFunction (GetSheet, the art catalogue, the bounty board), some by pushing on profile load and hoping the client's
	handler was connected by then -- and RemoteEvents are not queued for a listener that connects late in every case a UI needs.
	One request, answered by every owner, is that race solved once. A new slice is one `Register` line in its owner, not a new
	pull remote and a new client handshake.

	STATE, NEVER EVENTS. A snapshot re-sends what IS (the Qi pool, the tier held), never what HAPPENED: MeridianSystem's snapshot
	omits `Gained`, TierSystem's omits `PreviousTier`, so a replay never shows a gain toast or a promotion a second time. Hits,
	swings, cues and realm messages stay on their own remotes and are never registered here.

	WIRE COMPATIBILITY. No slice's remote name or payload changed; a replayed payload is byte-identical to the one its owner sends
	on profile load. The only new remote is PlayerState_Replay (client -> server, no arguments).

	Does not own: any slice's state, its payload type, its push cadence or dedup (each owner keeps its own), or the client mirror
	(Client/UI/State/ClientState.lua caches the last payload per slice and fires the replay).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerStateConstants = require(ReplicatedStorage.Shared.PlayerState.PlayerStateConstants)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local Types = require(ReplicatedStorage.Shared.Types)
local Endpoint = require(script.Parent.Parent.Network.Endpoint)

local logger = Logger.scope("PlayerStateSystem")

local PlayerStateSystem = {}

type Snapshot = (player: Player) -> ()

-- Registration order is replay order (the order the owners' Inits ran -- the same order they push on profile load).
local slices: { { Name: string, Snapshot: Snapshot } } = {}
local replayLimiter = RateLimiter.New(PlayerStateConstants.MaxReplaysPerSecond)

-- Registers `snapshot` as the answer for one slice. Call from the owner's Init. Registering a name again REPLACES its snapshot
-- in place (a System whose spec runs Stop/Init cycles registers on every Init), so a slice is never answered twice.
function PlayerStateSystem.Register(name: string, snapshot: Snapshot): ()
	for _, slice in slices do
		if slice.Name == name then
			slice.Snapshot = snapshot
			return
		end
	end
	table.insert(slices, { Name = name, Snapshot = snapshot })
end

-- Runs every slice's snapshot for `player`. A snapshot that throws is logged and the rest still run.
function PlayerStateSystem.Replay(player: Player): ()
	for _, slice in slices do
		local ok, err = pcall(slice.Snapshot, player)
		if not ok then
			logger:error(
				"Slice snapshot errored",
				{ slice = slice.Name, player = player.Name, errorMessage = tostring(err) }
			)
		end
	end
end

-- The registered slice names, in replay order (specs, diagnostics).
function PlayerStateSystem.SliceNames(): { string }
	local names = {}
	for _, slice in slices do
		table.insert(names, slice.Name)
	end
	return names
end

-- Spec-only.
function PlayerStateSystem.ResetForTesting(): ()
	table.clear(slices)
end

function PlayerStateSystem.Init(): ()
	Endpoint.Scope("PlayerStateSystem", logger).Event({
		Name = PlayerStateConstants.RemoteNames.Replay,
		Limiter = replayLimiter,
		Handler = PlayerStateSystem.Replay,
	})
	logger:info("PlayerStateSystem.Init() complete")
end

return PlayerStateSystem :: Types.SystemModule & typeof(PlayerStateSystem)
