--!strict
--[[
	DeathTypes.lua

	Owns: the Death_Notice wire payload (DeathConstants.Network.RemoteNames.Notice).

	Identity crosses as UserId + display string rather than Player references so a client can compare
	against its own LocalPlayer.UserId without the reference having to survive replication, and so a
	row for a player who has since left still renders.
]]

local DeathTypes = {}

export type DeathNotice = {
	VictimUserId: number,
	VictimName: string,
	-- Both nil for an unattributed death (a fall, the void, a non-player's blow) -- PlayerDeathSystem's
	-- own rule decides; the client only ever displays it.
	KillerUserId: number?,
	KillerName: string?,
}

-- Validates an untrusted payload off the wire. Returns nil for anything malformed -- a client never
-- renders half a notice.
function DeathTypes.Parse(raw: unknown): DeathNotice?
	if typeof(raw) ~= "table" then
		return nil
	end
	local notice = raw :: any
	if typeof(notice.VictimUserId) ~= "number" or typeof(notice.VictimName) ~= "string" then
		return nil
	end
	local hasKillerId = notice.KillerUserId ~= nil
	local hasKillerName = notice.KillerName ~= nil
	if hasKillerId ~= hasKillerName then
		return nil
	end
	if hasKillerId and (typeof(notice.KillerUserId) ~= "number" or typeof(notice.KillerName) ~= "string") then
		return nil
	end
	return {
		VictimUserId = notice.VictimUserId,
		VictimName = notice.VictimName,
		KillerUserId = notice.KillerUserId,
		KillerName = notice.KillerName,
	}
end

return DeathTypes
