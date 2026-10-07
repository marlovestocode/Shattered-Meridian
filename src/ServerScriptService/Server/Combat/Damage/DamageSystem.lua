--!strict
--[[
	DamageSystem.lua

	Owns: the Damage System's public surface -- the DefenseSystem.OnResolved subscription, applying
	health and guard pressure, hitstun and the swing cancellation it causes, the attack gate this layer
	contributes, the feedback remote, and its own Heartbeat.

	    HitboxEngine     where the volume is, who is inside it
	    DefenseSystem    what kind of hit that was
	    DamageSystem     how much it hurts, what it does to you   <- this module

	It is the third layer of that stack and the first consumer of the second's output, subscribing to
	OnResolved exactly the way DefenseSystem subscribes to the engine's OnHit. Neither of the two layers
	below was rewritten to accommodate it: the engine gained one field it was already carrying
	(HitReport.DebugName) and the defence layer gained one function (DrainGuard), and that is the whole
	integration surface.

	ONE PASS, NOT TWO, and the contrast with DefenseSystem is deliberate. That module needs two passes
	for two specific reasons -- SampleTime-accurate window classification, and Trade arbitration across
	a whole batch -- and neither applies here. OnResolved fires from INSIDE DefenseSystem's own
	already-arbitrated pass 2, so by the time a contact reaches this module everything time-sensitive
	about it has been decided. And nothing this layer grants is a resource a naive immediate-apply could
	be exploited into double-granting: damage and guard pressure are costs, not rewards, so applying
	them independently and symmetrically to both contacts of a mutual exchange already produces the fair
	outcome that an arbitration pass would otherwise have to guarantee.

	NO REGISTRY, and this is the one place this module deliberately departs from the shape of the two
	below it. Everything it needs about a combatant is derivable from the Model it is handed -- the
	Humanoid for health, HitboxEngine.GetCombatantId for the cancel, DefenseSystem for the guard -- and
	the only state it keeps of its own (hitstun expiry, combo escalation, the attacker-lunge window
	below) is bounded by a timestamp that expires on its own. So there is nothing to register and
	nothing to leak: a player, a bot and a training dummy all go through one path with nobody having
	to remember to register any of them, which is the same domain-agnostic outcome DefenseSystem's own
	registry achieves by the opposite means.

	ALSO OWNS (DamageConstants.AttackerLunge): a brief forced-forward Humanoid:Move() for the ATTACKER
	on a landed Basic-string (M1) hit -- a felt "the punch connected" cue, distinct from the knockback
	PHYSICS mentioned below (that is the DEFENDER's reaction to a hit; this is the attacker's own body
	on a hit they landed). Never writes WalkSpeed -- see RunSystem.lua's sole-owner rule -- it only
	forces MoveDirection for a few frames at whatever speed is already in effect, the same
	Humanoid:Move() surface touch controls/gamepads/AI already drive a character through.

	HEALTH IS NOT SHADOW-TRACKED. Humanoid.Health stays the single authority, exactly as
	StarterCharacterScripts/Health.server.lua's standing rule requires -- this module calls
	Humanoid:TakeDamage and reads Humanoid.Health, and keeps no parallel pool. Death is therefore
	unchanged too: Humanoid.Died still fires and PlayerDeathSystem still owns confirming it.

	HEARTBEAT ORDER IS LOAD-BEARING, the same way it is for the two layers below. Roblox fires Heartbeat
	connections in connection order, so Init must run after DefenseSystem.Init -- which must itself run
	after HitboxEngine.Init. Main.server.lua calls them in that order and Init asserts it rather than
	trusting the comment.

	ALSO OWNS KNOCKBACK, as "what it does to you". A landed hit whose move authors a MoveKnockback (and no
	Grab -- a grab replaces knockback) is resolved here to ONE world-space launch
	(Shared/Damage/Knockback.LaunchVelocity: away from the attacker, authored magnitudes, clamped by
	DamageConstants.Knockback) and written to DamageResult.Launch BEFORE OnApplied fires, so every
	subscriber sees the launch that was actually applied. Then it is applied by whoever owns the body:
	  * a server-owned body (a bot; an unanchored dummy) -- written here, on the server;
	  * a PLAYER -- handed to that player's own client on the Defender copy of Combat_Feedback, which
	    applies it after its hit-stop freeze (Client/Combat/KnockbackClient.lua). A server write would be
	    silently overwritten by the owner's next frame (the AttackerLunge paragraph above). The player's
	    Humanoid is stamped Attributes.KnockbackUntil so ParkourSystem does not count an honest launch
	    toward its cheater flag, and Server/Combat/Damage/KnockbackAudit.lua checks the client honoured it.
	The client decides nothing about a knock but WHEN inside its own frame to write it.

	READS A REALM'S RULES (2026-09-30), through the Attribute seam and nothing else (Shared/Domain/
	DomainRules.lua -- this layer never requires the realm runtime, which sits above it). A contact's damage
	is scaled by its attacker's DamageDealt and its defender's DamageTaken rule, its guard drain by the
	defender's GuardDamageTaken, its hitstun by the defender's HitstunTaken -- all 1 for a body no realm
	governs. A contact a REALM delivered (ProjectileContact.DomainId) is priced flat, like an M1, and does
	not advance its owner's combo: it is the realm striking, not a link in the owner's string.

	READS CULTIVATION POWER (2026-10-06), the same way: the tier gap between attacker and defender
	(Shared/Progression/CombatPower.lua, published by TierSystem as an Attribute) scales damage and guard
	drain, never hitstun. Off behind CombatPowerConstants.Enabled; exactly 1 between two bodies of one tier.

	Does not own: contact detection (HitboxEngine), what kind of hit something was (DefenseSystem), the
	guard pool itself (DefenseSystem.DrainGuard -- this decides how much, that owns the meter), per-move
	damage or knockback numbers (the Move Editor's moves, via AttackCatalog), air-combo treatment
	(AirComboSystem), or deciding when anyone throws an attack (the attack layer).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AirComboAttributes = require(ReplicatedStorage.Shared.AirCombo.AirComboAttributes)
local AirComboMoves = require(ReplicatedStorage.Shared.AirCombo.AirComboMoves)
local AmortizedReclaim = require(ReplicatedStorage.Shared.AmortizedReclaim)
local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)
local CallbackList = require(ReplicatedStorage.Shared.CallbackList)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local CombatPower = require(ReplicatedStorage.Shared.Progression.CombatPower)
local DamageConstants = require(ReplicatedStorage.Shared.Damage.DamageConstants)
local DamageTypes = require(ReplicatedStorage.Shared.Damage.DamageTypes)
local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local DefenseTypes = require(ReplicatedStorage.Shared.Defense.DefenseTypes)
local DomainRules = require(ReplicatedStorage.Shared.Domain.DomainRules)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local Knockback = require(ReplicatedStorage.Shared.Damage.Knockback)
local Logger = require(ReplicatedStorage.Shared.Logger)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Trove = require(ReplicatedStorage.Shared.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local ComboEscalation = require(script.Parent.ComboEscalation)
local DamageResolver = require(script.Parent.DamageResolver)
local AttackCatalog = require(script.Parent.Parent.AttackCatalog)
local DefenseSystem = require(script.Parent.Parent.Defense.DefenseSystem)
local HitboxEngine = require(script.Parent.Parent.HitboxEngine.HitboxEngine)

type DefenseOutcome = DefenseTypes.DefenseOutcome
type DamageResult = DamageTypes.DamageResult
type HitReport = HitboxTypes.HitReport
type CombatFeedback = DamageTypes.CombatFeedback

local logger = Logger.scope("DamageSystem")

local DamageSystem = {}

-- When each combatant's hitstun ends. Absent means none. Reclaimed by expiry rather than by
-- unregistration -- see this file's header on why there is no registry.
local hitstunUntil: { [Model]: number } = {}

-- Round-robin reclaim cursor for hitstunUntil -- see Step below, and Shared/AmortizedReclaim.lua for
-- why lungeUntil directly beneath it deliberately does NOT get one.
local hitstunReclaim = AmortizedReclaim.New()

-- When each attacker's post-M1-hit forced-forward window ends. Same "reclaimed by expiry, no
-- registry" shape as hitstunUntil above -- see this file's header's AttackerLunge paragraph.
local lungeUntil: { [Model]: number } = {}

-- OnApplied's subscribers (Shared/CallbackList.lua: pcall'd per consumer, safe to disconnect mid-dispatch).
local appliedListeners: CallbackList.CallbackList<DefenseOutcome, DamageResult> =
	CallbackList.New(logger, "DamageSystem.OnApplied")

-- THE AIR COMBO'S ONE SEAM INTO THIS LAYER (Server/Combat/AirCombo/AirComboSystem.lua, which sits ABOVE this
-- one as a sibling of the attack layer and so is never required from here). One slot, set by that System's
-- Attach: handed each contact's resolved damage before anything reads it, it returns the damage to apply
-- (air hits scale down, finishers scale up -- AirComboConstants.Damage) and an optional presentation tag
-- for the feedback payload. Nil means no air combo is booted, and every contact prices exactly as before.
--
-- A SLOT RATHER THAN AN OnApplied SUBSCRIBER REWRITING result.Damage, deliberately: OnApplied's consumers
-- (kill credit among them) must all read the one damage that is actually dealt, and a subscriber that
-- mutated it would make that depend on subscription order.
export type AirComboHook = (outcome: DefenseOutcome, moveId: string, damage: number) -> (number, string?)
local airComboHook: AirComboHook? = nil

