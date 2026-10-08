--!strict
--[[
	EnvironmentReactionSystem.lua

	Owns: the arena answering back -- the WALL SPLAT (a knockback that drives a body into a wall stuns it
	there) and the SWING SCUFF broadcast (a swing that reaches its strike next to a wall kicks dust and chips
	off it, shown to everyone nearby). Plus the Combat_EnvironmentFX remote both ride on.

	A SIBLING OF THE ATTACK LAYER, the shape CLAUDE.md asks for first: it subscribes to two existing
	extension points and is read by nobody.
	  * DamageSystem.OnApplied -- the resolved DamageResult.Launch, the same record KnockbackAudit watches.
	  * AttackRequestSystem.OnSwingAccepted -- a committed swing, for the scuff.
	It reaches down through exactly one narrow seam, DamageSystem.ExtendHitstun, which takes a deadline and
	nothing else: a splat says "reeling until then" and the damage layer stays the only thing that stuns.

	THE SPLAT IS WATCHED, NOT PREDICTED (EnvironmentConstants.WallSplat's header has the whole argument). At
	the hit: cast along the launch; if a wall is in reach, remember it. Every frame after, until the watch
	lapses: is the victim's own replicated root at that wall? The first frame it is, the victim is stunned
	and every nearby client is told. A player's launch is applied by their own client after its hit-stop,
	at a moment the server cannot know -- so the server does not guess it; it looks. A client that refused
	the launch never arrives and never takes the stun, which is the correct failure (KnockbackAudit is
	what counts that refusal against them).

	THE SCUFF IS COSMETIC AND DECIDED TWICE. The attacker's own client predicts its scuff at its own strike
	(Client/FX/EnvironmentFX.lua), so this system tells everyone ELSE -- never the swinger, who would see it
	twice, one round trip apart. It casts at the server's strike time (StartedAt + WindupSeconds), and only
	if the swing is still the one in flight then: a feinted, parried or stunned swing never reached a wall.

	NO HEARTBEAT WORK WHEN IDLE: Step returns on two empty tables.

	Does not own: the launch (DamageSystem), applying it (KnockbackClient), what counts as a wall
	(Shared/Combat/EnvironmentProbe.lua), the dust itself (Client/FX/EnvironmentFX.lua), or any tuning
	(EnvironmentConstants; presentation in FXConstants.EnvironmentImpact).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local DamageConstants = require(ReplicatedStorage.Shared.Damage.DamageConstants)
local DamageTypes = require(ReplicatedStorage.Shared.Damage.DamageTypes)
local DefenseTypes = require(ReplicatedStorage.Shared.Defense.DefenseTypes)
local EnvironmentConstants = require(ReplicatedStorage.Shared.Combat.EnvironmentConstants)
local EnvironmentProbe = require(ReplicatedStorage.Shared.Combat.EnvironmentProbe)
local FXConstants = require(ReplicatedStorage.Shared.FXConstants)
local Knockback = require(ReplicatedStorage.Shared.Damage.Knockback)
local Logger = require(ReplicatedStorage.Shared.Logger)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Trove = require(ReplicatedStorage.Shared.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local AttackRequestSystem = require(script.Parent.Parent.Attack.AttackRequestSystem)
local DamageSystem = require(script.Parent.Parent.Damage.DamageSystem)
local NetworkLatency = require(script.Parent.Parent.NetworkLatency)

local logger = Logger.scope("EnvironmentReactionSystem")

local EnvironmentReactionSystem = {}

-- One knocked body the server is watching for a wall arrival.
export type Watch = {
	Victim: Model,
	Attacker: Model,
	Root: BasePart,
	-- Where the launch was aimed at the wall, and the wall's outward normal there.
	WallPoint: Vector3,
	WallNormal: Vector3,
	Material: Enum.Material,
	Color: Color3,
	Deadline: number,
}

-- One committed swing waiting for its strike, for the scuff.
type PendingSwing = {
	StartedAt: number,
	StrikeAt: number,
}

local watches: { [Model]: Watch } = {}
local pendingSwings: { [Model]: PendingSwing } = {}

local started = false
local trove = Trove.New()
local appliedDisconnect: (() -> ())? = nil
local swingDisconnect: (() -> ())? = nil
local fxRemote: RemoteEvent? = nil
-- The swing scuff's own remote: unreliable, since dust is all it carries (EnvironmentConstants.Network).
local cosmeticRemote: UnreliableRemoteEvent? = nil

-- Helpers ------------------------------------------------------------------------------------------

local function surfaceColor(hit: EnvironmentProbe.Hit): Color3
	return EnvironmentProbe.ColorOf(
		hit,
		FXConstants.MovementDust.ColorByFloorMaterial,
		FXConstants.EnvironmentImpact.DefaultColor
	)
end

-- Round-trip latency for a player-backed body, 0 for a server-owned one (NetworkLatency).
local function pingSecondsFor(model: Model): number
	return NetworkLatency.PingSeconds(model)
end

-- Every player whose character is within `radius` of `position`, except `skip`.
local function playersNear(position: Vector3, radius: number, skip: Player?): { Player }
	local near = {}
	for _, player in Players:GetPlayers() do
		if player == skip then
			continue
		end
		local character = player.Character
		local root = if character then CharacterUtil.RootOf(character) else nil
		if root and (root.Position - position).Magnitude <= radius then
			table.insert(near, player)
		end
	end
	return near
end

-- A splat goes reliably (it carries a stun the victim mirrors); a scuff unreliably (it carries dust).
local function broadcast(payload: EnvironmentProbe.FxPayload, skip: Player?): ()
	local near = playersNear(payload.Position, EnvironmentConstants.SwingScuff.BroadcastRadiusStuds, skip)
	if payload.Kind == "SwingScuff" then
		local remote = cosmeticRemote
		if remote then
			for _, player in near do
				remote:FireClient(player, payload)
			end
		end
		return
	end
	local remote = fxRemote
	if remote then
		for _, player in near do
			remote:FireClient(player, payload)
		end
	end
end

-- The wall splat --------------------------------------------------------------------------------------

-- How far a launch can carry a body horizontally. A player's client decays the horizontal launch linearly
-- to zero over Knockback.HoldSeconds, so the flight is speed * hold / 2; ExtraReachStuds covers the rest
-- (a server-owned body's longer glide, and the body's own half-width).
function EnvironmentReactionSystem.ReachFor(horizontalSpeed: number): number
	return horizontalSpeed * DamageConstants.Knockback.HoldSeconds / 2 + EnvironmentConstants.WallSplat.ExtraReachStuds
end

-- Whether a root at `rootPosition` has ARRIVED at the watched wall: within ContactDistanceStuds of its
-- plane, and no further than MaxLateralDriftStuds along it from the aimed point. Pure, for the spec.
function EnvironmentReactionSystem.HasArrived(watch: Watch, rootPosition: Vector3): boolean
	local config = EnvironmentConstants.WallSplat
	local offset = rootPosition - watch.WallPoint
	local planeDistance = offset:Dot(watch.WallNormal)
	if planeDistance > config.ContactDistanceStuds then
		return false
	end
	local lateral = offset - watch.WallNormal * planeDistance
	return Vector3.new(lateral.X, 0, lateral.Z).Magnitude <= config.MaxLateralDriftStuds
end

-- Starts watching `victim` for a wall arrival under `launch`, or declines. Returns whether a watch began.
-- A newer launch replaces an older watch: a body knocked twice is going where the second knock sends it.
function EnvironmentReactionSystem.BeginWatch(
	victim: Model,
	attacker: Model,
	root: BasePart,
	launch: Vector3,
	now: number,
	pingSeconds: number
): boolean
	local config = EnvironmentConstants.WallSplat
	if not config.Enabled then
		return false
	end
	local flat, speed = Knockback.Horizontal(launch)
	if speed < config.MinHorizontalVelocity then
		return false
	end
	local direction = flat / speed
	local hit = EnvironmentProbe.Cast(
		root.Position,
		direction * EnvironmentReactionSystem.ReachFor(speed),
		{ victim, attacker }
	)
	if hit == nil or not EnvironmentProbe.IsWall(hit.Normal) then
		watches[victim] = nil
		return false
	end
	watches[victim] = {
		Victim = victim,
		Attacker = attacker,
		Root = root,
		WallPoint = hit.Position,
		WallNormal = hit.Normal,
		Material = hit.Material,
		Color = surfaceColor(hit),
		Deadline = now + config.WatchSeconds + math.min(pingSeconds * 2, config.PingAllowanceMaxSeconds),
	}
	return true
end

function EnvironmentReactionSystem.IsWatching(victim: Model): boolean
	return watches[victim] ~= nil
end

local function splat(watch: Watch, now: number): ()
	local config = EnvironmentConstants.WallSplat
	DamageSystem.ExtendHitstun(watch.Victim, now + config.StunSeconds, now)

	-- The impact point: where the root meets the wall's plane, not where the launch was first aimed -- the
	-- body may have arrived a little to one side.
	local rootPosition = watch.Root.Position
	local planeDistance = (rootPosition - watch.WallPoint):Dot(watch.WallNormal)
	broadcast({
		Kind = "WallSplat",
		Position = rootPosition - watch.WallNormal * planeDistance,
		Normal = watch.WallNormal,
		Material = watch.Material,
		Color = watch.Color,
		Victim = watch.Victim,
		Attacker = watch.Attacker,
		StunSeconds = config.StunSeconds,
	}, nil)
	logger:debug("Wall splat", { victim = watch.Victim.Name, attacker = watch.Attacker.Name })
end

local function stepWatches(now: number): ()
	for victim, watch in watches do
		if victim.Parent == nil or watch.Root.Parent == nil or CharacterUtil.LiveHumanoidOf(victim) == nil then
			watches[victim] = nil
			continue
		end
		if EnvironmentReactionSystem.HasArrived(watch, watch.Root.Position) then
			watches[victim] = nil
			splat(watch, now)
		elseif now >= watch.Deadline then
			watches[victim] = nil
		end
	end
end

local function onDamageApplied(outcome: DefenseTypes.DefenseOutcome, result: DamageTypes.DamageResult): ()
	local launch = result.Launch
	if launch == nil or outcome.Defender == outcome.Attacker then
		return
	end
	local root = outcome.Defender.PrimaryPart
	if root == nil then
		return
	end
	EnvironmentReactionSystem.BeginWatch(
		outcome.Defender,
		outcome.Attacker,
		root,
		launch,
		os.clock(),
		pingSecondsFor(outcome.Defender)
	)
end

-- The swing scuff -------------------------------------------------------------------------------------

local function onSwingAccepted(model: Model, view: AttackRequestSystem.InFlightView): ()
	if not EnvironmentConstants.SwingScuff.Enabled then
		return
	end
	pendingSwings[model] = {
		StartedAt = view.StartedAt,
		StrikeAt = view.StartedAt + view.WindupSeconds,
	}
end

local function stepSwings(now: number): ()
	for model, swing in pendingSwings do
		if now < swing.StrikeAt then
			continue
		end
		pendingSwings[model] = nil
		-- Still the same swing, still in flight: a feint, a parry or a stun in the windup never struck.
		local live = AttackRequestSystem.GetInFlight(model)
		if live == nil or live.StartedAt ~= swing.StartedAt then
			continue
		end
		local root = CharacterUtil.RootOf(model)
		if root == nil then
			continue
		end
		local hit = EnvironmentProbe.SwingFan(root.CFrame, { model })
		if hit == nil then
			continue
		end
		broadcast({
			Kind = "SwingScuff",
			Position = hit.Position,
			Normal = hit.Normal,
			Material = hit.Material,
			Color = surfaceColor(hit),
		}, Players:GetPlayerFromCharacter(model))
	end
end

-- Loop / lifecycle -----------------------------------------------------------------------------------

function EnvironmentReactionSystem.Step(now: number): ()
	if next(watches) ~= nil then
		stepWatches(now)
	end
	if next(pendingSwings) ~= nil then
		stepSwings(now)
	end
end

-- Subscribes to both extension points and nothing else -- split from Init, as DamageSystem.Attach is, so
-- a spec can drive Step on its own clock. Idempotent.
function EnvironmentReactionSystem.Attach(): ()
	if not appliedDisconnect then
		appliedDisconnect = DamageSystem.OnApplied(onDamageApplied)
	end
	if not swingDisconnect then
		swingDisconnect = AttackRequestSystem.OnSwingAccepted(onSwingAccepted)
	end
end

function EnvironmentReactionSystem.Init(): ()
	if started then
		return
	end
	assert(DamageSystem.ExtendHitstun ~= nil, "EnvironmentReactionSystem.Init() requires DamageSystem")
	started = true
	fxRemote = NetworkBridge.CreateRemoteEvent(EnvironmentConstants.Network.RemoteNames.Fx)
	cosmeticRemote = NetworkBridge.CreateUnreliableRemoteEvent(EnvironmentConstants.Network.RemoteNames.FxCosmetic)
	EnvironmentReactionSystem.Attach()
	trove:Connect(RunService.Heartbeat, function()
		EnvironmentReactionSystem.Step(os.clock())
	end)
	logger:info("EnvironmentReactionSystem.Init() complete")
end

function EnvironmentReactionSystem.Shutdown(): ()
	trove:Clean()
	started = false
end

-- Spec-only: drops every watch and subscription.
function EnvironmentReactionSystem.Reset(): ()
	if appliedDisconnect then
		appliedDisconnect()
		appliedDisconnect = nil
	end
	if swingDisconnect then
		swingDisconnect()
		swingDisconnect = nil
	end
	table.clear(watches)
	table.clear(pendingSwings)
end

return EnvironmentReactionSystem :: Types.SystemModule & typeof(EnvironmentReactionSystem)
