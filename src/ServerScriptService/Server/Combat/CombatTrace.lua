--!strict
--[[
	CombatTrace.lua

	Owns: "why did that attack do that?" -- one structured log line per step a combat interaction takes, on the
	"CombatTrace" Logger scope, readable in the Live Console (F5) with the console's own scope filter:

	  * Press refused  -- a press that will not throw, and why (AttackRequestSystem.OnPressRefused): a gate's
	                      refusal, or a buffered press that expired, was superseded, or was dropped.
	  * Swing thrown   -- a swing the attack layer accepted (AttackRequestSystem.OnSwingAccepted).
	  * Contact        -- what the defence layer made of a contact (DefenseSystem.OnResolved), with the inputs the
	                      resolver judged it against: the defender's state, block held, parry live / spent, guard
	                      disabled (air-held, stunned, NoBlock realm), evading, and the hit's source.
	  * Applied        -- what the damage layer did with it (DamageSystem.OnApplied): damage, posture, stun.

	A SIBLING, the same shape as Engagement and KnockbackAudit: it subscribes to the layers' existing extension
	points and is read by nothing. No layer learns that it exists, and removing this file changes no outcome.

	FREE WHEN NOBODY IS LOOKING. Lines are Debug level, which the Logger only captures while an admin has the
	Live Console open (LiveConsoleSystem raises the capture level), and every handler asks Logger.IsCapturing
	first -- so outside an open console not one field table is built. DebugConstants.CombatTrace.Enabled turns
	it off outright.

	Does not own: any decision. It reports what the layers decided; it never re-derives an outcome.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatPower = require(ReplicatedStorage.Shared.Progression.CombatPower)
local DamageTypes = require(ReplicatedStorage.Shared.Damage.DamageTypes)
local DebugConstants = require(ReplicatedStorage.Shared.DebugConstants)
local DefenseTypes = require(ReplicatedStorage.Shared.Defense.DefenseTypes)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)

local AttackRequestSystem = require(script.Parent.Attack.AttackRequestSystem)
local DamageSystem = require(script.Parent.Damage.DamageSystem)
local DefenseSystem = require(script.Parent.Defense.DefenseSystem)

local logger = Logger.scope("CombatTrace")

local CombatTrace = {}

local disconnects: { () -> () } = {}

local function tracing(): boolean
	return DebugConstants.CombatTrace.Enabled and Logger.IsCapturing("Debug")
end

local function nameOf(model: Model?): string
	return if model then model.Name else "?"
end

-- Rounded so a console line reads as numbers, not as float noise.
local function round(value: number?, places: number?): number?
	if typeof(value) ~= "number" or value ~= value then
		return nil
	end
	local scale = 10 ^ (places or 2)
	return math.floor(value * scale + 0.5) / scale
end

-- The fields of one resolved contact. Exposed for a spec, which has no console to read.
function CombatTrace.DescribeContact(outcome: DefenseTypes.DefenseOutcome): { [string]: unknown }
	local fields: { [string]: unknown } = {
		attacker = nameOf(outcome.Attacker),
		defender = nameOf(outcome.Defender),
		move = outcome.Report.DebugName,
		source = HitboxTypes.SourceOf(outcome.Report),
		kind = outcome.Kind,
		perfect = if outcome.Perfect then true else nil,
		clash = outcome.Clash,
		bearing = round(outcome.BearingDegrees, 0),
		stateAtContact = outcome.DefenderStateAtContact,
		guardDelta = round(outcome.GuardDelta),
	}
	local inputs = outcome.Inputs
	if inputs then
		fields.blockHeld = inputs.BlockHeld
		fields.parryLive = inputs.ParryLive
		fields.parrySpent = inputs.ParryConsumed
		fields.guardDisabled = if inputs.GuardDisabled then true else nil
		fields.evading = if inputs.Evading then true else nil
		fields.guardBefore = round(inputs.Guard)
	end
	return fields
end

-- The fields of one applied hit. Exposed for a spec.
function CombatTrace.DescribeApplied(
	outcome: DefenseTypes.DefenseOutcome,
	result: DamageTypes.DamageResult
): { [string]: unknown }
	-- The cultivation tier gap that scaled this hit, only when power is on and there was one -- a hit that
	-- landed for more or less than its move says should say why.
	local tierGap = if CombatPower.IsEnabled() then CombatPower.TierGap(outcome.Attacker, outcome.Defender) else 0
	return {
		attacker = nameOf(outcome.Attacker),
		defender = nameOf(outcome.Defender),
		move = outcome.Report.DebugName,
		source = HitboxTypes.SourceOf(outcome.Report),
		kind = outcome.Kind,
		tierGap = if tierGap ~= 0 then tierGap else nil,
		damage = round(result.Damage),
		posture = round(result.GuardDrain),
		stun = if result.HitstunSeconds > 0 then round(result.HitstunSeconds) else nil,
		launched = if result.Launch ~= nil then true else nil,
		grab = if result.Grab ~= nil then true else nil,
	}
end

local function onPressRefused(model: Model, pressId: number, reason: string): ()
	if not tracing() then
		return
	end
	logger:debug("Press refused", { who = model.Name, press = pressId, reason = reason })
end

local function onSwingAccepted(model: Model, view: AttackRequestSystem.InFlightView): ()
	if not tracing() then
		return
	end
	logger:debug("Swing thrown", {
		who = model.Name,
		move = view.MoveId,
		windup = round(view.WindupSeconds),
		power = view.PowerLevel,
	})
end

local function onResolved(outcome: DefenseTypes.DefenseOutcome): ()
	if not tracing() then
		return
	end
	logger:debug("Contact", CombatTrace.DescribeContact(outcome))
end

local function onApplied(outcome: DefenseTypes.DefenseOutcome, result: DamageTypes.DamageResult): ()
	if not tracing() then
		return
	end
	logger:debug("Applied", CombatTrace.DescribeApplied(outcome, result))
end

function CombatTrace.Init(): ()
	if #disconnects > 0 then
		return
	end
	table.insert(disconnects, AttackRequestSystem.OnPressRefused(onPressRefused))
	table.insert(disconnects, AttackRequestSystem.OnSwingAccepted(onSwingAccepted))
	table.insert(disconnects, DefenseSystem.OnResolved(onResolved))
	table.insert(disconnects, DamageSystem.OnApplied(onApplied))
end

function CombatTrace.Shutdown(): ()
	for _, disconnect in disconnects do
		disconnect()
	end
	table.clear(disconnects)
end

return CombatTrace
