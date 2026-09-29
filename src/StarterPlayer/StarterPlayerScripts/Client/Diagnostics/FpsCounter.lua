--!strict
--[[
	FpsCounter.lua

	Owns: the frame-rate overlay -- a small corner readout of frames per second and the WORST single
	frame in the last window, with a second line splitting where frame time goes, toggled with
	Constants.Debug.FpsCounter.ToggleKeyCode (F3) -- plus log lines for frames that spike and for windows
	where the frame rate falls well below its recent best.

	WHY THE WORST FRAME, NOT JUST FPS. A hitch -- one frame that takes 100ms -- barely moves an average
	over half a second, and it is exactly what a player feels. The worst-frame number shows it; the spike
	log timestamps it.

	WHY THE BREAKDOWN. "The frame rate dropped" has four very different causes, and Roblox's Stats service
	reports each one separately:
	  * gpu     -- Stats.RenderGPUFrameTime: the graphics card drawing the frame (Highlights, particles,
	              transparency, lights, shadows).
	  * render  -- Stats.RenderCPUFrameTime: the CPU preparing the frame for the GPU (draw calls, instance
	              counts, UI layout).
	  * scripts -- Stats.HeartbeatTimeMs: Lua work on Heartbeat. IN STUDIO this is the same process as the
	              server, so server scripts land here too.
	  * physics -- Stats.PhysicsStepTimeMs: the physics step (constraints, contacts, moving assemblies).
	Each is the WORST sample seen in the window, the same way the frame number is. Whichever one grows when
	the frame rate drops is where to look -- so the "Frame rate dropped" log carries all four.

	Measured off RenderStepped's own delta: the time between two rendered frames on THIS client.

	Plain Instances rather than a Fusion screen, deliberately: this is a diagnostic that must keep
	working when the UI layer is the thing misbehaving, and it repaints twice a second.

	Does not own: fixing anything it measures.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)

local logger = Logger.scope("FpsCounter")

local Config = Constants.Debug.FpsCounter

local FpsCounter = {}

local started = false

local GOOD_COLOR = Color3.fromRGB(120, 220, 130)
local OK_COLOR = Color3.fromRGB(235, 200, 90)
local BAD_COLOR = Color3.fromRGB(235, 95, 85)
local DETAIL_COLOR = Color3.fromRGB(210, 210, 210)

-- The four Stats readings, in display order. `Seconds` marks the ones Roblox reports in seconds rather
-- than milliseconds; each is read through pcall because not every build exposes every property.
local SOURCES = {
	{ Label = "gpu", Property = "RenderGPUFrameTime", Seconds = true },
	{ Label = "render", Property = "RenderCPUFrameTime", Seconds = true },
	{ Label = "scripts", Property = "HeartbeatTimeMs", Seconds = false },
	{ Label = "physics", Property = "PhysicsStepTimeMs", Seconds = false },
}

local function readMs(source: { Property: string, Seconds: boolean }): number?
	local ok, value = pcall(function()
		return (Stats :: any)[source.Property]
	end)
	if not ok or typeof(value) ~= "number" then
		return nil
	end
	return if source.Seconds then value * 1000 else value
end

-- The server's numbers, as Server/Diagnostics/ServerFrameStats.lua publishes them. Same literals as
-- ServerFrameStats.Attributes; a mismatch just reads n/a.
local SERVER_ATTRIBUTES = {
	Fps = "ServerFrameStats_Fps",
	WorstFrameMs = "ServerFrameStats_WorstFrameMs",
	ScriptsMs = "ServerFrameStats_ScriptsMs",
	PhysicsMs = "ServerFrameStats_PhysicsMs",
}

local function formatServer(): string
	local fps = ReplicatedStorage:GetAttribute(SERVER_ATTRIBUTES.Fps)
	if typeof(fps) ~= "number" then
		return "server n/a"
	end
	local worst = ReplicatedStorage:GetAttribute(SERVER_ATTRIBUTES.WorstFrameMs)
	local scripts = ReplicatedStorage:GetAttribute(SERVER_ATTRIBUTES.ScriptsMs)
	local physics = ReplicatedStorage:GetAttribute(SERVER_ATTRIBUTES.PhysicsMs)
	return `server fps {fps} | worst {worst or "?"}ms | scripts {scripts or "?"} | physics {physics or "?"} ms`
end

local function buildGui(): (ScreenGui, TextLabel, TextLabel, TextLabel)
	local gui = Instance.new("ScreenGui")
	gui.Name = "FpsCounter"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	-- Above every game surface, so a full-screen panel cannot hide the number being measured.
	gui.DisplayOrder = 10000
	gui.Enabled = Config.VisibleByDefault

	local frame = Instance.new("Frame")
	frame.Name = "Readout"
	frame.AnchorPoint = Vector2.new(1, 0)
	frame.Position = UDim2.new(1, -8, 0, 44)
	frame.Size = UDim2.fromOffset(320, if Config.ServerStats then 58 else 40)
	frame.BackgroundColor3 = Color3.new(0, 0, 0)
	frame.BackgroundTransparency = 0.45
	frame.BorderSizePixel = 0
	frame.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = frame

	local function line(name: string, y: number, color: Color3, size: number): TextLabel
		local label = Instance.new("TextLabel")
		label.Name = name
		label.Position = UDim2.fromOffset(0, y)
		label.Size = UDim2.new(1, 0, 0, 20)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.Code
		label.TextSize = size
		label.TextColor3 = color
		label.TextXAlignment = Enum.TextXAlignment.Center
		label.Text = "--"
		label.Parent = frame
		return label
	end

	local server = line("Server", 37, DETAIL_COLOR, 12)
	server.Visible = Config.ServerStats
	return gui, line("Headline", 0, GOOD_COLOR, 14), line("Breakdown", 19, DETAIL_COLOR, 12), server
end

local function formatBreakdown(worst: { [string]: number? }): string
	local parts = {}
	for _, source in SOURCES do
		local value = worst[source.Label]
		table.insert(parts, if value then `{source.Label} {string.format("%.1f", value)}` else `{source.Label} n/a`)
	end
	return table.concat(parts, " | ") .. " ms"
end

function FpsCounter.Start(): ()
	if started or not Config.Enabled then
		return
	end
	started = true

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
	local gui, headline, breakdown, serverLine = buildGui()
	gui.Parent = playerGui

	local windowStart = os.clock()
	local frames = 0
	local worstFrame = 0
	local worst: { [string]: number? } = {}
	local lastSpikeLogAt = -math.huge
	local lastSlowLogAt = -math.huge
	-- The best window FPS seen recently, decayed slowly so a sustained change in scene (a busier area)
	-- re-bases it rather than reading as a permanent drop.
	local recentBestFps = 0

	RunService.RenderStepped:Connect(function(deltaTime: number)
		frames += 1
		if deltaTime > worstFrame then
			worstFrame = deltaTime
		end
		for _, source in SOURCES do
			local value = readMs(source)
			if value then
				local current = worst[source.Label]
				if current == nil or value > current then
					worst[source.Label] = value
				end
			end
		end

		local now = os.clock()
		-- Logged whether or not the overlay is visible: a hitch worth chasing is worth a line in the
		-- Output even with the readout hidden.
		local frameMs = deltaTime * 1000
		if frameMs >= Config.SpikeLogMs and now - lastSpikeLogAt >= Config.SpikeLogCooldownSeconds then
			lastSpikeLogAt = now
			logger:info("Frame spike", { ms = math.floor(frameMs + 0.5), breakdown = formatBreakdown(worst) })
		end

		local elapsed = now - windowStart
		if elapsed < Config.WindowSeconds then
			return
		end
		local fps = frames / elapsed

		recentBestFps = math.max(fps, recentBestFps * 0.995)
		if
			recentBestFps > 0
			and fps < recentBestFps * Config.SlowWindowFraction
			and now - lastSlowLogAt >= Config.SlowWindowLogCooldownSeconds
		then
			lastSlowLogAt = now
			logger:info("Frame rate dropped", {
				fps = math.floor(fps + 0.5),
				recentBest = math.floor(recentBestFps + 0.5),
				worstFrameMs = math.floor(worstFrame * 1000 + 0.5),
				breakdown = formatBreakdown(worst),
				server = if Config.ServerStats then formatServer() else nil,
			})
		end

		if gui.Enabled then
			headline.Text = `FPS {math.floor(fps + 0.5)} | worst {math.floor(worstFrame * 1000 + 0.5)}ms`
			headline.TextColor3 = if fps >= Config.GoodFps
				then GOOD_COLOR
				elseif fps >= Config.OkFps then OK_COLOR
				else BAD_COLOR
			breakdown.Text = formatBreakdown(worst)
			if Config.ServerStats then
				serverLine.Text = formatServer()
			end
		end
		windowStart = now
		frames = 0
		worstFrame = 0
		table.clear(worst)
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed or input.KeyCode ~= Config.ToggleKeyCode then
			return
		end
		gui.Enabled = not gui.Enabled
	end)

	logger:info("FpsCounter started", { toggleKey = Config.ToggleKeyCode.Name, visible = gui.Enabled })
end

return FpsCounter
