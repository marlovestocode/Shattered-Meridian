--!strict
--[[
	BlimpController.lua

	Owns: everything about a blimp that happens on a client -- the local pilot's helm input (two held
	axes plus three edge presses), their release press, the on-screen cue that says what the controls
	are, the per-frame pose for EVERY mounted character this client can see (hands on the grips AND the
	body's lean), and driving the three blimp screens' handles: UI/Screens/BlimpHelm (the ship's console
	-- role, control legend, telegraph and live telemetry, for pilot and passenger alike),
	UI/Screens/BlimpFuel (the pilot's own gauges) and UI/Screens/CarriedResources -- plus one push into
	a channel it does not own, Shell/Notify, for the furnace's own "what did that press just do" answer
	(see onFuelTransfer). Also the module that
	tells Client/Camera/BlimpCamera.lua, Client/FX/BlimpAudio.lua and Client/FX/BlimpWindVFX.lua when a
	mount begins and ends.

	DECIDES NOTHING. Server/Systems/BlimpSystem.lua is the sole authority on who is mounted, who may
	steer, which rung the telegraph is on and where the hull goes; this module sends inputs and
	presents what the server says came back. Same posture, and for the same reasons, as
	Client/Combat/GrabInputClient.lua sitting next to Server/Combat/Grab/GrabSystem.lua.

	IT IS THE ONE PLACE THAT KNOWS A MOUNT STARTED, which is why four unrelated-looking subsystems are
	all started and stopped from here rather than each running its own watch. The camera needs the
	STATION PART (to find the hull assembly), not just a boolean, so an Attribute watch of the kind
	Client/Camera/FlightCamera.lua uses could not carry enough -- and once one of them has to be told,
	four independent watches for one edge is three more than the situation needs.

	THE POSE IS THE UNUSUAL PART and the reason this module is not simply an input file. Motor6D.
	Transform -- the only joint channel that can beat a playing idle clip -- does not replicate, so both
	the hands (Shared/Blimp/BlimpArmPose.lua) and the lean (Shared/Blimp/BlimpPilotPose.lua) have to be
	solved independently on every client that can see the body. That is why the mount broadcast is
	FireAllClients and why this module tracks a table of OTHER people's characters.

	EVERY POSED CHARACTER SAMPLES ITS OWN HULL, including the local player's -- so a body on a ship
	across the map leans with THAT ship rather than with the one this client happens to be standing on.
	The local player's hull is therefore measured twice a frame: once by BlimpCamera for the view, once
	here for the body. That is deliberate. The alternative is a special case ("if this is me, borrow
	the camera's sample") whose only payoff is two property reads and five multiply-adds, and whose
	cost is a second code path through the pose that only the local player ever exercises.

	THE POSE RUNS ON BindToRenderStep AT Character + 1, not on Heartbeat, and that priority is load-
	bearing: the character/animation update runs at Enum.RenderPriority.Character, so anything earlier
	is simply overwritten by the idle clip on the same frame and the body flickers between two poses.
	It also runs AFTER the camera's own Camera + 1 pass, which is what makes the telemetry this file
	hands the helm panel the same frame's numbers the view was drawn from.

	THE HELM CONTROLS ARE CONTEXTUAL, deliberately, and are the one place this module does not go
	through KeybindManager. A/D and Space/LeftShift are the movement keys the player already has their
	hand on, which are not KeybindActions in this codebase at all (Roblox owns them, via the Humanoid's
	own control module). W/S, X and G join them on the same principle rather than a different one: they
	are read only while this client is holding a helm, are meaningless everywhere else, and are
	invisible to a rebind screen that has no notion of "while piloting". Inventing six rebindable
	actions to shadow keys that screen cannot meaningfully show would be worse than honest raw reads.
	The one control that IS a bind, on one device, is the release press, which shares the Interact
	action with the prompt that started the mount.

	WHAT CHANGED IS WHERE THOSE INPUTS ARE WRITTEN DOWN, NOT WHETHER THEY ARE REBINDABLE. They live in
	BlimpConstants.Controls now, one row per control with a column per device, because the previous
	arrangement gave the same answer twice in two files that could not check each other -- the literals
	this file matched in onInputBegan, and the literal strings Screens/BlimpHelm drew in its legend.
	Read that table's header for the gamepad map and for why every button on it is conflict-free while
	mounted rather than merely unused.

	A PAD REACHES THE TWO HELD AXES THROUGH THE LEFT STICK AND THE FOUR PRESSES THROUGH THE FACE
	BUTTONS, and readHelmAxes SUMS the keyboard pair with Client/Input/Analog.Move() rather than
	branching on device. There is no `if gamepad then` anywhere in this file, and that is deliberate:
	a keyboard-only player's stick reads exactly Vector2.zero, so summing reproduces the old behaviour
	bit for bit, and a player with both plugged in gets whichever they touched without this module
	having to decide which one is "theirs". It is the same conclusion Client/Input/InputRouter.lua
	reaches for bound actions ("no per-caller device branching"), applied to a control that has no
	action to route.

	HOLDING A TELEGRAPH KEY WALKS THE LADDER, and it is implemented here rather than server-side on
	purpose. The server's contract is one rung per request (BlimpSpeedLadder.SanitizeDelta clamps a
	batched or dishonest delta down to one), so a repeat has to be a repeat of REQUESTS -- which means
	it belongs to the thing that can see the key still being held. The alternative, a "keep shifting
	until I say stop" message, would be the client asserting a duration, and a client that then crashed
	or was cut off would leave a ship walking its own throttle to flank with nobody driving it.

	Does not own: the mount rules, the flight integration, the telegraph's rungs, or the prompts
	themselves (BlimpSystem creates them server-side and owns which ones are Enabled for everybody --
	this module only re-keys them to the local player's Interact bind, and suppresses them FOR THIS
	VIEWER while it is mounted, which is what keeps the release press reachable; see
	setPromptsSuppressed for the full argument).
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local BlimpArmPose = require(ReplicatedStorage.Shared.Blimp.BlimpArmPose)
local BlimpCameraMath = require(ReplicatedStorage.Shared.Blimp.BlimpCameraMath)
local BlimpConstants = require(ReplicatedStorage.Shared.Blimp.BlimpConstants)
local BlimpPilotPose = require(ReplicatedStorage.Shared.Blimp.BlimpPilotPose)
local BlimpTypes = require(ReplicatedStorage.Shared.Blimp.BlimpTypes)
local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)
local GatheringConstants = require(ReplicatedStorage.Shared.Gathering.GatheringConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)

local BlimpCamera = require(script.Parent.Parent.Camera.BlimpCamera)
local BlimpAudio = require(script.Parent.Parent.FX.BlimpAudio)
local BlimpWindVFX = require(script.Parent.Parent.FX.BlimpWindVFX)
local Analog = require(script.Parent.Parent.Input.Analog)
local KeybindManager = require(script.Parent.Parent.Input.KeybindManager)
local BlimpFuelModule = require(script.Parent.Parent.UI.Screens.BlimpFuel)
local BlimpHelmModule = require(script.Parent.Parent.UI.Screens.BlimpHelm)
local CarriedResourcesModule = require(script.Parent.Parent.UI.Screens.CarriedResources)
local Notify = require(script.Parent.Parent.UI.Shell.Notify)

local logger = Logger.scope("BlimpController")

local BlimpController = {}

local RENDER_STEP_NAME = "BlimpPose"

local started = false
local setHelmInputRemote: RemoteEvent? = nil
local shiftSpeedRemote: RemoteEvent? = nil
local toggleAutopilotRemote: RemoteEvent? = nil
local dismountRemote: RemoteEvent? = nil

-- Handed in by Main.client.lua from uiHandles, the same "screen exposes state, client module drives
-- it" split every other Screens/ handle in this codebase follows. All three are set once at Start()
-- and never nil afterward.
local fuelHud: BlimpFuelModule.BlimpFuelHandle? = nil
local helmHud: BlimpHelmModule.BlimpHelmHandle? = nil
local carriedResourcesHud: CarriedResourcesModule.CarriedResourcesHandle? = nil
local notifyHandle: Notify.NotifyHandle? = nil

-- One entry per mounted character this client can see, local player included. Keyed by character so
-- the two broadcasts that can arrive for one body (a fast dismount-then-remount at another station)
-- collapse to one entry rather than leaving a stale station behind.
--
-- Motion and Lean are allocated ONCE per body and mutated in place for the whole mount -- see
-- BlimpCameraMath's and BlimpPilotPose's own headers on why neither allocates per frame.
type PosedEntry = {
	Station: BasePart,
	Motion: BlimpCameraMath.State,
	Lean: BlimpPilotPose.State,
}

local posed: { [Model]: PosedEntry } = {}
-- Whether the pose render step is currently bound. Tracked rather than asked, because
-- RunService has no "is this name bound" query and re-binding an already-bound name errors.
local poseBound = false

-- Which station the LOCAL player is on, and of what kind -- nil when not mounted. Separate from
-- `posed` because only this one gates input, and reading it out of the shared table would mean a
-- Players lookup on every frame of steering.
local localKind: BlimpTypes.StationKind? = nil

-- This hull's resolved bow correction, from the helm snapshot -- the one authoring fact a streaming
-- client cannot safely resolve for itself (see BlimpTypes.HelmUpdatedPayload.ForwardYawRadians). Only
-- meaningful while mounted; the heading readout falls back to the raw hull facing without it, which is
-- correct for the majority of hulls (those that need no correction at all).
local forwardYawRadians = 0

local lastSentHelm: BlimpTypes.HelmInput = { Steer = 0, Lift = 0 }
local sendAccumulator = 0

-- The rung the server last confirmed, so a HelmUpdated push can tell "the telegraph moved" apart from
-- "some other field of the same payload changed". nil until the first snapshot -- which matters,
-- because the first one is a mount and must NOT read as a rung change and kick the camera.
local lastSpeedIndex: number? = nil

-- Which telegraph key is currently held (+1 for W, -1 for S, 0 for neither) and how long until the
-- next repeat fires. Only one direction can be held at a time by construction: pressing the opposite
-- key replaces it, which is also what a pilot means by mashing S after holding W.
local telegraphHeld = 0
local telegraphRepeatIn = 0

-- Control legend ---------------------------------------------------------------------------------

-- Used to be a hand-built ScreenGui holding one 820-pixel TextLabel with three hardcoded style
-- values -- see Screens/BlimpHelm/init.lua's header for what was wrong with that and why the legend
-- is a band of a real Screen now. This function is all that is left of it: tell the console what the
-- player is.
--
-- IT NO LONGER PUSHES A RELEASE KEY NAME, and that removal is the point rather than a simplification.
-- It used to hand over KeybindManager.Get("Interact").KeyCode.Name -- a keyboard key, spelled as a
-- string, pushed once per mount -- which was wrong twice over: it drew "E" at a player holding a
-- controller, and being a push rather than a subscription it also went stale the moment somebody
-- rebound Interact while already aboard. That row is a KeyHint `Bindings` entry now
-- (BlimpConstants.Controls.Release), so it resolves per device AND follows a rebind by construction,
-- which is the same correction Client/Blimp/FurnacePromptClient.lua's own Start() records making, for
-- both rows of the furnace panel, for both halves of this reason.
local function refreshControls(): ()
	local handle = helmHud
	if not handle then
		return
	end
	handle.SetKind(localKind)
end

-- Prompt re-keying ------------------------------------------------------------------------------

-- The prompts are server-created (BlimpSystem), so their KeyboardKeyCode is whatever the server set
-- for everybody. Rewriting it here is a purely local property change -- it does not replicate, and
-- does not need to: each client only ever reads its own.
local function reKeyPrompt(instance: Instance): ()
	if not instance:IsA("ProximityPrompt") then
		return
	end
	-- BOTH prompt names, not just the station one. This used to match "BlimpPrompt" alone, so a player
	-- who rebound Interact away from E kept every furnace prompt listening for E -- a rebind that
	-- worked everywhere except the one prompt sitting closest to the wheel.
	local name = instance.Name
	if name ~= BlimpConstants.Prompt.StationPromptName and name ~= BlimpConstants.Prompt.FuelPromptName then
		return
	end
	local bind = KeybindManager.Get("Interact")
	if bind.KeyCode then
		(instance :: ProximityPrompt).KeyboardKeyCode = bind.KeyCode :: Enum.KeyCode
	end
end

-- PROMPTS ARE OFF FOR THIS CLIENT WHILE IT IS MOUNTED, and this is what makes the release press
-- reachable at all.
--
-- The release shares the Interact bind with the prompt that started the mount (see this file's
-- header), which is right -- but a station prompt is not the only prompt within arm's reach of a
-- mounted body. BlimpSystem disables the ONE station you took, and every other prompt on the same
-- hull stays live: the other handholds, and the furnace, whose MaxActivationDistance is 10 studs
-- against a pilot standing 2.5 studs from a wheel that is usually bolted to the furnace console. So
-- the press that was meant to release you was being eaten by whichever neighbouring prompt the engine
-- decided was closest, and E "stopped working" the moment you were aboard.
--
-- ProximityPromptService.Enabled is a CLIENT-LOCAL property, which is the whole reason the fix lives
-- here and not in BlimpSystem. Prompt.Enabled is per-prompt and replicated -- the server turning off
-- the hull's prompts to free up one pilot's E key would take the furnace away from the ground crew
-- refuelling it, and a client writing that property itself would just be overwritten the next time
-- the server touched it. This switch is per-viewer by construction, so it can say "while I am welded
-- to this thing, nothing else is in reach" without making that anyone else's problem.
--
-- The narrowing is real and intended: a passenger holding a rail within ten studs of the furnace can
-- no longer top up the tanks without letting go first. That is the correct reading of holding on with
-- both hands, and it is the price of E meaning exactly one thing while mounted.
local function setPromptsSuppressed(suppressed: boolean): ()
	ProximityPromptService.Enabled = not suppressed
end

local function watchBlimpModel(model: Model): ()
	for _, descendant in model:GetDescendants() do
		reKeyPrompt(descendant)
	end
	-- Prompts on a blimp that is still streaming in arrive after this pass, which is the common case
	-- on a client rather than the exception -- the model replicates before everything inside it does.
	model.DescendantAdded:Connect(reKeyPrompt)
end

-- Steering --------------------------------------------------------------------------------------

-- One key pair as a signed axis. IsKeyDown is the right read here and only here -- both keys in every
-- pair are KEYBOARD keys by construction (BlimpConstants.Controls' axis rows carry no gamepad button,
-- only the stick the legend draws), so the keyboard-only trap that made
-- KeybindManager.IsJumpKeyDown answer false forever on a pad cannot apply. See that function's own
-- note, and Client/Input/Analog.IsButtonDown, for the shape that would be needed if it could.
local function keyAxis(binding: BlimpTypes.HelmAxisBinding): number
	return (if UserInputService:IsKeyDown(binding.Positive) then 1 else 0)
		- (if UserInputService:IsKeyDown(binding.Negative) then 1 else 0)
end

-- The two HELD axes, and only those. The throttle is a telegraph rung the server owns and is moved by
-- an edge press (onInputBegan below), never sampled here -- see BlimpTypes.HelmInput.
--
-- SUMMED ACROSS DEVICES AND THEN CLAMPED, rather than picking one -- see this file's header. The
-- stick is Analog.Move(), whose X is the rudder and whose Y is the elevator, already past the
-- player's own deadzone and response curve; on a client with no pad connected it is exactly
-- Vector2.zero and this arithmetic collapses to the keyboard read it replaced.
--
-- ANALOG SURVIVES THE WHOLE WAY DOWN. BlimpTypes.HelmInput has always been two numbers in -1..1 and
-- Server/Blimp/BlimpDrive.SanitizeHelmInput has always clamped rather than snapped, so a stick held
-- a third over gives a third of the rudder -- the keyboard's three discrete values were a property of
-- the keyboard, never of the contract.
local function readHelmAxes(): BlimpTypes.HelmInput
	local stick = Analog.Move()
	return {
		Steer = math.clamp(keyAxis(BlimpConstants.Controls.Steer) + stick.X, -1, 1),
		Lift = math.clamp(keyAxis(BlimpConstants.Controls.Lift) + stick.Y, -1, 1),
	}
end

-- Sent on CHANGE only, rate-capped, with no keepalive: the server latches the last input it was
-- given, so a pilot holding a steady rudder costs exactly one packet.
--
-- "CHANGED" IS A THRESHOLD NOW, NOT AN EXACT COMPARISON, and the threshold is what preserves that
-- sentence. It was exact because keyboard axes are discrete -- three values, so equality meant what
-- it looked like it meant. A thumbstick's value differs at every sample, so the same comparison would
-- be true on every tick and a pilot holding a perfectly steady stick would stream at IntentSendHz
-- forever. See BlimpConstants.Input.HelmAxisEpsilon, which is a send resolution and deliberately not
-- a deadzone (a resting stick already reads as exactly zero).
local function pumpHelmInput(deltaTime: number): ()
	if localKind ~= "Helm" then
		return
	end
	local remote = setHelmInputRemote
	if not remote then
		return
	end

	sendAccumulator += deltaTime
	local interval = 1 / BlimpConstants.Network.IntentSendHz
	if sendAccumulator < interval then
		return
	end
	sendAccumulator = 0

	local helm = readHelmAxes()
	local epsilon = BlimpConstants.Input.HelmAxisEpsilon
	if math.abs(helm.Steer - lastSentHelm.Steer) < epsilon and math.abs(helm.Lift - lastSentHelm.Lift) < epsilon then
		return
	end
	lastSentHelm = helm
	remote:FireServer(helm)
end

-- Pose ------------------------------------------------------------------------------------------

-- One frame of pose for every mounted body on screen, plus the local player's own instrument
-- telemetry. Bound and unbound with the first/last entry rather than left running for the session --
-- see BlimpCamera.lua's header for the same reasoning applied to the camera.
local function applyPoses(deltaTime: number): ()
	for character, entry in posed do
		if character.Parent == nil or entry.Station.Parent == nil then
			-- The dismount broadcast is the ordinary way an entry leaves this table; this catches the
			-- case where the body or the station simply stopped existing and no broadcast is coming.
			posed[character] = nil
			continue
		end

		-- Re-read every frame rather than stored on the entry -- AssemblyRootPart is re-elected by the
		-- engine whenever the assembly changes shape, which on a blimp is every mount and dismount, and
		-- a client that has not yet received the hull's welds resolves the station as its own one-part
		-- assembly reporting ZERO velocity. A cached reference there leaves the body standing rigid for
		-- the whole flight. See Client/Camera/BlimpCamera.lua's header.
		local hull = entry.Station.AssemblyRootPart
		if hull then
			-- Cruise speed is only used for the SpeedFraction field, which the lean does not read --
			-- the shipped default is fine here rather than resolving this hull's own tuning per body.
			-- BlimpCamera does resolve it, because the view's pull-back and FOV DO scale by it.
			BlimpCameraMath.Observe(
				entry.Motion,
				hull.CFrame,
				hull.AssemblyLinearVelocity,
				hull.AssemblyAngularVelocity,
				BlimpConstants.Drive.CruiseSpeed,
				deltaTime
			)
		else
			-- A hull that stopped being readable relaxes the body upright rather than freezing it
			-- mid-lean, the same release posture the camera takes for the same situation.
			BlimpCameraMath.ZeroMotion(entry.Motion)
		end

		local motion = entry.Motion.Motion
		BlimpPilotPose.Step(entry.Lean, motion.YawRate, motion.ForwardAccel, motion.ClimbRate, deltaTime)

		-- The LEAN GOES ON FIRST and the hands are solved after, which is the whole ordering
		-- requirement between the two modules: BlimpArmPose re-reads the torso's current world CFrame
		-- every frame, so a torso this frame's lean has already moved is the one it lands the hands
		-- against. Reversing these two would put the hands where the body used to be.
		BlimpPilotPose.Apply(character, entry.Lean)
		if not BlimpArmPose.Apply(character, entry.Station) then
			-- A rig this solver cannot pose (no arms, a custom avatar with renamed joints). Dropped
			-- rather than retried, so one unusual character does not cost every frame of the mount.
			posed[character] = nil
		end
	end

	-- The local player's own instruments. Reads BlimpCamera's already-filtered sample rather than
	-- taking a third one -- see that module's GetMotion.
	local handle = helmHud
	if not handle or localKind == nil then
		return
	end
	local motion = BlimpCamera.GetMotion()
	local hull = BlimpCamera.GetHull()
	if not motion or not hull then
		return
	end

	-- The bearing, computed here rather than pushed: the hull's CFrame is replicated to this client
	-- anyway, and the only part of the answer the server had to supply is the constant bow correction
	-- that arrived once on the helm snapshot. atan2(x, -z) because Roblox looks down -Z, and the
	-- modulo is what makes "just west of north" read as 359 rather than as -1.
	local bow = (hull.CFrame * CFrame.Angles(0, forwardYawRadians, 0)).LookVector
	local heading = (math.deg(math.atan2(bow.X, -bow.Z)) + 360) % 360

	handle.SetTelemetry(
		motion.ForwardSpeed,
		motion.ForwardSpeed / math.max(BlimpConstants.Drive.CruiseSpeed, 1),
		hull.Position.Y,
		heading
	)

	-- Same sample, same frame -- the engine note, the visible air and the view can never disagree
	-- about how fast this ship is going, because there is only one measurement of it.
	BlimpAudio.Update(motion.SpeedFraction, math.abs(motion.ForwardSpeed))

	-- The wind gets the hull's own CFrame and RAW velocity -- see BlimpWindVFX's own header on why the
	-- volume is positioned and oriented off the HULL now, not the camera: this game's blimp camera is a
	-- zoomed-out third-person chase view, and a camera-relative volume placed only a few studs ahead of
	-- the CAMERA lands inside or behind the ship's own hull from that framing, occluded by the vessel it
	-- is supposed to be flying into. motion.YawRate is the same filtered sample the camera's own
	-- roll/sway already read -- the turn-sway cue, not a fourth measurement of it. See that module on
	-- why it derives its own UNSIGNED speed fraction rather than borrowing the camera's signed one: air
	-- does not care which way the ship is pointed, and reusing the camera's would show a dead-calm sky
	-- on every reverse.
	BlimpWindVFX.Update(
		hull.CFrame,
		hull.AssemblyLinearVelocity,
		motion.YawRate,
		BlimpCamera.GetCruiseSpeed(),
		deltaTime
	)
end

-- Bound only while at least one body needs posing. `posed` is empty for the overwhelming majority of
-- any session on any client, and a render step that exists to iterate an empty table sixty times a
-- second is a cost every player pays for a feature none of them are near.
local function refreshPoseBinding(): ()
	local wanted = next(posed) ~= nil
	if wanted == poseBound then
		return
	end
	poseBound = wanted
	if wanted then
		-- Character + 1, not Heartbeat -- see this file's header. This is the whole reason the pose
		-- survives a playing idle animation instead of fighting it.
		RunService:BindToRenderStep(RENDER_STEP_NAME, Enum.RenderPriority.Character.Value + 1, applyPoses)
	else
		RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	end
end

-- Network ---------------------------------------------------------------------------------------

local function onMountChanged(raw: unknown): ()
	if typeof(raw) ~= "table" then
		return
	end
	local payload = raw :: BlimpTypes.MountChangedPayload
	local character = payload.Character
	if typeof(character) ~= "Instance" or not character:IsA("Model") then
		return
	end

	local isLocal = Players.LocalPlayer.Character == character

	if not payload.Active then
		posed[character] = nil
		refreshPoseBinding()
		if isLocal then
			localKind = nil
			setPromptsSuppressed(false)
			lastSentHelm = { Steer = 0, Lift = 0 }
			forwardYawRadians = 0
			-- Cleared explicitly rather than left to the next InputEnded, which may never come: a player
			-- who dies at the wheel holding W gets a dismount broadcast and no key release at all, and a
			-- latched repeat would then walk the telegraph of whatever ship they boarded next.
			telegraphHeld = 0
			lastSpeedIndex = nil
			refreshControls()
			-- Released rather than stopped dead: the camera settles its springs back to level over
			-- their own rates and unbinds itself once they have, and the loops fade rather than cut.
			BlimpCamera.SetMount(nil)
			BlimpAudio.Stop()
			BlimpWindVFX.Stop()
			if helmHud then
				helmHud.SetVisible(false)
			end
			-- Every dismount, whether or not the fuel HUD was ever shown for this ride -- a blimp with
			-- no Furnace tag never sends a FuelUpdated push at all (see onFuelUpdated below), so this
			-- is the only edge that reliably clears it. mount() never lets a player mount again
			-- without dismounting first, so this single call also covers Helm -> Handhold and
			-- Helm -> Helm transitions between blimps.
			if fuelHud then
				fuelHud.SetVisible(false)
			end
		end
		return
	end

	local station = payload.Station
	if typeof(station) ~= "Instance" or not station:IsA("BasePart") then
		return
	end
	-- station.AssemblyRootPart IS the hull root, with no lookup: every part of a blimp is welded into
	-- one assembly by Server/Blimp/BlimpAssembly.lua, so the station and the hull's root are members
	-- of the same rigid body by construction.
	posed[character] = {
		Station = station,
		Motion = BlimpCameraMath.NewState(),
		Lean = BlimpPilotPose.NewState(),
	}
	refreshPoseBinding()

	if isLocal then
		localKind = payload.Kind
		setPromptsSuppressed(true)
		-- Zeroed on mount, not carried: the axes the player happened to be holding when they walked up
		-- to the wheel are not a command to set off.
		lastSentHelm = { Steer = 0, Lift = 0 }
		sendAccumulator = 0
		telegraphHeld = 0
		lastSpeedIndex = nil
		refreshControls()
		BlimpCamera.SetMount(station)
		BlimpAudio.Start()
		BlimpWindVFX.Start()
		if helmHud then
			-- refreshControls sets the kind AND the release key together, which is the pair the
			-- console's legend band needs -- see it just above.
			refreshControls()
			-- Shown for a passenger too -- see Screens/BlimpHelm's header on why the audience for the
			-- ship's own state is wider than the audience for the pilot's fuel gauges.
			helmHud.SetVisible(true)
		end
	end
end

-- Helm HUD ------------------------------------------------------------------------------------

-- FireClient'd to everyone aboard one hull.
--
-- DELIBERATELY NOT GATED ON localKind, unlike onFuelUpdated below, and the difference is not an
-- oversight. A mount fires TWO remotes back to back -- MountChanged and this one -- and ordering is
-- only guaranteed WITHIN one RemoteEvent, not across two. If this snapshot were dropped for arriving
-- a beat before the mount broadcast that sets localKind, the panel would sit blank until the next
-- time somebody moved the telegraph, which on a ship whose pilot never touches it again is never.
--
-- The straggler case that gate was protecting against is already covered better elsewhere: the
-- panel's VISIBILITY is driven off the mount edges alone, so a snapshot that lands a frame after a
-- dismount updates a hidden panel and is invisible either way. Writing state to a hidden panel is
-- harmless; refusing to write it to a visible one is not.
local function onHelmUpdated(raw: unknown): ()
	if typeof(raw) ~= "table" then
		return
	end
	local payload = raw :: BlimpTypes.HelmUpdatedPayload
	if typeof(payload.SpeedIndex) ~= "number" or typeof(payload.Mode) ~= "string" then
		return
	end
	if typeof(payload.ForwardYawRadians) == "number" then
		forwardYawRadians = payload.ForwardYawRadians
	end
	-- THE TELEGRAPH KICK. Fired only on a rung that actually MOVED, and never on the first snapshot of
	-- a mount -- a nil mirror means "this is the first thing this client has heard about this ship",
	-- and kicking the camera for it would shove the view on every single boarding.
	local previousIndex = lastSpeedIndex
	lastSpeedIndex = payload.SpeedIndex
	if previousIndex and payload.SpeedIndex ~= previousIndex then
		BlimpCamera.Kick(payload.SpeedIndex - previousIndex)
	end

	local handle = helmHud
	if not handle then
		return
	end
	handle.SetHelmState(payload)
end

-- Fuel HUD ----------------------------------------------------------------------------------------

-- FireClient'd to the pilot only, never a broadcast -- see BlimpConstants.Network.RemoteNames.
-- FuelUpdated's own comment. Gated on localKind == "Helm", unlike onHelmUpdated above, and here the
-- gate genuinely earns its keep: this handler is what makes the panel VISIBLE (see the SetVisible
-- below -- a blimp with no Furnace tag simply never pushes, which is how the panel knows not to
-- appear), so a straggler landing a frame after a dismount would put a fuel panel back on screen for
-- a ship the player has already stepped off. The helm panel has no such problem because its
-- visibility is driven off the mount edges alone.
--
-- The cost of that gate is the ordering hazard onHelmUpdated's comment describes, which is why
-- Server/Systems/BlimpSystem.mount fires the mount broadcast BEFORE this snapshot rather than after.
-- A blimp with no Furnace tag never sends this at all
-- (BlimpSystem.registerBlimp's HasFuelSystem gate), so the panel simply never appears for one --
-- there is no separate "does this blimp have fuel" signal to plumb through, the absence of a push
-- already says so.
local function onFuelUpdated(raw: unknown): ()
	if typeof(raw) ~= "table" then
		return
	end
	if localKind ~= "Helm" then
		return
	end
	local handle = fuelHud
	if not handle then
		return
	end
	local payload = raw :: BlimpTypes.FuelUpdatedPayload
	handle.SetSnapshot(payload)
	handle.SetVisible(true)
end

-- Carried Resources ---------------------------------------------------------------------------------

-- FireClient'd to whichever player it's about, NOT gated on mount state at all -- unlike the two
-- panels above, this is the player's own carried total, visible whether or not they've ever been near
-- a blimp. No localKind check here on purpose: the whole point is that it works for a player who has
-- never mounted anything.
local function onCarriedFuelUpdated(raw: unknown): ()
	if typeof(raw) ~= "table" then
		return
	end
	local handle = carriedResourcesHud
	if not handle then
		return
	end
	local payload = raw :: GatheringConstants.CarriedFuelUpdatePayload
	if typeof(payload.Coal) ~= "number" or typeof(payload.Water) ~= "number" then
		return
	end
	handle.SetCarried(payload.Coal, payload.Water)
end

-- Fuel transfer result -----------------------------------------------------------------------------

-- "180 coal, 320 water", or just the half that actually moved. Floored because both sides of this
-- are live fractional numbers (a tank has been burning since the last top-up) and "179.6 coal" is
-- not a fact anybody wants read back to them.
local function describeMoved(coal: number, water: number): string
	local parts: { string } = {}
	if coal > 0 then
		table.insert(parts, string.format("%d coal", math.floor(coal)))
	end
	if water > 0 then
		table.insert(parts, string.format("%d water", math.floor(water)))
	end
	return table.concat(parts, ", ")
end

-- The words for each of the six (action, outcome) pairs, kept as one table rather than as a branch
-- per case so the load and unload halves are read side by side -- the pair that is easiest to get
-- subtly backwards is exactly the pair a reader should be able to see at once.
--
-- EVERY FAILURE NAMES THE FIX, not just the fault. "Nothing to load" alone leaves a new player
-- exactly where they started; "mine coal and collect water first" is the sentence that actually ends
-- the confusion this whole remote was added to end.
local TRANSFER_MESSAGES: {
	[string]: { [string]: { Title: string, Detail: string? } },
} = {
	Load = {
		Moved = { Title = "Furnace loaded" },
		NothingToMove = { Title = "Nothing to load", Detail = "Mine coal and collect water first" },
		NoRoom = { Title = "Tanks are full", Detail = "This hull will not take any more" },
	},
	Unload = {
		Moved = { Title = "Fuel recovered" },
		NothingToMove = { Title = "Nothing to unload", Detail = "This hull's tanks are empty" },
		NoRoom = { Title = "You cannot carry any more", Detail = "Load some into a furnace first" },
	},
}

-- THE ANSWER TO "I PRESSED REFUEL AND NOTHING HAPPENED", which was true of two of the three outcomes
-- and is the reason this remote exists at all -- see BlimpConstants.Network.RemoteNames.FuelTransfer.
--
-- FIRED AT WHOEVER PRESSED, AND NOT GATED ON localKind, unlike onFuelUpdated above: anyone standing
-- next to the hull may load or unload it, pilot or not, so there is no mount state to check against.
-- The pilot's own gauges are a separate push and stay one.
--
-- The failures are Warnings and both successes are Acquisitions, which is Shell/Notify.lua's own
-- vocabulary rather than a new kind: Warning is that channel's only kind for "something the player
-- must act on", and a ship taking on fuel (or a player getting theirs back) is the closest thing the
-- other three kinds have to a thing being acquired. A fifth kind for one interaction would be a
-- worse trade than a slightly broad fourth.
local function onFuelTransfer(raw: unknown): ()
	if typeof(raw) ~= "table" then
		return
	end
	local notify = notifyHandle
	if not notify then
		return
	end
	local payload = raw :: BlimpTypes.FuelTransferPayload
	if typeof(payload.Action) ~= "string" or typeof(payload.Outcome) ~= "string" then
		return
	end

	local byOutcome = TRANSFER_MESSAGES[payload.Action]
	local message = byOutcome and byOutcome[payload.Outcome]
	if not message then
		return
	end

	if payload.Outcome ~= "Moved" then
		notify:Push({ Kind = "Warning", Title = message.Title, Detail = message.Detail })
		return
	end

	if typeof(payload.Coal) ~= "number" or typeof(payload.Water) ~= "number" then
		return
	end
	notify:Push({
		Kind = "Acquisition",
		Title = message.Title,
		Detail = describeMoved(payload.Coal, payload.Water),
	})
end

-- Input -----------------------------------------------------------------------------------------

-- True while any modal UI panel is up (Components/ModalScreen.lua publishes the count as
-- AttributeConstants.UiModalOpen). The same gate AttackInputClient and GrabInputClient hold, for
-- the same reason: gameProcessedEvent only covers presses that LAND on the GUI, and a centred panel
-- leaves most of the viewport uncovered.
local function isModalUiOpen(): boolean
	local player = Players.LocalPlayer
	return player ~= nil and player:GetAttribute(AttributeConstants.UiModalOpen) == true
end

-- One rung, or All Stop on a delta of 0 -- BlimpSpeedLadder.Shift owns both meanings server-side, and
-- this end deliberately sends the KEYPRESS rather than a target index. See
-- BlimpConstants.Network.RemoteNames.ShiftSpeedState.
local function sendSpeedShift(delta: number): ()
	local remote = shiftSpeedRemote
	if remote then
		remote:FireServer(delta)
	end
end

-- A telegraph key going down: one rung immediately, then the repeat arms behind the initial delay.
--
-- The immediate shift is what keeps a TAP exact -- the repeat delay is long enough that a tap ends
-- before it ever arms, so "one notch back" is one notch back and holding is a separate gesture. See
-- BlimpConstants.Input.
local function beginTelegraphHold(direction: number): ()
	telegraphHeld = direction
	telegraphRepeatIn = BlimpConstants.Input.TelegraphRepeatDelaySeconds
	sendSpeedShift(direction)
end

-- Called every Heartbeat while a telegraph key is held. Saturating at the end of the ladder is the
-- server's job (BlimpSpeedLadder.Shift), so this keeps asking and the server keeps answering with the
-- same rung -- which costs one small packet every sixth of a second while a pilot leans on a key at
-- flank, and buys not having to mirror the ladder's length and current position on the client just to
-- know when to stop.
local function pumpTelegraphHold(deltaTime: number): ()
	if telegraphHeld == 0 then
		return
	end
	if isModalUiOpen() then
		-- A panel opened mid-hold. The key is still physically down, but a player who just opened
		-- their settings is not asking for flank speed -- and unlike InputBegan, which is gated on
		-- this before a hold can ever start, the repeat has to keep checking. Held rather than
		-- dropped: closing the panel with the key still down resumes, which is what the player's
		-- hand is still saying.
		return
	end
	if localKind ~= "Helm" then
		-- Lost the wheel mid-hold (dismounted, died, was bumped off). Drop the repeat rather than
		-- firing into a remote that will reject it for the rest of the time the key stays down.
		telegraphHeld = 0
		return
	end

	telegraphRepeatIn -= deltaTime
	if telegraphRepeatIn > 0 then
		return
	end
	-- Reset rather than accumulated: a frame hitch longer than one interval should cost the pilot the
	-- rungs it swallowed, not hand them back all at once the moment the frame lands.
	telegraphRepeatIn = BlimpConstants.Input.TelegraphRepeatIntervalSeconds
	sendSpeedShift(telegraphHeld)
end

-- Whether `input` is the press that reaches `binding` on EITHER device -- the contextual counterpart
-- of KeybindManager.Matches, and the only thing in this file that knows a control has two columns.
--
-- BOTH COLUMNS ARE CHECKED UNCONDITIONALLY, with no read of which device is "current". That is the
-- same reasoning readHelmAxes sums rather than branches: an InputObject already carries which physical
-- input it was, so a device check here could only ever disagree with the press in hand -- and
-- Client/Input/InputDevice.lua's own hysteresis means it CAN disagree, for one press, right after a
-- player picks a controller up. The keyboard and gamepad columns hold disjoint KeyCodes, so checking
-- both is not ambiguous, merely thorough.
local function matchesControl(binding: BlimpTypes.HelmPressBinding, input: InputObject): boolean
	if input.KeyCode == binding.Gamepad then
		return true
	end
	local keyboard = binding.Keyboard
	if keyboard then
		return input.KeyCode == keyboard
	end
	-- The Release row, whose keyboard half is the live Interact bind rather than a fixed key. Matches
	-- checks BOTH of KeybindManager's maps, which is harmless here and not relied on: Interact has no
	-- plain gamepad binding at all (it is on the chord layer), so the gamepad answer for this row is
	-- the explicit ButtonX above and nothing else.
	local action = binding.Action
	return action ~= nil and KeybindManager.Matches(action, input)
end

local function onInputBegan(input: InputObject, gameProcessed: boolean): ()
	-- BUTTONA IS EXEMPTED FROM THE gameProcessed GATE, and this is a Roblox engine quirk, not a
	-- BlimpConstants reasoning error. BlimpConstants.Controls' header argues ButtonA is safe to spend
	-- here because PlatformStand suspends what the HUMANOID does with it -- true, but irrelevant to
	-- this gate: Roblox marks every gamepad ButtonA press as gameProcessedEvent = true unconditionally
	-- (confirmed devforum-wide engine behaviour, independent of jump, PlatformStand, or anything a game
	-- script can disable), because the engine's own GUI-navigation mode treats A like a confirm click.
	-- That made ThrottleDown -- the one control that spends ButtonA -- silently unreachable on every
	-- pad while ThrottleUp/AllStop/Release/Autopilot all worked, which is exactly "everything but
	-- decelerate". Safe to carve out unconditionally rather than only while mounted: nothing else in
	-- BlimpConstants.Controls binds ButtonA, so this can never let a real GUI click masquerade as a
	-- helm command, and localKind == nil below still bars it the instant the player is not at a helm.
	if (gameProcessed and input.KeyCode ~= Enum.KeyCode.ButtonA) or isModalUiOpen() then
		return
	end
	-- Declines to send what this client can already see is illegal -- the same convention
	-- GrabInputClient's own Grabbing check uses. Not mounted, nothing to release or steer.
	if localKind == nil then
		return
	end

	if matchesControl(BlimpConstants.Controls.Release, input) then
		local remote = dismountRemote
		if not remote then
			logger:warn("Release pressed before the dismount remote was ready")
			return
		end
		remote:FireServer()
		return
	end

	-- Everything below is the pilot's alone. Checked here rather than per-key so a passenger's
	-- keypresses cost one comparison instead of four.
	if localKind ~= "Helm" then
		return
	end

	if matchesControl(BlimpConstants.Controls.ThrottleUp, input) then
		beginTelegraphHold(1)
	elseif matchesControl(BlimpConstants.Controls.ThrottleDown, input) then
		beginTelegraphHold(-1)
	elseif matchesControl(BlimpConstants.Controls.AllStop, input) then
		-- The panic key. Rings the telegraph straight down to All Stop from wherever it was, rather
		-- than making a pilot tap S past four rungs while the ship carries on toward whatever they
		-- just noticed.
		--
		-- Cancels any repeat first: pressing this WITH W still held is a pilot changing their mind
		-- mid-gesture, and leaving the repeat armed would walk the ship straight back up the ladder
		-- they just slammed shut.
		telegraphHeld = 0
		sendSpeedShift(0)
	elseif matchesControl(BlimpConstants.Controls.Autopilot, input) then
		local remote = toggleAutopilotRemote
		if remote then
			remote:FireServer()
		end
	end
end

-- Releasing either telegraph control stops the repeat -- but only the one that is actually driving
-- it, so letting go of W after having already pressed S does not cancel the S hold that replaced it.
local function onInputEnded(input: InputObject, _gameProcessed: boolean): ()
	-- Checked before either match, and it is the ONLY reason this connection is cheap. This fires for
	-- every key and button release anywhere in the game, mounted or not, and the old body was two
	-- KeyCode comparisons; matchesControl is up to two each. The telegraph is not being held for the
	-- overwhelming majority of those releases, and when it is not there is nothing here to do.
	if telegraphHeld == 0 then
		return
	end
	local up = telegraphHeld > 0 and matchesControl(BlimpConstants.Controls.ThrottleUp, input)
	local down = telegraphHeld < 0 and matchesControl(BlimpConstants.Controls.ThrottleDown, input)
	if up or down then
		telegraphHeld = 0
	end
end

-- Lifecycle -------------------------------------------------------------------------------------

function BlimpController.Start(
	helmHudHandle: BlimpHelmModule.BlimpHelmHandle,
	fuelHudHandle: BlimpFuelModule.BlimpFuelHandle,
	carriedResourcesHudHandle: CarriedResourcesModule.CarriedResourcesHandle,
	notify: Notify.NotifyHandle
): ()
	if started then
		return
	end
	started = true
	helmHud = helmHudHandle
	fuelHud = fuelHudHandle
	carriedResourcesHud = carriedResourcesHudHandle
	notifyHandle = notify

	setHelmInputRemote = NetworkBridge.GetRemoteEvent(BlimpConstants.Network.RemoteNames.SetHelmInput)
	shiftSpeedRemote = NetworkBridge.GetRemoteEvent(BlimpConstants.Network.RemoteNames.ShiftSpeedState)
	toggleAutopilotRemote = NetworkBridge.GetRemoteEvent(BlimpConstants.Network.RemoteNames.ToggleAutopilot)
	dismountRemote = NetworkBridge.GetRemoteEvent(BlimpConstants.Network.RemoteNames.RequestDismount)

	local mountChangedRemote = NetworkBridge.GetRemoteEvent(BlimpConstants.Network.RemoteNames.MountChanged)
	mountChangedRemote.OnClientEvent:Connect(onMountChanged)

	-- Catch-up for the exact race BlimpConstants.Network.RemoteNames.GetCurrentMount's own header
	-- describes: Main.client.lua's boot is a long, synchronous chain of unrelated .Start() calls, and a
	-- fast player can already be standing at a wheel and pressing E before THIS line has even run --
	-- the server's mount succeeds regardless, but the one MountChanged broadcast for it fires into a
	-- connection that does not exist yet and is gone for good, leaving this client welded with no
	-- console and no steering until it dismounts and remounts. Pulled once, here, rather than polled: a
	-- client that was already listening in time (the overwhelming majority of mounts) gets back nil and
	-- this is a no-op. task.spawn so a slow round trip cannot itself delay the rest of Start().
	task.spawn(function()
		local ok, payload = pcall(function()
			local getCurrentMountRemote =
				NetworkBridge.GetRemoteFunction(BlimpConstants.Network.RemoteNames.GetCurrentMount)
			return getCurrentMountRemote:InvokeServer()
		end)
		if ok and payload then
			onMountChanged(payload)
		end
	end)

	local helmUpdatedRemote = NetworkBridge.GetRemoteEvent(BlimpConstants.Network.RemoteNames.HelmUpdated)
	helmUpdatedRemote.OnClientEvent:Connect(onHelmUpdated)

	local carriedFuelUpdatedRemote = NetworkBridge.GetRemoteEvent(GatheringConstants.RemoteNames.CarriedFuelUpdated)
	carriedFuelUpdatedRemote.OnClientEvent:Connect(onCarriedFuelUpdated)

	local fuelUpdatedRemote = NetworkBridge.GetRemoteEvent(BlimpConstants.Network.RemoteNames.FuelUpdated)
	fuelUpdatedRemote.OnClientEvent:Connect(onFuelUpdated)

	local fuelTransferRemote = NetworkBridge.GetRemoteEvent(BlimpConstants.Network.RemoteNames.FuelTransfer)
	fuelTransferRemote.OnClientEvent:Connect(onFuelTransfer)

	for _, tagged in CollectionService:GetTagged(BlimpConstants.Tags.Model) do
		if tagged:IsA("Model") then
			watchBlimpModel(tagged :: Model)
		end
	end
	CollectionService:GetInstanceAddedSignal(BlimpConstants.Tags.Model):Connect(function(instance: Instance)
		if instance:IsA("Model") then
			watchBlimpModel(instance :: Model)
		end
	end)

	-- THE BACKSTOP FOR THE PROMPT SUPPRESSION ABOVE, and the one thing in this module that does need a
	-- character edge. Un-suppressing is otherwise driven purely by the Active=false mount broadcast,
	-- and that broadcast carries the character it was ABOUT: a player who dies at the wheel can have
	-- their replacement character already installed by the time it lands, which makes `isLocal` false
	-- and skips the restore. Every other consequence of that (a stale camera, a stale cue) is cosmetic
	-- and self-corrects on the next mount -- a globally disabled ProximityPromptService does not. It
	-- would leave that player unable to interact with ANYTHING, anywhere in the game, for the rest of
	-- the session.
	--
	-- A raw CharacterAdded rather than Shared/PlayerLifecycle.BindLocalCharacter, deliberately: none of
	-- the three races that module exists to close apply here. This is not binding anything to the body,
	-- it does not touch the Humanoid, and it does not care which character it is -- a new body arriving
	-- is by itself proof the old mount is over.
	Players.LocalPlayer.CharacterAdded:Connect(function()
		setPromptsSuppressed(false)
	end)

	UserInputService.InputBegan:Connect(onInputBegan)
	-- NOT gated on gameProcessed, unlike InputBegan. A release must always be heard: a press that
	-- started the hold and a release that the GUI happened to swallow would leave the telegraph
	-- walking with nobody holding anything.
	UserInputService.InputEnded:Connect(onInputEnded)
	RunService.Heartbeat:Connect(pumpHelmInput)
	RunService.Heartbeat:Connect(pumpTelegraphHold)

	-- No PlayerLifecycle binding: this module holds no per-life state of its own. The local player's
	-- own mount is ended server-side on CharacterRemoving, and the dismount broadcast that follows is
	-- what clears localKind, the cue, the camera and the audio -- one path, already covered, rather
	-- than a second one here that could disagree with it.

	logger:info("BlimpController started")
end

return BlimpController
