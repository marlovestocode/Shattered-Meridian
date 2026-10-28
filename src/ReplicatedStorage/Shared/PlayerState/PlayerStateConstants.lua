--!strict
--[[
	PlayerStateConstants.lua

	The wire for Server/Systems/PlayerStateSystem.lua: one request a client makes once its state listeners are connected, which
	the server answers by re-sending every registered slice of that player's own state through the slice's own existing remote.
	See PlayerStateSystem's header.
]]

local PlayerStateConstants = {
	RemoteNames = {
		Replay = "PlayerState_Replay",
	},
	-- A client asks once per boot (ClientState.Bootstrap). The ceiling is only there because every public remote has one.
	MaxReplaysPerSecond = 2,
}

return PlayerStateConstants