local started = false
local heartbeatTrove = Trove.New()
local resolvedDisconnect: (() -> ())? = nil
local feedbackRemote: RemoteEvent? = nil

-- Helpers ------------------------------------------------------------------------------------------

local function debugLog(message: string, data: { [string]: any }?): ()
	if DamageConstants.Debug.Enabled and DamageConstants.Debug.LogApplied then
		logger:debug(message, data)
	end
end

-- Whether `moveId` is a weapon's Basic (M1) string hit -- gates DamageConstants.AttackerLunge.
-- LIVE MoveIds never match the hand-authored DebugName fields on CombatConstants.Weapons[...].
-- Stages.Basic ("Basic1", "Dagger1", ...); every attack actually thrown resolves through
-- DefaultMoveRegistry's synthetic scheme instead. Restated here rather than shared, the same
-- "coupling is to the naming convention, not to a shared function" reasoning Shared/Attack/
-- AttackWindows.lua's MarkerNameFor documents for its own identical pattern. A custom Move-Editor
-- move can never match this shape (its MoveId is an author-assigned slug), so this correctly
-- excludes those too -- Heavy and Finisher get no forward nudge, same as before this existed.
local function isBasicMoveId(moveId: string): boolean
	return string.match(moveId, "^default:%a+:Basic:%d+$") ~= nil
end

-- Tells one participant what just happened. Silently does nothing for a bot or a dummy, which have no
-- player to tell -- the same "not every combatant is a Player" tolerance every other module in this
-- stack keeps.
local function sendFeedback(model: Model, payload: CombatFeedback): ()
	local remote = feedbackRemote
	if not remote then
		return
	end
	local player = Players:GetPlayerFromCharacter(model)
	if not player then
		return
	end
	remote:FireClient(player, payload)
end

-- Application --------------------------------------------------------------------------------------

