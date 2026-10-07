--!strict
--[[
	DomainEffects.lua

	Owns: delivering ONE pulse of ONE realm effect to the bodies DomainSystem chose for it -- turning an
	authored Effect (DomainTypes) into calls on the systems that already do each thing. There is no damage,
	stun, guard or movement logic in this file; there is only the choice of which existing entry point a
	kind goes through, and the geometry of where a strike comes from.

	    Strike     the referenced move -- or, naming none, the REALM'S OWN (the domain move itself: its
	               Damage, PostureDamage, PowerLevel and Knockback, authored once and read by every
	               unnamed Strike) -- delivered to each target as ONE homing shot pinned to that body
	               (HitboxEngine.LaunchVolley, Exclusive). The engine reports the contact as the owner's;
	               DefenseSystem decides block / parry / evade exactly as for any shot (Parryable picks
	               CannotParry, and a parry DESTROYS the strike -- it never staggers an owner who may be on
	               the far side of the realm); DamageSystem prices it as that move, flat, times the
	               effect's Power.
	    Volley     the referenced PROJECTILE move's own volley, aimed at each target from the realm. Its own
	               spread, piercing, bounces and parry answers apply; it can hit whoever it meets. A move
	               with no Projectile block is delivered as a Strike instead (warned once).
	    Hitstun    DamageSystem.ExtendHitstun -- the stun a landed hit gives, for Magnitude seconds (max
	               MAX_HITSTUN_SECONDS). It cancels the target's swing, as a hit does.
	    GuardDrain DefenseSystem.DrainGuard -- Magnitude posture. Can break a guard.
	    Pull/Push  a horizontal launch toward / away from the realm's centre at Magnitude studs/s, through the
	               same owner split DamageSystem's knockback uses (the realm's Impulse port).
	    OwnerCast  the OWNER throws the referenced move (AttackRequestSystem.ThrowMove, every gate included
	               -- a stunned owner's cast is refused like any press). Once per pulse; targets unused.

	A CONTESTED REALM hits lighter: `scale` (its ContestScale, or 1) multiplies every Magnitude and starts
	each strike's shot at that DamageScale, which the damage layer already applies to health and posture.

	PORTS, NOT REQUIRES. Every system call goes through the Ports table DomainSystem hands in, so a spec
	drives a pulse against stubs and asserts on exactly which entry point was called with what -- and so
	this file cannot quietly grow a second path to any of them.

	Does not own: choosing targets or timing pulses (DomainSystem), or what any delivery does once made.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local DomainConstants = require(ReplicatedStorage.Shared.Domain.DomainConstants)
local DomainTypes = require(ReplicatedStorage.Shared.Domain.DomainTypes)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)
local ProjectileTypes = require(ReplicatedStorage.Shared.HitboxEngine.ProjectileTypes)

local logger = Logger.scope("DomainEffects")

local DomainEffects = {}

