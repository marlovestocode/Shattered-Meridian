--!strict
--[[
	RagdollSystem.lua

	Owns: the ragdoll at runtime -- taking a body limp when a hit ragdolls it, throwing it, watching it fall,
	getting it back up, and handing it back to whoever owned it. Plus the three Attributes that say so
	(Ragdolled, RagdollChainEndsAt, RagdollImmuneUntil -- the only writer, check-single-writers).

	A SIBLING ON DamageSystem.OnApplied (and GrabSystem.OnThrown, for a grab move's ragdoll -- onThrown below),
	the shape CLAUDE.md asks for first (GrabSystem's, EnvironmentReactionSystem's). It decides nothing about WHETHER: DamageSystem resolved that before OnApplied (DamageResult.Ragdoll,
	through Shared/Ragdoll/RagdollRules), so this applies exactly the spec it is handed. Nothing in the four layers
	requires it. It reaches down through nothing but RootControl (the claim that stands the client's movement down)
	and MovementAllowance (so the get-up is not read as a teleport).

	THE SERVER HOLDS A RAGDOLLED BODY, players included. A limp body is pure physics nobody steers, and every
	client must see the same fall -- so its parts are handed to the server (SetNetworkOwner(nil)) for the length of
	it and back to the player standing up. The player's own client stands down on the RootControl claim
	(ParkourController parks, CombatCamera stops writing the root, KnockbackClient and the hit-stop freeze are
	refused) and on PlatformStand, which replicates. The swing, guard, evade and emote gates refuse on the
	Ragdolled restraint (Shared/Combat/BodyRestraint).

	THE LIFE OF ONE RAGDOLL:
	  Limp       sockets in, motors out, thrown (RagdollRules.Impulse). Nothing is polled before DurationSeconds.
	             After it: with RecoverOnSettle, the torso is sampled RagdollConstants.Settle.PollHz times a second
	             (offset per body) until it has been at rest for StableSamples in a row, or MaxSeconds is spent;
	             without, the get-up starts at once.
	  GettingUp  the root is driven upright onto the floor beneath it while every joint is drawn back toward its
	             rest pose (RagdollRig.Tighten), over GetUpSeconds; then the motors take it again, and the body is
	             handed back standing.
	  Corpse     a body that died limp stays limp. Nothing is polled; the record goes with the model.
	A ragdolling hit on a limp body REFRESHES it -- re-thrown, its clock restarted, the get-up abandoned -- until
	RagdollConstants.Rules.MaxChainSeconds after its first fall (RagdollRules.Admits, read by DamageSystem).

	COST. Step returns at once with nobody limp. With bodies limp, a Limp body before its DurationSeconds is a
	deadline compare; after it, one velocity read per poll; only a GettingUp body writes per frame (its joint
	angles, a handful of numbers). The rig is built once per life (RagdollRig) and toggled after that. Constants
	and the move's spec are read once, when the ragdoll begins.

	Does not own: whether a hit ragdolls (RagdollRules / DamageSystem), the rig's Instances (RagdollRig), the spec
	schema (RagdollTypes), or the tuning (RagdollConstants).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local DamageTypes = require(ReplicatedStorage.Shared.Damage.DamageTypes)
local DefenseTypes = require(ReplicatedStorage.Shared.Defense.DefenseTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)
local RagdollConstants = require(ReplicatedStorage.Shared.Ragdoll.RagdollConstants)
local RagdollRules = require(ReplicatedStorage.Shared.Ragdoll.RagdollRules)
local RagdollTypes = require(ReplicatedStorage.Shared.Ragdoll.RagdollTypes)
local Trove = require(ReplicatedStorage.Shared.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local AttackCatalog = require(script.Parent.Parent.AttackCatalog)
local CombatTick = require(script.Parent.Parent.CombatTick)
local DamageSystem = require(script.Parent.Parent.Damage.DamageSystem)
local GrabSystem = require(script.Parent.Parent.Grab.GrabSystem)
local MovementAllowance = require(script.Parent.Parent.MovementAllowance)
local RootControl = require(script.Parent.Parent.RootControl)
local RagdollRig = require(script.Parent.RagdollRig)

type RagdollSpec = RagdollTypes.RagdollSpec

local logger = Logger.scope("RagdollSystem")

local RagdollSystem = {}

type Phase = "Limp" | "GettingUp" | "Corpse"

type Record = {
	Model: Model,
	Humanoid: Humanoid,
	Kit: RagdollRig.Kit,
	Spec: RagdollSpec,
	-- The player the body goes back to, or nil for a server-owned one (a bot, a dummy).
	Owner: Player?,
	Phase: Phase,
	StartedAt: number,
	LimpUntil: number,
	MaxUntil: number,
	NextPollAt: number,
	StableSamples: number,
	GetUpStartedAt: number,
	GetUpEndsAt: number,
	GetUpTarget: CFrame,
	-- An anchored body's root CFrame before it fell, to stand it back there (RagdollConstants.Recovery).
	Home: CFrame?,
}

local records: { [Model]: Record } = {}
-- One kit per life. Weak: a destroyed Humanoid takes its kit with it.
local kits: { [Humanoid]: RagdollRig.Kit } = setmetatable({}, { __mode = "k" }) :: any

local started = false
local trove = Trove.New()
local appliedDisconnect: (() -> ())? = nil
local thrownDisconnect: (() -> ())? = nil

-- Helpers ------------------------------------------------------------------------------------------

local function kitFor(model: Model, humanoid: Humanoid, root: BasePart): RagdollRig.Kit?
	local kit = kits[humanoid]
	if kit and kit.Root == root and root.Parent == model then
		return kit
	end
	local built = RagdollRig.Build(model, humanoid, root)
	if built then
		kits[humanoid] = built
	end
	return built
end

-- Where the body stands up: on the floor beneath its root, facing the way its torso points (its back, for a
-- body face down), upright.
local function standTarget(record: Record): CFrame
	local kit = record.Kit
	local root = kit.Root
	local position = root.Position
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { record.Model }
	params.RespectCanCollide = true
	local probe = RagdollConstants.Recovery.GroundProbeStuds
	local hit = Workspace:Raycast(position + Vector3.yAxis * 2, Vector3.yAxis * -(probe + 2), params)
	local standY = if hit then hit.Position.Y + kit.StandHeight else position.Y

	local look = root.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.3 then
		-- Lying flat on its front or back: the look is vertical, and the body's up (head-ward) is the heading.
		local up = root.CFrame.UpVector
		flat = Vector3.new(up.X, 0, up.Z)
	end
	if flat.Magnitude < 1e-3 then
		flat = -Vector3.zAxis
	end
	local at = Vector3.new(position.X, standY, position.Z)
	return CFrame.lookAt(at, at + flat.Unit)
end

local function beginGetUp(record: Record, now: number): ()
	local seconds = record.Spec.GetUpSeconds
	record.Phase = "GettingUp"
	record.GetUpStartedAt = now
	record.GetUpEndsAt = now + seconds
	record.GetUpTarget = standTarget(record)
	RagdollRig.BeginGetUp(record.Kit, record.GetUpTarget, seconds)
end

-- Hands the body back, standing, and publishes the immunity.
local function finish(record: Record, now: number): ()
	records[record.Model] = nil
	local home = if RagdollConstants.Recovery.ReturnAnchoredHome then record.Home else nil
	RagdollRig.Restore(record.Kit, home or record.GetUpTarget, record.Owner)
	local humanoid = record.Humanoid
	RootControl.Release(humanoid, RootControl.Owners.Ragdoll)
	humanoid:SetAttribute(AttributeConstants.Ragdolled, nil)
	humanoid:SetAttribute(AttributeConstants.RagdollChainEndsAt, nil)
	humanoid:SetAttribute(AttributeConstants.RagdollImmuneUntil, now + RagdollConstants.Rules.ImmunitySeconds)
	-- The client takes its body back wherever the server left it.
	MovementAllowance.Stamp(humanoid, now + RagdollConstants.Rules.AllowanceAfterSeconds)
end

-- The flat direction a contact throws its defender: along a shot's flight, else away from the attacker, else the
-- way the attacker faces.
local function awayOf(outcome: DefenseTypes.DefenseOutcome, defenderRoot: BasePart): Vector3
	local projectile = outcome.Report.Projectile
	if projectile then
		return projectile.Direction
	end
	local attackerRoot = CharacterUtil.RootOf(outcome.Attacker)
	if attackerRoot == nil then
		return Vector3.zero
	end
	local between = defenderRoot.Position - attackerRoot.Position
	if Vector3.new(between.X, 0, between.Z).Magnitude > 1e-3 then
		return between
	end
	return attackerRoot.CFrame.LookVector
end

-- Entry points -------------------------------------------------------------------------------------

-- Puts `model` down under `spec`, thrown with (`linear`, `angular`), at `now`. A body already limp is refreshed.
-- `lethal` marks the blow that kills it: such a body never gets up. Returns whether the body went limp (false:
-- no Humanoid, no root, or no ragdollable joints). Does NOT check RagdollRules.Admits -- the caller decided.
function RagdollSystem.Begin(
	model: Model,
	spec: RagdollSpec,
	linear: Vector3,
	angular: Vector3,
	lethal: boolean,
	now: number
): boolean
	local humanoid = CharacterUtil.HumanoidOf(model)
	local root = CharacterUtil.RootOf(model)
	if humanoid == nil or root == nil then
		return false
	end
	local kit = kitFor(model, humanoid, root)
	if kit == nil then
		return false
	end

	local record = records[model]
	if record == nil then
		local fresh: Record = {
			Model = model,
			Humanoid = humanoid,
			Kit = kit,
			Spec = spec,
			Owner = Players:GetPlayerFromCharacter(model),
			Phase = "Limp",
			StartedAt = now,
			LimpUntil = now,
			MaxUntil = now,
			NextPollAt = now,
			StableSamples = 0,
			GetUpStartedAt = now,
			GetUpEndsAt = now,
			GetUpTarget = root.CFrame,
			Home = if root.Anchored then root.CFrame else nil,
		}
		record = fresh
		records[model] = fresh
		RootControl.Claim(humanoid, RootControl.Owners.Ragdoll)
		humanoid:SetAttribute(AttributeConstants.Ragdolled, true)
		-- From the FIRST fall: a refresh never moves it (RagdollConstants.Rules.MaxChainSeconds).
		humanoid:SetAttribute(AttributeConstants.RagdollChainEndsAt, now + RagdollConstants.Rules.MaxChainSeconds)
	end
	local live = record :: Record

	RagdollRig.GoLimp(kit, spec)
	RagdollRig.Throw(kit, linear, angular)

	live.Spec = spec
	live.Phase = if lethal or humanoid.Health <= 0 then "Corpse" else "Limp"
	live.StartedAt = now
	live.LimpUntil = now + spec.DurationSeconds
	live.MaxUntil = now + math.max(spec.MaxSeconds, spec.DurationSeconds)
	-- Offset within one poll period, so bodies put down on one frame do not all poll on the same later frame.
	live.NextPollAt = live.LimpUntil + math.random() / math.max(RagdollConstants.Settle.PollHz, 1)
	live.StableSamples = 0
	return true
end

-- Whether `model` is limp or getting up.
function RagdollSystem.IsRagdolled(model: Model): boolean
	return records[model] ~= nil
end

-- The phase `model` is in, or nil -- for the debug readout and specs.
function RagdollSystem.PhaseOf(model: Model): Phase?
	local record = records[model]
	return if record then record.Phase else nil
end

local function onDamageApplied(outcome: DefenseTypes.DefenseOutcome, result: DamageTypes.DamageResult): ()
	local spec = result.Ragdoll
	if spec == nil then
		return
	end
	local defender = outcome.Defender
	local root = CharacterUtil.RootOf(defender)
	local humanoid = CharacterUtil.HumanoidOf(defender)
	if root == nil or humanoid == nil then
		return
	end
	-- OnApplied fires BEFORE the health write (DamageSystem), so this is the blow that will kill.
	local lethal = result.Damage > 0 and result.Damage >= humanoid.Health
	local linear, angular = RagdollRules.Impulse(spec, awayOf(outcome, root), result.Launch)
	local now = os.clock()
	if RagdollSystem.Begin(defender, spec, linear, angular, lethal, now) then
		logger:debug("Ragdolled", {
			defender = defender.Name,
			moveId = outcome.Report.DebugName,
			trigger = spec.Trigger,
			lethal = lethal,
		})
	end
end

-- A GRAB MOVE'S RAGDOLL HAPPENS ON THE THROW, never on the grab hit (DamageSystem resolves no ragdoll for a hit
-- that grabs: the body is welded into a hand). GrabSystem announces the throw the frame the body leaves the hand;
-- the move's own block is read off the catalogue and resolved as for a hit, against the contact the grab landed
-- as, with the body in the air -- so On hit, On air hit, On backstab and On guard break fire on the throw, and
-- On kill never does (a throw is not a killing blow; its landing damage is GrabSystem's). The throw's velocity
-- is the launch the ragdoll's KnockbackScale carries. GrabSystem's flight runs on beside it -- its landing still
-- deals ThrowSelfDamage / ThrowImpactDamage -- and leaves a limp body's ownership and PlatformStand to this.
local function onThrown(report: GrabSystem.ThrowReport): ()
	local entry = AttackCatalog.Get(report.MoveId)
	local authored = if entry then entry.Profile.Ragdoll else nil
	if authored == nil then
		return
	end
	local humanoid = CharacterUtil.LiveHumanoidOf(report.Victim)
	if humanoid == nil then
		return
	end
	local now = os.clock()
	local spec = RagdollRules.Resolve(authored, { Kind = report.Kind, Lethal = false, Airborne = true }, humanoid, now)
	if spec == nil then
		return
	end
	local linear, angular = RagdollRules.Impulse(spec, report.Direction, report.Velocity)
	if RagdollSystem.Begin(report.Victim, spec, linear, angular, false, now) then
		logger:debug("Ragdolled on the throw", { victim = report.Victim.Name, moveId = report.MoveId })
	end
end

-- Loop ---------------------------------------------------------------------------------------------

function RagdollSystem.Step(now: number): ()
	if next(records) == nil then
		return
	end
	local settle = RagdollConstants.Settle
	for model, record in records do
		if model.Parent == nil or record.Humanoid.Parent == nil then
			-- Despawned mid-fall: the kit and the claim went with the Humanoid.
			records[model] = nil
			continue
		end
		local phase = record.Phase
		if phase == "Corpse" then
			continue
		end
		if record.Humanoid.Health <= 0 then
			record.Phase = "Corpse"
			continue
		end
		if phase == "Limp" then
			if now < record.LimpUntil then
				continue
			end
			local ready = not record.Spec.RecoverOnSettle or now >= record.MaxUntil
			if not ready and now >= record.NextPollAt then
				record.NextPollAt = now + 1 / math.max(settle.PollHz, 1)
				local root = record.Kit.Root
				if
					RagdollRules.AtRest(root.AssemblyLinearVelocity.Magnitude, root.AssemblyAngularVelocity.Magnitude)
				then
					record.StableSamples += 1
				else
					record.StableSamples = 0
				end
				ready = record.StableSamples >= settle.StableSamples
			end
			if ready then
				beginGetUp(record, now)
			end
		else
			local span = math.max(record.GetUpEndsAt - record.GetUpStartedAt, 1e-3)
			RagdollRig.Tighten(record.Kit, (now - record.GetUpStartedAt) / span)
			if now >= record.GetUpEndsAt then
				finish(record, now)
			end
		end
	end
end

-- Lifecycle ----------------------------------------------------------------------------------------

-- Subscribes to OnApplied and GrabSystem.OnThrown and nothing else -- split from Init (EnvironmentReactionSystem.
-- Attach's reason) so a spec can drive Step on its own clock. Idempotent.
function RagdollSystem.Attach(): ()
	if not appliedDisconnect then
		appliedDisconnect = DamageSystem.OnApplied(onDamageApplied)
	end
	if not thrownDisconnect then
		thrownDisconnect = GrabSystem.OnThrown(onThrown)
	end
end

function RagdollSystem.Init(): ()
	if started then
		return
	end
	assert(DamageSystem.OnApplied ~= nil, "RagdollSystem.Init() requires DamageSystem")
	started = true
	RagdollSystem.Attach()
	trove:Add(CombatTick.Register("RagdollSystem", function(_deltaTime: number, now: number)
		RagdollSystem.Step(now)
	end))
	logger:info("RagdollSystem.Init() complete")
end

function RagdollSystem.Shutdown(): ()
	trove:Clean()
	started = false
end

-- Spec-only: stands every limp body back up where it lies, and drops every record and the subscription.
function RagdollSystem.Reset(): ()
	if appliedDisconnect then
		appliedDisconnect()
		appliedDisconnect = nil
	end
	if thrownDisconnect then
		thrownDisconnect()
		thrownDisconnect = nil
	end
	for model, record in records do
		if model.Parent ~= nil and record.Humanoid.Parent ~= nil then
			RagdollRig.Restore(record.Kit, nil, record.Owner)
			RootControl.Release(record.Humanoid, RootControl.Owners.Ragdoll)
			record.Humanoid:SetAttribute(AttributeConstants.Ragdolled, nil)
			record.Humanoid:SetAttribute(AttributeConstants.RagdollChainEndsAt, nil)
			record.Humanoid:SetAttribute(AttributeConstants.RagdollImmuneUntil, nil)
		end
	end
	table.clear(records)
end

return RagdollSystem :: Types.SystemModule & typeof(RagdollSystem)
