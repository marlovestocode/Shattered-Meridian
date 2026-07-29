--!strict
--[[
	RespawnSystem.lua

	Owns: putting a dead player back in a body. `Players.CharacterAutoLoads` is false
	(default.project.json), so Roblox spawns nobody automatically -- and the only other
	`Player:LoadCharacter()` call in this codebase is CharacterCreationSystem.lua's, which is
	explicitly and correctly scoped to this SESSION'S FIRST spawn (guarded by its own
	`spawnedThisSession` map so a replayed CharacterCreation_GetOnboardingState can't destroy an
	already-spawned character). Nothing owned the SECOND spawn or any after it, which meant a player
	who died stayed a corpse until they rejoined the server -- in a heavy-PvP game, the first death
	ended the session. This System is that missing owner, and nothing else here changes: dummies
	(CombatSystem.confirmDummyDeath) and bots (TrainingBotSystem, off CombatSystem.
	OnTrainingBotKilled) already own their own respawn paths and are untouched by this.

	Triggered off GameplayEvents.OnPlayerKilled -- the documented outward hook for exactly this
	("CombatSystem.OnPlayerKilled is the hook they listen to, not a call this module makes outward",
	CombatSystem.lua's header). That hook is the right one specifically because CombatSystem fires it
	from confirmDeath for EVERY death, not just PvP kills: an environmental/fall/void death runs the
	same path with no killer attribution (see confirmDeath's own header), so routing respawn through
	it covers every way a player can die without this module needing its own duplicate Humanoid.Died
	wiring to go stale alongside CombatSystem's.

	That signal used to be a public BindableEvent field ON CombatSystem, which meant this module
	required a 3400-line combat monolith -- pulling in ten Server/Combat/ siblings and two dozen
	remotes -- to reach one event it only ever listened to. It now requires
	Server/Events/GameplayEvents.lua instead and has no dependency on CombatSystem at all.

	Deliberately a new System rather than a few lines inside CombatSystem or CharacterCreation
	System: software-architecture.md's "don't fold new responsibilities into an existing system's
	file just because it's related." CombatSystem owns combat resolution and explicitly does not own
	post-death consequences; CharacterCreationSystem owns onboarding and the session's first spawn.
	Respawn is a third, genuinely separate player-lifecycle responsibility, and it reaches
	CombatSystem only through that System's public BindableEvent -- never by poking its internals.

	Does not own: WHERE a player respawns. `LoadCharacter()` uses Roblox's own spawn selection
	(Player.RespawnLocation, else any SpawnLocation), which is what should place a returning player;
	CharacterCreationSystem's `resolveArrivalCFrame` post-onboarding teleport is a one-time arrival
	beat, not a respawn rule, and is intentionally not reused here. Does not own death feedback or
	the death UI -- CombatSystem sends the "Death" Combat_FeedbackEvent and the client renders it.
	Does not own dummy/bot respawn (see above).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local GameplayEvents = require(ServerScriptService.Server.Events.GameplayEvents)

local RespawnSystem = {}

local logger = Logger.scope("RespawnSystem")

local Config = Constants.Respawn

-- Per-player respawn generation. Bumped both when a death schedules a respawn AND whenever the
-- player receives ANY new character, so a pending timer only fires if it's still the newest
-- outstanding request for a player who genuinely has not been re-bodied by some other path in the
-- meantime. Two real cases this guards, neither hypothetical:
--   * DevMenuSystem's ForceRespawnTarget (`target:LoadCharacter()`) landing inside the delay window
--     -- without the guard this timer would then load a SECOND character on top of the admin's,
--     destroying the one the admin just spawned.
--   * A player dying, and the death being confirmed again for the replacement life before this
--     timer elapses (a very short DelaySeconds plus an immediate second death).
-- The same generation-guard idiom Client/FX/AnimationTrackUtil.lua's FreezeGuard and CombatClient.
-- lua's jumpSuppressGeneration already use for "a delayed action must not act on a superseded
-- world" -- rather than a bare task.delay that trusts nothing changed while it slept.
local respawnGeneration: { [Player]: number } = {}

local function bumpGeneration(player: Player): number
	local next = (respawnGeneration[player] or 0) + 1
	respawnGeneration[player] = next
	return next
end

-- Loads a replacement character, unless this request has been superseded (see respawnGeneration) or
-- the player has since left. pcall'd because LoadCharacter throws if the Player instance is
-- parented out from under it mid-call -- a player disconnecting during the respawn delay is
-- ordinary, not an error worth propagating out of a task.delay callback where nothing can catch it.
local function respawn(player: Player, generation: number): ()
	if respawnGeneration[player] ~= generation then
		logger:debug("Respawn superseded, skipping", { player = player.Name })
		return
	end
	-- Players.PlayerRemoving has fired (or is mid-flight) -- LoadCharacter on a departed player is
	-- at best wasted work.
	if player.Parent ~= Players then
		logger:debug("Respawn skipped, player left", { player = player.Name })
		return
	end

	local ok, errorMessage = pcall(function()
		player:LoadCharacter()
	end)
	if not ok then
		logger:warn("LoadCharacter failed", { player = player.Name, errorMessage = tostring(errorMessage) })
		return
	end

	logger:info("Player respawned", { player = player.Name })
end

function RespawnSystem.Init(): ()
	-- Fires from CombatSystem.confirmDeath for every death, PvP or environmental -- see this file's
	-- header. killerPlayer is nil for a non-attributed death and is only logged here; who killed whom
	-- is RewardSystem/AbsorbSystem's concern off the same signal, not this module's.
	GameplayEvents.OnPlayerKilled(function(player: Player, killerPlayer: Player?)
		local generation = bumpGeneration(player)
		logger:debug("Respawn scheduled", {
			player = player.Name,
			killer = if killerPlayer then killerPlayer.Name else "none (environmental/other)",
			delaySeconds = Config.DelaySeconds,
		})
		task.delay(Config.DelaySeconds, respawn, player, generation)
	end)

	-- Any character arriving by ANY path (this System's own respawn, CharacterCreationSystem's
	-- session-first spawn, DevMenuSystem's ForceRespawnTarget) invalidates a pending timer -- the
	-- player already has a body, so a queued LoadCharacter would only destroy and replace it.
	local function watchPlayer(player: Player): ()
		player.CharacterAdded:Connect(function()
			bumpGeneration(player)
		end)
	end

	-- Players who joined before this connected (there are none under Main.server.lua's boot order,
	-- but this System must not silently depend on being initialized before the first PlayerAdded).
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
	Players.PlayerAdded:Connect(watchPlayer)

	Players.PlayerRemoving:Connect(function(player: Player)
		respawnGeneration[player] = nil
	end)

	logger:info("RespawnSystem.Init() complete")
end

return RespawnSystem
