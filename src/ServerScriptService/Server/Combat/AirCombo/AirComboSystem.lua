--!strict
--[[
	AirComboSystem.lua

	Owns: air combos, end to end -- the launch, the hover (a server-owned victim sprung to a point above
	where the launch landed), the shared continuation deadline, the air string's scaling, every way a combo
	ends, the two finishers' outcomes (Slam's knockdown, Spike's flight and wall splat), and publishing all
	of it as the Attributes every other system reads. The design is docs/design/air-combat-and-evade.md
	(Part B); AirComboMachine.lua holds its rules as pure functions, and this module applies them.

	    HitboxEngine     where the volume is, who is inside it
	    DefenseSystem    what kind of hit that was (and, for an air-held defender, that a guard is nothing)
	    DamageSystem     how much it hurts
	    AirComboSystem   what a launch does to both bodies, and how the air string plays out   <- this module

	A SIBLING OF THE ATTACK LAYER, SHAPED LIKE GrabSystem. It subscribes to DamageSystem.OnApplied (every
	outcome kind fires there, Parried included, so launches, air hits, parries and third-party hits all
	arrive through one subscription), holds DamageSystem's one air-combo hook slot for the damage scaling,
	and is READ by AttackRequestSystem.Throw through CanAttack -- a fourth gate of the same shape as
	DefenseSystem/DamageSystem/GrabSystem.CanAttack -- and ResolvePress. Nothing below the attack layer
	requires it: DefenseSystem, RunSystem-style readers and both clients learn everything from Attributes.

	THE VICTIM'S BODY IS THE SERVER'S WHILE HELD -- PlatformStand + SetNetworkOwner(nil) + RootControlLocked,
	GrabSystem's proven technique -- and is driven toward a FlightMath.SpringStep hover each Heartbeat, so the
	victim's server position is authoritative for every hitbox and cannot be dragged out of the hover by a
	modified client. THE ATTACKER'S BODY STAYS THEIR OWN: Client/Combat/AirComboClient.lua follows from the
	published anchor, and this module only AUDITS the spacing (SpacingFail). A server-owned attacker (the
	training bot) has no client to follow with, so it is driven here, to the same slot.

	EVERY RELEASE GOES THROUGH A TROVE, so an error mid-combo cannot leave a player server-owned and
	platform-standing: each session's constraints and body state are one Trove, cleaned on every ending.

	Does not own: what a press means outside a combo (SwingSequencer), whether a contact was a parry
	(DefenseSystem -- including the air parry's lag rewind, which lives there because the parry's own clock
	does), the attacker's follow (AirComboClient), or any presentation (Client/FX/AirComboFX.lua).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local AirComboConstants = require(ReplicatedStorage.Shared.AirCombo.AirComboConstants)
local AirComboMoves = require(ReplicatedStorage.Shared.AirCombo.AirComboMoves)
local AirComboTypes = require(ReplicatedStorage.Shared.AirCombo.AirComboTypes)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)
local DamageTypes = require(ReplicatedStorage.Shared.Damage.DamageTypes)
local DefenseTypes = require(ReplicatedStorage.Shared.Defense.DefenseTypes)
local FlightMath = require(ReplicatedStorage.Shared.FlightMath)
local Logger = require(ReplicatedStorage.Shared.Logger)
local Trove = require(ReplicatedStorage.Shared.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local AirComboMachine = require(script.Parent.AirComboMachine)
local DamageSystem = require(script.Parent.Parent.Damage.DamageSystem)
local DefenseSystem = require(script.Parent.Parent.Defense.DefenseSystem)
local NetworkLatency = require(script.Parent.Parent.NetworkLatency)
local RootControl = require(script.Parent.Parent.RootControl)

type Combo = AirComboTypes.Combo
type EndReason = AirComboTypes.EndReason
type Phase = AirComboTypes.Phase
type MoveRole = AirComboTypes.MoveRole
type FinisherKind = AirComboTypes.FinisherKind
type DefenseOutcome = DefenseTypes.DefenseOutcome
type DamageResult = DamageTypes.DamageResult

local ATTRIBUTES = AttributeConstants
local HOVER = AirComboConstants.Hover
local FOLLOW = AirComboConstants.Follow
local TIMING = AirComboConstants.Timing

local logger = Logger.scope("AirComboSystem")

local AirComboSystem = {}

-- One live combo. Keyed twice (byVictim, byAttacker) so every gate is an O(1) read from either side.
type Session = {
	Combo: Combo,
	Attacker: Model,
	Victim: Model,
	AttackerHumanoid: Humanoid,
	VictimHumanoid: Humanoid,
	AttackerRoot: BasePart,
	VictimRoot: BasePart,
	-- Whether each body is a player's (client-simulated) or the server's own (a bot, a dummy).
	AttackerIsPlayer: boolean,
	VictimIsPlayer: boolean,
	Anchor: Vector3,
	SpringPosition: Vector3,
	SpringVelocity: Vector3,
	-- The victim's hover constraints and body state; cleaned on every ending.
	VictimTrove: Trove.TroveInstance,
	VictimAlign: AlignPosition,
	VictimOrient: AlignOrientation,
	-- A server-owned attacker's follow constraints, or nil for a player (their own client follows).
	AttackerTrove: Trove.TroveInstance?,
	AttackerAlign: AlignPosition?,
	AttackerOrient: AlignOrientation?,
	-- Spacing audit: when the attacker was first seen out of its slot, or nil while it is in it.
	OutOfSlotSince: number?,
	-- Last values written to the replicated Attributes, so an unchanged value is never rewritten.
	PublishedHoldUntil: number?,
	PublishedPhase: Phase?,
	-- Set by the finisher that ended the combo, read by the aftermath.
	Finisher: FinisherKind?,
}

-- What happens to a victim's body after the combo is over. Slam and Spike keep it server-owned for their
-- own short flight; Fall has already handed it back and only watches for the landing (Recovering).
type Aftermath = {
	Kind: "Slam" | "Spike" | "Fall",
	Victim: Model,
	Humanoid: Humanoid,
	Root: BasePart,
	Attacker: Model?,
	StartedAt: number,
	-- Slam: when the drop landed, or nil while still dropping.
	LandedAt: number?,
	Trove: Trove.TroveInstance?,
}

local byVictim: { [Model]: Session } = {}
local byAttacker: { [Model]: Session } = {}
local aftermaths: { [Model]: Aftermath } = {}
-- When each Humanoid's lingering end phase clears (TIMING.PhaseLingerSeconds).
local phaseClearAt: { [Humanoid]: number } = {}

local started = false
local heartbeatTrove = Trove.New()
local appliedDisconnect: (() -> ())? = nil

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.RespectCanCollide = true
local rayFilter: { Instance } = {}

-- Helpers ------------------------------------------------------------------------------------------

local function debugLog(message: string, data: { [string]: any }?): ()
	if AirComboConstants.Debug.Enabled then
		logger:debug(message, data)
	end
end

-- A server os.clock() time converted to workspace:GetServerTimeNow() time, for an Attribute a client reads
-- (AttributeConstants' air-combo note on why the published deadlines use the shared clock).
local function toServerTime(at: number, now: number): number
	return Workspace:GetServerTimeNow() + (at - now)
end

local function isLanded(kind: DefenseTypes.OutcomeKind): boolean
	return kind == "Clean" or kind == "Backstab" or kind == "GuardBroken"
end

local function flat(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

local function flatUnit(vector: Vector3, fallback: Vector3): Vector3
	local flattened = flat(vector)
	if flattened.Magnitude < 1e-3 then
		return fallback
	end
	return flattened.Unit
end

-- A player-backed model's network latency (Player:GetNetworkPing), or 0 for a bot or a dummy.
local function pingOf(model: Model): number
	return NetworkLatency.PingSeconds(model)
end

local function setAttribute(humanoid: Humanoid, name: string, value: any): ()
	if humanoid.Parent ~= nil and humanoid:GetAttribute(name) ~= value then
		humanoid:SetAttribute(name, value)
	end
end

local function setPhase(humanoid: Humanoid, phase: Phase?, now: number, linger: boolean): ()
	setAttribute(humanoid, ATTRIBUTES.AirComboPhase, phase)
	if linger and phase ~= nil then
		phaseClearAt[humanoid] = now + TIMING.PhaseLingerSeconds
	else
		phaseClearAt[humanoid] = nil
	end
end

-- The attacker's slot for a hover at `anchor`: StandoffStuds back along the attacker->victim flat line, and
-- BelowStuds down -- the same arithmetic Client/Combat/AirComboClient.lua follows to.
local function slotFor(anchor: Vector3, attackerPosition: Vector3): Vector3
	local toVictim = flatUnit(anchor - attackerPosition, Vector3.new(0, 0, -1))
	return anchor - toVictim * FOLLOW.StandoffStuds - Vector3.new(0, FOLLOW.BelowStuds, 0)
end

local function groundBelow(root: BasePart, distance: number, ignore: { Instance }): boolean
	table.clear(rayFilter)
	for _, instance in ignore do
		table.insert(rayFilter, instance)
	end
	rayParams.FilterDescendantsInstances = rayFilter
	return Workspace:Raycast(root.Position, Vector3.new(0, -distance, 0), rayParams) ~= nil
end

-- Takes a body for the server: platform-standing (a free physics body, no Humanoid ground handling),
-- simulated here, and parked for the parkour framework. Everything it changes is undone by `trove`.
local function takeBody(humanoid: Humanoid, root: BasePart, isPlayer: boolean, trove: Trove.TroveInstance): ()
	humanoid.PlatformStand = true
	-- A claim (Server/Combat/RootControl.lua): a stagger or a grab on the same body is held independently.
	RootControl.Claim(humanoid, RootControl.Owners.AirCombo)
	if isPlayer then
		-- pcall-guarded the way GrabSystem's own call is: SetNetworkOwner throws on an anchored part.
		pcall(function()
			root:SetNetworkOwner(nil)
		end)
	end
	trove:Add(function()
		if humanoid.Parent ~= nil then
			humanoid.PlatformStand = false
		end
		RootControl.Release(humanoid, RootControl.Owners.AirCombo)
		if isPlayer and root.Parent ~= nil then
			pcall(function()
				root:SetNetworkOwnershipAuto()
			end)
		end
	end)
end

-- A position + orientation drive on `root`, both one-attachment (driven to a world target this module
-- writes every frame). Owned by `trove`.
local function driveRig(
	root: BasePart,
	trove: Trove.TroveInstance,
	maxForce: number,
	responsiveness: number
): (AlignPosition, AlignOrientation)
	local attachment = trove:Add(Instance.new("Attachment"))
	attachment.Name = "AirComboAttachment"
	attachment.Parent = root

	local align = trove:Add(Instance.new("AlignPosition"))
	align.Name = "AirComboAlignPosition"
	align.Mode = Enum.PositionAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	align.MaxForce = maxForce
	align.MaxVelocity = math.huge
	align.Responsiveness = responsiveness
	align.RigidityEnabled = false
	align.Position = root.Position
	align.Parent = root

	local orient = trove:Add(Instance.new("AlignOrientation"))
	orient.Name = "AirComboAlignOrientation"
	orient.Mode = Enum.OrientationAlignmentMode.OneAttachment
	orient.Attachment0 = attachment
	orient.MaxTorque = HOVER.MaxTorque
	orient.Responsiveness = HOVER.OrientationResponsiveness
	orient.RigidityEnabled = false
	orient.CFrame = root.CFrame.Rotation
	orient.Parent = root

	return align, orient
end

-- Facing `target` from `from`, upright.
local function uprightFacing(from: Vector3, target: Vector3, fallback: CFrame): CFrame
	local direction = flat(target - from)
	if direction.Magnitude < 1e-3 then
		return fallback.Rotation
	end
	return CFrame.lookAt(Vector3.zero, direction.Unit)
end

-- Publishing ---------------------------------------------------------------------------------------

local function publishSession(session: Session, now: number): ()
	local holdUntil = AirComboMachine.HoldUntil(session.Combo)
	if session.PublishedHoldUntil ~= holdUntil then
		session.PublishedHoldUntil = holdUntil
		local serverHold = toServerTime(holdUntil, now)
		setAttribute(session.VictimHumanoid, ATTRIBUTES.AirHeldUntil, serverHold)
		setAttribute(session.AttackerHumanoid, ATTRIBUTES.AirComboAttackerUntil, serverHold)
	end
	local phase = session.Combo.Phase
	if session.PublishedPhase ~= phase then
		session.PublishedPhase = phase
		setPhase(session.VictimHumanoid, phase, now, false)
		setPhase(session.AttackerHumanoid, phase, now, false)
	end
	-- Re-asserted, not trusted: RootControlLocked has other writers (HitboxEngine's swing lock, DefenseSystem's
	-- stagger lock) that each CLEAR it when their own hold ends -- a victim launched mid-swing would otherwise
	-- have the engine hand their parkour back the frame its cancelled swing exits.
	setAttribute(session.VictimHumanoid, ATTRIBUTES.RootControlLocked, true)
end

-- Ending -------------------------------------------------------------------------------------------

local function startAftermath(aftermath: Aftermath): ()
	local existing = aftermaths[aftermath.Victim]
	if existing and existing.Trove then
		existing.Trove:Clean()
	end
	aftermaths[aftermath.Victim] = aftermath
end

local function beginFinisherOutcome(session: Session, finisher: FinisherKind, now: number): ()
	local victim = session.Victim
	local root = session.VictimRoot
	local humanoid = session.VictimHumanoid
	-- The body stays the server's for the finisher's own short flight, under a fresh trove of its own: the
	-- hover's constraints are already gone, and taking the body again is idempotent.
	local trove = Trove.New()
	takeBody(humanoid, root, session.VictimIsPlayer, trove)
	if finisher == "Slam" then
		root.AssemblyLinearVelocity = Vector3.new(0, -AirComboConstants.Slam.DownSpeed, 0)
	else
		local SPIKE = AirComboConstants.Spike
		local facing = flatUnit(
			session.AttackerRoot.CFrame.LookVector,
			flatUnit(root.Position - session.AttackerRoot.Position, Vector3.new(0, 0, -1))
		)
		root.AssemblyLinearVelocity = facing * SPIKE.HorizontalSpeed + Vector3.new(0, SPIKE.VerticalSpeed, 0)
		-- Guard pressure: a fraction of the MAX guard, through DefenseSystem's own drain seam, so the
		-- meter, the crack and the regen delay are the ordinary ones.
		local _, maxGuard = DefenseSystem.GetGuard(victim)
		if maxGuard and maxGuard > 0 then
			DefenseSystem.DrainGuard(victim, maxGuard * SPIKE.GuardDrainFraction, now)
		end
	end
	startAftermath({
		Kind = finisher,
		Victim = victim,
		Humanoid = humanoid,
		Root = root,
		Attacker = session.Attacker,
		StartedAt = now,
		LandedAt = nil,
		Trove = trove,
	})
end

local function endSession(session: Session, reason: EndReason, now: number): ()
	local combo = session.Combo
	if not AirComboMachine.End(combo, reason, now) then
		return
	end
	byVictim[session.Victim] = nil
	byAttacker[session.Attacker] = nil

	-- The hover and the follow go first, through their troves: the one path back to a normal body.
	session.VictimTrove:Clean()
	if session.AttackerTrove then
		session.AttackerTrove:Clean()
	end

	local victimHumanoid = session.VictimHumanoid
	local attackerHumanoid = session.AttackerHumanoid
	setAttribute(victimHumanoid, ATTRIBUTES.AirHeldUntil, nil)
	setAttribute(victimHumanoid, ATTRIBUTES.AirComboAnchor, nil)
	setAttribute(attackerHumanoid, ATTRIBUTES.AirComboAttackerUntil, nil)
	setAttribute(attackerHumanoid, ATTRIBUTES.AirComboAnchor, nil)

	-- No instant relaunch, whatever ended it. The attacker is made immune too after a parry: a parried
	-- attacker must never become the target of a reversed air combo (docs B4).
	local immuneUntil = toServerTime(AirComboMachine.ImmuneUntil(now), now)
	setAttribute(victimHumanoid, ATTRIBUTES.LaunchImmuneUntil, immuneUntil)
	if reason == "Parried" then
		setAttribute(attackerHumanoid, ATTRIBUTES.LaunchImmuneUntil, immuneUntil)
	end

	setPhase(victimHumanoid, AirComboMachine.EndPhaseFor(reason, session.Finisher), now, true)
	-- The attacker reads the parry too (their own client pushes them back on it); any other ending is
	-- simply over for them.
	setPhase(attackerHumanoid, if reason == "Parried" then "Parried" else nil, now, reason == "Parried")

	if reason == "Parried" and not session.AttackerIsPlayer and session.AttackerRoot.Parent ~= nil then
		-- A server-owned attacker is pushed up and back on the clash here; a player's own client does it.
		local back = -flatUnit(session.VictimRoot.Position - session.AttackerRoot.Position, Vector3.new(0, 0, 1))
		session.AttackerRoot.AssemblyLinearVelocity = (back + Vector3.yAxis) * FOLLOW.ClashPushSpeed
	end

	if reason == "Finished" and session.Finisher then
		beginFinisherOutcome(session, session.Finisher, now)
	else
		startAftermath({
			Kind = "Fall",
			Victim = session.Victim,
			Humanoid = victimHumanoid,
			Root = session.VictimRoot,
			Attacker = nil,
			StartedAt = now,
			LandedAt = nil,
			Trove = nil,
		})
	end

	debugLog("Air combo ended", {
		reason = reason,
		attacker = session.Attacker.Name,
		victim = session.Victim.Name,
		airHits = combo.AirHitsLanded,
	})
end

-- Launch -------------------------------------------------------------------------------------------

local function isRestrained(humanoid: Humanoid): boolean
	return humanoid:GetAttribute(ATTRIBUTES.Grabbed) == true
		or humanoid:GetAttribute(ATTRIBUTES.Grabbing) == true
		or humanoid:GetAttribute(ATTRIBUTES.Mounted) == true
end

local function isLaunchImmune(humanoid: Humanoid): boolean
	local untilTime = humanoid:GetAttribute(ATTRIBUTES.LaunchImmuneUntil)
	return typeof(untilTime) == "number" and Workspace:GetServerTimeNow() < untilTime
end

-- Whether a landed launcher on `victim` by `attacker` may start a combo -- one launch per combo, no
-- relaunch, nobody in two combos at once.
local function mayLaunch(attacker: Model, victim: Model): boolean
	if not AirComboConstants.Enabled or attacker == victim then
		return false
	end
	if byVictim[victim] or byAttacker[victim] or byVictim[attacker] or byAttacker[attacker] or aftermaths[victim] then
		return false
	end
	local attackerHumanoid = CharacterUtil.LiveHumanoidOf(attacker)
	local victimHumanoid = CharacterUtil.LiveHumanoidOf(victim)
	if not attackerHumanoid or not victimHumanoid then
		return false
	end
	if isRestrained(attackerHumanoid) or isRestrained(victimHumanoid) then
		return false
	end
	return not isLaunchImmune(victimHumanoid)
end

local function launch(attacker: Model, victim: Model, riseSpeed: number, at: number): ()
	local attackerHumanoid = CharacterUtil.LiveHumanoidOf(attacker)
	local victimHumanoid = CharacterUtil.LiveHumanoidOf(victim)
	local attackerRoot = attacker.PrimaryPart
	local victimRoot = victim.PrimaryPart
	if not attackerHumanoid or not victimHumanoid or not attackerRoot or not victimRoot then
		return
	end
	if victimRoot.Anchored then
		-- An anchored dummy (DebugDummySystem) cannot be moved, so cannot be held; the hit stands as a hit.
		return
	end

	local victimIsPlayer = Players:GetPlayerFromCharacter(victim) ~= nil
	local attackerIsPlayer = Players:GetPlayerFromCharacter(attacker) ~= nil

	local victimTrove = Trove.New()
	takeBody(victimHumanoid, victimRoot, victimIsPlayer, victimTrove)
	local victimAlign, victimOrient = driveRig(victimRoot, victimTrove, HOVER.MaxForce, HOVER.Responsiveness)
	victimOrient.CFrame = uprightFacing(victimRoot.Position, attackerRoot.Position, victimRoot.CFrame)

	local anchor = victimRoot.Position + Vector3.new(0, HOVER.HeightStuds, 0)

	local session: Session = {
		Combo = AirComboMachine.Launch(at),
		Attacker = attacker,
		Victim = victim,
		AttackerHumanoid = attackerHumanoid,
		VictimHumanoid = victimHumanoid,
		AttackerRoot = attackerRoot,
		VictimRoot = victimRoot,
		AttackerIsPlayer = attackerIsPlayer,
		VictimIsPlayer = victimIsPlayer,
		Anchor = anchor,
		SpringPosition = victimRoot.Position,
		SpringVelocity = Vector3.new(0, riseSpeed, 0),
		VictimTrove = victimTrove,
		VictimAlign = victimAlign,
		VictimOrient = victimOrient,
		AttackerTrove = nil,
		AttackerAlign = nil,
		AttackerOrient = nil,
		OutOfSlotSince = nil,
		PublishedHoldUntil = nil,
		PublishedPhase = nil,
		Finisher = nil,
	}

	-- A server-owned attacker (the training bot) has no client to follow with, so the server drives it to
	-- the same slot a player's client would.
	if not attackerIsPlayer and not attackerRoot.Anchored then
		local attackerTrove = Trove.New()
		takeBody(attackerHumanoid, attackerRoot, false, attackerTrove)
		local align, orient = driveRig(attackerRoot, attackerTrove, FOLLOW.MaxForce, HOVER.Responsiveness)
		session.AttackerTrove = attackerTrove
		session.AttackerAlign = align
		session.AttackerOrient = orient
	end

	byVictim[victim] = session
	byAttacker[attacker] = session
	-- An earlier combo's lingering end phase must not outlive the start of this one.
	phaseClearAt[victimHumanoid] = nil
	phaseClearAt[attackerHumanoid] = nil
	setAttribute(victimHumanoid, ATTRIBUTES.AirComboAnchor, anchor)
	setAttribute(attackerHumanoid, ATTRIBUTES.AirComboAnchor, anchor)
	publishSession(session, os.clock())

	debugLog("Air combo launched", { attacker = attacker.Name, victim = victim.Name })
end

-- The loop -----------------------------------------------------------------------------------------

local function abortReason(session: Session): boolean
	return session.Attacker.Parent == nil
		or session.Victim.Parent == nil
		or session.AttackerHumanoid.Parent == nil
		or session.VictimHumanoid.Parent == nil
		or session.AttackerHumanoid.Health <= 0
		or session.VictimHumanoid.Health <= 0
		or session.VictimRoot.Parent == nil
		or session.AttackerRoot.Parent == nil
		or isRestrained(session.VictimHumanoid)
		or isRestrained(session.AttackerHumanoid)
end

local function stepSession(session: Session, deltaTime: number, now: number): ()
	if abortReason(session) then
		endSession(session, "Aborted", now)
		return
	end
	local combo = session.Combo
	local ended = AirComboMachine.Tick(combo, now)
	if ended then
		endSession(session, ended, now)
		return
	end

	-- THE HOVER. Three independent axes of the one unconditionally-stable spring (FlightMath.SpringStep).
	local position, velocity = session.SpringPosition, session.SpringVelocity
	local x, vx =
		FlightMath.SpringStep(position.X, velocity.X, session.Anchor.X, HOVER.Frequency, HOVER.Damping, deltaTime)
	local y, vy =
		FlightMath.SpringStep(position.Y, velocity.Y, session.Anchor.Y, HOVER.Frequency, HOVER.Damping, deltaTime)
	local z, vz =
		FlightMath.SpringStep(position.Z, velocity.Z, session.Anchor.Z, HOVER.Frequency, HOVER.Damping, deltaTime)
	session.SpringPosition = Vector3.new(x, y, z)
	session.SpringVelocity = Vector3.new(vx, vy, vz)
	session.VictimAlign.Position = session.SpringPosition
	session.VictimOrient.CFrame =
		uprightFacing(session.VictimRoot.Position, session.AttackerRoot.Position, session.VictimOrient.CFrame)

	-- THE FOLLOW, for a server-owned attacker; THE AUDIT, for a player's.
	local slot = slotFor(session.Anchor, session.AttackerRoot.Position)
	local attackerAlign, attackerOrient = session.AttackerAlign, session.AttackerOrient
	if attackerAlign and attackerOrient then
		attackerAlign.Position = slot
		attackerOrient.CFrame =
			uprightFacing(session.AttackerRoot.Position, session.VictimRoot.Position, attackerOrient.CFrame)
	elseif now >= combo.LaunchedAt + HOVER.RiseSeconds + FOLLOW.GraceSeconds then
		local distance = (session.AttackerRoot.Position - slot).Magnitude
		if distance > FOLLOW.ToleranceStuds + FOLLOW.DriftRadiusStuds then
			session.OutOfSlotSince = session.OutOfSlotSince or now
			if now - (session.OutOfSlotSince :: number) > FOLLOW.GraceSeconds then
				logger:info("Air combo dropped for spacing", {
					attacker = session.Attacker.Name,
					distance = math.floor(distance * 10) / 10,
				})
				endSession(session, "SpacingFail", now)
				return
			end
		else
			session.OutOfSlotSince = nil
		end
	end

	publishSession(session, now)
end

local function finishAftermath(aftermath: Aftermath, now: number, phase: Phase?): ()
	aftermaths[aftermath.Victim] = nil
	if aftermath.Trove then
		aftermath.Trove:Clean()
	end
	if phase and aftermath.Humanoid.Parent ~= nil then
		setPhase(aftermath.Humanoid, phase, now, true)
	end
end

local function stepAftermath(aftermath: Aftermath, now: number): ()
	local humanoid, root = aftermath.Humanoid, aftermath.Root
	if aftermath.Victim.Parent == nil or humanoid.Parent == nil or root.Parent == nil or humanoid.Health <= 0 then
		finishAftermath(aftermath, now, nil)
		return
	end
	local elapsed = now - aftermath.StartedAt
	local ignore: { Instance } = { aftermath.Victim }
	if aftermath.Attacker then
		table.insert(ignore, aftermath.Attacker)
	end

	if aftermath.Kind == "Slam" then
		local SLAM = AirComboConstants.Slam
		if aftermath.LandedAt == nil then
			local landed = groundBelow(root, SLAM.GroundProbeStuds, ignore) or elapsed >= SLAM.MaxDropSeconds
			if landed then
				-- THE HARD KNOCKDOWN. Still platform-standing (the body lies where it fell) and intangible:
				-- every contact resolves Evaded until it ends (DefenseSystem pass 1).
				aftermath.LandedAt = now
				root.AssemblyLinearVelocity = Vector3.zero
				setAttribute(
					humanoid,
					ATTRIBUTES.AirComboIntangibleUntil,
					toServerTime(now + SLAM.KnockdownSeconds, now)
				)
				-- Stunned for the knockdown too, so the ordinary attack/guard/run gates agree it is down.
				DamageSystem.ExtendHitstun(aftermath.Victim, now + SLAM.KnockdownSeconds, now)
			else
				root.AssemblyLinearVelocity = Vector3.new(0, -SLAM.DownSpeed, 0)
			end
		elseif now - (aftermath.LandedAt :: number) >= SLAM.KnockdownSeconds then
			setAttribute(humanoid, ATTRIBUTES.AirComboIntangibleUntil, nil)
			finishAftermath(aftermath, now, "Recovering")
		end
		return
	end

	if aftermath.Kind == "Spike" then
		local SPIKE = AirComboConstants.Spike
		local velocity = root.AssemblyLinearVelocity
		local horizontal = flat(velocity)
		if horizontal.Magnitude > 1 then
			table.clear(rayFilter)
			for _, instance in ignore do
				table.insert(rayFilter, instance)
			end
			rayParams.FilterDescendantsInstances = rayFilter
			local hit = Workspace:Raycast(root.Position, horizontal.Unit * SPIKE.WallProbeStuds, rayParams)
			if hit and math.abs(hit.Normal.Y) <= SPIKE.WallMaxNormalY then
				-- THE WALL SPLAT: stopped against it, and stunned through the one hitstun path the
				-- environment system already uses.
				root.AssemblyLinearVelocity = Vector3.new(0, velocity.Y, 0)
				DamageSystem.ExtendHitstun(aftermath.Victim, now + SPIKE.SplatHitstunSeconds, now)
				debugLog("Spike wall splat", { victim = aftermath.Victim.Name })
				finishAftermath(aftermath, now, "Spiked")
				return
			end
		end
		if elapsed >= SPIKE.SplatWindowSeconds or (elapsed > 0.15 and groundBelow(root, 3.5, ignore)) then
			finishAftermath(aftermath, now, "Recovering")
		end
		return
	end

	-- Fall: the body is already the victim's own again; publish Recovering the moment it is back on its feet.
	local RECOVERY = AirComboConstants.Recovery
	if humanoid.FloorMaterial ~= Enum.Material.Air or groundBelow(root, RECOVERY.GroundProbeStuds, ignore) then
		finishAftermath(aftermath, now, "Recovering")
	elseif elapsed >= RECOVERY.MaxFallSeconds then
		finishAftermath(aftermath, now, nil)
	end
end

-- One frame. `now` is the caller's clock, matching every other System's Step in this stack. DELIBERATELY
-- FULL WALKS: every entry here is per-entry WORK (a spring advanced, a flight watched), and all three tables
-- are bounded by combos actually in progress -- see Shared/AmortizedReclaim.lua's header on why a sweep that
-- does per-entry work must not be amortised.
function AirComboSystem.Step(deltaTime: number, now: number): ()
	for _, session in byVictim do
		stepSession(session, deltaTime, now)
	end
	for _, aftermath in aftermaths do
		stepAftermath(aftermath, now)
	end
	for humanoid, clearAt in phaseClearAt do
		if now >= clearAt or humanoid.Parent == nil then
			phaseClearAt[humanoid] = nil
			if
				humanoid.Parent ~= nil
				and not byVictim[humanoid.Parent :: any]
				and not byAttacker[humanoid.Parent :: any]
			then
				humanoid:SetAttribute(ATTRIBUTES.AirComboPhase, nil)
			end
		end
	end
end

-- The damage layer ---------------------------------------------------------------------------------

-- DamageSystem's air-combo hook (DamageSystem.SetAirComboHook): scales an air hit or finisher landing in a
-- live combo, and tags the contact for the heavier presentation. Called BEFORE OnApplied for the same
-- contact, so AirHitsLanded here is the count of hits before this one -- exactly the k the falloff wants.
local function onPriced(outcome: DefenseOutcome, moveId: string, damage: number): (number, string?)
	local session = byVictim[outcome.Defender]
	if session and session.Attacker == outcome.Attacker and not session.Combo.Ended then
		if outcome.Kind == "Parried" then
			return damage, "Clash"
		end
		if isLanded(outcome.Kind) then
			local role = AirComboMoves.RoleOf(moveId)
			if role and role.Role ~= "Launcher" then
				return AirComboMachine.ScaleDamage(session.Combo, role, damage),
					if role.Role == "Finisher" then "Finisher" else "Hit"
			end
		end
		return damage, nil
	end
	if
		isLanded(outcome.Kind)
		and AirComboMoves.IsLauncher(moveId)
		and mayLaunch(outcome.Attacker, outcome.Defender)
	then
		return damage, "Launch"
	end
	return damage, nil
end

local function onApplied(outcome: DefenseOutcome, result: DamageResult): ()
	local now = outcome.SampleTime
	local moveId = outcome.Report.DebugName
	local kind = outcome.Kind

	-- The attacker of a live combo, hit by anyone: the combo is over (Interrupted).
	local asAttacker = byAttacker[outcome.Defender]
	if asAttacker and isLanded(kind) then
		endSession(asAttacker, "Interrupted", now)
	end

	local session = byVictim[outcome.Defender]
	if session and session.Attacker == outcome.Attacker then
		if kind == "Parried" then
			endSession(session, "Parried", now)
		elseif isLanded(kind) then
			local role = AirComboMoves.RoleOf(moveId)
			if role and role.Role == "Air" then
				AirComboMachine.NoteAirHit(session.Combo, now)
				-- A small upward kick per hit: the hover bobs with the weight of it.
				session.SpringVelocity += Vector3.new(0, HOVER.HitKickSpeed, 0)
			elseif role and role.Role == "Finisher" then
				session.Finisher = role.Finisher
				endSession(session, "Finished", now)
			end
		end
		return
	end
	if session then
		-- A third party hitting a held victim deals its damage and changes nothing about the combo.
		return
	end

	if not isLanded(kind) then
		return
	end
	local knockback = result.Knockback
	local startsAirCombo = knockback ~= nil and knockback.StartsAirCombo == true
	if not AirComboMoves.IsLauncher(moveId, startsAirCombo) then
		return
	end
	if not mayLaunch(outcome.Attacker, outcome.Defender) then
		return
	end
	local riseSpeed = if knockback and knockback.UpVelocity > 0 then knockback.UpVelocity else HOVER.InitialRiseSpeed
	launch(outcome.Attacker, outcome.Defender, riseSpeed, now)
end

-- Public: the attack layer ---------------------------------------------------------------------------

-- Whether this combatant may start an attack. Refuses an air-held victim (and one lying in a slam's
-- knockdown or flying from a spike): their one way out is the parry, which is a DefenseSystem press, not an
-- attack. The attacker is never refused here -- what their presses MEAN is ResolvePress's question.
function AirComboSystem.CanAttack(model: Model, _now: number): (boolean, string?)
	if byVictim[model] then
		return false, "AirHeld"
	end
	local aftermath = aftermaths[model]
	if aftermath and aftermath.Kind ~= "Fall" then
		return false, "Knockdown"
	end
	return true, nil
end

-- What a Basic/Heavy press means for a live combo's attacker, or (nil, nil) for anyone else -- who then
-- resolves through the ground string as always. A (nil, reason) is a refusal: "AirRising" while the victim
-- is still leaving the ground (transient -- the press buffers), or the string already cashed out.
function AirComboSystem.ResolvePress(model: Model, kind: string, modifierUp: boolean, now: number): (MoveRole?, string?)
	if kind ~= "Basic" and kind ~= "Heavy" then
		return nil, nil
	end
	local session = byAttacker[model]
	if not session then
		return nil, nil
	end
	local allowed, reason = AirComboMachine.CanPress(session.Combo, now)
	if not allowed then
		return nil, if reason == "Rising" then "AirRising" else reason
	end
	return AirComboMachine.ResolvePress(session.Combo, kind :: "Basic" | "Heavy", modifierUp), nil
end

-- The attack layer accepted an air move for this attacker. Judged against the shared deadline at the
-- swing's REWOUND start (AirComboMachine.NoteSwingAccepted), and a finisher publishes Finishing.
function AirComboSystem.NoteSwingAccepted(
	model: Model,
	role: MoveRole,
	now: number,
	windupSeconds: number,
	activeSeconds: number
): ()
	local session = byAttacker[model]
	if not session then
		return
	end
	-- The swing's hold covers its active window PLUS the victim's parry rewind hold: a player victim's Clean
	-- contact waits up to that long in DefenseSystem before it applies (the air parry's lag rewind), and a
	-- hit that connected inside the window must not arrive to find the combo already dropped.
	local victimRewind = math.min(pingOf(session.Victim), AirComboConstants.Parry.RewindMaxSeconds)
	AirComboMachine.NoteSwingAccepted(
		session.Combo,
		role,
		now,
		math.min(pingOf(model), TIMING.SwingRewindMaxSeconds),
		windupSeconds,
		activeSeconds + victimRewind
	)
	publishSession(session, now)
end

function AirComboSystem.IsAttacker(model: Model): boolean
	return byAttacker[model] ~= nil
end

function AirComboSystem.IsHeld(model: Model): boolean
	return byVictim[model] ~= nil
end

-- A read-only view of the combo `model` is in (as either side), for the training bot and a spec.
export type ComboView = {
	Attacker: Model,
	Victim: Model,
	Phase: Phase,
	AirHitsLanded: number,
	HoldUntil: number,
	LaunchedAt: number,
}
function AirComboSystem.GetCombo(model: Model): ComboView?
	local session = byVictim[model] or byAttacker[model]
	if not session then
		return nil
	end
	return {
		Attacker = session.Attacker,
		Victim = session.Victim,
		Phase = session.Combo.Phase,
		AirHitsLanded = session.Combo.AirHitsLanded,
		HoldUntil = AirComboMachine.HoldUntil(session.Combo),
		LaunchedAt = session.Combo.LaunchedAt,
	}
end

-- Lifecycle ----------------------------------------------------------------------------------------

-- Subscribes to the damage layer and takes its hook slot, and nothing else -- split from Init for the reason
-- GrabSystem.Attach is: a spec drives this system on a synthetic clock. Idempotent.
function AirComboSystem.Attach(): ()
	if appliedDisconnect then
		return
	end
	appliedDisconnect = DamageSystem.OnApplied(onApplied)
	DamageSystem.SetAirComboHook(onPriced)
end

function AirComboSystem.Init(): ()
	if started then
		return
	end
	assert(DamageSystem.OnApplied ~= nil, "AirComboSystem.Init() requires DamageSystem to be available")
	assert(DefenseSystem.DrainGuard ~= nil, "AirComboSystem.Init() requires DefenseSystem to be available")
	started = true

	AirComboSystem.Attach()

	heartbeatTrove:Connect(RunService.Heartbeat, function(deltaTime: number)
		AirComboSystem.Step(deltaTime, os.clock())
	end)

	-- A same-frame backstop for a participant leaving mid-combo; Step's own Parent==nil sweep is the
	-- primary mechanism, the same split GrabSystem keeps.
	heartbeatTrove:Connect(Players.PlayerRemoving, function(player: Player)
		local character = player.Character
		if not character then
			return
		end
		local session = byVictim[character] or byAttacker[character]
		if session then
			endSession(session, "Aborted", os.clock())
		end
		local aftermath = aftermaths[character]
		if aftermath then
			finishAftermath(aftermath, os.clock(), nil)
		end
	end)

	logger:info("AirComboSystem.Init() complete")
end

function AirComboSystem.Shutdown(): ()
	heartbeatTrove:Clean()
	if appliedDisconnect then
		appliedDisconnect()
		appliedDisconnect = nil
	end
	DamageSystem.SetAirComboHook(nil)
	started = false
end

-- Drops every combo and subscription, releasing every body it held. Spec-only, the role GrabSystem.Reset
-- plays; unlike that one it DOES release through the troves, because a held body's PlatformStand and
-- network ownership are state a following case would otherwise inherit.
function AirComboSystem.Reset(): ()
	if appliedDisconnect then
		appliedDisconnect()
		appliedDisconnect = nil
	end
	DamageSystem.SetAirComboHook(nil)
	for _, session in byVictim do
		session.VictimTrove:Clean()
		if session.AttackerTrove then
			session.AttackerTrove:Clean()
		end
	end
	for _, aftermath in aftermaths do
		if aftermath.Trove then
			aftermath.Trove:Clean()
		end
	end
	table.clear(byVictim)
	table.clear(byAttacker)
	table.clear(aftermaths)
	table.clear(phaseClearAt)
end

return AirComboSystem :: Types.SystemModule & typeof(AirComboSystem)
