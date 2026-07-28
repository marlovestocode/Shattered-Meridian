--!strict
--[[
	AnnouncementClient.lua

	Owns: the local player's Announcement banner UX -- listens on the DevMenu_Announcement
	RemoteEvent (Constants.Debug.DevMenu.RemoteNames.Announcement) and drives
	UI/Screens/Announcement/init.lua's Display Value. Unlike DevMenuClient.lua this runs
	UNCONDITIONALLY for every player -- an admin broadcast (or a shutdown-countdown warning) is meant
	for the whole server, not just other admins, so there is no whitelist gate here at all.

	Does not own: who may broadcast (DevMenuSystem.lua's own whitelist + checkDevMenuPreconditions
	gate on the BroadcastAnnouncement/ShutdownServer RemoteFunctions that fire this Event -- this
	module only ever receives, never sends), or the banner's visual structure
	(UI/Screens/Announcement/init.lua) -- this module only drives that screen's handle from outside,
	the same "screen exposes state/signals, client module drives from outside" pattern
	DevMenuClient.lua/BugReportClient.lua already use.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local Logger = require(ReplicatedStorage.Shared.Logger)
local Tokens = require(script.Parent.Parent.UI.Tokens)

local AnnouncementModule = require(script.Parent.Parent.UI.Screens.Announcement)

type AnnouncementHandle = AnnouncementModule.AnnouncementHandle
type AnnouncementDisplay = AnnouncementModule.AnnouncementDisplay

local logger = Logger.scope("AnnouncementClient")

local DISPLAY_DURATION = Constants.Debug.DevMenu.AnnouncementDisplayDurationSeconds

local AnnouncementClient = {}

local function describeDisplay(payload: Types.DevMenuAnnouncementPayload): AnnouncementDisplay
	if payload.Kind == "Warning" then
		return { Title = "Server Warning", Message = payload.Message, Color = Tokens.Color.Warning }
	end
	return { Title = "Server Notice", Message = payload.Message, Color = Tokens.Color.AccentPrimary }
end

-- Generation counter guards the delayed clear below against a stale timer stomping a fresher
-- announcement -- same guard DevMenuClient.setStatus/BugReportClient.setStatus already use: without
-- it, two announcements landing within DISPLAY_DURATION of each other would let the FIRST one's timer
-- clear the SECOND one's still-fresh banner early.
local displayGeneration = 0

function AnnouncementClient.Start(handle: AnnouncementHandle): ()
	logger:info("AnnouncementClient.Start called")

	local announcementRemote = NetworkBridge.GetRemoteEvent(Constants.Debug.DevMenu.RemoteNames.Announcement)
	announcementRemote.OnClientEvent:Connect(function(payload: Types.DevMenuAnnouncementPayload)
		logger:debug("Announcement received", { kind = payload.Kind, length = #payload.Message })

		displayGeneration += 1
		local generation = displayGeneration
		handle.Display:set(describeDisplay(payload))

		task.delay(DISPLAY_DURATION, function()
			if displayGeneration == generation then
				handle.Display:set(nil)
			end
		end)
	end)

	logger:debug("AnnouncementClient bindings connected")
end

return AnnouncementClient
