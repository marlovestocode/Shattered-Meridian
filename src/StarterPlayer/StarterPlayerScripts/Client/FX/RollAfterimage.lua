--!strict
--[[
	RollAfterimage.lua

	Owns: the roll's afterimage -- translucent, limb-for-limb copies of a rolling rig left behind across
	the server's evade window, and the single brighter copy stamped on a dodger when a swing is
	confirmed to have gone through them (Combat_Feedback "Evaded").

	WHY IT EXISTS. DefenseSystem.BeginEvade opens a real, server-authoritative evade window on every
	accepted roll (DefenseConstants.Evade: a short vulnerable startup, then the active window). Without a
	visible tell, that window is something the roller has to trust and the attacker cannot read at all --
	a swing that "should have hit" and did nothing reads as lag. A trail of ghosts spanning exactly that
	window (FXConstants.RollAfterimage's own timing notes) is the window, drawn: both players can see
	when the dodge was live and when it was not.

	POOLED, AND BOUNDED THREE WAYS (performance-optimization.md's effect budget):
	  * A ghost is a SET -- one Part per R6 limb (the game is R6-locked), built once by the pool factory
	    and reused. No Instance.new on a roll after the pool is warm; a roll past PoolMaxSize leaves
	    fewer ghosts rather than allocating more.
	  * Fading is one Heartbeat walk over the live ghosts writing Transparency, not a Tween per part --
	    six Tween objects per stamp would be allocation the pool exists to avoid.
	  * At most one pending schedule per character: a second roll replaces the first one's remaining
	    stamps rather than stacking with them.

	ANCHORED AND INERT. Every ghost part is Anchored, CanCollide/CanQuery/CanTouch false and CastShadow
	false, parented under a shared FXPool holder rather than the rig, so a ghost can never be hit, stood
	on, raycast by a parkour probe (see the "probes treat bodies as terrain" history) or destroyed with
	the character mid-fade.

	Does not own: WHEN a roll happens (the local transition reaches this through MovementVFX; a remote
	player's through RemoteMovementFX's ParkourState watch), whether a swing was evaded (the server --
	this only draws what Combat_Feedback said), or the dust (MovementVFX). Purely local presentation.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local FXConstants = require(ReplicatedStorage.Shared.FXConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local Trove = require(ReplicatedStorage.Shared.Trove)

local FXPool = require(script.Parent.FXPool)

local logger = Logger.scope("RollAfterimage")

local CONFIG = FXConstants.RollAfterimage

-- The R6 limbs a ghost copies. HumanoidRootPart is deliberately absent: it is invisible on the rig, so
-- a ghost of it would draw a box nobody ever sees on the real body.
local RIG_PARTS = { "Head", "Torso", "Left Arm", "Right Arm", "Left Leg", "Right Leg" }

local RollAfterimage = {}

type Ghost = {
	Model: Model,
	Parts: { [string]: Part },
}

type LiveGhost = {
	Ghost: Ghost,
	BornAt: number,
	FadeSeconds: number,
	StartTransparency: number,
}

type Schedule = {
	NextAt: number,
	Remaining: number,
}

local function getHolder(): Folder
	return FXPool.GetHolder("RollAfterimageHolder", function(): Instance
		return Workspace
	end)
end

local function makeGhost(): Ghost
	local model = Instance.new("Model")
	model.Name = "RollGhost"
	local parts: { [string]: Part } = {}
	for _, name in RIG_PARTS do
		local part = Instance.new("Part")
		part.Name = name
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Material = Enum.Material.Neon
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Transparency = 1
		part.Parent = model
		parts[name] = part
	end
	return { Model = model, Parts = parts }
end

local function resetGhost(ghost: Ghost): ()
	ghost.Model.Parent = nil
end

local pool = FXPool.New(makeGhost, resetGhost, CONFIG.PoolMaxSize)

local live: { LiveGhost } = {}
local schedules: { [Model]: Schedule } = {}

local started = false
local trove = Trove.New()

-- Copies `character`'s current pose into one pooled ghost. Returns false (having done nothing) when
-- the pool is at cap or the rig has no limbs to copy -- neither is an error.
local function stamp(character: Model, color: Color3, startTransparency: number, fadeSeconds: number): boolean
	local ghost = pool:Acquire()
	if not ghost then
		logger:debug("RollAfterimage pool at cap -- dropping a ghost")
		return false
	end

	local copied = 0
	for name, part in ghost.Parts do
		local source = character:FindFirstChild(name)
		if source and source:IsA("BasePart") and source.Transparency < 1 then
			part.Size = source.Size
			part.CFrame = source.CFrame
			part.Color = color
			part.Transparency = startTransparency
			copied += 1
		else
			part.Transparency = 1
		end
	end
	if copied == 0 then
		pool:Release(ghost)
		return false
	end

	ghost.Model.Parent = getHolder()
	table.insert(live, {
		Ghost = ghost,
		BornAt = os.clock(),
		FadeSeconds = math.max(fadeSeconds, 1e-3),
		StartTransparency = startTransparency,
	})
	return true
end

local function onHeartbeat(): ()
	local now = os.clock()

	for character, schedule in schedules do
		if character.Parent == nil then
			schedules[character] = nil
			continue
		end
		if now < schedule.NextAt then
			continue
		end
		stamp(character, CONFIG.Color, CONFIG.StartTransparency, CONFIG.FadeSeconds)
		schedule.Remaining -= 1
		if schedule.Remaining <= 0 then
			schedules[character] = nil
		else
			schedule.NextAt += CONFIG.IntervalSeconds
		end
	end

	-- Walked backwards so a finished ghost can be removed in place.
	for index = #live, 1, -1 do
		local entry = live[index]
		local alpha = (now - entry.BornAt) / entry.FadeSeconds
		if alpha >= 1 then
			table.remove(live, index)
			pool:Release(entry.Ghost)
			continue
		end
		local transparency = entry.StartTransparency + (1 - entry.StartTransparency) * alpha
		for _, part in entry.Ghost.Parts do
			if part.Transparency < 1 then
				part.Transparency = transparency
			end
		end
	end
end

-- The roll's trail of ghosts on `character`, timed to the server's evade window. Replaces any stamps
-- still pending from that character's previous roll.
function RollAfterimage.PlayRoll(character: Model): ()
	if not started then
		return
	end
	schedules[character] = {
		NextAt = os.clock() + CONFIG.StartDelaySeconds,
		Remaining = CONFIG.StampCount,
	}
end

-- The single brighter ghost for a confirmed evade, stamped now.
function RollAfterimage.FlashEvade(character: Model): ()
	if not started then
		return
	end
	stamp(character, CONFIG.EvadeFlashColor, CONFIG.EvadeFlashStartTransparency, CONFIG.EvadeFlashFadeSeconds)
end

-- Diagnostics and specs: ghosts currently drawn, and characters with stamps still to come.
function RollAfterimage.CountLive(): number
	return #live
end

function RollAfterimage.IsPending(character: Model): boolean
	return schedules[character] ~= nil
end

function RollAfterimage.Start(): ()
	if started then
		return
	end
	started = true
	trove:Connect(RunService.Heartbeat, onHeartbeat)
end

function RollAfterimage.Stop(): ()
	if not started then
		return
	end
	started = false
	trove:Clean()
	table.clear(schedules)
	for _, entry in live do
		pool:Release(entry.Ghost)
	end
	table.clear(live)
end

return RollAfterimage