-- Cuts short the swing of whoever just got hit.
--
-- THIS IS WHAT MAKES A COUNTER-HIT A REAL ANSWER. Before it, nothing cancelled a swing except a parry,
-- and only the attacker's -- so a player struck mid-combo kept swinging and a well-timed interception
-- was only a parallel damage race. Now landing a hit is itself counterplay: no block, no parry, just
-- timing and spacing.
--
-- It reuses the exact call DefenseSystem already makes for a parried attacker, for a new reason, and
-- times it from the contact's own SampleTime rather than the frame clock so the interrupted machine
-- records the moment it actually happened. Idempotent: AttackStateMachine.Interrupt on an already-Idle
-- machine is a documented no-op, so a combatant hit twice in one batch by two different attackers is
-- cancelled at most meaningfully once.
local function cancelSwingOf(model: Model, at: number): ()
	local combatantId = HitboxEngine.GetCombatantId(model)
	if not combatantId then
		return
	end
	HitboxEngine.CancelAttack(combatantId, "Hitstun", at)
end

-- The launch this hit gives the defender, or nil. See this file's header, KNOCKBACK. Resolved from the
-- two PrimaryParts for the same reason the lunge loop below uses PrimaryPart rather than rig internals.
local function launchFor(outcome: DefenseOutcome, result: DamageResult): Vector3?
	local authored = result.Knockback
	if not DamageConstants.Knockback.Enabled or authored == nil or result.Grab ~= nil then
		return nil
	end
	-- A launcher's launch is the AIR COMBO's (AirComboSystem takes the body server-side and springs it to a
	-- hover), not a knockback -- the same "instead of ordinary knockback" rule a grab gets above. Handing
	-- the victim's client a launch as well would put two owners on one body for the first frames of the rise.
	if authored.StartsAirCombo == true then
		return nil
	end
	local defenderRoot = outcome.Defender.PrimaryPart
	if defenderRoot == nil then
		return nil
	end
	-- A PROJECTILE KNOCKS ALONG ITS FLIGHT, away from where it came from -- not away from a thrower who may
	-- be anywhere by now. It is also the one case where a hit on your own body launches you: a shot
	-- authored CanHitOwner that comes back is still a shot.
	local projectile = outcome.Report.Projectile
	if projectile then
		return Knockback.LaunchVelocity(
			projectile.SourcePosition,
			defenderRoot.Position,
			projectile.Direction,
			authored
		)
	end
	if outcome.Defender == outcome.Attacker then
		return nil
	end
	local attackerRoot = outcome.Attacker.PrimaryPart
	if attackerRoot == nil then
		return nil
	end
	return Knockback.LaunchVelocity(
		attackerRoot.Position,
		defenderRoot.Position,
		attackerRoot.CFrame.LookVector,
		authored
	)
end

-- Applies `launch` to the defender, by whichever machine owns the body. Returns the defending Player
-- when it is one, so the caller can put the launch on that player's feedback.
local function applyLaunch(defender: Model, launch: Vector3, at: number): Player?
	local player = Players:GetPlayerFromCharacter(defender)
	if player then
		local humanoid = CharacterUtil.HumanoidOf(defender)
		if humanoid then
			humanoid:SetAttribute(
				AttributeConstants.KnockbackUntil,
				at + DamageConstants.Knockback.MovementAllowanceSeconds
			)
		end
		return player
	end
	-- Server-owned: a bot, or a dummy that is not anchored (DebugDummySystem anchors its dummies, which
	-- correctly leaves them standing -- an anchored part has no velocity to set).
	local root = defender.PrimaryPart
	if root and not root.Anchored then
		root.AssemblyLinearVelocity = launch
	end
	return nil
end

