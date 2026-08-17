--!strict
--[[
	ParkourDebug.lua

	Owns: the development overlay for this framework -- visualized probes, and a live readout of state,
	velocity, direction, surface, angles, available actions, the REASON each unavailable action is
	unavailable, and (new) what the shimmy, the ledge-to-ledge leap and the wall-run corner turn are
	doing on the current frame.

	THE REASON COLUMN IS THE POINT OF THIS WHOLE FILE. The design named the exact failure it exists to
	fix: "this will make it much easier to debug situations where the player sees an obstacle but the
	system does not detect it correctly." Every refusal in the framework carries a stable string --
	ObstacleClassifier's classifications, every StateDefinition.CanEnter's second return value -- and
	this overlay prints them verbatim. "TooTallToMantle" or "SameWallLockout" answers the question;
	watching a character fail to vault does not.

	REBUILT AS A REAL PANEL (2026-08-15), not a monospace text blob. The prior version was one giant
	TextLabel string, rebuilt from scratch every ReadoutIntervalSeconds and printed as ~40 lines of
	Code-font text with no grouping, no color and no hierarchy -- readable if you already knew what you
	were looking for, and a wall of noise if you didn't. This version is built from Client/UI's own
	component library (Panel/Section/Label/Divider, Tokens-driven) -- the same primitives every other
	developer- and player-facing surface in this codebase uses -- so it gets real section grouping, a
	color language that means something (green = working, amber = attempted-but-not-committed, muted =
	inactive), and a scrollable body that never runs off the bottom of a smaller viewport. See
	docs/ui-ux-philosophy.md for the palette/type/shape rules this borrows rather than reinvents.

	FUSION, BUT OUTSIDE UI.Mount()'s TREE. This overlay is dev-only, toggled per-session with F6, and
	has no business being part of the always-mounted player-facing UI tree -- so it follows the same
	carve-out Client/Intro/IntroClient.lua's own header documents for Onboarding: its own
	Fusion.scoped(Fusion) root, created on enable and torn down with scope:doCleanup() on disable,
	never alive at the same time as anything else's scope because nothing else needs to know it exists.

	ROWS ARE PRE-ALLOCATED, NOT REBUILT PER REFRESH. Every section has a FIXED shape -- STATE and
	SURFACES are always the same number of lines, and AVAILABLE ACTIONS/RECENT TRANSITIONS are sized
	ONCE, on the first Update() call after the panel mounts, from the real registered-state count and
	ParkourConstants.Debug.TransitionHistory. Refreshing therefore means pushing new strings into
	existing Fusion Values (row.Text:set(...), row.Color:set(...)), not destroying and recreating ~40
	Instances ten times a second -- the same "reactive leaf values on a fixed tree" shape every other
	Fusion component in this codebase already uses for a fast-changing readout.

	LIVE MECHANICS is the new section: the shimmy, the ledge-to-ledge leap and the wall-run corner turn
	are all DECISIONS a single state's Update makes every frame, most of which produce no state
	transition to show in RECENT TRANSITIONS -- "why didn't the shimmy move" had no answer anywhere in
	the overlay before this. Backed by three ParkourContext fields (DebugShimmy/DebugLedgeLeap/
	DebugWallRunPivot) the writing states refresh every frame they run -- see that type's own header.

	STUDIO OR WHITELISTED ADMIN. The toggle key is bound raw (F6, from
	ParkourConstants.Debug.ToggleKeyCode) rather than as a rebindable KeybindAction -- deliberately, so
	it never appears in the player-facing rebind list.

	This used to be Studio-ONLY, on the reasoning that movement is reproducible in Studio and so a
	movement overlay never needs to run live. That turned out to be wrong in the way these arguments
	usually are: the bugs that matter (a grab that will not fire against real geometry, a wall-jump
	that falls short, another player's body being treated as terrain) are found while actually playing
	the game with other people in it, and Studio is exactly where they are not. So it now follows
	Constants.Debug.DevMenu's whitelist-gated posture instead -- ParkourDebug.SetAuthorized, driven by
	the same server round-trip that gates the dev menu. Studio access is unchanged and unconditional.

	Granting it is safe to decide client-side because this overlay is strictly READ-ONLY -- see
	SetAuthorized's own header for the full argument.

	SELF-LIMITING. The adorn pool is capped (ParkourConstants.Debug.MaxAdorns) and the readout refreshes
	on a timer rather than per frame, so the tool cannot become the performance problem it exists to
	diagnose -- a real risk for an overlay that draws a dozen rays every frame at 60Hz.

	Does not own: any probe (it reads EnvironmentProbe's own live result tables), any state decision
	(it reads StateMachine's availability query, which is contractually side-effect free), the design
	tokens it renders through (Client/UI/Tokens.lua), or anything that affects gameplay in any way.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local ParkourMath = require(ReplicatedStorage.Shared.Parkour.ParkourMath)
local ParkourTypes = require(ReplicatedStorage.Shared.Parkour.ParkourTypes)
local ParkourTagging = require(ReplicatedStorage.Shared.Parkour.ParkourTagging)
local Logger = require(ReplicatedStorage.Shared.Logger)

local EnvironmentProbe = require(script.Parent.EnvironmentProbe)
local StateMachine = require(script.Parent.StateMachine)

local Tokens = require(script.Parent.Parent.UI.Tokens)
local Panel = require(script.Parent.Parent.UI.Components.Panel)
local Label = require(script.Parent.Parent.UI.Components.Label)
local Section = require(script.Parent.Parent.UI.Components.Section)
local TrackedLabel = require(script.Parent.Parent.UI.Components.TrackedLabel)

local Children = Fusion.Children

type ParkourContext = ParkourTypes.ParkourContext
type Machine = StateMachine.Machine
type Scope = Fusion.Scope<typeof(Fusion)>

local logger = Logger.scope("ParkourDebug")

local DEBUG = ParkourConstants.Debug

local ParkourDebug = {}

local started = false
local enabled = DEBUG.StartEnabled
local lastReadoutAt = 0

--
-- Adorns -- UNCHANGED from the prior version. These draw directly into Workspace and have nothing to
-- do with the readout's own presentation; the "much better design" ask is about the thing a developer
-- READS, not the colored line segments already doing their job in the 3D view.
--

local adornFolder: Folder? = nil
local adornPool: { Part } = {}
local adornsUsedThisFrame = 0

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
-- The panel
--

local function formatVector(vector: Vector3): string
	return string.format("%.1f, %.1f, %.1f", vector.X, vector.Y, vector.Z)
end

-- One reactive line of the readout: a mono-scale Label whose text and color are pushed from outside
-- (Update, below) rather than recomputed reactively -- the same imperative-push-into-a-Fusion-Value
-- shape every other fast-changing readout in this codebase uses (e.g. TierBadge's meter fill), because
-- the SOURCE of truth here is a plain-old-Lua context table refreshed on a timer, not a Fusion
-- Computed graph.
type Row = {
	Instance: TextLabel,
	Text: Fusion.Value<string>,
	Color: Fusion.Value<Color3>,
}

local function makeRow(scope: Scope, order: number): Row
	local text = scope:Value("")
	local color: Fusion.Value<Color3> = scope:Value(Tokens.Color.TextPrimary)
	-- No Size passed, deliberately: Label.lua's own AutomaticSize logic (see its header) only auto-
	-- sizes HEIGHT when a Size is given (AutomaticSize.None, i.e. a fixed-at-zero row, since these are
	-- single-line and never call AutoHeight either) -- omitting Size entirely is what gets
	-- AutomaticSize.XY instead, auto-fitting both axes to the text. A row shrink-wrapping to its own
	-- text width is harmless here: every row sits inside a vertical UIListLayout with nothing anchored
	-- to its far edge, and the mono font's own internal %-14s-style padding is what keeps the COLUMNS
	-- lined up, not the container width.
	local instance = Label(scope, {
		Text = text,
		Scale = "Numeral",
		Color = color,
		LayoutOrder = order,
	})
	return { Instance = instance, Text = text, Color = color }
end

local function setRow(row: Row, text: string, color: Color3): ()
	row.Text:set(text)
	row.Color:set(color)
end

-- Fixed section sizes, known without a live context -- see this file's header on why AVAILABLE
-- ACTIONS/RECENT TRANSITIONS are the two sections that CANNOT be sized until the first real frame.
local STATE_ROW_COUNT = 8
local SURFACE_ROW_COUNT = 9
local MECHANICS_ROW_COUNT = 3

type Handles = {
	Scope: Scope,
	StateRows: { Row },
	SurfaceRows: { Row },
	MechanicsRows: { Row },
	-- Built once, on the first Update() call after mounting -- see BuildDynamicSections below.
	ActionRows: { Row },
	TransitionRows: { Row },
	ActionsBody: Instance,
	TransitionsBody: Instance,
	DynamicSectionsBuilt: boolean,
}

local handles: Handles? = nil

-- Builds the fixed-shape shell: header, and the three sections whose row count never depends on live
-- data (STATE/SURFACES/LIVE MECHANICS). AVAILABLE ACTIONS and RECENT TRANSITIONS are mounted as EMPTY
-- sections here and populated by buildDynamicSections below, the first time real data exists to size
-- them from.
local function mountPanel(): Handles?
	local localPlayer = Players.LocalPlayer
	local playerGui = localPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return nil
	end

	local scope = Fusion.scoped(Fusion)

	local stateRows: { Row } = {}
	for order = 1, STATE_ROW_COUNT do
		table.insert(stateRows, makeRow(scope, order))
	end
	local surfaceRows: { Row } = {}
	for order = 1, SURFACE_ROW_COUNT do
		table.insert(surfaceRows, makeRow(scope, order))
	end
	local mechanicsRows: { Row } = {}
	for order = 1, MECHANICS_ROW_COUNT do
		table.insert(mechanicsRows, makeRow(scope, order))
	end

	local actionsBody = scope:New "Frame" {
		Name = "ActionsBody",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 1,

		[Children] = scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Vertical,
			Padding = UDim.new(0, 2),
			SortOrder = Enum.SortOrder.LayoutOrder,
		},
	}
	local transitionsBody = scope:New "Frame" {
		Name = "TransitionsBody",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 1,

		[Children] = scope:New "UIListLayout" {
			FillDirection = Enum.FillDirection.Vertical,
			Padding = UDim.new(0, 2),
			SortOrder = Enum.SortOrder.LayoutOrder,
		},
	}

	-- Derived from the constant rather than written out, so retuning ToggleKeyCode can never leave the
	-- overlay advertising a key that no longer opens it.
	local headerTitle = TrackedLabel(scope, {
		Text = "PARKOUR DEBUG",
		Scale = "Action",
		Color = Tokens.Color.AccentPrimaryBright,
	})
	local headerSubtitle = Label(scope, {
		Text = string.format("%s to toggle -- read-only, affects nothing", DEBUG.ToggleKeyCode.Name),
		Scale = "Detail",
		Color = Tokens.Color.TextSecondary,
	})

	local body = scope:New "ScrollingFrame" {
		Name = "Body",
		Size = UDim2.new(1, 0, 1, -44),
		Position = UDim2.fromOffset(0, 44),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = Tokens.Color.AccentPrimary,
		ScrollBarImageTransparency = 0.4,
		CanvasSize = UDim2.fromOffset(0, 0),
		-- The PROPERTY is named AutomaticCanvasSize; its VALUE type is Enum.AutomaticSize (the same
		-- enum GuiObject.AutomaticSize itself uses) -- there is no separate Enum.AutomaticCanvasSize.
		AutomaticCanvasSize = Enum.AutomaticSize.Y,

		[Children] = {
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				Padding = UDim.new(0, Tokens.Space.S),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			Section(scope, "State", 1, {
				stateRows[1].Instance,
				stateRows[2].Instance,
				stateRows[3].Instance,
				stateRows[4].Instance,
				stateRows[5].Instance,
				stateRows[6].Instance,
				stateRows[7].Instance,
				stateRows[8].Instance,
			}),
			Section(scope, "Surfaces", 2, {
				surfaceRows[1].Instance,
				surfaceRows[2].Instance,
				surfaceRows[3].Instance,
				surfaceRows[4].Instance,
				surfaceRows[5].Instance,
				surfaceRows[6].Instance,
				surfaceRows[7].Instance,
				surfaceRows[8].Instance,
				surfaceRows[9].Instance,
			}),
			Section(
				scope,
				"Live Mechanics",
				3,
				{ mechanicsRows[1].Instance, mechanicsRows[2].Instance, mechanicsRows[3].Instance },
				"The shimmy, the ledge-to-ledge leap and the wall-run corner turn -- decisions made every frame with no state transition to show elsewhere.",
				nil,
				true -- emphasis: this is the section this whole redesign exists to add
			),
			Section(
				scope,
				"Available Actions",
				4,
				{ actionsBody },
				"Could this be ENTERED right now -- not what is running."
			),
			Section(scope, "Recent Transitions", 5, { transitionsBody }),
		},
	}

	-- No local kept for this: nothing after this point needs to reach back into the ScreenGui itself
	-- (teardown goes through scope:doCleanup(), not an explicit :Destroy() on any one Instance).
	scope:New "ScreenGui" {
		Name = "ParkourDebug",
		ResetOnSpawn = false,
		-- FALSE, not true -- see this file's prior header note on why IgnoreGuiInset=true hid the two
		-- most important lines of the readout underneath Roblox's own topbar. Unchanged by the redesign.
		IgnoreGuiInset = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = playerGui,

		[Children] = Panel(scope, {
			Name = "Root",
			Position = UDim2.fromOffset(12, 12),
			-- Fixed width, height relative to the viewport minus a margin -- adapts to any screen size
			-- rather than a hardcoded pixel height clipping on a smaller display, and the internal
			-- ScrollingFrame is what makes clipping harmless even so: nothing is ever unreachable, only
			-- scrolled.
			Size = UDim2.new(0, 460, 1, -24),
			CornerAccent = true,

			Children = {
				scope:New "Frame" {
					Name = "Header",
					Size = UDim2.new(1, 0, 0, 40),
					BackgroundTransparency = 1,

					[Children] = {
						scope:New "UIListLayout" {
							FillDirection = Enum.FillDirection.Vertical,
							Padding = UDim.new(0, 2),
							SortOrder = Enum.SortOrder.LayoutOrder,
						},
						headerTitle,
						headerSubtitle,
					},
				},
				body,
			},
		}),
	}

	return {
		Scope = scope,
		StateRows = stateRows,
		SurfaceRows = surfaceRows,
		MechanicsRows = mechanicsRows,
		ActionRows = {},
		TransitionRows = {},
		ActionsBody = actionsBody,
		TransitionsBody = transitionsBody,
		DynamicSectionsBuilt = false,
	} :: any
end

-- Builds AVAILABLE ACTIONS and RECENT TRANSITIONS once real data exists to size them from -- see
-- mountPanel's own header for why these two can't be built up front like every other section.
local function buildDynamicSections(current: Handles, context: ParkourContext, machine: Machine): ()
	local scope = current.Scope
	local availability = machine:EvaluateAvailability(context)

	local actionRows: { Row } = {}
	for order = 1, #availability do
		local row = makeRow(scope, order)
		row.Instance.Parent = current.ActionsBody
		table.insert(actionRows, row)
	end
	current.ActionRows = actionRows

	local transitionRows: { Row } = {}
	for order = 1, DEBUG.TransitionHistory do
		local row = makeRow(scope, order)
		row.Instance.Parent = current.TransitionsBody
		table.insert(transitionRows, row)
	end
	current.TransitionRows = transitionRows

	current.DynamicSectionsBuilt = true
end

--
-- Color language for the readout. Three tiers, matching docs/ui-ux-philosophy.md's own instruction
-- that color communicate information instantly rather than decoratively:
--   Positive  -- this is working / found / available / just succeeded.
--   Warning   -- attempted and not (yet) satisfied -- not an error, just "nothing happened this frame."
--   TextSecondary / TextDisabled -- inactive, not found, or not currently relevant.
--

local function foundColor(found: boolean): Color3
	return if found then Tokens.Color.Positive else Tokens.Color.TextSecondary
end

local function shimmyColor(outcome: string?): Color3
	if outcome == "Straight" or outcome == "Corner" then
		return Tokens.Color.Positive
	elseif outcome == "Refused" then
		return Tokens.Color.Warning
	end
	return Tokens.Color.TextSecondary
end

local function leapColor(outcome: string?): Color3
	if outcome == "Launched" then
		return Tokens.Color.Positive
	elseif outcome == "NoTarget" or outcome == "Unreachable" or outcome == "NoIntent" then
		return Tokens.Color.Warning
	end
	return Tokens.Color.TextSecondary
end

local function pivotColor(outcome: string?): Color3
	if outcome == "Pivoted" then
		return Tokens.Color.Positive
	end
	return Tokens.Color.TextSecondary
end

local function refreshReadout(context: ParkourContext, machine: Machine): ()
	local current = handles
	if not current then
		return
	end
	if not current.DynamicSectionsBuilt then
		buildDynamicSections(current, context, machine)
	end

	local state = current.StateRows
	setRow(
		state[1],
		string.format(
			"state       %s   (prev %s, %.2fs)",
			context.CurrentStateId,
			context.PreviousStateId,
			context.StateElapsed
		),
		Tokens.Color.AccentPrimaryBright
	)
	local definition = machine:GetCurrentDefinition()
	setRow(
		state[2],
		string.format("drive       %s", if definition then definition.Drive else "?"),
		Tokens.Color.TextPrimary
	)
	setRow(
		state[3],
		string.format("momentum    %.1f    measured %.1f", context.Momentum, context.PlanarSpeed),
		Tokens.Color.TextPrimary
	)
	setRow(
		state[4],
		string.format("velocity    %s  (vert %.1f)", formatVector(context.Velocity), context.VerticalVelocity),
		Tokens.Color.TextPrimary
	)
	setRow(state[5], string.format("direction   %s", formatVector(context.MoveDirection)), Tokens.Color.TextPrimary)
	setRow(
		state[6],
		string.format(
			"intent      %s   sprint=%s stage=%d",
			formatVector(context.MoveIntent),
			tostring(context.SprintHeld),
			context.SprintStage
		),
		Tokens.Color.TextPrimary
	)
	setRow(
		state[7],
		string.format("rays used   %d / %d", EnvironmentProbe.GetLastRayCount(), ParkourConstants.Probe.MaxRaysPerFrame),
		Tokens.Color.TextSecondary
	)
	setRow(
		state[8],
		string.format("combat owns %s", tostring(context.CombatOwned)),
		if context.CombatOwned then Tokens.Color.Warning else Tokens.Color.TextSecondary
	)

	local surface = current.SurfaceRows
	local ground = context.Ground
	setRow(
		surface[1],
		string.format(
			"ground      %s  dist %.2f  slope %.1fdeg  standable=%s",
			tostring(ground.Grounded),
			ground.Distance,
			ground.SlopeAngle,
			tostring(ground.Standable)
		),
		foundColor(ground.Grounded)
	)
	setRow(
		surface[2],
		string.format("surface     %s  friction x%.2f", ground.Material.Name, ground.FrictionScale),
		Tokens.Color.TextSecondary
	)

	local obstacle = context.Obstacle
	if obstacle.Found then
		setRow(
			surface[3],
			string.format(
				"obstacle    h %.2f  d %.2f  dist %.2f  land=%s stand=%s",
				obstacle.Height,
				obstacle.Depth,
				obstacle.Distance,
				tostring(obstacle.HasLandingSpace),
				tostring(obstacle.HasStandingSpace)
			),
			Tokens.Color.Positive
		)
		setRow(
			surface[4],
			string.format(
				"            vaultTag=%s mantleTag=%s  part=%s",
				tostring(obstacle.VaultAllowed),
				tostring(obstacle.MantleAllowed),
				if obstacle.Instance then obstacle.Instance.Name else "-"
			),
			Tokens.Color.TextSecondary
		)
	else
		setRow(surface[3], "obstacle    none", Tokens.Color.TextSecondary)
		setRow(surface[4], "", Tokens.Color.TextSecondary)
	end

	local function setWallRow(row: Row, label: string, probe: ParkourTypes.WallProbe): ()
		if probe.Found then
			setRow(
				row,
				string.format(
					"wall %s      dist %.2f  tilt %.1fdeg  approach %.1fdeg  runnable=%s",
					label,
					probe.Distance,
					probe.TiltAngle,
					ParkourMath.ApproachAngle(context.MoveDirection, probe.Tangent),
					tostring(probe.WallRunAllowed)
				),
				foundColor(probe.WallRunAllowed)
			)
		else
			setRow(row, string.format("wall %s      none", label), Tokens.Color.TextSecondary)
		end
	end
	setWallRow(surface[5], "L", context.WallLeft)
	setWallRow(surface[6], "R", context.WallRight)

	local ledge = context.Ledge
	if ledge.Found then
		setRow(
			surface[7],
			string.format(
				"ledge       at %s  stand=%s  hang=%s",
				formatVector(ledge.EdgePosition),
				tostring(ledge.HasStandingSpace),
				tostring(ledge.HasHangSpace)
			),
			Tokens.Color.Positive
		)
	elseif not ledge.Allowed then
		-- The refusal EnvironmentProbe.probeLedge deliberately preserves: an edge was found and rejected
		-- on a designer tag, which looks identical to open air unless the overlay says otherwise.
		setRow(
			surface[7],
			string.format("ledge       refused (tag) on %s", tostring(ledge.Instance)),
			Tokens.Color.Warning
		)
	else
		setRow(surface[7], "ledge       none", Tokens.Color.TextSecondary)
	end
	setRow(
		surface[8],
		string.format("ceiling     clear=%s", tostring(context.CeilingClear)),
		foundColor(context.CeilingClear)
	)
	setRow(
		surface[9],
		string.format("chains      wallRun %d  wallJump %d", context.WallRunChain, context.WallJumpChain),
		Tokens.Color.TextSecondary
	)

	-- LIVE MECHANICS. Gated on which state is actually running: DebugShimmy/DebugLedgeLeap only mean
	-- anything while LedgeHanging is current, DebugWallRunPivot only while WallRunning is -- see
	-- ParkourContext's own header for why the fields themselves don't need resetting to express this
	-- (they're refreshed every frame the writing state runs, and simply not read otherwise).
	local mechanics = current.MechanicsRows
	local hanging = context.CurrentStateId == "LedgeHanging"
	local wallRunning = context.CurrentStateId == "WallRunning"
	if hanging then
		setRow(
			mechanics[1],
			string.format("shimmy       %s", context.DebugShimmy or "Idle"),
			shimmyColor(context.DebugShimmy)
		)
		setRow(
			mechanics[2],
			string.format("ledge leap   %s", context.DebugLedgeLeap or "Idle"),
			leapColor(context.DebugLedgeLeap)
		)
	else
		setRow(mechanics[1], "shimmy       -- (not hanging)", Tokens.Color.TextDisabled)
		setRow(mechanics[2], "ledge leap   -- (not hanging)", Tokens.Color.TextDisabled)
	end
	if wallRunning then
		setRow(
			mechanics[3],
			string.format("wall pivot   %s", context.DebugWallRunPivot or "Straight"),
			pivotColor(context.DebugWallRunPivot)
		)
	else
		setRow(mechanics[3], "wall pivot   -- (not wall-running)", Tokens.Color.TextDisabled)
	end

	-- AVAILABLE ACTIONS. The active state gets ACTIVE rather than its CanEnter answer --
	-- EvaluateAvailability asks every registered state "could you be entered right now," and it asks
	-- that of the RUNNING state too, which routinely answers no for a perfectly good reason: a live
	-- slide reports "Sliding no NoSlideInput" the moment the buffered press expires (the hold is what
	-- continues it; the press is what starts it), and read on its own that line says the exact
	-- opposite of the truth. The running state is labelled as what it is instead.
	local currentId = machine:GetCurrentId()
	local availability = machine:EvaluateAvailability(context)
	for index, row in current.ActionRows do
		local record = availability[index]
		if not record then
			setRow(row, "", Tokens.Color.TextDisabled)
		elseif record.Id == currentId then
			setRow(row, string.format("  %-14s ACTIVE", record.Id), Tokens.Color.AccentPrimaryBright)
		else
			setRow(
				row,
				string.format(
					"  %-14s %s  %s",
					record.Id,
					if record.Available then "YES" else " no",
					record.Reason or ""
				),
				if record.Available then Tokens.Color.Positive else Tokens.Color.TextSecondary
			)
		end
	end

	-- RECENT TRANSITIONS. Newest first, oldest rows blank once there is less history than row slots
	-- (the common case for the first few seconds of any session).
	local history = machine:GetHistory()
	for index, row in current.TransitionRows do
		local entry = history[#history - index + 1]
		if entry then
			setRow(
				row,
				string.format("  %s -> %s  (%s)", entry.From, entry.To, entry.Route),
				Tokens.Color.TextSecondary
			)
		else
			setRow(row, "", Tokens.Color.TextSecondary)
		end
	end
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
	if not handles then
		handles = mountPanel()
	end
	refreshReadout(context, machine)
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
	local current = handles
	if current then
		current.Scope:doCleanup()
		handles = nil
	end
end

-- Binds the toggle key. Studio only -- see the file header. Idempotent.
-- Whether an authorized admin is allowed this overlay in a LIVE server. Set by
-- Client/DevMenu/DevMenuClient.lua once the server has answered its authorization round-trip -- see
-- SetAuthorized below.
local authorized = false

-- Whether the toggle key should do anything right now. Studio is unconditional (the overlay is
-- developer tooling and Studio is a developer); a live server additionally requires the same admin
-- whitelist the dev menu runs on.
local function toggleAvailable(): boolean
	return RunService:IsStudio() or authorized
end

-- Grants this overlay in a live server. Called from DevMenuClient once (and only once) the server has
-- confirmed this client is on the AdminConfig whitelist -- the same answer that gates the dev menu
-- itself, reused rather than re-asked, so there is one authorization round-trip per session and one
-- roster to maintain.
--
-- SAFE TO BE CLIENT-SIDE, and worth stating plainly since this is a flag a client sets on itself:
-- the overlay is strictly READ-ONLY. It draws EnvironmentProbe's existing result tables and calls
-- StateMachine.EvaluateAvailability, which is contractually a pure predicate. There is no action
-- behind it to escalate into -- an attacker who forced this true would gain a heads-up display of
-- their own client's movement state, which they could compute themselves anyway. Every privileged
-- ACTION still goes through DevMenuSystem's own server-side check, exactly as before.
function ParkourDebug.SetAuthorized(value: boolean): ()
	authorized = value
	if not value and enabled then
		ParkourDebug.SetEnabled(false)
	end
	logger:debug("Parkour debug authorization changed", { authorized = value })
end

function ParkourDebug.Start(): ()
	if started then
		return
	end
	started = true
	-- The input hook is connected UNCONDITIONALLY and the availability check moved to press time,
	-- where it used to be an early return here. That ordering is what makes live-server access work at
	-- all: Start() runs synchronously during the client boot sequence, while SetAuthorized arrives one
	-- server round-trip later (DevMenuClient deliberately does its authorization check off the boot
	-- path -- see its own Start header). Gating the CONNECTION on a flag that is still false at boot
	-- meant an authorized admin could never get the overlay in a live game no matter what happened
	-- afterwards.
	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if input.KeyCode ~= DEBUG.ToggleKeyCode then
			return
		end
		if not toggleAvailable() then
			return
		end
		ParkourDebug.SetEnabled(not enabled)
	end)
	logger:info("Parkour debug started", { toggleKey = DEBUG.ToggleKeyCode.Name, studio = RunService:IsStudio() })
end

return ParkourDebug
