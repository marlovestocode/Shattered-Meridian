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
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AttackConstants = require(ReplicatedStorage.Shared.Attack.AttackConstants)
local AttackTypes = require(ReplicatedStorage.Shared.Attack.AttackTypes)
local AttackWindows = require(ReplicatedStorage.Shared.Attack.AttackWindows)
local AmortizedReclaim = require(ReplicatedStorage.Shared.AmortizedReclaim)
local Constants = require(ReplicatedStorage.Shared.Constants)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local Logger = require(ReplicatedStorage.Shared.Logger)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local ParkourOwnership = require(ReplicatedStorage.Shared.Parkour.ParkourOwnership)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local Trove = require(ReplicatedStorage.Shared.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local SwingSequencer = require(script.Parent.SwingSequencer)
local AttackCatalog = require(script.Parent.Parent.AttackCatalog)
local DefaultMoveRegistry = require(script.Parent.Parent.DefaultMoveRegistry)
local MoveRegistryManager = require(script.Parent.Parent.MoveRegistryManager)
local DamageSystem = require(script.Parent.Parent.Damage.DamageSystem)
local DefenseSystem = require(script.Parent.Parent.Defense.DefenseSystem)
local GrabSystem = require(script.Parent.Parent.Grab.GrabSystem)
local HitboxEngine = require(script.Parent.Parent.HitboxEngine.HitboxEngine)
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
}
local inFlight: { [Model]: InFlight } = {}

-- When each combatant may feint again (AttackConstants.Feint.CooldownSeconds).
local feintReadyAt: { [Model]: number } = {}
local inFlightReclaim = AmortizedReclaim.New()
local feintReadyReclaim = AmortizedReclaim.New()

local started = false
local heartbeatTrove = Trove.New()
local startedRemote: RemoteEvent? = nil
local weaponChangedRemote: RemoteEvent? = nil
local cancelledRemote: RemoteEvent? = nil
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
		IsFinisher = false,
	},
		nil
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

	local resolution = SwingSequencer.Resolve(model, request.Kind, DamageSystem.GetComboStage(model, now), now)
	if not resolution then
		return nil, "UnknownMove"
	end
	return resolution, nil
end

-- Runs every gate and, if they all pass, actually throws. Returns (accepted, reason) -- a refusal is
-- normal and never an error, matching HitboxEngine.RequestAttack's own contract.
--
-- PUBLIC, so a bot's decision-making can throw through exactly the same path a player's press does,
-- with no special casing anywhere in this file -- the same reason DefenseSystem.SetBlocking is
-- exposed alongside its own remote handler.
--
-- `_authorized` is unused inside this function itself (resolveRequest no longer branches on it, and
-- the Hotbar Qi charge below no longer exempts it either -- see this function's own note there) but
-- stays in the signature: Press below still needs to accept, remember, and replay it for a buffered
-- press's later re-validation (rememberRefused's own Authorized field), and every existing caller --
-- production and this module's own spec -- already calls Throw positionally with it.
function AttackRequestSystem.Throw(
	model: Model,
	request: AttackRequest,
	_authorized: boolean,
	now: number
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

	local resolution, resolveReason = resolveRequest(model, request, now)
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
	if request.Kind ~= "Hotbar" and SwingSequencer.ChainDelayRemaining(model, now) > 0 then
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
	local accepted, engineReason =
		HitboxEngine.RequestAttack(combatantId, entry.Definition, comboStage, entry.PowerLevel)
	if not accepted then
		return false, engineReason or "Busy"
	end

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
	if request.Kind == "Hotbar" then
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
		SwingSequencer.Advance(model, request.Kind, resolution, commitment, now)
	end
	setCooldown(model, resolution.MoveId, entry.Cooldown, now)
	inFlight[model] = {
		MoveId = resolution.MoveId,
		Feintable = entry.Feintable,
		StartedAt = now,
		WindupSeconds = entry.Definition.WindupSeconds,
		SwingLengthCooldown = entry.Cooldown <= commitment + 1e-6,
		PowerLevel = entry.PowerLevel,
	}
	-- The same public view GetInFlight hands out, told to OnSwingAccepted subscribers the moment the swing
	-- is committed. A fresh table, so a subscriber may keep it.
	notifySwingAccepted(model, {
		MoveId = resolution.MoveId,
		StartedAt = now,
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
		humanoidForBusy:SetAttribute(Constants.Attributes.CombatBusyUntil, math.max(busyUntil, now + commitment))
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
		CooldownSeconds = entry.Cooldown,
		-- "" for every Default move today (DefaultMoveRegistry's own header). The client treats a blank
		-- id as "no clip", never as an error.
		AnimationId = entry.AnimationId,
		PlaybackSpeed = entry.PlaybackSpeed,
	})

	debugLog(AttackConstants.Debug.LogAccepted, "Attack thrown", {
		model = model.Name,
		moveId = resolution.MoveId,
		stageIndex = resolution.StageIndex,
		comboStage = comboStage,
	})
	return true, nil
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
	feintReadyAt[model] = now + AttackConstants.Feint.CooldownSeconds
	-- A press buffered against the swing being cancelled was aimed at what came after THAT swing. The
	-- player now decides afresh -- firing it on the recovery's last frame would turn every feint into a
	-- guaranteed follow-up the player never chose.
	buffered[model] = nil

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
		-- press, must not be queued.
		return
	end
	-- Newest wins, one slot. Replacing rather than queueing is the whole reason mashing cannot build a
	-- backlog that fires as a burst once the gate opens.
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
	local accepted, reason = AttackRequestSystem.Throw(model, request, authorized, now)
	if accepted then
		return true, nil
	end
	rememberRefused(model, request, authorized, reason or "Busy", now)
	return false, reason
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
			buffered[model] = nil
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
	local kind = candidate.Kind
	if kind ~= "Basic" and kind ~= "Heavy" and kind ~= "Hotbar" then
		return nil
	end

	if kind ~= "Hotbar" then
		-- Slot and MoveId are meaningless outside a hotbar press and are dropped rather than carried,
		-- so a client cannot smuggle a MoveId in on a Basic press and have some later reader honour it.
		return { Kind = kind :: AttackTypes.AttackKind }
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

	return { Kind = "Hotbar", Slot = slot, MoveId = rawMoveId :: string }
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
	buffered[character] = nil
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
	buffered[character] = nil
	inFlight[character] = nil
	feintReadyAt[character] = nil
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
		buffered[model] = nil
		notifyWeaponChanged(model, nil)
		return true
	end

	if not SwingSequencer.SetWeapon(model, weaponId, now) then
		return false
	end
	buffered[model] = nil
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
	table.clear(inFlight)
	table.clear(feintReadyAt)
	inFlightReclaim:Reset()
	feintReadyReclaim:Reset()
	table.clear(weaponChangedCallbacks)
	table.clear(swingAcceptedCallbacks)
	SwingSequencer.Reset()
end

return AttackRequestSystem :: Types.SystemModule & typeof(AttackRequestSystem)
