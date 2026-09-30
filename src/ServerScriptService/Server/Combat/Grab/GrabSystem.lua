--!strict
--[[
	GrabSystem.lua

	Owns: the hold and the throw, end to end -- welding a grabbed victim into the attacker's grip, the
	hold's lifetime (an auto-release safety timer), the throw (breaking the weld and handing the victim a
	real ballistic velocity), impact detection during flight, applying the throw's own impact/self damage
	directly, and returning control on release/landing/disconnect.

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

	THE HOLD IS A WELD INTO THE ATTACKER'S ASSEMBLY. It used to be an AlignPosition/AlignOrientation pair
	pulling a server-owned victim toward the attacker's RightHand, and that is why a grab flung people for
	a second before they "arrived": three separate faults, all of them the constraint's.
	  * A spring with a destination four studs away travels there THROUGH the attacker's body -- a
	    100000-force pull colliding with the attacker's own arm and torso, then overshooting.
	  * Two network owners on one constraint. The victim was handed to the server (SetNetworkOwner(nil))
	    while the hand it chased belonged to the ATTACKER'S client, so the server chased a hand position
	    one ping stale, and the ownership hand-off itself raced the victim client's own last frames.
	  * The target hung off the hand part, whose server-side pose is whatever the grab swing left it in,
	    so the same offset put the victim somewhere different -- often inside the attacker -- each time.
	A Weld (the victim's torso or head to the holder's hand part -- Shared/Grab/GrabRig.lua solves it) fixes
	all three at once: it lands the victim on its mark on the frame it is created, with no travel; it
	makes the victim part of the ATTACKER'S assembly, so whoever simulates the attacker (their own client,
	or the server for a bot) simulates the victim too, with no second owner to disagree and no
	SetNetworkOwner call at all; and the holder's arm is posed through its shoulder C0 (replicated, and
	pinned against animation on every client), so every grab looks the same on every machine. It is the technique Server/Vessel/
	VesselMount.lua already uses to weld a player to a hull, and this module follows its release order.
	Two things let the attacker carry the extra body without feeling it: every victim part goes Massless
	(so the attacker's root stays the assembly root and their movement is not dragged) and into
	GrabConstants.Hold.CollisionGroup, which collides with nothing. Both are recorded per part and
	restored exactly on throw or release -- see captureBody/restoreBody.

	PlatformStand IS STILL SET, for the same reason VesselMount sets it: it suspends the victim Humanoid's
	own balance/walk controller, which would otherwise push against the assembly it is now part of.

	THE THROW HANDS THE BODY TO THE SERVER. Destroying the weld makes the victim its own assembly again;
	the server takes it (SetNetworkOwner(nil)) in the same frame, before writing the launch velocity,
	because a velocity written onto a body some client owns is silently overwritten by that client's next
	replicated frame (DamageSystem.lua's AttackerLunge paragraph). The flight is therefore server-
	simulated, and control goes back on landing -- explicitly to the victim's own player, or to the server
	for a bot/dummy (SetNetworkOwnershipAuto, which this used to call, would hand a training bot to
	whichever player happened to be nearest; see TrainingBotSystem's header on why it pins its own bots).

	THE RELEASE ORDER (restoreControl) IS VesselMount.Release's, and for its reason: settle the body's
	velocity, then hand ownership back, THEN wake the Humanoid. A separated assembly inherits the velocity
	the attacker's had (a turning attacker's spin included); clearing PlatformStand before zeroing that
	re-arms the balance controller against a spin it did not cause, and the solver turns the argument into
	linear speed -- the canonical Roblox fling, one more time.

	MOVEMENT LOCK REUSES TWO EXISTING SEAMS, NEITHER OF WHICH THIS MODULE OWNS:
	  * Constants.Attributes.RootControlLocked -- the exact Attribute ParkourController.
	    resolveCombatOwned already polls generically as "something else owns this body right now" (its
	    own header lists a HoldAloft pin as one of the historical legitimate setters). Set on the
	    victim while held OR in flight; parks client-side parkour for free, no ParkourController edit.
	  * Constants.Attributes.Grabbed -- a NEW boolean, added to RunSystem.isMovementLocked's existing
	    tier list, because RootControlLocked has never carried WalkSpeed-zeroing semantics in this
	    codebase (a dedicated Attribute always did that job -- the since-deleted CombatTypes.lua's own
	    airComboChaseExpiry was the precedent). Pins the victim's WalkSpeed to 0 while held or in flight.
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
	ballistic body this module is already the sole owner of just hit the ground, a wall or someone else
	-- asked fresh every Step against the thrown victim's own current position, no causation gates needed
	because there is no ambiguity about what launched them (stepFlight lists the probes). Applies
	ThrowImpactDamage/ThrowSelfDamage directly via Humanoid:TakeDamage -- a new kind of contact this
	module owns outright rather than forcing back through the hitbox/defense pipeline, the same way
	DamageConstants.AttackerLunge is a self-contained side effect DamageSystem applies directly rather
	than routing through HitboxEngine.

	NO REGISTRY, same reasoning as DamageSystem's own header: everything this module needs about a
	combatant (their Humanoid, their root, whether they are still alive) is derivable from the Model
	DamageSystem.OnApplied hands it or the Model AttackRequestSystem/the remote hands it, and the only
	state kept (holds, heldBy, flights) is reclaimed by Step's own model.Parent==nil sweep -- the same
	convention every System in this stack uses rather than a CharacterRemoving listener per combatant.
	A hold's weld going missing (BreakJointsOnDeath, a respawn tearing a rig down mid-hold) is caught by
	the same sweep.

	THE BODY IS WELDED TO THE HAND. An earlier version welded the victim to the holder's root and posed
	the arm toward them; that only lined up while both rigs were R6-proportioned, and put an R15 dummy
	across the holder's shoulder. How a mode holds someone is data (GrabConstants.Modes: an arm direction,
	a gripped body part, a body orientation); GrabRig turns it into the weld against the real rigs.

	Does not own: whether a move is authored as a grab (the Move Creation System, via MoveTypes.
	MoveGrabConfig), what a landed hit costs before the grab side effect begins (DamageResolver --
	Damage/GuardDrain/HitstunSeconds are entirely unaffected by Grab being present), contact detection
	or outcome classification (HitboxEngine/DefenseSystem), or presentation
	(Client/Combat/GrabInputClient.lua for the cue, Client/FX/GrabHoldPose.lua for the arms).
]]

