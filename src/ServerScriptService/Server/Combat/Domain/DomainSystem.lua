--!strict
--[[
	DomainSystem.lua

	Owns: every live REALM (an Unfurling -- Shared/Domain/DomainTypes.lua's header): opening one when a
	domain move's swing is accepted, running its lifecycle (Server/Combat/Domain/DomainInstance.lua), who
	is inside it, the law it lays on them, the effects it delivers, what happens when two realms meet, its
	edge, its Qi upkeep, and telling every client enough to draw it. Server-authoritative end to end: a
	client learns what a realm looks like and never decides who is in it, what it does, or when it ends.

	A SIBLING OF THE ATTACK LAYER, NOT A FIFTH COMBAT LAYER (CLAUDE.md's combat layering). It sits beside
	GrabSystem and AirComboSystem and reaches the stack only through entry points that already existed or
	are one narrow seam each:
	  * IN, from the attack layer: AttackRequestSystem.OnSwingAccepted (the documented extension point for
	    "a swing started"). A domain move is thrown through the same path as any art, so its cooldown, its
	    Qi cost, its tell, its clip and every gate a press meets are the attack layer's, unchanged.
	    THE REALM IS THE MOVE'S EXTENSION, NOT THE MOVE: acceptance only PENDS the cast. The realm opens when
	    the move's own windup (the swing's WindupSeconds) has run out, and its clock -- the unfurl, the
	    boundary, the owner's pose -- starts at that scheduled instant. A swing cut before then (a feint, a
	    parry, a stun -- GetInFlight going quiet) or an owner who dies in it means the realm never exists.
	  * OUT, to deliver effects (Server/Combat/Domain/DomainEffects.lua): HitboxEngine.LaunchVolley (the
	    realm's one engine seam), DamageSystem.ExtendHitstun, DefenseSystem.DrainGuard,
	    AttackRequestSystem.ThrowMove -- every one a public function that already had a caller of the same
	    shape. So a realm's strike is blocked, parried, evaded, priced, credited as a kill and tags combat
	    exactly as that move would be, and nothing here decides any of it.
	  * OUT, to lay down law: Humanoid Attributes through Shared/Domain/DomainRules.lua. No combat layer
	    requires this module; each reads the one attribute its own question needs (that module's header
	    lists every reader).
	  * The boundary's projectile edge: HitboxEngine.SetProjectileBarrier, held only while a realm with a
	    closed edge is up.

	ONE HEARTBEAT, TWO RATES, NO PER-TARGET CONNECTIONS.
	  * Every frame: each live realm's owner is checked (dead, cut, struck), its lifecycle advanced on its
	    scheduled boundaries, and its effect timers compared against `now` -- a few comparisons per realm.
	  * At DomainConstants.MembershipHz: who is inside (a distance test per realm per REGISTERED
	    COMBATANT -- the Combatant tag's set, tracked by its own added/removed signals, never a world
	    search), the barred edges, the clash pass, Qi upkeep, and the law republished -- written only where
	    it changed (DomainRules.Publish).
	  A server with no realm pays one length check per frame.

	WHO A REALM GOVERNS. Membership is admission: whoever is inside when the realm is established (nearest
	first, up to MaxTargets) is a founding member; a later arrival is admitted through an Open entry (and
	stands through EntryGraceSeconds before any effect targets them), or repelled by a Barred one. A member
	who steps out keeps the law for ExitLingerSeconds and is then released -- unless the exit is Barred,
	in which case they are set back inside (the owning client predicts the same wall, Client/FX/DomainFX,
	so an honest player meets a wall rather than a correction). The owner is never held by their own realm.
	Where realms overlap, the clash outcome (Shared/Domain/DomainClash.lua) decides whose law a body in
	both is under: a suppressed or eroding loser's law and effects do not reach it; a contest applies both,
	each pulled toward nothing by its own ContestScale.

	CANCEL CONDITIONS, all checked here: the owner dying (always), the casting swing cut in its windup
	(always), the owner struck while the realm is still unfurling (CancelOnOwnerHit), the owner leaving
	their own Fixed realm (CancelOnOwnerExit), the owner running out of Qi for the upkeep (UpkeepQiPerSecond
	-- spent through QiSystem.Spend, so it also feeds Qi Deviation risk like any other expenditure), and a
	clash that Dominates or Shatters it.

	Does not own: the schema (DomainTypes), the phase machine (DomainInstance), geometry (DomainGeometry),
	clash arbitration (DomainClash), the attribute contract (DomainRules), effect delivery (DomainEffects),
	the physical wall (DomainWall), or anything a delivered effect does once it lands.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Allegiance = require(ReplicatedStorage.Shared.Combat.Allegiance)
local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)
local CallbackList = require(ReplicatedStorage.Shared.CallbackList)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local DomainClash = require(ReplicatedStorage.Shared.Domain.DomainClash)
local DomainConstants = require(ReplicatedStorage.Shared.Domain.DomainConstants)
local DomainGeometry = require(ReplicatedStorage.Shared.Domain.DomainGeometry)
local DomainRules = require(ReplicatedStorage.Shared.Domain.DomainRules)
local DomainTypes = require(ReplicatedStorage.Shared.Domain.DomainTypes)
local HitboxEngineConstants = require(ReplicatedStorage.Shared.HitboxEngine.HitboxEngineConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local SlowWatch = require(ReplicatedStorage.Shared.SlowWatch)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local Trove = require(ReplicatedStorage.Shared.Trove)

local CombatRoot = ServerScriptService.Server.Combat
local AttackCatalog = require(CombatRoot.AttackCatalog)
local AttackRequestSystem = require(CombatRoot.Attack.AttackRequestSystem)
local DamageSystem = require(CombatRoot.Damage.DamageSystem)
local DefenseSystem = require(CombatRoot.Defense.DefenseSystem)
local EngagementSystem = require(CombatRoot.Engagement.EngagementSystem)
local HitboxEngine = require(CombatRoot.HitboxEngine.HitboxEngine)
local MoveRegistryManager = require(CombatRoot.MoveRegistryManager)
local QiSystem = require(ServerScriptService.Server.Systems.QiSystem)

local DomainEffects = require(script.Parent.DomainEffects)
local DomainInstance = require(script.Parent.DomainInstance)
local DomainWall = require(script.Parent.DomainWall)
local CombatTick = require(script.Parent.Parent.CombatTick)

type DomainInstance = DomainInstance.DomainInstance
type Transition = DomainInstance.Transition
type DomainMessage = DomainTypes.DomainMessage
type DomainView = DomainTypes.DomainView

local logger = Logger.scope("DomainSystem")

-- Effect kinds that touch a body without resolving a hit, so the damage layer never tags the pair as engaged;
-- the Pressure port does it instead (EngagementSystem.RecordPressure).
local PRESSURE_KINDS: { [string]: true } = { Hitstun = true, GuardDrain = true, Pull = true, Push = true }

local DomainSystem = {}

-- State ---------------------------------------------------------------------------------------------------

-- Dense, in opening order, so every pass visits realms in a stable order.
local instances: { DomainInstance } = {}
local byId: { [string]: DomainInstance } = {}
local nextSerial = 0

-- Per realm: its Ring-strike Random, its physical wall, the swing that cast it (for the windup check), its
-- current boundary (refreshed each frame -- the barrier reads it once per shot step), and when its last
-- erosion was told to clients.
local randoms: { [string]: Random } = {}
local walls: { [string]: Model } = {}
type CastSwing = { StartedAt: number, WindupSeconds: number }
local castSwings: { [string]: CastSwing } = {}
local bounds: { [string]: DomainGeometry.Boundary } = {}
local lastErosionNotice: { [string]: number } = {}

-- Per realm: its strike shot budget (DomainConstants.Strike's token bucket) -- shots in hand, and when it
-- was last refilled. Tokens may go negative: a Volley's overdraw, paid back before the next pulse fires.
type ShotBudget = { Tokens: number, At: number }
local shotBudgets: { [string]: ShotBudget } = {}

-- Per realm: Qi upkeep accrued and not yet spent (DomainConstants.UpkeepChunkSeconds).
local upkeepOwed: { [string]: number } = {}

-- Every registered combatant, as a set -- the membership pass's candidates. Kept by the Combatant tag's own
-- signals rather than a GetTagged per tick.
local combatants: { [Model]: boolean } = {}

-- Bodies this System has published rules to, so a body no realm governs any more is cleared exactly once.
local governed: { [Model]: boolean } = {}

-- Live clashes, keyed by the two realm ids in sorted order.
type ClashRecord = { A: string, B: string, Outcome: DomainClash.Outcome }
local clashes: { [string]: ClashRecord } = {}

-- The MoveIds that open a realm, so the per-swing subscription is one table read for every swing that
-- does not (almost all of them). Kept by MoveRegistryManager.OnChanged.
local domainMoves: { [string]: boolean } = {}

-- Casts waiting out their move's windup: a domain move's swing was accepted, its realm has not opened yet.
type PendingCast = {
	Owner: Model,
	MoveId: string,
	Spec: DomainTypes.DomainSpec,
	StartedAt: number,
	WindupSeconds: number,
}
local pendingCasts: { PendingCast } = {}

local membershipAccumulator = 0
local barrierHeld = false

-- OnPhaseChanged's subscribers (Shared/CallbackList.lua).
local phaseListeners: CallbackList.CallbackList<string, Transition> =
	CallbackList.New(logger, "DomainSystem.OnPhaseChanged")

local started = false
local trove = Trove.New()
local stateRemote: RemoteEvent? = nil
local requestLimiter = RateLimiter.New(DomainConstants.Network.MaxRequestsPerSecond)

-- The realm's clocks. `clock` is the combat stack's (os.clock), the one every Step and deadline here runs
-- on; `serverClock` is the shared one clients and the rule leases compare against. Both swappable for the
-- specs (SetClocksForTesting).
local clock: () -> number = os.clock
local serverClock: () -> number = DomainRules.ServerNow

-- Converts an instance-clock time to the shared server clock.
--
-- THE OFFSET IS SAMPLED ONCE PER REALM (at Open) and reused, never re-derived per call. Re-deriving it read
-- two clocks at two slightly different instants, so the same scheduled end came out a few microseconds
-- different every tick -- and DomainRules.Publish, which writes only on change, rewrote DomainUntil on every
-- member ten times a second, replicating to every client. A realm's timeline is one fixed mapping.
local offsets: { [string]: number } = {}

local function sampleOffset(): number
	return serverClock() - clock()
end

local function serverTimeOf(at: number, id: string?): number
	local offset = if id then offsets[id] else nil
	return at + (offset or sampleOffset())
end

-- Ports -----------------------------------------------------------------------------------------------------

-- Everything this System calls on the rest of the server, in one table (DomainEffects' PORTS reasoning):
-- the specs swap it for stubs, and there is exactly one place each dependency is reached from.
export type Ports = DomainEffects.Ports & {
	SpendQi: (player: Player, amount: number) -> boolean,
	-- The Player whose character `model` is, or nil -- a thin seam so a spec can drive the upkeep with a
	-- stand-in (Instance.new("Player") errors in the harness).
	PlayerOf: (model: Model) -> Player?,
	IsHitstunned: (model: Model, now: number) -> boolean,
	InFlightStartedAt: (model: Model) -> number?,
	IsRegistered: (model: Model) -> boolean,
	SetBarrier: (callback: ((Model, string?, Vector3, Vector3) -> boolean)?) -> (),
	GetMove: (moveId: string) -> DomainTypes.DomainSpec?,
	-- Tags owner and target as engaged for a pulse that reached a body without resolving a hit (Hitstun,
	-- GuardDrain, Pull, Push). A Strike/Volley is tagged by the damage layer like any hit.
	Pressure: (owner: Model, target: Model, now: number) -> (),
}

local function applyImpulse(model: Model, velocity: Vector3, _now: number): ()
	-- The knockback path's owner split (DamageSystem.applyLaunch): a player's own client moves them, a
	-- server-owned body is moved here. The allowance stamp is the one DamageSystem uses for an honest launch.
	local player = Players:GetPlayerFromCharacter(model)
	if player then
		local humanoid = CharacterUtil.HumanoidOf(model)
		if humanoid then
			humanoid:SetAttribute(
				AttributeConstants.KnockbackUntil,
				os.clock() + DomainConstants.ContainmentAllowanceSeconds
			)
		end
		local remote = stateRemote
		if remote then
			remote:FireClient(player, { Kind = "Impulse", Velocity = velocity } :: DomainMessage)
		end
		return
	end
	local root = CharacterUtil.RootOf(model)
	if root and not root.Anchored then
		root.AssemblyLinearVelocity = velocity
	end
end

local defaultPorts: Ports = {
	CatalogGet = function(moveId: string)
		return AttackCatalog.Get(moveId) :: any
	end,
	LaunchVolley = function(owner, definition, aim, powerLevel, now, options)
		return HitboxEngine.LaunchVolley(owner, definition, aim, powerLevel, now, options :: any)
	end,
	ExtendHitstun = DamageSystem.ExtendHitstun,
	DrainGuard = function(model: Model, amount: number, now: number): any
		DefenseSystem.DrainGuard(model, amount, now)
		return nil
	end,
	ThrowMove = AttackRequestSystem.ThrowMove,
	Impulse = applyImpulse,
	SpendQi = function(player: Player, amount: number): boolean
		return QiSystem.Spend(player, amount, "DomainUpkeep")
	end,
	PlayerOf = function(model: Model): Player?
		return Players:GetPlayerFromCharacter(model)
	end,
	IsHitstunned = DamageSystem.IsHitstunned,
	InFlightStartedAt = function(model: Model): number?
		local swing = AttackRequestSystem.GetInFlight(model)
		return if swing then swing.StartedAt else nil
	end,
	IsRegistered = function(model: Model): boolean
		return HitboxEngine.GetCombatantId(model) ~= nil
	end,
	SetBarrier = function(callback)
		HitboxEngine.SetProjectileBarrier(callback)
	end,
	Pressure = EngagementSystem.RecordPressureBetween,
	GetMove = function(moveId: string): DomainTypes.DomainSpec?
		local move = MoveRegistryManager.Get(moveId)
		return if move then move.Domain else nil
	end,
}
local ports: Ports = defaultPorts

-- Helpers ---------------------------------------------------------------------------------------------------

local function debugLog(flag: boolean, message: string, data: { [string]: any }?): ()
	if DomainConstants.Debug.Enabled and flag then
		logger:debug(message, data)
	end
end

local function broadcast(message: DomainMessage): ()
	local remote = stateRemote
	if remote then
		remote:FireAllClients(message)
	end
end

local function viewOf(instance: DomainInstance): DomainView
	local spec = instance.Spec
	return {
		Id = instance.Id,
		Owner = instance.Owner,
		MoveId = instance.MoveId,
		Shape = spec.Shape,
		Radius = spec.Radius,
		Height = if spec.Shape == "Sphere" then spec.Radius * 2 else spec.Height,
		Center = instance.Center,
		Offset = instance.Offset,
		Yaw = instance.Yaw,
		Anchor = spec.Anchor,
		EntryRule = spec.EntryRule,
		ExitRule = spec.ExitRule,
		Phase = instance.Phase,
		PhaseStartedAt = serverTimeOf(instance.PhaseStartedAt, instance.Id),
		PhaseEndsAt = if instance.PhaseEndsAt == math.huge then 0 else serverTimeOf(instance.PhaseEndsAt, instance.Id),
		ActivationSeconds = spec.ActivationSeconds,
		EndSeconds = spec.EndSeconds,
		ClashState = instance.ClashState,
	}
end

local function pairKey(a: string, b: string): string
	return if a < b then `{a}|{b}` else `{b}|{a}`
end

local function outcomeBetween(a: DomainInstance, b: DomainInstance): DomainClash.Outcome?
	local record = clashes[pairKey(a.Id, b.Id)]
	return if record then record.Outcome else nil
end

-- Whether `instance`'s law is kept out of `body` by a realm that beat it and also governs that body.
local function suppressedFor(instance: DomainInstance, body: Model): boolean
	if next(instance.ClashingWith) == nil then
		return false
	end
	for otherId in instance.ClashingWith do
		local other = byId[otherId]
		if other and other.Phase == "Active" and other.Members[body] then
			local outcome = outcomeBetween(instance, other)
			if outcome and outcome.Loser == instance.Id and DomainClash.SuppressesLoser(outcome.Behavior) then
				return true
			end
		end
	end
	return false
end

-- Whether `instance` is contesting another realm that also governs `body`.
local function contestedFor(instance: DomainInstance, body: Model): boolean
	for otherId in instance.ClashingWith do
		local other = byId[otherId]
		if other and other.Phase == "Active" and other.Members[body] then
			local outcome = outcomeBetween(instance, other)
			if outcome and outcome.Behavior == "Contest" then
				return true
			end
		end
	end
	return false
end

local function refreshBarrier(): ()
	local needed = false
	for _, instance in instances do
		if
			instance.Phase == "Active" and (not instance.Spec.ProjectilesEnter or not instance.Spec.ProjectilesLeave)
		then
			needed = true
			break
		end
	end
	if needed == barrierHeld then
		return
	end
	barrierHeld = needed
	if needed then
		ports.SetBarrier(function(_owner: Model, domainId: string?, from: Vector3, to: Vector3): boolean
			for _, instance in instances do
				local spec = instance.Spec
				if instance.Phase ~= "Active" or instance.Id == domainId then
					continue
				end
				if spec.ProjectilesEnter and spec.ProjectilesLeave then
					continue
				end
				local boundary = bounds[instance.Id]
				if boundary then
					local crossing = DomainGeometry.Crossing(boundary, from, to)
					if crossing == "Leaving" and not spec.ProjectilesLeave then
						return true
					elseif crossing == "Entering" and not spec.ProjectilesEnter then
						return true
					end
				end
			end
			return false
		end)
	else
		ports.SetBarrier(nil)
	end
end

-- Sets a body back to `position`, keeping its facing. A player's body is theirs to simulate, but a pivot is a
-- property write the server may make (a teleport), unlike a velocity; the allowance stamp keeps
-- ParkourSystem from counting the correction against them.
local function setBack(body: Model, root: BasePart, position: Vector3): ()
	body:PivotTo(body:GetPivot() + (position - root.Position))
	if Players:GetPlayerFromCharacter(body) then
		local humanoid = CharacterUtil.HumanoidOf(body)
		if humanoid then
			humanoid:SetAttribute(
				AttributeConstants.KnockbackUntil,
				os.clock() + DomainConstants.ContainmentAllowanceSeconds
			)
		end
	end
end

-- Lifecycle -------------------------------------------------------------------------------------------------

local function notifyPhase(instance: DomainInstance, transition: Transition): ()
	broadcast({
		Kind = "Phase",
		Id = instance.Id,
		Phase = instance.Phase,
		PhaseStartedAt = serverTimeOf(instance.PhaseStartedAt, instance.Id),
		PhaseEndsAt = if instance.PhaseEndsAt == math.huge then 0 else serverTimeOf(instance.PhaseEndsAt, instance.Id),
		Reason = transition.Reason,
	})
	phaseListeners:Fire(instance.Id, transition)
	debugLog(DomainConstants.Debug.LogLifecycle, "Realm phase", {
		id = instance.Id,
		from = transition.From,
		to = transition.To,
		reason = transition.Reason,
	})
end

-- Founding membership: everyone inside at establishment, nearest first, up to MaxTargets; the rest are
-- Present (neither governed nor repelled). The owner, if inside, is always a founding member.
local function foundMembers(instance: DomainInstance, now: number): ()
	local boundary = DomainInstance.Boundary(instance)
	type Candidate = { Body: Model, Distance: number }
	local inside: { Candidate } = {}
	for body in combatants do
		local root = CharacterUtil.RootOf(body)
		if root and CharacterUtil.LiveHumanoidOf(body) and DomainGeometry.Contains(boundary, root.Position) then
			local distance = if body == instance.Owner then -1 else (root.Position - instance.Center).Magnitude
			table.insert(inside, { Body = body, Distance = distance })
		end
	end
	table.sort(inside, function(a: Candidate, b: Candidate): boolean
		return a.Distance < b.Distance
	end)
	for index, candidate in inside do
		if index <= instance.Spec.MaxTargets then
			DomainInstance.Admit(instance, candidate.Body, now, true)
		else
			instance.Present[candidate.Body] = true
		end
	end
end

local function establish(instance: DomainInstance, now: number): ()
	local spec = instance.Spec
	bounds[instance.Id] = DomainInstance.Boundary(instance)
	foundMembers(instance, now)
	for index, effect in spec.Effects do
		instance.EffectNextAt[index] = now + effect.FirstDelaySeconds
	end
	if spec.BoundaryCollision and spec.Anchor == "Fixed" then
		local ok, wall = pcall(DomainWall.Build, instance.Id, DomainInstance.Boundary(instance))
		if ok then
			walls[instance.Id] = wall
		else
			logger:error("Could not raise a realm's wall", { id = instance.Id, errorMessage = tostring(wall) })
		end
	end
	refreshBarrier()
end

-- The law lifts (Active -> Ending, or a realm collapsing before it was ever Active): members released, the
-- wall dropped, its clashes forgotten. The rules on each body are cleared by the governance pass this
-- forces immediately below, not left to the next tick.
local liftLaw: (instance: DomainInstance) -> ()

local function recomputeGovernance(now: number): ()
	type Governance = { Set: DomainRules.RuleSet, Until: number, Governor: string, Priority: number }
	local desired: { [Model]: Governance } = {}
	for _, instance in instances do
		if instance.Phase ~= "Active" then
			continue
		end
		local spec = instance.Spec
		local lawEnds = serverTimeOf(DomainInstance.LawEndsAt(instance, now), instance.Id)
		for body in instance.Members do
			if suppressedFor(instance, body) then
				continue
			end
			local entry = desired[body]
			if entry == nil then
				entry = { Set = DomainRules.Empty(), Until = lawEnds, Governor = instance.Id, Priority = spec.Priority }
				desired[body] = entry
			else
				entry.Until = math.max(entry.Until, lawEnds)
				if spec.Priority > entry.Priority then
					entry.Governor = instance.Id
					entry.Priority = spec.Priority
				end
			end
			local contest = if contestedFor(instance, body) then spec.ContestScale else 1
			for _, rule in spec.Rules do
				if
					Allegiance.Matches(rule.Affects, instance.Owner, body)
					and Allegiance.MatchesType(rule.TargetTypes, body)
				then
					DomainRules.Apply(entry.Set, rule.Kind, rule.Value, rule.MoveId, contest)
				end
			end
		end
	end

	for body, entry in desired do
		local humanoid = CharacterUtil.HumanoidOf(body)
		if humanoid then
			DomainRules.Publish(humanoid, entry.Set, entry.Until, entry.Governor)
		end
	end
	for body in governed do
		if desired[body] == nil then
			local humanoid = CharacterUtil.HumanoidOf(body)
			if humanoid then
				DomainRules.Clear(humanoid)
			end
		end
	end
	table.clear(governed)
	for body in desired do
		governed[body] = true
	end
end

liftLaw = function(instance: DomainInstance): ()
	for body in instance.Members do
		DomainInstance.Release(instance, body)
	end
	table.clear(instance.Present)
	local wall = walls[instance.Id]
	if wall then
		wall:Destroy()
		walls[instance.Id] = nil
	end
	for key, record in clashes do
		if record.A == instance.Id or record.B == instance.Id then
			clashes[key] = nil
			local otherId = if record.A == instance.Id then record.B else record.A
			local other = byId[otherId]
			if other then
				other.ClashingWith[instance.Id] = nil
			end
		end
	end
	table.clear(instance.ClashingWith)
	instance.ClashState = "None"
	refreshBarrier()
end

local function teardown(instance: DomainInstance): ()
	local index = table.find(instances, instance)
	if index then
		table.remove(instances, index)
	end
	byId[instance.Id] = nil
	randoms[instance.Id] = nil
	offsets[instance.Id] = nil
	castSwings[instance.Id] = nil
	bounds[instance.Id] = nil
	lastErosionNotice[instance.Id] = nil
	shotBudgets[instance.Id] = nil
	upkeepOwed[instance.Id] = nil
	local humanoid = CharacterUtil.HumanoidOf(instance.Owner)
	if humanoid then
		DomainRules.SetOwned(humanoid, nil)
	end
end

local function applyTransition(instance: DomainInstance, transition: Transition, now: number): ()
	if transition.To == "Active" then
		establish(instance, now)
	elseif transition.To == "Ending" or (transition.To == "Finished" and transition.From ~= "Ending") then
		liftLaw(instance)
		recomputeGovernance(now)
	end
	notifyPhase(instance, transition)
	if transition.To == "Finished" then
		teardown(instance)
	end
end

-- Watched (Shared/SlowWatch.lua): a transition is where a realm does its one-off work -- raising the wall,
-- founding its members, lifting the law -- so a slow one names itself in the Output.
local handleTransition = SlowWatch.Handler(logger, "DomainSystem.transition", applyTransition)

local function collapse(instance: DomainInstance, now: number, reason: string): ()
	local transition = DomainInstance.Collapse(instance, now, reason)
	if transition then
		handleTransition(instance, transition, now)
	end
end

-- Membership ------------------------------------------------------------------------------------------------

local function membershipPass(instance: DomainInstance, now: number): ()
	local spec = instance.Spec
	local boundary = bounds[instance.Id] or DomainInstance.Boundary(instance)
	local tolerance = DomainConstants.ContainmentToleranceStuds
	local margin = DomainConstants.ContainmentMarginStuds

	for body in combatants do
		local root = CharacterUtil.RootOf(body)
		local member = instance.Members[body]
		if root == nil or CharacterUtil.LiveHumanoidOf(body) == nil then
			if member then
				DomainInstance.Release(instance, body)
			end
			instance.Present[body] = nil
			continue
		end
		local depth = DomainGeometry.Depth(boundary, root.Position)
		local isOwner = body == instance.Owner

		if member then
			if depth >= 0 then
				member.LingerUntil = nil
			elseif spec.ExitRule == "Barred" and not isOwner then
				-- Held: still a member, set back inside once past the tolerance.
				if depth < -tolerance then
					setBack(body, root, DomainGeometry.ClampInside(boundary, root.Position, margin))
				end
			else
				if member.LingerUntil == nil then
					member.LingerUntil = now + spec.ExitLingerSeconds
				end
				if now >= (member.LingerUntil :: number) then
					DomainInstance.Release(instance, body)
				end
			end
		elseif depth >= 0 then
			if instance.Present[body] then
				continue
			end
			if spec.EntryRule == "Barred" and not isOwner then
				if depth > tolerance then
					setBack(body, root, DomainGeometry.ClampOutside(boundary, root.Position, margin))
				end
			elseif instance.MemberCount < spec.MaxTargets then
				DomainInstance.Admit(instance, body, now, false)
			end
		else
			instance.Present[body] = nil
		end

		if isOwner and spec.CancelOnOwnerExit and spec.Anchor == "Fixed" and depth < 0 then
			collapse(instance, now, "OwnerLeft")
			return
		end
	end
	-- A member whose body left the registry entirely (despawned, unregistered) is released too.
	for body in instance.Members do
		if not combatants[body] then
			DomainInstance.Release(instance, body)
		end
	end
end

-- Clashes ---------------------------------------------------------------------------------------------------

local function participantOf(instance: DomainInstance): DomainClash.Participant
	local spec = instance.Spec
	local overrides: { [string]: string } = {}
	for _, override in spec.ClashOverrides do
		overrides[override.OpponentMoveId] = override.Behavior
	end
	return {
		Id = instance.Id,
		MoveId = instance.MoveId,
		Priority = spec.Priority,
		Behavior = spec.ClashBehavior,
		Overrides = overrides,
		TieBreak = spec.TieBreak,
		Interacts = spec.Interacts,
		OpenedAt = instance.OpenedAt,
	}
end

local function clashStateOf(instance: DomainInstance): DomainInstance.ClashState
	local state: DomainInstance.ClashState = "None"
	for otherId in instance.ClashingWith do
		local record = clashes[pairKey(instance.Id, otherId)]
		if record then
			local outcome = record.Outcome
			if outcome.Behavior == "Contest" then
				state = "Contested"
			elseif outcome.Loser == instance.Id then
				return if outcome.Behavior == "Erode" then "Eroding" else "Suppressed"
			elseif outcome.Winner == instance.Id and state == "None" then
				state = "Dominant"
			end
		end
	end
	return state
end

local function clashPass(now: number, interval: number): ()
	local count = #instances
	for i = 1, count do
		local a = instances[i]
		if a == nil or a.Phase ~= "Active" then
			continue
		end
		for j = i + 1, count do
			local b = instances[j]
			if b == nil or b.Phase ~= "Active" or a.Phase ~= "Active" then
				continue
			end
			local key = pairKey(a.Id, b.Id)
			local overlapping = DomainGeometry.Overlaps(
				bounds[a.Id] or DomainInstance.Boundary(a),
				bounds[b.Id] or DomainInstance.Boundary(b)
			)
			local record = clashes[key]
			if overlapping and record == nil then
				local outcome = DomainClash.Resolve(participantOf(a), participantOf(b))
				record = { A = a.Id, B = b.Id, Outcome = outcome }
				clashes[key] = record
				a.ClashingWith[b.Id] = true
				b.ClashingWith[a.Id] = true
				debugLog(DomainConstants.Debug.LogClashes, "Realms clash", {
					a = a.Id,
					b = b.Id,
					behavior = outcome.Behavior,
					winner = outcome.Winner,
				})
				if outcome.Behavior == "Dominate" then
					local loser = byId[outcome.Loser :: string]
					if loser then
						collapse(loser, now, "Dominated")
					end
				elseif outcome.Behavior == "Shatter" then
					collapse(a, now, "Shattered")
					collapse(b, now, "Shattered")
				end
			elseif not overlapping and record ~= nil then
				clashes[key] = nil
				a.ClashingWith[b.Id] = nil
				b.ClashingWith[a.Id] = nil
			end
			-- Erosion, for as long as the overlap lasts: the loser's time drains at the WINNER's rate.
			local live = clashes[key]
			if live and live.Outcome.Behavior == "Erode" then
				local loser = byId[live.Outcome.Loser :: string]
				local winner = byId[live.Outcome.Winner :: string]
				if loser and winner and loser.Phase == "Active" then
					DomainInstance.Erode(loser, winner.Spec.ErodeRate * interval, now)
					local lastNotice = lastErosionNotice[loser.Id] or -math.huge
					if now - lastNotice >= 1 then
						lastErosionNotice[loser.Id] = now
						notifyPhase(loser, { From = "Active", To = "Active", At = now, Reason = "Eroding" })
					end
				end
			end
		end
	end
	for _, instance in instances do
		local state = if instance.Phase == "Active" then clashStateOf(instance) else "None"
		if state ~= instance.ClashState then
			instance.ClashState = state
			broadcast({ Kind = "Clash", Id = instance.Id, ClashState = state })
		end
	end
end

-- Effects ---------------------------------------------------------------------------------------------------

local function targetsFor(instance: DomainInstance, effect: DomainTypes.Effect, now: number): { Model }
	type Candidate = { Body: Model, Distance: number }
	local picked: { Candidate } = {}
	for body, member in instance.Members do
		if not DomainInstance.IsTargetable(instance, member, now) then
			continue
		end
		if not Allegiance.Matches(effect.Affects, instance.Owner, body) then
			continue
		end
		if not Allegiance.MatchesType(effect.TargetTypes, body) then
			continue
		end
		if suppressedFor(instance, body) then
			continue
		end
		local root = CharacterUtil.RootOf(body)
		if root == nil or CharacterUtil.LiveHumanoidOf(body) == nil then
			continue
		end
		table.insert(picked, { Body = body, Distance = (root.Position - instance.Center).Magnitude })
	end
	table.sort(picked, function(a: Candidate, b: Candidate): boolean
		return a.Distance < b.Distance
	end)
	local targets: { Model } = {}
	for index, candidate in picked do
		if index > effect.MaxPerPulse then
			break
		end
		table.insert(targets, candidate.Body)
	end
	return targets
end

-- The realm's strike shot budget, refilled to `now` (DomainConstants.Strike's header on the bucket).
local function shotBudgetOf(id: string, now: number): ShotBudget
	local tuning = DomainConstants.Strike
	local budget = shotBudgets[id]
	if budget == nil then
		budget = { Tokens = tuning.BurstShots, At = now }
		shotBudgets[id] = budget
	end
	local elapsed = math.max(now - budget.At, 0)
	budget.Tokens = math.min(budget.Tokens + elapsed * tuning.MaxShotsPerSecond, tuning.BurstShots)
	budget.At = now
	return budget
end

local function runEffects(instance: DomainInstance, now: number): ()
	local effects = instance.Spec.Effects
	if #effects == 0 then
		return
	end
	local scale = if instance.ClashState == "Contested" then instance.Spec.ContestScale else 1
	for index, effect in effects do
		local due = instance.EffectNextAt[index]
		if due == nil or now < due then
			continue
		end
		-- Next pulse on the authored rhythm; a long hitch fires once and resumes the rhythm, never a burst.
		local nextAt = due + effect.IntervalSeconds
		instance.EffectNextAt[index] = if nextAt <= now then now + effect.IntervalSeconds else nextAt

		-- A shot-firing pulse spends the realm's shot budget; with less than one shot in hand it is skipped
		-- before any targeting is done, and resumes on its rhythm once the budget has refilled.
		local budget: ShotBudget? = nil
		if effect.Kind == "Strike" or effect.Kind == "Volley" then
			budget = shotBudgetOf(instance.Id, now)
			if (budget :: ShotBudget).Tokens < 1 then
				continue
			end
		end

		local targets = if effect.Kind == "OwnerCast" then {} else targetsFor(instance, effect, now)
		if effect.Kind ~= "OwnerCast" and #targets == 0 then
			continue
		end
		local source: DomainEffects.Source = {
			Id = instance.Id,
			MoveId = instance.MoveId,
			Owner = instance.Owner,
			Center = instance.Center,
			Random = randoms[instance.Id] or Random.new(),
		}
		local ok, reached, spent = pcall(
			DomainEffects.Deliver,
			effect,
			source,
			targets,
			now,
			scale,
			ports,
			if budget then math.floor(budget.Tokens) else nil
		)
		if not ok then
			logger:error(
				"A realm effect errored",
				{ id = instance.Id, effect = index, errorMessage = tostring(reached) }
			)
			continue
		end
		if budget then
			budget.Tokens -= spent
		end
		if PRESSURE_KINDS[effect.Kind] then
			for _, target in reached do
				ports.Pressure(instance.Owner, target, now)
			end
		end
		if #reached > 0 then
			broadcast({
				Kind = "Pulse",
				Id = instance.Id,
				EffectIndex = index,
				EffectKind = effect.Kind,
				Targets = reached,
			})
		end
	end
end

-- The loop --------------------------------------------------------------------------------------------------

local function ownerCheck(instance: DomainInstance, now: number): boolean
	local owner = instance.Owner
	if owner.Parent == nil or CharacterUtil.LiveHumanoidOf(owner) == nil then
		collapse(instance, now, "OwnerDied")
		return false
	end
	if instance.Phase == "Activating" then
		-- The casting swing cut in its windup (feint, parry, stun): the realm never unfurls.
		local cast = castSwings[instance.Id]
		if cast and now < cast.StartedAt + cast.WindupSeconds then
			if ports.InFlightStartedAt(owner) ~= cast.StartedAt then
				collapse(instance, now, "Interrupted")
				return false
			end
		end
		if instance.Spec.CancelOnOwnerHit and ports.IsHitstunned(owner, now) then
			collapse(instance, now, "Interrupted")
			return false
		end
	end
	return true
end

local function upkeep(instance: DomainInstance, now: number, interval: number): ()
	local rate = instance.Spec.UpkeepQiPerSecond
	if rate <= 0 or instance.Phase ~= "Active" then
		return
	end
	local player = ports.PlayerOf(instance.Owner)
	if player == nil then
		return
	end
	-- Accrued every tick, booked once per UpkeepChunkSeconds (DomainConstants): one Spend carries the whole
	-- of what has built up, so the Qi drained over the realm's life is exactly rate x seconds.
	local owed = (upkeepOwed[instance.Id] or 0) + rate * interval
	if owed < rate * DomainConstants.UpkeepChunkSeconds - 1e-9 then
		upkeepOwed[instance.Id] = owed
		return
	end
	upkeepOwed[instance.Id] = 0
	if not ports.SpendQi(player, owed) then
		collapse(instance, now, "Depleted")
	end
end

-- Opens every pending cast whose move's windup has run out, and forgets every one whose swing was cut or whose
-- owner is gone. The realm begins at the windup's SCHEDULED end (StartedAt + WindupSeconds), not at the frame
-- that noticed, so a hitched frame does not push the unfurl later.
local function processPendingCasts(now: number): ()
	for index = #pendingCasts, 1, -1 do
		local cast = pendingCasts[index]
		local owner = cast.Owner
		if
			owner.Parent == nil
			or CharacterUtil.LiveHumanoidOf(owner) == nil
			or ports.InFlightStartedAt(owner) ~= cast.StartedAt
		then
			table.remove(pendingCasts, index)
			debugLog(
				DomainConstants.Debug.LogLifecycle,
				"Realm cast cut before its windup ended",
				{ moveId = cast.MoveId }
			)
			continue
		end
		local opensAt = cast.StartedAt + cast.WindupSeconds
		if now >= opensAt then
			table.remove(pendingCasts, index)
			local _, reason = DomainSystem.Open(owner, cast.MoveId, cast.Spec, opensAt, {
				StartedAt = cast.StartedAt,
				WindupSeconds = cast.WindupSeconds,
			})
			if reason then
				debugLog(
					DomainConstants.Debug.LogLifecycle,
					"Realm cast refused",
					{ moveId = cast.MoveId, reason = reason }
				)
			end
		end
	end
end

-- One frame. `now` is the combat stack's clock (os.clock), the convention every combat Step keeps.
function DomainSystem.Step(deltaTime: number, now: number): ()
	if #pendingCasts > 0 then
		processPendingCasts(now)
	end
	if #instances == 0 then
		membershipAccumulator = 0
		return
	end
	-- Labelled for the MicroProfiler (Ctrl+F6): the frame and the membership tick show as their own bars,
	-- so "is it the realm" is one capture rather than a guess.
	debug.profilebegin("DomainSystem.Frame")

	-- Walked over a copy: a transition can finish (and so remove) a realm mid-walk.
	for _, instance in table.clone(instances) do
		if instance.Phase == "Finished" then
			continue
		end
		-- A failed check collapses the realm; its Ending still advances below like any other.
		if DomainInstance.IsLive(instance) then
			ownerCheck(instance, now)
		end
		DomainInstance.Follow(instance, CharacterUtil.RootOf(instance.Owner))
		if instance.Phase == "Active" then
			bounds[instance.Id] = DomainInstance.Boundary(instance)
		end
		for _, transition in DomainInstance.Advance(instance, now) do
			handleTransition(instance, transition, now)
		end
		if instance.Phase == "Active" then
			runEffects(instance, now)
		end
	end

	debug.profileend()

	local interval = 1 / DomainConstants.MembershipHz
	membershipAccumulator += deltaTime
	if membershipAccumulator < interval then
		return
	end
	debug.profilebegin("DomainSystem.Membership")
	-- One sample per tick however long the hitch: a membership pass is a snapshot, not an integral.
	membershipAccumulator = math.min(membershipAccumulator - interval, interval)

	for _, instance in table.clone(instances) do
		if instance.Phase == "Active" then
			membershipPass(instance, now)
		end
	end
	clashPass(now, interval)
	for _, instance in table.clone(instances) do
		if instance.Phase == "Active" then
			upkeep(instance, now, interval)
		end
	end
	recomputeGovernance(now)
	debug.profileend()
end

-- Opening ---------------------------------------------------------------------------------------------------

-- Opens a realm for `owner` from `spec`, as if its domain move's swing had just been accepted. Returns the
-- realm's id, or (nil, reason). PUBLIC for the specs and for a future NPC/boss that owns a realm without a
-- swing -- every player-facing path comes through NoteSwingAccepted below.
function DomainSystem.Open(
	owner: Model,
	moveId: string,
	spec: DomainTypes.DomainSpec,
	now: number,
	castSwing: CastSwing?
): (string?, string?)
	if #instances >= DomainConstants.MaxLiveDomains then
		logger:warn("Realm ceiling reached; a cast was refused", { moveId = moveId })
		return nil, "TooManyDomains"
	end
	local root = CharacterUtil.RootOf(owner)
	local humanoid = CharacterUtil.LiveHumanoidOf(owner)
	if root == nil or humanoid == nil then
		return nil, "NoCharacter"
	end
	if not ports.IsRegistered(owner) then
		return nil, "NotRegistered"
	end
	for _, existing in instances do
		if existing.Owner == owner and existing.Phase ~= "Finished" then
			return nil, "DomainActive"
		end
	end

	nextSerial += 1
	local id = `D{nextSerial}`
	local instance = DomainInstance.new({
		Id = id,
		Owner = owner,
		MoveId = moveId,
		-- Its own copy: a Move Editor save mid-realm must not rewrite a law already laid down.
		Spec = DomainTypes.Copy(spec),
		OwnerPose = root.CFrame,
	})
	local transition = DomainInstance.Begin(instance, now) :: Transition
	table.insert(instances, instance)
	byId[id] = instance
	randoms[id] = Random.new(nextSerial)
	offsets[id] = sampleOffset()
	castSwings[id] = castSwing
	DomainRules.SetOwned(humanoid, serverTimeOf(DomainInstance.GoneAt(instance, now), id))

	broadcast({ Kind = "Open", Domain = viewOf(instance) })
	notifyPhase(instance, transition)
	-- A zero-length activation establishes on the same frame.
	for _, next_ in DomainInstance.Advance(instance, now) do
		handleTransition(instance, next_, now)
	end
	return id, nil
end

-- AttackRequestSystem.OnSwingAccepted's subscriber: a domain move's swing was committed.
function DomainSystem.NoteSwingAccepted(
	model: Model,
	swing: { MoveId: string, StartedAt: number, WindupSeconds: number }
): ()
	if not domainMoves[swing.MoveId] then
		return
	end
	local spec = ports.GetMove(swing.MoveId)
	if spec == nil then
		return
	end
	-- PENDED, not opened: the realm is the move's extension and begins when the move's windup ends
	-- (processPendingCasts). The spec is held as it was at acceptance -- a Move Editor save mid-windup must
	-- not change the realm this swing was thrown with.
	table.insert(pendingCasts, {
		Owner = model,
		MoveId = swing.MoveId,
		Spec = spec,
		StartedAt = swing.StartedAt,
		WindupSeconds = swing.WindupSeconds,
	})
end

-- Ends a realm early (an admin action, a spec). Returns whether the id named a live realm.
function DomainSystem.Collapse(id: string, reason: string?, now: number?): boolean
	local instance = byId[id]
	if instance == nil or not DomainInstance.IsLive(instance) then
		return false
	end
	collapse(instance, now or clock(), reason or "Collapsed")
	return true
end

-- Queries ---------------------------------------------------------------------------------------------------

export type Snapshot = {
	Id: string,
	Owner: Model,
	MoveId: string,
	Phase: DomainInstance.Phase,
	OpenedAt: number,
	PhaseEndsAt: number,
	Center: Vector3,
	Radius: number,
	Members: { Model },
	ClashState: string,
	CollapseReason: string?,
	Eroded: number,
}

local function snapshotOf(instance: DomainInstance): Snapshot
	local members: { Model } = {}
	for body in instance.Members do
		table.insert(members, body)
	end
	return {
		Id = instance.Id,
		Owner = instance.Owner,
		MoveId = instance.MoveId,
		Phase = instance.Phase,
		OpenedAt = instance.OpenedAt,
		PhaseEndsAt = instance.PhaseEndsAt,
		Center = instance.Center,
		Radius = instance.Spec.Radius,
		Members = members,
		ClashState = instance.ClashState,
		CollapseReason = instance.CollapseReason,
		Eroded = instance.Eroded,
	}
end

-- A read-only view of one realm (a fresh table), or nil once it has finished.
function DomainSystem.Get(id: string): Snapshot?
	local instance = byId[id]
	return if instance then snapshotOf(instance) else nil
end

function DomainSystem.GetAll(): { Snapshot }
	local result: { Snapshot } = {}
	for _, instance in instances do
		table.insert(result, snapshotOf(instance))
	end
	return result
end

-- The realm `owner` currently owns, or nil.
function DomainSystem.GetOwned(owner: Model): Snapshot?
	for _, instance in instances do
		if instance.Owner == owner then
			return snapshotOf(instance)
		end
	end
	return nil
end

function DomainSystem.LiveCount(): number
	return #instances
end

-- Every lifecycle transition of every realm, including the Erode notices (From == To == "Active").
-- Returns a disconnect function.
function DomainSystem.OnPhaseChanged(callback: (id: string, transition: Transition) -> ()): () -> ()
	return phaseListeners:Connect(callback)
end

-- The shared-clock time of an instance-clock moment -- for a spec reading a rule lease against its own
-- synthetic clock.
function DomainSystem.ServerTimeOf(at: number): number
	return serverTimeOf(at)
end

-- Boot ------------------------------------------------------------------------------------------------------

local function rebuildDomainMoves(): ()
	table.clear(domainMoves)
	for _, move in MoveRegistryManager.List() do
		if move.Domain then
			domainMoves[move.MoveId] = true
		end
	end
end

local function trackCombatant(instance: Instance): ()
	if instance:IsA("Model") then
		combatants[instance] = true
	end
end

local function handleRequest(player: Player): ()
	if requestLimiter:IsLimited(player) then
		return
	end
	local remote = stateRemote
	if remote == nil then
		return
	end
	local views: { DomainView } = {}
	for _, instance in instances do
		if instance.Phase ~= "Finished" then
			table.insert(views, viewOf(instance))
		end
	end
	remote:FireClient(player, { Kind = "Snapshot", Domains = views } :: DomainMessage)
end

function DomainSystem.Init(): ()
	if started then
		return
	end
	started = true

	stateRemote = NetworkBridge.CreateRemoteEvent(DomainConstants.Network.RemoteNames.State)
	local requestRemote = NetworkBridge.CreateRemoteEvent(DomainConstants.Network.RemoteNames.Request)
	trove:Connect(requestRemote.OnServerEvent, handleRequest)
	trove:Connect(Players.PlayerRemoving, function(player: Player)
		requestLimiter:Clear(player)
	end)

	for _, tagged in CollectionService:GetTagged(HitboxEngineConstants.CombatantTag) do
		trackCombatant(tagged)
	end
	trove:Connect(CollectionService:GetInstanceAddedSignal(HitboxEngineConstants.CombatantTag), trackCombatant)
	trove:Connect(CollectionService:GetInstanceRemovedSignal(HitboxEngineConstants.CombatantTag), function(instance)
		if instance:IsA("Model") then
			combatants[instance] = nil
		end
	end)

	rebuildDomainMoves()
	trove:Add(MoveRegistryManager.OnChanged(function(moveId: string)
		local move = MoveRegistryManager.Get(moveId)
		domainMoves[moveId] = if move and move.Domain then true else nil
	end))

	trove:Add(AttackRequestSystem.OnSwingAccepted(function(model: Model, swing)
		DomainSystem.NoteSwingAccepted(model, swing)
	end))

	trove:Add(CombatTick.Register("DomainSystem", DomainSystem.Step))
end

-- Collapses every realm at once and stops. A realm mid-life at shutdown has its law lifted, so no body is
-- left carrying rules after the System that wrote them is gone.
function DomainSystem.Shutdown(): ()
	table.clear(pendingCasts)
	local now = clock()
	for _, instance in table.clone(instances) do
		if instance.Phase ~= "Finished" then
			if DomainInstance.IsLive(instance) then
				liftLaw(instance)
			end
			teardown(instance)
		end
	end
	recomputeGovernance(now)
	trove:Clean()
	started = false
	stateRemote = nil
	if barrierHeld then
		barrierHeld = false
		ports.SetBarrier(nil)
	end
end

-- Spec-only ------------------------------------------------------------------------------------------------

-- Everything back to a fresh module: realms dropped (their walls destroyed and every published rule
-- cleared), registries emptied, ports and clocks restored.
function DomainSystem.Reset(): ()
	for _, wall in walls do
		wall:Destroy()
	end
	table.clear(walls)
	for body in governed do
		local humanoid = CharacterUtil.HumanoidOf(body)
		if humanoid then
			DomainRules.Clear(humanoid)
		end
	end
	for _, instance in instances do
		local humanoid = CharacterUtil.HumanoidOf(instance.Owner)
		if humanoid then
			DomainRules.SetOwned(humanoid, nil)
		end
	end
	table.clear(governed)
	table.clear(pendingCasts)
	table.clear(instances)
	table.clear(byId)
	table.clear(randoms)
	table.clear(offsets)
	table.clear(castSwings)
	table.clear(bounds)
	table.clear(lastErosionNotice)
	table.clear(shotBudgets)
	table.clear(upkeepOwed)
	table.clear(clashes)
	table.clear(combatants)
	table.clear(domainMoves)
	phaseListeners:Clear()
	if barrierHeld then
		ports.SetBarrier(nil)
	end
	barrierHeld = false
	membershipAccumulator = 0
	nextSerial = 0
	ports = defaultPorts
	clock = os.clock
	serverClock = DomainRules.ServerNow
	DomainEffects.ResetForTesting()
end

-- Swaps any subset of the ports for stubs (see Ports). Reset restores them.
function DomainSystem.SetPortsForTesting(overrides: { [string]: any }): ()
	local merged = table.clone(defaultPorts) :: any
	for key, value in overrides do
		merged[key] = value
	end
	ports = merged :: Ports
end

function DomainSystem.SetClocksForTesting(instanceClock: () -> number, sharedClock: () -> number): ()
	clock = instanceClock
	serverClock = sharedClock
end

-- Registers a body as a combatant candidate without the Combatant tag (a spec's rig).
function DomainSystem.TrackCombatantForTesting(model: Model): ()
	combatants[model] = true
end

-- Marks a MoveId as opening a realm without a registry round trip.
function DomainSystem.MarkDomainMoveForTesting(moveId: string): ()
	domainMoves[moveId] = true
end

return DomainSystem
