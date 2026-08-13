--!strict
--[[
	RagdollController.lua

	Owns: server-authoritative physical control of a combat character's BODY -- turning it into a
	ragdoll and recovering it (LaunchAndRagdoll / SlamToGround / Ragdoll / ExtendRagdoll / Recover),
	and pinning it to a fixed point in space (HoldAloft / ClearHold) for the air combo's hover and for
	an object stun's wall pin. A pure helper under Server/Combat/, the same role HitboxResolver plays
	for hit detection: CombatSystem drives it (knockback calls from hit resolution, Update() from its
	own single Heartbeat) and it owns no combat state of its own.

	Both halves are one module because they are the same job -- taking a body away from its owner's
	client and driving it from the server -- and they share all of the machinery that makes that safe:
	network ownership transfer, Humanoid suppression, and collision-group assignment. They also
	overlap constantly in practice (an air-combo target is held AND ragdolled at once), and every bug
	this file has historically had lived in the seams between them.

	Why server-authoritative: a player's character is network-owned by that player's client, so a bare
	velocity/CFrame write from the server is immediately overridden by the owner's own simulation.
	Ownership moves to the server (SetNetworkOwner(nil)) BEFORE any joint or velocity change, and back
	to the player on release. Every ownership/physics call is pcall-guarded -- a character can die or
	despawn mid-ragdoll, and a failed call must never break the recover path or throw out of hit
	resolution. This module never touches Humanoid.Health: a ragdoll is a physical state, damage is
	CombatSystem's job.

	Lifecycle of a ragdoll:
	  Limp      -- joints are ball sockets, Humanoid suppressed, physics drives the body. Lasts for
	               the authored RagdollSeconds/KnockdownSeconds window, and then for however much
	               longer the body is still genuinely in motion (see isSettled -- a body still flying
	               does not stand up in mid-air just because its timer lapsed).
	  Blending  -- the window elapsed and the body has settled; it physically folds back to its rest
	               pose and stands upright over Constants.Combat.Ragdoll.RecoverBlendSeconds (see that
	               constant for why this is a physics blend and not a Motor6D.Transform lerp).
	  (gone)    -- motors re-enabled, Humanoid released, ownership handed back.
	A fresh hit landing during either phase re-limps the body rather than stacking a second ragdoll.

	Structure. There is exactly ONE ragdoll entry path (applyKnockback) and one hold path
	(HoldAloft); every public knockback function is a thin adapter over the first that differs only in
	the velocity/spin it asks for. That is deliberate -- each of the three used to carry its own copy
	of the ownership/joint/velocity ordering, which is precisely the ordering every historical bug in
	this file got wrong, and a fix applied to one copy silently missed the others.

	Cost. Every character-wide operation takes a PRE-COLLECTED array of BaseParts rather than walking
	character:GetDescendants() itself, and a live ragdoll caches that array on its own record for its
	whole lifetime. A single knockback used to walk the full descendant tree seven times (twice for
	ownership, once for physical properties, once to seed velocity, once for the launch, twice for the
	collision group) -- on a rig with accessories that is several hundred instances visited per hit,
	per target, for a list that cannot change between the first walk and the last.

	Does not own: the decision to ragdoll (CombatSystem's finisher/AirCombo logic decides that), the
	combo state (CombatState.Vitals.ragdollExpiry mirrors this module's own timer so the action
	lockout and the physical recovery stay in lockstep -- see RemainingSeconds, which is how a caller
	keeps that mirror honest now that recovery can wait for a body to settle), or any gameplay
	validation.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local PhysicsService = game:GetService("PhysicsService")
local Constants = require(ReplicatedStorage.Shared.Constants)

local RagdollController = {}

local RAGDOLL_CFG = Constants.Combat.Ragdoll

-- Every instance this module parents onto a character, named once so ClearHold/exitRagdoll can find
-- and destroy exactly what they created and nothing else (a character carries plenty of Attachments
-- and constraints that aren't ours).
local NAME_HOLD_ATTACHMENT = "AirComboHoldAttachment"
local NAME_HOLD_ALIGN = "AirComboHoldAlign"
local NAME_HOLD_ORIENT = "AirComboHoldOrient"
local NAME_HOLD_GRAVITY_CANCEL = "AirComboHoldGravityCancel"
local NAME_UPRIGHT_ATTACHMENT = "RagdollUprightAttachment"
local NAME_UPRIGHT_ALIGN = "RagdollUprightAlign"

-- Everything a hold parents onto its rootPart, in teardown order (constraints before the attachment
-- they reference). One list rather than the literal ClearHold used to build inline on every call --
-- it is also the single place a future hold constraint has to be registered in order to be cleaned
-- up, which an inline literal at one of several teardown sites is not.
local HOLD_INSTANCE_NAMES = { NAME_HOLD_ALIGN, NAME_HOLD_GRAVITY_CANCEL, NAME_HOLD_ORIENT, NAME_HOLD_ATTACHMENT }

--------------------------------------------------------------------------------------------------
-- Collision groups
--------------------------------------------------------------------------------------------------

-- Two problems, both solved by taking a body out of the Default group for as long as the server is
-- driving it:
--
--   GROUP_RAGDOLL (intra-body). A rigid joint automatically no-collides the two parts it connects,
--   but that exemption belongs to the JOINT, not the parts -- disabling a Motor6D removes it. A
--   character's own adjacent limbs sit flush against each other at idle, so the instant they're ball
--   socketed they start genuinely colliding with EACH OTHER, and the solver reacts to that
--   self-interpenetration by shoving parts apart hard. That is what read as "launched into the air
--   and flailed" instead of a clean physical reaction.
--
--   GROUP_HELD (cross-body). Both participants of an air combo are pulled by a MaxForce = math.huge
--   AlignPosition toward FIXED points, and SwitchPriority's role swap literally sends the two bodies
--   to trade places -- straight through each other. Colliding mid-pull makes the AlignPosition fight
--   the contact response instead of winning outright, and the loser settles visibly off its point.
--
-- Ragdoll is also non-collidable with Held, because a body can be both at once (an air-combo dummy
-- target is ragdolled AND pinned) and can only ever be in one group -- see applyCollisionGroup for
-- the precedence. Everything else -- the floor, unrelated characters -- still collides normally,
-- since CollisionGroupSetCollidable only exempts the specific pairs named here.
--
-- Registration is guarded by IsCollisionGroupRegistered rather than swallowing CreateCollisionGroup's
-- "already exists" error, so a second require in the same session (a Studio hot-reload) is clean.
local GROUP_DEFAULT = "Default"
local GROUP_RAGDOLL = "Ragdoll"
local GROUP_HELD = "AirComboHeld"

for _, groupName in ipairs({ GROUP_RAGDOLL, GROUP_HELD }) do
	if not PhysicsService:IsCollisionGroupRegistered(groupName) then
		PhysicsService:CreateCollisionGroup(groupName)
	end
end
PhysicsService:CollisionGroupSetCollidable(GROUP_RAGDOLL, GROUP_RAGDOLL, false)
PhysicsService:CollisionGroupSetCollidable(GROUP_HELD, GROUP_HELD, false)
PhysicsService:CollisionGroupSetCollidable(GROUP_RAGDOLL, GROUP_HELD, false)

--------------------------------------------------------------------------------------------------
-- Public config shapes
--------------------------------------------------------------------------------------------------

-- One named table each instead of the trailing runs of positional numbers LaunchAndRagdoll and
-- SlamToGround used to take (4 and 3 respectively). Four independent call sites already build
-- knockback from four independently-shaped Constants tables (Constants.Combat.Finisher.Uppercut/
-- Downslam, Constants.Combat.AirCombo, Constants.Combat.ObjectStun, and a Move Editor author's
-- Types.HitboxAttackDefinition.Knockback); one more had nothing to import and check itself against,
-- just a parameter list to match by position. Field NAMES don't have to match Constants' own -- each
-- caller writes the small adapter table it needs (see HitResolution.ApplyFinisherPhysics) -- so a new
-- move wanting different tuning never forces a signature change here.
--
-- `character`/`humanoid`/`rootPart`/`ownerPlayer`/`attackerRootPart` stay positional on every
-- function: those five are WHO/WHERE, identical across every caller, and bundling them would add a
-- table construction with no upside.
export type LaunchProfile = {
	UpVelocity: number,
	HorizontalVelocity: number,
	BackwardSpin: number,
	RagdollSeconds: number,
}

export type SlamProfile = {
	DownVelocity: number,
	FaceDownSpin: number,
	KnockdownSeconds: number,
}

-- HoldAloft's own equivalent, for the same reason: it used to take FIVE trailing positional values
-- (position, duration, maxSpeed, responsiveness, facePoint) and AirCombo.lua calls it from five
-- different sites, where a transposed pair of numbers is invisible at the call site and produces a
-- pin that is merely subtly wrong rather than broken.
export type HoldProfile = {
	-- The FIXED world point the body is pinned to. Computed ONCE by the caller at sequence-start and
	-- reused verbatim by every refresh -- see HoldAloft's own header for why recomputing it ratchets.
	Position: Vector3,
	DurationSeconds: number,
	MaxSpeed: number,
	Responsiveness: number,
	-- Non-nil marks this as a LIVE (non-ragdolled) hold and is the world point to keep the body
	-- facing. See HoldAloft's header for the full live-body treatment this turns on.
	LiveBodyFacePoint: Vector3?,
	-- Fired once, from Update, when the hold reaches DurationSeconds and is released on its own.
	-- Deliberately NOT fired when a caller cancels the hold early via ClearHold: a caller that clears
	-- a hold is taking the body over, and running the "what happens when the pin lets go" beat
	-- underneath it is exactly the race this replaced (an object stun's wall pin used to schedule its
	-- own task.delay for the same instant HoldAloft scheduled the release, so the drop and the
	-- release argued over a body that might by then have died, respawned, or been re-pinned).
	OnRelease: (() -> ())?,
}

export type RagdollPhase = "Limp" | "Blending"

--------------------------------------------------------------------------------------------------
-- Module state
--------------------------------------------------------------------------------------------------

-- One ball-socketed joint of a live ragdoll: the Motor6D this module disabled, the Attachments and
-- BallSocketConstraint it created in that motor's place, and (during the recovery blend only) the
-- AlignOrientation easing the limb back toward its rest pose.
type RagdollJoint = {
	motor: Motor6D,
	attachment0: Attachment,
	attachment1: Attachment,
	socket: BallSocketConstraint,
	align: AlignOrientation?,
}

-- One live ragdoll, keyed by character Model in `ragdolls`. `rootPart` is nil only for a malformed
-- rig with no HumanoidRootPart, which degrades to a suppressed-Humanoid knockdown with no joint
-- swap at all. `ownerPlayer` is who network ownership goes back to (nil = server-owned for its whole
-- life, e.g. a training dummy). `blendUntil` is meaningless while phase == "Limp".
type ActiveRagdoll = {
	humanoid: Humanoid,
	rootPart: BasePart?,
	ownerPlayer: Player?,
	expiry: number,
	phase: RagdollPhase,
	blendUntil: number,
	joints: { RagdollJoint },
	-- Every BasePart of the character, collected ONCE when the ragdoll began -- see this file's own
	-- header for why. Held for the ragdoll's whole life: the set of parts a character HAS cannot
	-- change as a result of anything this module does (disabling a Motor6D re-partitions the parts
	-- into new assemblies, it does not add or remove any), and a part destroyed out from under it is
	-- already covered by the pcall every write here goes through.
	parts: { BasePart },
	-- Every part's CustomPhysicalProperties as it was BEFORE this ragdoll zeroed its Elasticity (see
	-- applyLandingPhysicalProperties) -- nil for a part that was already using its material's plain
	-- defaults, which is the common case and the correct value to restore to on the way out.
	originalPhysicalProperties: { [BasePart]: PhysicalProperties? },
}

local ragdolls: { [Model]: ActiveRagdoll } = {}

-- One live hold, keyed by the pinned rootPart. `character` is cached rather than read back off
-- rootPart.Parent because a hold routinely outlives its character's parenting (a despawn mid-
-- sequence) and the collision-group restore still needs to know who to fix up. `humanoid` is set
-- only for a LIVE (non-ragdolled) held body -- see enterLiveHold for why a live body needs its
-- Humanoid quieted and a ragdolled one doesn't.
--
-- `expiresAt` replaced a per-hold `task.delay` thread that had to be cancelled and rescheduled on
-- every refresh. Update already runs every tick and already owns the ragdoll half's timing, so the
-- hold half kept a whole second scheduling mechanism alive purely to answer the same question --
-- along with the failure mode that mechanism brings (a stale thread firing later against a NEWER
-- hold on the same rootPart, which is why the cancel dance existed at all). A timestamp compared in
-- the loop that was already running cannot go stale.
type ActiveHold = {
	character: Model?,
	humanoid: Humanoid?,
	ownerPlayer: Player?,
	expiresAt: number,
	onRelease: (() -> ())?,
}

local holds: { [BasePart]: ActiveHold } = {}

-- Which characters currently have a hold on them, so applyCollisionGroup can answer "is this body
-- held" with one lookup instead of scanning `holds`. Maintained purely by HoldAloft/ClearHold, the
-- only two writers of `holds`. A count rather than a boolean because nothing structurally forbids
-- two of a character's parts being pinned at once (holds are keyed by BasePart, not by character),
-- and a plain boolean would let the first release clear a flag the second hold still needs.
local heldCharacters: { [Model]: number } = {}

-- Humanoid suppression, reference counted. Both halves of this module need to stop a Humanoid's own
-- controller from fighting server-driven physics (PlatformStand + Physics state + GettingUp
-- disabled), and a body can genuinely be under both at once -- a live-held air-combo victim who then
-- eats a finisher is suppressed by the hold AND the ragdoll. Saving/restoring the Humanoid's own
-- properties independently in each path is what used to strand a player permanently limp: the second
-- path captured PlatformStand = true (set moments earlier by the first) as its "pristine" value and
-- faithfully restored it. Counting instead means the pristine values are captured exactly once, by
-- whoever got there first, and restored exactly once, by whoever leaves last.
type Suppression = {
	count: number,
	platformStand: boolean,
	autoRotate: boolean,
}

local suppressions: { [Humanoid]: Suppression } = {}

local function suppressHumanoid(humanoid: Humanoid): ()
	local record = suppressions[humanoid]
	if record then
		record.count += 1
	else
		suppressions[humanoid] = {
			count = 1,
			platformStand = humanoid.PlatformStand,
			autoRotate = humanoid.AutoRotate,
		}
	end
	-- Re-asserted on every claim, not just the first: cheap, and it repairs a Humanoid something else
	-- (a seat, a respawn-adjacent reset) knocked out of the suppressed state mid-window.
	humanoid.PlatformStand = true
	humanoid.AutoRotate = false
	humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)
	pcall(function()
		humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	end)
end

-- Drops one claim. Restores the Humanoid only when the last claim goes away AND the body is still a
-- living, parented character -- a corpse deliberately stays limp (standing a dead body back up is
-- exactly the snap CombatSystem.confirmDeath's own comment avoids), and a despawning one has nothing
-- worth restoring.
local function releaseHumanoid(humanoid: Humanoid): ()
	local record = suppressions[humanoid]
	if not record then
		return
	end
	record.count -= 1
	if record.count > 0 then
		return
	end
	suppressions[humanoid] = nil
	if not humanoid.Parent or humanoid.Health <= 0 then
		return
	end
	humanoid.PlatformStand = record.platformStand
	humanoid.AutoRotate = record.autoRotate
	humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
	pcall(function()
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	end)
end

--------------------------------------------------------------------------------------------------
-- Character-wide primitives
--------------------------------------------------------------------------------------------------

-- The one descendant walk. Everything below takes the resulting array instead of re-walking, and a
-- live ragdoll keeps it on its own record -- see ActiveRagdoll.parts.
local function collectParts(character: Model): { BasePart }
	local parts: { BasePart } = {}
	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

-- The cached array when this character is already ragdolled, a fresh walk otherwise. Every public
-- entry point resolves its part list through here exactly once and threads it down, so a knockback
-- landing on an already-ragdolled body (an air-combo continuation, an object stun's re-ragdoll)
-- costs no walk at all.
local function partsOf(character: Model): { BasePart }
	local entry = ragdolls[character]
	if entry then
		return entry.parts
	end
	return collectParts(character)
end

-- Per-part (a ball-socketed ragdoll is several assemblies, not one) and pcall-guarded, because
-- SetNetworkOwner throws on an anchored or otherwise ungrounded part. nil takes ownership to the
-- server; nil on RESTORE means automatic ownership, which is the correct answer for a dummy with no
-- player behind it.
local function setNetworkOwner(parts: { BasePart }, ownerPlayer: Player?): ()
	for _, part in ipairs(parts) do
		if not part.Anchored then
			pcall(function()
				part:SetNetworkOwner(ownerPlayer)
			end)
		end
	end
end

-- Longest this module will ever hold up a knockback's own ragdoll entry waiting for a player's own
-- client to actually relinquish network ownership -- see ensureServerOwnership/pendingKnockbacks'
-- own headers for why the wait exists and how it's paced. Bounded so a laggy connection degrades to
-- the OLD behaviour (a brief visible glitch) instead of the entry waiting indefinitely; well under
-- any window a player would notice as "delayed," since a healthy connection resolves this in one or
-- two Heartbeats.
local OWNERSHIP_HANDOFF_TIMEOUT = 0.25

-- A knockback whose target's rootPart hadn't been confirmed server-owned yet when applyKnockback was
-- called for it -- see ensureServerOwnership's own header for why entering the ragdoll (the joint
-- swap in particular) before that handoff actually lands reopens the exact ownership fight this
-- module exists to prevent. Resolved from Update below, once GetNetworkOwner() finally agrees or
-- `deadline` passes, rather than the CALLER's own thread blocking on it: hit resolution (HitboxResolver's
-- hit callback, all the way through CombatSystem's resolveHitAgainstTarget/AirCombo/Finisher chain,
-- which is what actually calls into a knockback) runs inline inside CombatSystem's own single
-- Heartbeat pass over every player's hits/movement/ragdoll ticks for that frame -- a caller blocking
-- there for up to OWNERSHIP_HANDOFF_TIMEOUT delayed everyone else sharing that same pass, every
-- single player knockback, not just a laggy-connection edge case.
--
-- Keyed by rootPart, one entry per pending knockback: a second knockback landing on a target that's
-- already waiting out its first one's handoff (two brand-new hits against the same live player
-- within the same short window) replaces the pending record outright rather than queuing a second --
-- the newer knockback is a more current picture of what this hit should do than the stale one it's
-- superseding, and applying both in sequence a tick later would double-launch the body.
type PendingKnockback = {
	character: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	ownerPlayer: Player?,
	parts: { BasePart },
	seconds: number,
	linearVelocity: Vector3?,
	spin: Vector3?,
	deadline: number,
}

