--!strict
--[[
	StartMenuClient.lua

	Owns: driving the Start Menu -- the very first boot gate, ahead of Client/Loading/LoadingClient.
	lua and Client/Intro/IntroClient.lua. Main.client.lua calls StartMenuClient.Run() before either
	of those.

	Same-place server hop, not a separate Roblox Place (see Constants.lua's own Constants.StartMenu
	header for why): Play invokes Server/Systems/ServerHopSystem.lua's RequestTeleport RemoteFunction,
	which calls TeleportService:TeleportAsync back into this SAME game.PlaceId and stamps
	{ FromStartMenu = true } into that teleport's TeleportData. TeleportService:
	GetLocalPlayerTeleportData() on the DESTINATION server reads that marker back -- Run() checks it
	FIRST and returns immediately if present, skipping the Start Menu entirely there. A player who
	joined a server directly (no marker) sees the Start Menu instead.

	Run()'s contract is unusual and worth stating plainly: it either returns immediately (arrived via
	a Play teleport, or Constants.StartMenu.SkipInStudio short-circuiting it in Studio -- see below),
	or it does NOT return AT ALL on this server. There is no third case. A successful Play request
	means Roblox is about to tear this entire client script down mid-flight as the actual teleport
	executes -- there is nothing to hand control back to locally, ever, since nothing on this server
	is meant to run past the Start Menu for a direct join. A failed request just re-shows the error
	and waits for another click. This creates its own temporary Fusion scope (Fusion.scoped(Fusion)),
	the same narrow, temporally-exclusive exception Client/Intro/IntroClient.lua/LoadingClient.lua's
	own headers already document and justify -- except this one is never torn down by this module itself
	(the engine does it, by killing the script, on a successful teleport).

	RunService:IsStudio() + Constants.StartMenu.SkipInStudio: ordinary Play Solo has no second server
	for TeleportAsync to actually land in, so leaving the real Start Menu up in Studio would strand
	every playtest on a button that can never succeed -- this check skips straight past the Start Menu
	there, same as a real Play-teleport arrival. Flip the constant off (in Studio only -- it's already
	inert outside RunService:IsStudio()) to actually test this screen's own layout/hover/error states.

	Does not own: the teleport itself or its failure handling (Server/Systems/ServerHopSystem.lua), or
	this screen's own rendering (UI/Screens/StartMenu/init.lua).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)

local StartMenuScreen = require(script.Parent.Parent.UI.Screens.StartMenu)

local peek = Fusion.peek

local logger = Logger.scope("StartMenuClient")

local DEFAULT_ERROR_TEXT = "Failed to join a server. Try again."

local StartMenuClient = {}

local function arrivedViaPlayTeleport(): boolean
	local ok, teleportData = pcall(function()
		return TeleportService:GetLocalPlayerTeleportData()
	end)
	if not ok or typeof(teleportData) ~= "table" then
		return false
	end
	return (teleportData :: { [string]: unknown }).FromStartMenu == true
end

function StartMenuClient.Run(): ()
	if arrivedViaPlayTeleport() then
		logger:debug("Arrived via Play teleport -- skipping Start Menu")
		return
	end

	if RunService:IsStudio() and Constants.StartMenu.SkipInStudio then
		logger:debug("Studio testing -- skipping Start Menu (Constants.StartMenu.SkipInStudio)")
		return
	end

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

	local scope = Fusion.scoped(Fusion)
	local isRequesting = scope:Value(false)
	local errorText = scope:Value("")

	local function requestPlay(): ()
		if peek(isRequesting) then
			return
		end
		isRequesting:set(true)
		errorText:set("")

		local remote = NetworkBridge.GetRemoteFunction(Constants.StartMenu.RemoteNames.RequestTeleport)
		local ok, successOrError, reason = pcall(function()
			return remote:InvokeServer()
		end)

		if ok and successOrError == true then
			logger:debug("Teleport accepted -- awaiting server-side transfer")
			-- Deliberately leaves isRequesting true and returns -- see this file's own header, the
			-- engine is about to tear this whole script down.
			return
		end

		logger:warn("Teleport request failed", { errorMessage = tostring(if ok then reason else successOrError) })
		isRequesting:set(false)
		errorText:set(if ok and typeof(reason) == "string" then reason :: string else DEFAULT_ERROR_TEXT)
	end

	StartMenuScreen.Mount(scope, playerGui, {
		IsRequesting = isRequesting,
		ErrorText = errorText,
		OnPlayRequested = function()
			task.spawn(requestPlay)
		end,
	})

	-- Blocks forever, by design -- nothing internal to this script ever fires this BindableEvent.
	-- The only ways out of Run() are the early return above (this arrival was a Play teleport) or the
	-- Roblox engine killing this script outright once a teleport this session requested actually
	-- lands. See this file's own header for why there is no third path back to Main.client.lua.
	local neverFires = Instance.new("BindableEvent")
	table.insert(scope, neverFires)
	neverFires.Event:Wait()
end

return StartMenuClient