-- Publishes a hitstun on the victim's Humanoid, as two deadlines -- the Attribute seams two systems this
-- layer must not require read from:
--   * AttributeConstants.CombatBusyUntil -- the same deadline AttackRequestSystem writes for a swing,
--     which Server/Systems/RunSystem.lua reads as "a combat action is committing this body": the victim
--     moves at walking pace until it passes (holding their gear -- see RunSystem's header).
--   * AttributeConstants.HitstunUntil -- the stun alone, which Server/Combat/Defense/DefenseSystem.lua
--     reads to hold a guard press until the stun ends (see that Attribute's own entry for why it is not
--     folded into the first).
--
-- math.max against whatever is there, never a bare write: being hit mid-swing must not SHORTEN the
-- attacker-side deadline the swing already set, and a second hit must not shorten the first's stun.
-- Both are on this layer's own clock (os.clock, the one Step runs on), which both readers compare
-- against.
local function extendDeadline(humanoid: Humanoid, attribute: string, until_: number): ()
	local existing = humanoid:GetAttribute(attribute)
	local current = if typeof(existing) == "number" then existing else 0
	if until_ > current then
		humanoid:SetAttribute(attribute, until_)
	end
end

-- THE STUN PARRY'S EXIT (DefenseConstants.StunParry). A defender who parries their way out of a hitstun is free
-- the moment the parry lands, not when the stun would have run out: they won the exchange, and making them
-- stand there while the attacker sits in the stagger would turn the punish into a wait. Brings both deadlines
-- down to `at` -- but CombatBusyUntil only when the stun is what was holding it, since that Attribute is also
-- the attack layer's swing deadline.
local function endHitstunOf(defender: Model, at: number): ()
	local stunnedUntil = hitstunUntil[defender]
	if stunnedUntil == nil or stunnedUntil <= at then
		return
	end
	hitstunUntil[defender] = at
	local humanoid = CharacterUtil.HumanoidOf(defender)
	if humanoid == nil then
		return
	end
	humanoid:SetAttribute(AttributeConstants.HitstunUntil, at)
	local busy = humanoid:GetAttribute(AttributeConstants.CombatBusyUntil)
	if typeof(busy) == "number" and busy > at and busy <= stunnedUntil + 1e-6 then
		humanoid:SetAttribute(AttributeConstants.CombatBusyUntil, at)
	end
end

local function publishHitstunOf(defender: Model, until_: number): ()
	local humanoid = CharacterUtil.HumanoidOf(defender)
	if humanoid == nil then
		return
	end
	extendDeadline(humanoid, AttributeConstants.CombatBusyUntil, until_)
	extendDeadline(humanoid, AttributeConstants.HitstunUntil, until_)
end

-- The spacing pushes for one contact (DamageConstants.Spacing): what the defender and the attacker are each
-- pushed by, either of which may be nil. `launch` is the authored knockback already resolved for this hit;
-- a hit that launched gets no hit push on top.
local function spacingFor(
	outcome: DefenseOutcome,
	moveId: string,
	result: DamageResult,
	launch: Vector3?
): (Vector3?, Vector3?)
	local spacing = DamageConstants.Spacing
	if not spacing.Enabled or outcome.Defender == outcome.Attacker or result.Grab ~= nil then
		return nil, nil
	end
	-- Spacing is the melee exchange's footwork -- the defender eased off, the attacker following in. A
	-- shot's thrower is not in reach to step anywhere, and its target's reaction is the move's knockback.
	if HitboxTypes.SourceOf(outcome.Report) ~= "Melee" then
		return nil, nil
	end
	if AirComboMoves.RoleOf(moveId) ~= nil then
		return nil, nil
	end
	local defenderHumanoid = CharacterUtil.HumanoidOf(outcome.Defender)
	local attackerHumanoid = CharacterUtil.HumanoidOf(outcome.Attacker)
	if defenderHumanoid == nil or attackerHumanoid == nil then
		return nil, nil
	end
	if AirComboAttributes.IsParticipant(defenderHumanoid) or AirComboAttributes.IsParticipant(attackerHumanoid) then
		return nil, nil
	end
	local attackerRoot = outcome.Attacker.PrimaryPart
	local defenderRoot = outcome.Defender.PrimaryPart
	if attackerRoot == nil or defenderRoot == nil then
		return nil, nil
	end
	local between = defenderRoot.Position - attackerRoot.Position
	local flat = Vector3.new(between.X, 0, between.Z)
	if flat.Magnitude <= 1e-3 then
		local look = attackerRoot.CFrame.LookVector
		flat = Vector3.new(look.X, 0, look.Z)
	end
	if flat.Magnitude <= 1e-3 then
		return nil, nil
	end
	local direction = flat.Unit
	-- Studs covered by a linear decay over the client's hold: speed = 2 * distance / hold.
	local hold = DamageConstants.Knockback.HoldSeconds
	local function speedFor(studs: number): number
		return if hold > 0 then 2 * math.max(studs, 0) / hold else 0
	end

	local kind = outcome.Kind
	if kind == "Clean" or kind == "Backstab" or kind == "GuardBroken" then
		if launch ~= nil then
			return nil, nil
		end
		local defenderPush = direction * speedFor(spacing.Hit.DefenderStuds)
		-- A SERVER-OWNED attacker already steps in on a landed M1 (DamageConstants.AttackerLunge), so the
		-- follow is only for a player, whose own client moves them.
		local attackerPush = if Players:GetPlayerFromCharacter(outcome.Attacker) ~= nil
			then direction * speedFor(spacing.Hit.AttackerFollowStuds)
			else nil
		return defenderPush, attackerPush
	elseif kind == "Blocked" then
		return direction * speedFor(spacing.Blocked.DefenderStuds), -direction * speedFor(spacing.Blocked.AttackerStuds)
	elseif kind == "Trade" then
		-- Two swings met and neither won: an even shove apart (DamageConstants.Spacing.Clash).
		local speed = speedFor(spacing.Clash.Studs)
		return direction * speed, -direction * speed
	end
	return nil, nil
end

local function applyOutcome(outcome: DefenseOutcome): ()
	local entry = AttackCatalog.Get(outcome.Report.DebugName)
	if not entry then
		-- Nothing priceable. Reported rather than silently dealing zero, because "hits land but nobody
		-- takes damage" is otherwise a mystery with no log line anywhere: the engine is working, the
		-- defence layer is working, and only the catalogue lookup failed.
		if DamageConstants.Debug.Enabled and DamageConstants.Debug.LogCatalogMisses then
			logger:debug("Resolved a contact for an attack with no catalogue entry", {
				debugName = outcome.Report.DebugName,
			})
		end
		return
	end

	local at = outcome.SampleTime
	local projectile = outcome.Report.Projectile
	-- A realm's strike or volley (see this file's header): flat-priced, and not a link in the owner's string.
	local fromRealm = HitboxTypes.SourceOf(outcome.Report) == "Realm"

	-- ADVANCED BEFORE RESOLVING, not after, so the stage handed to the resolver is the one this hit
	-- counts as. Resolving first and advancing afterwards would scale every hit by the stage of the one
	-- before it -- the first two hits of every string would both deal flat authored damage, which is
	-- invisible in play right up until someone measures a combo.
	local stage
	if DamageResolver.AdvancesCombo(outcome.Kind) and not fromRealm then
		stage = ComboEscalation.Advance(outcome.Attacker, at)
	else
		stage = ComboEscalation.GetStage(outcome.Attacker, at)
	end

	-- M1 (Basic weapon-string) hits are priced at flat authored damage every time, never scaled by the
	-- string's own escalation -- see DamageConstants.Combo.DamageMultiplierPerStage's own header for why
	-- that multiplier exists for everything else. `stage` above still tracks the real combo depth (feedback/
	-- Finisher-eligibility/UI all need the true number), so only the value fed into the resolver is pinned;
	-- pin to 1 rather than skip Resolve entirely so Basic keeps the exact same Clean/Blocked/Backstab/
	-- GuardBroken pricing rules as everything else, just at ComboMultiplier(1) == 1.
	-- Every air hit and finisher is flat-priced the same way (AirComboMoves.IsFlatPriced): the air combo
	-- scales them itself, and ComboEscalation's multiplier on top would make the two scalings stack.
	local pricingStage = if fromRealm
			or isBasicMoveId(entry.MoveId)
			or AirComboMoves.IsFlatPriced(entry.MoveId)
		then 1
		else stage
	local result = DamageResolver.Resolve(outcome.Kind, outcome.DefenderStateAtContact, entry.Profile, pricingStage)

	-- A shot a parry reflected hits as hard as its ReflectedDamageMultiplier says -- the engine carries the
	-- product of every one it has picked up (ProjectileContact.DamageScale), this applies it, to health and
	-- posture alike, before anything reads the result. 1 for every shot nobody turned, and every swing. A
	-- contested realm's strike arrives already scaled the same way (DomainEffects hands it a start scale).
	--
	-- A REALM'S RULES, read off the two bodies (this file's header). One server-clock read for all four, and
	-- every one is exactly 1 for a body no realm governs, so an ordinary fight multiplies by nothing. The
	-- arithmetic itself is DamageResolver.ApplyScales'; this only reads the inputs.
	local realmNow = DomainRules.ServerNow()
	--
	-- CULTIVATION POWER: the tier gap between the two (Shared/Progression/CombatPower.lua). Exactly 1 while
	-- CombatPowerConstants.Enabled is off, and between two bodies of one tier.
	local attackerHumanoid = CharacterUtil.HumanoidOf(outcome.Attacker)
	local defenderHumanoid = CharacterUtil.HumanoidOf(outcome.Defender)
	local powerDamage, powerGuard = CombatPower.Scales(outcome.Attacker, outcome.Defender)
	DamageResolver.ApplyScales(result, {
		Shot = if projectile then projectile.DamageScale else nil,
		PowerDamage = powerDamage,
		PowerGuard = powerGuard,
		DamageDealt = DomainRules.Scale(attackerHumanoid, "DamageDealt", realmNow),
		DamageTaken = DomainRules.Scale(defenderHumanoid, "DamageTaken", realmNow),
		GuardDamageTaken = DomainRules.Scale(defenderHumanoid, "GuardDamageTaken", realmNow),
		HitstunTaken = DomainRules.Scale(defenderHumanoid, "HitstunTaken", realmNow),
	})

	-- The air combo's scaling and presentation tag, before any reader sees the result (see airComboHook).
	local airComboTag: string? = nil
	local hook = airComboHook
	if hook then
		local ok, scaled, tag = pcall(hook, outcome, entry.MoveId, result.Damage)
		if ok then
			if typeof(scaled) == "number" and scaled == scaled and scaled >= 0 then
				result.Damage = scaled
			end
			airComboTag = if typeof(tag) == "string" then tag else nil
		else
			logger:error("The air combo damage hook errored", { errorMessage = tostring(scaled) })
		end
	end

	if result.GuardDrain > 0 then
		DefenseSystem.DrainGuard(outcome.Defender, result.GuardDrain, at)
	end

	if result.HitstunSeconds > 0 then
		DamageSystem.ExtendHitstun(outcome.Defender, at + result.HitstunSeconds, at)
	end

	-- A parry out of a ground stun frees the parrier on the spot (endHitstunOf). The air combo releases its own
	-- held victim on a parry and owns that body's deadlines, so it is left alone here.
	if
		outcome.Kind == "Parried"
		and DefenseConstants.StunParry.Enabled
		and not (defenderHumanoid ~= nil and AirComboAttributes.IsParticipant(defenderHumanoid))
	then
		endHitstunOf(outcome.Defender, at)
	end

	-- A landed M1 (Basic weapon-string) hit gives the ATTACKER a brief forced-forward nudge, driven
	-- from Step below -- see DamageConstants.AttackerLunge's own comment. Parried and Evaded are excluded
	-- because nothing of the attacker's own swing actually connected, and Trade because it pushes the two
	-- apart; every other resolved kind (Clean, Blocked, Backstab, GuardBroken) still counts as the swing
	-- having landed on something.
	--
	-- SERVER-OWNED ATTACKERS ONLY (bots, dummies). A player's character is network-owned by their own
	-- client, and Humanoid:Move from the server on a body it does not simulate is silently inert -- so
	-- for players this was a per-frame call in Step below that moved nothing, ever. Skipped for them
	-- rather than kept running for no effect; a player-side nudge would belong on their own client, the
	-- same way Client/Combat/SwingLunge.lua's step does.
	if
		DamageConstants.AttackerLunge.Enabled
		and outcome.Kind ~= "Parried"
		and outcome.Kind ~= "Evaded"
		-- A trade shoves both apart (Spacing.Clash); stepping the attacker in would undo it.
		and outcome.Kind ~= "Trade"
		and isBasicMoveId(entry.MoveId)
		and Players:GetPlayerFromCharacter(outcome.Attacker) == nil
	then
		lungeUntil[outcome.Attacker] = at + DamageConstants.AttackerLunge.DurationSeconds
	end

	-- Resolved before OnApplied so every subscriber reads it (DamageResult.Launch's own header).
	result.Launch = launchFor(outcome, result)

	-- FIRED BEFORE THE HEALTH WRITE, and the ordering is the whole point rather than an accident.
	-- Humanoid:TakeDamage raises Humanoid.Died synchronously when the blow is lethal, so a subscriber
	-- notified afterwards would always be told who dealt the killing hit strictly AFTER
	-- PlayerDeathSystem had already fired the death with no killer attributed. Announcing the intent
	-- first is what leaves kill attribution a pure follow-up in that module rather than a restructuring
	-- of this one. Nothing here attributes a kill today -- see this file's header on what it does not
	-- own -- but nothing here forecloses it either.
	-- Each consumer pcall'd (CallbackList): one subscriber erroring must not abort the rest, and above all
	-- must not unwind out of the Heartbeat.
	appliedListeners:Fire(outcome, result)

	if result.Damage > 0 then
		local humanoid = CharacterUtil.LiveHumanoidOf(outcome.Defender)
		if humanoid then
			humanoid:TakeDamage(result.Damage)
		end
	end

	local launch = result.Launch
	local launchedPlayer: Player? = if launch then applyLaunch(outcome.Defender, launch, os.clock()) else nil

	-- The spacing pushes (DamageConstants.Spacing). Applied through applyLaunch, the same owner split an
	-- authored knockback uses, and handed to each player's own client on their feedback as Push. Kept OFF
	-- result.Launch on purpose: Launch is what the knockback audit and the environment reactions read, and
	-- a spacing nudge is neither of those.
	local defenderPush, attackerPush = spacingFor(outcome, entry.MoveId, result, launch)
	local pushedDefender: Player? = if defenderPush
		then applyLaunch(outcome.Defender, defenderPush, os.clock())
		else nil
	local pushedAttacker: Player? = if attackerPush
		then applyLaunch(outcome.Attacker, attackerPush, os.clock())
		else nil

	local feedback: CombatFeedback = {
		Kind = outcome.Kind,
		Role = "Attacker",
		Attacker = outcome.Attacker,
		Defender = outcome.Defender,
		Damage = result.Damage,
		GuardDrain = result.GuardDrain,
		ComboStage = stage,
		MoveId = entry.MoveId,
		ContactPosition = outcome.Report.ContactPosition,
		-- Read AFTER the drain above, so a block that just pushed the guard under the line already
		-- throws the cracking sparks. Only meaningful on a Blocked contact; sent as nil otherwise so the
		-- common case costs nothing on the wire.
		GuardCracking = if outcome.Kind == "Blocked" and DefenseSystem.IsGuardCracking(outcome.Defender)
			then true
			else nil,
		Perfect = if outcome.Perfect then true else nil,
		AirCombo = airComboTag,
		-- The string-ender beat (DamageTypes.CombatFeedback.StringEnd): only on a hit that really landed.
		StringEnd = if DamageResolver.AdvancesCombo(outcome.Kind) and AttackCatalog.IsStringEnder(entry.MoveId)
			then true
			else nil,
		Push = if pushedAttacker then attackerPush else nil,
	}
	sendFeedback(outcome.Attacker, feedback)
	if outcome.Defender ~= outcome.Attacker then
		local defenderFeedback = table.clone(feedback)
		defenderFeedback.Role = "Defender"
		-- Only a player's own client applies a launch; a server-owned body already has it.
		defenderFeedback.Knockback = if launchedPlayer then launch else nil
		defenderFeedback.Push = if pushedDefender then defenderPush else nil
		-- The stun STILL TO RUN as this leaves (DamageSystem.StunRemaining), not the contact's authored length.
		defenderFeedback.HitstunSeconds = if result.HitstunSeconds > 0
			then DamageSystem.StunRemaining(outcome.Defender, os.clock())
			else nil
		sendFeedback(outcome.Defender, defenderFeedback)
	end

	debugLog("Damage applied", {
		kind = outcome.Kind,
		moveId = entry.MoveId,
		damage = result.Damage,
		guardDrain = result.GuardDrain,
		stage = stage,
	})
end

-- The loop -----------------------------------------------------------------------------------------

-- One frame. `now` is the caller's clock, matching HitboxEngine.Step and DefenseSystem.Step's own
-- convention so all three agree about what a frame is.
--
-- Outcomes themselves are applied the moment they resolve, from inside DefenseSystem's own pass 2
-- (see this file's header on why one pass is enough) -- most of what happens here is reclaiming
-- state whose timestamps have passed, which is what lets hitstunUntil/ComboEscalation stay
-- registry-free. The one exception is the attacker-lunge loop below: DamageConstants.AttackerLunge
-- needs a few consecutive FRAMES of Humanoid:Move(), not a single instantaneous write, so it rides
-- this System's already-connected Heartbeat rather than opening a second one.
function DamageSystem.Step(_deltaTime: number, now: number): ()
	-- AMORTISED, and no longer an expiry sweep. Every reader of hitstunUntil (CanAttack,
	-- IsHitstunned) already compares the stored timestamp against its own `now`, so an entry that has
	-- passed its expiry but has not yet been dropped is invisible from outside -- which means the
	-- eviction was never doing anything a reader could observe, and a full walk of the table every
	-- frame was paying for it. What the sweep IS still for is stopping the outer table from holding a
	-- reference to a destroyed character forever, and that is what the cursor does, a fixed handful of
	-- keys per frame regardless of how many combatants exist. The table's size is unchanged by the
	-- switch: it was already bounded by live-combatant count, since a fresh hit overwrites the
	-- existing entry rather than adding one.
	hitstunReclaim:Step(hitstunUntil)
	-- Left as a full walk deliberately: unlike hitstunUntil, this one's `now` is part of its own
	-- public contract (Sweep(now)), and its table is bounded by live-combatant count either way.
	ComboEscalation.Sweep(now)

	-- DELIBERATELY A FULL WALK, unlike hitstunUntil above. This loop does per-entry WORK -- it calls
	-- Humanoid:Move() on every live entry, every frame -- so an amortised cursor here would not be a
	-- delayed cleanup, it would be a dropped frame of the lunge. It is also naturally tiny: only
	-- combatants inside their post-hit forward window are ever in it. See
	-- Shared/AmortizedReclaim.lua's header on that distinction.
	for model, until_ in lungeUntil do
		if model.Parent == nil or now >= until_ then
			lungeUntil[model] = nil
			continue
		end
		local humanoid = CharacterUtil.LiveHumanoidOf(model)
		-- PrimaryPart, not Humanoid.RootPart -- every registration path into this combat stack
		-- (HitboxEngine.RegisterCombatant, DefenseSystem.RegisterCombatant) already requires and is
		-- handed a root explicitly rather than trusting Roblox's own rig-joint auto-detection, and a
		-- real player character's PrimaryPart is always its HumanoidRootPart. Same guarantee, no new
		-- dependency on rig internals this module has never needed before.
		local rootPart = model.PrimaryPart
		if humanoid and rootPart then
			-- The same Humanoid:Move() surface touch controls/gamepads/AI already drive a character
			-- through -- forces MoveDirection for this one frame regardless of what the player is
			-- actually holding, at whatever WalkSpeed RunSystem currently has in effect. relativeToCamera
			-- = false: the world-space LookVector is the swing's own facing, not the player's camera.
			humanoid:Move(rootPart.CFrame.LookVector, false)
		end
	end
end

-- Hitstun ------------------------------------------------------------------------------------------

-- Stuns `model` until `until_` (never shortening a stun already running), cancels its in-flight swing,
-- and publishes the deadline on HitstunUntil/CombatBusyUntil. The one path by which anything enters
-- hitstun: a resolved contact (applyOutcome above) and a wall splat
-- (Server/Combat/Environment/EnvironmentReactionSystem.lua) both land here, so "stunned" means the same
-- thing -- the same attack gate (CanAttack), the same guard hold (DefenseSystem.bodyCommitted), the same
-- run lock (RunSystem) -- whatever caused it.
--
-- THE ONE SEAM the environment sibling reaches down for, and it is narrow on purpose: it takes a
-- deadline, not a reason or an amount. Damage stays this module's to price; a splat only says "for
-- this long, you are reeling".
function DamageSystem.ExtendHitstun(model: Model, until_: number, at: number): ()
	if typeof(until_) ~= "number" or until_ ~= until_ or until_ <= at then
		return
	end
	local stunnedUntil = math.max(hitstunUntil[model] or 0, until_)
	hitstunUntil[model] = stunnedUntil
	cancelSwingOf(model, at)
	publishHitstunOf(model, stunnedUntil)
end

-- Impact damage ----------------------------------------------------------------------------------

-- Health removed by something that was never a swing or a shot -- today, a thrown body landing (GrabSystem): the
-- thrown victim's own landing, and the bystander it crashes into. It used to be a bare Humanoid:TakeDamage in the
-- grab layer, which kept it out of everything that hears about damage here: no kill credit (PlayerDeathSystem),
-- no engagement tag, no realm scaling, no damage number.
--
-- THE SECOND WAY INTO OnApplied, and deliberately narrow. No defence (a thrown body was never blockable or
-- parryable, so nothing here asks DefenseSystem), no stun, no guard, no combo -- only the damage scales (power, realm) and
-- the same announce-then-write order applyOutcome keeps for kill credit. The outcome it publishes is a Clean hit
-- whose Report.DebugName is DamageConstants.Impact.DebugName: no MoveId, so nothing keyed on a move (hit confirm,
-- the air combo's roles, a grab's trigger) can mistake it for one.
--
-- Feedback goes to the ATTACKER only (their damage number, the impact on the other body). The defender's copy is
-- withheld on purpose: their client treats a Clean feedback as a stun and cuts its own swing, and the server did
-- neither.
function DamageSystem.ApplyImpact(attacker: Model, target: Model, amount: number, at: number): number
	if typeof(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return 0
	end
	local humanoid = CharacterUtil.LiveHumanoidOf(target)
	local root = target.PrimaryPart
	if humanoid == nil or root == nil then
		return 0
	end
	local realmNow = DomainRules.ServerNow()
	local powerDamage = CombatPower.Scales(attacker, target)
	local result: DamageResult = DamageResolver.ApplyScales({
		Kind = "Clean",
		Damage = amount,
		GuardDrain = 0,
		HitstunSeconds = 0,
		AdvancesCombo = false,
	}, {
		PowerDamage = powerDamage,
		DamageDealt = DomainRules.Scale(CharacterUtil.HumanoidOf(attacker), "DamageDealt", realmNow),
		DamageTaken = DomainRules.Scale(humanoid, "DamageTaken", realmNow),
	})
	local damage = result.Damage
	if not (damage > 0) then
		return 0
	end

	local report: HitReport = {
		Attacker = attacker,
		Target = target,
		TargetPart = root,
		Shape = "Sphere",
		Dimensions = { Width = 0, Height = 0, Length = 0, Radius = 0, InnerRadius = 0, AngleDegrees = 0 },
		ContactPosition = root.Position,
		ComboStage = 0,
		PowerLevel = 0,
		SampleTime = at,
		DebugName = DamageConstants.Impact.DebugName,
		Source = "Impact",
	}
	local outcome: DefenseOutcome = {
		Kind = "Clean",
		Report = report,
		Attacker = attacker,
		Defender = target,
		BearingDegrees = 0,
		DefenderStateAtContact = "Neutral",
		Guard = 0,
		GuardDelta = 0,
		SampleTime = at,
	}
	appliedListeners:Fire(outcome, result)
	humanoid:TakeDamage(damage)

	if attacker ~= target then
		sendFeedback(attacker, {
			Kind = "Clean",
			Role = "Attacker",
			Attacker = attacker,
			Defender = target,
			Damage = damage,
			GuardDrain = 0,
			ComboStage = 0,
			MoveId = DamageConstants.Impact.DebugName,
			ContactPosition = root.Position,
		})
	end
	debugLog("Impact damage applied", { attacker = attacker.Name, target = target.Name, damage = damage })
	return damage
end

-- Public queries -----------------------------------------------------------------------------------

-- Whether this combatant may start an attack, and why not when they may not.
--
-- The attack layer consults this ALONGSIDE DefenseSystem.CanAttack, not instead of it: that one
-- answers "are you staggered or guarding", this one answers "are you reeling from a hit". Two
-- questions, two owners, and neither system has to know the other's states.
function DamageSystem.CanAttack(model: Model, now: number): (boolean, string?)
	local until_ = hitstunUntil[model]
	if until_ and now < until_ then
		return false, "Hitstun"
	end
	return true, nil
end

-- When this body's current hitstun ends, or -math.huge when it has none on record. For the attack layer's
-- latency refund (AttackConstants.Latency), which may not backdate a swing into a stun.
function DamageSystem.HitstunUntil(model: Model): number
	return hitstunUntil[model] or -math.huge
end

-- How much of `model`'s stun is still to run at `now`, 0 when none -- what the defender's Combat_Feedback
-- carries as HitstunSeconds. The STUN STILL TO RUN, not the contact's authored length, for two reasons:
-- the stun is timed from the contact (SampleTime), so a contact that waited out the rewind hold has already
-- spent up to that hold's cap of it (Parry.RewindMaxSeconds on the ground, AirComboConstants.Parry.
-- RewindMaxSeconds air-held); and a hit inside a longer stun ends with that one. Sending the length had the
-- defender's own mirror run long by both, which held their comeback swing back.
function DamageSystem.StunRemaining(model: Model, now: number): number
	local until_ = hitstunUntil[model]
	return if until_ then math.max(until_ - now, 0) else 0
end

function DamageSystem.IsHitstunned(model: Model, now: number): boolean
	local until_ = hitstunUntil[model]
	return until_ ~= nil and now < until_
end

-- Whether Step is currently forcing this attacker forward via DamageConstants.AttackerLunge. Same
-- read-only, timestamp-bounded query shape as IsHitstunned above -- exists so a spec can assert on
-- the gating decision directly rather than on a real Humanoid's physics response, which a synthetic
-- Step has no way to guarantee the timing of.
function DamageSystem.IsLunging(model: Model, now: number): boolean
	local until_ = lungeUntil[model]
	return until_ ~= nil and now < until_
end

function DamageSystem.GetComboStage(model: Model, now: number): number
	return ComboEscalation.GetStage(model, now)
end

-- Keeps this attacker's live landed combo from lapsing before `until_` (ComboEscalation.Hold). Adds no
-- depth, and does nothing for a combo that already lapsed at `at`.
--
-- AttackRequestSystem's ONE seam into this layer for chain-keeping (2026-09-29). It holds the combo
-- through an Art woven into a string, and through the stagger of a parried swing, so the combo depth the
-- launcher needs survives both. The string position half lives in SwingSequencer. This layer still owns
-- what a landing IS. It is only told when the clock must not run.
function DamageSystem.HoldCombo(model: Model, until_: number, at: number): ()
	ComboEscalation.Hold(model, until_, at)
end

-- Installs (or, with nil, removes) the air combo's damage hook -- see airComboHook. One slot: a second
-- installer replaces the first, which is correct for a hook with exactly one legitimate owner.
function DamageSystem.SetAirComboHook(hook: AirComboHook?): ()
	airComboHook = hook
end

-- This system's output signal, for anything downstream that wants to react to real damage --
-- PlayerDeathSystem's kill credit, GrabSystem, EngagementSystem and KnockbackAudit today. The
-- DamageResult carries Launch already resolved. Returns a disconnect function
-- rather than a connection object, matching HitboxEngine.OnHit and DefenseSystem.OnResolved's own
-- contract so a consumer of all three learns one shape.
--
-- Fired BEFORE the health write. See applyOutcome for why that ordering is load-bearing.
function DamageSystem.OnApplied(callback: (DefenseOutcome, DamageResult) -> ()): () -> ()
	return appliedListeners:Connect(callback)
end

-- Lifecycle ----------------------------------------------------------------------------------------

-- Subscribes to the defence layer's outcome signal, and nothing else. Split out of Init for the same
-- reason DefenseSystem.Attach is: a spec has to drive this system on a synthetic clock, and it cannot
-- do that if the only way to receive outcomes is to also start a real Heartbeat racing its own Step
-- calls. Idempotent.
function DamageSystem.Attach(): ()
	if resolvedDisconnect then
		return
	end
	resolvedDisconnect = DefenseSystem.OnResolved(applyOutcome)
end

function DamageSystem.Init(): ()
	if started then
		return
	end
	-- See this file's header: Heartbeat order is a correctness property, not a preference. Asserted
	-- rather than documented, because a comment in Main.server.lua cannot fail a boot.
	assert(HitboxEngine.RegisteredCount() >= 0, "DamageSystem.Init() requires HitboxEngine to be available")
	assert(DefenseSystem.CanAttack ~= nil, "DamageSystem.Init() requires DefenseSystem to be available")
	started = true

	feedbackRemote = NetworkBridge.CreateRemoteEvent(DamageConstants.Network.RemoteNames.Feedback)

	DamageSystem.Attach()

	-- Connected AFTER DefenseSystem.Init has connected its own, which Main.server.lua guarantees by
	-- calling that first.
	heartbeatTrove:Connect(RunService.Heartbeat, function(deltaTime: number)
		DamageSystem.Step(deltaTime, os.clock())
	end)

	logger:info("DamageSystem.Init() complete")
end

function DamageSystem.Shutdown(): ()
	heartbeatTrove:Clean()
	if resolvedDisconnect then
		resolvedDisconnect()
		resolvedDisconnect = nil
	end
	started = false
end

-- Drops every piece of per-combatant state and every subscription. Spec-only, so one case cannot serve
-- another its state -- the same role HitboxEngine.Reset and DefenseSystem.Reset play for their own
-- modules.
function DamageSystem.Reset(): ()
	-- Dropped so a following Attach() genuinely re-subscribes. DefenseSystem.Reset table.clears its own
	-- callback list, so a spec that resets both would otherwise hold a stale non-nil handle for a
	-- subscription that no longer exists -- and Attach's idempotence guard would then refuse to make a
	-- new one, silently delivering no outcomes for every case after the first. Exactly the trap
	-- DefenseSystem.Reset documents for itself.
	if resolvedDisconnect then
		resolvedDisconnect()
		resolvedDisconnect = nil
	end
	table.clear(hitstunUntil)
	table.clear(lungeUntil)
	hitstunReclaim:Reset()
	appliedListeners:Clear()
	airComboHook = nil
	ComboEscalation.Reset()
	AttackCatalog.Reset()
end

return DamageSystem :: Types.SystemModule & typeof(DamageSystem)
