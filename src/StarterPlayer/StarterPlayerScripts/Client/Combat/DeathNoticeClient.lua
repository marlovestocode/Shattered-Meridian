--!strict
--[[
	DeathNoticeClient.lua

	Owns: turning the Death_Notice broadcast (Server/Systems/PlayerDeathSystem.lua) into the two death
	surfaces Screens/DeathFeed already renders -- the local player's own death overlay, and the kill
	feed -- and clearing the overlay when the local player's next character arrives.

	THE RULES, all of them presentation, none of them gameplay:
	  * the overlay is the VICTIM's alone: shown only when the notice's VictimUserId is the local
	    player, with the killer's name or nil for an unattributed death;
	  * the feed is for ATTRIBUTED deaths only: a fall is the victim's news, not the server's, and a
	    brawl's feed should be about who is fighting whom;
	  * the local player's part in a kill (killer, victim, neither) is decided here, by UserId, and
	    handed to the row -- the server never tailors a broadcast per recipient.

	Decide is the whole of that, as a pure function of (notice, local UserId), so a spec can drive every
	branch with no remote and no UI. Start is the adapter around it.

	The killer's "+25 Meridian XP" is NOT here: it arrives on MeridianSystem's own per-grant update and
	renders on the TierBadge (Screens/HUD), because the amount is MeridianSystem's to state and the two
	remotes have no ordering guarantee between them -- joining them here would be joining two facts
	that can arrive in either order.

	Does not own: who killed whom (PlayerDeathSystem), rendering (Screens/DeathFeed, Components/
	KillFeedRow, Components/DeathOverlay), or the respawn itself (RespawnSystem).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DeathConstants = require(ReplicatedStorage.Shared.Death.DeathConstants)
local DeathTypes = require(ReplicatedStorage.Shared.Death.DeathTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)

local logger = Logger.scope("DeathNoticeClient")

local DeathNoticeClient = {}

export type Involvement = "Killer" | "Victim" | "None"

-- What one notice should do on this client. Overlay is present only for the local player's own death
-- (Killer is nil inside it for an unattributed one); Feed is present only for an attributed death.
export type Decision = {
	Overlay: { KillerName: string? }?,
	Feed: { KillerName: string, VictimName: string, Involvement: Involvement }?,
}

-- The subset of Screens/DeathFeed's handle this module drives. Typed structurally so a spec can pass a
-- recorder rather than a mounted screen.
export type DeathFeedSurface = {
	ShowDeath: (killerName: string?) -> (),
	ClearDeath: () -> (),
	PushKill: (killerName: string, victimName: string, involvement: Involvement) -> (),
}

local started = false

function DeathNoticeClient.Decide(notice: DeathTypes.DeathNotice, localUserId: number): Decision
	local decision: Decision = { Overlay = nil, Feed = nil }
	if notice.VictimUserId == localUserId then
		decision.Overlay = { KillerName = notice.KillerName }
	end
	local killerName = notice.KillerName
	local killerUserId = notice.KillerUserId
	if killerName ~= nil and killerUserId ~= nil then
		decision.Feed = {
			KillerName = killerName,
			VictimName = notice.VictimName,
			Involvement = if killerUserId == localUserId
				then "Killer"
				elseif notice.VictimUserId == localUserId then "Victim"
				else "None",
		}
	end
	return decision
end

-- Applies one raw notice to `surface`. Public for the spec; Start wires it to the remote.
function DeathNoticeClient.Apply(raw: unknown, localUserId: number, surface: DeathFeedSurface): ()
	local notice = DeathTypes.Parse(raw)
	if notice == nil then
		logger:warn("Malformed Death_Notice ignored", { payload = tostring(raw) })
		return
	end
	local decision = DeathNoticeClient.Decide(notice, localUserId)
	local overlay = decision.Overlay
	if overlay then
		surface.ShowDeath(overlay.KillerName)
	end
	local feed = decision.Feed
	if feed then
		surface.PushKill(feed.KillerName, feed.VictimName, feed.Involvement)
	end
end

-- `surface` is Screens/DeathFeed's handle from UI.Mount(). Idempotent.
function DeathNoticeClient.Start(surface: DeathFeedSurface): ()
	if started then
		return
	end
	started = true

	local localPlayer = Players.LocalPlayer
	local remote = NetworkBridge.GetRemoteEvent(DeathConstants.Network.RemoteNames.Notice)
	remote.OnClientEvent:Connect(function(raw: unknown)
		DeathNoticeClient.Apply(raw, localPlayer.UserId, surface)
	end)

	-- A new body ends the overlay -- the real end of the death, whatever the countdown last displayed
	-- (Screens/DeathFeed's header on why its countdown is an estimate). Also fires for the session's
	-- first character, where clearing nothing costs nothing.
	PlayerLifecycle.BindLocalCharacter({
		Scope = "DeathNoticeClient",
		OnCharacter = function()
			surface.ClearDeath()
		end,
	})
end

return DeathNoticeClient
