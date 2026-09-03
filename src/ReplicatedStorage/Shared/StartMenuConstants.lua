--!strict
--[[
	StartMenuConstants.lua

	Owns: the start menu's own config -- chiefly the Studio skip, which is consulted only behind a
	RunService:IsStudio() check at the call site and so can never affect a live server whatever its
	value.

	Does not own: the teleport it fronts, or the onboarding flow a first-time player reaches through
	it (Shared/CharacterCreationConstants.lua).

	Lifted out of Constants.lua. Constants.StartMenu re-exports this module, so every existing
	Constants.StartMenu.X call site keeps working unchanged; new code should require this module
	directly.
]]

-- Start Menu / server-hop (Server/Systems/ServerHopSystem.lua, Client/StartMenu/StartMenuClient.lua
-- + UI/Screens/StartMenu/*). The very first client boot gate, ahead of onboarding -- Play requests a
-- fresh server via TeleportService:TeleportAsync back into this SAME game.PlaceId (Roblox always
-- resolves that to a different running server), not a separate Place -- see StartMenuClient.lua's
-- own header for how a player who just arrived via a Play click is told apart from one who joined
-- this server directly.
local StartMenuConstants = {
	RemoteNames = {
		RequestTeleport = "StartMenu_RequestTeleport",
	},
	-- ServerHopSystem's own `pendingByPlayer` guard only rejects a concurrent duplicate invoke (a
	-- second call racing one already in flight) -- it does nothing about a client that waits for
	-- each TeleportAsync to fail/return and immediately fires another, which a rate limiter closes
	-- the same way every other public remote in this codebase (BugReportSystem's
	-- SubmitMaxCallsPerSecond, Constants.Settings.MaxCallsPerSecondPerPlayer) already does for its
	-- own handler.
	RequestTeleportMaxCallsPerSecond = 1,
	-- Studio-only dev convenience, gated by RunService:IsStudio() at the call site (StartMenuClient.
	-- lua) -- ordinary Play Solo has nothing for TeleportAsync to actually teleport INTO (there's no
	-- second server), so leaving the real Start Menu up would strand every Studio playtest on a
	-- button that can never succeed. True skips the Start Menu entirely when testing in Studio;
	-- flip to false to test the Start Menu screen itself (its layout/hover/error states) without
	-- needing a real teleport to succeed. Never consulted outside RunService:IsStudio() == true, so
	-- this can never affect a live server regardless of its value.
	SkipInStudio = true,
}

return StartMenuConstants
