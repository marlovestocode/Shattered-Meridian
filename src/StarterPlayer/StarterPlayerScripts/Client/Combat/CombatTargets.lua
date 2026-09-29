--!strict
--[[
	CombatTargets.lua

	Owns: "who could this client be fighting" -- the one answer lock-on (LockOnController.lua) and swing
	tracking (SwingTracking.lua) both draw from. A candidate is any model carrying HitboxEngineConstants.
	CombatantTag (the tag HitboxEngine puts on every registered combatant: players, training bots and debug
	dummies alike, and it replicates) that has a living Humanoid and a root, other than the local
	character itself.

	WHY THE TAG AND NOT Players:GetPlayers(). A bot or a dummy is a real opponent and has no Player. The tag
	is the engine's own list of who can be hit, so nothing here can disagree with it about who counts.

	Pure reads, no state. The candidate list is re-read on each call rather than cached, because it is only
	asked on a lock-on press and once per swing, and a cache would need its own respawn bookkeeping.

	Does not own: which candidate is chosen for what (the callers), or whether a hit lands (the server).
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local HitboxEngineConstants = require(ReplicatedStorage.Shared.HitboxEngine.HitboxEngineConstants)

local CombatTargets = {}

-- The candidate's root, when it is a live, targetable combatant other than `selfModel`.
function CombatTargets.LiveRoot(model: Instance?, selfModel: Model?): BasePart?
	if model == nil or not model:IsA("Model") or model == selfModel or model.Parent == nil then
		return nil
	end
	local asModel = model :: Model
	if CharacterUtil.LiveHumanoidOf(asModel) == nil then
		return nil
	end
	return CharacterUtil.RootOf(asModel)
end

-- Every live candidate, with its root.
function CombatTargets.All(selfModel: Model?): { { Model: Model, Root: BasePart } }
	local result = {}
	for _, instance in CollectionService:GetTagged(HitboxEngineConstants.CombatantTag) do
		local root = CombatTargets.LiveRoot(instance, selfModel)
		if root then
			table.insert(result, { Model = instance :: Model, Root = root })
		end
	end
	return result
end

-- The angle, in degrees, between flat `forward` and the flat direction from `origin` to `point`, and the
-- flat distance. Returns (180, distance) when either direction is degenerate.
function CombatTargets.FlatBearing(origin: Vector3, forward: Vector3, point: Vector3): (number, number)
	local offset = Vector3.new(point.X - origin.X, 0, point.Z - origin.Z)
	local distance = offset.Magnitude
	local flatForward = Vector3.new(forward.X, 0, forward.Z)
	if distance < 1e-3 or flatForward.Magnitude < 1e-3 then
		return 180, distance
	end
	local dot = math.clamp(offset.Unit:Dot(flatForward.Unit), -1, 1)
	return math.deg(math.acos(dot)), distance
end

-- The nearest live candidate within `rangeStuds` of `origin` and within `coneDegrees` of flat `forward`,
-- or nil. Nearest by distance: this is the swing assist's pick, where the closest body is the one the
-- swing was aimed at.
function CombatTargets.NearestInCone(
	origin: Vector3,
	forward: Vector3,
	rangeStuds: number,
	coneDegrees: number,
	selfModel: Model?
): Model?
	local best: Model? = nil
	local bestDistance = math.huge
	for _, candidate in CombatTargets.All(selfModel) do
		local angle, distance = CombatTargets.FlatBearing(origin, forward, candidate.Root.Position)
		if distance <= rangeStuds and angle <= coneDegrees and distance < bestDistance then
			best = candidate.Model
			bestDistance = distance
		end
	end
	return best
end

-- The yaw (radians, Roblox's convention: CFrame.Angles(0, yaw, 0) looks along it) of flat `direction`,
-- or nil for a degenerate one.
function CombatTargets.YawOf(direction: Vector3): number?
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 1e-3 then
		return nil
	end
	return math.atan2(-flat.X, -flat.Z)
end

-- The signed shortest difference `to - from` between two angles, in (-pi, pi].
function CombatTargets.AngleDelta(from: number, to: number): number
	local delta = (to - from) % (2 * math.pi)
	if delta > math.pi then
		delta -= 2 * math.pi
	end
	return delta
end

return CombatTargets
