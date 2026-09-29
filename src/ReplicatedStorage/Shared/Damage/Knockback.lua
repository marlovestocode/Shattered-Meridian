--!strict
--[[
	Knockback.lua

	Owns: turning a move's authored knockback (MoveTypes.MoveKnockback) and the two combatants' positions
	into one world-space launch velocity -- the whole of "which way, and how hard" -- plus the pure checks
	the anti-knockback audit is built on.

	Pure: no services, no Instances, no clock. Server/Combat/Damage/DamageSystem.lua calls LaunchVelocity
	once per landed hit and publishes the answer on DamageResult.Launch, so every consumer (the defender's
	client, the server-owned-body application, the audit) reads ONE computed launch rather than three
	re-derivations that could disagree.

	DIRECTION IS ATTACKER -> DEFENDER, FLATTENED. The knock carries the defender away from whoever hit
	them, whatever way either is facing -- a backstab knocks you forward, away from the blade. When the two
	roots coincide horizontally (a hit at point-blank from directly above or below), the attacker's facing
	is the fallback, and with no facing either the launch is purely vertical.

	MAGNITUDES ARE AUTHORED, BOUNDS ARE NOT. HorizontalVelocity/UpVelocity come from the move; the clamp to
	DamageConstants.Knockback.MaxHorizontalVelocity/MaxUpVelocity is the only thing this adds. Negative
	authored values are treated as zero: a "pull" is a different mechanic (GrabSystem's), not a sign flip.

	Not handled here: MoveKnockback.StartsAirCombo, which is not a velocity -- AirComboSystem reads it to
	decide whether the hit opens an air string (AirComboMoves.IsLauncher).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DamageConstants = require(ReplicatedStorage.Shared.Damage.DamageConstants)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

local Knockback = {}

local EPSILON = 1e-3

local function finiteNonNegative(value: number): number
	if typeof(value) ~= "number" or value ~= value or value <= 0 or value == math.huge then
		return 0
	end
	return value
end

local function flatUnit(vector: Vector3): Vector3?
	local flat = Vector3.new(vector.X, 0, vector.Z)
	if flat.Magnitude < EPSILON then
		return nil
	end
	return flat.Unit
end

-- The launch for one landed hit, or nil when the move authors no knock at all (both components zero).
function Knockback.LaunchVelocity(
	attackerPosition: Vector3,
	defenderPosition: Vector3,
	attackerLook: Vector3,
	knockback: MoveTypes.MoveKnockback
): Vector3?
	local bounds = DamageConstants.Knockback
	local horizontal = math.min(finiteNonNegative(knockback.HorizontalVelocity), bounds.MaxHorizontalVelocity)
	local up = math.min(finiteNonNegative(knockback.UpVelocity), bounds.MaxUpVelocity)
	if horizontal <= 0 and up <= 0 then
		return nil
	end
	local direction = flatUnit(defenderPosition - attackerPosition) or flatUnit(attackerLook) or Vector3.zero
	return direction * horizontal + Vector3.new(0, up, 0)
end

-- The horizontal part of `launch` and its speed. Split out because the client hold and the audit both
-- work on the flat component only -- gravity owns the vertical one.
function Knockback.Horizontal(launch: Vector3): (Vector3, number)
	local flat = Vector3.new(launch.X, 0, launch.Z)
	return flat, flat.Magnitude
end

-- Speed of `velocity` along the launch's horizontal direction. What the audit samples: an honoured
-- launch shows up here, a player running sideways does not.
function Knockback.SpeedAlong(launch: Vector3, velocity: Vector3): number
	local flat, speed = Knockback.Horizontal(launch)
	if speed < EPSILON then
		return 0
	end
	return Vector3.new(velocity.X, 0, velocity.Z):Dot(flat / speed)
end

-- Whether a launch is strong enough to audit at all (DamageConstants.Knockback.Audit.MinHorizontalVelocity).
function Knockback.IsAuditable(launch: Vector3): boolean
	local _, speed = Knockback.Horizontal(launch)
	return speed >= DamageConstants.Knockback.Audit.MinHorizontalVelocity
end

-- Whether the best sampled speed along the launch shows the client honoured it.
function Knockback.Complied(launch: Vector3, bestSpeedAlong: number): boolean
	local _, speed = Knockback.Horizontal(launch)
	return bestSpeedAlong >= speed * DamageConstants.Knockback.Audit.ComplianceFraction
end

return Knockback
