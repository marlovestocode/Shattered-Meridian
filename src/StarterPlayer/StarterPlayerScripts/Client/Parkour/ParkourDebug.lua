--!strict
--[[
	ParkourDebug.lua

	Owns: the development overlay for this framework -- visualized probes, and a live readout of state,
	velocity, direction, surface, angles, available actions and the REASON each unavailable action is
	unavailable.

	The reason column is the point of this whole file. The design named the exact failure it exists to
	fix: "this will make it much easier to debug situations where the player sees an obstacle but the
	system does not detect it correctly." Every refusal in the framework carries a stable string --
	ObstacleClassifier's classifications, every StateDefinition.CanEnter's second return value -- and
	this overlay prints them verbatim. "TooTallToMantle" or "SameWallLockout" answers the question;
	watching a character fail to vault does not.

	STUDIO-GATED. Start() does nothing outside Studio, and the toggle key is bound raw (F6, from
	ParkourConstants.Debug.ToggleKeyCode) rather than as a rebindable KeybindAction -- deliberately, so
	it never appears in the player-facing rebind list. This is the same "developer tooling is
	Studio-only" posture Constants.Debug.Logging takes, and the opposite of Constants.Debug.DevMenu's
	(which is whitelist-gated precisely because it needs to work in live servers). A movement overlay
	has no such need: movement is reproducible in Studio, which is where it gets tuned.

	SELF-LIMITING. The adorn pool is capped (ParkourConstants.Debug.MaxAdorns) and the readout refreshes
	on a timer rather than per frame, so the tool cannot become the performance problem it exists to
	diagnose -- a real risk for an overlay that draws a dozen rays every frame at 60Hz.

	Does not own: any probe (it reads EnvironmentProbe's own live result tables), any state decision
	(it reads StateMachine's availability query, which is contractually side-effect free), or anything
	that affects gameplay in any way.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)
local ParkourTagging = require(ReplicatedStorage.Shared.Parkour.ParkourTagging)
local Logger = require(ReplicatedStorage.Shared.Logger)

local EnvironmentProbe = require(script.Parent.EnvironmentProbe)
local StateMachine = require(script.Parent.StateMachine)

type ParkourContext = ParkourTypes.ParkourContext
type Machine = StateMachine.Machine

local logger = Logger.scope("ParkourDebug")

local DEBUG = ParkourConstants.Debug

local ParkourDebug = {}

local started = false
local enabled = DEBUG.StartEnabled
local lastReadoutAt = 0

local adornFolder: Folder? = nil
local adornPool: { Part } = {}
local adornsUsedThisFrame = 0

local screenGui: ScreenGui? = nil
local readoutLabel: TextLabel? = nil

--
-- Adorns
--

local function getAdornFolder(): Folder
	local existing = adornFolder
	if existing and existing.Parent then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "ParkourDebugAdorns"
	folder.Parent = Workspace
	adornFolder = folder
	return folder
end

-- Acquires a pooled adorn part, or nil once the cap is hit. Every adorn is CanCollide/CanQuery false,
-- which is what keeps EnvironmentProbe's own RespectCanCollide-filtered rays from hitting the overlay
-- that is drawing them -- an overlay that made the character vault over its own debug markers would
-- be worse than no overlay.
local function acquireAdorn(): Part?
	adornsUsedThisFrame += 1
	if adornsUsedThisFrame > DEBUG.MaxAdorns then
		return nil
	end
	local existing = adornPool[adornsUsedThisFrame]
	if existing and existing.Parent then
		existing.Transparency = 0.35
		return existing
	end
	local part = Instance.new("Part")
	part.Name = "ParkourDebugAdorn"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Transparency = 0.35
	part.Parent = getAdornFolder()
	adornPool[adornsUsedThisFrame] = part
	return part
end

local function drawSegment(from: Vector3, to: Vector3, color: Color3): ()
	local part = acquireAdorn()
	if not part then
		return
	end
	local delta = to - from
	local length = delta.Magnitude
	if length < 1e-3 then
		part.Transparency = 1
		return
	end
	part.Size = Vector3.new(DEBUG.RayThickness, DEBUG.RayThickness, length)
	part.CFrame = CFrame.lookAt(from + delta * 0.5, to)
	part.Color = color
end

local function drawPoint(position: Vector3, color: Color3): ()
	local part = acquireAdorn()
	if not part then
		return
	end
	part.Size = Vector3.one * DEBUG.PointSize
	part.CFrame = CFrame.new(position)
	part.Color = color
end

-- Hides every adorn the current frame did not use, rather than destroying it -- the pool is reused
-- across frames and the set of visible probes changes constantly as states come and go.
local function hideUnusedAdorns(): ()
	for index = adornsUsedThisFrame + 1, #adornPool do
		local part = adornPool[index]
		if part then
			part.Transparency = 1
		end
	end
end

--
-- Readout
--

local function ensureReadout(): TextLabel?
	local existing = readoutLabel
	if existing and existing.Parent then
		return existing
	end
	local localPlayer = Players.LocalPlayer
	local playerGui = localPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return nil
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "ParkourDebug"
	gui.ResetOnSpawn = false
	-- FALSE, not true. IgnoreGuiInset = true anchors the overlay to the raw top-left of the screen,
	-- which is where Roblox draws its OWN topbar (logo, menu, chat) -- so the first two lines of the
	-- readout rendered underneath it and could not be read at all. Those two lines are the title and
	-- the `state` line: the single most important thing the overlay exists to report was the one thing
	-- permanently hidden. Left like this it actively misleads, because the next legible mention of a
	-- state is the AVAILABLE ACTIONS list, which answers a completely different question (see the
	-- ACTIVE marker below). Respecting the inset places the whole readout below the topbar on every
	-- device without hardcoding its height.
	gui.IgnoreGuiInset = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = playerGui
	screenGui = gui

	local label = Instance.new("TextLabel")
	label.Name = "Readout"
	label.AnchorPoint = Vector2.new(0, 0)
	label.Position = UDim2.fromOffset(12, 12)
	-- Height grows with the content rather than being a fixed 520: the readout's length varies with how
	-- many probes hit and how many transitions are in the history, and a fixed box silently clipped the
	-- oldest transitions off the bottom -- the exact rows most useful for working out how the machine
	-- got where it is.
	label.AutomaticSize = Enum.AutomaticSize.Y
	label.Size = UDim2.fromOffset(430, 0)
	label.BackgroundColor3 = Color3.fromRGB(8, 8, 12)
	label.BackgroundTransparency = 0.25
	label.BorderSizePixel = 0
	label.Font = Enum.Font.Code
	label.TextSize = 13
	label.TextColor3 = Color3.fromRGB(225, 232, 240)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.Text = ""
	label.Parent = gui
	readoutLabel = label
	return label
end

local function formatVector(vector: Vector3): string
	return string.format("%.1f, %.1f, %.1f", vector.X, vector.Y, vector.Z)
end

local lines: { string } = {}

local function buildReadout(context: ParkourContext, machine: Machine): string
	table.clear(lines)

	-- Derived from the constant rather than written out, so retuning ToggleKeyCode can never leave the
	-- overlay advertising a key that no longer opens it.
	table.insert(lines, string.format("PARKOUR DEBUG  (%s to toggle)", DEBUG.ToggleKeyCode.Name))
	table.insert(
		lines,
		string.format(
			"state       %s   (prev %s, %.2fs)",
			context.CurrentStateId,
			context.PreviousStateId,
			context.StateElapsed
		)
	)
	table.insert(
		lines,
		string.format(
			"drive       %s",
			machine:GetCurrentDefinition() and (machine:GetCurrentDefinition() :: any).Drive or "?"
		)
	)
	table.insert(lines, string.format("momentum    %.1f    measured %.1f", context.Momentum, context.PlanarSpeed))
	table.insert(
		lines,
		string.format("velocity    %s  (vert %.1f)", formatVector(context.Velocity), context.VerticalVelocity)
	)
	table.insert(lines, string.format("direction   %s", formatVector(context.MoveDirection)))
	table.insert(
		lines,
		string.format("intent      %s   sprint=%s", formatVector(context.MoveIntent), tostring(context.SprintHeld))
	)
	table.insert(
		lines,
		string.format("rays used   %d / %d", EnvironmentProbe.GetLastRayCount(), ParkourConstants.Probe.MaxRaysPerFrame)
	)
	table.insert(lines, string.format("combat owns %s", tostring(context.CombatOwned)))
	table.insert(lines, "")

	local ground = context.Ground
	table.insert(
		lines,
		string.format(
			"ground      %s  dist %.2f  slope %.1fdeg  standable=%s",
			tostring(ground.Grounded),
			ground.Distance,
			ground.SlopeAngle,
			tostring(ground.Standable)
		)
	)
	table.insert(lines, string.format("surface     %s  friction x%.2f", ground.Material.Name, ground.FrictionScale))

	local obstacle = context.Obstacle
	if obstacle.Found then
		table.insert(
			lines,
			string.format(
				"obstacle    h %.2f  d %.2f  dist %.2f  land=%s stand=%s",
				obstacle.Height,
				obstacle.Depth,
				obstacle.Distance,
				tostring(obstacle.HasLandingSpace),
				tostring(obstacle.HasStandingSpace)
			)
		)
		table.insert(
			lines,
			string.format(
				"            vaultTag=%s mantleTag=%s  part=%s",
				tostring(obstacle.VaultAllowed),
				tostring(obstacle.MantleAllowed),
				if obstacle.Instance then obstacle.Instance.Name else "-"
			)
		)
	else
		table.insert(lines, "obstacle    none")
	end

	for label, probe in { L = context.WallLeft, R = context.WallRight } do
		if probe.Found then
			table.insert(
				lines,
				string.format(
					"wall %s      dist %.2f  tilt %.1fdeg  approach %.1fdeg  runnable=%s",
					label,
					probe.Distance,
					probe.TiltAngle,
					ParkourMath.ApproachAngle(context.MoveDirection, probe.Tangent),
					tostring(probe.WallRunAllowed)
				)
			)
		else
			table.insert(lines, string.format("wall %s      none", label))
		end
	end

	local ledge = context.Ledge
	if ledge.Found then
		table.insert(
			lines,
			string.format(
				"ledge       at %s  stand=%s  hang=%s",
				formatVector(ledge.EdgePosition),
				tostring(ledge.HasStandingSpace),
				tostring(ledge.HasHangSpace)
			)
		)
	else
		table.insert(lines, "ledge       none")
	end
	table.insert(lines, string.format("ceiling     clear=%s", tostring(context.CeilingClear)))
	table.insert(
		lines,
		string.format("chains      wallRun %d  wallJump %d", context.WallRunChain, context.WallJumpChain)
	)
	table.insert(lines, "")
	table.insert(lines, "AVAILABLE ACTIONS  (could this be ENTERED right now -- not what is running)")

	-- The active state gets ACTIVE rather than its CanEnter answer. EvaluateAvailability asks every
	-- registered state "could you be entered right now", and it asks that of the RUNNING state too --
	-- which routinely answers no for a perfectly good reason. A live slide reports
	-- "Sliding no NoSlideInput" the moment the buffered press expires (the hold is what continues it;
	-- the press is what starts it), and read on its own that line says the exact opposite of the truth.
	-- Costing a reader that misreading is worse than the line is worth, so the running state is labelled
	-- as what it is.
	local currentId = machine:GetCurrentId()
	for _, record in machine:EvaluateAvailability(context) do
		if record.Id == currentId then
			table.insert(lines, string.format("  %-14s ACTIVE", record.Id))
		else
			table.insert(
				lines,
				string.format(
					"  %-14s %s  %s",
					record.Id,
					if record.Available then "YES" else " no",
					record.Reason or ""
				)
			)
		end
	end

	table.insert(lines, "")
	table.insert(lines, "RECENT TRANSITIONS")
	local history = machine:GetHistory()
	for index = #history, 1, -1 do
		local entry = history[index]
		table.insert(lines, string.format("  %s -> %s  (%s)", entry.From, entry.To, entry.Route))
	end

	return table.concat(lines, "\n")
end

--
-- Public API
--

-- Draws this frame's probes and refreshes the readout on its own timer. Called by ParkourController
-- at the end of every movement frame; returns immediately (and cheaply) when the overlay is off,
-- which is its permanent state for every player who is not a developer with Studio open.
function ParkourDebug.Update(context: ParkourContext, machine: Machine): ()
	if not enabled then
		return
	end

	adornsUsedThisFrame = 0
	local rootPart = context.RootPart
	local origin = rootPart.Position
	local footOffset = EnvironmentProbe.GetFootOffset()
	local footPosition = origin - Vector3.new(0, footOffset, 0)

	local ground, obstacle, wallLeft, wallRight, ledge = EnvironmentProbe.GetResults()

	drawSegment(
		origin,
		origin - Vector3.new(0, footOffset + ParkourConstants.Slope.GroundProbeDistance, 0),
		if ground.Grounded then DEBUG.HitColor else DEBUG.MissColor
	)
	if ground.Grounded then
		drawPoint(footPosition - Vector3.new(0, ground.Distance, 0), DEBUG.HitColor)
	end

	local travel = ParkourMath.SafeUnit(ParkourMath.Flatten(context.MoveDirection), rootPart.CFrame.LookVector)
	drawSegment(
		footPosition + Vector3.new(0, ParkourConstants.Obstacle.StepMaxHeight * 0.5, 0),
		footPosition
			+ Vector3.new(0, ParkourConstants.Obstacle.StepMaxHeight * 0.5, 0)
			+ travel * ParkourConstants.Obstacle.ProbeDistance,
		if obstacle.Found then DEBUG.HitColor else DEBUG.MissColor
	)
	if obstacle.Found then
		drawPoint(obstacle.TopPosition, if obstacle.HasLandingSpace then DEBUG.HitColor else DEBUG.BlockedColor)
	end

	local right = ParkourMath.SafeUnit(ParkourMath.Flatten(rootPart.CFrame.RightVector), Vector3.new(1, 0, 0))
	drawSegment(
		origin,
		origin - right * ParkourConstants.WallRun.ProbeDistance,
		if wallLeft.Found then DEBUG.HitColor else DEBUG.MissColor
	)
	drawSegment(
		origin,
		origin + right * ParkourConstants.WallRun.ProbeDistance,
		if wallRight.Found then DEBUG.HitColor else DEBUG.MissColor
	)
	if wallLeft.Found then
		drawSegment(
			origin - right * wallLeft.Distance,
			origin - right * wallLeft.Distance + wallLeft.Tangent * 3,
			DEBUG.BlockedColor
		)
	end
	if wallRight.Found then
		drawSegment(
			origin + right * wallRight.Distance,
			origin + right * wallRight.Distance + wallRight.Tangent * 3,
			DEBUG.BlockedColor
		)
	end

	if ledge.Found then
		drawPoint(ledge.EdgePosition, if ledge.HasStandingSpace then DEBUG.HitColor else DEBUG.BlockedColor)
	end

	hideUnusedAdorns()

	if (context.Now - lastReadoutAt) < DEBUG.ReadoutIntervalSeconds then
		return
	end
	lastReadoutAt = context.Now
	local label = ensureReadout()
	if label then
		label.Text = buildReadout(context, machine)
	end
end

function ParkourDebug.IsEnabled(): boolean
	return enabled
end

-- Public toggle, so a future admin tool could expose the overlay without this module having to grow
-- its own authorization path.
function ParkourDebug.SetEnabled(nextEnabled: boolean): ()
	enabled = nextEnabled
	logger:info("Parkour debug overlay toggled", { enabled = enabled })
	if enabled then
		-- A retagged world should be picked up immediately when a developer deliberately opens the
		-- overlay, rather than waiting out ParkourTagging's own TTL -- opening the overlay is almost
		-- always the moment after changing a tag.
		ParkourTagging.ClearCache()
		return
	end
	for _, part in adornPool do
		part.Transparency = 1
	end
	local gui = screenGui
	if gui then
		gui:Destroy()
		screenGui = nil
		readoutLabel = nil
	end
end

-- Binds the toggle key. Studio only -- see the file header. Idempotent.
function ParkourDebug.Start(): ()
	if started then
		return
	end
	started = true
	if not RunService:IsStudio() then
		return
	end
	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if input.KeyCode == DEBUG.ToggleKeyCode then
			ParkourDebug.SetEnabled(not enabled)
		end
	end)
	logger:info("Parkour debug available", { toggleKey = DEBUG.ToggleKeyCode.Name })
end

return ParkourDebug
