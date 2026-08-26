--!strict
--[[
	GrabSystem.lua

	Owns: the hold and the throw, end to end -- attaching a grabbed victim to the attacker's fist, the
	hold's lifetime (an auto-release safety timer), the throw (destroying the hold's constraints and
	handing the victim a real ballistic velocity), impact detection during flight, applying the throw's
	own impact/self damage directly, and returning control on release/landing/disconnect.

	    HitboxEngine     where the volume is, who is inside it
	    DefenseSystem    what kind of hit that was
	    DamageSystem     how much it hurts, what it does to you
	    GrabSystem       what happens instead of ordinary knockback, when a move says so   <- this module

	A SIBLING OF THE ATTACK LAYER, NOT A FIFTH LAYER STACKED ON TOP. It subscribes to
	DamageSystem.OnApplied exactly the way that function's own header names as its intended use
	("RewardSystem, AchievementSystem, and eventually kill attribution"), and it is READ by
	Server/Combat/Attack/AttackRequestSystem.Throw the same way DefenseSystem.CanAttack/
	DamageSystem.CanAttack already are -- one more gate of the identical shape. Neither of those two
	existing layers gained a new dependency to make this possible; the seams (OnApplied, the CanAttack
	contract) were already there, built for exactly this kind of extension.

	A GRAB IS AUTHORED, NOT A NEW ATTACK KIND. Any Basic/Heavy/Hotbar move can carry an optional
	MoveTypes.MoveGrabConfig sub-table -- the same "Enable X" toggle pattern Knockback's own Move
	Editor section already uses. This module never sees an AttackRequest, a MoveDefinition or a
	hitbox; it only ever sees DamageResult.Grab, already resolved by DamageResolver in the same
	Clean/Backstab/GuardBroken branches that resolve Knockback. A successful block/parry already
	prevents a grab from landing at the correct existing layer, for free, because DefenseSystem
	decides the outcome kind before this module ever hears about the hit.

	WHY A PLAYER'S BODY NEEDS PlatformStand + SetNetworkOwner AT ALL. A real player's character is
	client-network-owned: the owning client simulates its own physics and replicates the result, so a
	bare server CFrame/velocity write on it is silently overwritten by the owner's own next replicated
	frame -- DamageSystem.lua's AttackerLunge paragraph and AdminActionSystem.ApplyFlying's header both
	spell this out from two different angles. The fix this codebase already uses for exactly this
	problem (AdminActionSystem.SetFlying, pcall-guarded the identical way here) is PlatformStand = true
	(suspends the Humanoid's own ground-movement state so the root part behaves as a free physics body)
	plus an explicit BasePart:SetNetworkOwner(nil) to hand the part to the SERVER -- only then does a
	server-driven AlignPosition/AlignOrientation constraint, or a velocity write, actually stick. This
	is new territory (nothing before this attached or launched a player's body), but the technique is
	not; it is the deleted RagdollController.HoldAloft's own closest prior art, referenced only in
	comments today (CombatTypes.lua, Movement.lua) -- the same server-side pin, the same "leave the
	victim's own Humanoid/Motor6D control intact, this is not a ragdoll" posture.

	MOVEMENT LOCK REUSES TWO EXISTING SEAMS, NEITHER OF WHICH THIS MODULE OWNS:
	  * Constants.Attributes.RootControlLocked -- the exact Attribute ParkourController.
	    resolveCombatOwned already polls generically as "something else owns this body right now" (its
	    own header lists a HoldAloft pin as one of the historical legitimate setters). Set on the
	    victim while held OR in flight; parks client-side parkour for free, no ParkourController edit.
	  * Constants.Attributes.Grabbed -- a NEW boolean, added to RunSystem.isMovementLocked's existing
	    tier list, because RootControlLocked has never carried WalkSpeed-zeroing semantics in this
	    codebase (a dedicated Attribute always did that job -- see CombatTypes.lua's own
	    airComboChaseExpiry). Pins the victim's WalkSpeed to 0 while held or in flight.
	Neither Attribute is interpreted anywhere else by this module -- RunSystem/ParkourController read
	them generically, exactly as they already do for every other setter.

	GATING WHO MAY ACT: GrabSystem.CanAttack(model, now) is the third gate AttackRequestSystem.Throw
	asks, alongside DefenseSystem.CanAttack and DamageSystem.CanAttack -- same shape, same "two
	systems, neither knows the other exists" posture. Refuses a holding ATTACKER (must Throw or wait
	the hold out) and a held-or-thrown VICTIM. Nothing here refuses a hold's own START: that is decided
	entirely by DamageResolver handing this module a Grab profile on a landed hit, already gated by the
	same Clean/Backstab/GuardBroken conditions Knockback requires.

	IMPACT DETECTION IS A SMALL SWEPT CHECK THIS MODULE OWNS OUTRIGHT, written fresh rather than
	reviving the orphaned ObjectStunResolver.lua -- that module's whole design is proving a KNOCKBACK
	caused an impact against a target that is still otherwise playing normally, with its own causation
	gates (clearance, minimum travel, impact angle...). A grab throw is a simpler question -- did the
	ballistic body this module is already the sole owner of just hit the ground or someone else -- asked
	fresh every Step against the thrown victim's own current position, no causation gates needed because
	there is no ambiguity about what launched them. Applies ThrowImpactDamage/ThrowSelfDamage directly
	via Humanoid:TakeDamage -- a new kind of contact this module owns outright rather than forcing back
	through the hitbox/defense pipeline, the same way DamageConstants.AttackerLunge is a self-contained
	side effect DamageSystem applies directly rather than routing through HitboxEngine.

	NO REGISTRY, same reasoning as DamageSystem's own header: everything this module needs about a
	combatant (their Humanoid, their root, whether they are still alive) is derivable from the Model
	DamageSystem.OnApplied hands it or the Model AttackRequestSystem/the remote hands it, and the only
	state kept (holds, heldBy, flights) is reclaimed by Step's own model.Parent==nil sweep -- the same
	convention every System in this stack uses rather than a CharacterRemoving listener per combatant.

	Does not own: whether a move is authored as a grab (the Move Creation System, via MoveTypes.
	MoveGrabConfig), what a landed hit costs before the grab side effect begins (DamageResolver --
	Damage/GuardDrain/HitstunSeconds are entirely unaffected by Grab being present), contact detection
	or outcome classification (HitboxEngine/DefenseSystem), or presentation
	(Client/Combat/GrabInputClient.lua).
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local Constants = require(ReplicatedStorage.Shared.Constants)
local DamageTypes = require(ReplicatedStorage.Shared.Damage.DamageTypes)
local DefenseTypes = require(ReplicatedStorage.Shared.Defense.DefenseTypes)
local GrabConstants = require(ReplicatedStorage.Shared.Grab.GrabConstants)
local GrabTypes = require(ReplicatedStorage.Shared.Grab.GrabTypes)
local HitboxEngineConstants = require(ReplicatedStorage.Shared.HitboxEngine.HitboxEngineConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local Trove = require(ReplicatedStorage.Shared.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local DamageSystem = require(script.Parent.Parent.Damage.DamageSystem)

type DefenseOutcome = DefenseTypes.DefenseOutcome
type DamageResult = DamageTypes.DamageResult
type MoveGrabConfig = MoveTypes.MoveGrabConfig
type GrabRole = GrabTypes.GrabRole

local logger = Logger.scope("GrabSystem")

local GrabSystem = {}

-- One hold per attacker -- the CanAttack gate below is what makes "already holding someone" refuse a
-- second one before beginHold would ever see it, so this table structurally cannot hold two entries
-- for the same attacker.
type Hold = {
	Victim: Model,
	VictimHumanoid: Humanoid,
	VictimRoot: BasePart,
	AttackerHumanoid: Humanoid,
	Config: MoveGrabConfig,
	ExpiresAt: number,
	AttackerAttachment: Attachment,
	VictimAttachment: Attachment,
	AlignPosition: AlignPosition,
	AlignOrientation: AlignOrientation,
}

-- One flight per thrown victim -- Attacker is carried for impact-damage attribution only; the flight
-- itself has no dependency on the attacker's character still existing (see Step's own sweep).
type Flight = {
	Attacker: Model,
	VictimHumanoid: Humanoid,
	VictimRoot: BasePart,
	Config: MoveGrabConfig,
	ExpiresAt: number,
	LastPosition: Vector3,
}

local holds: { [Model]: Hold } = {}
-- Reverse index, victim -> attacker, kept ONLY for the duration of a hold (not a flight -- a thrown
-- victim is tracked in `flights` instead, see Throw below) -- what makes GrabSystem.CanAttack an O(1)
-- lookup for "is this model somebody's held victim right now" without scanning every hold.
local heldBy: { [Model]: Model } = {}
local flights: { [Model]: Flight } = {}

local started = false
local heartbeatTrove = Trove.New()
local appliedDisconnect: (() -> ())? = nil
local throwRemote: RemoteEvent? = nil
local holdChangedRemote: RemoteEvent? = nil
local throwRateLimiter = RateLimiter.New(GrabConstants.Network.MaxThrowsPerSecondPerPlayer)

-- stepFlight's query state, hoisted to module scope and reused every frame -- mirrors
-- CandidateGatherer.lua's "one shared OverlapParams for the whole engine" discipline. stepFlight used
-- to allocate a fresh OverlapParams, a fresh RaycastParams, a fresh {victim, attacker} filter table
-- AND a fresh CollectionService:GetTagged() array on EVERY frame for EVERY in-flight throw. Reuse is
-- safe because GrabSystem.Step runs flights sequentially, never concurrently, so there is never more
-- than one stepFlight call touching this state at a time.
local combatantOverlapParams = OverlapParams.new()
combatantOverlapParams.FilterType = Enum.RaycastFilterType.Include
combatantOverlapParams.RespectCanCollide = false

local groundRayParams = RaycastParams.new()
groundRayParams.FilterType = Enum.RaycastFilterType.Exclude
groundRayParams.RespectCanCollide = true
-- Reused 2-element filter for the ground raycast -- overwritten (not reallocated) per flight.
local groundRayFilter: { Instance } = { false :: any, false :: any }

-- Tagged-combatant list backing combatantOverlapParams, kept in sync with HitboxEngine's own
-- Register/UnregisterCombatant tagging (see HitboxEngine.lua's CombatantTag usage) via the tag's
-- Added/Removed signals rather than re-querying CollectionService every frame -- registration churn
-- is a spawn or a death, not a frame event, the same reasoning CandidateGatherer.SetRegisteredModels'
-- own header gives for pushing updates rather than polling.
--
-- Wired at module load, not inside GrabSystem.Init(): HitboxEngine.RegisterCombatant tags a model the
-- moment it is called, independent of whether GrabSystem.Init() has ever run (GrabSystem.spec.lua, like
-- every combat spec, deliberately never calls Init -- see that file's own header). Subscribing here
-- instead keeps this list correct under both the real Main.server.lua boot order and a spec's own
-- synthetic Step-driven one.
local taggedCombatants: { Instance } = CollectionService:GetTagged(HitboxEngineConstants.CombatantTag)
combatantOverlapParams.FilterDescendantsInstances = taggedCombatants
CollectionService:GetInstanceAddedSignal(HitboxEngineConstants.CombatantTag):Connect(function(instance: Instance)
	table.insert(taggedCombatants, instance)
end)
CollectionService:GetInstanceRemovedSignal(HitboxEngineConstants.CombatantTag):Connect(function(instance: Instance)
	local index = table.find(taggedCombatants, instance)
	if index then
		-- Swap-with-last removal -- order doesn't matter for a filter list, same reasoning
		-- HitboxEngine's own engaged-swing removal uses.
		local last = #taggedCombatants
		taggedCombatants[index] = taggedCombatants[last]
		taggedCombatants[last] = nil
	end
end)

-- Helpers ------------------------------------------------------------------------------------------

local function debugLog(flag: boolean, message: string, data: { [string]: any }?): ()
	if GrabConstants.Debug.Enabled and flag then
		logger:debug(message, data)
	end
end

-- Which BasePart on `character` a hold pins a victim to, or attaches its own anchor onto for a would-
-- be attacker. See GrabConstants.HandPartNames' own header for the R15/R6/fallback order.
local function resolveAttachPart(character: Model): BasePart?
	for _, name in GrabConstants.HandPartNames do
		local part = character:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			return part
		end
	end
	return character.PrimaryPart
end

-- Tells one participant the hold/flight just started or ended. Silently does nothing for a bot or a
-- dummy, which have no player to tell -- the same "not every combatant is a Player" tolerance every
-- other module in this stack keeps.
local function sendHoldChanged(model: Model, role: GrabRole, active: boolean): ()
	local remote = holdChangedRemote
	if not remote then
		return
	end
	local player = Players:GetPlayerFromCharacter(model)
	if not player then
		return
	end
	remote:FireClient(player, { Role = role, Active = active } :: GrabTypes.GrabHoldChangedPayload)
end

-- Hands PlatformStand/network ownership/the Attributes back to a victim who is regaining control --
-- shared by a dropped hold, a landed throw, and the disconnect sweep. Never called for a victim about
-- to fly instead (Throw destroys the hold rig but deliberately leaves PlatformStand/ownership/
-- Attributes in place -- see Throw's own comment).
local function restoreControl(humanoid: Humanoid, rootPart: BasePart?): ()
	if humanoid.Parent ~= nil then
		humanoid.PlatformStand = false
		humanoid:SetAttribute(Constants.Attributes.RootControlLocked, nil)
		humanoid:SetAttribute(Constants.Attributes.Grabbed, nil)
	end
	if rootPart and rootPart.Parent ~= nil then
		-- pcall-guarded the same way AdminActionSystem.SetFlying's own SetNetworkOwnershipAuto call is
		-- -- an already-anchored or already-destroyed part can throw here.
		pcall(function()
			rootPart:SetNetworkOwnershipAuto()
		end)
	end
end

-- Destroys a hold's constraints/attachments only -- never touches PlatformStand, network ownership or
-- Attributes, because the two callers disagree about what should happen to those afterwards
-- (releaseHold hands control back immediately; Throw hands the body a velocity and keeps it server-
-- pinned through the flight instead).
local function destroyHoldRig(hold: Hold): ()
	hold.AlignPosition:Destroy()
	hold.AlignOrientation:Destroy()
	hold.VictimAttachment:Destroy()
	hold.AttackerAttachment:Destroy()
end

-- Begin / release ------------------------------------------------------------------------------------

-- Starts a hold. Called only from the DamageSystem.OnApplied subscription below, and silently
-- declines rather than erroring for every precondition that isn't met -- a grab that can't begin is
-- not a bug in the hit that triggered it, the ordinary Clean/Backstab/GuardBroken damage/posture/
-- hitstun already resolved by DamageResolver still applies regardless of whether this side effect
-- fires.
local function beginHold(attacker: Model, victim: Model, config: MoveGrabConfig, now: number): ()
	if attacker == victim then
		return
	end
	-- Already holding someone -- see GrabSystem.CanAttack's own header on why this should be
	-- structurally unreachable via the attack layer (a holding attacker cannot throw another attack),
	-- but a hotbar move or a bot's own direct HitboxEngine.RequestAttack call bypasses that gate, so
	-- this is the backstop.
	if holds[attacker] then
		return
	end
	-- The victim is already somebody else's hold or already in flight.
	if heldBy[victim] or flights[victim] then
		return
	end

	local attackerHumanoid = CharacterUtil.LiveHumanoidOf(attacker)
	local victimHumanoid = CharacterUtil.LiveHumanoidOf(victim)
	if not attackerHumanoid or not victimHumanoid then
		return
	end
	-- A body welded to a blimp station (Server/Systems/BlimpSystem.lua) cannot be held. This is not a
	-- balance call, it is a physical one: a mount is a rigid Weld into the hull's assembly and a hold is
	-- an AlignPosition dragging the same root toward a fist, so honouring both would have the two fight
	-- every physics step -- and whichever won, the mount's own release path would be operating on a body
	-- it no longer describes. Refused at the START rather than by yanking the victim off the blimp,
	-- because the attacker landing a hit on a passenger has no business dismounting them.
	--
	-- Read as an Attribute, not through a BlimpSystem require, the same seam AttackRequestSystem's and
	-- DefenseSystem's own Mounted gates use.
	if victimHumanoid:GetAttribute(Constants.Attributes.Mounted) == true then
		return
	end
	local attackerAttachPart = resolveAttachPart(attacker)
	local victimRoot = victim.PrimaryPart
	if not attackerAttachPart or not victimRoot then
		return
	end

	victimHumanoid.PlatformStand = true
	-- pcall-guarded the same way AdminActionSystem.SetFlying's own SetNetworkOwner call is --
	-- SetNetworkOwner throws on an anchored or otherwise ungrounded part.
	pcall(function()
		victimRoot:SetNetworkOwner(nil)
	end)

	local attackerAttachment = Instance.new("Attachment")
	attackerAttachment.Name = "GrabAnchor"
	attackerAttachment.CFrame = config.AttachOffset
	attackerAttachment.Parent = attackerAttachPart

	local victimAttachment = Instance.new("Attachment")
	victimAttachment.Name = "GrabTarget"
	victimAttachment.Parent = victimRoot

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Name = "GrabAlignPosition"
	alignPosition.Attachment0 = victimAttachment
	alignPosition.Attachment1 = attackerAttachment
	alignPosition.MaxForce = GrabConstants.Hold.MaxForce
	alignPosition.Responsiveness = GrabConstants.Hold.PositionResponsiveness
	alignPosition.RigidityEnabled = false
	alignPosition.Parent = victimRoot

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = "GrabAlignOrientation"
	alignOrientation.Attachment0 = victimAttachment
	alignOrientation.Attachment1 = attackerAttachment
	alignOrientation.MaxTorque = GrabConstants.Hold.MaxTorque
	alignOrientation.Responsiveness = GrabConstants.Hold.OrientationResponsiveness
	alignOrientation.RigidityEnabled = false
	alignOrientation.Parent = victimRoot

	attackerHumanoid:SetAttribute(Constants.Attributes.Grabbing, true)
	victimHumanoid:SetAttribute(Constants.Attributes.Grabbed, true)
	victimHumanoid:SetAttribute(Constants.Attributes.RootControlLocked, true)

	holds[attacker] = {
		Victim = victim,
		VictimHumanoid = victimHumanoid,
		VictimRoot = victimRoot,
		AttackerHumanoid = attackerHumanoid,
		Config = config,
		ExpiresAt = now + config.HoldSeconds,
		AttackerAttachment = attackerAttachment,
		VictimAttachment = victimAttachment,
		AlignPosition = alignPosition,
		AlignOrientation = alignOrientation,
	}
	heldBy[victim] = attacker

	sendHoldChanged(attacker, "Attacker", true)
	sendHoldChanged(victim, "Victim", true)

	debugLog(
		GrabConstants.Debug.LogHoldStarted,
		"Grab hold started",
		{ attacker = attacker.Name, victim = victim.Name }
	)
end

-- Drops the victim where they stand and hands control back to both sides -- the auto-release safety
-- timer, and the disconnect/death backstop Step's own sweep calls this for. Never applies any damage:
-- a dropped hold is not a throw, it is the hold simply not happening any more.
local function releaseHold(attacker: Model, hold: Hold): ()
	holds[attacker] = nil
	heldBy[hold.Victim] = nil

	destroyHoldRig(hold)

	if hold.AttackerHumanoid.Parent ~= nil then
		hold.AttackerHumanoid:SetAttribute(Constants.Attributes.Grabbing, nil)
	end
	restoreControl(hold.VictimHumanoid, hold.VictimRoot)

	sendHoldChanged(attacker, "Attacker", false)
	sendHoldChanged(hold.Victim, "Victim", false)

	debugLog(GrabConstants.Debug.LogHoldReleased, "Grab hold released", { attacker = attacker.Name })
end

-- Throw ----------------------------------------------------------------------------------------------

-- Ends the hold and launches the victim. PUBLIC, so a bot's decision-making (or a scripted boss beat)
-- can throw through exactly the same path a player's press does -- the same "public function the
-- remote calls, so nothing needs a special case" convention DefenseSystem.SetBlocking/
-- AttackRequestSystem.Press are exposed alongside their own remote handlers for.
function GrabSystem.Throw(attackerModel: Model, now: number): (boolean, string?)
	local hold = holds[attackerModel]
	if not hold then
		return false, "NotHolding"
	end
	if hold.VictimRoot.Parent == nil or hold.VictimHumanoid.Parent == nil then
		releaseHold(attackerModel, hold)
		return false, "NoCharacter"
	end

	-- The attacker's own root CFrame, not the hand attachment's -- consistent with every other
	-- facing-relative effect in this combat stack (DamageConstants.AttackerLunge, every authored
	-- move's own root-relative Offset), and immune to whatever orientation an in-progress animation
	-- happens to have left the hand part in.
	local attackerRoot = attackerModel.PrimaryPart
	local lookVector = if attackerRoot then attackerRoot.CFrame.LookVector else Vector3.new(0, 0, -1)

	local config = hold.Config
	holds[attackerModel] = nil
	heldBy[hold.Victim] = nil
	destroyHoldRig(hold)

	if hold.AttackerHumanoid.Parent ~= nil then
		hold.AttackerHumanoid:SetAttribute(Constants.Attributes.Grabbing, nil)
	end
	sendHoldChanged(attackerModel, "Attacker", false)
	-- Deliberately NO sendHoldChanged for the victim here: Constants.Attributes.Grabbed spans the whole
	-- hold-then-flight lifetime (see this file's header), and so does the "GRABBED" client cue it
	-- drives -- the victim's own Active=false fires once, on landing, not twice.

	-- The victim's body stays PlatformStand + server-network-owned (both already set by beginHold) --
	-- only the constraints that were pinning it to the attacker's fist are gone. Real Roblox gravity
	-- now carries the arc; this module only has to watch for where it ends.
	local velocity = lookVector * config.ThrowHorizontalVelocity + Vector3.new(0, config.ThrowUpVelocity, 0)
	hold.VictimRoot.AssemblyLinearVelocity = velocity

	flights[hold.Victim] = {
		Attacker = attackerModel,
		VictimHumanoid = hold.VictimHumanoid,
		VictimRoot = hold.VictimRoot,
		Config = config,
		ExpiresAt = now + GrabConstants.Impact.MaxFlightSeconds,
		LastPosition = hold.VictimRoot.Position,
	}

	debugLog(
		GrabConstants.Debug.LogHoldReleased,
		"Grab thrown",
		{ attacker = attackerModel.Name, victim = hold.Victim.Name }
	)
	return true, nil
end

-- Impact -----------------------------------------------------------------------------------------

-- Ends a flight, applying its own damage and handing control back. `impactTarget` is the other
-- combatant the thrown body collided with, or nil for a plain landing on geometry / the safety
-- timeout.
local function landFlight(victim: Model, flight: Flight, impactTarget: Model?): ()
	flights[victim] = nil

	if
		flight.VictimHumanoid.Parent ~= nil
		and flight.VictimHumanoid.Health > 0
		and flight.Config.ThrowSelfDamage > 0
	then
		flight.VictimHumanoid:TakeDamage(flight.Config.ThrowSelfDamage)
	end
	if impactTarget and flight.Config.ThrowImpactDamage > 0 then
		local targetHumanoid = CharacterUtil.LiveHumanoidOf(impactTarget)
		if targetHumanoid then
			targetHumanoid:TakeDamage(flight.Config.ThrowImpactDamage)
		end
	end

	if flight.VictimRoot.Parent ~= nil then
		-- Stops the body dead rather than letting it keep sliding under whatever velocity remained --
		-- a thrown body that skids through the landing reads as still being thrown, not as having
		-- landed.
		flight.VictimRoot.AssemblyLinearVelocity = Vector3.zero
	end
	restoreControl(flight.VictimHumanoid, flight.VictimRoot)
	sendHoldChanged(victim, "Victim", false)

	debugLog(GrabConstants.Debug.LogThrowLanded, "Grab throw landed", {
		victim = victim.Name,
		impactTarget = if impactTarget then impactTarget.Name else nil,
	})
end

-- One flight's own small swept check, run every Step -- see this file's header on why this is written
-- fresh rather than reviving ObjectStunResolver.lua. Two independent tests, either one ends the
-- flight:
--   * a nearby registered combatant (a player-collision impact), and
--   * a ray swept from last frame's position to this one (a ground/geometry impact) -- swept rather
--     than a single point sample so a fast throw cannot tunnel an entire floor between two Heartbeats,
--     the identical reasoning HitboxEngineConstants' own substep system exists for.
local function stepFlight(victim: Model, flight: Flight, now: number): ()
	if victim.Parent == nil or flight.VictimRoot.Parent == nil or flight.VictimHumanoid.Parent == nil then
		flights[victim] = nil
		return
	end
	if flight.VictimHumanoid.Health <= 0 then
		-- Death takes over from here (Humanoid.Died, PlayerDeathSystem) -- this module just stops
		-- tracking a flight for a body that no longer needs to land anywhere.
		flights[victim] = nil
		return
	end
	if now >= flight.ExpiresAt then
		landFlight(victim, flight, nil)
		return
	end

	local currentPosition = flight.VictimRoot.Position

	local nearbyParts = Workspace:GetPartBoundsInRadius(
		currentPosition,
		GrabConstants.Impact.CollisionRadiusStuds,
		combatantOverlapParams
	)
	for _, part in ipairs(nearbyParts) do
		local model = part:FindFirstAncestorOfClass("Model")
		if model and model ~= victim and model ~= flight.Attacker then
			local candidateHumanoid = CharacterUtil.LiveHumanoidOf(model)
			if candidateHumanoid then
				landFlight(victim, flight, model)
				return
			end
		end
	end

	local lastPosition = flight.LastPosition
	local delta = currentPosition - lastPosition
	local travelled = delta.Magnitude
	local alreadyGrounded = flight.VictimHumanoid.FloorMaterial ~= Enum.Material.Air
	if travelled > 1e-3 or alreadyGrounded then
		groundRayFilter[1] = victim
		groundRayFilter[2] = flight.Attacker
		groundRayParams.FilterDescendantsInstances = groundRayFilter
		local direction = if travelled > 1e-3 then delta.Unit else Vector3.new(0, -1, 0)
		local castDistance = travelled + GrabConstants.Impact.GroundProbeExtraStuds
		local result = Workspace:Raycast(lastPosition, direction * castDistance, groundRayParams)
		if result or alreadyGrounded then
			landFlight(victim, flight, nil)
			return
		end
	end

	flight.LastPosition = currentPosition
end

-- The loop -----------------------------------------------------------------------------------------

-- One frame. `now` is the caller's clock, matching every other System's Step in this stack.
-- DELIBERATELY FULL WALKS, both of them -- the one place in this stack that did NOT get an amortised
-- reclaim cursor when AttackRequestSystem/SwingSequencer/DamageSystem did. Neither loop below is a
-- reclaim: the first RELEASES a hold when its expiry passes (skipping an entry would leave a victim
-- pinned past the window), and the second advances flight physics on every entry (skipping one is a
-- dropped frame of motion). Both tables are also bounded by "grabs actually in progress right now",
-- which on any real server is a handful, so the full walk was never the cost. See
-- Shared/AmortizedReclaim.lua's header on why a sweep that does per-entry work must not be amortised.
function GrabSystem.Step(_deltaTime: number, now: number): ()
	for attacker, hold in holds do
		local attackerGone = attacker.Parent == nil
			or hold.AttackerHumanoid.Parent == nil
			or hold.AttackerHumanoid.Health <= 0
		local victimGone = hold.Victim.Parent == nil
			or hold.VictimHumanoid.Parent == nil
			or hold.VictimHumanoid.Health <= 0
		if attackerGone or victimGone or now >= hold.ExpiresAt then
			releaseHold(attacker, hold)
		end
	end

	for victim, flight in flights do
		stepFlight(victim, flight, now)
	end
end

-- Public queries -----------------------------------------------------------------------------------

-- Whether this combatant may start an ordinary attack, and why not when they may not.
--
-- The attack layer consults this ALONGSIDE DefenseSystem.CanAttack and DamageSystem.CanAttack, not
-- instead of either: those answer "are you staggered or guarding" and "are you reeling from a hit",
-- this one answers "is a grab currently committing your body, on either end of it." Three questions,
-- three owners, none of them merged into a shared notion of "can act."
-- `now` is accepted but not read -- kept in the signature to match DamageSystem.CanAttack(model, now)'s
-- own call shape (AttackRequestSystem.Throw calls all three gates identically), even though this
-- module never needs a clock to answer: `holds`/`heldBy`/`flights` only ever contain a LIVE
-- hold/flight, since Step's own sweep evicts a stale one the moment its own expiry passes, every frame,
-- before any caller could observe it lingering.
function GrabSystem.CanAttack(model: Model, _now: number): (boolean, string?)
	if holds[model] then
		return false, "Grabbing"
	end
	if heldBy[model] ~= nil or flights[model] ~= nil then
		return false, "Grabbed"
	end
	return true, nil
end

function GrabSystem.IsHolding(model: Model): boolean
	return holds[model] ~= nil
end

function GrabSystem.IsHeld(model: Model): boolean
	return heldBy[model] ~= nil
end

function GrabSystem.IsInFlight(model: Model): boolean
	return flights[model] ~= nil
end

-- Lifecycle ----------------------------------------------------------------------------------------

local function onDamageApplied(outcome: DefenseOutcome, result: DamageResult): ()
	local config = result.Grab
	if not config then
		return
	end
	beginHold(outcome.Attacker, outcome.Defender, config, outcome.SampleTime)
end

-- Subscribes to the damage layer's outcome signal, and nothing else. Split out of Init for the same
-- reason DamageSystem.Attach/DefenseSystem.Attach are: a spec has to drive this system on a synthetic
-- clock, and it cannot do that if the only way to receive applied hits is to also start a real
-- Heartbeat racing its own Step calls. Idempotent.
function GrabSystem.Attach(): ()
	if appliedDisconnect then
		return
	end
	appliedDisconnect = DamageSystem.OnApplied(onDamageApplied)
end

function GrabSystem.Init(): ()
	if started then
		return
	end
	-- See DamageSystem.lua's own header: Heartbeat order is a correctness property here too, though a
	-- softer one than the four layers below it -- this module's own Step only reclaims ITS OWN state
	-- (holds/flights), so an out-of-order boot costs at most one extra frame of a stale hold/flight
	-- rather than a wrong outcome. Asserted anyway for the same "a comment cannot fail a boot" reason.
	assert(DamageSystem.OnApplied ~= nil, "GrabSystem.Init() requires DamageSystem to be available")
	started = true

	throwRemote = NetworkBridge.CreateRemoteEvent(GrabConstants.Network.RemoteNames.Throw)
	throwRemote.OnServerEvent:Connect(function(player: Player)
		-- Was the one gameplay remote in this codebase with no limiter -- see
		-- GrabConstants.Network.MaxThrowsPerSecondPerPlayer's own comment. Safe to just drop rather than
		-- buffer: a dropped Throw leaves the hold intact and its own ExpiresAt safety timer still
		-- releases it, unlike a "stop"/release action RateLimiter.lua's own header warns against gating.
		if throwRateLimiter:IsLimited(player) then
			return
		end
		local character = player.Character
		if not character then
			return
		end
		local accepted, reason = GrabSystem.Throw(character, os.clock())
		if not accepted then
			debugLog(GrabConstants.Debug.LogRefused, "Grab throw refused", { player = player.Name, reason = reason })
		end
	end)
	holdChangedRemote = NetworkBridge.CreateRemoteEvent(GrabConstants.Network.RemoteNames.HoldChanged)

	GrabSystem.Attach()

	heartbeatTrove:Connect(RunService.Heartbeat, function(deltaTime: number)
		GrabSystem.Step(deltaTime, os.clock())
	end)

	-- A holding/held/thrown player disconnecting mid-hold must not leave the OTHER side stuck
	-- PlatformStand-locked forever -- Step's own sweep already covers this every frame (attacker/victim
	-- Parent==nil), but a player's Character is torn down (CharacterRemoving) on PlayerRemoving BEFORE
	-- the next Heartbeat is guaranteed to run in every ordering, so this is a same-frame backstop
	-- rather than the primary mechanism.
	Players.PlayerRemoving:Connect(function(player: Player)
		throwRateLimiter:Clear(player)
		local character = player.Character
		if not character then
			return
		end
		local hold = holds[character]
		if hold then
			releaseHold(character, hold)
		end
		local heldByAttacker = heldBy[character]
		if heldByAttacker then
			local attackersHold = holds[heldByAttacker]
			if attackersHold then
				releaseHold(heldByAttacker, attackersHold)
			end
		end
		flights[character] = nil
	end)

	logger:info("GrabSystem.Init() complete")
end

function GrabSystem.Shutdown(): ()
	heartbeatTrove:Clean()
	if appliedDisconnect then
		appliedDisconnect()
		appliedDisconnect = nil
	end
	started = false
end

-- Drops every piece of per-combatant state and every subscription. Spec-only, so one case cannot
-- serve another its state -- the same role DamageSystem.Reset/DefenseSystem.Reset/HitboxEngine.Reset
-- play for their own modules. Deliberately a hard wipe rather than a graceful releaseHold/landFlight
-- per entry: a spec Destroys its own rigs in afterEach regardless, so there is no Instance/Attribute
-- left over for this to bother cleaning up, and Reset must never itself depend on the Instances it is
-- discarding still being valid.
function GrabSystem.Reset(): ()
	if appliedDisconnect then
		appliedDisconnect()
		appliedDisconnect = nil
	end
	table.clear(holds)
	table.clear(heldBy)
	table.clear(flights)
end

return GrabSystem :: Types.SystemModule & typeof(GrabSystem)