local CollectionService = game:GetService("CollectionService")
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AirComboAttributes = require(ReplicatedStorage.Shared.AirCombo.AirComboAttributes)
local AnimationManager = require(ReplicatedStorage.Shared.Animation.AnimationManager)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local Constants = require(ReplicatedStorage.Shared.Constants)
local DamageTypes = require(ReplicatedStorage.Shared.Damage.DamageTypes)
local DefenseTypes = require(ReplicatedStorage.Shared.Defense.DefenseTypes)
local GrabConstants = require(ReplicatedStorage.Shared.Grab.GrabConstants)
local GrabRig = require(ReplicatedStorage.Shared.Grab.GrabRig)
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
type ModeSpec = GrabConstants.ModeSpec
type AnimationManagerInstance = AnimationManager.AnimationManagerInstance

local logger = Logger.scope("GrabSystem")

local GrabSystem = {}

-- What a hold changed on each of the victim's parts, index-aligned, so a throw or release puts back
-- exactly what was there -- not a guess at what a character's parts "normally" are (an accessory is
-- already Massless, a custom rig may have its own collision group).
type BodySnapshot = {
	Parts: { BasePart },
	Massless: { boolean },
	CollisionGroups: { string },
}

-- One hold per attacker -- the CanAttack gate below is what makes "already holding someone" refuse a
-- second one before beginHold would ever see it, so this table structurally cannot hold two entries
-- for the same attacker.
type Hold = {
	Victim: Model,
	VictimHumanoid: Humanoid,
	VictimRoot: BasePart,
	AttackerHumanoid: Humanoid,
	AttackerRoot: BasePart,
	Config: MoveGrabConfig,
	Mode: ModeSpec,
	ExpiresAt: number,
	Weld: Weld,
	Body: BodySnapshot,
	-- The holder's posed shoulder and the C0 it had before, to put back on release (nil when the rig
	-- had no arm GrabRig could pose and the weld fell back to root-to-root).
	Shoulder: Motor6D?,
	OriginalShoulderC0: CFrame?,
	-- One per body with an authored hold clip, nil otherwise -- see playHoldClip.
	VictimAnimator: AnimationManagerInstance?,
	AttackerAnimator: AnimationManagerInstance?,
}