local pendingKnockbacks: { [BasePart]: PendingKnockback } = {}

-- Requests the ownership handoff if `rootPart` isn't already server-owned, and reports whether it is
-- CONFIRMED server-owned right now. NEVER yields -- see pendingKnockbacks' own header for why a
-- caller reaching this from hit resolution cannot afford to block here the way this function's own
-- history once did.
--
-- Every knockback reaching here is a BRAND NEW one (an already-ragdolled target's ownership was
-- already settled by its own earlier call, and GetNetworkOwner() below returns nil immediately for
-- it, so this is the common, zero-wait case). SetNetworkOwner asks the client to give up ownership,
-- it does not grant it instantly -- until the owning client (a real player's own client; a dummy or
-- bot has none, which is why this never reproduced on them) actually receives and processes that
-- request, IT is still the machine simulating this body. For however long that round trip takes, two
-- machines simulating the same parts with two different ideas of what's true is what read as the
-- body flying and flipping uncontrollably for a moment before "settling" -- which is why
-- applyKnockback defers the actual joint-swap/velocity write (via pendingKnockbacks) rather than
-- doing it against a body this function just reported NOT yet confirmed.
local function ensureServerOwnership(rootPart: BasePart, parts: { BasePart }): boolean
	local currentOwner
	local ok = pcall(function()
		currentOwner = rootPart:GetNetworkOwner()
	end)
	if not ok or currentOwner == nil then
		return true
	end
	setNetworkOwner(parts, nil)
	return false
end

-- Puts `character` in the one collision group its CURRENT state calls for, rather than having each
-- entry/exit path assert its own group and clobber whatever the other one wanted. Ragdoll wins over
-- Held because a ragdolled body's self-collision problem is the more destructive of the two and the
-- Ragdoll/Held pair is already exempted above, so a ragdolled-and-held body in GROUP_RAGDOLL still
-- gets both exemptions. Every caller that changes ragdoll or hold state calls this afterwards; there
-- is no other writer of CollisionGroup in this module.
local function applyCollisionGroup(character: Model, parts: { BasePart }): ()
	local groupName = GROUP_DEFAULT
	if ragdolls[character] then
		groupName = GROUP_RAGDOLL
	elseif heldCharacters[character] then
		groupName = GROUP_HELD
	end
	for _, part in ipairs(parts) do
		pcall(function()
			part.CollisionGroup = groupName
		end)
	end
end

