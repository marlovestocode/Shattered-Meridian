--!strict
--[[
	EnvironmentProbe.lua

	Owns: the one question both halves of the environment's reactions ask -- "is there a real, visible,
	non-character surface along this ray, and what does it look like" -- plus the payload shape the server
	sends when it finds one.

	SHARED, AND THAT IS THE POINT. The swing scuff is decided twice (EnvironmentConstants.SwingScuff: the
	attacker's client predicts its own, the server tells everyone else), and two copies of "what counts as
	a wall" would drift into a scuff the attacker sees and nobody else does. One cast, one filter, one
	color rule, required by Server/Combat/Environment/EnvironmentReactionSystem.lua and
	Client/FX/EnvironmentFX.lua alike.

	WHAT IS NOT A SURFACE: any part of a Model with a Humanoid (a body, player or bot -- the same "bodies are
	not terrain" lesson the parkour probes learned), a part that does not collide (RespectCanCollide), and a
	part nobody can see (EnvironmentConstants.MaxSurfaceTransparency). A cast that meets a body steps past
	it -- up to MAX_PASSES times -- rather than stopping, so a wall behind your opponent still reads.

	Does not own: when to cast (the reaction system / the FX client), what happens after (the stun, the
	dust), or any tuning (EnvironmentConstants).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local EnvironmentConstants = require(ReplicatedStorage.Shared.Combat.EnvironmentConstants)

local EnvironmentProbe = {}

export type Hit = {
	Position: Vector3,
	Normal: Vector3,
	Material: Enum.Material,
	-- The surface's own look: a part's Color, or for Terrain the caller's per-material color.
	Instance: Instance,
	Distance: number,
}

-- Combat_EnvironmentFX's payload (EnvironmentConstants.Network.RemoteNames.Fx).
export type FxPayload = {
	Kind: "SwingScuff" | "WallSplat",
	Position: Vector3,
	Normal: Vector3,
	Material: Enum.Material,
	Color: Color3,
	-- WallSplat only: who hit the wall, who put them there, and how long they are stunned for -- so the
	-- victim's own client can mirror the stun (LocalCombatState) and each side picks its own shake.
	Victim: Model?,
	Attacker: Model?,
	StunSeconds: number?,
}

-- How many bodies a single cast may step past before giving up. A crowd between you and the wall is
-- still a wall; a cast through a dozen bodies is a brawl nobody needs dust for.
local MAX_PASSES = 4

local function isBody(instance: Instance): boolean
	local model = instance:FindFirstAncestorOfClass("Model")
	while model do
		if model:FindFirstChildOfClass("Humanoid") then
			return true
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return false
end

-- Whether a raycast result is a surface the environment reacts to. See this file's header.
function EnvironmentProbe.IsSurface(instance: Instance): boolean
	if instance:IsA("Terrain") then
		return true
	end
	if not instance:IsA("BasePart") then
		return false
	end
	if instance.Transparency >= EnvironmentConstants.MaxSurfaceTransparency then
		return false
	end
	return not isBody(instance)
end

-- Whether `normal` belongs to a wall rather than a floor or a ceiling (EnvironmentConstants.MaxWallNormalY).
function EnvironmentProbe.IsWall(normal: Vector3): boolean
	return math.abs(normal.Y) <= EnvironmentConstants.MaxWallNormalY
end

-- Casts from `origin` along `direction` (whose length is the reach), stepping past bodies and see-through
-- parts, and returns the first real surface, or nil. `exclude` is what the caller already knows to skip
-- (its own character, usually).
function EnvironmentProbe.Cast(origin: Vector3, direction: Vector3, exclude: { Instance }): Hit?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.RespectCanCollide = true
	params.IgnoreWater = true
	local skip = table.clone(exclude)
	params.FilterDescendantsInstances = skip

	for _ = 1, MAX_PASSES do
		local result = Workspace:Raycast(origin, direction, params)
		if result == nil then
			return nil
		end
		if EnvironmentProbe.IsSurface(result.Instance) then
			return {
				Position = result.Position,
				Normal = result.Normal,
				Material = result.Material,
				Instance = result.Instance,
				Distance = result.Distance,
			}
		end
		-- A body, or something nobody can see: step past it. Skipping the whole body model, not just the
		-- limb, so the next pass does not meet its other arm.
		local model = result.Instance:FindFirstAncestorOfClass("Model")
		table.insert(skip, if model and isBody(result.Instance) then model else result.Instance)
		params.FilterDescendantsInstances = skip
	end
	return nil
end

-- The nearest WALL across a horizontal fan in front of `rootCFrame` (EnvironmentConstants.SwingScuff),
-- or nil. The swing scuff's whole probe, shared by the predicting client and the server.
function EnvironmentProbe.SwingFan(rootCFrame: CFrame, exclude: { Instance }): Hit?
	local config = EnvironmentConstants.SwingScuff
	local look = Vector3.new(rootCFrame.LookVector.X, 0, rootCFrame.LookVector.Z)
	if look.Magnitude < 1e-3 then
		return nil
	end
	look = look.Unit
	local origin = rootCFrame.Position + Vector3.new(0, config.HeightOffsetStuds, 0)
	local best: Hit? = nil
	for _, degrees in config.FanDegrees do
		local direction = CFrame.fromAxisAngle(Vector3.yAxis, math.rad(degrees)):VectorToWorldSpace(look)
		local hit = EnvironmentProbe.Cast(origin, direction * config.ReachStuds, exclude)
		if hit and EnvironmentProbe.IsWall(hit.Normal) and (best == nil or hit.Distance < best.Distance) then
			best = hit
		end
	end
	return best
end

-- What a hit surface LOOKS like: a part's own Color, or for Terrain the per-material color the caller
-- supplies (FXConstants.MovementDust.ColorByFloorMaterial on the client), else `fallback`.
function EnvironmentProbe.ColorOf(hit: Hit, colorByMaterial: { [Enum.Material]: Color3 }, fallback: Color3): Color3
	local instance = hit.Instance
	if instance:IsA("BasePart") and not instance:IsA("Terrain") then
		return instance.Color
	end
	return colorByMaterial[hit.Material] or fallback
end

return EnvironmentProbe
