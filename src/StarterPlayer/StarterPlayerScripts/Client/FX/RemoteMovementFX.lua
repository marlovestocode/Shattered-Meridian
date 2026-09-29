--!strict
--[[
	RemoteMovementFX.lua

	Owns: drawing OTHER players' evades on this client -- the dust at each end and the afterimage across
	the evade window -- off the replicated Humanoid ParkourState Attribute.

	NO REMOTE. Server/Systems/ParkourSystem.lua writes Constants.Attributes.ParkourState = "Evade" on
	exactly the reports it ACCEPTS (beginAction) and clears it when the action ends, and Humanoid
	Attributes replicate to every client for free. That write is the same accepted report
	Main.server.lua turns into DefenseSystem.BeginEvade -- so a ghost drawn here is an evade the server
	really opened an evade window for, never a client's claim. The audit's N1 finding (the game is
	already over its per-player remote budget) is why this is an Attribute watch and not a broadcast.

	THE LOCAL PLAYER IS SKIPPED. Their own evade is drawn at the predicted transition by
	Client/FX/MovementVFX.OnStateChanged, a round trip earlier than this Attribute could arrive; drawing
	it again here would double every ghost.

	Distance-culled against the camera (FXConstants.RollAfterimage.RemoteMaxDistanceStuds) and bounded
	by RollAfterimage's and MovementVFX's own pools, so a crowded server costs a capped number of ghosts
	and puffs, not one per evade.

	Does not own: what an evade looks like (MovementVFX, RollAfterimage), or whether one happened (the
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

-- The ParkourState value ParkourSystem writes for an accepted evade -- the report Kind, not the client's
-- MovementStateId ("Evading").
local EVADE_KIND = "Evade"

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
-- drive it without a replicated Attribute: "Start" entering an evade, "End" leaving one, nil otherwise.
function RemoteMovementFX.Classify(previous: unknown, current: unknown): ("Start" | "End")?
	if current == EVADE_KIND and previous ~= EVADE_KIND then
		return "Start"
	end
	if previous == EVADE_KIND and current ~= EVADE_KIND then
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
		-- Start only, matching the local player's own evade (MovementVFX.OnStateChanged): the glide eases to
		-- rest, so nothing marks its end.
		if edge == "Start" then
			MovementVFX.PlayRollBurst(character)
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