-- The longest stun one Hitstun pulse may hand out (DomainConstants.MaxHitstunSeconds' reasoning).
local MAX_HITSTUN_SECONDS = DomainConstants.MaxHitstunSeconds

-- What a pulse needs from the rest of the server. See this file's header (PORTS).
export type CatalogEntry = {
	MoveId: string,
	Definition: HitboxTypes.AttackDefinition,
	PowerLevel: number,
}

export type Ports = {
	CatalogGet: (moveId: string) -> CatalogEntry?,
	LaunchVolley: (
		owner: Model,
		definition: HitboxTypes.AttackDefinition,
		aim: CFrame,
		powerLevel: number,
		now: number,
		options: { [string]: any }
	) -> (number, number),
	ExtendHitstun: (model: Model, until_: number, at: number) -> (),
	DrainGuard: (model: Model, amount: number, now: number) -> any,
	ThrowMove: (model: Model, moveId: string, now: number) -> (boolean, string?),
	Impulse: (model: Model, velocity: Vector3, now: number) -> (),
}

-- What one pulse is told about the realm it belongs to.
export type Source = {
	Id: string,
	-- The move that opened the realm: the price of every Strike that names no move of its own.
	MoveId: string,
	Owner: Model,
	Center: Vector3,
	-- Seeded per realm so a Ring strike's bearing is varied but a spec's is reproducible.
	Random: Random,
}

local warned: { [string]: boolean } = {}
local function warnOnce(key: string, message: string, data: { [string]: any }): ()
	if warned[key] then
		return
	end
	warned[key] = true
	logger:warn(message, data)
end

-- Where a strike on `targetPosition` starts.
local function originFor(effect: DomainTypes.Effect, source: Source, targetPosition: Vector3): Vector3
	local distance = effect.OriginDistance
	local origin = effect.Origin
	if origin == "Center" then
		-- A target standing on the centre would be struck from inside itself; it is struck from above.
		if (source.Center - targetPosition).Magnitude > 1 then
			return source.Center
		end
	elseif origin == "Owner" then
		local root = CharacterUtil.RootOf(source.Owner)
		if root and (root.Position - targetPosition).Magnitude > 1 then
			return root.Position
		end
	elseif origin == "Ring" then
		local angle = source.Random:NextNumber(0, 2 * math.pi)
		return targetPosition
			+ Vector3.new(math.cos(angle) * distance, DomainConstants.RingHeightStuds, math.sin(angle) * distance)
	end
	return targetPosition + Vector3.yAxis * distance
end

-- The shot a Strike flies: one, pinned, fast enough to cross its distance in TravelSeconds, and passing
-- through the world -- the realm is the only wall a strike respects (the barrier slot exempts it anyway).
function DomainEffects.StrikeSpec(effect: DomainTypes.Effect, distance: number): ProjectileTypes.ProjectileSpec
	local limits = ProjectileTypes.Limits
	local tuning = DomainConstants.Strike
	local spec = ProjectileTypes.Defaults()
	spec.Count = 1
	spec.SpreadPattern = "Single"
	spec.Speed = math.clamp(distance / math.max(effect.TravelSeconds, 0.01), limits.Speed.Min, limits.Speed.Max)
	spec.LifetimeSeconds = math.clamp(
		effect.TravelSeconds + tuning.LifetimeSlackSeconds,
		limits.LifetimeSeconds.Min,
		limits.LifetimeSeconds.Max
	)
	spec.MaxRange = math.clamp(distance * tuning.RangeMultiplier, limits.MaxRange.Min, limits.MaxRange.Max)
	spec.Size = math.clamp(effect.StrikeSize, limits.Size.Min, limits.Size.Max)
	spec.SpawnDirection = "Anchor"
	spec.Gravity = 0
	spec.Acceleration = 0
	spec.Piercing = false
	spec.CollisionBehavior = "Continue"
	spec.Homing = true
	spec.HomingStrength = math.min(tuning.HomingStrength, limits.HomingStrength.Max)
	spec.HomingMaxAngle = limits.HomingMaxAngle.Max
	spec.HomingRange = math.clamp(distance * tuning.RangeMultiplier, 30, limits.HomingRange.Max)
	spec.TargetSelection = "Nearest"
	spec.CanHitOwner = false
	spec.ParryBehavior = if effect.Parryable then "ParryOne" else "CannotParry"
	spec.ParryResponse = "Destroy"
	return spec
end

local function strike(
	effect: DomainTypes.Effect,
	entry: CatalogEntry,
	source: Source,
	target: Model,
	now: number,
	scale: number,
	ports: Ports
): number
	local root = CharacterUtil.RootOf(target)
	if root == nil then
		return 0
	end
	local origin = originFor(effect, source, root.Position)
	local toward = root.Position - origin
	local distance = toward.Magnitude
	if distance < 0.5 then
		return 0
	end
	local definition = table.clone(entry.Definition)
	definition.Projectile = DomainEffects.StrikeSpec(effect, distance)
	local aim = CFrame.lookAt(origin, root.Position)
	local _, launched = ports.LaunchVolley(source.Owner, definition, aim, entry.PowerLevel, now, {
		Target = target,
		Exclusive = true,
		DomainId = source.Id,
		DamageScale = scale,
	})
	return launched
end

local function volley(
	effect: DomainTypes.Effect,
	entry: CatalogEntry,
	source: Source,
	target: Model,
	now: number,
	scale: number,
	ports: Ports
): number
	local root = CharacterUtil.RootOf(target)
	if root == nil then
		return 0
	end
	local origin = originFor(effect, source, root.Position)
	if (root.Position - origin).Magnitude < 0.5 then
		return 0
	end
	local _, launched = ports.LaunchVolley(
		source.Owner,
		entry.Definition,
		CFrame.lookAt(origin, root.Position),
		entry.PowerLevel,
		now,
		{
			Target = target,
			Exclusive = false,
			DomainId = source.Id,
			DamageScale = scale,
		}
	)
	return launched
end

-- Delivers one pulse of `effect` to `targets`. Returns the bodies it actually reached (for the realm's
-- Pulse message to clients) -- the owner alone for an OwnerCast that was accepted -- and how many shots it
-- launched. `shotBudget` (DomainConstants.Strike's shot budget; nil is unlimited) stops a Strike/Volley
-- pulse once that many shots are out: checked before each target, so a Volley may finish the volley it
-- started past it.
function DomainEffects.Deliver(
	effect: DomainTypes.Effect,
	source: Source,
	targets: { Model },
	now: number,
	scale: number,
	ports: Ports,
	shotBudget: number?
): ({ Model }, number)
	local reached: { Model } = {}
	local kind = effect.Kind

	if kind == "OwnerCast" then
		local ok = ports.ThrowMove(source.Owner, effect.MoveId, now)
		if ok then
			table.insert(reached, source.Owner)
		end
		return reached, 0
	end

	if kind == "Strike" or kind == "Volley" then
		-- A Strike that names no move is the realm's own: priced by the move that opened it.
		local moveId = if effect.MoveId == "" and kind == "Strike" then source.MoveId else effect.MoveId
		local entry = ports.CatalogGet(moveId)
		if entry == nil then
			warnOnce(`missing:{moveId}`, "A realm effect names a move the catalogue cannot resolve; skipped", {
				realm = source.Id,
				moveId = moveId,
			})
			return reached, 0
		end
		-- Power multiplies whatever the contest left of the price.
		scale *= effect.Power
		local asVolley = kind == "Volley" and entry.Definition.Projectile ~= nil
		if kind == "Volley" and not asVolley then
			warnOnce(`notProjectile:{effect.MoveId}`, "A realm Volley names a melee move; delivering it as a Strike", {
				moveId = effect.MoveId,
			})
		end
		local spent = 0
		for _, target in targets do
			if shotBudget ~= nil and spent >= shotBudget then
				break
			end
			local launched = if asVolley
				then volley(effect, entry, source, target, now, scale, ports)
				else strike(effect, entry, source, target, now, scale, ports)
			if launched > 0 then
				spent += launched
				table.insert(reached, target)
			end
		end
		return reached, spent
	end

	local magnitude = effect.Magnitude * scale
	for _, target in targets do
		if kind == "Hitstun" then
			local seconds = math.min(magnitude, MAX_HITSTUN_SECONDS)
			if seconds > 0 then
				ports.ExtendHitstun(target, now + seconds, now)
				table.insert(reached, target)
			end
		elseif kind == "GuardDrain" then
			if magnitude > 0 then
				ports.DrainGuard(target, magnitude, now)
				table.insert(reached, target)
			end
		elseif kind == "Pull" or kind == "Push" then
			local root = CharacterUtil.RootOf(target)
			if root then
				local between = source.Center - root.Position
				local flat = Vector3.new(between.X, 0, between.Z)
				if flat.Magnitude > 0.5 then
					local direction = if kind == "Pull" then flat.Unit else -flat.Unit
					local speed = math.min(magnitude, DomainConstants.ImpulseMaxSpeed)
					if speed > 0 then
						ports.Impulse(target, direction * speed, now)
						table.insert(reached, target)
					end
				end
			end
		end
	end
	return reached, 0
end

-- Spec-only: forget which warnings have been raised.
function DomainEffects.ResetForTesting(): ()
	table.clear(warned)
end

return DomainEffects
