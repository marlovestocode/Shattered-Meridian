--!strict
--[[
	EmoteSystem.lua

	Owns: legality/validation for playing an emote, the one authoritative start/stop lifecycle
	(activeEmotes below), the Humanoid movement-lock Attribute an emote sets while it plays, the
	player's loadout (Types.PlayerProfile.emoteLoadout), and every Remote this feature exposes
	(EmoteConstants.RemoteNames). Boots after PlayerDataSystem and EmoteUnlockService -- see
	Main.server.lua's own numbered boot-order comments for exactly why each has to exist first.

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
	established idiom for "an effect that should end after N seconds" is an expiry timestamp checked
	on the next tick, never a scheduled callback that could race a manual stop. activeEmotes[player].
	EndsAt is exactly that: set at start time for a non-Loop emote, left nil for a Loop emote, and
	checked in the OnHeartbeatTick handler below -- one read of activeEmotes per tick.

	WHAT ENDS A ONE-SHOT EMOTE, and why the authored Duration is no longer it. EndsAt used to be
	`now + definition.Duration`, which silently truncated any emote whose real animation ran longer
	than that hand-authored number: the emote's visible length was min(Duration, clip length), and
	nothing anywhere forced those two to agree. AnimationTrack.Length is a CLIENT-side value (this
	server never loads the clip at all), so a Duration typed into EmoteDefinitions.lua is only ever a
	guess about an asset an artist uploads separately -- and a guess that goes stale the moment a clip
	is swapped, with the only symptom being an emote that visibly cuts off mid-motion.

	So the real stop for a CLIP-BEARING one-shot (definition.AnimationId ~= "") is now the acting
	client's own Emote_NotifyFinished report, raised when its AnimationTrack actually ends -- see
	handleNotifyFinished below for how that report is validated, and Client/FX/EmoteAnimator.lua's
	SetFinishedCallback for why only that side can raise it. EndsAt survives as the safety valve
	behind it (EmoteConstants.MaxOneShotSeconds, deliberately NOT derived from Duration -- see that
	constant), covering a client that never reports at all. An emote with NO clip authored yet still
	falls back to Duration exactly as before: there is no track to finish, so no report is coming.

	This also removes a latency bug that applied even to correctly-authored Durations. The old EndsAt
	clock started when the SERVER accepted RequestPlay, but the animation didn't begin until the
	Emote_Started echo reached the client one round trip later -- so every emote lost roughly an RTT
	off its tail. The client's own track is now what times the emote, so that skew is gone; the
	residual cost moved to the benign side (the movement lock outlives the animation by the one-way
	trip of the finish report, rather than the animation being cut short by a full round trip).

	WHAT ENDS A LOOPING EMOTE, and why it needed a remote of its own. A Loop emote (Sit, Dance) has no
	EndsAt and no track that could ever finish, so neither of the two stops above can reach it -- and
	both of those emotes are also MovementLocked, which means the WalkSpeed this file zeroes at start
	was left zeroed. Until Emote_RequestStop existed, a player who sat down had exactly three exits: be
	attacked (the InCombat interruption below), die, or leave. Sitting down was a trap.

	So the third stop is the player's own: Emote_RequestStop, fired by Client/Emotes/EmoteWheelClient.
	lua the moment they press a movement or jump key. It is a command rather than a report -- see
	handleRequestStop for why that distinction lets it skip the emote-id validation NotifyFinished
	needs -- and it ends a one-shot just as readily as a loop, which is also the fix for the other half
	of the same complaint: a one-shot emote rejects any other RequestPlay until it ends (see below), so
	without a cancel a mistaken Bow held the wheel shut for its whole duration.

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
	Types.PlayerProfile.unlockedEmoteIds directly. Does not own movement state itself --
	Server/Systems/RunSystem.lua's resolver (not this file) is what actually zeroes WalkSpeed once the
	EmoteMovementLocked Attribute is set.

	PARTIALLY GATED ON COMBAT STATE AGAIN, THROUGH ONE ATTRIBUTE. RequestPlay and the active-emote
	monitor below used to read CombatSystem.GetCombatState and reject/interrupt an emote for being dead,
	stunned, posture-broken, ragdolled, held aloft, mid-swing, or (for a non-CombatAllowed emote) simply
	in combat. That module was deleted in the combat teardown and every one of those gates went with it.

	Exactly ONE of them is back: EmoteDefinition.CombatAllowed. Server/Combat/Engagement/
	EngagementSystem.lua now publishes Constants.Attributes.InCombat, so a non-CombatAllowed emote (Sit,
	Dance, Meditate, Kneel, Sleep -- the sustained, vulnerable poses) is refused while that Attribute is
	set, and an already-running one is interrupted the moment it becomes set. That field had been
	authored on all 11 emotes and validated by EmoteRegistry while being read by literally nothing.

	READ AS AN ATTRIBUTE, NOT THROUGH A require. This is a Systems/ module; EngagementSystem is a
	Combat/ one, and taking a dependency on it would invert the same layering the Mounted gate below
	already avoids the same way. The Attribute seam is the whole interface.

	The other gates stay gone, and their state genuinely does not exist to re-derive: stunned/posture-
	broken/ragdolled/held-aloft/mid-swing all lived on CombatState. CancelOnDamage is likewise still
	inert -- it compared live Health against the emote's starting Health, which nothing tracks now.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Types = require(ReplicatedStorage.Shared.Types)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local Constants = require(ReplicatedStorage.Shared.Constants)
local EmoteConstants = require(ReplicatedStorage.Shared.EmoteConstants)
local EmoteRegistry = require(ReplicatedStorage.Shared.Emotes.EmoteRegistry)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local GameplayEvents = require(ServerScriptService.Server.Events.GameplayEvents)
local PlayerDataSystem = require(script.Parent.PlayerDataSystem)
local EmoteUnlockService = require(script.Parent.EmoteUnlockService)

local logger = Logger.scope("EmoteSystem")

local EmoteSystem = {}

type ActiveEmote = {
	EmoteId: Types.EmoteId,
	-- nil for a Loop emote (never auto-stops on its own). For a one-shot this is the LATEST this emote
	-- may run, not the moment it is expected to end -- see this file's header (WHAT ENDS A ONE-SHOT
	-- EMOTE): a clip-bearing emote is normally stopped by the client's own Emote_NotifyFinished and
	-- only falls back to this ceiling if that never arrives, while a clipless one still ends exactly
	-- at its authored Duration.
	EndsAt: number?,
	-- Whether this emote survives entering combat, copied off the definition when the emote starts.
	--
	-- The monitor below used to call EmoteRegistry.Get(active.EmoteId) once per active emoter per
	-- frame to re-read this one boolean off static content (EmoteDefinitions.lua never changes at
	-- runtime, which is why the registry's own miss branch is documented as defensive-only). Copying
	-- it at start turns the whole per-frame lookup into a field read, and cannot go stale: an emote
	-- that is running already had its definition resolved, and a definition cannot change under it.
	CombatAllowed: boolean,
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

local function setMovementLocked(player: Player, locked: boolean): ()
	local _, humanoid = CharacterUtil.LiveRig(player)
	if not humanoid then
		return
	end
	if locked then
		humanoid:SetAttribute(Constants.Attributes.EmoteMovementLocked, true)
	else
		-- nil clears the Attribute entirely (SetAttribute(name, nil) removes it) rather than leaving
		-- a stale `false` behind -- matches Server/Systems/RunSystem.lua's own `== true` reads for
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

-- Whether this emote has a real animation clip authored yet. The SAME condition Client/FX/
-- EmoteAnimator.lua uses to decide whether to build a template at all, derived on both sides from the
-- same static EmoteDefinitions.lua content -- which is what makes it safe for this server to predict
-- whether an Emote_NotifyFinished report is ever coming for a given emote without asking the client.
local function hasClip(definition: Types.EmoteDefinition): boolean
	return definition.AnimationId ~= ""
end

-- See this file's header (WHAT ENDS A ONE-SHOT EMOTE) for the reasoning behind all three branches.
local function computeEndsAt(definition: Types.EmoteDefinition, now: number): number?
	if definition.Loop then
		return nil
	end
	if hasClip(definition) then
		-- The client's own track times this emote; this is only the backstop.
		return now + EmoteConstants.MaxOneShotSeconds
	end
	-- No clip authored yet -- no track will ever finish, so the authored Duration is the only signal
	-- available and stays authoritative exactly as it was before.
	return now + (definition.Duration or 0)
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

-- Whether this rig is currently combat-tagged (Server/Combat/Engagement/EngagementSystem.lua writes
-- the Attribute on each true/false edge). One helper rather than the read inline twice, so the
-- refusal in handleRequestPlay and the interruption in onHeartbeatTick can never disagree about what
-- "in combat" means.
local function isInCombat(humanoid: Humanoid): boolean
	return humanoid:GetAttribute(Constants.Attributes.InCombat) == true
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

	-- A mounted body is welded to a blimp station and its arms are being driven by the mount's own pose
	-- solver (Shared/Blimp/BlimpArmPose.lua). An emote here would play a full-body clip the pose then
	-- half-overwrites, which looks like a bug in both systems at once. Read as an Attribute rather than
	-- through a BlimpSystem require -- the same seam the two combat gates use.
	local _, gateHumanoid = CharacterUtil.LiveRig(player)
	if gateHumanoid and gateHumanoid:GetAttribute(Constants.Attributes.Mounted) == true then
		logger:debug("RequestPlay rejected: Mounted", { player = player.Name, emoteId = emoteId })
		return
	end

	-- A sustained, vulnerable pose has no place mid-skirmish -- EmoteDefinition.CombatAllowed's own
	-- header. A quick social gesture (Wave, Taunt, Point) is deliberately still allowed to carry into a
	-- lingering in-combat window, which is why this reads the emote's own flag rather than refusing
	-- everything. Same Attribute seam as the Mounted gate directly above; see this file's header on why
	-- it is not a require into EngagementSystem.
	if not definition.CombatAllowed and gateHumanoid and isInCombat(gateHumanoid) then
		logger:debug("RequestPlay rejected: InCombat", { player = player.Name, emoteId = emoteId })
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

	local now = os.clock()
	activeEmotes[player] = {
		EmoteId = emoteId,
		EndsAt = computeEndsAt(definition, now),
		CombatAllowed = definition.CombatAllowed,
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

-- The acting client reporting that its own AnimationTrack for `rawEmoteId` reached its natural end --
-- the normal stop for a clip-bearing one-shot emote (see this file's header). Treated as a REPORT
-- about an emote this server already knows is running, never as a command: the only thing a player
-- can achieve by firing this is ending their own current emote, which they can already do by playing
-- another one.
--
-- Shares playRateLimiter with RequestPlay rather than taking a third bucket -- unlike the
-- RequestPlay/RequestSetLoadoutSlot split (two genuinely independent player actions that must not
-- starve each other), this fires at most once per accepted RequestPlay and is bounded by the same
-- budget that gates those starts in the first place.
local function handleNotifyFinished(player: Player, rawEmoteId: unknown): ()
	if playRateLimiter:IsLimited(player) then
		return
	end
	if typeof(rawEmoteId) ~= "string" then
		logger:debug("NotifyFinished: non-string emoteId ignored", { player = player.Name })
		return
	end
	local emoteId = rawEmoteId :: string

	local active = activeEmotes[player]
	if not active then
		-- Routine, not suspicious: the server may already have stopped this emote (death, the
		-- interruption guard, a superseding play) in the time the report spent in flight.
		logger:debug("NotifyFinished ignored: no active emote", { player = player.Name, emoteId = emoteId })
		return
	end
	if active.EmoteId ~= emoteId then
		logger:debug("NotifyFinished ignored: stale emoteId", {
			player = player.Name,
			reported = emoteId,
			active = active.EmoteId,
		})
		return
	end

	local definition = EmoteRegistry.Get(emoteId)
	if not definition then
		return
	end
	-- A Loop emote has no natural end, and a clipless one has no track that could have finished --
	-- in both cases the report is meaningless and accepting it would let a client cut short an emote
	-- whose length this server is still the sole owner of.
	if definition.Loop or not hasClip(definition) then
		logger:debug("NotifyFinished ignored: emote does not end on its own animation", {
			player = player.Name,
			emoteId = emoteId,
		})
		return
	end

	EmoteSystem.StopEmote(player)
end

-- The player asking to end their own current emote -- see EmoteConstants.RemoteNames.RequestStop for
-- why this remote has to exist at all (a Loop emote had no exit that did not involve dying).
--
-- No payload, no emote-id match, and no legality check beyond the rate limit: unlike
-- handleNotifyFinished above (a REPORT about one specific track, which must be validated against the
-- active emote or a client could cut short an emote whose length this server owns), this is a
-- COMMAND about the caller themselves, and StopEmote is already a safe no-op on a player with
-- nothing running. There is no state a player can reach with it that they cannot already reach by
-- playing a different emote.
--
-- Shares playRateLimiter with RequestPlay/NotifyFinished for the same reason NotifyFinished does:
-- starting and ending your own pose is one budget, and a stop is only ever reachable after a start
-- that already spent from it.
local function handleRequestStop(player: Player): ()
	if playRateLimiter:IsLimited(player) then
		return
	end
	EmoteSystem.StopEmote(player)
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
		if active.EndsAt and now >= active.EndsAt then
			EmoteSystem.StopEmote(player)
			continue
		end

		-- Entering combat DURING a vulnerable pose breaks it. Refusing the start (handleRequestPlay)
		-- without this would leave a player who sat down a half-second before being attacked seated for
		-- the whole fight -- the one case the gate is most obviously meant to cover. Loop emotes are the
		-- ones this actually catches, since they have no EndsAt of their own to expire.
		if not active.CombatAllowed then
			-- HumanoidOf, not LiveRig -- only the Humanoid is used here, and LiveRig also resolves the
			-- root (a second FindFirstChild scan of the character) purely to discard it.
			local character = player.Character
			local humanoid = if character then CharacterUtil.HumanoidOf(character) else nil
			if humanoid and isInCombat(humanoid) then
				logger:debug("Emote interrupted: InCombat", { player = player.Name, emoteId = active.EmoteId })
				EmoteSystem.StopEmote(player)
				continue
			end
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

	local notifyFinishedRemote = NetworkBridge.CreateRemoteEvent(EmoteConstants.RemoteNames.NotifyFinished)
	notifyFinishedRemote.OnServerEvent:Connect(handleNotifyFinished)

	local requestStopRemote = NetworkBridge.CreateRemoteEvent(EmoteConstants.RemoteNames.RequestStop)
	requestStopRemote.OnServerEvent:Connect(handleRequestStop)

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

	PlayerLifecycle.BindAllPlayers({
		Scope = "EmoteSystem",
		OnPlayerRemoving = onPlayerRemoving,
	})

	logger:info("EmoteSystem.Init() complete")
end

return EmoteSystem :: Types.SystemModule
