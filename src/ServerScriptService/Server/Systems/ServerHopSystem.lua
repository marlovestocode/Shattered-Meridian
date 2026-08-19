--!strict
--[[
	ServerHopSystem.lua

	Owns: StartMenu_RequestTeleport, the RemoteFunction Client/StartMenu/StartMenuClient.lua's Play
	button invokes. Moves the requesting player onto a DIFFERENT running server of this SAME
	game.PlaceId via TeleportService:TeleportAsync -- not a separate Roblox Place -- and stamps
	{ FromStartMenu = true } into that teleport's TeleportData, which is what lets the destination
	server's own StartMenuClient.Run() (via TeleportService:GetLocalPlayerTeleportData()) tell "I
	just arrived via Play" apart from "I just joined this server directly" and skip the Start Menu
	there instead of showing it forever in a loop.

	Zero dependency on any other System (no PlayerDataSystem/CombatSystem/etc. state involved) --
	boots early in Main.server.lua for exactly that reason.

	Does not own: the Start Menu's own rendering or retry/error UI (Client/UI/Screens/StartMenu/
	init.lua, Client/StartMenu/StartMenuClient.lua own both) -- this module only ever executes one
	teleport per successful request and reports whether it worked.
]]

local TeleportService = game:GetService("TeleportService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)

local ServerHopSystem = {}

local logger = Logger.scope("ServerHopSystem")

local Config = Constants.StartMenu

local rateLimiter = RateLimiter.New(Config.RequestTeleportMaxCallsPerSecond)

local TELEPORT_FAILED_MESSAGE = "Failed to join a server. Try again."

-- Rejects a concurrent duplicate invoke from the same player (a double-click racing the client's own
-- Disabled-while-requesting guard, or a client that skips that guard entirely) -- engineering-
-- standards.md's "validate at every external boundary" applies to a RemoteFunction handler's own
-- call discipline, not just its payload; a second TeleportAsync for a player already mid-teleport
-- would be redundant at best. Cleared on PlayerRemoving below, same convention as BugReportSystem.
-- lua's own per-player maps.
local pendingByPlayer: { [Player]: boolean } = {}

function ServerHopSystem.Init(): ()
	local requestTeleportRemote = NetworkBridge.CreateRemoteFunction(Config.RemoteNames.RequestTeleport)

	requestTeleportRemote.OnServerInvoke = function(player: Player): (boolean, string?)
		if rateLimiter:IsLimited(player) then
			return false, TELEPORT_FAILED_MESSAGE
		end
		if pendingByPlayer[player] then
			logger:warn("Duplicate teleport request ignored", { player = player.Name })
			return false, TELEPORT_FAILED_MESSAGE
		end
		pendingByPlayer[player] = true

		local options = Instance.new("TeleportOptions")
		options:SetTeleportData({ FromStartMenu = true })

		local ok, errorMessage = pcall(function()
			TeleportService:TeleportAsync(game.PlaceId, { player }, options)
		end)

		pendingByPlayer[player] = nil

		if not ok then
			logger:warn("TeleportAsync failed", { player = player.Name, errorMessage = tostring(errorMessage) })
			return false, TELEPORT_FAILED_MESSAGE
		end

		logger:info("Teleport requested", { player = player.Name })
		return true
	end

	PlayerLifecycle.BindAllPlayers({
		Scope = "ServerHopSystem",
		OnPlayerRemoving = function(player: Player)
			pendingByPlayer[player] = nil
			rateLimiter:Clear(player)
		end,
	})

	logger:info("ServerHopSystem.Init() complete")
end

return ServerHopSystem
