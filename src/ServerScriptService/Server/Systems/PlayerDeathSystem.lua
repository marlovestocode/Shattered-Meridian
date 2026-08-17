--!strict
--[[
	PlayerDeathSystem.lua

	Owns: detecting that a player has died -- ANY death, PvP, environmental (fall, void), or
	otherwise -- and publishing it as GameplayEvents.FirePlayerKilled(player, nil). Nothing here ever
	attributes a killer: with no combat/PvP system, there is no notion of who dealt the fatal blow, so
	every death fires with `killer = nil`, exactly the shape GameplayEvents.OnPlayerKilled's own
	subscribers (RespawnSystem, RivalrySystem, BountySystem) already treat as "environmental/other" --
	see each of their own OnPlayerKilled handlers, none of which required a non-nil killer to function.

	WHY THIS EXISTS. Death detection (a Humanoid.Died listener bound per character, guarded against
	double-firing) used to be a small, incidental piece of Server/Systems/CombatSystem.lua's own
	onCharacterAdded/confirmDeath -- see that file's former header: "the ONLY place a kill is
	confirmed is the Humanoid.Died handler... an environmental/non-combat death... also runs
	confirmDeath... CombatSystem needs to know about every death to keep its own state... consistent
	regardless of cause." That module owned it because it ALSO needed to know about every death for
	its own bookkeeping, not because detecting a death is combat logic -- it never was. Removing
	CombatSystem left GameplayEvents.FirePlayerKilled with no publisher at all, which silently broke
	every one of its subscribers: a player who died would never get a new body (RespawnSystem),
	RivalrySystem/BountySystem would never see a kill again. This module is exactly the piece that
	was quietly load-bearing underneath those systems, extracted on its own -- it carries no combat
	resolution, no damage math, no health mutation, nothing beyond "notice a Humanoid died, tell
	whoever's listening."

	Health authority stays Roblox's own `Humanoid.Health`/`Humanoid:TakeDamage`/`Humanoid.Died` --
	this module owns none of it, it only listens.

	Double-fire guard: a fresh boolean per character (deathConfirmed below), the same shape
	CombatSystem's own state.deathConfirmed used -- Humanoid.Died can in principle fire more than
	once for edge-case rig setups, and a second GameplayEvents.FirePlayerKilled for the same life
	would double-schedule a respawn and double-count a kill for every subscriber.

	Does not own: what happens after a death (RespawnSystem gives the player a new body,
	RivalrySystem/BountySystem react to a PvP kill that can no longer happen without a combat system,
	MeridianSystem/RewardSystem's own reactions if any). Does not own damage, health, or combat state
	of any kind -- see GameplayEvents.lua's own header for why the producer of an event should never
	be a dependency of everyone interested in it, and why this module stays exactly this small.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local GameplayEvents = require(ServerScriptService.Server.Events.GameplayEvents)

local PlayerDeathSystem = {}

local logger = Logger.scope("PlayerDeathSystem")

type PlayerDeathState = {
	DeathConfirmed: boolean,
	DiedConnection: RBXScriptConnection?,
}

local deathStates: { [Player]: PlayerDeathState } = {}

local function onCharacterAdded(player: Player, character: Model): ()
	local state = deathStates[player]
	if not state then
		return
	end

	if state.DiedConnection then
		state.DiedConnection:Disconnect()
		state.DiedConnection = nil
	end
	state.DeathConfirmed = false

	local humanoidInstance = character:WaitForChild("Humanoid", Constants.Network.WaitForChildTimeoutSeconds)
	if not humanoidInstance or not humanoidInstance:IsA("Humanoid") then
		logger:warn("Character has no Humanoid -- death cannot be detected for this life", { player = player.Name })
		return
	end
	local humanoid = humanoidInstance :: Humanoid

	state.DiedConnection = humanoid.Died:Connect(function()
		if state.DeathConfirmed then
			return
		end
		state.DeathConfirmed = true
		logger:debug("Player died", { player = player.Name })
		GameplayEvents.FirePlayerKilled(player, nil)
	end)
end

local function onPlayerAdded(player: Player): ()
	deathStates[player] = { DeathConfirmed = false, DiedConnection = nil }

	player.CharacterAdded:Connect(function(character: Model)
		onCharacterAdded(player, character)
	end)
	if player.Character then
		onCharacterAdded(player, player.Character)
	end
end

local function onPlayerRemoving(player: Player): ()
	local state = deathStates[player]
	if state and state.DiedConnection then
		state.DiedConnection:Disconnect()
	end
	deathStates[player] = nil
end

function PlayerDeathSystem.Init(): ()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end

	logger:info("PlayerDeathSystem.Init() complete")
end

return PlayerDeathSystem
