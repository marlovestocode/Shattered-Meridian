--!strict
--[[
	SpectateController.lua

	Owns: a free spectator camera for the LOCAL admin -- retargets workspace.CurrentCamera.
	CameraSubject to another player's Humanoid while keeping CameraType Custom, so the stock
	follow-cam (mouse orbit/zoom, occlusion, everything) just keeps working against a different
	subject -- no custom Scriptable camera rig, per this feature's own brief. Client-only: there is no
	new remote here at all. CameraSubject is a purely local, cosmetic reassignment -- it changes
	nothing about this admin's own character, position, health, or any other player's replicated
	state, so there is nothing to authorize server-side.

	Re-binds across the target's own respawns (CharacterAdded) and auto-stops if the target leaves the
	server (Players.PlayerRemoving) -- mirrors Client/Flight/FlightController.lua's own
	"watch a Humanoid, rebind on respawn" idiom, just for a possibly-other player's Humanoid instead of
	always the local one.

	Does not own: which player is the current spectate target -- DevMenuClient.lua resolves that the
	same way its own Admin-tab target tracking already does (Combat_LockOnChanged), and only calls
	Start/Stop here. Nor the toggle button itself (UI/Screens/DevTools/DevMenu/init.lua).
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local Logger = require(ReplicatedStorage.Shared.Logger)

local logger = Logger.scope("SpectateController")

local SpectateController = {}

local spectatingPlayer: Player? = nil
local targetCharacterAddedConnection: RBXScriptConnection? = nil
local targetRemovingConnection: RBXScriptConnection? = nil

local function bindTargetHumanoid(character: Model): ()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local humanoidInstance = CharacterUtil.AwaitHumanoid(character)
	if not humanoidInstance then
		return
	end
	camera.CameraSubject = humanoidInstance
end

-- Restores the camera to the local player's own Humanoid -- called both for an explicit Stop() and
-- (indirectly, via Start's own leading call) as the reset step before spectating a new target.
function SpectateController.Stop(): ()
	if targetCharacterAddedConnection then
		targetCharacterAddedConnection:Disconnect()
		targetCharacterAddedConnection = nil
	end
	if targetRemovingConnection then
		targetRemovingConnection:Disconnect()
		targetRemovingConnection = nil
	end

	local wasSpectating = spectatingPlayer ~= nil
	spectatingPlayer = nil

	local camera = Workspace.CurrentCamera
	local localPlayer = Players.LocalPlayer
	local ownCharacter = localPlayer.Character
	if camera and ownCharacter then
		local ownHumanoid = CharacterUtil.HumanoidOf(ownCharacter)
		if ownHumanoid then
			camera.CameraSubject = ownHumanoid
		end
	end

	if wasSpectating then
		logger:info("Spectate stopped")
	end
end

function SpectateController.Start(targetPlayer: Player): ()
	SpectateController.Stop()

	local localPlayer = Players.LocalPlayer
	if targetPlayer == localPlayer then
		logger:debug("Spectate ignored -- target is the local player")
		return
	end

	spectatingPlayer = targetPlayer

	if targetPlayer.Character then
		bindTargetHumanoid(targetPlayer.Character)
	end

	targetCharacterAddedConnection = targetPlayer.CharacterAdded:Connect(bindTargetHumanoid)

	targetRemovingConnection = Players.PlayerRemoving:Connect(function(leavingPlayer: Player)
		if leavingPlayer == targetPlayer then
			SpectateController.Stop()
		end
	end)

	logger:info("Spectate started", { target = targetPlayer.Name })
end

-- Whether SpectateController currently has an active target -- lets DevMenuClient.lua drive a single
-- toggle button (rather than separate Start/Stop buttons) without keeping its own duplicate copy of
-- this module's state.
function SpectateController.IsSpectating(): boolean
	return spectatingPlayer ~= nil
end

return SpectateController
