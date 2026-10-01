--!strict
--[[
	DefenseSystem.lua

	Owns: the Defense System's public surface -- the HitboxEngine.OnHit subscription, the per-combatant
	registry, the block/parry remotes, the DefenseState Attribute, and the two-pass resolution that
	turns contacts into outcomes.

	WHAT THIS LAYER IS FOR. The hitbox engine reports contacts and deliberately refuses to say what a
	contact MEANS. This system is the first consumer of that signal: it decides what KIND of hit it
	was -- clean, blocked, parried, traded, guard-broken, backstab, evaded -- and then stops. It emits a
	DefenseOutcome and applies no damage, no health, no knockback. The damage layer subscribes to
	OnResolved exactly the way this subscribes to OnHit, and neither had to be rewritten to
	accommodate the other.

	    HitboxEngine     where the volume is, who is inside it
	    DefenseSystem    what kind of hit that was              <- this module
	    DamageSystem     how much it hurts, what it does to you

	THE ONE THING THE LAYER ABOVE REACHES BACK FOR is the guard meter, because guard doubles as the
	posture pool -- see DefenseSystem.DrainGuard's own header. That is a narrow, one-function seam and
	it keeps the pool's ownership here rather than splitting it across two systems.

	TWO PASSES, AND WHY ONE IS NOT ENOUGH. The engine subdivides a Heartbeat into up to eight substeps
	and fires OnHit from inside that loop, so one frame can deliver contacts tens of milliseconds
	apart -- comfortably wider than a parry window.
	  * PASS 1 runs eagerly inside OnHit and CLASSIFIES each contact against the defender's posture at
	    that contact's own SampleTime (DefenseStateMachine.StateAt/BlockHeldAt/IsParryLiveAt). Nothing
	    is applied. Classifying the whole frame against the posture at frame END would let a hit that
	    landed before ParryStart be parried, and one that landed after it closed be parried too,
	    both silently. Running here also means the bearing is measured against poses from the substep
	    the contact was found in rather than from the end of the frame.
	  * PASS 2 runs at the end of the frame, ARBITRATES trades across the batch, then applies and
	    emits. Trades need the whole batch by definition, and applying eagerly would mean whichever
	    report arrived first cancelled the other before the trade could be seen. That is also what
	    makes a CLASH possible (DefenseConstants.Clash): two Clean hits that land on each other in the
	    same frame are one exchange, not two independent hits, and only the batch can see both.

	THE ONE-FRAME RESIDUAL, stated rather than hidden. Because cancels apply in pass 2, a parried
	attacker's swing keeps sampling for the remainder of the frame it was parried in and can land a
	contact after the parry that killed it. It is bounded at one frame, and it is the same bound the
	engine already accepts elsewhere -- its substep loop deliberately defers a callback-started
	follow-up swing to the next frame for the same reason. DefenseSystem.spec asserts the bound rather
	than the absence.

	HEARTBEAT ORDER IS LOAD-BEARING. Roblox fires Heartbeat connections in connection order, so this
	module's Step must run after HitboxEngine's or pass 2 executes before the substeps that fill its
	buffer and every batch resolves a frame late -- invisibly, and only on some boot orders. Init
	asserts the engine is already started rather than trusting a comment in Main.server.lua.

	Does not own: contact detection (HitboxEngine), window timing (Shared/Defense/ParryWindows.lua),
	damage of any kind, or the attack move set. Attack GATING is here rather than in the engine
	(CanAttack) precisely so the engine stays ignorant of stagger and remains standalone.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local AirComboAttributes = require(ReplicatedStorage.Shared.AirCombo.AirComboAttributes)
local AirComboConstants = require(ReplicatedStorage.Shared.AirCombo.AirComboConstants)
local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local DefenseTypes = require(ReplicatedStorage.Shared.Defense.DefenseTypes)
local DomainRules = require(ReplicatedStorage.Shared.Domain.DomainRules)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local ParkourOwnership = require(ReplicatedStorage.Shared.Parkour.ParkourOwnership)
local HitboxEngineConstants = require(ReplicatedStorage.Shared.HitboxEngine.HitboxEngineConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local ParryWindows = require(ReplicatedStorage.Shared.Defense.ParryWindows)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local Trove = require(ReplicatedStorage.Shared.Trove)
local Types = require(ReplicatedStorage.Shared.Types)
local WeaponDefenseAnimations = require(ReplicatedStorage.Shared.Defense.WeaponDefenseAnimations)

local DefenseStateMachine = require(script.Parent.DefenseStateMachine)
local GuardMeter = require(script.Parent.GuardMeter)
local OutcomeResolver = require(script.Parent.OutcomeResolver)
local HitboxEngine = require(script.Parent.Parent.HitboxEngine.HitboxEngine)
local NetworkLatency = require(script.Parent.Parent.NetworkLatency)

type DefenseState = DefenseTypes.DefenseState
type DefenseOutcome = DefenseTypes.DefenseOutcome
type PendingContact = DefenseTypes.PendingContact
type HitReport = HitboxTypes.HitReport

local logger = Logger.scope("DefenseSystem")

local DefenseSystem = {}

type Registration = {
	Model: Model,
	RootPart: BasePart,
	Humanoid: Humanoid,
	Machine: DefenseStateMachine.Machine,
	Guard: GuardMeter.Meter,
	-- The clip whose markers define this combatant's parry window. Empty when they have none, which
	-- is the fail-closed case: their block still works, it just never opens a window.
	ParryAnimationId: string,
	-- Whether THIS system currently holds RootControlLocked for this body. Mirrors the engine's own
	-- HoldsMovementLock flag, and for the same reason -- two writers to one Attribute need each to
	-- know whether it is the one holding it.
	HoldsMovementLock: boolean,
	-- The DefenseState last actually written to the Humanoid Attribute, so publishState can skip the
	-- write when Step re-asserts the same state it already published. See publishState's own header.
	PublishedState: DefenseState?,
	-- A guard press that arrived while the body was committed -- mid-swing or stunned -- and is being
	-- held until it is free. See SetBlocking. Cleared by the release, or by Step raising the guard.
	GuardDeferred: boolean,
	-- When the last guard release (key up, or an evade dropping the guard) reached this system. The rewind
	-- never judges a press as having happened before it -- see rewoundPressAt.
	ReleasedAt: number,
	-- The GuardCrack tag state last written to the Humanoid -- deduped like PublishedState, and the
	-- hysteresis memory publishGuardCrack needs (DefenseConstants.GuardCrack).
	PublishedCracking: boolean,
	-- The quantised guard fraction last written to the GuardFraction Attribute (publishGuardFraction),
	-- or nil before the first write. Deduped like PublishedCracking.
	PublishedGuardStep: number?,
	-- The parry trade this combatant is in (DefenseConstants.Rally): who with, how many parries have
	-- been traded so far, and when it lapses. RallyCount 0 / RallyPartner nil is "not rallying".
	RallyPartner: Model?,
	RallyCount: number,
	RallyLapsesAt: number,
	-- The owning player, resolved once at registration -- nil for a bot or a dummy, which has no client
	-- to tell and so is skipped by syncGuard without a Players lookup every frame.
	Player: Player?,
	-- The guard pool as the owning client was last told it, and when -- see syncGuard.
	SentGuard: number?,
	SentGuardMax: number?,
	GuardSentAt: number,
}

local registrations: { [Model]: Registration } = {}
-- This frame's classified-but-unapplied contacts. Cleared at the end of every Step.
local pending: { PendingContact } = {}
-- Defenders whose parry has already been spent by an earlier contact in THIS batch. Being surrounded
-- is supposed to be dangerous: one window stops one attack. Kept here rather than by consuming the
-- machine's own flag in pass 1, so pass 1 genuinely applies nothing.
local parryConsumedThisBatch: { [Model]: boolean } = {}
-- Each defender's guard as the contacts classified so far in THIS batch leave it. Pass 1 resolves every
-- contact before pass 2 applies any, so reading the pool fresh per contact classified each one against
-- the pool as it stood before the batch: two blocked hits drained it once, and a parry's restore was
-- invisible to a block behind it in the same batch. Cleared with the batch.
local batchGuard: { [Model]: number } = {}

-- THE REWIND HOLD. A Clean contact on a player-backed defender with a real round trip is not applied at the
-- end of its frame: it waits here for up to min(round trip, cap), so a parry or block pressed in time on the
-- defender's own screen -- whose press is still in flight to the server -- is not eaten by lag. A press
-- arriving in the hold is judged at its rewound time (see rewoundPressAt and resolveHeldContactsFor);
-- otherwise the contact applies as the Clean it was when the hold runs out.
--
-- Born as the air parry's rewind (docs/design/air-combat-and-evade.md B5, cap AirComboConstants.Parry.
-- RewindMaxSeconds) and extended to the ground (2026-09-29, cap DefenseConstants.Parry.RewindMaxSeconds),
-- because the same lag made ground parries feel late and ground blocks feel dropped. Only contacts a later
-- press could actually change are held (rewindHoldFor), so an exchange never stalls on a hit no input could
-- have answered. Air-held defenders keep their one rule: only the parry is rewound, never the guard.
type HeldContact = {
	Contact: PendingContact,
	ReleaseAt: number,
}
local heldContacts: { HeldContact } = {}

local outcomeCallbacks: { (DefenseOutcome) -> () } = {}

local started = false
local heartbeatTrove = Trove.New()
local hitDisconnect: (() -> ())? = nil
local stateChangedRemote: RemoteEvent? = nil
local rateLimiter = RateLimiter.New(DefenseConstants.Network.MaxCallsPerSecondPerPlayer)

-- The clip used by any combatant registered without one of their own.
local defaultParryAnimationId = ""

-- Helpers ------------------------------------------------------------------------------------------

local function debugLog(message: string, data: { [string]: any }?): ()
	if DefenseConstants.Debug.Enabled and DefenseConstants.Debug.LogOutcomes then
		logger:debug(message, data)
	end
end

-- Whether a parry can answer this contact at all. Every swing can; a projectile authored CannotParry
-- cannot (ProjectileTypes' header) -- the one projectile rule this layer applies itself.
local function isParryable(report: HitReport): boolean
	local projectile = report.Projectile
	return projectile == nil or projectile.Parryable
end

-- Spec-only replacement for the ping lookup below (SetPingResolver). A dummy has no Player and so no ping,
-- which would leave every latency rule in this system untestable without a live client.
local pingResolver: ((model: Model) -> number)? = nil

-- Network latency for a player-backed combatant, in seconds, as Player:GetNetworkPing reports it. Zero for
-- anything else -- a bot or a training dummy has no connection to refund.
local function pingSecondsFor(model: Model): number
	local resolver = pingResolver
	if resolver then
		return resolver(model)
	end
	return NetworkLatency.PingSeconds(model)
end

-- Whether this body is held in an air combo, or lying in a slam's intangible knockdown -- the Attributes
-- AirComboSystem publishes, read through Shared/AirCombo/AirComboAttributes (which owns their clock). Never
-- through a require of that System: the air combo is a sibling ABOVE this layer.
local isAirHeld = AirComboAttributes.IsHeld
local isAirComboIntangible = AirComboAttributes.IsIntangible

-- Publishes the live state so the HUD and any future spectator tooling can read it off the Humanoid
-- for free, and takes or releases the movement lock for the two states that genuinely remove control.
--
-- THE STATE ATTRIBUTE ITSELF IS DEDUPED, THE MOVEMENT LOCK IS NOT (see below for why the lock already
-- was). Step calls this every frame for every registration regardless of whether the state actually
-- changed -- RunSystem.lua's own header names writing an unchanged replicated Attribute sixty times a
-- second as "the single most expensive thing a System with a Heartbeat can do for no effect", and this
-- system used to do exactly that on every Humanoid it manages. PublishedState is what makes a re-
-- assertion of the same state a no-op instead of a property write.
--
-- ROOTCONTROLLOCKED HAS TWO WRITERS -- this system and HitboxEngine, which holds it for the duration
-- of a locking swing's Active window. They are kept from fighting by ordering rather than by locking:
-- in pass 2 an attacker's swing is CANCELLED before they are staggered, so the engine has already
-- released before this takes it. Step re-asserts every frame while the condition lasts, so even if
-- the engine clears it out from under us the gap is one frame, and this only ever CLEARS the
-- Attribute when it is the holder.
local function publishState(registration: Registration, state: DefenseState): ()
	local humanoid = registration.Humanoid
	if humanoid.Parent == nil then
		return
	end
	if registration.PublishedState ~= state then
		registration.PublishedState = state
		humanoid:SetAttribute(DefenseConstants.DefenseStateAttribute, state)
	end

	-- IsStaggerHeld covers a parry armed out of a stagger (DefenseConstants.Rally): the state is
	-- Raising/ParryWindow, but the punish is still running, so the body stays parked.
	local wantsLock = state == "Staggered" or state == "GuardBroken" or registration.Machine:IsStaggerHeld()
	if wantsLock == registration.HoldsMovementLock then
		return
	end
	registration.HoldsMovementLock = wantsLock
	if wantsLock then
		humanoid:SetAttribute(HitboxEngineConstants.RootControlLockedAttribute, true)
	else
		-- Only cleared because this system is the holder. If the engine is mid-swing on this body it
		-- will have set the Attribute itself and will clear it through its own exit path.
		humanoid:SetAttribute(HitboxEngineConstants.RootControlLockedAttribute, nil)
	end
end

-- Whether a guard at `guard` of `max` reads as cracking, given whether it already did. The hysteresis
-- rule of DefenseConstants.GuardCrack in one place, so the tag and the Combat_Feedback stamp
-- (DefenseSystem.IsGuardCracking) can never disagree about the same pool.
local function crackingFor(guard: number, max: number, wasCracking: boolean): boolean
	if max <= 0 then
		return false
	end
	local fraction = guard / max
	if wasCracking then
		return fraction < DefenseConstants.GuardCrack.ExitFraction
	end
	return fraction < DefenseConstants.GuardCrack.EnterFraction
end

-- Publishes the GuardCrack tag for every client to read (the strain pose -- see
-- DefenseConstants.GuardCrack on why a tag). Deduped on PublishedCracking, since Step calls this every
-- frame for every registration and an unchanged replicated write is pure cost -- publishState's own
-- reasoning, applied to the second thing this system publishes.
local function publishGuardCrack(registration: Registration): ()
	local humanoid = registration.Humanoid
	if humanoid.Parent == nil then
		return
	end
	local cracking = crackingFor(registration.Guard:Get(), registration.Guard:GetMax(), registration.PublishedCracking)
	if cracking == registration.PublishedCracking then
		return
	end
	registration.PublishedCracking = cracking
	if cracking then
		humanoid:AddTag(DefenseConstants.GuardCrack.Tag)
	else
		humanoid:RemoveTag(DefenseConstants.GuardCrack.Tag)
	end
end

-- Publishes this combatant's guard, as a fraction of its max, on the GuardFraction Humanoid Attribute so
-- EVERY client can read an opponent's guard. The lock-on marker (Client/Combat/LockOnController.lua) is
-- the reader. The owner still gets exact numbers through syncGuard; this is for everyone else.
--
-- QUANTISED to DefenseConstants.GuardFraction.Steps and deduped, because Step calls this every frame and
-- a regenerating guard would otherwise replicate a fresh float to every client every frame. At 20 steps a
-- full regen is at most 20 writes.
local function publishGuardFraction(registration: Registration): ()
	local humanoid = registration.Humanoid
	if humanoid.Parent == nil then
		return
	end
	local max = registration.Guard:GetMax()
	local steps = DefenseConstants.GuardFraction.Steps
	local fraction = if max > 0 then math.clamp(registration.Guard:Get() / max, 0, 1) else 0
	local step = math.floor(fraction * steps + 0.5)
	if step == registration.PublishedGuardStep then
		return
	end
	registration.PublishedGuardStep = step
	humanoid:SetAttribute(DefenseConstants.GuardFraction.Attribute, step / steps)
end

-- The parry window this combatant's press arms, or nil when none is armed for them.
local function parryWindowFor(registration: Registration): DefenseTypes.ParryWindow?
	-- A weapon whose own parry clip carries no window falls back to the DEFAULT clip's window
	-- rather than to no parry at all. That default is itself explicit (markers, or a
	-- DefenseConstants.RegisteredParryWindows entry), and the boot validation already warned
	-- about the unarmed clip -- so this is "the baseline timing until the animator marks this
	-- clip", not a hidden constant. Without it, authoring a PARRY clip for a weapon silently
	-- removed that weapon's parry.
	return ParryWindows.Get(registration.ParryAnimationId)
		or (if defaultParryAnimationId ~= "" then ParryWindows.Get(defaultParryAnimationId) else nil)
end

-- `verdict` answers one press (see handleSetBlocking); every other push omits it.
local function notifyClient(
	registration: Registration,
	state: DefenseState,
	attackerPosition: Vector3?,
	verdict: DefenseTypes.PressVerdict?
): ()
	local remote = stateChangedRemote
	if not remote then
		return
	end
	local player = registration.Player
	if not player then
		return
	end
	local guard = registration.Guard:Get()
	local guardMax = registration.Guard:GetMax()
	-- Every push carries the pool, so every push counts as the latest sync (see syncGuard).
	registration.SentGuard = guard
	registration.SentGuardMax = guardMax
	registration.GuardSentAt = os.clock()
	local window = parryWindowFor(registration)
	local payload: DefenseTypes.StatePayload = {
		State = state,
		Guard = guard,
		GuardMax = guardMax,
		-- Sent only on a parry, so the client can snap the defender to face their attacker. The snap
		-- is done client-side rather than by writing CFrame from here: the client owns its own
		-- character's physics, so a server rotation write would be fought and then overwritten. Feel
		-- belongs on the client; the decision that a parry happened stays here.
		FaceTowards = attackerPosition,
		-- The client predicts whether its next press arms a parry, so it can play the parry swing-up or
		-- go straight to the guard on the key edge (Client/Defense/DefenseClient.lua). That prediction
		-- needs the window this press would be judged with, and only the server has it: a per-weapon
		-- clip's markers are read here, never on the client. Three numbers on a push that already goes.
		Window = if window then { Open = window.Open, Close = window.Close, RecoveryEnd = window.RecoveryEnd } else nil,
		Press = verdict,
	}
	remote:FireClient(player, payload)
end

-- Keeps the owning client's guard readout true -- see DefenseConstants.Guard.SyncIntervalSeconds. The
-- pool moves where no state transition happens (regeneration every frame, a blocked hit while already
-- Blocking), and those changes used to reach the HUD only when some later transition happened to carry
-- the number. Pushes any meaningful change, rate-limited, and the empty/full end states at once.
local function syncGuard(registration: Registration, now: number): ()
	if not registration.Player then
		return
	end
	local guard = registration.Guard:Get()
	local guardMax = registration.Guard:GetMax()
	local sent = registration.SentGuard
	if sent == guard and registration.SentGuardMax == guardMax then
		return
	end
	local atEnd = guard <= 0 or guard >= guardMax
	if not atEnd then
		local GUARD = DefenseConstants.Guard
		if sent ~= nil and math.abs(guard - sent) < GUARD.SyncMinDelta then
			return
		end
		if now - registration.GuardSentAt < GUARD.SyncIntervalSeconds then
			return
		end
	end
	notifyClient(registration, registration.Machine:GetState(), nil)
end

-- Registry -----------------------------------------------------------------------------------------

-- Registers a combatant. Mirrors HitboxEngine.RegisterCombatant's shape (model, root, humanoid) on
-- purpose -- anything the engine accepts as a fighter, this accepts as a defender, so a bot and a
-- dummy get the same defensive rules a player does with no branching anywhere.
function DefenseSystem.RegisterCombatant(
	model: Model,
	rootPart: BasePart,
	humanoid: Humanoid,
	parryAnimationId: string?
): ()
	if registrations[model] then
		DefenseSystem.UnregisterCombatant(model)
	end

	local registration: Registration = {
		Model = model,
		RootPart = rootPart,
		Humanoid = humanoid,
		Machine = nil :: any,
		Guard = GuardMeter.New(),
		ParryAnimationId = parryAnimationId or defaultParryAnimationId,
		HoldsMovementLock = false,
		PublishedState = nil,
		GuardDeferred = false,
		ReleasedAt = -math.huge,
		PublishedCracking = false,
		PublishedGuardStep = nil,
		RallyPartner = nil,
		RallyCount = 0,
		RallyLapsesAt = 0,
		Player = Players:GetPlayerFromCharacter(model),
		SentGuard = nil,
		SentGuardMax = nil,
		GuardSentAt = -math.huge,
	}
	registration.Machine = DefenseStateMachine.New({
		OnTransition = function(_from: DefenseState, to: DefenseState, _at: number)
			publishState(registration, to)
			notifyClient(registration, to, nil)
			if DefenseConstants.Debug.Enabled and DefenseConstants.Debug.LogTransitions then
				logger:debug("Defense state changed", { model = model.Name, to = to })
			end
		end,
	})

	registrations[model] = registration
	publishState(registration, "Neutral")
	-- The owning client's first push of this life: its guard readout, and the parry window its first press
	-- will be judged with (ParryPrediction), rather than both waiting for the first state change.
	notifyClient(registration, "Neutral", nil)
end

function DefenseSystem.UnregisterCombatant(model: Model): ()
	local registration = registrations[model]
	if not registration then
		return
	end
	-- Released explicitly rather than left to the Humanoid being destroyed: a character that is
	-- unregistered but not destroyed (a spectator handoff, a spec reset) must not be left with this
	-- system's movement lock set on it forever.
	if registration.HoldsMovementLock and registration.Humanoid.Parent ~= nil then
		registration.Humanoid:SetAttribute(HitboxEngineConstants.RootControlLockedAttribute, nil)
	end
	if registration.Humanoid.Parent ~= nil then
		registration.Humanoid:SetAttribute(DefenseConstants.DefenseStateAttribute, nil)
		registration.Humanoid:RemoveTag(DefenseConstants.GuardCrack.Tag)
	end
	registrations[model] = nil
	parryConsumedThisBatch[model] = nil
	batchGuard[model] = nil
end

function DefenseSystem.IsRegistered(model: Model): boolean
	return registrations[model] ~= nil
end

-- The clip every combatant registered without one of their own uses. Nothing arms a parry until this
-- (or a per-combatant id) resolves to a window -- see ParryWindows' fail-closed rule.
function DefenseSystem.SetDefaultParryAnimation(animationId: string): ()
	defaultParryAnimationId = animationId
end

-- Re-points ONE combatant's parry clip, which re-points that combatant's parry WINDOW -- the markers
-- on this id are the window (see Shared/Defense/ParryWindows.lua), so this is a timing change, not a
-- cosmetic one.
--
-- EXISTS FOR THE WEAPON SWAP, and the layering is the reason it is a setter here rather than this
-- System reaching for the answer itself. Which weapon a combatant holds is the ATTACK layer's fact
-- (SwingSequencer's record, published through AttackRequestSystem.OnWeaponChanged), and Defense sits
-- two layers BELOW Attack -- a require in that direction would invert the stack. So the composition
-- root wires the two together: Server/Main.server.lua subscribes to that signal and calls this with
-- WeaponDefenseAnimations.GetParry(weaponId). Same shape as SetDefaultParryAnimation directly above,
-- which Main.server.lua already calls for the same "the boot script knows both, the layer knows one"
-- reason.
--
-- A blank id is a legitimate argument, not an error: it is what a combatant with no parry clip at all
-- resolves to, and it fail-closes exactly as an unregistered combatant does -- the block still works,
-- no window ever opens. Silently ignores a model that is not registered (an unbound character mid-
-- respawn), since RegisterCombatant re-reads the default for the new life anyway.
function DefenseSystem.SetParryAnimation(model: Model, animationId: string): ()
	local registration = registrations[model]
	if not registration then
		return
	end
	registration.ParryAnimationId = animationId
	-- A new clip is a new window: re-sent now, so the client's next press is predicted on this weapon's
	-- timing rather than the last one's.
	notifyClient(registration, registration.Machine:GetState(), nil)
end

-- Input --------------------------------------------------------------------------------------------

-- The block/parry input edge. Exposed as a function as well as being wired to the remote, so a bot
-- can defend through exactly the same path a player does.
-- Whether this body is committed to something a guard may not interrupt: its own swing (any phase the
-- engine is still running -- windup, active or recovery) or a hitstun. Read from the engine directly
-- (the layer below, already a dependency) and from the damage layer's HitstunUntil Attribute (the
-- layer above, which this module may not require -- see that Attribute's own entry).
--
-- WHY THE GUARD WAITS FOR THE SWING, rather than cancelling it. Before this gate a guard could be
-- raised mid-swing and both ran at once: the swing's hitbox stayed live while the body was blocking,
-- and the client played the guard animation over the attack. Committing to a swing has to mean
-- something, and the attack side already refuses the mirror image (a swing while guarding --
-- DefenseStateMachine.CanAttack's "Guarding").
--
-- WHY THE GUARD WAITS FOR THE STUN. DamageConstants.Hitstun's own header promises a stunned combatant
-- "reliably eats at least one more committed attack" -- a promise a guard raised inside the stun
-- would break for every hit after the first, turning every combo into one hit and a block.
local function bodyCommitted(registration: Registration, now: number): boolean
	local combatantId = HitboxEngine.GetCombatantId(registration.Model)
	if combatantId then
		local attackState = HitboxEngine.GetAttackState(combatantId)
		if attackState ~= nil and attackState ~= "Idle" then
			return true
		end
	end
	local stunnedUntil = registration.Humanoid:GetAttribute(Constants.Attributes.HitstunUntil)
	return typeof(stunnedUntil) == "number" and now < stunnedUntil
end

-- The guard press itself, once every gate has passed -- shared by a press that arrives with the body
-- free and by Step raising a press that was held (GuardDeferred).
-- Rally ---------------------------------------------------------------------------------------------

-- The window multiplier for this combatant's next parry press -- see DefenseConstants.Rally. 1 outside
-- a live rally.
local function rallyScale(registration: Registration, now: number): number
	local RALLY = DefenseConstants.Rally
	if registration.RallyCount <= 0 or now >= registration.RallyLapsesAt then
		return 1
	end
	return math.max(RALLY.MinWindowScale, RALLY.WindowScalePerParry ^ registration.RallyCount)
end

local function clearRally(registration: Registration): ()
	registration.RallyPartner = nil
	registration.RallyCount = 0
	registration.RallyLapsesAt = 0
end

-- Ends the rally `model` is in, on both sides. For a clean hit, a backstab or a guard break -- the
-- exchange was lost outright, so the next one starts from the full window.
local function endRally(model: Model): ()
	local registration = registrations[model]
	if not registration then
		return
	end
	local partner = registration.RallyPartner
	clearRally(registration)
	local partnerRegistration = if partner then registrations[partner] else nil
	if partnerRegistration and partnerRegistration.RallyPartner == model then
		clearRally(partnerRegistration)
	end
end

-- One more parry traded between `parrier` and `parried`. Continues their rally when it is still live
-- between exactly these two; anything else starts a fresh one at 1.
local function noteRallyParry(parrier: Model, parried: Model, now: number): ()
	local a = registrations[parrier]
	local b = registrations[parried]
	if not a or not b then
		return
	end
	local continuing = a.RallyPartner == parried and b.RallyPartner == parrier and now < a.RallyLapsesAt
	local count = if continuing then a.RallyCount + 1 else 1
	local lapsesAt = now + DefenseConstants.Rally.LapseSeconds
	-- Either side may have been rallying with someone else a moment ago; that one is over now.
	if not continuing then
		endRally(parrier)
		endRally(parried)
	end
	a.RallyPartner, a.RallyCount, a.RallyLapsesAt = parried, count, lapsesAt
	b.RallyPartner, b.RallyCount, b.RallyLapsesAt = parrier, count, lapsesAt
	debugLog("Rally parry", { parrier = parrier.Name, parried = parried.Name, count = count })
end

-- Converts the held contact an arriving press covers into the parry it would have been, and applies it.
-- Declared here, defined in pass 2 below (it needs applyContact).
local resolveHeldContactsFor: (
	registration: Registration,
	now: number,
	window: DefenseTypes.ParryWindow?,
	scale: number,
	armed: boolean
) -> ()

-- `blockOnly` raises a plain guard with no parry window. It is for a press HELD through a committed
-- body (GuardDeferred, raised by Step): see Step's own note on why that press may block but not parry.
local function pressGuard(registration: Registration, now: number, blockOnly: boolean?): boolean
	local window = if blockOnly then nil else parryWindowFor(registration)
	local scale = rallyScale(registration, now)
	local armed = registration.Machine:Press(now, window, pingSecondsFor(registration.Model), scale)
	-- The press may be the parry -- or, on the ground, the block -- for a contact still in its rewind hold,
	-- judged at the press's REWOUND time rather than now. See resolveHeldContactsFor. Never for a press
	-- Step is raising out of a deferral (`blockOnly`): that press arrived while the body was committed, so
	-- rewinding it from now would judge it as if it had reached a free body.
	if not blockOnly and #heldContacts > 0 then
		resolveHeldContactsFor(registration, now, window, scale, armed)
	end
	return armed
end

-- Returns whether a press armed a parry window -- false for a release, a refused press, a press held for a
-- committed body, and a press that only raised a plain block. handleSetBlocking reports it back to the
-- pressing client; a bot's caller ignores it.
function DefenseSystem.SetBlocking(model: Model, blocking: boolean, now: number): boolean
	local registration = registrations[model]
	if not registration then
		return false
	end
	if blocking then
		-- A committed traversal refuses the guard, on the same rule and through the same predicate
		-- AttackRequestSystem.Throw refuses a swing with -- see Shared/Parkour/ParkourOwnership. Raising
		-- a guard mid-vault would be the cheapest possible way to make every traversal safe, which is
		-- the opposite of what committing to one is supposed to mean.
		--
		-- ONLY THE PRESS. A Release always goes through: refusing one would strand a guard already up
		-- when the traversal started, held open with no input able to lower it -- the machine's own
		-- Press/Release pairing is what keeps the state honest, and a gate that can break the pair is a
		-- worse bug than the one it is closing.
		if ParkourOwnership.OwnsBody(registration.Humanoid) then
			return false
		end
		-- HELD, NOT REFUSED. A player who presses guard a moment before their swing ends -- or while
		-- still reeling -- gets the guard the instant they are free (Step), as long as the key is still
		-- down. Refusing it outright would make the guard feel dropped at exactly the moment it matters.
		--
		-- EXCEPT WHILE AIR-HELD. Every air hit stuns, so deferring the press past the stun would hold an
		-- air-held victim's parry until the combo was already over -- and the parry is their one way out
		-- (docs/design/air-combat-and-evade.md B4). The stun still means what it means everywhere else:
		-- the held guard does nothing (pass 1's AirHeld rule), and only a timed parry counts.
		if bodyCommitted(registration, now) and not isAirHeld(registration.Humanoid) then
			registration.GuardDeferred = true
			return false
		end
		return pressGuard(registration, now)
	end
	registration.GuardDeferred = false
	registration.ReleasedAt = now
	registration.Machine:Release(now)
	return false
end

-- Opens this combatant's evade window (DefenseConstants.Evade), or refuses and says why. Public for
-- the same reason SetBlocking is: a bot evades through exactly the path a player does. For a player it is
-- reached from the composition root (Main.server.lua), which calls this when ParkourSystem accepts an Evade
-- start -- so this system and ParkourSystem never require each other, and the trigger is the evade report
-- the client already sends rather than a new remote.
--
-- BODY GATES HERE, POSTURE GATES ON THE MACHINE (DefenseStateMachine.BeginEvade), the same split as
-- SetBlocking/Press:
--   * Committed to a swing or reeling from a hit -- bodyCommitted, the rule the guard already waits on.
--     No evade-cancelling out of your own swing, and no evading out of a stun: DamageConstants.Hitstun's
--     promise that a stunned combatant eats the next committed attack is exactly as broken by an evade
--     as by a guard.
--   * Grabbed, grabbing, or mounted. A held body is going where the grab sends it, a grabber's hands are
--     full, and a body welded to a vessel station is not evading anywhere.
--
-- A refusal changes nothing, and it does not refuse the GLIDE -- the client's movement is its own. It
-- refuses the evade frames, so an evade the server would not honour is a glide that gets hit. That is the
-- correct failure for a client that skipped its own gates, and an honest client never reaches it: the
-- same conditions are checked locally in States/Evading.CanEnter.
function DefenseSystem.BeginEvade(model: Model, now: number): (boolean, string?)
	local registration = registrations[model]
	if not registration then
		return false, "NotRegistered"
	end
	if bodyCommitted(registration, now) then
		return false, "Committed"
	end
	local humanoid = registration.Humanoid
	if
		humanoid:GetAttribute(Constants.Attributes.Grabbed) == true
		or humanoid:GetAttribute(Constants.Attributes.Grabbing) == true
		or humanoid:GetAttribute(Constants.Attributes.Mounted) == true
	then
		return false, "Restrained"
	end
	-- Held in an air combo: the parry is the one way out, never an evade.
	if isAirHeld(humanoid) then
		return false, "AirHeld"
	end
	-- A realm that forbids the evade (a NoEvade rule, Shared/Domain/DomainRules.lua): read as an Attribute
	-- on the defender, like the air combo's own holds above, never through the realm runtime above this layer.
	if DomainRules.Has(humanoid, "NoEvade") then
		return false, "DomainSealed"
	end
	local ok, reason = registration.Machine:BeginEvade(now, pingSecondsFor(model))
	if ok then
		-- A guard press held for later (SetBlocking's deferral) is dropped along with the raised guard the
		-- machine just released: the player chose to roll instead, and raising the guard the moment the
		-- roll ends would be a posture they never asked for on this press. Only on success -- a refused
		-- evade leaves the body exactly as it was, deferred press included.
		registration.GuardDeferred = false
		registration.ReleasedAt = now
		debugLog("Evade opened", { model = model.Name })
	end
	return ok, reason
end

-- The largest press id accepted. The client counts up from 1 per session; anything outside this is not an
-- id the client could have sent, and a verdict echoing it back would be answering nothing.
local MAX_PRESS_ID = 2 ^ 31

local function handleSetBlocking(player: Player, rawBlocking: unknown, rawPressId: unknown): ()
	if rateLimiter:IsLimited(player) then
		return
	end
	if typeof(rawBlocking) ~= "boolean" then
		return
	end
	-- Optional, and only meaningful on a press: the id the client will match the verdict against. A
	-- malformed one drops the verdict, never the press -- the guard does not depend on it.
	local pressId: number? = nil
	if
		rawBlocking
		and typeof(rawPressId) == "number"
		and rawPressId == math.floor(rawPressId)
		and rawPressId >= 1
		and rawPressId <= MAX_PRESS_ID
	then
		pressId = rawPressId
	end
	local character = player.Character
	if not character then
		return
	end
	-- Same gate, same reasoning, as AttackRequestSystem's own Mounted refusal: a body welded to a blimp
	-- station belongs to the vehicle, and a guard raised from one would be a defence the arm pose is
	-- already overwriting the animation for. Read as an Attribute, not through a BlimpSystem require.
	local humanoid = CharacterUtil.HumanoidOf(character)
	if humanoid and humanoid:GetAttribute(Constants.Attributes.Mounted) == true then
		return
	end
	local armed = DefenseSystem.SetBlocking(character, rawBlocking, os.clock())
	-- THE VERDICT. The client plays the parry swing-up or the plain guard on the key edge from its own
	-- prediction; this is the correction, for the cases the prediction cannot see (a stun it had not heard
	-- about yet, a lockout timed on the server's clock). Sent even when it agrees, so the client never has
	-- to guess whether silence means "confirmed" or "lost".
	local registration = registrations[character]
	if pressId and registration then
		notifyClient(registration, registration.Machine:GetState(), nil, { Id = pressId, Armed = armed })
	end
end

-- Pass 1 -------------------------------------------------------------------------------------------

-- Classifies one contact against the defender's posture AT ITS SAMPLETIME. Applies nothing.
local function onHit(report: HitReport): ()
	local registration = registrations[report.Target]
	if not registration then
		-- An unregistered target has no defence at all, which is a legitimate state (scenery, a
		-- combatant registered with the engine but not here). Reported as Clean so the damage layer
		-- still sees every contact, rather than dropped.
		if #pending < DefenseConstants.MaxPendingContactsPerFrame then
			table.insert(pending, {
				Report = report,
				Attacker = report.Attacker,
				Defender = report.Target,
				BearingDegrees = 0,
				DefenderStateAtContact = "Neutral" :: DefenseState,
				Result = {
					Kind = "Clean" :: DefenseTypes.OutcomeKind,
					Guard = 0,
					GuardDelta = 0,
					ConsumesParry = false,
				},
				SampleTime = report.SampleTime,
			})
		end
		return
	end

	if #pending >= DefenseConstants.MaxPendingContactsPerFrame then
		-- Bounded rather than allowed to make an already-bad frame worse. Same reasoning as
		-- HitboxEngineConstants.MaxActiveSwings.
		return
	end

	-- A PROJECTILE HITS FROM ITS OWN DIRECTION OF TRAVEL, not from wherever its thrower now stands: a shot
	-- that curved round a defender, or a thrower who ran past the shot they fired, must be judged against
	-- the side the shot actually arrived from. The engine states that point (ProjectileContact.
	-- SourcePosition); everything below measures against it exactly as it measures against an attacker.
	local projectile = report.Projectile
	local attackerRoot = CharacterUtil.RootOf(report.Attacker)
	local attackerPosition = if projectile
		then projectile.SourcePosition
		elseif attackerRoot then attackerRoot.Position
		else report.ContactPosition
	local defenderCFrame = registration.RootPart.CFrame
	local bearing = OutcomeResolver.BearingDegrees(defenderCFrame.LookVector, defenderCFrame.Position, attackerPosition)

	local machine = registration.Machine
	local at = report.SampleTime

	-- THE AIR COMBO'S TWO RULES, both read off the defender's own Attributes (see isAirHeld):
	--   * a slam's hard knockdown is intangible -- the contact resolves Evaded, which prices to nothing and
	--     leaves the attacker's swing running, exactly "the defender was not there";
	--   * an AIR-HELD defender's guard does nothing -- a contact that would have been Blocked (or a
	--     Backstab/GuardBroken, both of which exist only because a guard was up) resolves Clean. A timed
	--     parry is the one defence that still counts, and ParryLive below is untouched for it.
	local humanoid = registration.Humanoid
	local intangible = isAirComboIntangible(humanoid)
	local airHeld = not intangible and isAirHeld(humanoid)

	-- A REALM'S TWO DEFENCE RULES, read the same way (Shared/Domain/DomainRules.lua):
	--   * NoParry -- a live window meets this contact as though it were already spent, exactly the
	--     unparryable shot's treatment below: a held key still blocks, a tap does nothing, and the window
	--     is not consumed.
	--   * NoBlock -- a contact that would have been Blocked (or a Backstab/GuardBroken, which exist only
	--     because a guard was up) resolves Clean, the air-held rule. A parry, if the realm allows one, still
	--     counts: that is the realm saying "only a perfect read saves you here".
	local realmNow = DomainRules.ServerNow()
	local realmNoParry = DomainRules.Has(humanoid, "NoParry", realmNow)
	local realmNoBlock = DomainRules.Has(humanoid, "NoBlock", realmNow)

	-- ADVANCED TO THE CONTACT'S OWN TIME BEFORE IT IS QUERIED. Pass 1 runs inside the engine's Step,
	-- which is the frame BEFORE this system's own Step advances anything -- so without this the
	-- machine's live segment still describes whatever it was at the end of the LAST frame, and
	-- StateAt would report a window still open that closed two substeps ago. Advancing a clock is not
	-- applying a contact, so this does not break pass 1's "applies nothing" rule; contacts arrive in
	-- ascending SampleTime, so it is monotonic, and an `at` that predates the last Update is a no-op
	-- because transitions only fire when now >= the time they were due.
	machine:Update(at)
	local result = OutcomeResolver.Resolve({
		DefenderState = machine:StateAt(at),
		BearingDegrees = bearing,
		PowerLevel = report.PowerLevel,
		Guard = batchGuard[report.Target] or registration.Guard:Get(),
		GuardMax = registration.Guard:GetMax(),
		BlockHeld = machine:BlockHeldAt(at),
		ParryLive = machine:IsParryLiveAt(at),
		-- An unparryable shot (ProjectileTypes' CannotParry) meets a live window as though it were already
		-- spent -- which is exactly the resolver's "a held key behind a used parry is a block" rule
		-- (OutcomeResolver.Mitigates). So the shot is blocked, never parried, and the window itself is NOT
		-- spent: ConsumesParry stays false, and the next contact can still be parried.
		ParryConsumed = parryConsumedThisBatch[report.Target] == true or not isParryable(report) or realmNoParry,
		Evading = intangible or machine:IsEvadingAt(at),
	})
	if
		(airHeld or realmNoBlock)
		and (result.Kind == "Blocked" or result.Kind == "Backstab" or result.Kind == "GuardBroken")
	then
		result = {
			Kind = "Clean",
			Guard = batchGuard[report.Target] or registration.Guard:Get(),
			GuardDelta = 0,
			ConsumesParry = false,
		}
	end
	batchGuard[report.Target] = result.Guard

	-- THE CLASH MEASUREMENT (DefenseConstants.Clash), taken here at the contact's own substep, where the
	-- defender's live volume is where it really was. Only a Clean melee hit between two grounded bodies can
	-- clash; OutcomeResolver.ArbitrateClashes decides in pass 2.
	local defenderSwingReaches: boolean? = nil
	if
		DefenseConstants.Clash.Enabled
		and result.Kind == "Clean"
		and projectile == nil
		and not intangible
		and not airHeld
	then
		local defenderId = HitboxEngine.GetCombatantId(report.Target)
		defenderSwingReaches = defenderId ~= nil
			and HitboxEngine.ActiveSwingReaches(defenderId, report.Attacker, DefenseConstants.Clash.ReachMarginStuds)
	end

	if result.ConsumesParry then
		-- Marked in the batch, not on the machine: pass 1 applies nothing, and the machine's own flag
		-- is set in pass 2 alongside every other application.
		parryConsumedThisBatch[report.Target] = true
	end

	table.insert(pending, {
		Report = report,
		Attacker = report.Attacker,
		Defender = report.Target,
		BearingDegrees = bearing,
		DefenderStateAtContact = machine:StateAt(at),
		Result = result,
		SampleTime = at,
		-- Judged here, at the contact's own SampleTime, against the same window the parry itself was just
		-- judged against -- never re-derived in pass 2, where ConsumeParry has already closed it.
		Perfect = result.Kind == "Parried" and machine:IsPerfectParryAt(at),
		DefenderSwingReaches = defenderSwingReaches,
	})
end

-- Pass 2 -------------------------------------------------------------------------------------------

local function emit(outcome: DefenseOutcome): ()
	for _, callback in outcomeCallbacks do
		-- pcall'd because a consumer erroring must not take down the rest of the batch -- an outcome
		-- half-applied across two subscribers is worse than one subscriber missing an outcome.
		local ok, err = pcall(callback, outcome)
		if not ok then
			logger:error("A DefenseSystem.OnResolved consumer errored", { errorMessage = tostring(err) })
		end
	end
end

-- How long a parry staggers the attacker -- longer for a PERFECT parry (DefenseConstants.PerfectParry).
-- The one definition: applyContact staggers with it, and DefenseSystem.ParryStaggerSeconds hands it to the
-- attack layer, which holds a parried attacker's string until exactly this much later.
local function parryStaggerSeconds(perfect: boolean): number
	return if perfect then DefenseConstants.PerfectParry.StaggerSeconds else DefenseConstants.Stagger.DurationSeconds
end

local function applyContact(contact: PendingContact, now: number): ()
	local defenderRegistration = registrations[contact.Defender]
	local kind = contact.Result.Kind

	if defenderRegistration then
		local machine = defenderRegistration.Machine
		local guard = defenderRegistration.Guard

		if contact.Result.ConsumesParry then
			machine:ConsumeParry(contact.SampleTime)
		end

		-- A block is the only thing that suppresses regeneration, and only because it is the only
		-- thing that spends the pool. A parry's restore must not also start a regen delay, or the
		-- reward would partly cancel itself.
		--
		-- APPLIED AS THE DELTA, NOT THE ABSOLUTE pass 1 worked out. The absolute was the pool at
		-- classification time, which is stale by the time a contact out of the rewind hold applies (up
		-- to Parry.RewindMaxSeconds later): writing it back undid any drain or regeneration in between,
		-- so a held Clean hit silently refunded the posture drain of the hit before it. A trade's
		-- rollback (ArbitrateTrades) zeroes its delta, so it composes here too. A break is pinned to
		-- empty whatever regenerated since classification -- it was judged to empty the pool.
		local spendsGuard = kind == "Blocked" or kind == "GuardBroken"
		local applied = if kind == "GuardBroken" then 0 else guard:Get() + contact.Result.GuardDelta
		guard:Set(applied, now, spendsGuard)
		-- The emitted outcome carries the pool as it actually is now, not as pass 1 predicted it.
		contact.Result.Guard = guard:Get()

		if kind == "GuardBroken" then
			machine:BreakGuard(now)
		end
	end

	-- A PARRIED OR EVADED PROJECTILE is answered on the SHOT, through the engine's projectile counterparts
	-- of CancelAttack -- the thrower's swing is not what was parried: it may be long over, or be a
	-- different swing entirely by now, and cancelling it would punish a thrower for whatever they are
	-- doing when their shot arrives. Only a shot authored with the existing parry response
	-- (ProjectileContact.StaggersOwner) goes on to cancel and stagger its thrower below, exactly as a
	-- parried swing does. OutcomeResolver.ArbitrateTrades never makes a projectile contact a Trade.
	local projectile = contact.Report.Projectile
	if projectile then
		if kind == "Parried" then
			HitboxEngine.ParryProjectile(projectile.Id, contact.Defender, contact.SampleTime)
		elseif kind == "Evaded" then
			HitboxEngine.PassProjectile(projectile.Id, contact.Defender, contact.SampleTime)
		end
	end
	local punishesAttacker = projectile == nil or projectile.StaggersOwner

	if (kind == "Parried" or kind == "Trade") and punishesAttacker then
		local attackerId = HitboxEngine.GetCombatantId(contact.Attacker)
		if attackerId then
			-- CANCELLED BEFORE STAGGERED, and the order is load-bearing: the engine clears
			-- RootControlLocked through its own exit path when a swing ends, so staggering first
			-- would have the engine clear the lock this system had just taken. Timed from the
			-- contact's SampleTime rather than the frame-end clock, so the attacker's own machine
			-- records the interruption at the substep it actually happened.
			HitboxEngine.CancelAttack(attackerId, if kind == "Trade" then "Traded" else "Parried", contact.SampleTime)
		end
	end
	-- A CLASH COSTS BOTH SWINGS. A mutual parry's defender was parrying, not swinging, so only a clash
	-- reaches the defender's own swing -- which was out and meeting the attacker's (DefenseConstants.Clash).
	if kind == "Trade" and contact.Clash == true then
		local defenderId = HitboxEngine.GetCombatantId(contact.Defender)
		if defenderId then
			HitboxEngine.CancelAttack(defenderId, "Traded", contact.SampleTime)
		end
	end

	if kind == "Parried" then
		-- A TRADE STAGGERS NOBODY. Both sides read correctly and both lose their swing; punishing
		-- either would make a mutual success into a mutual failure.
		local attackerRegistration = registrations[contact.Attacker]
		if attackerRegistration and punishesAttacker then
			-- A PERFECT parry staggers longer (DefenseConstants.PerfectParry) -- the one gameplay difference
			-- it makes; the rest of its reward is presentation, keyed off Perfect on the outcome below.
			attackerRegistration.Machine:Stagger(now, parryStaggerSeconds(contact.Perfect == true))
		end
		if defenderRegistration then
			-- The facing snap turns the parrier toward where the blow came from -- for a shot, its source.
			notifyClient(
				defenderRegistration,
				defenderRegistration.Machine:GetState(),
				if projectile then projectile.SourcePosition else contact.Report.ContactPosition
			)
		end
		noteRallyParry(contact.Defender, contact.Attacker, now)
	elseif kind == "Clean" or kind == "Backstab" or kind == "GuardBroken" then
		-- A hit that actually got through ends the trade for both sides.
		endRally(contact.Defender)
	end

	emit({
		Kind = kind,
		Report = contact.Report,
		Attacker = contact.Attacker,
		Defender = contact.Defender,
		BearingDegrees = contact.BearingDegrees,
		DefenderStateAtContact = contact.DefenderStateAtContact,
		Guard = contact.Result.Guard,
		GuardDelta = contact.Result.GuardDelta,
		SampleTime = contact.SampleTime,
		Perfect = contact.Perfect == true,
		Clash = if contact.Clash == true then true else nil,
	})
	debugLog("Contact resolved", { kind = kind, defender = contact.Defender.Name, perfect = contact.Perfect })
end

-- How far back an arriving press from this defender is judged: min(round trip, cap), with the air combo's
-- longer cap while air-held (see DefenseConstants.Parry.RewindMaxSeconds on why the two differ). Zero for a
-- bot or a dummy, which has no round trip to rewind.
local function rewindSecondsFor(registration: Registration): number
	local cap = if isAirHeld(registration.Humanoid)
		then AirComboConstants.Parry.RewindMaxSeconds
		else DefenseConstants.Parry.RewindMaxSeconds
	return math.min(pingSecondsFor(registration.Model), cap)
end

-- The moment a press arriving `now` is judged as having been made: its arrival less the rewind, but never
-- before the release that preceded it. The two travelled the same wire in order, so a press rewound past its
-- own release would be claiming the key went down before it came up -- and a guard already up at that moment
-- cannot mint a fresh window anyway (DefenseStateMachine.RewoundParryCovers refuses it).
local function rewoundPressAt(registration: Registration, now: number): number
	return math.max(now - rewindSecondsFor(registration), registration.ReleasedAt)
end

-- How long a resolved contact waits in the rewind hold before it applies, or 0 to apply it now. Only a CLEAN
-- contact that a later press could still turn into a parry or a block is held -- a parry, a trade and an
-- evade are already decided, and holding anything else would only delay a hit no input could have answered:
--   * outside the block arc: a parry or a block from that side does nothing either way;
--   * the key already down at contact: a held guard mints no window, and there is no press left to arrive;
--   * on the ground, a body committed to its own swing or a stun: a press arriving now is deferred and
--     comes up as a plain block later (SetBlocking), never judged against this contact.
-- Also 0 for a bot or a dummy (rewindSecondsFor), which has no round trip.
local function rewindHoldFor(contact: PendingContact, now: number): number
	if contact.Result.Kind ~= "Clean" then
		return 0
	end
	local registration = registrations[contact.Defender]
	if not registration then
		return 0
	end
	if not OutcomeResolver.IsWithinBlockArc(contact.BearingDegrees) then
		return 0
	end
	if registration.Machine:BlockHeldAt(contact.SampleTime) then
		return 0
	end
	if not isAirHeld(registration.Humanoid) and bodyCommitted(registration, now) then
		return 0
	end
	return rewindSecondsFor(registration)
end

-- Takes one held contact out of the hold, re-classified, and applies it now.
local function releaseHeld(held: HeldContact, result: DefenseTypes.ResolveResult, stateThen: DefenseState): ()
	local index = table.find(heldContacts, held)
	if index then
		table.remove(heldContacts, index)
	end
	local contact = held.Contact
	contact.Result = result
	contact.DefenderStateAtContact = stateThen
end

-- Judges this defender's held contacts against a press that has just arrived, as if it had arrived at its
-- rewound time (rewoundPressAt). Runs after the live Press, so the arriving press has already done its
-- ordinary work; this only corrects the contacts that landed while it was in flight.
--
--   1. THE PARRY. An armed press parries the EARLIEST held contact its rewound window covers
--      (DefenseStateMachine.RewoundParryCovers -- the same arming checks, evaluated then). Only one: a parry
--      window stops one attack. The parry applies through applyContact, whose ConsumeParry also spends the
--      live window this press just armed, so one press can never parry twice.
--   2. THE GUARD, ground only. Every other held contact that landed at or after the rewound press is judged
--      against the guard that press would have put up: from the press itself for a plain block, from the
--      rewound window's close for an armed press (the raise time is still the raise time), and -- the
--      OutcomeResolver.Mitigates rule -- straight after the parry for a held key. A contact inside an armed
--      window that nothing parried stays the Clean it was: that is a window which caught the wrong hit, not
--      a guard. Air-held defenders skip this step: their guard does nothing (pass 1's AirHeld rule).
--
-- Both go through the same resolver pass 1 uses, so the guard arithmetic and the arc rules are the ordinary
-- ones, and a resolver that disagrees leaves the contact held as the Clean it was.
resolveHeldContactsFor = function(
	registration: Registration,
	now: number,
	window: DefenseTypes.ParryWindow?,
	scale: number,
	armed: boolean
): ()
	local candidates: { HeldContact } = {}
	for _, held in heldContacts do
		if held.Contact.Defender == registration.Model then
			table.insert(candidates, held)
		end
	end
	if #candidates == 0 then
		return
	end
	table.sort(candidates, function(a: HeldContact, b: HeldContact): boolean
		return a.Contact.SampleTime < b.Contact.SampleTime
	end)

	local machine = registration.Machine
	local pressAt = rewoundPressAt(registration, now)
	local function resolveAs(held: HeldContact, stateThen: DefenseState, parryLive: boolean, parrySpent: boolean)
		return OutcomeResolver.Resolve({
			DefenderState = stateThen,
			BearingDegrees = held.Contact.BearingDegrees,
			PowerLevel = held.Contact.Report.PowerLevel,
			Guard = registration.Guard:Get(),
			GuardMax = registration.Guard:GetMax(),
			BlockHeld = true,
			ParryLive = parryLive,
			ParryConsumed = parrySpent,
			Evading = false,
		})
	end

	-- 1. The parry.
	local parriedAt: number? = nil
	if armed then
		for _, held in candidates do
			-- An unparryable shot is not a candidate for the window; the guard pass below may still block it.
			if not isParryable(held.Contact.Report) then
				continue
			end
			local covers, perfect = machine:RewoundParryCovers(pressAt, held.Contact.SampleTime, window, scale)
			if covers then
				local result = resolveAs(held, "ParryWindow", true, false)
				if result.Kind == "Parried" then
					releaseHeld(held, result, "ParryWindow")
					held.Contact.Perfect = perfect
					parriedAt = held.Contact.SampleTime
					applyContact(held.Contact, now)
					debugLog("Parry judged on the rewind", { defender = registration.Model.Name, perfect = perfect })
				end
				break
			end
		end
	end

	-- 2. The guard.
	if isAirHeld(registration.Humanoid) then
		return
	end
	-- The posture the guard settles into once it is up. A press into a guard break raised nothing.
	local liveState = machine:GetState()
	if liveState == "GuardBroken" then
		return
	end
	local guardState: DefenseState = if liveState == "Staggered" then "Staggered" else "Blocking"
	-- When the rewound press's guard came up: at the rewound window's close if that press would have armed
	-- one, at the press itself if it would only have blocked. Asked at `pressAt`, not taken from the live
	-- press: a press that arms NOW (MinUnguarded or a lockout just ran out) may not have armed THEN, and a
	-- press that did not arm then was a plain block from that moment.
	local guardUpAt = pressAt
	if armed and window and machine:CanArmParryAt(pressAt) then
		guardUpAt = pressAt + window.Open + (window.Close - window.Open) * scale
	end
	for _, held in candidates do
		if table.find(heldContacts, held) == nil then
			continue
		end
		local at = held.Contact.SampleTime
		if at < pressAt then
			continue
		end
		local result: DefenseTypes.ResolveResult
		local stateThen: DefenseState
		if at >= guardUpAt then
			stateThen = guardState
			result = resolveAs(held, stateThen, false, false)
		elseif (parriedAt ~= nil and at >= parriedAt) or not isParryable(held.Contact.Report) then
			-- Behind the parry, or an unparryable shot inside the window: the held key blocks it (pass 1's
			-- CannotParry rule, judged on the rewind).
			stateThen = "ParryWindow"
			result = resolveAs(held, stateThen, false, true)
		else
			continue
		end
		if result.Kind == "Clean" then
			continue
		end
		releaseHeld(held, result, stateThen)
		applyContact(held.Contact, now)
		debugLog("Guard judged on the rewind", { defender = registration.Model.Name, kind = result.Kind })
	end
end

-- The loop -----------------------------------------------------------------------------------------

-- One frame. `now` is the caller's clock and is treated as the END of the frame, matching
-- HitboxEngine.Step's own convention so the two agree about what a frame is.
function DefenseSystem.Step(deltaTime: number, now: number): ()
	-- Machines first: a window that closed during this frame must have closed before the batch is
	-- arbitrated, or a whiff's recovery would be charged a frame late.
	for _, registration in registrations do
		local machine = registration.Machine
		-- A guard held through a swing or a stun comes up the first frame the body is free -- and this
		-- Step runs AFTER HitboxEngine.Step (Main.server.lua's boot order, asserted in Init), so a swing
		-- that ended this frame is already Idle here. A traversal in the meantime keeps it waiting
		-- rather than dropping it, the same "never strand the key" reasoning SetBlocking's release keeps.
		if
			registration.GuardDeferred
			and not bodyCommitted(registration, now)
			and not ParkourOwnership.OwnsBody(registration.Humanoid)
		then
			registration.GuardDeferred = false
			-- A HELD PRESS COMES UP AS A BLOCK, NEVER A PARRY (2026-09-29). This press was made while the body
			-- was committed (a swing, a stun), and it rises the instant the body is free. If it armed a
			-- parry, holding the key through hitstun would parry the next hit of any tight string with no
			-- timing at all. The parry is a read made on a free body, so it takes a fresh press, and the
			-- ordinary MinUnguardedSeconds rule applies to that press like any other.
			pressGuard(registration, now, true)
		end
		machine:Update(now)
		local state = machine:GetState()
		-- Re-asserted every frame while the condition lasts -- see publishState's two-writer note.
		publishState(registration, state)

		-- Guard regenerates only from a posture that is not spending it. Blocking is excluded because
		-- you cannot rebuild a guard you are actively holding up, and Staggered because suppressing
		-- regeneration is one of the three costs that stops "a parried attacker can still block" from
		-- making the punish hollow.
		local regenerates = state ~= "Blocking" and state ~= "Staggered" and not machine:IsBlockHeld()
		registration.Guard:Regenerate(deltaTime, now, regenerates)
		publishGuardCrack(registration)
		publishGuardFraction(registration)
		syncGuard(registration, now)
	end

	-- The rewind holds that have run out apply as the Clean they were. First, so a held contact from an
	-- earlier frame never lands after a newer one.
	if #heldContacts > 0 then
		for index = #heldContacts, 1, -1 do
			local held = heldContacts[index]
			if now >= held.ReleaseAt then
				table.remove(heldContacts, index)
				applyContact(held.Contact, now)
			end
		end
	end

	if #pending == 0 then
		return
	end

	OutcomeResolver.ArbitrateTrades(pending)
	OutcomeResolver.ArbitrateClashes(pending)
	for _, contact in pending do
		local hold = rewindHoldFor(contact, now)
		if hold > 0 then
			table.insert(heldContacts, { Contact = contact, ReleaseAt = now + hold })
		else
			applyContact(contact, now)
		end
	end

	table.clear(pending)
	table.clear(parryConsumedThisBatch)
	table.clear(batchGuard)
end

-- Public queries -----------------------------------------------------------------------------------

-- Whether this combatant may start an attack, and why not when they may not.
--
-- ATTACK GATING IS THIS LAYER'S JOB, not the engine's -- the engine stays ignorant of stagger, which
-- is what keeps it standalone. The input layer consults this before HitboxEngine.RequestAttack.
--
-- Consumed by AttackRequestSystem.Throw (Server/Combat/Attack/AttackRequestSystem.lua) as the first
-- of its three CanAttack-shaped gates -- stagger's no-attack rule is enforced in play.
function DefenseSystem.CanAttack(model: Model): (boolean, string?)
	local registration = registrations[model]
	if not registration then
		return true, nil
	end
	-- A guard key held through a swing or a stun is a guard, even before Step has raised it: the swing
	-- that ends the commitment must not be followed by a fresh one ahead of the guard the player is
	-- still holding the key for.
	if registration.GuardDeferred then
		return false, "Guarding"
	end
	return registration.Machine:CanAttack()
end

-- The earliest moment this layer would have let the body start a swing that is being judged NOW: when its
-- current attack-allowing state began, and never before its last guard release. math.huge while CanAttack
-- refuses, -math.huge for a body this system does not know. For the attack layer's latency refund
-- (AttackConstants.Latency), which may not backdate a swing into a stagger or a raised guard. Conservative
-- on purpose: a body that went Neutral -> Evading -> Neutral reports the second Neutral, not the first.
function DefenseSystem.AttackFreeSince(model: Model, now: number): number
	local registration = registrations[model]
	if not registration then
		return -math.huge
	end
	if registration.GuardDeferred or not registration.Machine:CanAttack() then
		return math.huge
	end
	local enteredAt = now - registration.Machine:GetStateElapsed(now)
	return math.max(enteredAt, registration.ReleasedAt)
end

-- How long a Parried outcome staggers its attacker, from the outcome's own Perfect flag. A pure query on
-- the rule applyContact staggers with, so the attack layer never restates the two stagger lengths. A
-- rally parry out of a stagger can END a stagger early; this is the length it was stamped with.
function DefenseSystem.ParryStaggerSeconds(perfect: boolean): number
	return parryStaggerSeconds(perfect)
end

-- Whether a guard press is being held for this body until it is free of its own swing or a stun -- the
-- press Step will raise the moment it can. The attack layer reads it to cut the tail of that swing's
-- recovery so the guard comes up sooner (AttackConstants.GuardCut).
function DefenseSystem.IsGuardDeferred(model: Model): boolean
	local registration = registrations[model]
	return registration ~= nil and registration.GuardDeferred
end

function DefenseSystem.GetState(model: Model): DefenseState?
	local registration = registrations[model]
	return if registration then registration.Machine:GetState() else nil
end

-- How many parries this combatant has traded in their current rally, and with whom -- 0/nil when not
-- rallying or the rally has lapsed. For the debug readout and the spec; see DefenseConstants.Rally.
function DefenseSystem.GetRally(model: Model, now: number): (number, Model?)
	local registration = registrations[model]
	if not registration or registration.RallyCount <= 0 or now >= registration.RallyLapsesAt then
		return 0, nil
	end
	return registration.RallyCount, registration.RallyPartner
end

function DefenseSystem.GetGuard(model: Model): (number?, number?)
	local registration = registrations[model]
	if not registration then
		return nil, nil
	end
	return registration.Guard:Get(), registration.Guard:GetMax()
end

-- Whether this combatant's guard is cracking RIGHT NOW, by the same hysteresis rule the GuardCrack tag
-- is published under. Read live off the pool rather than off that tag, because the
-- damage layer asks straight after draining it -- inside the frame, before Step has re-published -- and
-- stamps the answer on Combat_Feedback so a block's sparks never race the tag's replication.
function DefenseSystem.IsGuardCracking(model: Model): boolean
	local registration = registrations[model]
	if not registration then
		return false
	end
	return crackingFor(registration.Guard:Get(), registration.Guard:GetMax(), registration.PublishedCracking)
end

-- Drains guard from OUTSIDE a blocked contact, breaking it if the drain empties the pool. Returns
-- (remaining, delta, broke); (nil, nil, false) for an unregistered model.
--
-- WHY THIS EXISTS: GUARD IS ALSO THE POSTURE POOL. Everything above this function only ever moves
-- guard while a player is actively blocking -- spent on a mitigated hit, restored on a parry -- which
-- means on its own it cannot touch a player who never raises a guard at all. The damage layer supplies
-- the other half: a hit that connects with no guard covering it drains the same meter, so turtling and
-- never engaging defence are both answerable with one resource and one HUD number instead of a second
-- parallel posture bar.
--
-- OWNERSHIP STAYS HERE rather than the damage layer reaching into GuardMeter itself. This module owns
-- the pool, the machine, the regeneration rule and what a break DOES; the caller owns only the
-- decision of how much and when. Two writers to one meter is two places for it to be computed
-- differently, which is the exact reasoning GuardMeter's own pure/stateful split already records.
--
-- `blockRegen` is passed true for the same reason a blocked hit passes it: without it, guard would
-- refill between the hits of a combo and the pressure would never accumulate into anything.
function DefenseSystem.DrainGuard(model: Model, amount: number, now: number): (number?, number?, boolean)
	local registration = registrations[model]
	if not registration then
		return nil, nil, false
	end
	if typeof(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return registration.Guard:Get(), 0, false
	end

	local remaining, delta, broke = GuardMeter.ApplyDrain(registration.Guard:Get(), amount)
	registration.Guard:Set(remaining, now, true)
	if broke then
		registration.Machine:BreakGuard(now)
	end

	-- Pushed to the owning client because nothing else would. notifyClient is otherwise only reached
	-- from a state TRANSITION, and an unblocked hit that merely dents the guard is not one -- so
	-- without this the meter would drain invisibly and a player's first sign of the mechanic would be
	-- the break itself. A break does transition, and would double-notify, so it is left to the
	-- transition hook to report.
	if not broke then
		notifyClient(registration, registration.Machine:GetState(), nil)
	end

	return remaining, delta, broke
end

-- This system's sole output. Returns a disconnect function rather than a connection object, matching
-- HitboxEngine.OnHit's own contract so a consumer of both learns one shape.
function DefenseSystem.OnResolved(callback: (DefenseOutcome) -> ()): () -> ()
	table.insert(outcomeCallbacks, callback)
	return function()
		local index = table.find(outcomeCallbacks, callback)
		if index then
			table.remove(outcomeCallbacks, index)
		end
	end
end

-- Lifecycle ----------------------------------------------------------------------------------------

-- Subscribes to the engine's contact signal, and nothing else. Split out of Init for the same reason
-- HitboxEngine keeps Step public and its own Init one line wide: a spec has to be able to drive this
-- system on a synthetic clock, and it cannot do that if the only way to receive contacts is to also
-- start a real Heartbeat that races the spec's own Step calls. Idempotent.
function DefenseSystem.Attach(): ()
	if hitDisconnect then
		return
	end
	hitDisconnect = HitboxEngine.OnHit(onHit)
end

function DefenseSystem.Init(): ()
	if started then
		return
	end
	-- See this file's header: Heartbeat order is a correctness property, not a preference. Asserted
	-- rather than documented, because a comment in Main.server.lua cannot fail a boot.
	assert(
		HitboxEngine.RegisteredCount() >= 0 and HitboxEngine.EngagedCount() >= 0,
		"DefenseSystem.Init() requires HitboxEngine to be available"
	)
	started = true

	local setBlocking = NetworkBridge.CreateRemoteEvent(DefenseConstants.Network.RemoteNames.SetBlocking)
	setBlocking.OnServerEvent:Connect(handleSetBlocking)
	stateChangedRemote = NetworkBridge.CreateRemoteEvent(DefenseConstants.Network.RemoteNames.StateChanged)

	DefenseSystem.Attach()

	-- REGISTERS PLAYER CHARACTERS ITSELF, rather than waiting to be told by whoever registers them
	-- with the hitbox engine. Defence does not depend on the engine's registry -- it needs one of its
	-- own for the machine and the guard pool, and GetCombatantId is consulted only to cancel a
	-- parried swing (and correctly returns nil when the attacker is unknown to the engine). So a
	-- player can block and parry from the moment this ships, months before the attack layer that
	-- registers engine combatants is rebuilt.
	--
	-- Bots and dummies are NOT auto-registered: they have no CharacterAdded to hang off, and whoever
	-- spawns them already knows when they exist. They call RegisterCombatant directly.
	-- Through Shared/PlayerLifecycle.lua, which supplies the per-player character hookup AND the
	-- Init()-time sweep for players who joined before this System booted. The Humanoid arrives already
	-- resolved; the HumanoidRootPart stays this System's own lookup, since RegisterCombatant requires
	-- a root explicitly rather than trusting rig-joint auto-detection.
	PlayerLifecycle.BindAllPlayers({
		Scope = "DefenseSystem",
		OnCharacter = function(_player: Player, character: Model, humanoid: Humanoid)
			local rootPart = CharacterUtil.RootOf(character)
			if not rootPart then
				return
			end
			DefenseSystem.RegisterCombatant(character, rootPart, humanoid)
		end,
		OnCharacterRemoving = function(_player: Player, character: Model)
			DefenseSystem.UnregisterCombatant(character)
		end,
		-- Separate from OnCharacterRemoving above and NOT redundant with it: CharacterRemoving does not
		-- fire for a player who simply leaves the server, so the registration has to be dropped here too.
		OnPlayerRemoving = function(player: Player)
			rateLimiter:Clear(player)
			local character = player.Character
			if character then
				DefenseSystem.UnregisterCombatant(character)
			end
		end,
	})

	-- Connected AFTER HitboxEngine.Init has connected its own, which Main.server.lua guarantees by
	-- calling that first.
	heartbeatTrove:Connect(RunService.Heartbeat, function(deltaTime: number)
		DefenseSystem.Step(deltaTime, os.clock())
	end)

	-- Warms every window this system might arm and warns per missing one, so an unmarked clip is a
	-- startup warning rather than a mid-fight mystery. Spawned rather than awaited: it makes web
	-- calls, and blocking the server boot on a rate-limited endpoint would be worse than the first
	-- few seconds of play having no parry armed.
	--
	-- EVERY WEAPON'S PARRY CLIP, not just the default -- WeaponDefenseAnimations.GetParryIds sweeps
	-- Workspace.Weapons for per-weapon Animations/PARRY overrides and returns them alongside the
	-- baseline. Warming only the baseline (which is all this did before per-weapon clips existed)
	-- would leave a weapon that authors its own parry strictly worse off than one that authors none:
	-- ParryWindows.Get never yields, so an id nobody prefetched returns nil at press time and that
	-- weapon's parry would never once arm, with no error anywhere.
	--
	-- Reads Workspace.Weapons at Init, which Main.server.lua has already populated by running
	-- WeaponRoster.Start() before the combat stack boots. A weapon added to the folder after this
	-- point is not swept -- the same boot-time-snapshot property WeaponRoster itself has.
	-- Registered windows first, so the validation below reports them (and flags any that authored
	-- markers have since shadowed). See DefenseConstants.RegisteredParryWindows for why this exists.
	for animationId, window in DefenseConstants.RegisteredParryWindows do
		ParryWindows.Register(animationId, window.Open, window.Close, window.RecoveryEnd)
	end

	local parryIds = WeaponDefenseAnimations.GetParryIds()
	-- GetParryIds' own baseline is DefenseConstants.ParryAnimationId, which is what Main.server.lua
	-- happens to pass to SetDefaultParryAnimation -- but this System's contract is that the default is
	-- whatever that setter was LAST given, not that constant. Appended (deduplicated) rather than
	-- assumed already present, so a caller that sets a different default still gets it warmed.
	if defaultParryAnimationId ~= "" and table.find(parryIds, defaultParryAnimationId) == nil then
		table.insert(parryIds, defaultParryAnimationId)
	end
	if #parryIds > 0 then
		task.spawn(function()
			ParryWindows.ValidateAll(parryIds)
		end)
	end

	logger:info("DefenseSystem.Init() complete")
end

function DefenseSystem.Shutdown(): ()
	heartbeatTrove:Clean()
	if hitDisconnect then
		hitDisconnect()
		hitDisconnect = nil
	end
	started = false
end

-- Drops every registration and buffered contact. Spec-only, so one case cannot serve another its
-- state -- the same role HitboxEngine.Reset plays for the engine.
function DefenseSystem.Reset(): ()
	-- Dropped so a following Attach() genuinely re-subscribes. HitboxEngine.Reset table.clears its own
	-- callback list, so a spec that resets both would otherwise be left holding a stale non-nil handle
	-- for a subscription that no longer exists -- and Attach's idempotence guard would then refuse to
	-- make a new one, silently delivering no contacts for every case after the first.
	if hitDisconnect then
		hitDisconnect()
		hitDisconnect = nil
	end
	for model in registrations do
		DefenseSystem.UnregisterCombatant(model)
	end
	table.clear(registrations)
	table.clear(pending)
	table.clear(heldContacts)
	table.clear(parryConsumedThisBatch)
	table.clear(batchGuard)
	table.clear(outcomeCallbacks)
	defaultParryAnimationId = ""
	pingResolver = nil
end

-- Replaces the ping lookup, or restores the real one when passed nil. Spec-only, the same role
-- ParryWindows.SetExtractor plays: a dummy has no Player, so without it the rewind hold and the ping
-- refunds could never be exercised. Reset restores the real lookup.
function DefenseSystem.SetPingResolver(resolver: ((model: Model) -> number)?): ()
	pingResolver = resolver
end

return DefenseSystem :: Types.SystemModule & typeof(DefenseSystem)
