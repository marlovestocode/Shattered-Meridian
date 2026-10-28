--!strict
--[[
	RagdollRules.lua

	Owns: the pure decisions around a ragdoll -- WHETHER a landed hit puts a body down (Resolve: the move's
	block and its trigger, the death fallback, the anti-lock rules), the THROW it is given (Impulse), and the
	joint numbers a stiffness maps to (JointLimits, FrictionTorque). No Instances are created, nothing is
	written; the anti-lock state is read off three Humanoid Attributes.

	WHY THE DECISION IS HERE AND NOT IN THE RUNTIME. DamageSystem must know a hit ragdolls BEFORE it fires
	OnApplied: a ragdolled body's launch belongs to the ragdoll (the server simulates it), so DamageSystem must
	not also hand that launch to the victim's client, nor a spacing push, nor let KnockbackAudit expect one. The
	damage layer may not require the ragdoll runtime (a sibling above it), so the runtime publishes its state as
	Attributes (AttributeConstants.Ragdolled / RagdollChainEndsAt / RagdollImmuneUntil -- the Attribute-seam
	pattern HitstunUntil already is) and this module reads them. DamageSystem asks Resolve; RagdollSystem applies
	exactly what DamageResult.Ragdoll says and never re-decides.

	One clock: the two deadlines are the server's os.clock(), the clock DamageSystem and CombatTick run on.
	Clients read only the Ragdolled flag (through BodyRestraint).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)
local RagdollConstants = require(ReplicatedStorage.Shared.Ragdoll.RagdollConstants)
local RagdollTypes = require(ReplicatedStorage.Shared.Ragdoll.RagdollTypes)
local Sanitize = require(ReplicatedStorage.Shared.Sanitize)

type RagdollSpec = RagdollTypes.RagdollSpec

local RagdollRules = {}

-- What Resolve needs to know about the contact. Kind is a DefenseTypes.OutcomeKind.
export type Contact = {
	Kind: string,
	-- The hit will kill (its damage reaches the defender's health).
	Lethal: boolean,
	-- The defender was off the ground when it landed.
	Airborne: boolean,
}

-- The outcomes that are a landed hit on the body -- the same three DamageResolver prices a hit for.
local LANDED: { [string]: boolean } = { Clean = true, Backstab = true, GuardBroken = true }

-- Whether `spec`'s trigger fires on this contact.
function RagdollRules.Triggers(spec: RagdollSpec, contact: Contact): boolean
	if not LANDED[contact.Kind] then
		return false
	end
	local trigger = spec.Trigger
	if trigger == "Hit" then
		return true
	elseif trigger == "Lethal" then
		return contact.Lethal
	elseif trigger == "Airborne" then
		return contact.Airborne
	elseif trigger == "GuardBreak" then
		return contact.Kind == "GuardBroken"
	elseif trigger == "Backstab" then
		return contact.Kind == "Backstab"
	end
	return false
end

local function numberAttribute(humanoid: Humanoid, name: string): number
	local value = humanoid:GetAttribute(name)
	return if typeof(value) == "number" then value else 0
end

-- Whether a NEW ragdoll may begin on this body at `now`, and the reason when not. RagdollConstants.Rules:
--   Immune    it got up less than ImmunitySeconds ago
--   Chained   it is limp, and has been since longer ago than MaxChainSeconds (or refreshing is off)
function RagdollRules.Admits(humanoid: Humanoid, now: number): (boolean, string?)
	local rules = RagdollConstants.Rules
	if humanoid:GetAttribute(AttributeConstants.Ragdolled) == true then
		if
			not rules.RefreshWhileRagdolled
			or now >= numberAttribute(humanoid, AttributeConstants.RagdollChainEndsAt)
		then
			return false, "Chained"
		end
		return true, nil
	end
	if now < numberAttribute(humanoid, AttributeConstants.RagdollImmuneUntil) then
		return false, "Immune"
	end
	return true, nil
end

-- The spec this contact ragdolls the defender with, or nil: the move's own block when its trigger fires, else
-- the death spec on a lethal hit (RagdollConstants.Death), provided the system is on and the body admits one.
-- `humanoid` nil (a body without one) never ragdolls.
function RagdollRules.Resolve(authored: RagdollSpec?, contact: Contact, humanoid: Humanoid?, now: number): RagdollSpec?
	if not RagdollConstants.Enabled or humanoid == nil then
		return nil
	end
	local spec: RagdollSpec? = nil
	if authored and RagdollRules.Triggers(authored, contact) then
		spec = authored
	elseif contact.Lethal and LANDED[contact.Kind] and RagdollConstants.Death.Enabled then
		spec = RagdollConstants.Death.Spec :: any
	end
	if spec == nil then
		return nil
	end
	-- A killing blow is never refused: a corpse is not "chained" or "immune", it is down for good.
	if not contact.Lethal and not RagdollRules.Admits(humanoid, now) then
		return nil
	end
	return spec
end

-- A non-finite vector (NaN anywhere, or infinite) becomes zero: nothing is thrown rather than everything.
local function clampMagnitude(vector: Vector3, maxMagnitude: number): Vector3
	local magnitude = vector.Magnitude
	local clamped = Sanitize.ClampNumber(magnitude, 0, maxMagnitude)
	if clamped == nil or magnitude == math.huge or magnitude <= 0 then
		return Vector3.zero
	end
	return if clamped == magnitude then vector else vector * (clamped / magnitude)
end

-- The throw: (linear velocity, angular velocity) in world space.
--   `away`    the flat direction the body is thrown in (from the attacker, or along a shot's flight); a zero
--             vector throws straight up / spins about nothing horizontal
--   `launch`  the move's resolved knockback launch (DamageResult.Launch), or nil
-- Linear is the launch scaled by KnockbackScale, plus Push along `away` and Lift up. Angular is Tumble about the
-- axis across the throw (positive tips the head back, away from the hit) plus Twist about up. Both clamped to
-- RagdollConstants.Limits.
function RagdollRules.Impulse(spec: RagdollSpec, away: Vector3, launch: Vector3?): (Vector3, Vector3)
	local flat = Vector3.new(away.X, 0, away.Z)
	local direction = if flat.Magnitude > 1e-4 then flat.Unit else Vector3.zero
	local linear = direction * spec.Push + Vector3.yAxis * spec.Lift
	if launch and spec.KnockbackScale > 0 then
		linear += launch * spec.KnockbackScale
	end
	-- up x direction: spinning about it with positive speed carries the top of the body along `direction`, the
	-- way the body is flying -- for a defender facing the hit, the head goes back: a backflip away from it.
	local up = Vector3.new(0, 1, 0)
	local across = if direction ~= Vector3.zero then up:Cross(direction) else Vector3.zero
	local angular = across * spec.Tumble + Vector3.yAxis * spec.Twist
	local limits = RagdollConstants.Limits
	return clampMagnitude(linear, limits.MaxLinearSpeed), clampMagnitude(angular, limits.MaxAngularSpeed)
end

export type JointClass = { Axis: Vector3, UpperAngle: number, TwistLower: number, TwistUpper: number }

-- The class a Motor6D's name puts it in (RagdollConstants.Rig.Joints).
function RagdollRules.JointClassOf(motorName: string): JointClass
	local joints = RagdollConstants.Rig.Joints
	if motorName == "Neck" then
		return joints.Neck
	elseif string.find(motorName, "Shoulder", 1, true) then
		return joints.Shoulder
	elseif string.find(motorName, "Hip", 1, true) then
		return joints.Hip
	end
	return joints.Default
end

-- A class's cone and twist at `stiffness` (0..1): the class angles at 0, StiffAngleScale of them at 1.
function RagdollRules.JointLimits(class: JointClass, stiffness: number): (number, number, number)
	local scale = 1 + (RagdollConstants.Rig.StiffAngleScale - 1) * math.clamp(stiffness, 0, 1)
	return class.UpperAngle * scale, class.TwistLower * scale, class.TwistUpper * scale
end

-- Socket friction torque at `stiffness`.
function RagdollRules.FrictionTorque(stiffness: number): number
	local range = RagdollConstants.Rig.FrictionTorque
	return range.Limp + (range.Stiff - range.Limp) * math.clamp(stiffness, 0, 1)
end

-- An angle eased from `from` to the get-up's final angle (signed like `from`) at `alpha` (0..1).
function RagdollRules.TightenedAngle(from: number, alpha: number): number
	local final = RagdollConstants.Recovery.FinalAngleDegrees
	local target = if from < 0 then -final else final
	if math.abs(from) <= final then
		return from
	end
	return from + (target - from) * math.clamp(alpha, 0, 1)
end

-- Whether a body moving at these speeds is at rest (RagdollConstants.Settle).
function RagdollRules.AtRest(linearSpeed: number, angularSpeed: number): boolean
	local settle = RagdollConstants.Settle
	return linearSpeed <= settle.LinearSpeed and angularSpeed <= settle.AngularSpeed
end

return RagdollRules
