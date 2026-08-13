--!strict
--[[
	LoadingClient.lua

	Owns: driving the boot-time Loading screen -- creates its OWN temporary Fusion scope (the same
	narrow, temporally-exclusive exception Client/Intro/IntroClient.lua's own header documents and
	justifies), mounts Screens/Loading/init.lua, runs Client/Loading/AssetPreloader.lua's blocking
	preload pass with a callback that feeds this screen's Progress/Total, flips Complete once that
	returns, waits for the screen's own fade-out to settle, then tears the scope down.

	LoadingClient.Run() is a BLOCKING call from Main.client.lua's perspective, same as
	IntroClient.Run() -- it does not return until every known asset has been preloaded (or
	failed -- see AssetPreloader.lua's own header on why there's no artificial timeout). Unlike
	IntroClient.Run(), which skips entirely for returning players, this ALWAYS runs: asset
	loading isn't a first-time-player concern.

	Does not own: what counts as an asset or how preloading actually works (AssetPreloader.lua), or
	this screen's own rendering (UI/Screens/Loading/init.lua).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Logger = require(ReplicatedStorage.Shared.Logger)

local AssetPreloader = require(script.Parent.AssetPreloader)
local LoadingScreen = require(script.Parent.Parent.UI.Screens.Loading)

local logger = Logger.scope("LoadingClient")

-- Settle time for the screen's own fade-out spring (Screens/Loading/init.lua's Tokens.Motion.
-- FadeSpring) before tearing the scope down -- long enough for a FadeSpring-speed transparency
-- spring to visually finish, short enough not to stall boot on a trailing animation nobody's still
-- looking at.
local FADE_OUT_SETTLE_SECONDS = 0.4

local LoadingClient = {}

function LoadingClient.Run(): ()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

	local scope = Fusion.scoped(Fusion)
	local progress = scope:Value(0)
	local total = scope:Value(1)
	local complete = scope:Value(false)

	LoadingScreen.Mount(scope, playerGui, {
		Progress = progress,
		Total = total,
		Complete = complete,
	})

	logger:debug("Asset preload start")
	AssetPreloader.Run(function(completedCount: number, totalCount: number)
		progress:set(completedCount)
		total:set(totalCount)
	end)
	logger:debug("Asset preload end")

	complete:set(true)
	task.wait(FADE_OUT_SETTLE_SECONDS)
	scope:doCleanup()
end

return LoadingClient