-- The network-ownership counterpart to applyCollisionGroup's own Ragdoll > Held precedence just
-- above -- restores `ownerPlayer` ONLY if neither system still claims `character`, and otherwise
-- leaves it server-owned for whichever one still does. Both exitRagdoll and ClearHold hand ownership
-- back on their own exit, and a body routinely leaves one system while the OTHER is still actively
-- driving it (an air-combo dummy target is ragdolled AND held at once, per this file's own header) --
-- without this, the FIRST of the two to finish handed the body straight back to its owning client
-- while the second system's own physics (a live ball-socket joint swap still mid-recovery-blend, an
-- AlignPosition still pinning position with MaxForce = math.huge) kept writing to parts the client
-- was now simulating too. That is exactly the ownership fight ensureServerOwnership exists to
-- prevent on ENTRY, reopened on exit for anything that didn't check whether a sibling system was
-- still mid-flight.
local function restoreNetworkOwnershipIfUnclaimed(character: Model?, parts: { BasePart }, ownerPlayer: Player?): ()
	if character and (ragdolls[character] or heldCharacters[character]) then
		return
	end
	setNetworkOwner(parts, ownerPlayer)
end

-- Clamped to Constants.Combat.Ragdoll.MaxLaunchSpeed -- see that constant for why (containment
-- against a fat-fingered authored knockback, not a feel knob; nothing tuned comes near it).
local function setLinearVelocity(part: BasePart, velocity: Vector3): ()
	if part.Anchored then
		return
	end
	local speed = velocity.Magnitude
	local clamped = if speed > RAGDOLL_CFG.MaxLaunchSpeed
		then velocity * (RAGDOLL_CFG.MaxLaunchSpeed / speed)
		else velocity
	pcall(function()
		part.AssemblyLinearVelocity = clamped
	end)
end

local function setAngularVelocity(part: BasePart, angularVelocity: Vector3): ()
	if part.Anchored then
		return
	end
	pcall(function()
		part.AssemblyAngularVelocity = angularVelocity
	end)
end

-- Writes one linear velocity across a whole body. Never `rootPart.AssemblyLinearVelocity = v`: a
-- Motor6D-rigged character is ONE assembly, so that write moves all of it, but a ragdolled one is
-- fourteen ball-socketed assemblies and the identical line moves only the TORSO, leaving every limb
-- on whatever velocity it already had. The sockets then have to reconcile a violent relative-velocity
-- mismatch on the very next step, which does not read as the body starting or stopping -- it reads as
-- the body flailing, flipping and spinning on the spot.
local function writeBodyVelocity(parts: { BasePart }, velocity: Vector3): ()
	for _, part in ipairs(parts) do
		setLinearVelocity(part, velocity)
	end
end

-- Forces every part of the body to RAGDOLL_CFG.RagdollElasticity for as long as it stays limp --
-- see that constant's own header for why (a real material's default bounce, on either the character
-- or whatever it lands on, was enough at finisher-launch/wall-drop speeds to visibly bounce the body
-- back off the ground on impact, which read as a second, unrelated "flight" distinct from the
-- knockback's own launch). Density and Friction are preserved from the part's OWN material
-- (PhysicalProperties.new(part.Material) reads that material's real defaults) rather than being
-- overwritten with a guessed constant -- density in particular feeds AssemblyMass, which
-- ensureGravityCancel's hover force and every other mass-aware calculation in this module depends on
-- staying correct, so only Elasticity/ElasticityWeight are actually changed.
-- Returns each touched part's ORIGINAL CustomPhysicalProperties (nil for the common "used the
-- material's plain defaults" case) so exitRagdoll can put it back exactly as it found it.
local function applyLandingPhysicalProperties(parts: { BasePart }): { [BasePart]: PhysicalProperties? }
	local original: { [BasePart]: PhysicalProperties? } = {}
	for _, part in ipairs(parts) do
		original[part] = part.CustomPhysicalProperties
		local ok, materialDefaults = pcall(PhysicalProperties.new, part.Material)
		if ok then
			pcall(function()
				part.CustomPhysicalProperties = PhysicalProperties.new(
					materialDefaults.Density,
					materialDefaults.Friction,
					RAGDOLL_CFG.RagdollElasticity,
					materialDefaults.FrictionWeight,
					RAGDOLL_CFG.RagdollElasticityWeight
				)
			end)
		end
	end
	return original
end

-- Undoes applyLandingPhysicalProperties, part by part -- called from exitRagdoll's restore path only
-- (a corpse/despawn abandons the body as-is, same rule every other piece of ragdoll state follows).
local function restorePhysicalProperties(original: { [BasePart]: PhysicalProperties? }): ()
	for part, value in pairs(original) do
		if part.Parent then
			pcall(function()
				part.CustomPhysicalProperties = value
			end)
		end
	end
end

-- Horizontal direction a knockback should throw a target: away from the attacker, falling back to
-- the target's own reversed facing when there's no attacker to be away from (a dummy hit with no
-- meaningful source) or when the two are stacked close enough that the delta is noise.
--
-- Public, because it is not only knockback's own business: an object stun's clearance probe has to
-- look along the direction the body is genuinely ABOUT to travel, which means the exact vector the
-- knockback that registered the watch is about to use. CombatSystem carried its own transcription of
-- this same math for that purpose -- two copies of "flatten, check MinDirectionMagnitude, fall back
-- to -LookVector" that were only correct while they stayed identical, in a place where drifting
-- apart would not fail loudly (it would just quietly aim the causation probe somewhere the target
-- isn't going, and refuse or accept the wrong watches).
function RagdollController.ResolveKnockbackDirection(rootPart: BasePart, attackerRootPart: BasePart?): Vector3
	if attackerRootPart then
		local delta = rootPart.Position - attackerRootPart.Position
		local flat = Vector3.new(delta.X, 0, delta.Z)
		if flat.Magnitude > Constants.Combat.MinDirectionMagnitude then
			return flat.Unit
		end
	end
	return -rootPart.CFrame.LookVector
end

-- The horizontal axis a tumble spins about: perpendicular to travel (direction x world up), so the
-- tumble reads as "flipped along the flight path" rather than a random corkscrew. Returns nil when
-- the direction is degenerate enough that the cross product is noise. An uppercut rotates about
-- +axis (the body's up goes AWAY from its travel direction -- head tips backward, lands on its
-- back); a downslam uses -axis so the head tips down and forward into a face-first landing.
local function resolveTumbleAxis(direction: Vector3): Vector3?
	local axis = direction:Cross(Vector3.new(0, 1, 0))
	if axis.Magnitude > Constants.Combat.MinDirectionMagnitude then
		return axis.Unit
	end
	return nil
end

--------------------------------------------------------------------------------------------------
-- Ragdoll: entering
--------------------------------------------------------------------------------------------------

-- Swaps every Motor6D that doesn't touch the HumanoidRootPart for a BallSocketConstraint. Skipping
-- HRP-touching joints keeps the HRP rigidly welded to the torso, so the body keeps one stable primary
-- assembly for collision and for the launch velocity to act on, while every other limb goes floppy.
-- Rig-agnostic by construction: it keys off "does this joint touch the root part," which is as true
-- of an R6 rig's four limb joints and neck as it is of R15's fourteen.
--
-- Attachment0's local CFrame is C0 * Transform, NOT plain C0. While a Motor6D is enabled Roblox drives
-- Part1.CFrame = Part0.CFrame * C0 * Transform * C1:Inverse() every frame, where Transform is the live
-- offset the Animator writes on top of the joint's static rest pose to actually pose the limb. The two
-- parts' REAL relative orientation at the instant the motor is disabled is therefore C0 * Transform,
-- not C0 alone. Building the attachment from bare C0 anchors the socket's neutral reference to the
-- rest pose while the parts themselves sit at the ANIMATED pose -- for anything but a perfect T-pose
-- (an attack swing, a stride, even idle sway) that's a large constraint violation the solver must
-- forcibly correct on the very first step, which is what read as the body snapping/flipping the
-- instant it was hit. Multiplying Transform back in makes the two attachments' world CFrames coincide
-- at creation, so the body drapes from whatever pose it was actually in and the cone limit only ever
-- constrains motion AWAY from that pose.
local function buildRagdollJoints(character: Model, rootPart: BasePart): { RagdollJoint }
	local joints: { RagdollJoint } = {}

	for _, descendant in ipairs(character:GetDescendants()) do
		if not descendant:IsA("Motor6D") then
			continue
		end
		local part0 = descendant.Part0
		local part1 = descendant.Part1
		if not part0 or not part1 or part0 == rootPart or part1 == rootPart then
			continue
		end

		local attachment0 = Instance.new("Attachment")
		attachment0.Name = "RagdollAttachment0"
		attachment0.CFrame = descendant.C0 * descendant.Transform
		attachment0.Parent = part0

		local attachment1 = Instance.new("Attachment")
		attachment1.Name = "RagdollAttachment1"
		attachment1.CFrame = descendant.C1
		attachment1.Parent = part1

		local socket = Instance.new("BallSocketConstraint")
		socket.Name = "RagdollSocket"
		socket.Attachment0 = attachment0
		socket.Attachment1 = attachment1
		socket.LimitsEnabled = true
		socket.UpperAngle = RAGDOLL_CFG.BallSocketUpperAngle
		socket.TwistLimitsEnabled = true
		socket.TwistLowerAngle = RAGDOLL_CFG.BallSocketTwistLowerAngle
		socket.TwistUpperAngle = RAGDOLL_CFG.BallSocketTwistUpperAngle
		-- See BallSocketFrictionTorque -- without it a ragdoll never comes to rest.
		socket.MaxFrictionTorque = RAGDOLL_CFG.BallSocketFrictionTorque
		socket.Parent = part0

		descendant.Enabled = false

		table.insert(joints, {
			motor = descendant,
			attachment0 = attachment0,
			attachment1 = attachment1,
			socket = socket,
			align = nil,
		})
	end

	return joints
end

-- Destroys whatever recovery drives are on a body and puts its sockets back to their loose limits.
-- Shared by the re-limp path (a fresh hit landing mid-getup, which must cancel the fold-back so the
-- body goes limp again from wherever it currently is) and by nothing else -- exitRagdoll's own
-- teardown destroys the sockets outright rather than restoring them. Split out because the re-limp
-- path used to carry an inline copy of it, and "restore the loose limits" is four separate socket
-- properties that have to agree with buildRagdollJoints' four.
local function clearRecoveryDrives(entry: ActiveRagdoll): ()
	for _, joint in ipairs(entry.joints) do
		if joint.align then
			joint.align:Destroy()
			joint.align = nil
		end
		joint.socket.UpperAngle = RAGDOLL_CFG.BallSocketUpperAngle
		joint.socket.TwistLowerAngle = RAGDOLL_CFG.BallSocketTwistLowerAngle
		joint.socket.TwistUpperAngle = RAGDOLL_CFG.BallSocketTwistUpperAngle
		joint.socket.MaxFrictionTorque = RAGDOLL_CFG.BallSocketFrictionTorque
	end

	local rootPart = entry.rootPart
	if not rootPart then
		return
	end
	for _, name in ipairs({ NAME_UPRIGHT_ALIGN, NAME_UPRIGHT_ATTACHMENT }) do
		local instance = rootPart:FindFirstChild(name)
		if instance then
			instance:Destroy()
		end
	end
end

-- Shared setup for every ragdoll variant. Idempotent: a second finisher landing on an already-
-- ragdolled target extends the timer instead of double-swapping joints, and a hit landing during the
-- recovery blend cancels that blend and re-limps the body rather than fighting it. Returns the live
-- record so the caller can write velocity through its cached part list.
--
-- Order matters. Ownership moves to the server FIRST, before a single joint is touched, so the
-- constraint swap and every physics step after it are simulated authoritatively -- doing it the other
-- way round leaves the owning client simulating a body whose joints just vanished for however long
-- the ownership change takes to land, which is a frame of client-side scatter that then has to be
-- corrected by replication. It is then asserted a SECOND time immediately after the swap, because
-- the swap itself replaces the one assembly that first call applied to with fourteen new ones -- see
-- that call's own comment, and note that skipping it is what made knockback fail on players
-- specifically while working on dummies.
--
-- Then every part is seeded with the velocity the body was ALREADY travelling at. A Motor6D-rigged
-- character is one assembly with one velocity; the instant it becomes fourteen ball-socketed
-- assemblies, each part keeps whatever it had, and any subsequent velocity write to the root alone
-- leaves the torso moving while the limbs sit still. The sockets then have to violently reconcile
-- that relative-velocity mismatch on the very first step -- which reads as the character spinning and
-- flipping instead of travelling. Giving every part the same velocity up front means there is nothing
-- to reconcile, and it makes the "no explicit launch at all" case (a plain knockdown, a continuation
-- extend) inherit the body's real momentum instead of dropping it.
local function enterRagdoll(
	character: Model,
	humanoid: Humanoid,
	ownerPlayer: Player?,
	seconds: number,
	parts: { BasePart },
	now: number
): ActiveRagdoll
	local existing = ragdolls[character]
	if existing then
		if existing.phase == "Blending" then
			clearRecoveryDrives(existing)
			existing.phase = "Limp"
		end
		existing.expiry = math.max(existing.expiry, now + seconds)
		return existing
	end

	local rootPartInstance = character:FindFirstChild("HumanoidRootPart")
	local rootPart: BasePart? = if rootPartInstance and rootPartInstance:IsA("BasePart") then rootPartInstance else nil

	suppressHumanoid(humanoid)
	setNetworkOwner(parts, nil)
	local originalPhysicalProperties = applyLandingPhysicalProperties(parts)

	local joints: { RagdollJoint } = {}
	if rootPart then
		local carriedVelocity = rootPart.AssemblyLinearVelocity
		joints = buildRagdollJoints(character, rootPart)
		-- Re-asserted AFTER the joint swap, and this is not redundant with the call above.
		--
		-- SetNetworkOwner acts on an ASSEMBLY, and the call above set it on the one assembly a
		-- Motor6D-rigged character has. Disabling those motors (buildRagdollJoints) splits that single
		-- assembly into roughly fourteen new ones, and a newly-formed assembly gets its ownership
		-- assigned automatically -- which, for a player's own character, hands it straight back to that
		-- player. Every velocity write below (and every launch after it) would then be the server
		-- writing to assemblies the CLIENT simulates authoritatively, so the client's own version of
		-- events -- a limp body already at rest on the floor -- overwrites the launch on the next
		-- replication step and the target simply crumples where it stood.
		--
		-- That is why this only ever reproduced on players: a dummy or NPC has no client to hand
		-- ownership back to, so the server kept it and the identical code path launched correctly.
		--
		-- The call above still earns its place for the reason this function's header gives (the owning
		-- client must not simulate a frame of a body whose joints just vanished); this one covers the
		-- assemblies that did not exist yet when it ran.
		setNetworkOwner(parts, nil)
		writeBodyVelocity(parts, carriedVelocity)
	else
		-- A rig with no HumanoidRootPart can't be ball socketed coherently (nothing identifies the one
		-- joint that must stay rigid, so every joint would break and the character would scatter).
		-- Degrade to a suppressed-Humanoid knockdown: still downed and still on the timer, just stiff.
		warn(`RagdollController: {character:GetFullName()} has no HumanoidRootPart -- stiff knockdown only`)
	end

	local entry: ActiveRagdoll = {
		humanoid = humanoid,
		rootPart = rootPart,
		ownerPlayer = ownerPlayer,
		expiry = now + seconds,
		phase = "Limp",
		blendUntil = 0,
		joints = joints,
		parts = parts,
		originalPhysicalProperties = originalPhysicalProperties,
	}
	ragdolls[character] = entry
	applyCollisionGroup(character, parts)
	return entry
