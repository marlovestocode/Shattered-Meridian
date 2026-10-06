--!strict
--[[
	BoatController.lua

	Owns: everything about a boat that happens on a client -- the local helmsman's rudder (one held
	axis), their four edge presses, the per-frame pose for EVERY mounted character this client can see
	(hands on the wheel AND the body's lean), and re-keying the station prompts to this player's own
	Interact bind.

	DECIDES NOTHING. Server/Systems/BoatSystem.lua is the sole authority on who is mounted, who may
	steer, which rung the sails are on and where the hull goes; this module sends inputs and presents
	what the server says came back. Same posture, and for the same reasons, as
	Client/Blimp/BlimpController.lua sitting next door.

	THE POSE IS THE UNUSUAL PART and the reason this module is not simply an input file. Motor6D.
	Transform -- the only joint channel that can beat a playing idle clip -- does not replicate, so both
	the hands (Shared/Vessel/VesselArmPose.lua) and the lean (Shared/Vessel/VesselPilotPose.lua) have to
	be solved independently on every client that can see the body. That is why the mount broadcast is
	FireAllClients and why this module tracks a table of OTHER people's characters. Read
	Shared/Vessel/VesselArmPose.lua's header for the full argument; every word of it applies here.

	THE POSE RUNS ON BindToRenderStep AT Character + 1, not on Heartbeat, and that priority is load-
	bearing: the character/animation update runs at Enum.RenderPriority.Character, so anything earlier is
	simply overwritten by the idle clip on the same frame and the body flickers between two poses.

	EVERY POSED CHARACTER SAMPLES ITS OWN HULL, including the local player's -- so a body on a boat
	across the bay leans with THAT boat rather than with the one this client happens to be standing on.

	THE HELM CONTROLS ARE CONTEXTUAL, deliberately, and are the one place this module does not go through
	KeybindManager. A/D are the movement keys the player already has their hand on, which are not
	KeybindActions in this codebase at all (Roblox owns them, via the Humanoid's own control module).
	W/S, X and G join them on the same principle: they are read only while this client is holding a helm,
	are meaningless everywhere else, and are invisible to a rebind screen that has no notion of "while
	sailing". The one control that IS a bind, on one device, is the release press, which shares the
	Interact action with the prompt that started the mount. See BoatConstants.Controls.

	A PAD REACHES THE RUDDER THROUGH THE LEFT STICK AND THE FOUR PRESSES THROUGH THE FACE BUTTONS, and
	readHelmAxis SUMS the keyboard pair with Client/Input/Analog.Move() rather than branching on device.
	There is no `if gamepad then` anywhere in this file: a keyboard-only player's stick reads exactly
	Vector2.zero, so summing reproduces the keyboard behaviour bit for bit, and a player with both
	plugged in gets whichever they touched.

	HOLDING W OR S WALKS THE SAIL LADDER, and it is implemented here rather than server-side on purpose.
	The server's contract is one rung per request (VesselSpeedLadder.SanitizeDelta clamps a batched or
	dishonest delta down to one), so a repeat has to be a repeat of REQUESTS -- which means it belongs to
	the thing that can see the key still being held. The alternative, a "keep shifting until I say stop"
	message, would be the client asserting a duration, and a client that then crashed would leave a boat
	walking her own canvas to full with nobody aboard.

	THREE THINGS THE BLIMP HAS AND THIS DELIBERATELY DOES NOT, each a seam rather than a gap:
	  * A HELM PANEL. Client/UI/Screens/BlimpHelm is a 900-line console; a boat's equivalent wants a
	    wind vane and a point-of-sail readout, which is a different panel and not a re-skin. Everything
	    it would need is already resolved here and on the wire -- the sail rung and the hull mode arrive
	    on BoatTypes.HelmUpdatedPayload, and Shared/Boat/BoatWind.PointOfSail turns this client's own
	    reading of the wind into the word it would print. Adding one means giving Start a handle and
	    calling it from onHelmUpdated and applyPoses, not re-deriving anything.
	  * A BESPOKE CAMERA. An airship needs one because it banks, climbs and has no ground reference; a
	    boat sits on a plane and reads perfectly well through the stock chase camera.
	    Shared/Vessel/VesselMotion.lua is the sampler a boat camera would be built on, and this file
	    already holds one sample per mounted body.
	  * AUDIO. BoatConstants.Audio already authors the three speed bands and their dead band, and
	    Shared/Vessel/VesselSpeedStage.lua is the one-line binding that resolves them -- but nothing
	    binds it yet, deliberately, because a bound-but-unread module is an orphan. applyPoses below
	    already takes the per-frame speed sample a Client/FX/BoatAudio.lua would need.

	Does not own: the mount rules, the sailing integration, the sail ladder's rungs, or the prompts
	themselves (BoatSystem creates them server-side and owns which ones are Enabled for everybody -- this
	module only rewrites their KEY, locally).
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local BoatArmPose = require(ReplicatedStorage.Shared.Boat.BoatArmPose)
local BoatConstants = require(ReplicatedStorage.Shared.Boat.BoatConstants)
local BoatMotion = require(ReplicatedStorage.Shared.Boat.BoatMotion)
local BoatPilotPose = require(ReplicatedStorage.Shared.Boat.BoatPilotPose)
local BoatTypes = require(ReplicatedStorage.Shared.Boat.BoatTypes)
local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local VesselTypes = require(ReplicatedStorage.Shared.Vessel.VesselTypes)

local Analog = require(script.Parent.Parent.Input.Analog)
local KeybindManager = require(script.Parent.Parent.Input.KeybindManager)

local logger = Logger.scope("BoatController")

local BoatController = {}

local RENDER_STEP_NAME = "BoatPose"

local started = false
local setHelmInputRemote: RemoteEvent? = nil
local shiftSailRemote: RemoteEvent? = nil
local toggleAdriftRemote: RemoteEvent? = nil
local dismountRemote: RemoteEvent? = nil

-- One entry per mounted character this client can see, local player included. Keyed by character so the
-- two broadcasts that can arrive for one body (a fast dismount-then-remount at another station) collapse
-- to one entry rather than leaving a stale station behind.
--
-- Motion and Lean are allocated ONCE per body and mutated in place for the whole mount -- see
-- Shared/Vessel/VesselMotion.lua's and VesselPilotPose's own headers on why neither allocates per frame.
type PosedEntry = {
	Station: BasePart,
	Motion: BoatMotion.State,
	Lean: BoatPilotPose.State,
}

local posed: { [Model]: PosedEntry } = {}
-- Whether the pose render step is currently bound. Tracked rather than asked, because RunService has no
-- "is this name bound" query and re-binding an already-bound name errors.
local poseBound = false

-- Which station the LOCAL player is on, and of what kind -- nil when not mounted. Separate from `posed`
-- because only this one gates input, and reading it out of the shared table would mean a Players lookup
-- on every frame of steering.
local localKind: VesselTypes.StationKind? = nil

local lastSentHelm: BoatTypes.HelmInput = { Steer = 0 }
local sendAccumulator = 0

-- Which sail key is currently held (+1 for W, -1 for S, 0 for neither) and how long until the next
-- repeat fires. Only one direction can be held at a time by construction: pressing the opposite key
-- replaces it, which is also what a skipper means by mashing S after holding W.
local sailHeld = 0
local sailRepeatIn = 0

-- Prompt re-keying ------------------------------------------------------------------------------

-- The prompts are server-created (BoatSystem), so their KeyboardKeyCode is whatever the server set for
-- everybody. Rewriting it here is a purely local property change -- it does not replicate, and does not
-- need to: each client only ever reads its own.
local function reKeyPrompt(instance: Instance): ()
	if not instance:IsA("ProximityPrompt") then
		return
	end
	if instance.Name ~= BoatConstants.Prompt.StationPromptName then
		return
	end
	local bind = KeybindManager.Get("Interact")
	if bind.KeyCode then
		(instance :: ProximityPrompt).KeyboardKeyCode = bind.KeyCode :: Enum.KeyCode
	end
end

-- PROMPTS ARE OFF FOR THIS CLIENT WHILE IT IS MOUNTED, and this is what makes the release press
-- reachable at all -- the identical fix, for the identical reason, that
-- Client/Blimp/BlimpController.setPromptsSuppressed records in full. In short: the release shares the
-- Interact bind with the prompt that started the mount, BoatSystem disables only the ONE station you
-- took, and every other station on the same hull stays live within arm's reach of a welded body. The
-- press meant to release you gets eaten by whichever neighbouring prompt the engine decides is closest.
--
-- ProximityPromptService.Enabled is a CLIENT-LOCAL property, which is the whole reason the fix lives
-- here and not in BoatSystem: Prompt.Enabled is per-prompt and replicated, so a server turning off a
-- hull's prompts to free one helmsman's E key would take them away from everybody else aboard.
local function setPromptsSuppressed(suppressed: boolean): ()
	ProximityPromptService.Enabled = not suppressed
end

local function watchBoatModel(model: Model): ()
	for _, descendant in model:GetDescendants() do
		reKeyPrompt(descendant)
	end
	-- Prompts on a boat that is still streaming in arrive after this pass, which is the common case on a
	-- client rather than the exception -- the model replicates before everything inside it does.
	model.DescendantAdded:Connect(reKeyPrompt)
end

-- Steering --------------------------------------------------------------------------------------

-- One key pair as a signed axis. IsKeyDown is the right read here and only here -- both keys in the pair
-- are KEYBOARD keys by construction (BoatConstants.Controls' axis row carries no gamepad button, only
-- the stick the legend draws), so the keyboard-only trap that made KeybindManager.IsJumpKeyDown answer
-- false forever on a pad cannot apply.
local function keyAxis(binding: VesselTypes.HelmAxisBinding): number
	return (if UserInputService:IsKeyDown(binding.Positive) then 1 else 0)
		- (if UserInputService:IsKeyDown(binding.Negative) then 1 else 0)
end

-- The ONE held axis. The sail setting is a rung the server owns and is moved by an edge press
-- (onInputBegan below), never sampled here -- see BoatTypes.HelmInput.
--
-- SUMMED ACROSS DEVICES AND THEN CLAMPED, rather than picking one. The stick is Analog.Move(), whose X
-- is the rudder, already past the player's own deadzone and response curve; on a client with no pad
-- connected it is exactly Vector2.zero and this arithmetic collapses to the keyboard read.
--
-- Analog.Move's Y IS DELIBERATELY DISCARDED. On a blimp it is the elevator; a boat has no vertical
-- control at all, and the stick's forward axis is genuinely unused here rather than quietly bound to
-- something. Pushing forward on the stick does nothing, which is the honest behaviour for a vehicle
-- whose speed is the wind's.
local function readHelmAxis(): BoatTypes.HelmInput
	local stick = Analog.Move()
	return { Steer = math.clamp(keyAxis(BoatConstants.Controls.Steer) + stick.X, -1, 1) }
end

-- Sent on CHANGE only, rate-capped, with no keepalive: the server latches the last input it was given,
-- so a helmsman holding a steady rudder costs exactly one packet.
--
-- "CHANGED" IS A THRESHOLD, NOT AN EXACT COMPARISON, and the threshold is what preserves that sentence.
-- Keyboard axes are discrete -- three values, so equality means what it looks like it means. A
-- thumbstick's value differs at every sample, so an exact comparison would be true on every tick and a
-- player holding a perfectly steady stick would stream at IntentSendHz forever. See
-- BoatConstants.Input.HelmAxisEpsilon, which is a send resolution and deliberately not a deadzone.
local function pumpHelmInput(deltaTime: number): ()
	if localKind ~= "Helm" then
		return
	end
	local remote = setHelmInputRemote
	if not remote then
		return
	end

	sendAccumulator += deltaTime
	local interval = 1 / BoatConstants.Network.IntentSendHz
	if sendAccumulator < interval then
		return
	end
	sendAccumulator = 0

	local helm = readHelmAxis()
	if math.abs(helm.Steer - lastSentHelm.Steer) < BoatConstants.Input.HelmAxisEpsilon then
		return
	end
	lastSentHelm = helm
	remote:FireServer(helm)
end

-- Pose ------------------------------------------------------------------------------------------

-- One frame of pose for every mounted body on screen. Bound and unbound with the first/last entry
-- rather than left running for the session.
local function applyPoses(deltaTime: number): ()
	for character, entry in posed do
		if character.Parent == nil or entry.Station.Parent == nil then
			-- The dismount broadcast is the ordinary way an entry leaves this table; this catches the case
			-- where the body or the station simply stopped existing and no broadcast is coming.
			posed[character] = nil
			continue
		end

		-- Re-read every frame rather than stored on the entry -- AssemblyRootPart is re-elected by the
		-- engine whenever the assembly changes shape, which on a boat is every mount and dismount, and a
		-- client that has not yet received the hull's welds resolves the station as its own one-part
		-- assembly reporting ZERO velocity. A cached reference there leaves the body standing rigid for
		-- the whole voyage.
		local hull = entry.Station.AssemblyRootPart
		if hull then
			-- The shipped hull speed rather than this hull's own resolved tuning: the only field that
			-- reads it is SpeedFraction, which the lean does not use. A boat camera would want the real
			-- one (see this file's header), which is what BoatTagging.ResolveTuning is for.
			BoatMotion.Observe(
				entry.Motion,
				hull.CFrame,
				hull.AssemblyLinearVelocity,
				hull.AssemblyAngularVelocity,
				BoatConstants.Drive.HullSpeed,
				deltaTime
			)
		else
			-- A hull that stopped being readable relaxes the body upright rather than freezing it
			-- mid-lean.
			BoatMotion.Zero(entry.Motion)
		end

		-- ClimbRate here is the hull's HEAVE off the swell rather than a commanded climb -- one channel,
		-- because a body standing on the deck does not care which of the two lifted it. See
		-- Shared/Vessel/VesselMotion.Motion.ClimbRate.
		local motion = entry.Motion.Motion
		BoatPilotPose.Step(entry.Lean, motion.YawRate, motion.ForwardAccel, motion.ClimbRate, deltaTime)

		-- THE LEAN GOES ON FIRST and the hands are solved after, which is the whole ordering requirement
		-- between the two modules: VesselArmPose re-reads the torso's current world CFrame every frame,
		-- so a torso this frame's lean has already moved is the one it lands the hands against. Reversing
		-- these two would put the hands where the body used to be.
		BoatPilotPose.Apply(character, entry.Lean)
		if not BoatArmPose.Apply(character, entry.Station) then
			-- A rig this solver cannot pose (no arms, a custom avatar with renamed joints). Dropped rather
			-- than retried, so one unusual character does not cost every frame of the mount.
			posed[character] = nil
		end
	end
end

-- Bound only while at least one body needs posing. `posed` is empty for the overwhelming majority of any
-- session on any client, and a render step that exists to iterate an empty table sixty times a second is
-- a cost every player pays for a feature none of them are near.
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
	local payload = raw :: VesselTypes.MountChangedPayload
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
			lastSentHelm = { Steer = 0 }
			-- Cleared explicitly rather than left to the next InputEnded, which may never come: a player
			-- who dies at the wheel holding W gets a dismount broadcast and no key release at all, and a
			-- latched repeat would then walk the canvas of whatever ship they boarded next.
			sailHeld = 0
		end
		return
	end

	local station = payload.Station
	if typeof(station) ~= "Instance" or not station:IsA("BasePart") then
		return
	end
	-- station.AssemblyRootPart IS the hull root, with no lookup: every part of a boat is welded into one
	-- assembly by Server/Vessel/VesselAssembly.lua, so the station and the hull's root are members of the
	-- same rigid body by construction.
	posed[character] = {
		Station = station,
		Motion = BoatMotion.NewState(),
		Lean = BoatPilotPose.NewState(),
	}
	refreshPoseBinding()

	if isLocal then
		localKind = payload.Kind
		setPromptsSuppressed(true)
		-- Zeroed on mount, not carried: the axis the player happened to be holding when they walked up to
		-- the wheel is not a command to put the helm over.
		lastSentHelm = { Steer = 0 }
		sendAccumulator = 0
		sailHeld = 0
	end
end

-- Input -----------------------------------------------------------------------------------------

-- True while any modal UI panel is up (Components/ModalScreen.lua publishes the count as
-- AttributeConstants.UiModalOpen). The same gate AttackInputClient and GrabInputClient hold, for the
-- same reason: gameProcessedEvent only covers presses that LAND on the GUI, and a centred panel leaves
-- most of the viewport uncovered.
local function isModalUiOpen(): boolean
	local player = Players.LocalPlayer
	return player ~= nil and player:GetAttribute(AttributeConstants.UiModalOpen) == true
end

-- One rung, or furled outright on a delta of 0 -- VesselSpeedLadder.Shift owns both meanings
-- server-side, and this end deliberately sends the KEYPRESS rather than a target index.
local function sendSailShift(delta: number): ()
	local remote = shiftSailRemote
	if remote then
		remote:FireServer(delta)
	end
end

-- A sail key going down: one rung immediately, then the repeat arms behind the initial delay.
--
-- The immediate shift is what keeps a TAP exact -- the repeat delay is long enough that a tap ends
-- before it ever arms, so "one notch less canvas" is one notch and holding is a separate gesture.
local function beginSailHold(direction: number): ()
	sailHeld = direction
	sailRepeatIn = BoatConstants.Input.SailRepeatDelaySeconds
	sendSailShift(direction)
end

-- Called every Heartbeat while a sail key is held. Saturating at the end of the ladder is the server's
-- job (VesselSpeedLadder.Shift), so this keeps asking and the server keeps answering with the same rung
-- -- which costs one small packet every fifth of a second while a skipper leans on a key at full sail,
-- and buys not having to mirror the ladder's length and current position on the client just to know when
-- to stop.
local function pumpSailHold(deltaTime: number): ()
	if sailHeld == 0 then
		return
	end
	if isModalUiOpen() then
		-- A panel opened mid-hold. The key is still physically down, but a player who just opened their
		-- settings is not asking for full sail -- and unlike InputBegan, which is gated on this before a
		-- hold can ever start, the repeat has to keep checking. Held rather than dropped: closing the
		-- panel with the key still down resumes, which is what the player's hand is still saying.
		return
	end
	if localKind ~= "Helm" then
		-- Lost the wheel mid-hold (dismounted, died, was bumped off). Drop the repeat rather than firing
		-- into a remote that will reject it for the rest of the time the key stays down.
		sailHeld = 0
		return
	end

	sailRepeatIn -= deltaTime
	if sailRepeatIn > 0 then
		return
	end
	-- Reset rather than accumulated: a frame hitch longer than one interval should cost the skipper the
	-- rungs it swallowed, not hand them back all at once the moment the frame lands.
	sailRepeatIn = BoatConstants.Input.SailRepeatIntervalSeconds
	sendSailShift(sailHeld)
end

-- Whether `input` is the press that reaches `binding` on EITHER device -- the contextual counterpart of
-- KeybindManager.Matches, and the only thing in this file that knows a control has two columns.
--
-- BOTH COLUMNS ARE CHECKED UNCONDITIONALLY, with no read of which device is "current". Same reasoning as
-- readHelmAxis summing rather than branching: an InputObject already carries which physical input it
-- was, so a device check here could only ever disagree with the press in hand. The keyboard and gamepad
-- columns hold disjoint KeyCodes, so checking both is not ambiguous, merely thorough.
local function matchesControl(binding: VesselTypes.HelmPressBinding, input: InputObject): boolean
	if input.KeyCode == binding.Gamepad then
		return true
	end
	local keyboard = binding.Keyboard
	if keyboard then
		return input.KeyCode == keyboard
	end
	-- The Release row, whose keyboard half is the live Interact bind rather than a fixed key.
	local action = binding.Action
	return action ~= nil and KeybindManager.Matches(action, input)
end

local function onInputBegan(input: InputObject, gameProcessed: boolean): ()
	-- BUTTONA IS EXEMPTED FROM THE gameProcessed GATE, and this is a Roblox engine quirk rather than a
	-- BoatConstants reasoning error -- the identical carve-out Client/Blimp/BlimpController.onInputBegan
	-- documents in full. Roblox marks every gamepad ButtonA press as gameProcessedEvent = true
	-- unconditionally (its own GUI-navigation mode treats A like a confirm click), independent of jump,
	-- PlatformStand, or anything a game script can disable. Without this, SailDown -- the one control
	-- that spends ButtonA -- is silently unreachable on every pad while every other helm press works,
	-- which is exactly "everything but take canvas off". Safe to carve out unconditionally: nothing else
	-- in BoatConstants.Controls binds ButtonA, and localKind == nil below still bars it the instant the
	-- player is not at a helm.
	if (gameProcessed and input.KeyCode ~= Enum.KeyCode.ButtonA) or isModalUiOpen() then
		return
	end
	-- Declines to send what this client can already see is illegal. Not mounted, nothing to release or
	-- steer.
	if localKind == nil then
		return
	end

	if matchesControl(BoatConstants.Controls.Release, input) then
		local remote = dismountRemote
		if not remote then
			logger:warn("Release pressed before the dismount remote was ready")
			return
		end
		remote:FireServer()
		return
	end

	-- Everything below is the helmsman's alone. Checked here rather than per-key so a passenger's
	-- keypresses cost one comparison instead of four.
	if localKind ~= "Helm" then
		return
	end

	if matchesControl(BoatConstants.Controls.SailUp, input) then
		beginSailHold(1)
	elseif matchesControl(BoatConstants.Controls.SailDown, input) then
		beginSailHold(-1)
	elseif matchesControl(BoatConstants.Controls.Furl, input) then
		-- The panic key. Takes every sail off her from wherever the rung was, rather than making a
		-- skipper tap S past three rungs while the ship carries on toward whatever they just noticed.
		--
		-- Cancels any repeat first: pressing this WITH W still held is a skipper changing their mind
		-- mid-gesture, and leaving the repeat armed would walk the canvas straight back up the ladder
		-- they just took it off.
		sailHeld = 0
		sendSailShift(0)
	elseif matchesControl(BoatConstants.Controls.Adrift, input) then
		local remote = toggleAdriftRemote
		if remote then
			remote:FireServer()
		end
	end
end

-- Releasing either sail control stops the repeat -- but only the one that is actually driving it, so
-- letting go of W after having already pressed S does not cancel the S hold that replaced it.
local function onInputEnded(input: InputObject, _gameProcessed: boolean): ()
	-- Checked before either match, and it is the ONLY reason this connection is cheap. This fires for
	-- every key and button release anywhere in the game, mounted or not, and matchesControl is up to two
	-- comparisons each. The sails are not being held for the overwhelming majority of those releases.
	if sailHeld == 0 then
		return
	end
	local up = sailHeld > 0 and matchesControl(BoatConstants.Controls.SailUp, input)
	local down = sailHeld < 0 and matchesControl(BoatConstants.Controls.SailDown, input)
	if up or down then
		sailHeld = 0
	end
end

-- Lifecycle -------------------------------------------------------------------------------------

function BoatController.Start(): ()
	if started then
		return
	end
	started = true

	setHelmInputRemote = NetworkBridge.GetRemoteEvent(BoatConstants.Network.RemoteNames.SetHelmInput)
	shiftSailRemote = NetworkBridge.GetRemoteEvent(BoatConstants.Network.RemoteNames.ShiftSailState)
	toggleAdriftRemote = NetworkBridge.GetRemoteEvent(BoatConstants.Network.RemoteNames.ToggleAdrift)
	dismountRemote = NetworkBridge.GetRemoteEvent(BoatConstants.Network.RemoteNames.RequestDismount)

	local mountChangedRemote = NetworkBridge.GetRemoteEvent(BoatConstants.Network.RemoteNames.MountChanged)
	mountChangedRemote.OnClientEvent:Connect(onMountChanged)

	-- RESOLVED BUT NOT YET LISTENED TO, and deliberately resolved anyway. The helm snapshot is what a
	-- boat's own panel will read (see this file's header on the one screen this layer does not have
	-- yet); resolving it here means the remote is proven to exist at boot rather than the day somebody
	-- writes that panel and discovers the name never matched. NetworkBridge memoises lookups, so this
	-- costs one WaitForChild at start-up and nothing afterwards.
	NetworkBridge.GetRemoteEvent(BoatConstants.Network.RemoteNames.HelmUpdated)

	for _, tagged in CollectionService:GetTagged(BoatConstants.Tags.Model) do
		if tagged:IsA("Model") then
			watchBoatModel(tagged :: Model)
		end
	end
	CollectionService:GetInstanceAddedSignal(BoatConstants.Tags.Model):Connect(function(instance: Instance)
		if instance:IsA("Model") then
			watchBoatModel(instance :: Model)
		end
	end)

	-- THE BACKSTOP FOR THE PROMPT SUPPRESSION ABOVE, and the one thing in this module that needs a
	-- character edge. Un-suppressing is otherwise driven purely by the Active=false mount broadcast, and
	-- that broadcast carries the character it was ABOUT: a player who dies at the wheel can have their
	-- replacement character already installed by the time it lands, which makes `isLocal` false and skips
	-- the restore. Every other consequence of that is cosmetic and self-corrects on the next mount -- a
	-- globally disabled ProximityPromptService does not. It would leave that player unable to interact
	-- with ANYTHING, anywhere in the game, for the rest of the session.
	--
	-- A raw CharacterAdded rather than Shared/PlayerLifecycle.BindLocalCharacter, deliberately: none of
	-- the three races that module exists to close apply here. This is not binding anything to the body,
	-- it does not touch the Humanoid, and it does not care which character it is -- a new body arriving
	-- is by itself proof the old mount is over.
	Players.LocalPlayer.CharacterAdded:Connect(function()
		setPromptsSuppressed(false)
	end)

	UserInputService.InputBegan:Connect(onInputBegan)
	-- NOT gated on gameProcessed, unlike InputBegan. A release must always be heard: a press that started
	-- the hold and a release that the GUI happened to swallow would leave the sails walking with nobody
	-- holding anything.
	UserInputService.InputEnded:Connect(onInputEnded)
	RunService.Heartbeat:Connect(pumpHelmInput)
	RunService.Heartbeat:Connect(pumpSailHold)

	-- No PlayerLifecycle binding: this module holds no per-life state of its own. The local player's own
	-- mount is ended server-side on CharacterRemoving, and the dismount broadcast that follows is what
	-- clears localKind -- one path, already covered, rather than a second one here that could disagree.

	logger:info("BoatController started")
end

return BoatController