-- One flight per thrown victim -- Attacker is carried for impact-damage attribution and to keep the
-- thrower out of the flight's own probes; the flight itself has no dependency on the attacker's
-- character still existing (see Step's own sweep).
type Flight = {
	Attacker: Model,
	VictimHumanoid: Humanoid,
	VictimRoot: BasePart,
	Config: MoveGrabConfig,
	-- No landing probe before this -- GrabConstants.Impact.MinFlightSeconds.
	ChecksLandingAt: number,
	ExpiresAt: number,
	LastPosition: Vector3,
	-- When the body first dropped under Impact.StallSpeed, or nil while it is still moving.
	StalledSince: number?,
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

-- Query state, hoisted to module scope and reused every frame -- mirrors CandidateGatherer.lua's "one
-- shared OverlapParams for the whole engine" discipline. Reuse is safe because GrabSystem.Step runs
-- flights sequentially, never concurrently, so there is never more than one probe touching this state
-- at a time.
local combatantOverlapParams = OverlapParams.new()
combatantOverlapParams.FilterType = Enum.RaycastFilterType.Include
combatantOverlapParams.RespectCanCollide = false

local worldRayParams = RaycastParams.new()
worldRayParams.FilterType = Enum.RaycastFilterType.Exclude
worldRayParams.RespectCanCollide = true
-- Reused 2-element filter for every world ray -- overwritten (not reallocated) per use.
local worldRayFilter: { Instance } = { false :: any, false :: any }

-- The Include list for combatantOverlapParams is every model HitboxEngine has tagged as a combatant.
-- ASSIGNING FilterDescendantsInstances COPIES THE ARRAY -- the params object never sees a later edit to
-- the Lua table it was given. This used to keep a live table in sync with the tag's Added/Removed
-- signals and assign it once, at module load, before any combatant existed: the copy the engine
-- actually filtered by stayed empty for the life of the server, and a thrown body never struck anyone.
-- A dirty flag instead, re-read on the next flight probe after registration churn (a spawn or a death,
-- never a per-frame event). Wired at module load rather than in Init() because
-- HitboxEngine.RegisterCombatant tags a model whether or not Init() has run -- GrabSystem.spec.lua, like
-- every combat spec, never calls it.
local combatantFilterDirty = true
CollectionService:GetInstanceAddedSignal(HitboxEngineConstants.CombatantTag):Connect(function()
	combatantFilterDirty = true
end)
CollectionService:GetInstanceRemovedSignal(HitboxEngineConstants.CombatantTag):Connect(function()
	combatantFilterDirty = true
end)

local function refreshCombatantFilter(): ()
	if combatantFilterDirty then
		combatantFilterDirty = false
		combatantOverlapParams.FilterDescendantsInstances =
			CollectionService:GetTagged(HitboxEngineConstants.CombatantTag)
	end
end

-- nil until first asked, then whether GrabConstants.Hold.CollisionGroup is registered and usable.
-- Resolved lazily (beginHold asks) as well as eagerly in Init, for the same spec-never-calls-Init reason.
local collisionGroupReady: boolean? = nil

-- Registers the hold's collision group and switches it off against every group that exists right now,
-- itself included. A group registered LATER still collides with it (Roblox's default for a new pair);
-- nothing in this codebase registers one at runtime today.
local function ensureCollisionGroup(): boolean
	if collisionGroupReady ~= nil then
		return collisionGroupReady
	end
	local name = GrabConstants.Hold.CollisionGroup
	local ok, err = pcall(function()
		if not PhysicsService:IsCollisionGroupRegistered(name) then
			PhysicsService:RegisterCollisionGroup(name)
		end
		for _, group in PhysicsService:GetRegisteredCollisionGroups() do
			PhysicsService:CollisionGroupSetCollidable(name, group.name, false)
		end
	end)
	if not ok then
		-- Degrades rather than refuses: a hold without the group still works, it just lets the held
		-- body touch things. Warned once, since the answer is cached.
		logger:warn("Grab collision group unavailable -- held bodies keep their own collision", {
			error = tostring(err),
		})
	end
	collisionGroupReady = ok
	return ok
end

-- Helpers ------------------------------------------------------------------------------------------

local function debugLog(flag: boolean, message: string, data: { [string]: any }?): ()
	if GrabConstants.Debug.Enabled and flag then
		logger:debug(message, data)
	end
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

-- The registered combatant `part` belongs to, or nil. Walks up to the TAGGED model rather than taking
-- the nearest Model ancestor, which for a weapon or any other nested Model welded into a rig is that
-- nested Model rather than the character carrying it.
local function combatantOf(part: BasePart): Model?
	local node = part.Parent
	while node ~= nil and node ~= Workspace do
		if node:IsA("Model") and CollectionService:HasTag(node, HitboxEngineConstants.CombatantTag) then
			return node
		end
		node = node.Parent
	end
	return nil
end

local function castWorld(origin: Vector3, direction: Vector3, victim: Model, attacker: Model): RaycastResult?
	worldRayFilter[1] = victim
	worldRayFilter[2] = attacker
	worldRayParams.FilterDescendantsInstances = worldRayFilter
	return Workspace:Raycast(origin, direction, worldRayParams)
end

-- Makes every part of `victim` massless (so the attacker's root stays its assembly's root and the
-- attacker's movement does not carry the victim's weight) and, when `useGroup`, moves it into the hold's
-- collision group. Returns what it overwrote, for restoreBody. Must run BEFORE the weld is created: the
-- assembly root is chosen the moment the two assemblies join.
local function captureBody(victim: Model, useGroup: boolean): BodySnapshot
	local parts: { BasePart } = {}
	local massless: { boolean } = {}
	local groups: { string } = {}
	local groupName = GrabConstants.Hold.CollisionGroup
	for _, descendant in victim:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
			table.insert(massless, descendant.Massless)
			table.insert(groups, descendant.CollisionGroup)
			descendant.Massless = true
			if useGroup then
				descendant.CollisionGroup = groupName
			end
		end
	end
	return { Parts = parts, Massless = massless, CollisionGroups = groups }
end

local function restoreBody(body: BodySnapshot): ()
	for index, part in body.Parts do
		if part.Parent ~= nil then
			part.Massless = body.Massless[index]
			part.CollisionGroup = body.CollisionGroups[index]
		end
	end
end

-- Pulls a body that is about to get its collision back out of any wall standing between it and the
-- attacker. See GrabConstants.Hold.WallClearanceStuds on why this is needed at all. The ray is
-- extended past the victim's root by the same clearance, because a body whose root is still short of a
-- wall can have its front half inside it.
local function clearOfWalls(attacker: Model, attackerRoot: BasePart, victim: Model, victimRoot: BasePart): ()
	if attackerRoot.Parent == nil or victimRoot.Parent == nil then
		return
	end
	local origin = attackerRoot.Position
	local offset = victimRoot.Position - origin
	local distance = offset.Magnitude
	if distance < 1e-3 then
		return
	end
	local clearance = GrabConstants.Hold.WallClearanceStuds
	local direction = offset / distance
	local hit = castWorld(origin, direction * (distance + clearance), victim, attacker)
	if not hit then
		return
	end
	local safeDistance = math.max(hit.Distance - clearance, 0)
	if safeDistance < distance then
		victimRoot.CFrame += direction * (safeDistance - distance)
	end
end

-- Hands a victim back their own body -- shared by a dropped hold, a landed throw, and the disconnect
-- sweep. In VesselMount.Release's order, for its reason (this file's header, THE RELEASE ORDER):
-- settle, then ownership, then the Humanoid.
local function restoreControl(victim: Model, humanoid: Humanoid, root: BasePart): ()
	if root.Parent ~= nil then
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		-- To the victim's own player explicitly, or to the server for a bot/dummy (nil) -- never Auto;
		-- see this file's header, THE THROW. pcall-guarded because SetNetworkOwner throws on an anchored
		-- or grounded part, which a body can have become mid-teardown.
		local owner = Players:GetPlayerFromCharacter(victim)
		pcall(function()
			root:SetNetworkOwner(owner)
		end)
	end
	if humanoid.Parent ~= nil then
		humanoid.PlatformStand = false
		humanoid:SetAttribute(Constants.Attributes.RootControlLocked, nil)
		humanoid:SetAttribute(Constants.Attributes.Grabbed, nil)
	end
end

-- Loops an authored hold clip (MoveGrabConfig.VictimAnimation/AttackerAnimation) on `model` for the
-- length of the hold, or does nothing for "" / nil. Through AnimationManager, like every other track in
-- this codebase, on a manager of its own: the hold clip is one claim on one layer for a few seconds, and
-- borrowing a longer-lived manager would mean reaching into a module that owns a different rig's
-- lifetime. PLAYED BY THE SERVER, which is the one machine that can play a clip on a player, a bot and
-- a debug dummy alike -- a server-loaded track replicates to every client, the held player's own
-- included. GrabConstants.Animation on why Action4 and why looped.
local function playHoldClip(model: Model, clip: string?, role: GrabRole): AnimationManagerInstance?
	if clip == nil or clip == "" then
		return nil
	end
	local manager = AnimationManager.new({ Name = `GrabSystem:{role}:{model.Name}` })
	if not manager:Bind(model) then
		manager:Destroy()
		return nil
	end
	local animation = GrabConstants.Animation
	manager:Claim(animation.Layer, "GrabSystem", {
		Clip = clip,
		Looped = true,
		Priority = animation.Priority,
		FadeIn = animation.FadeInSeconds,
		FadeOut = animation.FadeOutSeconds,
	})
	return manager
end

-- Fades the clip out rather than cutting it (AnimationManager.Unbind destroys its tracks outright), and
-- only then releases the manager. The delay holds nothing but the manager itself: Destroy on a rig that
-- has since gone away is a no-op.
local function stopHoldClip(manager: AnimationManagerInstance?): ()
	if not manager then
		return
	end
	manager:Clear(GrabConstants.Animation.Layer, "GrabSystem")
	task.delay(GrabConstants.Animation.FadeOutSeconds, function()
		manager:Destroy()
	end)
end

-- Undoes the hold's rig and hands the body back to physics as its own assembly -- the half a throw and
-- a release share. Neither the ownership nor the Humanoid is touched here: the two callers disagree
-- about what happens to those next.
local function detachHold(attacker: Model, hold: Hold): ()
	holds[attacker] = nil
	heldBy[hold.Victim] = nil
	CollectionService:RemoveTag(attacker, GrabConstants.Hold.HolderTag)
	CollectionService:RemoveTag(hold.Victim, GrabConstants.Hold.HeldTag)
	attacker:SetAttribute(GrabConstants.Hold.ArmAttribute, nil)
	local shoulder, originalC0 = hold.Shoulder, hold.OriginalShoulderC0
	if shoulder and originalC0 and shoulder.Parent ~= nil then
		shoulder.C0 = originalC0
	end
	hold.Victim:SetAttribute(GrabConstants.Hold.ModeAttribute, nil)
	hold.Victim:SetAttribute(GrabConstants.Hold.VictimAnimatedAttribute, nil)
	stopHoldClip(hold.VictimAnimator)
	stopHoldClip(hold.AttackerAnimator)
	hold.Weld:Destroy()
	restoreBody(hold.Body)
	clearOfWalls(attacker, hold.AttackerRoot, hold.Victim, hold.VictimRoot)
	if hold.AttackerHumanoid.Parent ~= nil then
		hold.AttackerHumanoid:SetAttribute(Constants.Attributes.Grabbing, nil)
	end
	sendHoldChanged(attacker, "Attacker", false)
end

-- Begin / release ------------------------------------------------------------------------------------

-- Drops the victim where they are held and hands control back to both sides -- the auto-release
-- safety timer, and the disconnect/death backstop Step's own sweep calls this for. Never applies any
-- damage: a dropped hold is not a throw, it is the hold simply not happening any more.
local function releaseHold(attacker: Model, hold: Hold): ()
	detachHold(attacker, hold)
	restoreControl(hold.Victim, hold.VictimHumanoid, hold.VictimRoot)
	sendHoldChanged(hold.Victim, "Victim", false)

	debugLog(GrabConstants.Debug.LogHoldReleased, "Grab hold released", { attacker = attacker.Name })
end

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
	-- this is the backstop. An attacker who is themselves held or mid-flight is refused the same way.
	if holds[attacker] or heldBy[attacker] or flights[attacker] then
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
	-- balance call, it is a physical one: a mount is a rigid Weld into the hull's assembly, and so is a
	-- hold now -- honouring both would weld the attacker to the hull through the victim, and whichever
	-- released first would be operating on a body it no longer describes. Refused at the START rather
	-- than by yanking the victim off the blimp, because the attacker landing a hit on a passenger has no
	-- business dismounting them.
	--
	-- Read as an Attribute, not through a BlimpSystem require, the same seam AttackRequestSystem's and
	-- DefenseSystem's own Mounted gates use.
	if victimHumanoid:GetAttribute(Constants.Attributes.Mounted) == true then
		return
	end
	-- Either side of a live air combo: AirComboSystem is already driving that body server-side, and a
	-- weld on top of its spring is two owners on one body -- the exact fault this module's own header
	-- describes. AirComboSystem refuses Grabbed/Grabbing bodies from its side for the same reason.
	if AirComboAttributes.IsParticipant(victimHumanoid) or AirComboAttributes.IsParticipant(attackerHumanoid) then
		return
	end
	local attackerRoot = attacker.PrimaryPart
	local victimRoot = victim.PrimaryPart
	if not attackerRoot or not victimRoot then
		return
	end
	-- Anchored, or jointed to something anchored (an admin freeze, a cutscene rig): welding that into
	-- the attacker's assembly would anchor the ATTACKER in place instead of lifting the victim.
	if victimRoot:IsGrounded() then
		return
	end

	-- A victim who was holding someone themselves drops them first -- a chain of welded bodies is not
	-- a hold anybody authored.
	local victimsOwnHold = holds[victim]
	if victimsOwnHold then
		releaseHold(victim, victimsOwnHold)
	end

	victimHumanoid.PlatformStand = true
	local body = captureBody(victim, ensureCollisionGroup())

	-- The victim's torso (or head) welded to the holder's HAND part, with the holder's arm posed through
	-- its shoulder C0 -- see Shared/Grab/GrabRig.lua's header on why this, and not a placement relative
	-- to the root, is what "attached to the hand" has to mean. The weld's C0/C1 carry the whole
	-- placement, so the body is on its mark the frame the weld exists: no travel, no pre-positioning
	-- CFrame write racing an ownership change.
	local mode = GrabConstants.ModeOf(config.Mode)
	local solution = GrabRig.Solve(attacker, attackerRoot, victim, victimRoot, mode)
	if solution.Shoulder and solution.ShoulderC0 then
		solution.Shoulder.C0 = solution.ShoulderC0
	end
	local weld = Instance.new("Weld")
	weld.Name = GrabConstants.Hold.WeldName
	weld.Part0 = solution.Part0
	weld.Part1 = solution.Part1
	weld.C0 = solution.C0
	weld.C1 = solution.C1
	weld.Parent = solution.Part1

	attackerHumanoid:SetAttribute(Constants.Attributes.Grabbing, true)
	victimHumanoid:SetAttribute(Constants.Attributes.Grabbed, true)
	victimHumanoid:SetAttribute(Constants.Attributes.RootControlLocked, true)

	-- What every client's Client/FX/GrabHoldPose.lua needs: which of the holder's arms to pin (so no
	-- animation swings the hand the victim is welded to), the victim's mode, whether an authored clip
	-- owns the victim's arms, and a tag on each Model. Attributes before tags, so a client never sees a
	-- tagged body without what it needs to pose it. Only set when an arm was actually posed -- a
	-- root-to-root fallback has no arm to pin.
	local victimClip = config.VictimAnimation
	attacker:SetAttribute(GrabConstants.Hold.ArmAttribute, if solution.Shoulder then "Right" else nil)
	victim:SetAttribute(GrabConstants.Hold.ModeAttribute, config.Mode or GrabConstants.DefaultMode)
	victim:SetAttribute(
		GrabConstants.Hold.VictimAnimatedAttribute,
		if victimClip ~= nil and victimClip ~= "" then true else nil
	)
	CollectionService:AddTag(attacker, GrabConstants.Hold.HolderTag)
	CollectionService:AddTag(victim, GrabConstants.Hold.HeldTag)

	holds[attacker] = {
		Victim = victim,
		VictimHumanoid = victimHumanoid,
		VictimRoot = victimRoot,
		AttackerHumanoid = attackerHumanoid,
		AttackerRoot = attackerRoot,
		Config = config,
		Mode = mode,
		ExpiresAt = now + config.HoldSeconds,
		Weld = weld,
		Body = body,
		Shoulder = solution.Shoulder,
		OriginalShoulderC0 = solution.OriginalShoulderC0,
		VictimAnimator = playHoldClip(victim, victimClip, "Victim"),
		AttackerAnimator = playHoldClip(attacker, config.AttackerAnimation, "Attacker"),
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

	-- Flattened, so an attacker pitched by a slope or an animation throws along the ground rather than
	-- into it -- the vertical part of the launch is ThrowUpVelocity's alone. The root, not a hand,
	-- consistent with every other facing-relative effect in this stack (DamageConstants.AttackerLunge,
	-- every authored move's own root-relative Offset). A mode that holds the body BEHIND the attacker
	-- (a drag -- GrabConstants.Modes' ThrowAway) throws along attacker-to-victim instead, which is
	-- "onward, the way it was already being hauled" rather than straight back through the thrower.
	local along = if hold.Mode.ThrowAway
		then hold.VictimRoot.Position - hold.AttackerRoot.Position
		else hold.AttackerRoot.CFrame.LookVector
	local flat = Vector3.new(along.X, 0, along.Z)
	local forward = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
	local config = hold.Config
	local victimRoot = hold.VictimRoot

	detachHold(attackerModel, hold)
	-- The server takes the now-separate body BEFORE writing its velocity -- see this file's header, THE
	-- THROW. PlatformStand and the Grabbed/RootControlLocked Attributes deliberately stay set: the
	-- flight still owns this body until it lands.
	pcall(function()
		victimRoot:SetNetworkOwner(nil)
	end)
	-- The separated assembly inherited the attacker's velocity, turning included; none of that is part
	-- of the throw.
	victimRoot.AssemblyAngularVelocity = Vector3.zero
	victimRoot.AssemblyLinearVelocity = forward * config.ThrowHorizontalVelocity
		+ Vector3.new(0, config.ThrowUpVelocity, 0)
	-- Deliberately NO sendHoldChanged for the victim here: Constants.Attributes.Grabbed spans the whole
	-- hold-then-flight lifetime (see this file's header), and so does the "GRABBED" client cue it
	-- drives -- the victim's own Active=false fires once, on landing, not twice.

	flights[hold.Victim] = {
		Attacker = attackerModel,
		VictimHumanoid = hold.VictimHumanoid,
		VictimRoot = victimRoot,
		Config = config,
		ChecksLandingAt = now + GrabConstants.Impact.MinFlightSeconds,
		ExpiresAt = now + GrabConstants.Impact.MaxFlightSeconds,
		LastPosition = victimRoot.Position,
		StalledSince = nil,
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

	-- restoreControl zeroes the velocity first -- a thrown body that skids through the landing reads as
	-- still being thrown, not as having landed.
	restoreControl(victim, flight.VictimHumanoid, flight.VictimRoot)
	sendHoldChanged(victim, "Victim", false)

	debugLog(GrabConstants.Debug.LogThrowLanded, "Grab throw landed", {
		victim = victim.Name,
		impactTarget = if impactTarget then impactTarget.Name else nil,
	})
end

-- One flight's own small check, run every Step -- see this file's header on why this is written fresh
-- rather than reviving ObjectStunResolver.lua. Any one of these ends the flight:
--   * another live combatant within Impact.CollisionRadiusStuds (the only one that deals impact damage),
--   * a ray swept from last frame's position to this one hitting something (a wall, a floor arrived at
--     steeply) -- swept rather than a point sample so a fast throw cannot tunnel a floor between two
--     Heartbeats, the identical reasoning HitboxEngineConstants' own substep system exists for,
--   * a descending body with a floor within Impact.FootProbeStuds under it (a low, flat throw that
--     skims in with nothing AHEAD of it for the swept ray to find),
--   * a body that has stalled (Impact.StallSpeed for Impact.StallSeconds) wherever it came to rest.
-- The three geometry checks wait out Impact.MinFlightSeconds first; the combatant check does not.
local function stepFlight(victim: Model, flight: Flight, now: number): ()
	local root = flight.VictimRoot
	if victim.Parent == nil or root.Parent == nil or flight.VictimHumanoid.Parent == nil then
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

	local currentPosition = root.Position

	refreshCombatantFilter()
	local nearbyParts = Workspace:GetPartBoundsInRadius(
		currentPosition,
		GrabConstants.Impact.CollisionRadiusStuds,
		combatantOverlapParams
	)
	-- Consecutive parts almost always belong to the same rig; remembering the last one rejected skips
	-- re-walking its ancestry for each of its other fifteen parts.
	local rejected: Model? = nil
	for _, part in nearbyParts do
		local model = combatantOf(part)
		if model and model ~= rejected then
			if model ~= victim and model ~= flight.Attacker and CharacterUtil.LiveHumanoidOf(model) then
				landFlight(victim, flight, model)
				return
			end
			rejected = model
		end
	end

	local lastPosition = flight.LastPosition
	flight.LastPosition = currentPosition
	if now < flight.ChecksLandingAt then
		return
	end

	local delta = currentPosition - lastPosition
	local travelled = delta.Magnitude
	if travelled > 1e-3 then
		local reach = delta.Unit * (travelled + GrabConstants.Impact.GroundProbeExtraStuds)
		if castWorld(lastPosition, reach, victim, flight.Attacker) then
			landFlight(victim, flight, nil)
			return
		end
	end

	local velocity = root.AssemblyLinearVelocity
	if velocity.Y <= 0 then
		local down = Vector3.new(0, -GrabConstants.Impact.FootProbeStuds, 0)
		if castWorld(currentPosition, down, victim, flight.Attacker) then
			landFlight(victim, flight, nil)
			return
		end
	end

	if velocity.Magnitude < GrabConstants.Impact.StallSpeed then
		local stalledSince = flight.StalledSince
		if stalledSince == nil then
			flight.StalledSince = now
		elseif now - stalledSince >= GrabConstants.Impact.StallSeconds then
			landFlight(victim, flight, nil)
		end
	else
		flight.StalledSince = nil
	end
end

-- The loop -----------------------------------------------------------------------------------------

-- One frame. `now` is the caller's clock, matching every other System's Step in this stack.
-- DELIBERATELY FULL WALKS, both of them -- the one place in this stack that did NOT get an amortised
-- reclaim cursor when AttackRequestSystem/SwingSequencer/DamageSystem did. Neither loop below is a
-- reclaim: the first RELEASES a hold when its expiry passes (skipping an entry would leave a victim
-- pinned past the window), and the second advances flight probes on every entry (skipping one is a
-- dropped frame of landing detection). Both tables are also bounded by "grabs actually in progress
-- right now", which on any real server is a handful, so the full walk was never the cost. See
-- Shared/AmortizedReclaim.lua's header on why a sweep that does per-entry work must not be amortised.
--
-- A hold costs nothing per frame beyond the checks below -- the weld does the carrying, on whichever
-- machine simulates the attacker, with no server-side constraint solve at all.
function GrabSystem.Step(_deltaTime: number, now: number): ()
	for attacker, hold in holds do
		local attackerGone = attacker.Parent == nil
			or hold.AttackerRoot.Parent == nil
			or hold.AttackerHumanoid.Parent == nil
			or hold.AttackerHumanoid.Health <= 0
		local victimGone = hold.Victim.Parent == nil
			or hold.VictimRoot.Parent == nil
			or hold.VictimHumanoid.Parent == nil
			or hold.VictimHumanoid.Health <= 0
		-- The weld itself going (BreakJointsOnDeath, a rig torn down under it) ends the hold even if
		-- both Humanoids somehow still read alive -- there is nothing holding the body any more.
		local weldGone = hold.Weld.Parent == nil
		if attackerGone or victimGone or weldGone or now >= hold.ExpiresAt then
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

	-- Eagerly, so the group exists (and is paired off against every group the place registers at edit
	-- time) before the first grab rather than on it.
	ensureCollisionGroup()

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