end

--------------------------------------------------------------------------------------------------
-- Ragdoll: recovering
--------------------------------------------------------------------------------------------------

-- Whether a body whose window has elapsed is actually done MOVING, which is a different question
-- from whether its timer is up and the reason a knockdown no longer ends the instant it is scheduled
-- to. RagdollSeconds is authored as "how long they're down", but a big launch routinely spends most
-- of that window still in the air: the old timer-only recovery therefore opened the stand-up blend
-- mid-flight, so the body folded itself upright while still travelling and landed neatly on its feet
-- -- which reads as the knockback being shrugged off, exactly opposite to what a finisher is for.
-- (CombatSystem's object stun already had to work around this from the outside: it re-ragdolls a
-- wall-slammed target specifically because the launch's own window "had already run out, or was
-- already folding the body back upright, before the target ever reached the surface".)
--
-- Deliberately a SPEED test, not a ground test. "Is there a floor under me" is the wrong question --
-- a body knocked off a ledge has no floor and must still eventually recover, and a body at rest on a
-- surface this module never learns about (a moving platform, a pile of debris) is settled whether or
-- not a downward ray agrees. Speed answers the thing that actually matters: a body still carrying
-- real momentum has not finished being knocked down.
--
-- A rig with no root part reports settled immediately -- it has no assembly to read a velocity from,
-- and its degraded stiff knockdown has nothing to wait for.
local function isSettled(entry: ActiveRagdoll): boolean
	local rootPart = entry.rootPart
	if not rootPart then
		return true
	end
	return rootPart.AssemblyLinearVelocity.Magnitude <= RAGDOLL_CFG.RecoverSettleSpeed
end

-- Opens the recovery blend -- see Constants.Combat.Ragdoll.RecoverBlendSeconds for what this window
-- buys and why it is physics rather than a scripted pose lerp. Two kinds of drive go on:
--
--   Per joint, an AlignOrientation pulling the CHILD limb back to the parent's captured frame.
--   Attachment0 is the child's attachment and Attachment1 the parent's, deliberately reversed
--   relative to the BallSocketConstraint: with ReactionTorqueEnabled off, AlignOrientation torques
--   only Attachment0's assembly, so this arrangement moves the light limb to the heavy torso rather
--   than the other way round.
--
--   On the root, one AlignOrientation that removes pitch and roll while PRESERVING yaw, so the body
--   stands up facing wherever it landed instead of being spun to some canonical heading. Degenerate
--   cases (a body lying exactly along the world Y axis, so its flattened look vector is noise) fall
--   back to the up vector, then to a fixed heading.
--
-- Both start at zero authority; stepRecovery ramps them in. Friction goes to zero for the duration so
-- it can't fight the fold-back it was tuned to damp.
local function beginRecovery(entry: ActiveRagdoll, now: number): ()
	entry.phase = "Blending"
	entry.blendUntil = now + RAGDOLL_CFG.RecoverBlendSeconds

	for _, joint in ipairs(entry.joints) do
		joint.socket.MaxFrictionTorque = 0

		local align = Instance.new("AlignOrientation")
		align.Name = "RagdollRecoverAlign"
		align.Mode = Enum.OrientationAlignmentMode.TwoAttachment
		align.Attachment0 = joint.attachment1
		align.Attachment1 = joint.attachment0
		align.RigidityEnabled = false
		align.MaxTorque = math.huge
		align.Responsiveness = 0
		align.Parent = joint.motor.Part1
		joint.align = align
	end

	local rootPart = entry.rootPart
	if not rootPart then
		return
	end

	local currentCFrame = rootPart.CFrame
	local flatLook = Vector3.new(currentCFrame.LookVector.X, 0, currentCFrame.LookVector.Z)
	if flatLook.Magnitude < Constants.Combat.MinDirectionMagnitude then
		flatLook = Vector3.new(currentCFrame.UpVector.X, 0, currentCFrame.UpVector.Z)
	end
	if flatLook.Magnitude < Constants.Combat.MinDirectionMagnitude then
		flatLook = Vector3.new(0, 0, -1)
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = NAME_UPRIGHT_ATTACHMENT
	attachment.Parent = rootPart

	local align = Instance.new("AlignOrientation")
	align.Name = NAME_UPRIGHT_ALIGN
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	align.RigidityEnabled = false
	align.MaxTorque = math.huge
	align.Responsiveness = 0
	align.CFrame = CFrame.lookAt(Vector3.zero, flatLook.Unit)
	align.Parent = rootPart
end

-- One tick of the blend. `alpha` runs 0 -> 1 across RecoverBlendSeconds.
--
-- Responsiveness eases in as alpha^2 rather than linearly so the gather starts soft -- a body that
-- has only just stopped tumbling shouldn't be yanked into a pose the same frame its window lapsed.
-- The sockets' cone and twist limits close toward RecoverEndAngle over the same curve, which is what
-- actually GUARANTEES arrival: by the last tick no limb can be more than a few degrees off rest
-- regardless of what the alignment drives managed, so re-enabling the motors has almost nothing left
-- to correct.
--
-- Each joint's parent-side attachment is also re-synced to the motor's live C0 * Transform every
-- tick. The pose was captured when the ragdoll started; if the Animator has moved on since (the
-- Humanoid is suppressed, so usually it hasn't, but a manually played track can), tracking it keeps
-- the physical pose converging on the exact pose the motors will impose, not a stale one.
--
-- Horizontal velocity is scaled down by (1 - alpha) so a body that was sliding when its window
-- expired comes to a stop as it stands rather than moonwalking out of the recovery. Vertical velocity
-- is left alone -- a body recovering mid-air is still falling, and arresting that would read as a
-- mid-air freeze.
local function stepRecovery(entry: ActiveRagdoll, alpha: number): ()
	local eased = alpha * alpha
	local upperAngle = RAGDOLL_CFG.BallSocketUpperAngle
		+ (RAGDOLL_CFG.RecoverEndAngle - RAGDOLL_CFG.BallSocketUpperAngle) * eased
	local twistLower = RAGDOLL_CFG.BallSocketTwistLowerAngle
		+ (-RAGDOLL_CFG.RecoverEndAngle - RAGDOLL_CFG.BallSocketTwistLowerAngle) * eased
	local twistUpper = RAGDOLL_CFG.BallSocketTwistUpperAngle
		+ (RAGDOLL_CFG.RecoverEndAngle - RAGDOLL_CFG.BallSocketTwistUpperAngle) * eased

	for _, joint in ipairs(entry.joints) do
		if joint.motor.Parent then
			joint.attachment0.CFrame = joint.motor.C0 * joint.motor.Transform
		end
		joint.socket.UpperAngle = upperAngle
		joint.socket.TwistLowerAngle = twistLower
		joint.socket.TwistUpperAngle = twistUpper
		local align = joint.align
		if align then
			align.Responsiveness = RAGDOLL_CFG.RecoverJointResponsiveness * eased
		end
	end

	local rootPart = entry.rootPart
	if not rootPart then
		return
	end

	local uprightAlign = rootPart:FindFirstChild(NAME_UPRIGHT_ALIGN)
	if uprightAlign and uprightAlign:IsA("AlignOrientation") then
		uprightAlign.Responsiveness = RAGDOLL_CFG.RecoverUprightResponsiveness * eased
	end

	local velocity = rootPart.AssemblyLinearVelocity
	setLinearVelocity(rootPart, Vector3.new(velocity.X * (1 - alpha), velocity.Y, velocity.Z * (1 - alpha)))
end

-- Tears the ragdoll down and hands the body back. `restore` false is the corpse/despawn path: the
-- constraints and disabled motors are left exactly as they are so a dead body stays limp (and, for a
-- character about to be replaced, so nothing bothers reversing state on instances that are seconds
-- from destruction). Bookkeeping is dropped either way, so nothing leaks in `ragdolls` or in the
-- suppression counts.
local function exitRagdoll(character: Model, entry: ActiveRagdoll, restore: boolean): ()
	if restore then
		restorePhysicalProperties(entry.originalPhysicalProperties)
		for _, joint in ipairs(entry.joints) do
			if joint.align then
				joint.align:Destroy()
			end
			joint.socket:Destroy()
			joint.attachment0:Destroy()
			joint.attachment1:Destroy()
			if joint.motor.Parent then
				joint.motor.Enabled = true
			end
		end
		local rootPart = entry.rootPart
		if rootPart then
			for _, name in ipairs({ NAME_UPRIGHT_ALIGN, NAME_UPRIGHT_ATTACHMENT }) do
				local instance = rootPart:FindFirstChild(name)
				if instance then
					instance:Destroy()
				end
			end
		end
	end

	ragdolls[character] = nil
	releaseHumanoid(entry.humanoid)

	if restore and character.Parent then
		-- Only hands ownership back if nothing else (a live hold) still claims this character -- see
		-- restoreNetworkOwnershipIfUnclaimed's own header. `ragdolls[character]` is already nil above,
		-- so this is really asking "is `character` still held," but goes through the shared helper
		-- rather than a bespoke heldCharacters check so the rule lives in exactly one place.
		restoreNetworkOwnershipIfUnclaimed(character, entry.parts, entry.ownerPlayer)
		applyCollisionGroup(character, entry.parts)
	end
end

--------------------------------------------------------------------------------------------------
-- Ragdoll: public knockback API
--------------------------------------------------------------------------------------------------

-- The one door every knockback goes through, and the only place the ownership -> ragdoll -> velocity
-- ordering exists. `linearVelocity` nil means "don't write one" -- the body keeps the momentum
-- enterRagdoll seeded across its new assemblies, which is what a plain knockdown wants. `spin` is
-- applied to the root only: it is a bias on the tumble, not a per-part rotation, and writing it to
-- every limb would spin each one about its own centre rather than tipping the body.
--
-- The linear write goes onto EVERY part, not just the root -- see writeBodyVelocity for why a
-- root-only write on a freshly-split ragdoll produces flailing instead of flight.
--
-- Clears an existing hold on `rootPart` FIRST, before anything else -- a hold's fixed-point
-- AlignPosition (MaxForce = math.huge) would otherwise keep pulling the body toward its pin point at
-- the exact same moment this knockback's own velocity is trying to launch or slam it, which reads as
-- a weaker, fighting-itself knockback instead of the authored one. AirCombo.lua's own MaxHits branch
-- already had to clear the hold by hand before calling SlamToGround for exactly this reason -- doing
-- it here instead covers every OTHER caller too (a finisher landing on someone else's air-combo
-- target, an object stun re-ragdolling a held body) without one more special case at each call site.
-- A no-op when there's nothing held, so every caller that never overlaps a hold pays nothing for it.
local function applyKnockback(
	character: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	ownerPlayer: Player?,
	seconds: number,
	linearVelocity: Vector3?,
	spin: Vector3?
): ()
	local parts = partsOf(character)
	if holds[rootPart] then
		RagdollController.ClearHold(rootPart, ownerPlayer)
	end

	-- See ensureServerOwnership/pendingKnockbacks' own headers. `owned` false means the assembly
	-- hasn't been confirmed server-owned yet -- the ragdoll entry below has to wait for that (or the
	-- same bounded timeout this used to spend yielding for), and does so from Update instead of
	-- blocking this call, which is what actually lets this function return without ever yielding.
	local owned = ensureServerOwnership(rootPart, parts)
	if not owned then
		pendingKnockbacks[rootPart] = {
			character = character,
			humanoid = humanoid,
			rootPart = rootPart,
			ownerPlayer = ownerPlayer,
			parts = parts,
			seconds = seconds,
			linearVelocity = linearVelocity,
			spin = spin,
			deadline = os.clock() + OWNERSHIP_HANDOFF_TIMEOUT,
		}
		return
	end
	-- Confirmed synchronously (the common case -- a dummy/bot with no client, or a target whose
	-- ownership an earlier call already settled) -- supersede any still-pending record for this same
	-- rootPart, same reasoning as pendingKnockbacks' own header: this fresher call wins outright.
	pendingKnockbacks[rootPart] = nil

	local entry = enterRagdoll(character, humanoid, ownerPlayer, seconds, parts, os.clock())

	if linearVelocity then
		writeBodyVelocity(entry.parts, linearVelocity)
	end
	if spin then
		setAngularVelocity(rootPart, spin)
	end
end

-- Uppercut: ragdoll plus a launch that's up AND away from the attacker (not a pure vertical pop),
-- with a backward angular velocity biasing the tumble to land on its back rather than face-down or
-- at random. A bias at launch, never a forced landing -- this module deliberately never CFrame-snaps
-- a ball-socketed body, which reads as a teleport jerk.
function RagdollController.LaunchAndRagdoll(
	character: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	ownerPlayer: Player?,
	attackerRootPart: BasePart?,
	profile: LaunchProfile
): ()
	local direction = RagdollController.ResolveKnockbackDirection(rootPart, attackerRootPart)
	local axis = resolveTumbleAxis(direction)
	applyKnockback(
		character,
		humanoid,
		rootPart,
		ownerPlayer,
		profile.RagdollSeconds,
		direction * profile.HorizontalVelocity + Vector3.new(0, profile.UpVelocity, 0),
		if axis then axis * profile.BackwardSpin else nil
	)
end

-- Makes a body limp for `seconds` and does nothing else: no launch, no spin, no re-derived direction.
-- The supported door for "this body must be under server physics control for this long," which
-- callers used to have to spell as LaunchAndRagdoll with an all-zero LaunchProfile -- a call that
-- reads like a knockback, is indexed by every search for one, and quietly depends on the fact that a
-- zero direction times a zero speed happens to be harmless.
--
-- The distinction is real and not cosmetic: this writes NO velocity at all, where the zeroed profile
-- wrote Vector3.zero across the whole body. A caller that is about to write its own velocity (an
-- object stun's rebound or pin) does not want the body stopped dead first, and one that isn't wants
-- the momentum enterRagdoll already seeded, not a body frozen in mid-air.
function RagdollController.Ragdoll(
	character: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	ownerPlayer: Player?,
	seconds: number
): ()
	applyKnockback(character, humanoid, rootPart, ownerPlayer, seconds, nil, nil)
end

-- Writes one velocity across the WHOLE body, and the only supported way for anything outside this
-- module to change a ragdolled character's velocity. See writeBodyVelocity's own header for why
-- `rootPart.AssemblyLinearVelocity = v` is a trap on a ragdolled body that reads like it isn't.
--
-- Per-part clamping and the anchored-part skip come free from setLinearVelocity, so a caller cannot
-- accidentally exceed MaxLaunchSpeed through this door either.
function RagdollController.SetBodyVelocity(character: Model, velocity: Vector3): ()
	writeBodyVelocity(partsOf(character), velocity)
end

-- The angular counterpart, and the one a caller that is trying to make a ragdolled body STILL must
-- also call. Killing linear velocity alone leaves every part rotating at whatever rate it arrived
-- with, and a position-only pin (HoldAloft without a LiveBodyFacePoint, which is what an object stun
-- uses) constrains where the root IS without constraining how it is turned -- so the body hangs in
-- place and keeps tumbling, with the limbs whipping around it through the sockets. Stopping a
-- ragdoll is therefore always two writes, never one.
function RagdollController.SetBodyAngularVelocity(character: Model, angularVelocity: Vector3): ()
	for _, part in ipairs(partsOf(character)) do
		setAngularVelocity(part, angularVelocity)
	end
end

-- Distance (studs) from `rootPart`'s centre straight down to the first solid thing beneath the
-- character, or nil when nothing is within SlamGroundCheckDistance (slammed out over a void or off a
-- cliff -- no floor to hit, so no clamp applies). The character's own parts are excluded so its legs
-- never register as the ground under its own root, and non-collidable geometry is ignored so
-- decorative volumes don't read as a floor. A failed cast reports nil, the same "no clamp" answer as
-- an honest miss, which is the safe direction to fail: it preserves the authored slam rather than
-- silently weakening it.
local function resolveGroundClearance(character: Model, rootPart: BasePart): number?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	params.IgnoreWater = true
	params.RespectCanCollide = true

	local ok, result = pcall(function()
		return Workspace:Raycast(rootPart.Position, Vector3.new(0, -RAGDOLL_CFG.SlamGroundCheckDistance, 0), params)
	end)
	if not ok or result == nil then
		return nil
	end
	return (rootPart.Position - result.Position).Magnitude
end

-- How much of a slam's authored force a target actually has room to receive: 1 = full clearance (or
-- no floor found at all), 0 = already standing on the ground with nowhere to fall. See
-- Constants.Combat.Ragdoll.SlamGroundCheckDistance / SlamPenetrationGuardSeconds for the full
-- mechanism and why an unclamped slam on a grounded target ejected the body upward instead of driving
-- it down.
--
-- `restingRootHeight` is what the root's clearance reads as when the character is simply STANDING,
-- derived from the rig itself (half the root's own height plus the Humanoid's hip height) rather than
-- a magic number, so a scaled avatar measures correctly. Subtracting it converts raw clearance into
-- USABLE drop: a standing target measures ~0 no matter how tall it is. R6 reports HipHeight = 0, so
-- an R6 body slightly underestimates its resting height and takes a marginally stronger slam.
--
-- Second return: `immediate`, true when usableDrop is at or below Constants.Combat.Ragdoll.
-- SlamImmediateImpactDropStuds -- see that constant's own header for why SlamToGround's caller needs
-- this as an explicit, authoritative fact rather than leaving the client to infer "did this already
-- hit the ground" from a physics poll that structurally can't catch a same-frame fall-and-arrest.
local function resolveSlamScale(
	character: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	downVelocity: number
): (number, boolean)
	if downVelocity <= 0 then
		return 0, true
	end
	local clearance = resolveGroundClearance(character, rootPart)
	if clearance == nil then
		-- No floor within range at all -- the opposite extreme from "immediate" (a genuine fall with
		-- real, possibly unbounded, hangtime ahead of it).
		return 1, false
	end
	local restingRootHeight = rootPart.Size.Y * 0.5 + humanoid.HipHeight
	local usableDrop = math.max(clearance - restingRootHeight, 0)
	local immediate = usableDrop <= RAGDOLL_CFG.SlamImmediateImpactDropStuds
	local safeSpeed = usableDrop / RAGDOLL_CFG.SlamPenetrationGuardSeconds
	return math.clamp(safeSpeed / downVelocity, 0, 1), immediate
end

-- Downslam: ragdoll (a briefer knockdown than the uppercut's) plus a hard straight-down launch that
-- drives a target back into the floor, biased to land face-down. Still no CFrame snap -- the downward
-- velocity does the grounding.
--
-- The slam IS ground-aware, which is a different thing from snapping: it scales the FORCE to the
-- clearance the target actually has, never moving or reorienting anything directly. This exists
-- because AirSlam gates on the ATTACKER being airborne, not the target, so the common downslam victim
-- is standing on the floor -- and an unclamped DownVelocity written onto feet already touching the
-- ground punched every part through the floor surface and let penetration recovery eject the body
-- upward in pieces. A target with real height on them (the air-combo MaxHits slam from HoverHeight, a
-- genuine airborne victim) clears the clamp outright and still takes the full authored slam.
--
-- The face-down pitch is deliberately NOT scaled by clearance. A downward VELOCITY has nowhere to go
-- on a body already touching the floor, but a PITCH does: a standing body has its own height to rotate
-- through on the way from upright to prone without needing any clearance underneath it. That visible
-- collapse is what actually sells "slammed into the ground" for a grounded target, since the vertical
-- travel reads as nothing. Scaling it down alongside the velocity was an earlier mistake that left a
-- grounded downslam with neither drop nor rotation -- it read as the target quietly sitting down.
--
-- Returns `immediateGroundImpact` (see resolveSlamScale's own header) -- every caller threads this
-- through to the feedback payload that triggers Client/FX/SlamImpactVFX.BeginWatch, so the client
-- knows whether to expect a real, observable fall (the existing velocity-poll detection, which works
-- fine for that case) or an already-resolved contact it should simply show right away.
function RagdollController.SlamToGround(
	character: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	ownerPlayer: Player?,
	attackerRootPart: BasePart?,
	profile: SlamProfile
): boolean
	-- Measured BEFORE the ragdoll. The probe is a plain downward raycast excluding this character, so
	-- ragdolling first wouldn't change the answer, but taking it up front keeps the reading honest even
	-- if a future entry path ever repositions anything.
	local slamScale, immediateGroundImpact = resolveSlamScale(character, humanoid, rootPart, profile.DownVelocity)

	-- Never below SlamMinDownVelocity, so an already-grounded slam still trips SlamImpactVFX's
	-- fall-then-arrest detection and plays its impact; never above the authored DownVelocity, which
	-- stays the ceiling for a target with real height on them.
	local scaledDownVelocity = math.clamp(
		profile.DownVelocity * slamScale,
		math.min(profile.DownVelocity, RAGDOLL_CFG.SlamMinDownVelocity),
		profile.DownVelocity
	)

	-- Same perpendicular-to-travel axis LaunchAndRagdoll uses, but NEGATED: an uppercut rotates the
	-- body's up away from its travel direction (head tips backward, landing on its back), a downslam
	-- wants the opposite sense so the head tips down and forward into a face-first landing.
	local axis = resolveTumbleAxis(RagdollController.ResolveKnockbackDirection(rootPart, attackerRootPart))
	applyKnockback(
		character,
		humanoid,
		rootPart,
		ownerPlayer,
		profile.KnockdownSeconds,
		Vector3.new(0, -scaledDownVelocity, 0),
		if axis then -axis * profile.FaceDownSpin else nil
	)

	return immediateGroundImpact
end

-- Extends an already-ragdolled character's window WITHOUT touching velocity, constraints or network
-- ownership -- for a continuation hit that needs the ragdoll to keep lasting but has nothing new to
-- launch (an air-combo continuation: the target's position is already owned by HoldAloft, so calling
-- a full knockback with a zero velocity just to touch the timer was also stomping whatever the hold
-- had settled into, forcing a re-accelerate from rest on every landed hit). A no-op if the character
-- isn't ragdolled. Deliberately does NOT cancel an in-progress recovery blend: a caller with nothing
-- to launch has nothing to re-limp the body with either, and the blend is already committed to
-- standing it up.
--
-- Returns whether the extension actually applied -- false meaning the character is not ragdolled at
-- all, or is already blending back upright. A caller that merely wants the timer nudged (the
-- air-combo continuation above) can ignore that; a caller that REQUIRES the body limp for a window of
-- its own cannot, because a silent no-op leaves it operating on a live, client-simulated body. That
-- is exactly how CombatSystem's object stun used to end up pinning a wall-slammed target who had
-- already recovered mid-flight -- the pin was built, and the target's own client walked out of it.
function RagdollController.ExtendRagdoll(character: Model, seconds: number): boolean
	local entry = ragdolls[character]
	if entry and entry.phase == "Limp" then
		entry.expiry = math.max(entry.expiry, os.clock() + seconds)
		return true
	end
	return false
end

-- Immediate recovery, out of band with the timer. CombatSystem calls this when a ragdolled character
-- dies, despawns, or is administratively reset, so nothing leaks onto a body that's about to be
-- replaced or handed back to its player. Safe on a character that isn't ragdolled.
--
-- A living, still-parented character is fully restored on the spot (motors back, control back) --
-- that's the reset case, where the point is to make the player playable again NOW and a smooth blend
-- would just be latency. A corpse or a despawning character is abandoned limp instead: standing a
-- dead body up is the exact snap CombatSystem.confirmDeath avoids, and a character being replaced has
-- nothing worth restoring.
function RagdollController.Recover(character: Model): ()
	local entry = ragdolls[character]
	if not entry then
		return
	end
	local alive = character.Parent ~= nil and entry.humanoid.Parent ~= nil and entry.humanoid.Health > 0
	exitRagdoll(character, entry, alive)
end

--------------------------------------------------------------------------------------------------
-- Holds
--------------------------------------------------------------------------------------------------

-- Quiets a LIVE (non-ragdolled) held body's Humanoid so only the AlignPosition drives it. A live
-- Humanoid keeps running its own controller in the air (Freefall state machine, balance, landing
-- detection) even while server-owned, and that controller fights the pin every frame -- the rise
-- stutters and steps instead of gliding. A ragdolled target doesn't need this because enterRagdoll
-- already suppressed its Humanoid.
--
-- Swinging still works: attacks are RemoteEvents CombatSystem validates against stun/posture/ragdoll/
-- cooldown, none of which PlatformStand touches, and AnimationTracks play independent of Humanoid
-- movement state.
--
-- Also zeroes whatever momentum the body carried INTO the hold, exactly once. Both hold constraints
-- are deliberately SOFT (the AlignPosition so the rise reads as flight rather than a teleport, the
-- AlignOrientation so a large re-facing eases instead of snapping) and both only ever CORRECT
-- position and orientation with force and torque -- neither resets existing velocity. A body arriving
-- with real dash momentum therefore visibly coasts and spins while the soft pulls fight it down from
-- a standing start, instead of the gentle settle that softness was meant to read as. By the time a
-- continuation hit refreshes the hold the constraints have long since damped the assembly to rest, so
-- there is nothing left to re-zero.
local function enterLiveHold(rootPart: BasePart, record: ActiveHold): ()
	if record.humanoid then
		return
	end
	local character = record.character
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	record.humanoid = humanoid
	suppressHumanoid(humanoid)
	pcall(function()
		rootPart.AssemblyLinearVelocity = Vector3.zero
		rootPart.AssemblyAngularVelocity = Vector3.zero
	end)
end

-- Adds (or refreshes) a VectorForce that exactly cancels gravity on the held assembly, so an
-- AlignPosition holding a LIVE body doesn't have to fight gravity to stay put. An AlignPosition's
-- Responsiveness behaves like a spring stiffness even at MaxForce = math.huge: under a constant
-- disturbance a SOFT responsiveness settles with a large following error, i.e. the body hangs well
-- BELOW its target ("floating down, never reaching them"). The ragdolled target tolerates this at its
-- stiffer HoverResponsiveness; the attacker, held at the deliberately soft ChaseResponsiveness that
-- reads as flight, sagged badly. Cancelling gravity removes the disturbance entirely, keeping both the
-- flight feel and the reach. Sized to the assembly's own mass and recomputed on every refresh so a
-- mass change between hits stays correct; applied at the centre of mass so it contributes no torque.
--
-- Only the live hold uses this. A ragdolled target is a split multi-assembly body whose limbs are
-- meant to hang, and cancelling gravity on the root alone would leave them hanging off a floating
-- torso.
local function ensureGravityCancel(rootPart: BasePart, attachment: Attachment): ()
	local existing = rootPart:FindFirstChild(NAME_HOLD_GRAVITY_CANCEL)
	local force: VectorForce
	if existing and existing:IsA("VectorForce") then
		force = existing
	else
		if existing then
			existing:Destroy()
		end
		local created = Instance.new("VectorForce")
		created.Name = NAME_HOLD_GRAVITY_CANCEL
		created.Attachment0 = attachment
		created.ApplyAtCenterOfMass = true
		created.RelativeTo = Enum.ActuatorRelativeTo.World
		created.Parent = rootPart
		force = created
	end
	force.Force = Vector3.new(0, rootPart.AssemblyMass * Workspace.Gravity, 0)
end

-- Faces a live held body horizontally toward `facePoint` via a SOFT AlignOrientation. Without it the
-- body's facing is frozen at whatever it last had, so once both bodies settle at their standoff
-- positions the other one sits slightly off that frozen line and every continuation swing is rejected
-- "OutsideArc" -- the combo lands its first hit then whiffs the rest.
--
-- Soft rather than rigid because SwitchPriority can re-point a body that was facing ANY direction a
-- moment ago, and an instant re-facing whips the third-person camera (which follows the character's
-- own back) around with it. Eased Responsiveness turns that into a pan instead of a snap. See
-- Constants.Combat.Ragdoll.FaceOrientationResponsiveness for why the gain is what it is.
local function ensureFaceOrientation(
	rootPart: BasePart,
	attachment: Attachment,
	holdPosition: Vector3,
	facePoint: Vector3
): ()
	local flatFace = Vector3.new(facePoint.X, holdPosition.Y, facePoint.Z)
	if (flatFace - holdPosition).Magnitude < RAGDOLL_CFG.FaceAlignToleranceStuds then
		-- Target directly overhead (degenerate horizontal direction) -- keep whatever facing exists
		-- rather than aligning to a near-zero look vector.
		return
	end
	local lookCFrame = CFrame.lookAt(holdPosition, flatFace)

	local existing = rootPart:FindFirstChild(NAME_HOLD_ORIENT)
	if existing and existing:IsA("AlignOrientation") then
		existing.CFrame = lookCFrame
		return
	end
	if existing then
		existing:Destroy()
	end
	local orient = Instance.new("AlignOrientation")
	orient.Name = NAME_HOLD_ORIENT
	orient.Mode = Enum.OrientationAlignmentMode.OneAttachment
	orient.Attachment0 = attachment
	orient.RigidityEnabled = false
	-- A float, NOT a Vector3 (that's BodyGyro's shape). Assigning a Vector3 here raises, and this
	-- construction runs inside HoldAloft's build pcall -- which is what made every live-body hold fail
	-- to build and immediately tear itself down, so the attacker's chase pin and a live victim's hover
	-- pin never existed at all.
	orient.MaxTorque = math.huge
	orient.Responsiveness = RAGDOLL_CFG.FaceOrientationResponsiveness
	orient.CFrame = lookCFrame
	orient.Parent = rootPart
end

-- Stops an in-progress hold on `rootPart`, if any: forgets the pending auto-release, destroys the pin
-- instances, releases the Humanoid suppression a live hold claimed, restores network ownership, and
-- re-derives the collision group -- which, note, puts a still-ragdolled body back into GROUP_RAGDOLL
-- rather than Default, so releasing the hold on a ragdolled air-combo target never silently drops its
-- self-collision protection.
--
-- Called by HoldAloft itself (to rebuild a stale hold), by Update (when the hold's own window
-- elapses), and directly by callers ending a sequence early (the slam finisher, so a lingering upward
-- pin doesn't fight the slam's own downward velocity; the attacker's own hold, so movement control
-- returns immediately rather than a few hundred ms late). `ownerPlayer` nil restores automatic
-- ownership (a dummy); a real player gets their own back.
--
-- Does NOT run HoldProfile.OnRelease -- see that field's own header. A caller reaching this function
-- directly is taking the body over, and Update is the one path that fires the callback, immediately
-- after calling this.
--
-- This restores PHYSICAL control only. It does NOT touch CombatState.AirCombo.airComboChaseExpiry
-- (this module owns no combat state), so a caller clearing the ATTACKER's hold early MUST zero that
-- field itself in the same breath, or the player stays pinned at WalkSpeed 0 for whatever's left of
-- the original window even though the pull already stopped.
function RagdollController.ClearHold(rootPart: BasePart, ownerPlayer: Player?): ()
	local record = holds[rootPart]
	if record then
		holds[rootPart] = nil
		local character = record.character
		if character then
			local count = (heldCharacters[character] or 1) - 1
			heldCharacters[character] = if count > 0 then count else nil
		end
	end

	for _, name in ipairs(HOLD_INSTANCE_NAMES) do
		local instance = rootPart:FindFirstChild(name)
		if instance then
			instance:Destroy()
		end
	end

	-- Restore the Humanoid BEFORE handing ownership back, matching exitRagdoll's order -- a client that
	-- resumes simulating a body still stuck in PlatformStand reads as a frozen character.
	if record and record.humanoid then
		releaseHumanoid(record.humanoid)
	end

	local characterInstance = if record then record.character else rootPart.Parent
	local character: Model? = if characterInstance and characterInstance:IsA("Model") then characterInstance else nil
	if character then
		applyCollisionGroup(character, partsOf(character))
	end

	if rootPart.Parent then
		-- Only hands ownership back if nothing else (a live ragdoll) still claims this character --
		-- see restoreNetworkOwnershipIfUnclaimed's own header. `heldCharacters[character]` is already
		-- decremented above, so this is really asking "is `character` still ragdolled." A hold's own
		-- ownership grab (HoldAloft's SetNetworkOwner(nil)) only ever touches rootPart's own assembly
		-- (never split into several, unlike a ragdoll), so restoring through rootPart alone here still
		-- covers the whole body when nothing else is claiming it -- exactly what the direct
		-- SetNetworkOwner call this replaces did.
		restoreNetworkOwnershipIfUnclaimed(character, { rootPart }, ownerPlayer)
	end
end

-- Position control: pins `rootPart` to a single FIXED `profile.Position` for `profile.DurationSeconds`
-- via a server-side AlignPosition, then releases it. Used for BOTH sides of an air combo (the target's
-- hover and the attacker's standoff point near them) and for an object stun's wall pin. These were
-- once two mechanisms (this one, and a chase that re-targeted an AlignPosition to the target's live
-- position every Heartbeat); they collapsed into one because once the target's position stops moving
-- there is nothing left to track, and re-assigning an already-converged AlignPosition's Position 60
-- times a second visibly disturbs its own responsiveness ramp -- it read as "snap up snap up" instead
-- of one continuous rise. Position is therefore written ONCE per call and Roblox's solver enforces it
-- every step with no further script involvement.
--
-- `profile.Position` is computed ONCE by the caller at sequence-start and MUST be reused verbatim by
-- every continuation hit rather than recomputed from wherever things currently are -- recomputing is
-- what let a fast combo ratchet the target's height up hit over hit.
--
-- `profile.LiveBodyFacePoint` marks this as a LIVE (non-ragdolled) hold and is the world point to keep
-- the body facing. Non-nil triggers the full live-body treatment: gravity cancellation so the soft pin
-- doesn't sag, Humanoid quieting so the rise doesn't stutter, and a face orientation so swings keep
-- landing. A ragdolled target passes nil -- its ragdoll already handed control to physics and it has
-- no swings to aim.
--
-- Takes and holds server ownership for the duration. Safe for a ragdolled target (already suppressed,
-- no WASD to fight). For a LIVE attacker, network ownership alone does NOT stop their held WASD from
-- commanding Humanoid movement server-side -- the server simulates their Humanoid off replicated move
-- input regardless of who owns the part. Suppressing the Humanoid here handles the controller;
-- silencing WalkSpeed is CombatState.AirCombo.airComboChaseExpiry's job (Movement.
-- ComputeDesiredWalkSpeed pins it to 0 while active), which every caller using this for the ATTACKER
-- side is responsible for setting in the same breath.
--
-- Refreshes in place: calling this again on a rootPart that's already pinned updates Position and
-- pushes the release out without destroying and recreating the constraint or re-applying
-- MaxSpeed/Responsiveness (a live AlignPosition keeps its tuning). A caller that needs a rootPart
-- re-pinned with DIFFERENT tuning -- a SwitchPriority role swap, where a hover pin becomes a chase pin
-- -- must ClearHold first so this rebuilds it.
--
-- Returns whether the pin actually exists once this call returns -- false on either failure exit
-- below (an anchored rootPart, a construction pcall that threw). A caller that writes combat state
-- assuming the pin exists (ACTION_GATES.HeldAloft's WalkSpeed-0/root-lock, airComboHeldExpiry) has to
-- know when it didn't: a failed hold used to leave a player frozen by state that believed a
-- constraint existed when nothing was actually holding them up, with no way for the caller to tell.
function RagdollController.HoldAloft(rootPart: BasePart, ownerPlayer: Player?, profile: HoldProfile): boolean
	if rootPart.Anchored then
		return false
	end

	local expiresAt = os.clock() + profile.DurationSeconds

	local existingRecord = holds[rootPart]
	local existingAlign = rootPart:FindFirstChild(NAME_HOLD_ALIGN)
	if existingRecord and existingAlign and existingAlign:IsA("AlignPosition") then
		existingAlign.Position = profile.Position
		if profile.LiveBodyFacePoint then
			local attachment = rootPart:FindFirstChild(NAME_HOLD_ATTACHMENT)
			if attachment and attachment:IsA("Attachment") then
				ensureGravityCancel(rootPart, attachment)
				ensureFaceOrientation(rootPart, attachment, profile.Position, profile.LiveBodyFacePoint)
			end
			enterLiveHold(rootPart, existingRecord)
		end
		existingRecord.ownerPlayer = ownerPlayer
		existingRecord.expiresAt = expiresAt
		existingRecord.onRelease = profile.OnRelease
		return true
	end

	-- Not held, or held by a half-built/stale set of instances -- tear down whatever is there and
	-- build fresh. ClearHold also hands ownership back, which the SetNetworkOwner(nil) below then
	-- immediately reclaims; doing it in that order means a failure partway through construction leaves
	-- ownership where it belongs rather than stranded on the server.
	RagdollController.ClearHold(rootPart, ownerPlayer)

	local characterInstance = rootPart.Parent
	local character: Model? = if characterInstance and characterInstance:IsA("Model") then characterInstance else nil
	local record: ActiveHold = {
		character = character,
		humanoid = nil,
		ownerPlayer = ownerPlayer,
		expiresAt = expiresAt,
		onRelease = profile.OnRelease,
	}
	holds[rootPart] = record
	if character then
		heldCharacters[character] = (heldCharacters[character] or 0) + 1
	end

	pcall(function()
		rootPart:SetNetworkOwner(nil)
	end)

	local built = pcall(function()
		local attachment = Instance.new("Attachment")
		attachment.Name = NAME_HOLD_ATTACHMENT
		attachment.Parent = rootPart

		local alignPosition = Instance.new("AlignPosition")
		alignPosition.Name = NAME_HOLD_ALIGN
		alignPosition.Attachment0 = attachment
		alignPosition.Mode = Enum.PositionAlignmentMode.OneAttachment
		alignPosition.MaxForce = math.huge
		alignPosition.MaxVelocity = profile.MaxSpeed
		alignPosition.Responsiveness = profile.Responsiveness
		alignPosition.Position = profile.Position
		alignPosition.Parent = rootPart

		if profile.LiveBodyFacePoint then
			ensureGravityCancel(rootPart, attachment)
			ensureFaceOrientation(rootPart, attachment, profile.Position, profile.LiveBodyFacePoint)
		end
	end)

	if not built then
		-- ClearHold undoes the partial build AND the ownership grab above, neither of which a bespoke
		-- teardown here would cover -- a failed hold used to leave the rootPart stuck server-owned with
		-- nothing to ever hand it back.
		RagdollController.ClearHold(rootPart, ownerPlayer)
		return false
	end

	-- Only once the pin actually exists, and outside the pcall above: this changes Humanoid properties
	-- rather than building physics instances, so it isn't part of the same construction that can fail.
	if profile.LiveBodyFacePoint then
		enterLiveHold(rootPart, record)
	end

	if character then
		applyCollisionGroup(character, partsOf(character))
	end

	return true
end

--------------------------------------------------------------------------------------------------
-- Tick
--------------------------------------------------------------------------------------------------

-- Driven once per tick from CombatSystem.onHeartbeat -- this module opens no Heartbeat connection of
-- its own, same as HitboxResolver. Resolves knockbacks still waiting on a network-ownership handoff,
-- advances every ragdoll's lifecycle (limp -> blend -> gone), expires and settles live holds, and
-- prunes bookkeeping for characters that vanished without a clean release.
--
-- Removing keys from a table mid-`pairs` is well defined in Luau (only ADDING during traversal is
-- not), so the recovery paths below can clear their own entry inline.
function RagdollController.Update(now: number): ()
	-- Pending knockbacks first, so one that clears THIS tick enters the ragdoll loop below in the
	-- same Update call that just confirmed it, rather than waiting one more tick to be picked up. See
	-- pendingKnockbacks/ensureServerOwnership's own headers for why this exists instead of the
	-- knockback's own caller blocking on it.
	if next(pendingKnockbacks) ~= nil then
		for rootPart, pending in pairs(pendingKnockbacks) do
			if pending.character.Parent == nil or pending.humanoid.Parent == nil or pending.humanoid.Health <= 0 then
				-- Despawned, or died while waiting -- see enterRagdoll's own corpse handling elsewhere in
				-- this module; nothing left to launch onto a body that isn't there to receive it, and a
				-- dead one gets Roblox's own death handling instead (confirmDeath's own comment).
				pendingKnockbacks[rootPart] = nil
				continue
			end

			local currentOwner
			local stillOwned = pcall(function()
				currentOwner = rootPart:GetNetworkOwner()
			end)
			local confirmed = not stillOwned or currentOwner == nil
			if not confirmed and now < pending.deadline then
				-- Still not confirmed, still within the window -- ask again (setNetworkOwner is safe to
				-- repeat) and check again next tick.
				setNetworkOwner(pending.parts, nil)
				continue
			end

			pendingKnockbacks[rootPart] = nil
			local entry = enterRagdoll(
				pending.character,
				pending.humanoid,
				pending.ownerPlayer,
				pending.seconds,
				pending.parts,
				now
			)
			if pending.linearVelocity then
				writeBodyVelocity(entry.parts, pending.linearVelocity)
			end
			if pending.spin then
				setAngularVelocity(rootPart, pending.spin)
			end
		end
	end

	for character, entry in pairs(ragdolls) do
		if character.Parent == nil or entry.humanoid.Parent == nil then
			-- Vanished without CombatSystem getting a lifecycle callback in first. Drop the bookkeeping
			-- (including the suppression claim) but restore nothing -- there is nothing left to restore.
			exitRagdoll(character, entry, false)
		elseif entry.phase == "Limp" then
			if now >= entry.expiry then
				-- The window is up, but a body still travelling does not stand up in mid-air -- see
				-- isSettled. RecoverSettleMaxSeconds caps the wait so a body that never comes to rest (a
				-- conveyor, a bottomless fall, a part the solver refuses to damp) still recovers rather
				-- than staying limp forever.
				if isSettled(entry) or now >= entry.expiry + RAGDOLL_CFG.RecoverSettleMaxSeconds then
					beginRecovery(entry, now)
				end
			elseif entry.humanoid.Health > 0 and not entry.humanoid.PlatformStand then
				-- Something else (a seat, an unrelated system) un-suppressed this Humanoid mid-window; its
				-- controller would otherwise start fighting the ball sockets for the rest of the ragdoll.
				entry.humanoid.PlatformStand = true
			end
		elseif now >= entry.blendUntil then
			exitRagdoll(character, entry, true)
		else
			local remaining = entry.blendUntil - now
			stepRecovery(entry, math.clamp(1 - remaining / RAGDOLL_CFG.RecoverBlendSeconds, 0, 1))
		end
	end

	-- Expired holds are collected first and released after the traversal, never inside it. Releasing
	-- one runs its OnRelease -- arbitrary gameplay code, which for an object stun's wall pin goes on
	-- to slam the body and could in principle pin something again -- and ADDING a key to a table
	-- being traversed is the one thing Luau's `pairs` genuinely does not define (removal, which the
	-- ragdoll loop above relies on, is fine). Almost always empty, so this costs an allocation only
	-- on the ticks where a hold actually ends.
	local expiredHolds: { BasePart }? = nil

	for rootPart, record in pairs(holds) do
		if rootPart.Parent == nil then
			-- Vanished mid-hold. Drop the bookkeeping directly rather than going through ClearHold: its
			-- instance teardown and ownership restore have nothing left to act on, and its collision-group
			-- re-derive would walk a destroyed character.
			holds[rootPart] = nil
			local character = record.character
			if character then
				local count = (heldCharacters[character] or 1) - 1
				heldCharacters[character] = if count > 0 then count else nil
			end
			if record.humanoid then
				releaseHumanoid(record.humanoid)
			end
		elseif now >= record.expiresAt then
			if expiredHolds then
				table.insert(expiredHolds, rootPart)
			else
				expiredHolds = { rootPart }
			end
		elseif record.humanoid then
			-- Continuously damp angular velocity on every LIVE held body. enterLiveHold zeroes it once
			-- when the hold begins, which stops the body coasting in on dash momentum -- but a live body
			-- keeps its full Motor6D rig and can keep SWINGING mid-hold, and on a free-floating airborne
			-- assembly with nothing to brace against, each swing's Motor6D-driven arm motion imparts a
			-- real reaction torque on the torso (the Newton's-third-law wobble an astronaut gets moving a
			-- limb in zero-g). The face-orientation constraint is a soft torque drive, not a kinematic
			-- weld, so between its corrective frames that reaction torque accumulates into a building
			-- spin. Heartbeat fires AFTER the physics step, so this frame's corrective rotation is already
			-- baked into the body's orientation by the time this runs -- zeroing here wipes the leftover
			-- before it can compound into the next frame, without ever preventing the constraint from
			-- turning the body.
			pcall(function()
				rootPart.AssemblyAngularVelocity = Vector3.zero
			end)
		end
	end

	if expiredHolds then
		for _, rootPart in ipairs(expiredHolds) do
			local record = holds[rootPart]
			if record then
				local onRelease = record.onRelease
				RagdollController.ClearHold(rootPart, record.ownerPlayer)
				if onRelease then
					-- Spawned rather than called inline: the callback is gameplay code, and neither an
					-- error nor a yield inside it may stop the remaining releases from happening.
					task.spawn(onRelease)
				end
			end
		end
	end

	-- Suppression claims are released by the paths that take them; this only catches a Humanoid that
	-- was destroyed out from under one (a respawn racing a release), so the table can't grow across a
	-- session.
	for humanoid in pairs(suppressions) do
		if humanoid.Parent == nil then
			suppressions[humanoid] = nil
		end
	end
end

--------------------------------------------------------------------------------------------------
-- Queries
--------------------------------------------------------------------------------------------------

-- Whether this character is physically under server control right now, in either phase. The honest
-- answer to "can this body act", which a caller previously had to approximate from its own mirrored
-- timestamp -- and that approximation is now genuinely wrong for up to RecoverSettleMaxSeconds,
-- because recovery waits for the body to stop moving (isSettled) rather than for the clock alone.
function RagdollController.IsRagdolled(character: Model): boolean
	return ragdolls[character] ~= nil
end

-- "Limp" (physics owns the body) or "Blending" (it is folding back upright), nil when not ragdolled.
-- The distinction a caller needs in order to tell "still being knocked down" from "already getting
-- up" -- ExtendRagdoll's own false return encodes the same split for the one caller that only wanted
-- the timer, but a caller deciding whether to START something needs to ask before acting.
function RagdollController.GetPhase(character: Model): RagdollPhase?
	local entry = ragdolls[character]
	return if entry then entry.phase else nil
end

-- Seconds until this body is physically free again -- the remaining limp window, plus the recovery
-- blend that always follows it, or 0 when the character isn't ragdolled. This is how a caller keeps
-- its own action lockout in lockstep with physical reality (CombatState.Vitals.ragdollExpiry's whole
-- stated purpose): a body waiting to settle past its authored window reports the time it has actually
-- got left, so the lockout tracks the body instead of drifting off a timestamp stamped at hit time.
--
-- An unsettled body reports the blend alone once its authored window has lapsed, which is a FLOOR
-- rather than a prediction -- how long it keeps flying is a physics question this module can't answer
-- ahead of time, so a caller that needs the lockout to keep up polls this per tick rather than
-- stamping it once.
function RagdollController.RemainingSeconds(character: Model, now: number): number
	local entry = ragdolls[character]
	if not entry then
		return 0
	end
	if entry.phase == "Blending" then
		return math.max(entry.blendUntil - now, 0)
	end
	return math.max(entry.expiry - now, 0) + RAGDOLL_CFG.RecoverBlendSeconds
end

-- Whether any part of this character is currently pinned by a hold.
function RagdollController.IsHeld(character: Model): boolean
	return heldCharacters[character] ~= nil
end

function RagdollController.ActiveRagdollCount(): number
	local count = 0
	for _ in pairs(ragdolls) do
		count += 1
	end
	return count
end

return RagdollController
