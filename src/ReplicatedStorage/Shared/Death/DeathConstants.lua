--!strict
--[[
	DeathConstants.lua

	Owns: the wire name and presentation tunables for telling players about a death -- the one
	Death_Notice remote Server/Systems/PlayerDeathSystem.lua broadcasts, and how long the kill feed
	(Client/UI/Screens/DeathFeed) keeps a row and how many it shows.

	Deliberately NOT the kill-credit window: that bounds DAMAGE (how long a blow stays the explanation
	for a death) and lives in Shared/Damage/DamageConstants.lua beside the layer that applies it.

	Does not own: who killed whom (PlayerDeathSystem), the respawn delay the overlay counts down
	(Constants.Respawn), or any reward (MeridianSystem).
]]

local DeathConstants = {}

DeathConstants.Network = {
	RemoteNames = {
		-- Server -> every client, once per confirmed death, with DeathTypes.DeathNotice. One broadcast
		-- rather than a victim-only event plus a feed event: every client needs the attributed kills
		-- for its feed, the victim needs every one of its own deaths for its overlay, and a death is a
		-- few-times-a-minute event, so one small payload to everyone is cheaper than two remotes to
		-- keep in step. Carries nothing a client could act on -- the death is already confirmed.
		Notice = "Death_Notice",
	},
}

DeathConstants.KillFeed = {
	-- Rows shown at once. The oldest is dropped when a new one arrives past this. Five is a brawl's
	-- worth without the tile growing into the fuel gauge below it in the TopRight stack.
	MaxRows = 5,
	-- Seconds a row stays up. Long enough to read two names mid-fight, short enough that the feed is
	-- about the fight happening now.
	RowSeconds = 8,
}

return DeathConstants
