--!strict
--[[
	PlayerLifecycle.lua

	Owns: the two player/character binding shapes this codebase writes over and over, and the three
	correctness details every hand-rolled copy of them was supposed to get right.

	BindLocalCharacter (client) replaces the shape that was hand-written in fifteen modules with
	byte-identical race-condition comments:

		local function onCharacterAdded(character) ... end
		localPlayer.CharacterAdded:Connect(onCharacterAdded)
		localPlayer.CharacterRemoving:Connect(onCharacterRemoving)
		if localPlayer.Character then task.spawn(onCharacterAdded, localPlayer.Character) end

	BindAllPlayers (server) replaces the add/sweep/remove triple hand-written in about ten more:

		Players.PlayerAdded:Connect(onPlayerAdded)
		Players.PlayerRemoving:Connect(onPlayerRemoving)
		for _, player in Players:GetPlayers() do onPlayerAdded(player) end

	THE THREE DETAILS, each of which some call sites had and others did not:

	1. WAIT FOR THE HUMANOID. CharacterAdded fires the instant the Model is parented into this
	   client's copy of the DataModel, which is NOT the instant every descendant has replicated. A
	   raw FindFirstChildOfClass("Humanoid") immediately afterwards can lose that race, and every
	   module loses it differently but always silently -- AnimationManager.Bind fails PERMANENTLY for
	   the life it was called for, CombatAnimator leaves `tracks` empty for the life, and neither
	   self-heals without a further respawn. That is what "animations bug out on death and never come
	   back" looks like from the player's seat. Handlers here are only ever called with a Humanoid in
	   hand; a life whose Humanoid never arrives inside Constants.Network.WaitForChildTimeoutSeconds
	   is warned about once, under the caller's own logger scope, and skipped.

	2. NEVER BIND ON THE BOOT THREAD. Waiting for the Humanoid YIELDS, so the already-present-
	   character call must be task.spawn'd -- calling it inline on Main.client.lua's synchronous boot
	   thread makes every module booted afterwards wait behind one character's assembly, up to the
	   full WaitForChild timeout. Five call sites wrapped it and five did not; this module always
	   does, so the distinction stops being something a new call site can get wrong.

	3. RE-CHECK THE CHARACTER AFTER THE YIELD. A fast respawn during the Humanoid wait means the
	   character this handler is about to bind is already the PREVIOUS body. ShiftLockCamera and
	   FlightCamera both guarded this by hand (`if localPlayer.Character ~= character then return`);
	   most sites did not, and would bind a corpse for the rest of the life. Applied uniformly here.

	THE PER-LIFE TROVE is the other half of the contract. Every handler is passed a Shared/Trove.lua
	scope that is Cleaned automatically before the next life binds and on teardown -- so per-life
	connections are released by the structure rather than by a module remembering to nil one specific
	field, which is the leak shape RunController's own sessionConnections/lifeConnections split
	already documents having paid for once.

	Does NOT own: what a module does with a character, any authorization question (nothing here
	consults a whitelist), or the OTHER-player-character watching a few modules do (spectate targets,
	roster rows) -- those bind to a Player this module was never handed, and are deliberately left
	hand-rolled rather than bent into this shape.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local Logger = require(ReplicatedStorage.Shared.Logger)
local Trove = require(ReplicatedStorage.Shared.Trove)

local PlayerLifecycle = {}

export type LocalCharacterHandlers = {
	-- Logger scope the "no Humanoid this life" warning is emitted under -- the CALLER's scope, not
	-- this module's, so the warning names the module that actually lost the binding rather than the
	-- shared helper every module goes through.
	Scope: string,
	-- Called once per life, on its own thread, with the character's Humanoid already resolved and a
	-- per-life Trove that is Cleaned before the next call.
	OnCharacter: (character: Model, humanoid: Humanoid, life: Trove.TroveInstance) -> (),
	-- Called on CharacterRemoving, AFTER the per-life Trove has been cleaned. Optional: a module
	-- whose entire per-life state is tracked in the Trove needs no teardown callback at all, which is
	-- the point.
	OnCharacterRemoving: (() -> ())?,
}

export type PlayerHandlers = {
	Scope: string,
	-- Called once per player, present-at-Init and future alike, with a per-player Trove cleaned when
	-- they leave. Runs BEFORE any OnCharacter call for that player.
	OnPlayer: ((player: Player, session: Trove.TroveInstance) -> ())?,
	-- Called on PlayerRemoving, AFTER that player's Trove (and any live per-life Trove inside it) has
	-- been cleaned -- so a handler here only has to drop the module's OWN per-player table entry.
	OnPlayerRemoving: ((player: Player) -> ())?,
	OnCharacter: ((player: Player, character: Model, humanoid: Humanoid, life: Trove.TroveInstance) -> ())?,
	OnCharacterRemoving: ((player: Player, character: Model) -> ())?,
}

-- Resolves `character`'s Humanoid, waiting out the replication race in detail 1 above. Returns nil
-- (having warned under the caller's scope) if it never arrives -- the caller skips the life rather
-- than binding half of it.
local function resolveHumanoid(scope: string, character: Model): Humanoid?
	local humanoid = CharacterUtil.AwaitHumanoid(character)
	if humanoid then
		return humanoid
	end
	Logger.scope(scope):warn("No Humanoid resolved -- not bound this life", { character = character.Name })
	return nil
end

-- Binds the LOCAL player's successive characters. Returns the session Trove: Clean() it to
-- disconnect everything and release the current life, which is what a module's own Stop() wants.
--
-- Safe to call before the local player has a character, after they already have one, and from
-- Main.client.lua's synchronous boot thread -- none of the three is a distinction a caller has to
-- make, which is the whole reason five of the fifteen sites this replaces got it wrong.
function PlayerLifecycle.BindLocalCharacter(handlers: LocalCharacterHandlers): Trove.TroveInstance
	local session = Trove.New()
	local life = session:Extend()
	local localPlayer = Players.LocalPlayer

	local function bind(character: Model): ()
		-- Cleaned FIRST, not after the wait below: a new body means the previous life's connections
		-- are already meaningless, and a Humanoid that never arrives must not leave them live.
		life:Clean()

		local humanoid = resolveHumanoid(handlers.Scope, character)
		if not humanoid then
			return
		end
		-- Detail 3: the wait above yields, and a fast respawn during it means this is already the
		-- previous body. Binding it would spend the whole next life driving a corpse.
		if localPlayer.Character ~= character then
			return
		end
		handlers.OnCharacter(character, humanoid, life)
	end

	session:Connect(localPlayer.CharacterAdded, bind)
	session:Connect(localPlayer.CharacterRemoving, function()
		life:Clean()
		if handlers.OnCharacterRemoving then
			handlers.OnCharacterRemoving()
		end
	end)

	local existing = localPlayer.Character
	if existing then
		-- Detail 2: bind() yields. This is the Studio play-solo and fast-rejoin path -- the one a
		-- developer boots through most often -- and calling it inline here is what used to stall the
		-- rest of the client boot behind one character's assembly.
		task.spawn(bind, existing)
	end

	return session
end

-- Binds EVERY player, present and future. Returns the master Trove: Clean() it to disconnect the
-- Players signals and release every live per-player scope.
--
-- The Init()-time GetPlayers() sweep is not optional and not a caller's responsibility here: a
-- player who joined before this System booted is otherwise never bound, which is a bug that only
-- reproduces under a real join race and never in Studio.
function PlayerLifecycle.BindAllPlayers(handlers: PlayerHandlers): Trove.TroveInstance
	local master = Trove.New()
	local sessions: { [Player]: Trove.TroveInstance } = {}

	local function addPlayer(player: Player): ()
		-- The Init sweep below and the PlayerAdded signal can both reach the same player when someone
		-- joins mid-boot. Binding twice would double every connection this makes.
		if sessions[player] then
			return
		end
		local session = Trove.New()
		sessions[player] = session

		if handlers.OnPlayer then
			handlers.OnPlayer(player, session)
		end

		if handlers.OnCharacter or handlers.OnCharacterRemoving then
			local life = session:Extend()

			local function bindCharacter(character: Model): ()
				life:Clean()
				local humanoid = resolveHumanoid(handlers.Scope, character)
				if not humanoid then
					return
				end
				-- Same post-yield re-check as the client path. On the server the Humanoid is normally
				-- present the instant CharacterAdded fires, so this only ever fires on a genuinely
				-- pathological respawn -- but "normally" is not a guarantee worth binding a corpse over.
				if player.Character ~= character then
					return
				end
				if handlers.OnCharacter then
					handlers.OnCharacter(player, character, humanoid, life)
				end
			end

			session:Connect(player.CharacterAdded, bindCharacter)
			session:Connect(player.CharacterRemoving, function(character: Model)
				life:Clean()
				if handlers.OnCharacterRemoving then
					handlers.OnCharacterRemoving(player, character)
				end
			end)

			local existing = player.Character
			if existing then
				task.spawn(bindCharacter, existing)
			end
		end
	end

	local function removePlayer(player: Player): ()
		local session = sessions[player]
		if session then
			sessions[player] = nil
			session:Clean()
		end
		if handlers.OnPlayerRemoving then
			handlers.OnPlayerRemoving(player)
		end
	end

	master:Connect(Players.PlayerAdded, addPlayer)
	master:Connect(Players.PlayerRemoving, removePlayer)
	-- Cleaning the master must not leave live per-player connections behind. Tracked as a teardown
	-- closure rather than as nested Troves, because a session is dropped from tracking when its
	-- player leaves -- nesting would grow the master's list by one dead entry per join for the whole
	-- life of the server.
	master:Add(function()
		for player, session in sessions do
			sessions[player] = nil
			session:Clean()
		end
	end)

	for _, player in Players:GetPlayers() do
		addPlayer(player)
	end

	return master
end

return PlayerLifecycle
