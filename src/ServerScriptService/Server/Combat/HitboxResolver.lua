--!strict
--[[
	HitboxResolver.lua

	Owns: the swept melee hitbox pipeline -- scheduling a swing's windup/active/recovery timeline,
	sampling an oriented box (Workspace:GetPartBoundsInBox) at each attacker pose during the active
	window, sweeping between samples via CFrame:Lerp sub-steps so fast relative movement can't skip
	a target between two discrete samples, and deduping so a given target is only ever counted once
	per swing. Pure geometry and scheduling -- this module has no idea what a Player, damage,
	posture, or block/parry even is.

	The sampled pose is root-relative (AttackerRootPart.CFrame * Offset) by default, but a caller
	can optionally supply AttackerTrackedPart (SwingConfig) to have the box's POSITION follow a
	different part instead -- e.g. the attacker's own hand, for a punch whose reach a fixed
	root-relative offset can't accurately represent across every animation pose. The box's
	ORIENTATION always comes from AttackerRootPart regardless -- see AttackerTrackedPart's own
	header for why.

	Does not own: what counts as a legal target, arc/line-of-sight validation, or any damage/posture/
	block/parry resolution -- CombatSystem.lua owns all of that. Every overlapped Model this module
	finds is handed to the caller's `OnHit` callback (see SwingConfig) for that caller to accept or
	reject; this module only tracks *whether the caller already said yes* for dedup purposes. It also
	doesn't decide *which* attack definition to use (combo stage selection, Basic vs Heavy) -- it
	only ever runs the single Types.HitboxAttackDefinition it's handed.

	Driven entirely by CombatSystem.lua calling Update(deltaTime) once per Heartbeat -- this module
	does not connect its own RunService event or track boot order (no Init()), since it isn't a peer
	System per software-architecture.md, it's a narrow server-only helper for the one System that
	owns combat (performance-optimization.md's server-tick-discipline guidance is why CombatSystem
	drives this from its existing single Heartbeat connection rather than this module opening a
	second one).
]]

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)

local HitboxResolver = {}

-- Sub-sample count and per-query part cap live in Constants.Combat.Hitboxes.SweepSubsteps/
-- MaxPartsPerQuery -- were module-local constants here, moved per luau-coding-standards.md's "no
-- magic numbers in system logic" now that every other hitbox tunable lives in Constants.lua.

--
-- Studio-only debug visualization (Constants.Combat.DebugHitboxes). Off by default, gated a
-- second time on RunService:IsStudio() so flipping the constant true can never make hitboxes
-- visible in a live server -- see that constant's own comment in Constants.lua. Purely a rendered
-- Part per sampled pose; nothing here is read by, or can influence, the actual overlap query
-- above it in performSample. Cosmetics now live in Constants.Combat.Hitboxes.DebugPart, alongside
-- this table's own sibling tunables (SweepSubsteps/MaxPartsPerQuery) -- see that field's own header.
--

local DEBUG_PART_LIFETIME = Constants.Combat.Hitboxes.DebugPart.LifetimeSeconds
local DEBUG_PART_COLOR = Constants.Combat.Hitboxes.DebugPart.Color
local DEBUG_PART_TRANSPARENCY = Constants.Combat.Hitboxes.DebugPart.Transparency

local debugFolder: Folder? = nil

local function getDebugFolder(): Folder
	if debugFolder and debugFolder.Parent then
		return debugFolder
	end
	local folder = Instance.new("Folder")
	folder.Name = "HitboxDebug"
	folder.Parent = Workspace
	debugFolder = folder
	return folder
end

local function renderDebugHitbox(pose: CFrame, size: Vector3): ()
	if not Constants.Combat.DebugHitboxes or not RunService:IsStudio() then
		return
	end

	local part = Instance.new("Part")
	part.Name = "HitboxSample"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.ForceField
	part.Color = DEBUG_PART_COLOR
	part.Transparency = DEBUG_PART_TRANSPARENCY
	part.Size = size
	part.CFrame = pose
	part.Parent = getDebugFolder()

	Debris:AddItem(part, DEBUG_PART_LIFETIME)
end

