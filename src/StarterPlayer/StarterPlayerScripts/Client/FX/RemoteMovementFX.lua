--!strict
--[[
	RemoteMovementFX.lua

	Owns: drawing OTHER players' rolls on this client -- the dust at each end and the afterimage across
	the evade window -- off the replicated Humanoid ParkourState Attribute.

	NO REMOTE. Server/Systems/ParkourSystem.lua writes Constants.Attributes.ParkourState = "Roll" on
	exactly the reports it ACCEPTS (beginAction) and clears it when the action ends, and Humanoid
	Attributes replicate to every client for free. That write is the same accepted report
	Main.server.lua turns into DefenseSystem.BeginEvade -- so a ghost drawn here is a roll the server
	really opened an evade window for, never a client's claim. The audit's N1 finding (the game is
	already over its per-player remote budget) is why this is an Attribute watch and not a broadcast.

	THE LOCAL PLAYER IS SKIPPED. Their own roll is drawn at the predicted transition by
	Client/FX/MovementVFX.OnStateChanged, a round trip earlier than this Attribute could arrive; drawing
	it again here would double every ghost.

	Distance-culled against the camera (FXConstants.RollAfterimage.RemoteMaxDistanceStuds) and bounded
	by RollAfterimage's and MovementVFX's own pools, so a crowded server costs a capped number of ghosts
	and puffs, not one per roll.

	Does not own: what a roll looks like (MovementVFX, RollAfterimage), or whether one happened (the
	server). Purely local presentation.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Constants = require(ReplicatedStorage.Shared.Constants)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local FXConstants = require(ReplicatedStorage.Shared.FXConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local Trove = require(ReplicatedStorage.Shared.Trove)

local MovementVFX = require(script.Parent.MovementVFX)
local RollAfterimage = require(script.Parent.RollAfterimage)

local logger = Logger.scope("RemoteMovementFX")

-- The ParkourState value ParkourSystem writes for an accepted roll -- the report Kind, not the client's
-- MovementStateId ("Rolling").
local ROLL_KIND = "Roll"

local RemoteMovementFX = {}

local started = false
local session: Trove.TroveInstance? = nil

local function withinDrawDistance(character: Model): boolean
	local camera = Workspace.CurrentCamera
	local root = CharacterUtil.RootOf(character)
	if not camera or not root then
		return false
	end
	local limit = FXConstants.RollAfterimage.RemoteMaxDistanceStuds
	return (root.Position - camera.CFrame.Position).Magnitude <= limit
end

-- What one ParkourState change on a remote rig means, split out as a pure-ish decision so the spec can
-- drive it without a replicated Attribute: "Start" entering a roll, "End" leaving one, nil otherwise.
function RemoteMovementFX.Classify(previous: unknown, current: unknown): ("Start" | "End")?
	if current == ROLL_KIND and previous ~= ROLL_KIND then
		return "Start"
	end
	if previous == ROLL_KIND and current ~= ROLL_KIND then
		return "End"
	end
	return nil
end

local function bindRemoteCharacter(character: Model, humanoid: Humanoid, life: Trove.TroveInstance): ()
	local last: unknown = humanoid:GetAttribute(Constants.Attributes.ParkourState)
	life:Connect(humanoid:GetAttributeChangedSignal(Constants.Attributes.ParkourState), function()
		local current = humanoid:GetAttribute(Constants.Attributes.ParkourState)
		local edge = RemoteMovementFX.Classify(last, current)
		last = current
		if not edge or not withinDrawDistance(character) then
			return
		end
		MovementVFX.PlayRollBurst(character)
		if edge == "Start" then
			RollAfterimage.PlayRoll(character)
		end
	end)
end

function RemoteMovementFX.Start(): ()
	if started then
		return
	end
	started = true
	local localPlayer = Players.LocalPlayer
	session = PlayerLifecycle.BindAllPlayers({
		Scope = "RemoteMovementFX",
		OnCharacter = function(player: Player, character: Model, humanoid: Humanoid, life: Trove.TroveInstance)
			if player == localPlayer then
				return
			end
			bindRemoteCharacter(character, humanoid, life)
		end,
	})
	logger:debug("RemoteMovementFX started")
end

function RemoteMovementFX.Stop(): ()
	if not started then
		return
	end
	started = false
	local current = session
	if current then
		current:Clean()
		session = nil
	end
end

return RemoteMovementFX
