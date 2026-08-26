--!strict
--[[
	PreviewViewport.lua

	Owns: the Move Editor's right column -- a live, local, no-round-trip-needed 3D preview of the
	currently selected draft's hitbox against a dummy rig. The one genuinely novel UI piece in this
	codebase: no ViewportFrame-based component existed anywhere before this.

	The dummy rig is built ONCE via Players:CreateHumanoidModelFromDescription (an empty
	HumanoidDescription, R15) -- the exact same client-safe API DummyCombat.lua's own
	createTrainingDummy already uses server-side to build a generic body with no asset upload/
	reference needed. It never moves and has no live combat state; it exists purely to give the
	gizmo a sense of scale/position, the same purpose HitboxResolver.lua's own Studio debug parts
	serve for a real swing.

	The hitbox gizmo is a POOL of Parts -- one per piece of HitboxShapes.BuildPreviewParts'
	decomposition of the draft's (Shape, Dimensions) pair, styled with the same ForceField/translucent
	look HitboxResolver.lua's own debug-visualization part uses, for visual consistency with what an
	admin already sees in Studio during a real swing. It is the SAME function, on the same numbers,
	that HitboxResolver's own debug renderer draws from and that the server resolves hits against, so
	the silhouette an author tunes here and the volume that actually hits cannot drift apart -- which
	is the entire reason that decomposition lives in HitboxShapes rather than in either renderer.
	The pool is positioned at dummyRootCFrame * Draft.Offset (each piece then offset by its own local
	CFrame), mirroring HitboxResolver.performSample's own `trackedCFrame * definition.Offset` formula
	exactly -- pure local geometry math, no server round trip.

	Why a pool of plain Instances rather than one reactive Fusion Part: the piece COUNT is itself a
	function of the draft (1 for a Sphere, 24 for a ringed Disc), and a shape change has to add and
	remove real Instances rather than re-point properties. So the pool is rebuilt imperatively from an
	Observer on a geometry KEY -- a string encoding just Shape plus the eight Dimensions numbers --
	and the per-frame pose/tint are pushed over the existing pool by their own Observers. That split
	matters: during playback the pose changes every frame while the geometry usually doesn't, and
	rebuilding two dozen Parts per frame is exactly what keying the rebuild separately avoids.

	Phase buttons (Windup/Active/Recovery) tint the gizmo for manual step-through. The Play button
	(below) is the literal-recreation counterpart: a real-time playthrough of the whole authored
	timeline rather than a drag-scrubber -- driven by Heartbeat instead of input, since nothing about
	"watch the move happen" needs a draggable handle. It loops until Stop is pressed, so an author can
	watch a swing repeat while tweaking numbers on the panel beside it.
	During playback: the dummy's root actually translates for a Movement lunge (constant speed,
	distanceStuds/durationSeconds, starting at t=0 -- mirrors the deleted Movement.ApplyCustomMoveLunge's own
	formula and CombatSystem.ThrowCustomMove's own "applied at the moment of the throw" timing) and a
	Projectile's gizmo actually flies from its windup-end spawn pose out to MaxRange/Speed (mirrors
	HitboxResolver's own computeProjectilePose formula exactly, spawnCFrame * CFrame.new(0, 0,
	-traveledStuds), captured ONCE and independent of any lunge -- the same "projectile detaches at
	launch" behavior StartProjectile's own header describes). The authored animation TIMELINE plays on
	the dummy's own Animator for the same reason -- watching the real clips, not just a tinted box, is
	most of what "literal recreation" means here.

	Animation playback is driven off AnimationTimeline.Resolve, the same pure scheduler the timeline
	editor draws its strip from, so each clip starts and stops at exactly the resolved second and
	carries its own authored Speed/Weight/FadeIn/FadeOut/Looped. A clip whose StopMode is "Natural"
	(ScheduledClip.LetPlayOut) is deliberately never Stopped at its drawn end -- that end is a
	drawing/statistics bound, and cutting the track there would contradict what "let it play itself
	out" means; the loop boundary's own stopAllClips is what finally releases it. A move carrying only
	the legacy single AnimationId is projected through AnimationTimeline.FromLegacyAnimationId, the
	same rule MoveRegistryManager.Validate applies server-side, so an unsaved v1 draft previews
	identically to how it will play once saved.

	Camera is a click-drag orbit around a fixed focus point just above the dummy's feet, plus a
	scroll-wheel zoom (distance clamped to [MIN_ORBIT_DISTANCE, MAX_ORBIT_DISTANCE]) -- together the
	only interactive camera controls in this UI framework.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local HitboxShapes = require(ReplicatedStorage.Shared.HitboxShapes)
local AnimationTimeline = require(ReplicatedStorage.Shared.AnimationTimeline)
local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local MoveStatsGrid = require(script.Parent.MoveStatsGrid)
local Panel = require(script.Parent.Parent.Parent.Parent.Components.Panel)
local Stack = require(script.Parent.Parent.Parent.Parent.Components.Stack)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local Tab = require(script.Parent.Parent.Parent.Parent.Components.Tab)
local Button = require(script.Parent.Parent.Parent.Parent.Components.Button)

local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type MoveDefinition = MoveTypes.MoveDefinition
type Phase = "Windup" | "Active" | "Recovery"

export type PreviewViewportProps = {
	Draft: Fusion.Value<MoveDefinition?>,
	-- Watched only to stop an in-flight Play loop the instant the whole editor closes -- otherwise
	-- the Heartbeat connection below would keep ticking (invisibly, ScreenGui.Enabled = false)
	-- until the admin reopens the editor and presses Stop themselves.
	IsOpen: Fusion.Value<boolean>,
}

-- Formerly Constants.Combat.Hitboxes.DebugPart, matching HitboxResolver.lua's own Studio
-- debug-part cosmetics so this preview read as "the same hitbox an admin would see in Studio."
-- HitboxResolver.lua (and the rest of core combat) was removed; this is now the only reader, so
-- the color/transparency are inlined here rather than kept as a shared Constants table for one.
local DEBUG_PART = {
	Color = Color3.fromRGB(255, 64, 64),
	Transparency = 0.6,
}
local ORBIT_SENSITIVITY = 0.5
local ORBIT_MIN_PITCH = -80
local ORBIT_MAX_PITCH = 80
local DEFAULT_ORBIT_DISTANCE = 9
local MIN_ORBIT_DISTANCE = 3
local MAX_ORBIT_DISTANCE = 25
-- Studs per scroll-wheel notch -- one Roblox MouseWheelForward/Backward event fires per physical
-- notch on a standard mouse, so this reads as a comfortable, predictable step rather than a
-- delta-scaled zoom.
local ZOOM_STEP = 1.5
local FOCUS_HEIGHT = 3

-- Builds the static, never-moving preview rig -- an empty HumanoidDescription is enough for a
-- generic body silhouette (no player avatar lookup, no asset reference). Not a real combat
-- participant: its own Humanoid/Animate script are left alone but never driven by anything here.
local function buildDummyRig(): (Model, CFrame)
	local description = Instance.new("HumanoidDescription")
	local model = Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
	model.Name = "PreviewDummy"
	model:PivotTo(CFrame.new(0, 0, 0))

	local rootPart = model:FindFirstChild("HumanoidRootPart")
	local rootCFrame = if rootPart and rootPart:IsA("BasePart") then rootPart.CFrame else CFrame.new(0, 3, 0)
	return model, rootCFrame
end

local PreviewViewportModule = {}

function PreviewViewportModule.Mount(scope: Scope, width: number, height: number, props: PreviewViewportProps): Frame
	-- The dummy rig is NOT built here -- buildDummyRig calls the yielding
	-- Players:CreateHumanoidModelFromDescription, and Mount runs for every player at UI boot (see
	-- UI/init.lua), admin or not, panel opened or not. Deferred to ensureDummyRig below, called the
	-- first time this panel's own IsOpen flips true (near worldModel's own construction, since that's
	-- what the rig gets parented into), so a player who never opens the Move Editor never pays for a
	-- rig they'll never see. dummyRootCFrame starts at the same fallback buildDummyRig itself falls
	-- back to for a rig missing a HumanoidRootPart, so the gizmo positioning math below has a sane
	-- pose to read before the real rig exists.
	local dummyModel: Model? = nil
	local dummyHumanoid: Humanoid? = nil
	local dummyAnimator: Animator? = nil
	local dummyRootCFrame = CFrame.new(0, 3, 0)
	local dummyRigBuilt = false

	local selectedPhase: Fusion.Value<Phase> = scope:Value("Active" :: Phase)

	-- Play state -- see this file's own header for the overall behavior. dummyLiveCFrame tracks the
	-- dummy's CURRENT root pose (moves during a Movement lunge; equal to dummyRootCFrame otherwise),
	-- read by gizmoCFrame below for a melee move's hitbox so the gizmo rides along with the dummy
	-- exactly as HitboxResolver.performSample's own live trackedCFrame does for a real swing.
	local isPlaying = scope:Value(false)
	local playElapsed = scope:Value(0)
	local dummyLiveCFrame = scope:Value(dummyRootCFrame)
	local heartbeatConnection: RBXScriptConnection? = nil

	-- Every AnimationTrack the timeline has loaded, keyed by ClipId .. "|" .. AnimationId. Keyed on
	-- BOTH so that re-pointing a clip at a different asset loads a fresh track instead of replaying
	-- the old one, and so two clips sharing one asset still get an independent track each -- a single
	-- AnimationTrack cannot play twice concurrently, which is exactly what two overlapping clips
	-- would ask of it. Cached across loop iterations: LoadAnimation is the expensive part, and a
	-- looping preview would otherwise re-load every clip once per cycle.
	local loadedTracks: { [string]: AnimationTrack } = {}
	-- The clips the timeline has started and not yet released, keyed by ClipId.
	local playingTracks: { [string]: AnimationTrack } = {}
	local scheduledClips: { AnimationTimeline.ScheduledClip } = {}

	local function stopAllClips(): ()
		for clipId, track in pairs(playingTracks) do
			track:Stop()
			playingTracks[clipId] = nil
		end
	end

	local function loadClipTrack(clip: AnimationTimeline.Clip): AnimationTrack?
		-- Captured into a local so the nil check narrows for the closure below.
		local animator = dummyAnimator
		if not animator then
			return nil
		end
		local key = `{clip.ClipId}|{clip.AnimationId}`
		local existing = loadedTracks[key]
		if existing then
			return existing
		end
		-- pcall because an author can type any string into a clip's animation field and LoadAnimation
		-- throws on a malformed or inaccessible asset id. One clip failing to load must not take the
		-- rest of the preview down with it.
		local ok, result = pcall(function()
			local animation = Instance.new("Animation")
			animation.AnimationId = clip.AnimationId
			return animator:LoadAnimation(animation)
		end)
		if not ok then
			return nil
		end
		local track = result :: AnimationTrack
		loadedTracks[key] = track
		return track
	end

	-- Starts every clip that just became live and releases every one that just ended. Idempotent per
	-- frame: a clip already in playingTracks is never re-Played, so this is safe to call every tick.
	local function syncTimeline(elapsed: number): ()
		for _, entry in ipairs(scheduledClips) do
			local clip = entry.Clip
			local isLive = elapsed >= entry.StartSeconds and elapsed < entry.StopSeconds
			local track = playingTracks[clip.ClipId]
			if isLive and not track then
				local loaded = loadClipTrack(clip)
				if loaded then
					loaded.Looped = clip.Looped
					-- The authored layer, applied before Play so the track never renders one frame at
					-- whatever priority the uploaded asset was exported with. The clip stores a STRING (it
					-- crosses a DataStore and a remote -- see AnimationTimeline.ClipPriority), so this is
					-- where it becomes a real EnumItem. An unknown name can't reach here: SanitizeClip
					-- restricts the field to the four the picker offers, and the fallback keeps a hand-crafted
					-- payload from indexing Enum with nil.
					loaded.Priority = (Enum.AnimationPriority :: any)[clip.Priority] or Enum.AnimationPriority.Action
					loaded:Play(clip.FadeInSeconds, clip.Weight, clip.Speed)
					playingTracks[clip.ClipId] = loaded
				end
			elseif not isLive and track and not entry.LetPlayOut then
				track:Stop(clip.FadeOutSeconds)
				playingTracks[clip.ClipId] = nil
			end
			-- A LetPlayOut clip is deliberately left BOTH running and registered: its StopSeconds is a
			-- drawing bound, not a real stop (see this file's header), and leaving it registered means
			-- the loop boundary's own stopAllClips still owns releasing it while this branch can never
			-- restart it mid-cycle.
		end
	end

	local function stopPlayback(): ()
		if heartbeatConnection then
			heartbeatConnection:Disconnect()
			heartbeatConnection = nil
		end
		stopAllClips()
		table.clear(scheduledClips)
		isPlaying:set(false)
		playElapsed:set(0)
		dummyLiveCFrame:set(dummyRootCFrame)
		if dummyModel then
			dummyModel:PivotTo(dummyRootCFrame)
		end
	end

	-- The clip list a draft previews with: its authored timeline, or -- for a move carrying only the
	-- legacy single AnimationId -- that id projected onto a one-clip timeline, which is exactly the
	-- rule MoveRegistryManager.Validate applies server-side. See this file's header.
	local function draftClips(draft: MoveDefinition): { AnimationTimeline.Clip }
		if #draft.Animations > 0 then
			return draft.Animations
		end
		return AnimationTimeline.FromLegacyAnimationId(draft.AnimationId)
	end

	local function startPlayback(): ()
		local draft = peek(props.Draft)
		if not draft or draft.WindupSeconds + draft.ActiveSeconds + draft.RecoverySeconds <= 0 then
			return
		end
		stopPlayback()
		isPlaying:set(true)

		heartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime: number)
			local currentDraft = peek(props.Draft)
			if not currentDraft or currentDraft.MoveId ~= draft.MoveId then
				-- The selected move changed (or was cleared) out from under an in-flight playthrough --
				-- stop rather than keep animating stale geometry against a different draft's numbers.
				stopPlayback()
				return
			end

			local totalDuration = currentDraft.WindupSeconds + currentDraft.ActiveSeconds + currentDraft.RecoverySeconds
			local elapsed = peek(playElapsed) + deltaTime
			if elapsed >= totalDuration then
				-- Loop -- see file header on why Play repeats instead of a single playthrough. Every
				-- track is released here (including any LetPlayOut clip still running) so the next
				-- cycle starts from a clean slate rather than layering a second copy of each clip.
				elapsed = 0
				stopAllClips()
			end
			playElapsed:set(elapsed)

			-- Re-resolved every tick rather than cached against a key: the schedule is a pure function
			-- of at most AnimationTimeline.Limits.MaxClips (8) clips, so resolving it costs microseconds,
			-- and doing it fresh is what lets an author retime a clip mid-playthrough and see it land on
			-- the very next frame. playingTracks is keyed by ClipId, which survives re-resolution, so
			-- what is already playing lines up with the new schedule.
			scheduledClips = AnimationTimeline.Resolve(draftClips(currentDraft), {
				WindupSeconds = currentDraft.WindupSeconds,
				ActiveSeconds = currentDraft.ActiveSeconds,
				RecoverySeconds = currentDraft.RecoverySeconds,
			})
			syncTimeline(elapsed)

			if currentDraft.Movement then
				local speed = currentDraft.Movement.LungeDistanceStuds / currentDraft.Movement.LungeDurationSeconds
				local traveled = math.min(elapsed, currentDraft.Movement.LungeDurationSeconds) * speed
				local liveRoot = dummyRootCFrame * CFrame.new(0, 0, -traveled)
				dummyLiveCFrame:set(liveRoot)
				if dummyModel then
					dummyModel:PivotTo(liveRoot)
				end
			end
		end)
	end

	-- Stops an in-flight Play loop the instant the whole editor closes -- see PreviewViewportProps.
	-- IsOpen's own header.
	scope:Observer(props.IsOpen):onChange(function()
		if not peek(props.IsOpen) then
			stopPlayback()
		end
	end)

	-- Switching moves out from under a running playthrough is handled inside the Heartbeat loop
	-- above (it compares MoveId every tick), but a manual Windup/Active/Recovery tab click should
	-- also hand control back to the author immediately rather than fight a still-running loop.
	local function selectPhaseManually(phase: Phase): ()
		stopPlayback()
		selectedPhase:set(phase)
	end

	local yaw = scope:Value(35)
	local pitch = scope:Value(-15)
	local distance = scope:Value(DEFAULT_ORBIT_DISTANCE)
	local isDragging = false
	local lastPointerX, lastPointerY = 0, 0

	local cameraCFrame = scope:Computed(function(use)
		local yawRadians = math.rad(use(yaw))
		local pitchRadians = math.rad(use(pitch))
		local focusPoint = Vector3.new(0, FOCUS_HEIGHT, 0)
		local offset = Vector3.new(
			math.sin(yawRadians) * math.cos(pitchRadians),
			math.sin(pitchRadians),
			math.cos(yawRadians) * math.cos(pitchRadians)
		) * use(distance)
		return CFrame.lookAt(focusPoint + offset, focusPoint)
	end)

	-- The phase every readout below actually renders: driven by the live playElapsed while Play is
	-- running, otherwise whatever the author last clicked manually.
	local displayPhase = scope:Computed(function(use)
		local draft = use(props.Draft)
		if use(isPlaying) and draft then
			local elapsed = use(playElapsed)
			if elapsed < draft.WindupSeconds then
				return "Windup" :: Phase
			elseif elapsed < draft.WindupSeconds + draft.ActiveSeconds then
				return "Active" :: Phase
			end
			return "Recovery" :: Phase
		end
		return use(selectedPhase)
	end)

	-- Encodes ONLY what BuildPreviewParts' output actually depends on -- the shape plus the eight
	-- measurements -- into one comparable string, so the Observer below rebuilds the part pool when
	-- the geometry genuinely changed and not when the pose ticked. See this file's header on why the
	-- rebuild and the per-frame pose are keyed separately.
	local geometryKey = scope:Computed(function(use)
		local draft = use(props.Draft)
		if not draft then
			return ""
		end
		local dimensions = HitboxShapes.Sanitize(draft.Shape, draft.Dimensions)
		return string.format(
			"%s|%.4f|%.4f|%.4f|%.4f|%.4f|%.4f|%.4f|%.4f",
			draft.Shape,
			dimensions.Width,
			dimensions.Height,
			dimensions.Depth,
			dimensions.Length,
			dimensions.Thickness,
			dimensions.Radius,
			dimensions.InnerRadius,
			dimensions.AngleDegrees
		)
	end)
	-- Whether elapsed Active-phase flight time has already exceeded a projectile's own MaxRange/Speed
	-- cap -- mirrors HitboxResolver.Update's own maxFlightSeconds = min(ActiveSeconds, MaxRange/Speed)
	-- exactly, so the preview hides the gizmo at the same instant a real projectile's visualPart would
	-- have already been destroyed, instead of showing it sitting stationary at max range for the rest
	-- of Active/Recovery.
	local isProjectileExpired = scope:Computed(function(use)
		local draft = use(props.Draft)
		if not (use(isPlaying) and draft and draft.Projectile) then
			return false
		end
		local elapsed = use(playElapsed)
		local activeElapsed = elapsed - draft.WindupSeconds
		local maxFlightSeconds = math.min(draft.ActiveSeconds, draft.Projectile.MaxRange / draft.Projectile.Speed)
		return activeElapsed > maxFlightSeconds
	end)
	local gizmoCFrame = scope:Computed(function(use)
		local draft = use(props.Draft)
		local liveRoot = use(dummyLiveCFrame)
		if not draft then
			return liveRoot
		end
		if use(isPlaying) and draft.Projectile then
			local spawnCFrame = dummyRootCFrame * draft.Offset
			local elapsed = use(playElapsed)
			if elapsed < draft.WindupSeconds then
				return spawnCFrame
			end
			-- Mirrors HitboxResolver's own computeProjectilePose formula exactly.
			local activeElapsed = elapsed - draft.WindupSeconds
			local traveled = math.min(activeElapsed * draft.Projectile.Speed, draft.Projectile.MaxRange)
			return spawnCFrame * CFrame.new(0, 0, -traveled)
		end
		return liveRoot * draft.Offset
	end)
	local gizmoColor = scope:Computed(function(use)
		local phase = use(displayPhase)
		if phase == "Windup" then
			return Tokens.Color.TextDisabled
		elseif phase == "Recovery" then
			return Tokens.Color.AccentSecondary
		end
		return DEBUG_PART.Color
	end)
	local gizmoTransparency = scope:Computed(function(use)
		if use(isProjectileExpired) then
			return 1
		end
		return if use(displayPhase) == "Active" then DEBUG_PART.Transparency else 0.75
	end)
	local phaseTimeText = scope:Computed(function(use)
		local draft = use(props.Draft)
		if not draft then
			return ""
		end
		local phase = use(displayPhase)
		local elapsedSuffix = if use(isPlaying) then ` (t={string.format("%.2f", use(playElapsed))}s)` else ""
		if phase == "Windup" then
			return `Windup: 0s -> {string.format("%.2f", draft.WindupSeconds)}s{elapsedSuffix}`
		elseif phase == "Active" then
			local activeText = `Active: {string.format("%.2f", draft.WindupSeconds)}s -> {string.format(
				"%.2f",
				draft.WindupSeconds + draft.ActiveSeconds
			)}s{elapsedSuffix}`
			if draft.Projectile then
				local rangeSuffix = if use(isProjectileExpired) then " (out of range -- despawned)" else ""
				return `{activeText} (travels {draft.Projectile.Speed} studs/s, up to {draft.Projectile.MaxRange} studs){rangeSuffix}`
			end
			return activeText
		end
		return `Recovery: {string.format("%.2f", draft.WindupSeconds + draft.ActiveSeconds)}s -> {string.format(
			"%.2f",
			draft.WindupSeconds + draft.ActiveSeconds + draft.RecoverySeconds
		)}s{elapsedSuffix}`
	end)

	-- The live pool, paired with each piece's own local CFrame so a pose update is one multiply per
	-- piece rather than a re-decomposition. Parented to a Fusion-owned Folder, so tearing the panel
	-- down destroys every piece with it without a cleanup callback of its own.
	local gizmoFolder = scope:New "Folder" { Name = "HitboxGizmo" } :: Folder
	local gizmoPieces: { { Part: Part, LocalCFrame: CFrame } } = {}

	local function applyGizmoPose(): ()
		local pose = peek(gizmoCFrame)
		for _, piece in ipairs(gizmoPieces) do
			piece.Part.CFrame = pose * piece.LocalCFrame
		end
	end

	local function applyGizmoStyle(): ()
		local color = peek(gizmoColor)
		local transparency = peek(gizmoTransparency)
		for _, piece in ipairs(gizmoPieces) do
			piece.Part.Color = color
			piece.Part.Transparency = transparency
		end
	end

	local function rebuildGizmo(): ()
		for _, piece in ipairs(gizmoPieces) do
			piece.Part:Destroy()
		end
		table.clear(gizmoPieces)

		local draft = peek(props.Draft)
		if not draft then
			return
		end

		local pose = peek(gizmoCFrame)
		local color = peek(gizmoColor)
		local transparency = peek(gizmoTransparency)
		-- Re-sanitized rather than trusted: a draft mid-edit is local, unvalidated client state, and
		-- BuildPreviewParts divides by several of these fields. Sanitize is the same normalization
		-- MoveRegistryManager.Validate will run server-side, so the preview draws what will be saved.
		local dimensions = HitboxShapes.Sanitize(draft.Shape, draft.Dimensions)

		for _, piece in ipairs(HitboxShapes.BuildPreviewParts(draft.Shape, dimensions)) do
			local part = Instance.new("Part")
			part.Name = "GizmoPiece"
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.CastShadow = false
			part.Material = Enum.Material.ForceField
			part.Shape = piece.PartType
			part.Size = piece.Size
			part.Color = color
			part.Transparency = transparency
			part.CFrame = pose * piece.CFrame
			part.Parent = gizmoFolder
			table.insert(gizmoPieces, { Part = part, LocalCFrame = piece.CFrame })
		end
	end

	scope:Observer(geometryKey):onChange(rebuildGizmo)
	scope:Observer(gizmoCFrame):onChange(applyGizmoPose)
	scope:Observer(gizmoColor):onChange(applyGizmoStyle)
	scope:Observer(gizmoTransparency):onChange(applyGizmoStyle)
	-- Observers only fire on CHANGE, so the initial pool has to be built explicitly -- otherwise a
	-- move already selected when the panel mounts would show nothing until its first edit.
	rebuildGizmo()

	local worldModel = scope:New "WorldModel" {
		[Children] = { gizmoFolder },
	}

	-- Builds the rig into `worldModel` above -- see this file's own header and Mount's opening
	-- comment for why this is deferred rather than built eagerly. Re-derives dummyRootCFrame/
	-- dummyLiveCFrame from the REAL rig (not the placeholder) and refreshes the gizmo pool against
	-- it, since rebuildGizmo() already ran once above against the placeholder pose during Mount.
	local function ensureDummyRig(): ()
		if dummyRigBuilt then
			return
		end
		dummyRigBuilt = true
		local model, rootCFrame = buildDummyRig()
		dummyModel = model
		dummyRootCFrame = rootCFrame
		dummyLiveCFrame:set(rootCFrame)
		dummyHumanoid = model:FindFirstChildOfClass("Humanoid")
		if dummyHumanoid then
			dummyAnimator = dummyHumanoid:FindFirstChildOfClass("Animator")
			if not dummyAnimator then
				dummyAnimator = Instance.new("Animator")
				dummyAnimator.Parent = dummyHumanoid
			end
		end
		model.Parent = worldModel
		rebuildGizmo()
	end

	if peek(props.IsOpen) then
		ensureDummyRig()
	else
		scope:Observer(props.IsOpen):onChange(function()
			if peek(props.IsOpen) then
				ensureDummyRig()
			end
		end)
	end

	local camera = scope:New "Camera" {
		CFrame = cameraCFrame,
		FieldOfView = 60,
	} :: Camera

	-- Fills whatever the phase row above it leaves, rather than subtracting that row's height and the
	-- gap after it -- see Components/Stack.lua. Stack.Fill works on any child of any UIListLayout, and
	-- the one here is Components/Panel.lua's, not a Stack's.
	local viewport = scope:New "ViewportFrame" {
		Name = "Viewport",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Tokens.Color.Background,
		BorderSizePixel = 0,
		-- Without this, scrolling/dragging over the viewport doesn't count as "consumed by the UI"
		-- as far as Roblox's own core camera-control scripts are concerned, so the player's REAL
		-- third-person camera zooms/rotates right along with this preview's own orbit camera --
		-- Active = true is what makes this GuiObject capture the input instead of letting it fall
		-- through to whatever's rendered behind it.
		Active = true,
		Ambient = Color3.fromRGB(90, 84, 104),
		LightColor = Color3.fromRGB(255, 250, 240),
		LightDirection = Vector3.new(-1, -2, -1),
		CurrentCamera = camera,
		LayoutOrder = 2,

		[OnEvent "InputBegan"] = function(input: InputObject)
			if
				input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
			then
				isDragging = true
				lastPointerX, lastPointerY = input.Position.X, input.Position.Y
			end
		end,
		[OnEvent "InputChanged"] = function(input: InputObject)
			if
				isDragging
				and (
					input.UserInputType == Enum.UserInputType.MouseMovement
					or input.UserInputType == Enum.UserInputType.Touch
				)
			then
				local deltaX = input.Position.X - lastPointerX
				local deltaY = input.Position.Y - lastPointerY
				lastPointerX, lastPointerY = input.Position.X, input.Position.Y
				yaw:set(peek(yaw) - deltaX * ORBIT_SENSITIVITY)
				pitch:set(math.clamp(peek(pitch) - deltaY * ORBIT_SENSITIVITY, ORBIT_MIN_PITCH, ORBIT_MAX_PITCH))
			end
		end,
		[OnEvent "InputEnded"] = function(input: InputObject)
			if
				input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
			then
				isDragging = false
			end
		end,
		-- Scroll wheel zoom -- GuiObject's own dedicated wheel events (one fire per physical notch),
		-- rather than parsing InputChanged's MouseWheel UserInputType, since this is a plain
		-- "hovering over the viewport" gesture with no drag state to track.
		[OnEvent "MouseWheelForward"] = function()
			distance:set(math.clamp(peek(distance) - ZOOM_STEP, MIN_ORBIT_DISTANCE, MAX_ORBIT_DISTANCE))
		end,
		[OnEvent "MouseWheelBackward"] = function()
			distance:set(math.clamp(peek(distance) + ZOOM_STEP, MIN_ORBIT_DISTANCE, MAX_ORBIT_DISTANCE))
		end,

		[Children] = { camera, worldModel },
	} :: ViewportFrame

	return Panel(scope, {
		Name = "PreviewViewport",
		Size = UDim2.fromOffset(width, height),
		CornerAccent = true,

		Children = {
			scope:New "UIPadding" {
				PaddingTop = UDim.new(0, Tokens.Space.M),
				PaddingBottom = UDim.new(0, Tokens.Space.M),
				PaddingLeft = UDim.new(0, Tokens.Space.M),
				PaddingRight = UDim.new(0, Tokens.Space.M),
			},
			scope:New "UIListLayout" {
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Left,
				Padding = UDim.new(0, Tokens.Space.S),
				SortOrder = Enum.SortOrder.LayoutOrder,
			},
			Label(scope, {
				Text = "Preview",
				Scale = "CardTitle",
				LayoutOrder = 0,
			}),
			scope:New "Frame" {
				Name = "PhaseRow",
				Size = UDim2.new(1, 0, 0, Tokens.Control.StepButtonSize),
				BackgroundTransparency = 1,
				LayoutOrder = 1,

				[Children] = {
					scope:New "UIListLayout" {
						FillDirection = Enum.FillDirection.Horizontal,
						Padding = UDim.new(0, Tokens.Space.XS),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},
					Tab(scope, {
						Text = "Windup",
						Size = UDim2.fromOffset(96, Tokens.Control.StepButtonSize),
						Selected = scope:Computed(function(use)
							return use(displayPhase) == "Windup"
						end),
						LayoutOrder = 1,
						OnActivated = function()
							selectPhaseManually("Windup")
						end,
					}),
					Tab(scope, {
						Text = "Active",
						Size = UDim2.fromOffset(96, Tokens.Control.StepButtonSize),
						Selected = scope:Computed(function(use)
							return use(displayPhase) == "Active"
						end),
						LayoutOrder = 2,
						OnActivated = function()
							selectPhaseManually("Active")
						end,
					}),
					Tab(scope, {
						Text = "Recovery",
						Size = UDim2.fromOffset(96, Tokens.Control.StepButtonSize),
						Selected = scope:Computed(function(use)
							return use(displayPhase) == "Recovery"
						end),
						LayoutOrder = 3,
						OnActivated = function()
							selectPhaseManually("Recovery")
						end,
					}),
					Button(scope, {
						Text = scope:Computed(function(use)
							return if use(isPlaying) then "Stop" else "Play"
						end),
						Size = UDim2.fromOffset(96, Tokens.Control.StepButtonSize),
						LayoutOrder = 4,
						Disabled = scope:Computed(function(use)
							return use(props.Draft) == nil
						end),
						OnActivated = function()
							if peek(isPlaying) then
								stopPlayback()
							else
								startPlayback()
							end
						end,
					}),
				},
			},
			Stack.Fill(scope, viewport),
			-- A small readout chip, not a bare Label -- Tokens.Wash.Inset (its own doc comment already
			-- names "a stepper button's face" as a use, the same recessed-field reading this is)
			-- instead of floating text directly on the panel background, so the phase/timing readout
			-- reads as a distinct instrument, not incidental caption text.
			-- The reference's always-visible at-a-glance readout, beneath the viewport. Distinct from
			-- the Stats SECTION (StatsPanel.lua) -- see MoveStatsGrid.lua's header on why both exist.
			MoveStatsGrid.Build(scope, props.Draft, 4),
			scope:New "Frame" {
				Name = "PhaseReadout",
				Size = UDim2.fromOffset(0, 0),
				AutomaticSize = Enum.AutomaticSize.XY,
				BackgroundColor3 = Tokens.Wash.Inset.Color,
				BackgroundTransparency = Tokens.Wash.Inset.Transparency,
				LayoutOrder = 3,

				[Children] = {
					scope:New "UICorner" { CornerRadius = Tokens.Radius.Sharp },
					scope:New "UIStroke" {
						Color = Tokens.Border.Standard.Color,
						Thickness = 1,
						Transparency = Tokens.Border.Standard.Transparency,
					},
					scope:New "UIPadding" {
						PaddingTop = UDim.new(0, Tokens.Space.XS),
						PaddingBottom = UDim.new(0, Tokens.Space.XS),
						PaddingLeft = UDim.new(0, Tokens.Space.S),
						PaddingRight = UDim.new(0, Tokens.Space.S),
					},
					Label(scope, {
						Text = phaseTimeText,
						Scale = "Body",
						Color = Tokens.Color.TextPrimary,
					}),
				},
			},
		},
	}) :: Frame
end

return PreviewViewportModule
