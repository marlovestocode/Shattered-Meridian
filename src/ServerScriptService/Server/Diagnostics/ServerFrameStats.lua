--!strict
--[[
	ServerFrameStats.lua

	Owns: publishing the SERVER's own frame numbers for the client frame-rate overlay
	(Client/Diagnostics/FpsCounter.lua) -- server frames per second, its worst frame, and the worst
	script (Stats.HeartbeatTimeMs) and physics (Stats.PhysicsStepTimeMs) time -- as Attributes on
	ReplicatedStorage, repainted every Constants.Debug.FpsCounter.WindowSeconds.

	WHY IT EXISTS. A client's own Stats only see the client. In Studio's ordinary Play mode the server
	runs in the SAME PROCESS as the client, so everything the server does -- the training bot's brain,
	the hitbox engine's substeps, every combat system's Heartbeat -- costs the player frames without
	appearing in any client-side number. A frame that takes 19ms while the client's own gpu/render/
	scripts/physics add up to 10ms is missing exactly this. Published here, the overlay can show it.

	Not a System and not in the boot manifest: it owns no remote, no gameplay state and nothing any
	other module reads. Main.server.lua starts it directly.

	Does not own: fixing anything it measures, or any per-system breakdown of the server's script time
	(the MicroProfiler has that -- Ctrl+F6 in Studio shows server labels alongside the client's).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")

local Constants = require(ReplicatedStorage.Shared.Constants)

local Config = Constants.Debug.FpsCounter

local ServerFrameStats = {}

-- The Attribute names the client overlay reads. Kept here and in FpsCounter by the same literal on
-- purpose -- a diagnostic that fails soft (the line just reads n/a) when the two ever disagree.
ServerFrameStats.Attributes = table.freeze({
	Fps = "ServerFrameStats_Fps",
	WorstFrameMs = "ServerFrameStats_WorstFrameMs",
	ScriptsMs = "ServerFrameStats_ScriptsMs",
	PhysicsMs = "ServerFrameStats_PhysicsMs",
})

local started = false

local function readNumber(property: string): number?
	local ok, value = pcall(function()
		return (Stats :: any)[property]
	end)
	if not ok or typeof(value) ~= "number" then
		return nil
	end
	return value
end

function ServerFrameStats.Start(): ()
	if started or not Config.Enabled or not Config.ServerStats then
		return
	end
	started = true

	local names = ServerFrameStats.Attributes
	local windowStart = os.clock()
	local frames = 0
	local worstFrame = 0
	local worstScripts = 0
	local worstPhysics = 0

	RunService.Heartbeat:Connect(function(deltaTime: number)
		frames += 1
		if deltaTime > worstFrame then
			worstFrame = deltaTime
		end
		local scripts = readNumber("HeartbeatTimeMs")
		if scripts and scripts > worstScripts then
			worstScripts = scripts
		end
		local physics = readNumber("PhysicsStepTimeMs")
		if physics and physics > worstPhysics then
			worstPhysics = physics
		end

		local now = os.clock()
		local elapsed = now - windowStart
		if elapsed < Config.WindowSeconds then
			return
		end
		ReplicatedStorage:SetAttribute(names.Fps, math.floor(frames / elapsed + 0.5))
		ReplicatedStorage:SetAttribute(names.WorstFrameMs, math.floor(worstFrame * 1000 + 0.5))
		ReplicatedStorage:SetAttribute(names.ScriptsMs, math.floor(worstScripts * 10 + 0.5) / 10)
		ReplicatedStorage:SetAttribute(names.PhysicsMs, math.floor(worstPhysics * 10 + 0.5) / 10)
		windowStart = now
		frames = 0
		worstFrame = 0
		worstScripts = 0
		worstPhysics = 0
	end)
end

return ServerFrameStats