export type SwingConfig = {
	-- The attacker's HumanoidRootPart, read fresh every sample -- the hitbox tracks wherever this
	-- part currently is/faces, it is not frozen at swing start. Still the FACING source even when
	-- AttackerTrackedPart below is supplied -- see that field's own header for why.
	AttackerRootPart: BasePart,
	-- Optional. When supplied (and still parented -- see performSample's own fallback), the hitbox's
	-- POSITION tracks this part instead of AttackerRootPart's -- for an attack that should follow
	-- the attacker's actual swinging hand rather than a fixed root-relative guess (a hand ends up
	-- meaningfully forward of the torso center during a lunge, which a root-relative Offset alone
	-- can't account for across every animation pose). The hitbox's ORIENTATION still comes from
	-- AttackerRootPart, never the hand's own raw rotation -- a hand's rotation swings through wild
	-- angles over the course of a punch animation, and inheriting that would spin/tumble the box
	-- through the swing instead of sweeping cleanly forward the way Size/Offset were tuned to
	-- assume. Every OTHER attack (the M1 Basic/Heavy string) leaves this nil and keeps the original
	-- root-relative behavior unchanged.
	AttackerTrackedPart: BasePart?,
	Definition: Types.HitboxAttackDefinition,
	-- Called fresh on every sample so the candidate roster (deaths, leaves, new lock-on) is always
	-- current. Returning the attacker's own Model is harmless (never matches itself) but the caller
	-- should exclude it anyway to keep the box's own query small.
	GetCandidates: () -> { Model },
	-- Checked before every sample; returning false ends the swing immediately (no further sampling,
	-- OnComplete still fires) -- e.g. the attacker died or respawned since the swing started.
	IsStillValid: () -> boolean,
	-- Called at most once per distinct Model per swing (this module's own dedup guarantee), for
	-- every Model whose parts overlap the box and hasn't already returned true from this callback
	-- this swing. Return true to mean "this counted as a landed hit" -- the model is then excluded
	-- from all future samples this swing. Return false to mean "overlapped, but didn't count" (e.g.
	-- failed an arc/line-of-sight check) -- the model remains eligible and may be re-offered on a
	-- later sample if it's still overlapping.
	OnHit: (target: Model) -> boolean,
	OnComplete: (() -> ())?,
}

type ActiveSwing = {
	attackerRootPart: BasePart,
	attackerTrackedPart: BasePart?,
	definition: Types.HitboxAttackDefinition,
	getCandidates: () -> { Model },
	isStillValid: () -> boolean,
	onHit: (Model) -> boolean,
	onComplete: (() -> ())?,

	elapsed: number,
	timeSinceLastSample: number,
	sampleCount: number,
	hasPreviousSample: boolean,
	previousCFrame: CFrame,
	hitModels: { [Model]: boolean },
	hitCount: number,
}

local activeSwings: { [number]: ActiveSwing } = {}
local nextSwingId = 0

local function performSample(swing: ActiveSwing): ()
	local definition = swing.definition
	local rootCFrame = swing.attackerRootPart.CFrame

	-- Tracked-part position, root-part facing -- see SwingConfig.AttackerTrackedPart's own header
	-- for why these are deliberately split rather than just using the tracked part's own full
	-- CFrame. Falls back to the root part's own position (i.e. the original, pre-tracking behavior)
	-- if no tracked part was supplied, or it's been destroyed/unparented since the swing started
	-- (e.g. a respawn mid-swing) -- never errors on a stale reference.
	local trackedPart = swing.attackerTrackedPart
	local trackedPosition = if trackedPart and trackedPart.Parent then trackedPart.Position else rootCFrame.Position
	local trackedCFrame = CFrame.new(trackedPosition) * (rootCFrame - rootCFrame.Position)

	local currentCFrame = trackedCFrame * definition.Offset

	-- Swept sub-poses between the previous and current sample (Constants.Combat.Hitboxes.
	-- SweepSubsteps); the very first sample of a swing has nothing to sweep from, so it's just the
	-- current pose.
	local poses: { CFrame }
	if swing.hasPreviousSample then
		poses = {}
		for step = 1, Constants.Combat.Hitboxes.SweepSubsteps do
			table.insert(
				poses,
				swing.previousCFrame:Lerp(currentCFrame, step / Constants.Combat.Hitboxes.SweepSubsteps)
			)
		end
	else
		poses = { currentCFrame }
	end

	-- Rendered (when DebugHitboxes is on) regardless of whether any candidate exists this sample --
	-- debug visualization is for verifying shape/reach/timing on its own, not only during a real
	-- exchange.
	for _, pose in ipairs(poses) do
		renderDebugHitbox(pose, definition.Size)
	end

	local candidates = swing.getCandidates()
	if #candidates > 0 then
		local overlapParams = OverlapParams.new()
		overlapParams.FilterType = Enum.RaycastFilterType.Include
		overlapParams.FilterDescendantsInstances = candidates
		overlapParams.MaxParts = Constants.Combat.Hitboxes.MaxPartsPerQuery

		-- Priority rank per candidate (1 = highest), so a capped swing (definition.MaxTargets)
		-- offers its remaining slots to the caller's ordered candidate list (locked-on target
		-- first -- see CombatSystem.lua's getSwingCandidates) instead of whatever order
		-- Workspace:GetPartBoundsInBox happens to return, which reflects its own spatial-query
		-- broadphase, not the FilterDescendantsInstances list's order -- a capped swing could
		-- otherwise land on an unlocked bystander instead of the locked target in a multi-target
		-- scrum even though the candidate list already put the locked target first.
		local priorityByModel: { [Model]: number } = {}
		for index, model in ipairs(candidates) do
			priorityByModel[model] = index
		end

		local maxTargets = definition.MaxTargets or math.huge

		-- Gather every distinct, not-yet-hit model this sample overlaps (across every sweep
		-- sub-pose) before applying the cap, so the cap is applied to a priority-sorted roster
		-- instead of incrementally to whatever order each pose's physics query happened to return.
		local overlapped: { Model } = {}
		local seenThisSample: { [Model]: boolean } = {}
		for _, pose in ipairs(poses) do
			local parts = Workspace:GetPartBoundsInBox(pose, definition.Size, overlapParams)
			for _, part in ipairs(parts) do
				local model = part:FindFirstAncestorOfClass("Model") :: Model?
				if not model or swing.hitModels[model] or seenThisSample[model] then
					continue
				end
				seenThisSample[model] = true
				table.insert(overlapped, model)
			end
		end

		table.sort(overlapped, function(a, b)
			return (priorityByModel[a] or math.huge) < (priorityByModel[b] or math.huge)
		end)

		for _, model in ipairs(overlapped) do
			if swing.hitCount >= maxTargets then
				break
			end
			if swing.onHit(model) then
				swing.hitModels[model] = true
				swing.hitCount += 1
			end
		end
	end

	swing.previousCFrame = currentCFrame
	swing.hasPreviousSample = true
end

-- Fire-and-forget: schedules a new swing tracked internally, advanced by Update(). No handle is
-- returned -- nothing in this codebase needs to cancel a swing mid-flight yet (IsStillValid already
-- covers "the attacker is no longer in a state where this swing should keep going"), and returning
-- one on spec would be exactly the kind of unused surface engineering-standards.md's "no stubs"
-- rule warns against.
function HitboxResolver.StartSwing(config: SwingConfig): ()
	nextSwingId += 1
	activeSwings[nextSwingId] = {
		attackerRootPart = config.AttackerRootPart,
		attackerTrackedPart = config.AttackerTrackedPart,
		definition = config.Definition,
		getCandidates = config.GetCandidates,
		isStillValid = config.IsStillValid,
		onHit = config.OnHit,
		onComplete = config.OnComplete,

		elapsed = 0,
		timeSinceLastSample = math.huge, -- forces an immediate sample on the first active-window tick
		sampleCount = 0,
		hasPreviousSample = false,
		previousCFrame = CFrame.identity,
		hitModels = {},
		hitCount = 0,
	}
end

-- Call once per Heartbeat from CombatSystem.lua. Advances every in-flight swing: ends it (and fires
-- OnComplete) once IsStillValid fails or its full windup+active+recovery timeline has elapsed;
-- otherwise samples the hitbox on a SampleRate cadence while inside the active window, up to
-- MaxSamplesPerSwing samples.
function HitboxResolver.Update(deltaTime: number): ()
	for id, swing in pairs(activeSwings) do
		if not swing.attackerRootPart.Parent or not swing.isStillValid() then
			activeSwings[id] = nil
			if swing.onComplete then
				swing.onComplete()
			end
			continue
		end

		swing.elapsed += deltaTime
		local definition = swing.definition
		local totalDuration = definition.WindupSeconds + definition.ActiveSeconds + definition.RecoverySeconds

		if swing.elapsed >= totalDuration then
			activeSwings[id] = nil
			if swing.onComplete then
				swing.onComplete()
			end
			continue
		end

		local activeWindowStart = definition.WindupSeconds
		local activeWindowEnd = activeWindowStart + definition.ActiveSeconds
		if swing.elapsed < activeWindowStart or swing.elapsed > activeWindowEnd then
			continue
		end

		if swing.sampleCount >= Constants.Combat.Hitboxes.MaxSamplesPerSwing then
			continue
		end

		swing.timeSinceLastSample += deltaTime
		if swing.timeSinceLastSample < Constants.Combat.Hitboxes.SampleRate then
			continue
		end

		swing.timeSinceLastSample = 0
		swing.sampleCount += 1
		performSample(swing)
	end
end

return HitboxResolver
