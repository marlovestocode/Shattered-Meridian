--!strict
--[[
	KnockbackAudit.lua

	Owns: detecting a client that ignores knockback. A player's body is simulated by that player's own
	client, so the launch DamageSystem hands it (Combat_Feedback's Knockback) is applied there -- and a
	cheating client can simply not apply it, standing its ground through every heavy hit. The server
	cannot force the launch without taking network ownership of the body on every knock (a hitch the
	victim would feel on every exchange); what it CAN do is watch.

	THE CHECK. After launching a player, sample that body's replicated velocity every server frame for
	DamageConstants.Knockback.Audit.SampleSeconds and keep the best speed ALONG the launch direction. A
	client that honoured the launch shows it at some sample; one that ignored it shows only whatever it
	was doing anyway. Knockback.Complied is the whole judgement, and it is deliberately lenient: the best
	sample need only reach ComplianceFraction of the launch.

	WHY IT IS HARD TO TRIP HONESTLY, which is the property that matters most for a detector:
	  * weak launches are never audited (Knockback.IsAuditable) -- below that line an honest knock and a
	    player simply running cannot be told apart;
	  * a launch the client was entitled to refuse is not audited: the server holds root control
	    (Attributes.RootControlLocked -- a grab, a mount, admin freeze), or a parkour action owns the
	    body's velocity (Attributes.ParkourVelocityOwned) -- ParkourMotor refuses or overwrites a write
	    in exactly those states;
	  * only the LATEST launch per player is audited; a second knock replaces the first rather than
	    judging a body being thrown two ways at once;
	  * a death or a despawn mid-sample drops the audit rather than failing it;
	  * one failure is nothing. FailuresBeforeFlag failures inside WindowSeconds flag the player ONCE per
	    session through the shared SuspicionLedger (ModerationSystem.ReportAutomated) -- the same path ParkourSystem's sustained-
	    implausible-report detector uses -- for an admin to look at, never an automatic punishment.

	A SIBLING OF THE ATTACK LAYER, like GrabSystem and EngagementSystem: it subscribes to
	DamageSystem.OnApplied (which carries the resolved DamageResult.Launch) and nothing reads it back.

	THE IDENTITY SEAM. Every Players lookup is in onDamageApplied and Init's lifecycle binding; Begin/
	Sample/RecordFailure take resolved identities, so Tests/Combat/Damage/Knockback.spec.lua drives every
	branch with stand-in players.

	Does not own: the launch (DamageSystem), applying it (Client/Combat/KnockbackClient.lua, or
	DamageSystem for a server-owned body), or any consequence of a flag (ModerationSystem, and an admin).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local DamageConstants = require(ReplicatedStorage.Shared.Damage.DamageConstants)
local DamageTypes = require(ReplicatedStorage.Shared.Damage.DamageTypes)
local DefenseTypes = require(ReplicatedStorage.Shared.Defense.DefenseTypes)
local Knockback = require(ReplicatedStorage.Shared.Damage.Knockback)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local Trove = require(ReplicatedStorage.Shared.Trove)
local Types = require(ReplicatedStorage.Shared.Types)
local GameplayEvents = require(ServerScriptService.Server.Events.GameplayEvents)
local SuspicionLedger = require(ServerScriptService.Server.Systems.Support.SuspicionLedger)

local DamageSystem = require(script.Parent.DamageSystem)

local logger = Logger.scope("KnockbackAudit")

local KnockbackAudit = {}

type Pending = {
	Root: BasePart,
	Launch: Vector3,
	Deadline: number,
	Best: number,
}

-- The one audit per player currently sampling. See this file's header on why a new launch replaces it.
local pending: { [Player]: Pending } = {}

-- Failed audits per player, counted and flagged through the shared SuspicionLedger (2026-10-08): the same window
-- and once-per-session flag this file used to hand-roll, now shared with ParkourSystem and MovementGuard.
local failures = SuspicionLedger.New({
	Name = "Knockback",
	ReasonCode = "KnockbackIgnored",
	Summary = "launches not honoured",
	Strikes = DamageConstants.Knockback.Audit.FailuresBeforeFlag,
	WindowSeconds = DamageConstants.Knockback.Audit.WindowSeconds,
})

local appliedDisconnect: (() -> ())? = nil
local tickDisconnect: (() -> ())? = nil
local lifecycle: Trove.TroveInstance? = nil
local started = false

-- Starts auditing `launch` for `player`, whose body is `root`. Returns whether an audit began.
function KnockbackAudit.Begin(player: Player, root: BasePart, launch: Vector3, now: number): boolean
	if not DamageConstants.Knockback.Audit.Enabled or not Knockback.IsAuditable(launch) then
		return false
	end
	pending[player] = {
		Root = root,
		Launch = launch,
		Deadline = now + DamageConstants.Knockback.Audit.SampleSeconds,
		Best = -math.huge,
	}
	return true
end

-- Folds one velocity sample into `player`'s audit. Returns "Complied" the moment the launch shows,
-- "Failed" once the window closes without it, or nil while still sampling (or when nothing is pending).
function KnockbackAudit.Sample(player: Player, velocity: Vector3, now: number): ("Complied" | "Failed")?
	local audit = pending[player]
	if audit == nil then
		return nil
	end
	audit.Best = math.max(audit.Best, Knockback.SpeedAlong(audit.Launch, velocity))
	if Knockback.Complied(audit.Launch, audit.Best) then
		pending[player] = nil
		return "Complied"
	end
	if now >= audit.Deadline then
		pending[player] = nil
		return "Failed"
	end
	return nil
end

-- Records one failed audit. Returns true exactly once per session per player: the moment the count
-- inside the window first reaches FailuresBeforeFlag.
function KnockbackAudit.RecordFailure(player: Player, now: number): boolean
	return failures:Strike(player, now)
end

function KnockbackAudit.IsPending(player: Player): boolean
	return pending[player] ~= nil
end

-- Drops every trace of `player`. Bound to PlayerRemoving by Init.
function KnockbackAudit.ReleasePlayer(player: Player): ()
	pending[player] = nil
	failures:Release(player)
end

-- One server frame over the (tiny) set of open audits. Only ever non-empty for a second or so after a
-- strong launch, so the walk costs nothing between fights.
local function step(): ()
	if next(pending) == nil then
		return
	end
	local now = os.clock()
	for player, audit in pending do
		local body = audit.Root.Parent
		local humanoid = if body and body:IsA("Model") then CharacterUtil.LiveHumanoidOf(body) else nil
		if humanoid == nil then
			-- Died or despawned mid-sample: nothing to judge.
			pending[player] = nil
			continue
		end
		local verdict = KnockbackAudit.Sample(player, audit.Root.AssemblyLinearVelocity, now)
		if verdict == "Failed" then
			KnockbackAudit.RecordFailure(player, now)
		end
	end
end

-- The adapter. See this file's header for every reason a launch is not audited.
local function onDamageApplied(outcome: DefenseTypes.DefenseOutcome, result: DamageTypes.DamageResult): ()
	local launch = result.Launch
	if launch == nil or not Knockback.IsAuditable(launch) then
		return
	end
	local player = Players:GetPlayerFromCharacter(outcome.Defender)
	if player == nil then
		return
	end
	local humanoid = CharacterUtil.HumanoidOf(outcome.Defender)
	local root = outcome.Defender.PrimaryPart
	if humanoid == nil or root == nil then
		return
	end
	if
		humanoid:GetAttribute(AttributeConstants.RootControlLocked) == true
		or humanoid:GetAttribute(AttributeConstants.ParkourVelocityOwned) == true
	then
		return
	end
	KnockbackAudit.Begin(player, root, launch, os.clock())
end

-- Subscribes to the damage layer's applied-hit signal. Split from Init for the same reason
-- EngagementSystem.Attach is. Idempotent.
function KnockbackAudit.Attach(): ()
	if appliedDisconnect then
		return
	end
	appliedDisconnect = DamageSystem.OnApplied(onDamageApplied)
end

function KnockbackAudit.Init(): ()
	if started then
		return
	end
	assert(DamageSystem.OnApplied ~= nil, "KnockbackAudit.Init() requires DamageSystem to be available")
	started = true

	KnockbackAudit.Attach()
	tickDisconnect = GameplayEvents.OnHeartbeatTick(step)
	lifecycle = PlayerLifecycle.BindAllPlayers({
		Scope = "KnockbackAudit",
		OnPlayerRemoving = KnockbackAudit.ReleasePlayer,
	})

	logger:info("KnockbackAudit.Init() complete", { enabled = DamageConstants.Knockback.Audit.Enabled })
end

-- Drops all state and every subscription. Spec-only.
function KnockbackAudit.Reset(): ()
	if appliedDisconnect then
		appliedDisconnect()
		appliedDisconnect = nil
	end
	if tickDisconnect then
		tickDisconnect()
		tickDisconnect = nil
	end
	if lifecycle then
		lifecycle:Clean()
		lifecycle = nil
	end
	table.clear(pending)
	failures:Reset()
	started = false
end

return KnockbackAudit :: Types.SystemModule & typeof(KnockbackAudit)
