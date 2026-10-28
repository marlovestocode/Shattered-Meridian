--!strict
--[[
	PlayerScoped.lua

	Owns: "this table is keyed by Player, and a player's entry goes when the player does". `PlayerScoped.New(name)` returns an
	ordinary `{ [Player]: V }` table -- read, write, iterate and `next` it exactly as before -- that this module empties of a player's
	entry after that player leaves.

	WHY (coworking plan F10, W17). Forty-odd server tables were keyed by Player, and each System wrote a PlayerRemoving handler whose
	body was mostly `someTable[player] = nil` lines and `someLimiter:Clear(player)` calls. A table added later and missed from that
	list leaks one entry per session for the life of the server, with nothing to notice it. Declaring the table as player-scoped
	makes the cleanup part of the declaration, the way Trove makes a connection's cleanup part of creating it.

	THE CLEAR IS DEFERRED (task.defer from Players.PlayerRemoving), and that is the one guarantee to build on: every System's own
	PlayerRemoving handler still sees the leaver's entry in the same frame -- BlimpSystem.Dismount reads `mounts[player]`,
	AdminActionSystem releases invisibility from `overrideStates[player]`, PlayerDeathSystem settles credit -- and the entry is gone
	before anything later. A handler that YIELDS and reads the table after resuming must not use this (PlayerDataSystem's save path
	does exactly that, and keeps its own tables).

	Does not own: other per-player teardown (a dismount, a save, a broadcast) -- that stays in the System's leave handler, which is
	kept whenever it does anything but clear. Nor a profile-ready gate (PlayerDataSystem.OnProfileLoaded / IsLoaded is server-only
	and stays there). Tables keyed by a Model, a userId or a string are not player-scoped and do not belong here.

	SPECS. The harness has no real Players, so PlayerRemoving never fires for a spec's fake player; `Release(player)` clears it from
	every scoped table synchronously, for a spec that asserts "nothing is left once they leave".
]]

local Players = game:GetService("Players")

local PlayerScoped = {}

-- Names already taken by New, so two modules cannot share one table by accident.
local names: { [string]: { [Player]: any } } = {}
-- Every scoped table. WEAK-KEYED: a named table is also held by `names` (it lives as long as the VM), but one Adopt-ed by a
-- short-lived owner (a RateLimiter a spec makes per case) must not be kept alive by being scoped.
local registry: { [{ [Player]: any }]: true } = setmetatable({}, { __mode = "k" }) :: any

local function release(player: Player): ()
	for map in registry do
		map[player] = nil
	end
end

-- A new `{ [Player]: V }` whose entries are dropped after their player leaves. `name` is "<Module>.<table>", and must be unique in
-- the VM (a second New with one name is two modules sharing a table by accident).
function PlayerScoped.New<V>(name: string): { [Player]: V }
	assert(names[name] == nil, `PlayerScoped.New("{name}"): that name is already scoped -- one name, one table`)
	local map: { [Player]: V } = {}
	names[name] = map
	registry[map] = true
	return map
end

-- Scopes a table some other object owns (RateLimiter's buckets), unnamed and held weakly: it is released when its owner is.
function PlayerScoped.Adopt<V>(map: { [Player]: V }): { [Player]: V }
	registry[map] = true
	return map
end

-- Clears `player` from every scoped table now. Called (deferred) by PlayerRemoving; called directly by specs.
function PlayerScoped.Release(player: Player): ()
	release(player)
end

-- How many NAMED scoped tables exist, for specs.
function PlayerScoped.Count(): number
	local count = 0
	for _ in names do
		count += 1
	end
	return count
end

Players.PlayerRemoving:Connect(function(player: Player)
	task.defer(release, player)
end)

return PlayerScoped
