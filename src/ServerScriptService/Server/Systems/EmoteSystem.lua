--!strict
--[[
	EmoteSystem.lua

	Owns: legality/validation for playing an emote, the one authoritative start/stop lifecycle
	(activeEmotes below), the Humanoid movement-lock Attribute an emote sets while it plays, the
	player's loadout (Types.PlayerProfile.emoteLoadout), and every Remote this feature exposes
	(EmoteConstants.RemoteNames). Boots after PlayerDataSystem, EmoteUnlockService, and CombatSystem
	-- see Main.server.lua's own numbered boot-order comments for exactly why each has to exist
	first.

	Phase 1 of 2 -- this is the full backend; the radial wheel UI (a later session) is pure
	presentation on top of it. That's a binding requirement, not just a convenient split: everything
	in this file must work correctly with ZERO client UI attached, driven purely by RequestPlay/
	RequestSetLoadoutSlot remote calls -- nothing here may assume a wheel exists.

	ANIMATION REPLICATION. Mirrors CombatSystem's own contract exactly (see Client/FX/CombatAnimator.
	lua's header): this module validates legality only and fires Started to the ACTING PLAYER'S OWN
	CLIENT ONLY (FireClient, never FireAllClients). That one client then loads and plays the real
	AnimationTrack itself (Client/FX/EmoteAnimator.lua), which Roblox replicates to every other client
	for free. This file never loads or plays an AnimationTrack itself.

	STOP SCHEDULING. A non-loop emote's automatic stop is NOT a task.delay -- this codebase's own
	established idiom for "an effect that should end after N seconds" (CombatState.Vitals.
	stunExpiry/ragdollExpiry, AirComboState.airComboHeldExpiry, ...) is an expiry timestamp checked on
	the next tick, never a scheduled callback that could race a manual stop. activeEmotes[player].
	EndsAt is exactly that: set at start time for a Duration-bearing emote, left nil for a Loop
	emote, and checked in the SAME OnHeartbeatTick handler that already reads CombatSnapshot for the
	interruption guard below -- one read of activeEmotes per tick, not two competing timers.

	RE-TRIGGER SEMANTICS (RequestPlay while an emote is already active). A LOOPING emote (Sit/Dance)
	may be freely replaced by another RequestPlay at any time -- StopEmote runs first, then the new
	one starts, the same "wheel picks a different pose" interaction a player expects. A NON-LOOP
	emote (Wave, Bow, ...) rejects a RequestPlay for anything else until it finishes on its own (or is
	cut short by the interruption guard/death) -- letting a one-shot gesture be endlessly re-chopped
	by mashing the same remote would read as broken, not responsive, and the animation has no
	meaningful "resume" concept to interrupt into. This is a design choice this file owns, not a
	limitation -- see handleRequestPlay's own "EmoteInProgress" branch.

	Does not own: which emotes a player has UNLOCKED (Server/Systems/EmoteUnlockService.lua) --
	RequestPlay/RequestSetLoadoutSlot both defer to EmoteUnlockService.HasUnlocked rather than reading
	Types.PlayerProfile.unlockedEmoteIds directly. Does not own combat/movement state itself --
	CombatSystem.GetCombatState is the only read this file performs of that state, and Server/Combat/
	Movement.lua's ComputeDesiredWalkSpeed (not this file) is what actually zeroes WalkSpeed once the
	EmoteMovementLocked Attribute is set.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Types = require(ReplicatedStorage.Shared.Types)
local Constants = require(ReplicatedStorage.Shared.Constants)
local EmoteConstants = require(ReplicatedStorage.Shared.EmoteConstants)
local EmoteRegistry = require(ReplicatedStorage.Shared.Emotes.EmoteRegistry)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local Logger = require(ReplicatedStorage.Shared.Logger)
local GameplayEvents = require(ServerScriptService.Server.Events.GameplayEvents)
local PlayerDataSystem = require(script.Parent.PlayerDataSystem)
local EmoteUnlockService = require(script.Parent.EmoteUnlockService)
local CombatSystem = require(script.Parent.CombatSystem)

local logger = Logger.scope("EmoteSystem")

local EmoteSystem = {}

type ActiveEmote = {
	EmoteId: Types.EmoteId,
	-- Health at the moment this emote started -- CancelOnDamage compares the LIVE snapshot's Health
	-- against this, not against MaxHealth or a delta threshold, so any confirmed damage (however
	-- small) breaks a vulnerable pose.
	StartedHealth: number,
	-- nil for a Loop emote (never auto-stops on its own); os.clock() + Duration for a one-shot --
	-- see this file's header on why this is a checked expiry, not a task.delay.
	EndsAt: number?,
}

-- One entry per player currently playing an emote -- O(concurrent emoters), read once per
-- OnHeartbeatTick per this file's own header.
local activeEmotes: { [Player]: ActiveEmote } = {}

-- Two independent per-player-per-second budgets built from the SAME EmoteConstants.
-- MaxRequestsPerSecondPerPlayer number -- CombatSystem.lua's attackRateLimiter/defensiveRateLimiter/
-- utilityRateLimiter precedent: a burst against RequestPlay (mashing the wheel) must never be able
-- to silently eat a RequestSetLoadoutSlot press sharing the same bucket, and vice versa.
local playRateLimiter = RateLimiter.New(EmoteConstants.MaxRequestsPerSecondPerPlayer)
local loadoutRateLimiter = RateLimiter.New(EmoteConstants.MaxRequestsPerSecondPerPlayer)

local startedRemote: RemoteEvent? = nil
local stoppedRemote: RemoteEvent? = nil
local loadoutUpdatedRemote: RemoteEvent? = nil
local unlockedUpdatedRemote: RemoteEvent? = nil

local function getHumanoid(player: Player): Humanoid?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

local function setMovementLocked(player: Player, locked: boolean): ()
	local humanoid = getHumanoid(player)
	if not humanoid then
		return
	end
	if locked then
		humanoid:SetAttribute(Constants.Attributes.EmoteMovementLocked, true)
	else
		-- nil clears the Attribute entirely (SetAttribute(name, nil) removes it) rather than leaving
		-- a stale `false` behind -- matches Movement.ComputeDesiredWalkSpeed's own `== true` reads for
		-- every sibling Attribute (Frozen/Flying), which treat "absent" and "false" identically.
		humanoid:SetAttribute(Constants.Attributes.EmoteMovementLocked, nil)
	end
end

local function sendUnlockedUpdated(player: Player): ()
	if not unlockedUpdatedRemote then
		return
	end
	local payload: Types.EmoteUnlockedUpdatePayload = { EmoteIds = EmoteUnlockService.GetUnlockedIds(player) }
	unlockedUpdatedRemote:FireClient(player, payload)
end

local function sendLoadoutUpdated(player: Player): ()
	if not loadoutUpdatedRemote then
		return
	end
	local profile = PlayerDataSystem.GetProfile(player)
	local loadout = if profile then profile.emoteLoadout else table.clone(EmoteConstants.DefaultLoadout)
	local payload: Types.EmoteLoadoutUpdatePayload = { Loadout = loadout }
	loadoutUpdatedRemote:FireClient(player, payload)
end

-- The one authoritative stop path -- see this file's header. Safe to call on a player with no active
-- emote (every call site below treats it as an unconditional "make sure this player isn't emoting,"
-- not something that needs its own existence check first).
function EmoteSystem.StopEmote(player: Player): ()
	local active = activeEmotes[player]
	if not active then
		return
	end
	activeEmotes[player] = nil

	local definition = EmoteRegistry.Get(active.EmoteId)
	if definition and definition.MovementLocked then
		setMovementLocked(player, false)
	end

	if stoppedRemote then
		local payload: Types.EmoteStoppedPayload = { EmoteId = active.EmoteId }
		stoppedRemote:FireClient(player, payload)
	end

	logger:debug("Emote stopped", { player = player.Name, emoteId = active.EmoteId })
end

local function handleRequestPlay(player: Player, rawEmoteId: unknown): ()
	if playRateLimiter:IsLimited(player) then
		return
	end
	if typeof(rawEmoteId) ~= "string" then
		logger:debug("RequestPlay: non-string emoteId ignored", { player = player.Name })
		return
	end
	local emoteId = rawEmoteId :: string

	if not EmoteRegistry.Exists(emoteId) then
		logger:debug("RequestPlay rejected: UnknownEmote", { player = player.Name, emoteId = emoteId })
		return
	end
	local definition = EmoteRegistry.Get(emoteId) :: Types.EmoteDefinition

	if not EmoteUnlockService.HasUnlocked(player, emoteId) then
		logger:debug("RequestPlay rejected: NotUnlocked", { player = player.Name, emoteId = emoteId })
		return
	end

	-- Re-trigger semantics -- see this file's header. A currently-playing LOOP emote is simply
	-- replaced; a currently-playing ONE-SHOT emote rejects until it ends on its own.
	local existing = activeEmotes[player]
	if existing then
		local existingDefinition = EmoteRegistry.Get(existing.EmoteId)
		if existingDefinition and not existingDefinition.Loop then
			logger:debug("RequestPlay rejected: EmoteInProgress", { player = player.Name, emoteId = emoteId })
			return
		end
		EmoteSystem.StopEmote(player)
	end

	local snapshot = CombatSystem.GetCombatState(player)
	if not snapshot then
		logger:debug("RequestPlay rejected: NoCombatState", { player = player.Name, emoteId = emoteId })
		return
	end

	if
		not snapshot.Alive
		or snapshot.Stunned
		or snapshot.PostureBroken
		or snapshot.Ragdolled
		or snapshot.HeldAloft
		or snapshot.Attacking
		or (not definition.CombatAllowed and snapshot.InCombat)
	then
		logger:debug("RequestPlay rejected: RestrictedState", {
			player = player.Name,
			emoteId = emoteId,
			alive = snapshot.Alive,
			stunned = snapshot.Stunned,
			postureBroken = snapshot.PostureBroken,
			ragdolled = snapshot.Ragdolled,
			heldAloft = snapshot.HeldAloft,
			attacking = snapshot.Attacking,
			inCombat = snapshot.InCombat,
		})
		return
	end

	local now = os.clock()
	activeEmotes[player] = {
		EmoteId = emoteId,
		StartedHealth = snapshot.Health,
		EndsAt = if definition.Loop then nil else now + (definition.Duration or 0),
	}

	if definition.MovementLocked then
		setMovementLocked(player, true)
	end

	if startedRemote then
		local payload: Types.EmoteStartedPayload = { EmoteId = emoteId }
		startedRemote:FireClient(player, payload)
	end

	logger:debug("Emote started", { player = player.Name, emoteId = emoteId })
end

local function handleRequestSetLoadoutSlot(player: Player, rawSlotIndex: unknown, rawEmoteId: unknown): ()
	if loadoutRateLimiter:IsLimited(player) then
		return
	end
	-- rawSlotIndex ~= rawSlotIndex is the standard NaN test (NaN is the only Luau value unequal to
	-- itself) -- without it, a NaN slot index passes typeof/math.floor/range checks unrejected (NaN
	-- compares false against both < 1 and > LoadoutSize) and reaches `profile.emoteLoadout[slotIndex]
	-- = emoteId` below, which errors ("table index is NaN") inside PlayerDataSystem.Transform's
	-- mutator instead of being cleanly rejected here.
	if typeof(rawSlotIndex) ~= "number" or rawSlotIndex ~= rawSlotIndex or typeof(rawEmoteId) ~= "string" then
		logger:debug("RequestSetLoadoutSlot: malformed arguments ignored", { player = player.Name })
		return
	end

	local slotIndex = math.floor(rawSlotIndex :: number)
	if slotIndex < 1 or slotIndex > EmoteConstants.LoadoutSize then
		logger:debug("RequestSetLoadoutSlot rejected: OutOfRange", { player = player.Name, slotIndex = slotIndex })
		return
	end

	local emoteId = rawEmoteId :: string
	if not EmoteUnlockService.HasUnlocked(player, emoteId) then
		logger:debug("RequestSetLoadoutSlot rejected: NotUnlocked", { player = player.Name, emoteId = emoteId })
		return
	end

	local transformed = PlayerDataSystem.Transform(player, function(profile)
		profile.emoteLoadout[slotIndex] = emoteId
	end)
	if not transformed then
		logger:warn("RequestSetLoadoutSlot: Transform failed (profile not loaded)", { player = player.Name })
		return
	end

	sendLoadoutUpdated(player)
end

local function onProfileLoaded(player: Player): ()
	sendUnlockedUpdated(player)
	sendLoadoutUpdated(player)
end

-- See this file's header on why a Duration-bearing emote's stop is a checked expiry here, not a
-- scheduled task.delay -- and why this piggybacks GameplayEvents.OnHeartbeatTick rather than opening
-- a second RunService.Heartbeat connection (that signal's own header: the sanctioned seam for
-- exactly this kind of per-frame work).
local function onHeartbeatTick(): ()
	if next(activeEmotes) == nil then
		return
	end

	local now = os.clock()
	for player, active in activeEmotes do
		local definition = EmoteRegistry.Get(active.EmoteId)
		if not definition then
			-- Defensive only -- an emote that was legal to start can't stop existing in the registry
			-- mid-flight (EmoteDefinitions.lua is static content), but a stale/malformed entry should
			-- never spin forever.
			EmoteSystem.StopEmote(player)
			continue
		end

		if active.EndsAt and now >= active.EndsAt then
			EmoteSystem.StopEmote(player)
			continue
		end

		local snapshot = CombatSystem.GetCombatState(player)
		if not snapshot then
			EmoteSystem.StopEmote(player)
			continue
		end

		if
			not snapshot.Alive
			or snapshot.Stunned
			or snapshot.PostureBroken
			or snapshot.Ragdolled
			or snapshot.HeldAloft
			or snapshot.Attacking
		then
			EmoteSystem.StopEmote(player)
			continue
		end

		if definition.CancelOnDamage and snapshot.Health < active.StartedHealth then
			EmoteSystem.StopEmote(player)
			continue
		end
	end
end

local function onPlayerRemoving(player: Player): ()
	activeEmotes[player] = nil
	playRateLimiter:Clear(player)
	loadoutRateLimiter:Clear(player)
end

function EmoteSystem.Init(): ()
	startedRemote = NetworkBridge.CreateRemoteEvent(EmoteConstants.RemoteNames.Started)
	stoppedRemote = NetworkBridge.CreateRemoteEvent(EmoteConstants.RemoteNames.Stopped)
	loadoutUpdatedRemote = NetworkBridge.CreateRemoteEvent(EmoteConstants.RemoteNames.LoadoutUpdated)
	unlockedUpdatedRemote = NetworkBridge.CreateRemoteEvent(EmoteConstants.RemoteNames.UnlockedUpdated)

	local requestPlayRemote = NetworkBridge.CreateRemoteEvent(EmoteConstants.RemoteNames.RequestPlay)
	requestPlayRemote.OnServerEvent:Connect(handleRequestPlay)

	local requestSetLoadoutSlotRemote =
		NetworkBridge.CreateRemoteEvent(EmoteConstants.RemoteNames.RequestSetLoadoutSlot)
	requestSetLoadoutSlotRemote.OnServerEvent:Connect(handleRequestSetLoadoutSlot)

	PlayerDataSystem.OnProfileLoaded.Event:Connect(onProfileLoaded)
	EmoteUnlockService.OnEmoteGranted.Event:Connect(function(player: Player, _emoteId: string)
		sendUnlockedUpdated(player)
	end)

	GameplayEvents.OnHeartbeatTick(onHeartbeatTick)
	GameplayEvents.OnPlayerKilled(function(victim: Player, _killer: Player?)
		EmoteSystem.StopEmote(victim)
	end)

	Players.PlayerRemoving:Connect(onPlayerRemoving)

	logger:info("EmoteSystem.Init() complete")
end

return EmoteSystem :: Types.SystemModule
