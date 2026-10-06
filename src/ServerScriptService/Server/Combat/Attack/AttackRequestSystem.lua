--!strict
--[[
	AttackRequestSystem.lua

	Owns: the Attack layer's public surface -- the request remote, the gates a press has to clear, the
	per-move cooldown, the forgiving input buffer, the call into HitboxEngine, and the confirmation
	the attacker gets back.

	    HitboxEngine     where the volume is, who is inside it
	    DefenseSystem    what kind of hit that was
	    DamageSystem     how much it hurts, what it does to you
	    AttackLayer      what you are trying to throw, and whether you may   <- this module

	It is the piece the other three were built without: HitboxEngine.RequestAttack had exactly one
	caller before this file, Server/Combat/TestAttackHarness.lua, which existed only so the defence
	layer had something to classify and which this module DELETES on arrival, exactly as its own header
	always said it would.

	NOTHING BELOW IT WAS REWRITTEN TO ACCOMMODATE IT. This module consumes three already-shipped
	queries in the shape they already had -- DefenseSystem.CanAttack (which had no caller at all until
	now; its own header says so), DamageSystem.CanAttack, and HitboxEngine.RequestAttack -- and adds
	two gates of its own that no lower layer could own: the move's authored Cooldown, and the
	deliberate beat between links of a string (AttackConstants.Sequence.ChainDelaySeconds, owned by
	SwingSequencer because it is a property of the string rather than of any move). That is the whole
	integration surface.

	IT ALSO OWNS ENGINE REGISTRATION, inherited from the harness. HitboxEngine and DefenseSystem keep
	SEPARATE registries by design (see DefenseSystem's own header on why), and DefenseSystem registers
	player characters itself. The engine's registry had no owner but the harness, so it moves here --
	the layer that actually throws things is the natural home for "who is a fighter the engine knows
	about." A bot or a dummy still calls HitboxEngine.RegisterCombatant directly, exactly as before.

	THREE GATES, NOT ONE, AND NO TWO SYSTEMS KNOW EACH OTHER EXIST. DefenseSystem.CanAttack answers "are
	you staggered, broken, or currently guarding"; DamageSystem.CanAttack answers "are you reeling from
	a hit"; GrabSystem.CanAttack answers "is a grab currently committing your body, on either end of
	it." Three questions, three owners. This module is the only place they are asked together, and it
	deliberately does not merge them into a shared notion of "can act" that all three would then have
	to agree on.

	REFUSAL IS ORDINARY, AND MOST OF IT IS BUFFERED RATHER THAN DROPPED. A press that arrives a few
	milliseconds before recovery ends is not a mistake worth punishing -- it is the single most common
	thing a player does, and dropping it reads as the game ignoring the input rather than as their own
	mistiming. So a refusal whose reason CLEARS ON ITS OWN (AttackConstants.Input.TransientRefusals) is
	remembered for AttackConstants.Input.BufferSeconds and thrown the instant the gate opens,
	RE-VALIDATED at flush time rather than replayed: a player parried while a press was buffered does
	not get that swing out of their own stagger. One slot, newest wins -- mashing must never build a
	backlog that fires as a burst.

	The buffer is also what makes the chain delay costless to the player: they press at whatever rhythm
	they like, and the pause shapes what comes OUT rather than being something they have to feel for on
	the way in.

	A refusal whose reason does NOT clear on its own -- no character, an unresolvable move, an
	unauthorised hotbar press, guard deliberately held -- is dropped on the spot. Buffering "you are
	holding block" would fire an attack the moment a player let go of a guard they were holding on
	purpose, which is a worse answer than doing nothing.

	NO CLIENT PREDICTION, inherited deliberately. HitboxEngine's header states the stance ("SERVER-
	AUTHORITATIVE, WITH NO CLIENT PREDICTION... the deleted PredictionMirror/CombatClient pair is not
	being rebuilt") and this layer does not quietly reintroduce it one level up. The client plays its
	own local windup cue on press and Attack_Started is the confirmation, never a rollback -- the same
	shape DefenseClient already established for the block press. Nothing the client does can decide a
	hit, so nothing it does can need undoing.

	HEARTBEAT ORDER IS LOAD-BEARING, the same way it is for the three layers below. Roblox fires
	Heartbeat connections in connection order, and this module's Step flushes buffered presses --
	which must happen AFTER DamageSystem's Step has reclaimed expired hitstun, or a press buffered
	against hitstun would be re-tested against the same expired hitstun for one extra frame. Main.
	server.lua calls the four Inits in order and Init asserts it rather than trusting the comment.

	ALSO WARMS AttackWindows' clip cache at boot (Init's own task.spawn, mirroring DefenseSystem.Init's
	identical treatment of ParryWindows.ValidateAll) -- collectClipEntries walks every Default and
	custom move the catalogue can resolve, so every swing is synced to its clip's real length from its
	first throw. A clip that first appears mid-session (a move authored in the Move Editor after boot)
	is requested on its first throw instead -- see Throw.

	Does not own: contact detection (HitboxEngine), what kind of hit something was (DefenseSystem),
	what a hit costs (DamageSystem), which move a press means (SwingSequencer), what a move IS
	(AttackCatalog and the Move Creation System behind it), how a move's timeline is built from its
	clip (Shared/Attack/AttackWindows.lua and AttackCatalog.Get's own concern), or any
	presentation whatsoever -- every FX decision belongs to the client that receives Attack_Started.

	KEEPING THE CHAIN (2026-09-29). Two things must not cost a player their place in a string, and this
	module is where both are decided, because it is the one layer that sees the string AND the combo:
	  * an Art woven in mid-string (Throw's hotbar branch: SwingSequencer.Weave holds the string's place,
	    DamageSystem.HoldCombo keeps the landed combo alive until the art's hit window closes), and
	  * a swing that got PARRIED (onDamageApplied: SwingSequencer.RestoreParried hands the stage back and
	    holds it through the stagger, and DamageSystem.HoldCombo holds the landed combo the same way).
	Either way B1, B2, then an Art or a parry still leaves B3 and the launcher within reach.

	A REALM'S RULES ON WHAT MAY BE THROWN (2026-09-30), read off the thrower's Humanoid through
	Shared/Domain/DomainRules.lua -- never through the realm runtime, which sits ABOVE this layer and
	subscribes to it (OnSwingAccepted is how a domain move's acceptance becomes a realm). Three:
	  * a sealed move -- one named by a SealMove rule, or an art / projectile / domain move under a
	    SealArts / SealProjectiles / SealDomains rule -- is refused "DomainSealed";
	  * a domain move while the thrower's OWN realm is still up is refused "DomainActive" (one realm per
	    caster -- the realm runtime stamps the lease, this reads it);
	  * a Cooldown rule scales the cooldown this swing sets.
	Neither refusal is transient (AttackConstants.Input.TransientRefusals): a sealed press buffered until
	the realm ended would fire a move the player pressed while it was forbidden.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AttackConstants = require(ReplicatedStorage.Shared.Attack.AttackConstants)
local AttackTypes = require(ReplicatedStorage.Shared.Attack.AttackTypes)
local AttackWindows = require(ReplicatedStorage.Shared.Attack.AttackWindows)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local AirComboMoves = require(ReplicatedStorage.Shared.AirCombo.AirComboMoves)
local DamageConstants = require(ReplicatedStorage.Shared.Damage.DamageConstants)
local DamageTypes = require(ReplicatedStorage.Shared.Damage.DamageTypes)
local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local DefenseTypes = require(ReplicatedStorage.Shared.Defense.DefenseTypes)
local AmortizedReclaim = require(ReplicatedStorage.Shared.AmortizedReclaim)
local Constants = require(ReplicatedStorage.Shared.Constants)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local DomainRules = require(ReplicatedStorage.Shared.Domain.DomainRules)
local Logger = require(ReplicatedStorage.Shared.Logger)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local ParkourOwnership = require(ReplicatedStorage.Shared.Parkour.ParkourOwnership)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local Trove = require(ReplicatedStorage.Shared.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local ProjectileRelevance = require(script.Parent.ProjectileRelevance)
local SwingSequencer = require(script.Parent.SwingSequencer)
local AttackCatalog = require(script.Parent.Parent.AttackCatalog)
local DefaultMoveRegistry = require(script.Parent.Parent.DefaultMoveRegistry)
local MoveRegistryManager = require(script.Parent.Parent.MoveRegistryManager)
local DamageSystem = require(script.Parent.Parent.Damage.DamageSystem)
local DefenseSystem = require(script.Parent.Parent.Defense.DefenseSystem)
local GrabSystem = require(script.Parent.Parent.Grab.GrabSystem)
local AirComboSystem = require(script.Parent.Parent.AirCombo.AirComboSystem)
local HitboxEngine = require(script.Parent.Parent.HitboxEngine.HitboxEngine)
local NetworkLatency = require(script.Parent.Parent.NetworkLatency)
local AdminConfig = require(script.Parent.Parent.Parent.Config.AdminConfig)
local ArtSystem = require(script.Parent.Parent.Parent.Systems.ArtSystem)

type AttackRequest = AttackTypes.AttackRequest
type AttackStartedPayload = AttackTypes.AttackStartedPayload

local logger = Logger.scope("AttackRequestSystem")

local AttackRequestSystem = {}

-- Engine registration, inherited from TestAttackHarness -- see this file's header.
local combatantIds: { [Model]: number } = {}

-- When each combatant may throw each move again. Nested per model so a whole character's cooldowns
-- drop in one assignment when their life ends, rather than needing a sweep over a flat composite key.
local cooldownUntil: { [Model]: { [string]: number } } = {}

-- One round-robin reclaim cursor per table above -- see Shared/AmortizedReclaim.lua for why these are
-- separate instances rather than one shared cursor, and Step below for what they replaced.
local combatantIdsReclaim = AmortizedReclaim.New()
local cooldownReclaim = AmortizedReclaim.New()

-- The one buffered press per combatant, or none. AttackConstants.Input.BufferDepth is 1 and this
-- shape enforces it structurally rather than by checking a length.
type Buffered = {
	Request: AttackRequest,
	ExpiresAt: number,
	-- Carried so a flush can still tell an admin-gated hotbar press from an ordinary one without
	-- re-deriving authorisation from a Player who may have left in the meantime.
	Authorized: boolean,
}
local buffered: { [Model]: Buffered } = {}

-- The highest attack press id each body has pressed (AttackRequest.PressId). A press at or below it is a
-- duplicate -- a retransmit, a replay -- and is dropped before it reaches a gate. Per character, so a new life
-- starts clean; the client's count runs on across lives, so its ids only ever grow.
local lastPressId: { [Model]: number } = {}

-- OnPressRefused's subscribers -- see answerRefused.
local pressRefusedCallbacks: { (Model, number, string) -> () } = {}

-- The largest press id accepted; the client counts up from 1 per session.
local MAX_PRESS_ID = 2 ^ 31

-- The swing each combatant most recently had ACCEPTED, for Feint to judge. Only what the feint gate
-- needs, captured from the same catalogue entry the engine was handed, so "how far into the windup"
-- is measured against the windup that is actually running. Stale once the swing ends -- Feint asks
-- the engine whether it is still in Windup rather than trusting this table to know.
type InFlight = {
	MoveId: string,
	Feintable: boolean,
	StartedAt: number,
	WindupSeconds: number,
	-- Whether the move's Cooldown is a swing-length one (it stands for "until this swing is over"),
	-- which a feint shortens along with the swing; a real, longer cooldown is left alone.
	SwingLengthCooldown: boolean,
	-- The swing's weight class, carried for GetInFlight's readers (a Heavy is PowerLevel 2+).
	PowerLevel: number,
	-- The rest of the timeline, for the hit-confirm cancel point (AttackConstants.HitConfirmCancelAt).
	ActiveSeconds: number,
	RecoverySeconds: number,
	-- Set once this swing LANDS (onDamageApplied): when its recovery may be cut into a follow-up. nil for a
	-- swing that has not landed, and for an air move, which never cancels.
	ConfirmCancelAt: number?,
}
local inFlight: { [Model]: InFlight } = {}

-- When each combatant may feint again (AttackConstants.Feint.CooldownSeconds).
local feintReadyAt: { [Model]: number } = {}

-- Models currently carrying the heavy tell (AttackConstants.Tell), and when (os.clock) it comes off. Only
-- ever holds the few swings winding up right now, so Step walks it in full.
local tellEndsAt: { [Model]: number } = {}
local inFlightReclaim = AmortizedReclaim.New()
local feintReadyReclaim = AmortizedReclaim.New()

local started = false
local heartbeatTrove = Trove.New()
local startedRemote: RemoteEvent? = nil
local weaponChangedRemote: RemoteEvent? = nil
local cancelledRemote: RemoteEvent? = nil
local projectileRemote: RemoteEvent? = nil
local projectileDisconnect: (() -> ())? = nil
-- The DamageSystem.OnApplied subscription (onDamageApplied), connected in Init.
local appliedDisconnect: (() -> ())? = nil
local requestLimiter = RateLimiter.New(AttackConstants.Network.MaxCallsPerSecondPerPlayer)
local swapLimiter = RateLimiter.New(AttackConstants.Network.MaxSwapsPerSecondPerPlayer)
local feintLimiter = RateLimiter.New(AttackConstants.Network.MaxFeintsPerSecondPerPlayer)

-- OnWeaponChanged's subscriber list -- see that function's own header. A plain array, not a
-- RateLimiter/Trove-tracked resource: subscribers are Systems that live for the server's whole
-- lifetime (WeaponVisualSystem today), never a per-player thing to clear on PlayerRemoving.
local weaponChangedCallbacks: { (Model, Types.WeaponId) -> () } = {}

-- OnSwingAccepted's subscriber list -- same lifetime and same reasoning as weaponChangedCallbacks above.
-- Typed loosely here because InFlightView is declared further down; OnSwingAccepted's own signature
-- carries the real type.
local swingAcceptedCallbacks: { (Model, any) -> () } = {}

-- Helpers ------------------------------------------------------------------------------------------

local function debugLog(flag: boolean, message: string, data: { [string]: any }?): ()
	if AttackConstants.Debug.Enabled and flag then
		logger:debug(message, data)
	end
end

-- THE PRESS VERDICT: tells the pressing player this press will not throw, so their client cuts its prediction
-- of it now (AttackTypes.AttackCancelReason "Refused"). A press with no id (a bot, a scripted throw) has nobody
-- waiting on it.
local function answerRefused(model: Model, request: AttackRequest, reason: string): ()
	local pressId = request.PressId
	if pressId == nil then
		return
	end
	for _, callback in pressRefusedCallbacks do
		local ok, err = pcall(callback, model, pressId, reason)
		if not ok then
			logger:error("An OnPressRefused consumer errored", { errorMessage = tostring(err) })
		end
	end
	local remote = cancelledRemote
	local player = Players:GetPlayerFromCharacter(model)
	if remote == nil or player == nil then
		return
	end
	remote:FireClient(
		player,
		{
			MoveId = request.MoveId or "",
			Reason = "Refused",
			RecoverySeconds = 0,
			PressId = pressId,
			RefusedReason = reason,
		} :: AttackTypes.AttackCancelledPayload
	)
end

-- Drops this combatant's buffered press, if any, and answers it -- every path that throws one away goes
-- through here, so no buffered press is ever left for the client to time out.
local function dropBuffered(model: Model, reason: string): ()
	local entry = buffered[model]
	if entry == nil then
		return
	end
	buffered[model] = nil
	answerRefused(model, entry.Request, reason)
end

-- Every move this server might throw that has a clip, paired with its resolved AnimationId -- what
-- AttackWindows.ValidateAll needs to warm its clip cache at boot. Walks the Default registry (every
-- weapon's every stage plus the standalones) and every custom move, so the list is whatever the
-- catalogue can actually resolve rather than a second copy of it. Resolved through AttackCatalog.Get
-- rather than read off the MoveDefinition because a Default move's clip is not ON its definition --
-- it falls through to AttackAnimations there -- and Get is the one place that fallback lives.
local function collectClipEntries(): { { MoveId: string, AnimationId: string } }
	local entries: { { MoveId: string, AnimationId: string } } = {}
	local seen: { [string]: boolean } = {}
	local function add(moveId: string)
		if seen[moveId] then
			return
		end
		seen[moveId] = true
		local entry = AttackCatalog.Get(moveId)
		if entry and entry.AnimationId ~= "" then
			table.insert(entries, { MoveId = moveId, AnimationId = entry.AnimationId })
		end
	end
	for _, move in DefaultMoveRegistry.List() do
		add(move.MoveId)
	end
	for _, move in MoveRegistryManager.List() do
		add(move.MoveId)
	end
	return entries
end

local function isAlive(model: Model): boolean
	if model.Parent == nil then
		return false
	end
	return CharacterUtil.LiveHumanoidOf(model) ~= nil
end

local function cooldownRemaining(model: Model, moveId: string, now: number): number
	local perMove = cooldownUntil[model]
	if not perMove then
		return 0
	end
	local until_ = perMove[moveId]
	if not until_ then
		return 0
	end
	return math.max(until_ - now, 0)
end

local function setCooldown(model: Model, moveId: string, seconds: number, now: number): ()
	if seconds <= 0 then
		return
	end
	local perMove = cooldownUntil[model]
	if not perMove then
		perMove = {}
		cooldownUntil[model] = perMove
	end
	perMove[moveId] = now + seconds
end

-- The volume a client can reproduce for its own predicted hit cue (AttackTypes.ContactVolume), or nil. Any
-- shape on any anchor -- the client builds it on its own rig with the engine's own HitboxAnchor and
-- HitboxGeometry -- but only at a size it can know: a flat-scaled melee move. A combo-, power- or
-- charge-scaled volume, or a projectile, sends nil and its hit waits for the server.
local function isFlatScaled(scaling: any): boolean
	if typeof(scaling) ~= "table" then
		return true
	end
	if (tonumber(scaling.ChargeSeconds) or 0) > 0 or (tonumber(scaling.PowerMultiplierPerUnit) or 0) ~= 0 then
		return false
	end
	for _, multiplier in scaling.ComboStageMultipliers or {} do
		if multiplier ~= 1 then
			return false
		end
	end
	return true
end

local function contactVolumeOf(definition: any): AttackTypes.ContactVolume?
	if definition.Projectile ~= nil or not isFlatScaled(definition.Scaling) then
		return nil
	end
	local dimensions = definition.BaseDimensions
	if typeof(dimensions) ~= "table" or typeof(definition.Shape) ~= "string" then
		return nil
	end
	return {
		Shape = definition.Shape,
		Dimensions = table.clone(dimensions),
		Offset = definition.Offset or CFrame.identity,
		AttachmentPart = definition.AttachmentPart or "Root",
		SizeFromAttachmentPart = if definition.SizeFromAttachmentPart == true then true else nil,
		SizeMultiplier = if typeof(definition.SizeMultiplier) == "number" then definition.SizeMultiplier else nil,
	}
end

-- Tells the attacker, and only the attacker, what the server just started. Silently does nothing for
-- a bot or a dummy, which have no player to tell -- the same "not every combatant is a Player"
-- tolerance every other module in this stack keeps.
local function sendStarted(model: Model, payload: AttackStartedPayload): ()
	local remote = startedRemote
	if not remote then
		return
	end
	local player = Players:GetPlayerFromCharacter(model)
	if not player then
		return
	end
	remote:FireClient(player, payload)
end

-- Every OnWeaponChanged subscriber, in registration order. pcall'd for the same reason DamageSystem.
-- OnApplied's own dispatch loop is: one subscriber erroring (WeaponVisualSystem today) must not abort
-- the rest and above all must not unwind out of handleSwap/bindCharacter into this System's own
-- Heartbeat/PlayerAdded plumbing.
local function notifyWeaponChanged(character: Model, weaponId: Types.WeaponId?): ()
	for _, callback in weaponChangedCallbacks do
		local ok, err = pcall(callback, character, weaponId)
		if not ok then
			logger:error("An AttackRequestSystem.OnWeaponChanged consumer errored", { errorMessage = tostring(err) })
		end
	end
end

-- Every OnSwingAccepted subscriber, pcall'd for the notifyWeaponChanged reason directly above: a
-- cosmetic sibling erroring must never unwind into Throw and leave a swing half-committed.
local function notifySwingAccepted(model: Model, view: any): ()
	for _, callback in swingAcceptedCallbacks do
		local ok, err = pcall(callback, model, view)
		if not ok then
			logger:error("An AttackRequestSystem.OnSwingAccepted consumer errored", { errorMessage = tostring(err) })
		end
	end
end

-- Throwing -----------------------------------------------------------------------------------------

-- Resolution for a Hotbar slot that has a real, persisted Art equipped in it -- the whole of
-- resolveRequest's Hotbar case below, so an admin and everyone else go through the IDENTICAL
-- Qi-cost/mastery/tier/Deviation gate the instant a genuine Art sits in the slot they pressed.
-- nil, nil (not an error reason) when the slot simply has nothing equipped -- that is not a
-- refusal, just "keep looking."
local function resolveFromEquippedArt(model: Model, player: Player, slot: number): (SwingSequencer.Resolution?, string?)
	local artId = ArtSystem.GetEquipped(player)[slot]
	if not artId then
		return nil, nil
	end
	local refusal = ArtSystem.CanUse(player, artId)
	if refusal then
		return nil, refusal
	end
	return {
		MoveId = artId,
		WeaponId = SwingSequencer.GetWeapon(model),
		StageIndex = 0,
	}, nil
end

-- The heavy tell --------------------------------------------------------------------------------------

local function clearTell(model: Model): ()
	if tellEndsAt[model] == nil then
		return
	end
	tellEndsAt[model] = nil
	if model.Parent ~= nil then
		CollectionService:RemoveTag(model, AttackConstants.Tell.Tag)
	end
end

-- Raises the tell on `model` for `windupSeconds`. Removed first so a re-raise always fires the client's
-- tag-added signal, even if an earlier tell somehow had not come off yet.
local function raiseTell(model: Model, windupSeconds: number, now: number): ()
	clearTell(model)
	local seconds = math.max(windupSeconds, 0)
	model:SetAttribute(AttackConstants.Tell.UntilAttribute, Workspace:GetServerTimeNow() + seconds)
	CollectionService:AddTag(model, AttackConstants.Tell.Tag)
	tellEndsAt[model] = now + seconds
end

-- Hit-confirm cancel -----------------------------------------------------------------------------------

-- Which AttackConstants.HitConfirm.CancelInto entry a resolved press is, or nil for one that can never
-- take the cut (an air move).
local function cancelTargetFor(request: AttackRequest, resolution: SwingSequencer.Resolution): string?
	if resolution.AirRole ~= nil then
		return nil
	end
	if resolution.IsLauncher == true then
		return "Launcher"
	end
	return request.Kind
end

-- Whether this combatant's current swing landed and has reached its cut point, and whether `target` may
-- take the cut. Asks the engine for the phase rather than trusting inFlight, which goes stale once a
-- swing ends.
local function confirmCancelReady(model: Model, combatantId: number, target: string?, now: number): boolean
	local tuning = AttackConstants.HitConfirm
	if not tuning.Enabled or target == nil or tuning.CancelInto[target] ~= true then
		return false
	end
	local swing = inFlight[model]
	local cancelAt = swing and swing.ConfirmCancelAt
	if cancelAt == nil or now < cancelAt then
		return false
	end
	return HitboxEngine.GetAttackState(combatantId) == "Recovery"
end

-- Marks the swing that just landed as cancelable. Only the in-flight swing it is actually about, and
-- never an air-combo move (the air string has its own deadline grammar, AirComboMachine). Production
-- reaches it from onDamageApplied; PUBLIC so a spec can land a swing without a whole contact pipeline.
function AttackRequestSystem.NoteHitConfirmed(model: Model, moveId: string): ()
	local swing = inFlight[model]
	if swing == nil or swing.MoveId ~= moveId or swing.ConfirmCancelAt ~= nil then
		return
	end
	if AirComboMoves.RoleOf(moveId) ~= nil then
		return
	end
	swing.ConfirmCancelAt = AttackConstants.HitConfirmCancelAt(
		swing.StartedAt,
		swing.WindupSeconds,
		swing.ActiveSeconds,
		swing.RecoverySeconds
	)
end

-- Which client hears about which shot (Server/Combat/Attack/ProjectileRelevance.lua's header).
local projectileRelevance = ProjectileRelevance.New(AttackConstants.Network.ProjectileRelevanceStuds)

-- One engine frame's shot changes, to each client they concern -- never FireAllClients, which drew every
-- shot in the server on every client. Stamped with the server clock clients share (GetServerTimeNow), so
-- each can fly a shot forward by exactly how long its event took to arrive.
local function broadcastProjectiles(events: { any }): ()
	local remote = projectileRemote
	if not remote then
		return
	end
	local viewers: { ProjectileRelevance.Viewer } = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = if character then CharacterUtil.RootOf(character) else nil
		table.insert(viewers, {
			Player = player,
			Character = character,
			Position = if root then root.Position else nil,
		})
	end
	local sentAt = Workspace:GetServerTimeNow()
	local routed = projectileRelevance:Route(events :: { AttackTypes.ProjectileWireEvent }, viewers, os.clock())
	for player, share in routed do
		remote:FireClient(
			player,
			{
				SentAt = sentAt,
				Events = share,
			} :: AttackTypes.ProjectileBatchPayload
		)
	end
end

-- Resolves which move a request means. Split from Throw below so the answer is available before any
-- gate runs -- the cooldown check needs a MoveId, and a press that is refused must not have advanced
-- the string, so nothing here mutates.
local function resolveRequest(model: Model, request: AttackRequest, now: number): (SwingSequencer.Resolution?, string?)
	if request.Kind == "Hotbar" then
		-- RESOLVED FROM ARTSYSTEM, ADMIN OR NOT. A hotbar slot can only ever hold a real, persisted
		-- Art now -- ArtSystem.Equip for the normal ArtsTab flow, ArtSystem.DevGrantAndEquip for an
		-- admin's Move Editor "bind to slot" test-fire (see that function's own header) -- so the
		-- client's own MoveId is ignored entirely and the slot is resolved against
		-- ArtSystem.GetEquipped, the same server-persisted binding either writer goes through. There
		-- used to be a second, trusted branch here that let an admin fire an arbitrary MoveId
		-- (AttackCatalog.Has) with no Art binding at all; it's gone because that path no longer
		-- exists on the write side either -- a move with no Art binding is refused a slot at bind
		-- time (ArtTreeManager.IsArt), so there is no second kind of MoveId left to trust here. A
		-- slot with nothing equipped, or an equipped art CanUse currently refuses (not unlocked, not
		-- enough Qi, Deviation-locked), refuses the whole request -- there is no other way onto this
		-- branch, for anyone.
		local player = Players:GetPlayerFromCharacter(model)
		if not player then
			return nil, "NotAuthorized"
		end
		-- An air combo's attacker is committed to its string: the air grammar has no hotbar branch, and an
		-- Art cast from a hover would be a free, unscaled hit on a victim who can only parry.
		if AirComboSystem.IsAttacker(model) then
			return nil, "AirCombo"
		end
		local slot = request.Slot
		if typeof(slot) ~= "number" then
			return nil, "InvalidSlot"
		end
		local resolution, refusal = resolveFromEquippedArt(model, player, slot)
		if resolution then
			return resolution, nil
		end
		return nil, refusal or "NoArtEquipped"
	end

	-- THE AIR GRAMMAR (docs/design/air-combat-and-evade.md B2). Inside a live combo AirComboSystem decides what
	-- the press means -- the next beat, or a finisher -- and may say "not yet" (the victim is still rising,
	-- transient, so the press buffers). Outside one it returns nothing and the ground string resolves as it
	-- always has, with the modifier offered for the launcher branch.
	local modifierUp = request.Modifier == "Up"
	local airRole, airRefusal = AirComboSystem.ResolvePress(model, request.Kind, modifierUp, now)
	if airRefusal then
		return nil, airRefusal
	end
	local resolution = SwingSequencer.Resolve(
		model,
		request.Kind,
		DamageSystem.GetComboStage(model, now),
		now,
		{ ModifierUp = modifierUp, AirRole = airRole }
	)
	if not resolution then
		return nil, "UnknownMove"
	end
	return resolution, nil
end

-- THE ATTACKER'S LATENCY REFUND (AttackConstants.Latency): when a press that has just passed every gate
-- is judged to have been made, which the engine then starts the swing from. `now` less half this player's
-- round trip (the press made one trip), capped -- and never before any moment a gate would have refused
-- it: the end of a stun, the start of the defence state that allows attacking, the end of the chain beat
-- or the move's cooldown. The engine adds the last two limits itself (its previous swing's end, and the
-- windup it may not skip). So the refund covers time on the wire and never time the body was not free.
--
-- The grab, air-hold, traversal and mount gates keep no history to ask (each answers only for now, which
-- the press has already passed), so a press arriving just after one of those ended may be backdated up to
-- MaxLeadSeconds into it. The client predicts no swing during any of them, so such a press was made after
-- the attacker's own screen showed them free.
local function backdatedStartFor(
	model: Model,
	request: AttackRequest,
	resolution: SwingSequencer.Resolution,
	forced: boolean,
	confirmCancel: boolean,
	now: number
): number
	local latency = AttackConstants.Latency
	if not latency.Enabled or forced or resolution.AirRole ~= nil then
		return now
	end
	local lead = math.min(NetworkLatency.PingSeconds(model) / 2, latency.MaxLeadSeconds)
	if not (lead > 0) then
		return now
	end
	local startedAt = math.max(now - lead, DamageSystem.HitstunUntil(model), DefenseSystem.AttackFreeSince(model, now))
	if startedAt >= now then
		return now
	end
	if request.Kind ~= "Hotbar" and not confirmCancel then
		startedAt += SwingSequencer.ChainDelayRemaining(model, startedAt, resolution)
	end
	startedAt += cooldownRemaining(model, resolution.MoveId, startedAt)
	return math.min(startedAt, now)
end

-- Runs every gate and, if they all pass, actually throws. Returns (accepted, reason) -- a refusal is
-- normal and never an error, matching HitboxEngine.RequestAttack's own contract. Throw and ThrowMove
-- below are its two public faces.
--
-- `forced` is ThrowMove's pre-resolved move (see that function): when present it replaces resolveRequest
-- and nothing else -- every gate, the cooldown, the engine call and every commit below run exactly as
-- for a press.
local function throw(
	model: Model,
	request: AttackRequest,
	now: number,
	forced: SwingSequencer.Resolution?
): (boolean, string?)
	if not isAlive(model) then
		return false, "NoCharacter"
	end

	local combatantId = combatantIds[model] or HitboxEngine.GetCombatantId(model)
	if not combatantId then
		return false, "NotRegistered"
	end

	-- Asked BEFORE the catalogue lookup and the engine call, because both of those cost more than a
	-- table read and neither can succeed while these refuse.
	local defenceAllows, defenceReason = DefenseSystem.CanAttack(model)
	if not defenceAllows then
		return false, defenceReason or "Defending"
	end

	local damageAllows, damageReason = DamageSystem.CanAttack(model, now)
	if not damageAllows then
		return false, damageReason or "Hitstun"
	end

	-- Third gate of the identical shape -- see Server/Combat/Grab/GrabSystem.lua's own header on why
	-- it belongs alongside DefenseSystem.CanAttack/DamageSystem.CanAttack rather than being merged into
	-- either: this one asks "is a grab currently committing your body, on either end of it," a
	-- question neither of the other two systems can answer. Refuses a holding attacker (must Throw or
	-- wait the hold out) and a held-or-thrown victim.
	local grabAllows, grabReason = GrabSystem.CanAttack(model, now)
	if not grabAllows then
		return false, grabReason or "Grabbed"
	end

	-- Fourth gate of the same shape (Server/Combat/AirCombo/AirComboSystem.lua): an air-held victim cannot
	-- swing -- the parry is their one way out, and it is a DefenseSystem press, not an attack.
	local airAllows, airReason = AirComboSystem.CanAttack(model, now)
	if not airAllows then
		return false, airReason or "AirHeld"
	end

	-- A COMMITTED TRAVERSAL REFUSES THE SWING OUTRIGHT. Mid-vault, mid-slide, mid-wall-run, the body
	-- belongs to the movement framework, and a swing thrown out of one would be a character attacking
	-- from a pose the animation, the hitbox and the player's own expectations all disagree about.
	--
	-- Deliberately NOT in AttackConstants.Input.TransientRefusals, unlike almost every other refusal
	-- in this function. A buffered press would fire on the frame the traversal ends, which is exactly
	-- the "vault into a free hit" the gate exists to prevent -- the press is dropped, and the player
	-- presses again once they have landed. That table is the whole mechanism for this distinction, so
	-- the choice is expressed by leaving the reason out of it rather than by a branch here.
	--
	-- Reads the Attribute through Shared/Parkour/ParkourOwnership rather than requiring ParkourSystem,
	-- so this layer stays free of a movement dependency and a bot (no parkour, no Attribute) is never
	-- gated. See that module's header for what the Attribute does and does not cover.
	local humanoid = CharacterUtil.HumanoidOf(model)
	if humanoid and ParkourOwnership.OwnsBody(humanoid) then
		return false, "ParkourAction"
	end

	-- A MOUNTED BODY CANNOT SWING. Welded to a blimp station (Server/Systems/BlimpSystem.lua), the body
	-- is part of a vehicle: its position is not its own, its animation channel is being driven by the arm
	-- pose, and a hitbox thrown from it would sweep whatever the hull happened to be flying past.
	--
	-- Read as an Attribute rather than through a BlimpSystem require, the same way the traversal gate
	-- immediately above reads ParkourOwnership rather than requiring ParkourSystem -- this layer stays
	-- free of a dependency on a world system, and a bot (never mounted, no Attribute) is never gated.
	--
	-- Deliberately NOT in AttackConstants.Input.TransientRefusals, for the same reason ParkourAction is
	-- not: a buffered press would fire on the frame the pilot let go of the wheel, which is a free hit
	-- out of a state the player was not in when they pressed.
	if humanoid and humanoid:GetAttribute(Constants.Attributes.Mounted) == true then
		return false, "Mounted"
	end

	local resolution, resolveReason
	if forced then
		resolution = forced
	else
		resolution, resolveReason = resolveRequest(model, request, now)
	end
	if not resolution then
		return false, resolveReason or "UnknownMove"
	end

	local entry = AttackCatalog.Get(resolution.MoveId)
	if not entry then
		-- Resolve already asked Has() for the hotbar path and the sequencer probed the catalogue for
		-- the string path, so reaching here means the registry changed between those two reads. Real,
		-- rare, and worth a line rather than a silent nothing.
		return false, "UnknownMove"
	end
	-- A REALM'S GATES (this file's header). Asked after resolution because both need to know what the move
	-- IS -- its id and its three traits -- and before the cooldown and the engine, which cost more.
	local realmNow = DomainRules.ServerNow()
	if
		DomainRules.IsSealed(humanoid, resolution.MoveId, {
			IsArt = request.Kind == "Hotbar" and forced == nil,
			IsProjectile = entry.Definition.Projectile ~= nil,
			IsDomain = entry.IsDomain,
		}, realmNow)
	then
		return false, "DomainSealed"
	end
	if entry.IsDomain and DomainRules.OwnsLiveDomain(humanoid, realmNow) then
		return false, "DomainActive"
	end

	-- A clip the boot warm pass never saw (authored after boot) starts reading now, so this swing uses
	-- its authored timeline and every later one is synced to the clip. A no-op for anything already
	-- read or in flight. Only once Init has run: the specs drive Throw without Init, and a background
	-- web fetch landing mid-spec would retime swings under their assertions.
	if started then
		AttackWindows.Request(entry.AnimationId)
	end

	if cooldownRemaining(model, resolution.MoveId, now) > 0 then
		return false, "Cooldown"
	end

	-- The deliberate beat between links of a string. Not applied to a hotbar move: that is a one-off
	-- cast with its own authored Cooldown, not a link in a chain, and making it wait on the rhythm of a
	-- string it is not part of would be a second, invisible cooldown on top of its real one.
	--
	-- REPORTED AS "Busy" WHILE THE SWING THAT OWES THE BEAT IS STILL RUNNING. The beat always outlasts
	-- its own swing (it starts when the swing ends), so checking it before the engine would otherwise
	-- mean a mid-swing press ALWAYS reports ChainDelay and "Busy" never appears for a weapon string at
	-- all -- which would quietly cost the debug log its most basic distinction between "you are still
	-- swinging" and "you are waiting out the pause". Both are transient and both buffer identically, so
	-- this changes nothing about behaviour and everything about whether the log can be read.
	-- A LANDED swing's recovery may be cut into this press (AttackConstants.HitConfirm). The cut replaces
	-- the chain beat and any end-of-string lockout, so both gates are skipped for it.
	local confirmCancel = confirmCancelReady(model, combatantId, cancelTargetFor(request, resolution), now)
	if
		request.Kind ~= "Hotbar"
		and not confirmCancel
		and SwingSequencer.ChainDelayRemaining(model, now, resolution) > 0
	then
		local engineState = HitboxEngine.GetAttackState(combatantId)
		return false, if engineState ~= nil and engineState ~= "Idle" then "Busy" else "ChainDelay"
	end

	-- comboStage scales the VOLUME of this one swing by how deep the attacker's unbroken landed string
	-- is (HitboxEngine's own ScalingProfile), which is a different question from which move the string
	-- is on. Projected moves are flat-scaled today (MoveTypes.ToEngineAttackDefinition's own note), so
	-- this currently changes nothing -- it is passed honestly anyway, so the day the Move Editor grows
	-- a scaling curve this needs no edit.
	local comboStage = DamageSystem.GetComboStage(model, now)
	-- PowerLevel is the weight class -- what makes a blocked heavy drain twice the guard a blocked jab
	-- does (GuardMeter.DrainFor). Resolved by the catalogue (MoveTypes.PowerLevelOf): by stage for a
	-- weapon string's Default moves, authored for a custom one. It also scales hitbox volume, but only
	-- through a Scaling.PowerMultiplierPerUnit no projected move sets, so today it changes guard drain
	-- and nothing else.
	local requestedStart = backdatedStartFor(model, request, resolution, forced ~= nil, confirmCancel, now)
	local backdated = requestedStart < now
	if confirmCancel then
		HitboxEngine.CancelRecovery(combatantId, now)
	end
	local accepted, engineReason, begunAt = HitboxEngine.RequestAttack(
		combatantId,
		entry.Definition,
		comboStage,
		entry.PowerLevel,
		if backdated then requestedStart else nil
	)
	if not accepted then
		return false, engineReason or "Busy"
	end
	-- THE SWING'S OWN CLOCK from here on (AttackConstants.Latency): when the engine judged it to have begun,
	-- which for a player's press is a little before it arrived. Everything below that measures this swing's
	-- timeline -- the string's beat, the cooldown, the feint gate, the busy deadline, the tell -- runs from
	-- it, so no part of the swing is timed from the wire and another part from the press. A press with no
	-- lead keeps `now`, exactly as before.
	local startedAt = if backdated then begunAt or now else now

	-- ART QI IS CHARGED ONLY NOW, after the engine agreed to throw -- not inside resolveRequest's
	-- CanUse check above, which runs before Cooldown and the engine's own concurrent-swing ceiling
	-- and would otherwise charge Qi for a swing that goes on to be refused as "Cooldown" or "Busy".
	-- UseArt re-checks unlock and Qi itself rather than trusting resolveRequest's CanUse asked
	-- moments ago; nothing yields between the two in this synchronous call, so it cannot newly fail
	-- here. Never runs for a Basic/Heavy swing (those cost no Qi). DOES run for an admin's Hotbar
	-- press -- an earlier version of this gate exempted `authorized` from the charge (so a dev-tested
	-- art wouldn't drain real Qi or level up from live-fire testing alone), but that exemption also
	-- silently ate the admin's own Qi UI feedback: an admin equipping a real Art normally, testing it
	-- through the SAME hotbar slot, would never see their Qi bar move. resolveRequest already resolves
	-- an admin's Hotbar press to a real, persisted Art the same as anyone else's (see ArtSystem.lua's
	-- own header) -- there's no separate "dev-tested" MoveId to distinguish it by, so there's no honest
	-- way to charge everyone else and not the admin. See ArtSystem.DevGrantAndEquip's own header.
	-- A forced throw (the Move Editor's Test) is not an art cast: the move may not be an art at all, and
	-- testing one must not drain the admin's Qi or grant mastery for a swing they never earned.
	if request.Kind == "Hotbar" and forced == nil then
		local player = Players:GetPlayerFromCharacter(model)
		if player then
			local refusal = ArtSystem.UseArt(player, resolution.MoveId)
			if refusal then
				logger:warn(
					"Art Qi charge failed after engine accepted swing",
					{ player = player.Name, artId = resolution.MoveId, reason = refusal }
				)
			end
		end
	end

	-- Committed only now, after the engine agreed. A refused press leaves the string exactly where it
	-- was, which is what makes "press early, get refused, press again" continue the combo rather than
	-- silently skipping a stage.
	--
	-- The commitment handed over is the same definition the engine was just given, so the string's own
	-- deadline can never be built from a different version of the move than the one actually swinging.
	local commitment = entry.Definition.WindupSeconds
		+ entry.Definition.ActiveSeconds
		+ entry.Definition.RecoverySeconds
	if request.Kind ~= "Hotbar" then
		SwingSequencer.Advance(model, request.Kind, resolution, commitment, startedAt)
	else
		-- AN ART IS A LINK, NOT A RESET (see this file's header, KEEPING THE CHAIN). The string keeps its
		-- place through the art, and the landed combo cannot lapse before the art's own hit window closes:
		-- a landed art advances it as any hit does, and a whiffed one lets it lapse from there.
		SwingSequencer.Weave(model, resolution.MoveId, commitment, startedAt)
		DamageSystem.HoldCombo(model, startedAt + entry.Definition.WindupSeconds + entry.Definition.ActiveSeconds, now)
	end
	-- A realm's Cooldown rule scales what this swing sets (1 outside any realm); the client is told the same
	-- number below, so its hotbar sweep matches the gate.
	local cooldownSeconds = entry.Cooldown * DomainRules.Scale(humanoid, "Cooldown", realmNow)
	setCooldown(model, resolution.MoveId, cooldownSeconds, startedAt)
	inFlight[model] = {
		MoveId = resolution.MoveId,
		Feintable = entry.Feintable,
		StartedAt = startedAt,
		WindupSeconds = entry.Definition.WindupSeconds,
		SwingLengthCooldown = entry.Cooldown <= commitment + 1e-6,
		PowerLevel = entry.PowerLevel,
		ActiveSeconds = entry.Definition.ActiveSeconds,
		RecoverySeconds = entry.Definition.RecoverySeconds,
		ConfirmCancelAt = nil,
	}
	-- The air combo judges an air swing against its shared deadline the moment the swing is committed --
	-- against its REWOUND start, so a press that was in time on the attacker's own screen is honoured
	-- (AirComboMachine.NoteSwingAccepted). A no-op for anything that is not an air move.
	if resolution.AirRole then
		AirComboSystem.NoteSwingAccepted(
			model,
			resolution.AirRole,
			now,
			entry.Definition.WindupSeconds,
			entry.Definition.ActiveSeconds
		)
	end
	-- The heavy tell (AttackConstants.Tell): every other client sees this swing flash for its windup.
	-- Anything lighter drops a tell a previous heavy might still have up.
	local tell = AttackConstants.Tell
	if tell.Enabled and entry.PowerLevel >= tell.MinPowerLevel then
		raiseTell(model, entry.Definition.WindupSeconds - (now - startedAt), now)
	else
		clearTell(model)
	end

	-- The same public view GetInFlight hands out, told to OnSwingAccepted subscribers the moment the swing
	-- is committed. A fresh table, so a subscriber may keep it.
	notifySwingAccepted(model, {
		MoveId = resolution.MoveId,
		StartedAt = startedAt,
		WindupSeconds = entry.Definition.WindupSeconds,
		Feintable = entry.Feintable,
		PowerLevel = entry.PowerLevel,
	})

	-- PUBLISHED FOR RunSystem, which reads it and forces the run down for the duration -- see
	-- Constants.Attributes.CombatBusyUntil for the whole contract and for why it is a deadline rather
	-- than a flag. This layer knows nothing about running and gains no dependency on it; it states when
	-- this swing is over and lets anyone who cares read that.
	--
	-- Computed for a Hotbar move too, unlike the SwingSequencer commitment above -- a hotbar cast is
	-- not a link in a string, but it is just as much a swing you should not be sprinting through.
	--
	-- math.max against whatever is already there, never a bare write: a swing accepted while a longer
	-- one is still committing this body must not SHORTEN the deadline. That cannot happen through
	-- HitboxEngine today (it refuses a second swing as Busy), but a future move with an early-cancel
	-- window would reach here mid-swing, and a gate that quietly gets weaker under a feature nobody has
	-- built yet is the kind that fails silently when they do.
	--
	-- THE ONE DOCUMENTED EXCEPTION is AttackRequestSystem.Feint, which bare-writes this deadline
	-- BACKWARDS to the end of the feint's own recovery. That is not the gate getting weaker: the swing
	-- that owed the longer deadline no longer exists, and leaving it would force a feinting player to
	-- walk through the swing they just cancelled.
	local humanoidForBusy = CharacterUtil.HumanoidOf(model)
	if humanoidForBusy then
		local existingBusy = humanoidForBusy:GetAttribute(Constants.Attributes.CombatBusyUntil)
		local busyUntil = if typeof(existingBusy) == "number" then existingBusy else 0
		humanoidForBusy:SetAttribute(Constants.Attributes.CombatBusyUntil, math.max(busyUntil, startedAt + commitment))
	end

	sendStarted(model, {
		MoveId = resolution.MoveId,
		Kind = request.Kind,
		Slot = request.Slot,
		WeaponId = resolution.WeaponId,
		StageIndex = resolution.StageIndex,
		ComboStage = comboStage,
		WindupSeconds = entry.Definition.WindupSeconds,
		ActiveSeconds = entry.Definition.ActiveSeconds,
		RecoverySeconds = entry.Definition.RecoverySeconds,
		CooldownSeconds = cooldownSeconds,
		-- "" for every Default move today (DefaultMoveRegistry's own header). The client treats a blank
		-- id as "no clip", never as an error.
		AnimationId = entry.AnimationId,
		PlaybackSpeed = entry.PlaybackSpeed,
		ContactVolume = contactVolumeOf(entry.Definition),
		StringEnd = if AttackCatalog.IsStringEnder(resolution.MoveId) then true else nil,
		PressId = request.PressId,
	})

	debugLog(AttackConstants.Debug.LogAccepted, "Attack thrown", {
		model = model.Name,
		moveId = resolution.MoveId,
		stageIndex = resolution.StageIndex,
		comboStage = comboStage,
	})
	return true, nil
end

-- PUBLIC, so a bot's decision-making can throw through exactly the same path a player's press does,
-- with no special casing anywhere in this file -- the same reason DefenseSystem.SetBlocking is
-- exposed alongside its own remote handler.
--
-- `_authorized` is unused (resolveRequest no longer branches on it, and the Hotbar Qi charge no longer
-- exempts it either) but stays in the signature: Press below still needs to accept, remember, and
-- replay it for a buffered press's later re-validation (rememberRefused's own Authorized field), and
-- every existing caller -- production and this module's own spec -- already calls Throw positionally
-- with it.
function AttackRequestSystem.Throw(
	model: Model,
	request: AttackRequest,
	_authorized: boolean,
	now: number
): (boolean, string?)
	return throw(model, request, now, nil)
end

-- Throws one specific move by id, through every gate Throw applies -- the Move Editor's Test button
-- (Server/Systems/MoveEditorSystem.lua), and the reason the editor never needs a combat path of its own.
--
-- It is a one-off cast, exactly like a hotbar art: its own authored Cooldown, no chain beat, and the
-- string keeps its place (Kind "Hotbar", with no Slot, so no client slot lights up). What it skips is
-- only the art machinery -- resolving a slot and charging Qi -- because the move under test need not be
-- an art, and an admin tuning one must not pay for, or level up from, their own test swings.
--
-- NO AUTHORIZATION HERE, deliberately, the same way HitboxEngine.SetDebugVolumesEnabled has none: this
-- layer has no notion of who may do what, and throwing an arbitrary MoveId is only safe behind the
-- caller's own admin gate. The one caller is MoveEditorSystem's TestFire handler, behind AdminGate.
function AttackRequestSystem.ThrowMove(model: Model, moveId: string, now: number): (boolean, string?)
	if not AttackCatalog.Has(moveId) then
		return false, "UnknownMove"
	end
	-- The same refusal a hotbar press gets mid air string: the air grammar has no one-off branch.
	if AirComboSystem.IsAttacker(model) then
		return false, "AirCombo"
	end
	return throw(model, { Kind = "Hotbar" }, now, {
		MoveId = moveId,
		WeaponId = SwingSequencer.GetWeapon(model),
		StageIndex = 0,
	})
end

-- Feinting -----------------------------------------------------------------------------------------

-- Cancels this combatant's own swing early in its windup, to bait a parry or a block. Returns
-- (accepted, reason); a refusal is ordinary and never an error, the same contract as Throw.
--
-- THE GATE, in the order it is asked: a swing this layer threw is in flight, the engine still has it
-- in Windup, the move is feintable (MoveTypes.IsFeintable -- Heavy stages by default), no more than
-- AttackConstants.Feint.WindowFraction of that windup has elapsed, and the feint cooldown has passed.
-- The window is what makes a feint a read rather than a reaction -- see that constant's own header.
--
-- WHAT A FEINT DOES: the engine interrupts the swing through its own CancelAttack (so nothing is left
-- locked, and no hitbox ever opens), the string is abandoned back to stage 1, the attacker's lockout --
-- the chain beat, a swing-length move cooldown, and CombatBusyUntil -- is rewritten to the feint's own
-- short recovery, and the attacker is told on Attack_Cancelled so their clip stops. The stop reaches
-- everyone else through the attacker's Animator, which replicates; no broadcast needed.
--
-- NOT REFUNDED: an art's Qi. A feintable art is authorable (a custom move may set Feintable) and
-- feinting it still costs the cast -- the charge happened when the engine accepted the swing, and
-- refunding it would make a Qi-costed feint free.
--
-- PUBLIC, for the same "one path for players and bots" reason Throw is.
function AttackRequestSystem.Feint(model: Model, now: number): (boolean, string?)
	if not isAlive(model) then
		return false, "NoCharacter"
	end
	local combatantId = combatantIds[model] or HitboxEngine.GetCombatantId(model)
	if not combatantId then
		return false, "NotRegistered"
	end
	local swing = inFlight[model]
	if not swing or HitboxEngine.GetAttackState(combatantId) ~= "Windup" then
		return false, "NotInWindup"
	end
	if not swing.Feintable then
		return false, "NotFeintable"
	end
	if now - swing.StartedAt > swing.WindupSeconds * AttackConstants.Feint.WindowFraction then
		return false, "TooLate"
	end
	local readyAt = feintReadyAt[model]
	if readyAt and now < readyAt then
		return false, "Cooldown"
	end

	if not HitboxEngine.CancelAttack(combatantId, "Feint", now) then
		return false, "NotInWindup"
	end
	inFlight[model] = nil
	clearTell(model)
	feintReadyAt[model] = now + AttackConstants.Feint.CooldownSeconds
	-- A press buffered against the swing being cancelled was aimed at what came after THAT swing. The
	-- player now decides afresh -- firing it on the recovery's last frame would turn every feint into a
	-- guaranteed follow-up the player never chose.
	dropBuffered(model, "Dropped")

	local recoveredAt = now + AttackConstants.Feint.RecoverySeconds
	SwingSequencer.CancelString(model, recoveredAt, now)
	if swing.SwingLengthCooldown then
		local perMove = cooldownUntil[model]
		if perMove then
			perMove[swing.MoveId] = recoveredAt
		end
	end
	-- A bare write, deliberately -- the one exception the math.max note in Throw names.
	local humanoid = CharacterUtil.HumanoidOf(model)
	if humanoid then
		humanoid:SetAttribute(Constants.Attributes.CombatBusyUntil, recoveredAt)
	end

	local remote = cancelledRemote
	local player = Players:GetPlayerFromCharacter(model)
	if remote and player then
		remote:FireClient(
			player,
			{
				MoveId = swing.MoveId,
				Reason = "Feint",
				RecoverySeconds = AttackConstants.Feint.RecoverySeconds,
			} :: AttackTypes.AttackCancelledPayload
		)
	end

	debugLog(AttackConstants.Debug.LogAccepted, "Swing feinted", { model = model.Name, moveId = swing.MoveId })
	return true, nil
end

-- Parried and traded ---------------------------------------------------------------------------------

-- The body shared by the two public keepers below: restore the string to where it was before `moveId` was
-- thrown, hold the landed combo until the string can continue, and tell the client's mirror where it went.
-- `readyAt`, when given, is when the next link may be thrown (SwingSequencer.RestoreParried).
local function keepChain(
	model: Model,
	moveId: string,
	reason: "Parried" | "Traded",
	resumeAt: number,
	readyAt: number?,
	at: number
): boolean
	if not SwingSequencer.RestoreParried(model, moveId, resumeAt, readyAt) then
		return false
	end
	DamageSystem.HoldCombo(model, resumeAt + DamageConstants.Combo.WindowSeconds, at)

	-- The client mirrors the string to predict the next swing's clip (AttackInputClient). Tell it where the
	-- string went back to, or its next prediction plays the stage AFTER the one the server will throw.
	local remote = cancelledRemote
	local player = Players:GetPlayerFromCharacter(model)
	if remote and player then
		local kind, stage = SwingSequencer.GetString(model, at)
		remote:FireClient(
			player,
			{
				MoveId = moveId,
				Reason = reason,
				RecoverySeconds = resumeAt - at,
				StringKind = kind,
				StringStage = stage,
			} :: AttackTypes.AttackCancelledPayload
		)
	end

	debugLog(AttackConstants.Debug.LogAccepted, `{reason} -- chain kept`, { model = model.Name, moveId = moveId })
	return true
end

-- A parried swing keeps the attacker's chain: the string goes back to where it was before that swing, and
-- the string and the landed combo are both held until the stagger ends, so the next press continues rather
-- than restarting. Returns whether a chain was kept. `moveId` is the parried swing's, and `perfect` and `at`
-- are the outcome's own Perfect flag and SampleTime.
--
-- "WHENEVER WE GET PARRIED ON A CHAIN OUR M1 CHAIN NEEDS TO STAY WHERE IT WAS, SO WE CAN DO AN UPPERCUT IF
-- WE WERE CLOSE" (user, 2026-09-29). B1 and B2 land, B3 is parried: after the stagger, M1 is B3 and Space +
-- M1 after it launches. A parried launcher leaves the string at B3 with the landed depth held, so Space +
-- M1 tries the launcher again. The PUNISH IS UNCHANGED. The attacker is staggered exactly as long as
-- before and the parrier's free combo is the same. What the attacker keeps is only the progress the
-- parried swing never spent.
--
-- The combo is held a full DamageConstants.Combo.WindowSeconds past the stagger. The attacker cannot land
-- anything while staggered, and the parried swing's own contact was usually most of a window after the
-- hit before it, so a hold that only reached the stagger's end would lapse the moment they could swing.
--
-- AIR MOVES KEEP NOTHING. A parried air hit is the victim's one way out and ends the combo
-- (docs/design/air-combat-and-evade.md B4); SwingSequencer keeps no undo for one, so this returns false.
--
-- PUBLIC for the spec, and so a scripted caller can drive it; production reaches it only through
-- onDamageApplied below.
function AttackRequestSystem.KeepChainThroughParry(model: Model, moveId: string, perfect: boolean, at: number): boolean
	return keepChain(model, moveId, "Parried", at + DefenseSystem.ParryStaggerSeconds(perfect), nil, at)
end

-- A TRADE KEEPS THE CHAIN TOO (DefenseConstants.Clash). Two swings met and neither landed, so neither spends
-- its stage -- the same rule as a parry, for the same reason -- and both sides may swing again at the same
-- instant, Clash.RecoverySeconds after the contact, whatever was left of the swing each one had cut.
--
-- PUBLIC for the spec; production reaches it only through onDamageApplied below.
function AttackRequestSystem.KeepChainThroughTrade(model: Model, moveId: string, at: number): boolean
	local resumeAt = at + DefenseConstants.Clash.RecoverySeconds
	return keepChain(model, moveId, "Traded", resumeAt, resumeAt, at)
end

local function onDamageApplied(outcome: DefenseTypes.DefenseOutcome, _result: DamageTypes.DamageResult): ()
	-- Both answers below are about the attacker's SWING -- its recovery cut on a landed hit, its string kept
	-- through a parry. A projectile's contact arrives on its own clock, long after (or during some other)
	-- swing, so it confirms nothing and keeps nothing; the shot's own parry response was the defence
	-- layer's to apply (HitboxEngine.ParryProjectile).
	-- An impact (DamageSystem.ApplyImpact) is no swing's contact either.
	if HitboxTypes.SourceOf(outcome.Report) ~= "Melee" then
		return
	end
	if AttackConstants.HitConfirm.ConfirmKinds[outcome.Kind] then
		AttackRequestSystem.NoteHitConfirmed(outcome.Attacker, outcome.Report.DebugName)
		-- The hit cut the DEFENDER's own swing (DamageSystem's hitstun cancel), so their tell is over.
		clearTell(outcome.Defender)
		return
	end
	if outcome.Kind == "Trade" then
		-- Both swings were cut: the attacker's always, the defender's too when the trade was a clash. Each
		-- keeps its place. The defender's swing is named by what it had in flight -- it was out and meeting
		-- this one, so that entry is the swing that just got cut.
		clearTell(outcome.Attacker)
		AttackRequestSystem.KeepChainThroughTrade(outcome.Attacker, outcome.Report.DebugName, outcome.SampleTime)
		local defenderSwing = inFlight[outcome.Defender]
		if outcome.Clash == true and defenderSwing then
			clearTell(outcome.Defender)
			AttackRequestSystem.KeepChainThroughTrade(outcome.Defender, defenderSwing.MoveId, outcome.SampleTime)
		end
		return
	end
	if outcome.Kind ~= "Parried" then
		return
	end
	clearTell(outcome.Attacker)
	AttackRequestSystem.KeepChainThroughParry(
		outcome.Attacker,
		outcome.Report.DebugName,
		outcome.Perfect == true,
		outcome.SampleTime
	)
end

-- Cuts a LANDED swing's recovery so the evade that was just accepted can take effect (AttackConstants.
-- HitConfirm.CancelInto.Evade). Returns whether it cut anything. Reached from the composition root
-- (Main.server.lua), which calls this before DefenseSystem.BeginEvade on an accepted Evade report: that
-- System refuses evade frames to a body still in a swing, and a confirmed recovery is exactly the swing
-- this is allowed to end. Refused (false, nothing cut) before the cut point, for a swing that did not
-- land, and when Evade is not in CancelInto. That is the same answer the client's own gate gives.
function AttackRequestSystem.CancelRecoveryForEvade(model: Model, now: number): boolean
	local combatantId = combatantIds[model] or HitboxEngine.GetCombatantId(model)
	-- Judged a little ahead (EvadeLatencyToleranceSeconds): the evade report has no buffer to wait in.
	local judgedAt = now + AttackConstants.HitConfirm.EvadeLatencyToleranceSeconds
	if not combatantId or not confirmCancelReady(model, combatantId, "Evade", judgedAt) then
		return false
	end
	if not HitboxEngine.CancelRecovery(combatantId, now) then
		return false
	end
	-- A press buffered against the swing just cut was aimed at what came after it, not at an evade.
	dropBuffered(model, "Dropped")
	return true
end

-- Buffering ----------------------------------------------------------------------------------------

local function rememberRefused(
	model: Model,
	request: AttackRequest,
	authorized: boolean,
	reason: string,
	now: number
): ()
	if not AttackConstants.Input.TransientRefusals[reason] then
		-- Not a "not yet" -- see this file's header on why holding a guard, or an unauthorised hotbar
		-- press, must not be queued. Answered at once.
		answerRefused(model, request, reason)
		return
	end
	-- Newest wins, one slot. Replacing rather than queueing is the whole reason mashing cannot build a
	-- backlog that fires as a burst once the gate opens. The press it replaces is answered.
	dropBuffered(model, "Superseded")
	buffered[model] = {
		Request = request,
		ExpiresAt = now + AttackConstants.Input.BufferSeconds,
		Authorized = authorized,
	}
	debugLog(AttackConstants.Debug.LogBuffer, "Press buffered", { model = model.Name, reason = reason })
end

-- A PRESS, as opposed to a throw: tries to throw, and remembers the press for a moment if the only
-- reason it could not is one that clears on its own.
--
-- This is the entry point a press should go through -- the remote handler calls it, and so should a
-- bot, for the same "one path for players and bots" reason DefenseSystem.SetBlocking is exposed
-- alongside its own remote handler. Throw above stays public and separate for a caller that wants a
-- straight yes/no with no buffering at all (a scripted boss beat, a spec asserting a single gate).
--
-- Returns Throw's own (accepted, reason), so a caller can tell "thrown" from "buffered" from
-- "dropped" -- accepted is true for the first, and the reason distinguishes the other two through
-- AttackConstants.Input.TransientRefusals.
function AttackRequestSystem.Press(
	model: Model,
	request: AttackRequest,
	authorized: boolean,
	now: number
): (boolean, string?)
	local pressId = request.PressId
	if pressId then
		local last = lastPressId[model]
		if last and pressId <= last then
			-- Already answered: nothing to throw and nothing to say.
			return false, "Duplicate"
		end
		lastPressId[model] = pressId
	end
	local accepted, reason = AttackRequestSystem.Throw(model, request, authorized, now)
	if accepted then
		return true, nil
	end
	rememberRefused(model, request, authorized, reason or "Busy", now)
	return false, reason
end

-- Fires when a press that carried an id (AttackRequest.PressId) will not throw: refused on arrival, or buffered
-- and then expired, superseded or dropped -- `reason` says which. The same moment the pressing client hears its
-- "Refused" verdict. For a spec, and for whatever wants to explain a missing swing. Returns a disconnect.
function AttackRequestSystem.OnPressRefused(callback: (Model, number, string) -> ()): () -> ()
	table.insert(pressRefusedCallbacks, callback)
	return function()
		local index = table.find(pressRefusedCallbacks, callback)
		if index then
			table.remove(pressRefusedCallbacks, index)
		end
	end
end

-- Whether a press is currently sitting in this combatant's buffer. For a spec, and for any future
-- readout that wants to show a queued input.
function AttackRequestSystem.HasBufferedPress(model: Model, now: number): boolean
	local entry = buffered[model]
	return entry ~= nil and now < entry.ExpiresAt
end

-- Re-runs every buffered press against the CURRENT state, dropping whatever has expired. Re-validated
-- rather than replayed: the whole point is that a press buffered a moment ago may have become illegal
-- since, and firing it anyway would hand a parried player a swing out of their own stagger.
local function flushBuffers(now: number): ()
	for model, entry in buffered do
		if model.Parent == nil or now >= entry.ExpiresAt then
			dropBuffered(model, "Expired")
			continue
		end
		local accepted = AttackRequestSystem.Throw(model, entry.Request, entry.Authorized, now)
		if accepted then
			buffered[model] = nil
			debugLog(AttackConstants.Debug.LogBuffer, "Buffered press flushed", { model = model.Name })
		end
	end
end

-- Requests -----------------------------------------------------------------------------------------

-- Turns whatever arrived over the wire into an AttackRequest, or nil. Every field is checked rather
-- than trusted: this is a public remote, and the payload is the one thing in this system a client
-- authors.
local function sanitizeRequest(raw: unknown): AttackRequest?
	if typeof(raw) ~= "table" then
		return nil
	end
	local candidate = raw :: { [string]: unknown }
	-- Optional, and anything that is not a whole number in range is simply no id (the press still counts).
	local rawPressId = candidate.PressId
	local pressId: number? = nil
	if
		typeof(rawPressId) == "number"
		and rawPressId == rawPressId
		and rawPressId >= 1
		and rawPressId <= MAX_PRESS_ID
		and math.floor(rawPressId) == rawPressId
	then
		pressId = rawPressId
	end
	local kind = candidate.Kind
	if kind ~= "Basic" and kind ~= "Heavy" and kind ~= "Hotbar" then
		return nil
	end

	if kind ~= "Hotbar" then
		-- Slot and MoveId are meaningless outside a hotbar press and are dropped rather than carried,
		-- so a client cannot smuggle a MoveId in on a Basic press and have some later reader honour it.
		-- The modifier is the one extra a weapon press may carry, and only its one legal value survives.
		return {
			Kind = kind :: AttackTypes.AttackKind,
			Modifier = if candidate.Modifier == "Up" then "Up" else nil,
			PressId = pressId,
		}
	end

	local rawSlot = candidate.Slot
	-- The NaN check is not paranoia: math.floor(0/0) is still NaN, and NaN passes every comparison
	-- below by failing all of them, so an unchecked NaN slot would sail through as a valid index.
	if typeof(rawSlot) ~= "number" or rawSlot ~= rawSlot then
		return nil
	end
	local slot = math.floor(rawSlot :: number)
	if slot < 1 or slot > AttackConstants.Hotbar.SlotCount then
		return nil
	end

	local rawMoveId = candidate.MoveId
	if typeof(rawMoveId) ~= "string" or rawMoveId == "" then
		return nil
	end

	return { Kind = "Hotbar", Slot = slot, MoveId = rawMoveId :: string, PressId = pressId }
end

local function handleRequest(player: Player, raw: unknown): ()
	-- Throttled requests are DROPPED, never buffered: the buffer forgives a mistimed press, it does not
	-- hand a mashing client a queue.
	if requestLimiter:IsLimited(player) then
		return
	end

	local request = sanitizeRequest(raw)
	if not request then
		return
	end

	local character = player.Character
	if not character then
		return
	end

	local authorized = AdminConfig.AuthorizedUserIds[player.UserId] == true
	local accepted, reason = AttackRequestSystem.Press(character, request, authorized, os.clock())
	if not accepted then
		debugLog(AttackConstants.Debug.LogRefused, "Attack refused", {
			player = player.Name,
			kind = request.Kind,
			reason = reason,
		})
	end
end

local function handleFeint(player: Player): ()
	-- Throttled presses are dropped, and so is a refused one: a feint is a now-or-never decision, and
	-- a buffered feint would fire into whatever the player did next.
	if feintLimiter:IsLimited(player) then
		return
	end
	local character = player.Character
	if not character then
		return
	end
	local accepted, reason = AttackRequestSystem.Feint(character, os.clock())
	if not accepted then
		debugLog(AttackConstants.Debug.LogRefused, "Feint refused", { player = player.Name, reason = reason })
	end
end

local function handleSwap(player: Player): ()
	if swapLimiter:IsLimited(player) then
		return
	end
	local character = player.Character
	if not character then
		return
	end
	local weaponId = SwingSequencer.SwapWeapon(character, os.clock())
	if not weaponId then
		-- An empty roster (nothing in Workspace.Weapons). Nothing to swap TO, so the press is a no-op
		-- rather than an un-equip -- taking a player's weapon away on a swap they can't complete is a
		-- worse answer than ignoring the key.
		return
	end
	-- A swap abandons the in-progress string, so anything buffered against it is stale by definition.
	dropBuffered(character, "Dropped")
	notifyWeaponChanged(character, weaponId)

	local remote = weaponChangedRemote
	if remote then
		remote:FireClient(player, { WeaponId = weaponId } :: AttackTypes.WeaponChangedPayload)
	end
end

-- Registry -----------------------------------------------------------------------------------------

-- `humanoid` is resolved by Shared/PlayerLifecycle.lua before this is reached; the HumanoidRootPart
-- is this System's own additional requirement and is still looked up here. A character missing its
-- root is simply not registered -- the engine requires a root explicitly and there is nothing useful
-- to register without one.
local function bindCharacter(character: Model, humanoid: Humanoid): ()
	local rootPart = CharacterUtil.RootOf(character)
	if not rootPart then
		return
	end
	combatantIds[character] = HitboxEngine.RegisterCombatant(character, rootPart, humanoid)
	-- Reports the weapon a fresh life starts on (the roster's first, via SwingSequencer's own recordFor
	-- default) through the same signal a later swap uses -- see notifyWeaponChanged's own header for
	-- why this is a bind-time report rather than a separate "initial equip" path.
	notifyWeaponChanged(character, SwingSequencer.GetWeapon(character))
end

local function unbindCharacter(character: Model): ()
	local id = combatantIds[character]
	if id then
		HitboxEngine.UnregisterCombatant(id)
		combatantIds[character] = nil
	end
	-- A new life inherits none of the previous one's string, cooldowns or buffered press. Dropped here
	-- rather than left to the Step sweep so a respawn is immediate rather than up-to-a-frame stale.
	cooldownUntil[character] = nil
	lastPressId[character] = nil
	dropBuffered(character, "Dropped")
	inFlight[character] = nil
	feintReadyAt[character] = nil
	clearTell(character)
	SwingSequencer.Clear(character)
end

-- Public queries -----------------------------------------------------------------------------------

-- What an OPPONENT can see of this combatant's current swing: which move started, when, how long its
-- windup is, whether it may be feinted and how heavy it is -- or nil while nothing is swinging.
--
-- This is the information a practised player reads off the attacker's animation and their own
-- knowledge of the move list, and nothing more: not a buffered press, not whether a feint is coming.
-- Server/Combat/TrainingBot is its reader -- the bot decides when to parry from exactly this, plus its
-- own reaction delay, so it can be baited by a feint the same way a person can.
--
-- nil once the engine says the swing is over (Idle) or cut (Interrupted), rather than trusting inFlight,
-- which is deliberately left stale until the next accepted swing (see its own header). `now` is not
-- needed to answer, so it is not asked for. A fresh table per call: the caller may keep it.
export type InFlightView = {
	MoveId: string,
	StartedAt: number,
	WindupSeconds: number,
	Feintable: boolean,
	PowerLevel: number,
}

function AttackRequestSystem.GetInFlight(model: Model): InFlightView?
	local swing = inFlight[model]
	if not swing then
		return nil
	end
	local combatantId = combatantIds[model] or HitboxEngine.GetCombatantId(model)
	if not combatantId then
		return nil
	end
	local state = HitboxEngine.GetAttackState(combatantId)
	if state == nil or state == "Idle" or state == "Interrupted" then
		return nil
	end
	return {
		MoveId = swing.MoveId,
		StartedAt = swing.StartedAt,
		WindupSeconds = swing.WindupSeconds,
		Feintable = swing.Feintable,
		PowerLevel = swing.PowerLevel,
	}
end

-- Tells `callback` about every swing this layer COMMITS -- after every gate has passed and the engine
-- has accepted it, with the same InFlightView GetInFlight answers. Returns a disconnect function, the
-- OnWeaponChanged/DamageSystem.OnApplied shape. The extension point for a sibling that reacts to a swing
-- starting rather than to a hit landing -- Server/Combat/Environment/EnvironmentReactionSystem.lua (the
-- dust a swing scuffs off a wall) today. A subscriber that needs to know whether the swing survived to
-- its strike asks GetInFlight again at that time: a feint, a parry or a stun can end it in between, and
-- this signal deliberately says nothing about the future.
function AttackRequestSystem.OnSwingAccepted(callback: (Model, InFlightView) -> ()): () -> ()
	table.insert(swingAcceptedCallbacks, callback)
	return function()
		local index = table.find(swingAcceptedCallbacks, callback)
		if index then
			table.remove(swingAcceptedCallbacks, index)
		end
	end
end

-- Seconds until this combatant may throw this move again. For a HUD, a bot's own planning, or a spec.
function AttackRequestSystem.GetCooldownRemaining(model: Model, moveId: string, now: number): number
	return cooldownRemaining(model, moveId, now)
end

function AttackRequestSystem.GetWeapon(model: Model): Types.WeaponId?
	return SwingSequencer.GetWeapon(model)
end

-- Puts `weaponId` in this combatant's hand -- or empties it, for nil -- AND tells everything
-- downstream that it changed. The entry point anything outside this layer uses to arm or disarm
-- somebody; Server/Combat/Weapon/WeaponInventorySystem.lua's draw/sheathe is its only caller today.
--
-- EXISTS BECAUSE SwingSequencer.SetWeapon IS NOT ENOUGH ON ITS OWN, and that gap shipped once: the
-- inventory system called SwingSequencer directly, which mutated the record and notified nobody. The
-- sequencer knew the player was armed (they could actually swing), the HUD knew (it is fed
-- separately), and WeaponVisualSystem -- the one thing that puts a Tool in the hand -- was never told,
-- so drawing a weapon reported success and produced no sword. Two components agreeing with each other
-- is not evidence the third consumer was updated.
--
-- So the SETTER lives here, next to the signal it has to fire, rather than callers being trusted to
-- remember a second call. Returns whether the change was accepted -- false for an id the roster does
-- not know (SwingSequencer.SetWeapon's own check), in which case nothing is notified either.
function AttackRequestSystem.SetWeapon(model: Model, weaponId: Types.WeaponId?, now: number): boolean
	if weaponId == nil then
		SwingSequencer.ClearWeapon(model, now)
		-- A swap abandons the in-progress string, so anything buffered against it is stale -- the same
		-- reasoning handleSwap's own buffer clear gives.
		dropBuffered(model, "Dropped")
		notifyWeaponChanged(model, nil)
		return true
	end

	if not SwingSequencer.SetWeapon(model, weaponId, now) then
		return false
	end
	dropBuffered(model, "Dropped")
	notifyWeaponChanged(model, weaponId)
	return true
end

-- This layer's weapon-swap signal, for anything downstream that wants to react to which weapon a
-- combatant currently fights with -- WeaponVisualSystem today. Fires on every accepted swap AND once
-- per character bind (spawn/respawn -- see bindCharacter), so a subscriber never has to special-case
-- what a fresh life starts holding separately from what a swap changes it to. Returns a disconnect
-- function rather than a connection object, matching DamageSystem.OnApplied's own contract.
function AttackRequestSystem.OnWeaponChanged(callback: (Model, Types.WeaponId) -> ()): () -> ()
	table.insert(weaponChangedCallbacks, callback)
	return function()
		local index = table.find(weaponChangedCallbacks, callback)
		if index then
			table.remove(weaponChangedCallbacks, index)
		end
	end
end

-- The loop -----------------------------------------------------------------------------------------

-- One frame. `now` is the caller's clock, matching HitboxEngine.Step, DefenseSystem.Step and
-- DamageSystem.Step's own convention so all four agree about what a frame is.
function AttackRequestSystem.Step(_deltaTime: number, now: number): ()
	flushBuffers(now)

	-- Reclaims cooldown records for characters that no longer exist. Every individual timestamp
	-- expires on its own, so this only exists to stop the OUTER table holding a reference to a
	-- destroyed model forever -- which is exactly the "nothing here goes stale in a way a reader can
	-- observe" property that makes an amortised cursor safe. Both of these used to be a FULL walk of
	-- their table every frame; they are now a fixed handful of key checks regardless of how many
	-- combatants the server holds. See Shared/AmortizedReclaim.lua, and note the deliberate contrast
	-- with DamageSystem.Step's lungeUntil and GrabSystem.Step's holds/flights, which do per-entry work
	-- and therefore keep their full walks.
	cooldownReclaim:Step(cooldownUntil)
	-- Same reclaim for combatantIds -- unlike cooldownUntil this one is normally cleared by
	-- unbindCharacter's CharacterRemoving/PlayerRemoving handlers, but this is the belt-and-braces
	-- sweep every other per-model table in this stack keeps (DamageSystem.Step, SwingSequencer.Sweep)
	-- in case that event ordering is ever missed.
	combatantIdsReclaim:Step(combatantIds)
	-- Same reclaim-only shape: both are read-on-demand and timestamp- or engine-checked, never walked.
	inFlightReclaim:Step(inFlight)
	feintReadyReclaim:Step(feintReadyAt)
	SwingSequencer.Sweep()

	-- THE GUARD CUT (AttackConstants.GuardCut): a guard held against this body's own swing cuts the tail of
	-- its recovery. DefenseSystem raises the held guard on its next Step, once the engine reports the body
	-- free. A full walk of inFlight, but the first test is one lookup, and only a body with a guard waiting
	-- gets past it.
	if AttackConstants.GuardCut.Enabled then
		for model, swing in inFlight do
			if not DefenseSystem.IsGuardDeferred(model) or AirComboMoves.RoleOf(swing.MoveId) ~= nil then
				continue
			end
			local cutAt = AttackConstants.GuardCutAt(
				swing.StartedAt,
				swing.WindupSeconds,
				swing.ActiveSeconds,
				swing.RecoverySeconds
			)
			local combatantId = combatantIds[model] or HitboxEngine.GetCombatantId(model)
			if now >= cutAt and combatantId and HitboxEngine.CancelRecovery(combatantId, now) then
				-- A press buffered against the swing just cut was aimed at what came after it, not at a guard.
				dropBuffered(model, "Dropped")
			end
		end
	end

	-- A full walk, unlike the reclaims above: every entry is a live tell with a deadline to act on, and
	-- there are only ever as many as there are heavies winding up right now.
	for model, endsAt in tellEndsAt do
		if now >= endsAt or model.Parent == nil then
			clearTell(model)
		end
	end
end

-- Lifecycle ----------------------------------------------------------------------------------------

function AttackRequestSystem.Init(): ()
	if started then
		return
	end
	-- See this file's header: Heartbeat order is a correctness property, not a preference. Asserted
	-- rather than documented, because a comment in Main.server.lua cannot fail a boot.
	assert(HitboxEngine.RegisteredCount() >= 0, "AttackRequestSystem.Init() requires HitboxEngine to be available")
	assert(DefenseSystem.CanAttack ~= nil, "AttackRequestSystem.Init() requires DefenseSystem to be available")
	assert(DamageSystem.CanAttack ~= nil, "AttackRequestSystem.Init() requires DamageSystem to be available")
	assert(GrabSystem.CanAttack ~= nil, "AttackRequestSystem.Init() requires GrabSystem to be available")
	assert(AirComboSystem.CanAttack ~= nil, "AttackRequestSystem.Init() requires AirComboSystem to be available")
	started = true

	local requestRemote = NetworkBridge.CreateRemoteEvent(AttackConstants.Network.RemoteNames.Request)
	requestRemote.OnServerEvent:Connect(handleRequest)
	startedRemote = NetworkBridge.CreateRemoteEvent(AttackConstants.Network.RemoteNames.Started)

	local swapRemote = NetworkBridge.CreateRemoteEvent(AttackConstants.Network.RemoteNames.SwapWeapon)
	swapRemote.OnServerEvent:Connect(handleSwap)
	weaponChangedRemote = NetworkBridge.CreateRemoteEvent(AttackConstants.Network.RemoteNames.WeaponChanged)

	local feintRemote = NetworkBridge.CreateRemoteEvent(AttackConstants.Network.RemoteNames.Feint)
	feintRemote.OnServerEvent:Connect(handleFeint)
	cancelledRemote = NetworkBridge.CreateRemoteEvent(AttackConstants.Network.RemoteNames.Cancelled)

	-- Shots in flight, to the clients they concern (Client/FX/ProjectileFX.lua, ProjectileRelevance). The engine has no remote of its own
	-- by design; this layer, which already tells clients what it threw, tells them what it launched.
	projectileRemote = NetworkBridge.CreateRemoteEvent(AttackConstants.Network.RemoteNames.Projectile)
	projectileDisconnect = HitboxEngine.OnProjectileEvents(broadcastProjectiles)

	-- A parried swing keeps its chain -- see KeepChainThroughParry. DamageSystem.OnApplied is that layer's
	-- documented extension point and fires for Parried too (GrabSystem subscribes the same way).
	appliedDisconnect = DamageSystem.OnApplied(onDamageApplied)

	-- REGISTERS PLAYER CHARACTERS WITH THE ENGINE, inherited from the deleted TestAttackHarness -- see
	-- this file's header. Bots and dummies are NOT auto-registered: they have no CharacterAdded to
	-- hang off, and whoever spawns them already knows when they exist.
	-- Through Shared/PlayerLifecycle.lua: the per-player CharacterAdded/CharacterRemoving hookup and
	-- the Init()-time sweep for players who joined before this System booted are all its job now.
	PlayerLifecycle.BindAllPlayers({
		Scope = "AttackRequestSystem",
		OnPlayerRemoving = function(player: Player)
			requestLimiter:Clear(player)
			swapLimiter:Clear(player)
			feintLimiter:Clear(player)
			local character = player.Character
			if character then
				unbindCharacter(character)
			end
		end,
		OnCharacter = function(_player: Player, character: Model, humanoid: Humanoid)
			bindCharacter(character, humanoid)
		end,
		OnCharacterRemoving = function(_player: Player, character: Model)
			unbindCharacter(character)
		end,
	})

	-- Connected AFTER DamageSystem.Init has connected its own, which Main.server.lua guarantees by
	-- calling that first.
	heartbeatTrove:Connect(RunService.Heartbeat, function(deltaTime: number)
		AttackRequestSystem.Step(deltaTime, os.clock())
	end)

	-- Warms AttackWindows' clip cache for every move with a clip and reports what it found -- the same
	-- "spawned rather than awaited" reasoning DefenseSystem.Init gives ParryWindows.ValidateAll:
	-- GetKeyframeSequenceAsync is a rate-limited web call, and blocking boot on it would cost every
	-- player more than the first few seconds of swings on their authored timeline ever would.
	task.spawn(function()
		AttackWindows.ValidateAll(collectClipEntries())
	end)

	logger:info("AttackRequestSystem.Init() complete")
end

function AttackRequestSystem.Shutdown(): ()
	heartbeatTrove:Clean()
	local disconnect = appliedDisconnect
	appliedDisconnect = nil
	if disconnect then
		disconnect()
	end
	local disconnectProjectiles = projectileDisconnect
	projectileDisconnect = nil
	if disconnectProjectiles then
		disconnectProjectiles()
	end
	started = false
end

-- Drops every piece of per-combatant state, and every OnWeaponChanged subscription -- otherwise a
-- WeaponVisualSystem.spec.lua case that calls WeaponVisualSystem.Attach() would leak its callback into
-- the next spec file's AttackRequestSystem entirely, the one piece of state here that is not
-- per-combatant. Spec-only, so one case cannot serve another its state -- the same role HitboxEngine.
-- Reset, DefenseSystem.Reset and DamageSystem.Reset play for their own modules.
function AttackRequestSystem.Reset(): ()
	table.clear(combatantIds)
	table.clear(cooldownUntil)
	combatantIdsReclaim:Reset()
	cooldownReclaim:Reset()
	table.clear(buffered)
	table.clear(lastPressId)
	table.clear(inFlight)
	table.clear(feintReadyAt)
	for model in tellEndsAt do
		clearTell(model)
	end
	inFlightReclaim:Reset()
	feintReadyReclaim:Reset()
	table.clear(weaponChangedCallbacks)
	table.clear(swingAcceptedCallbacks)
	projectileRelevance:Reset()
	SwingSequencer.Reset()
end

return AttackRequestSystem :: Types.SystemModule & typeof(AttackRequestSystem)
