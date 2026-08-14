--!strict
--[[
	CombatClient.lua

	Owns: the client's combat input surface -- captures the player's attack/block/parry/dash/
	sprint/lock-on/feint input and sends *requests* through NetworkBridge, never a computed outcome (CombatSystem
	server-side decides what actually happens -- engineering-standards.md's server-authoritative
	rule; luau-coding-standards.md's server/client split: "a client module should never contain a
	function named something like ApplyDamage -- it should contain RequestAttack"). Also owns
	translating CombatSystem's feedback remotes (Combat_FeedbackEvent, Combat_LockOnChanged) into
	calls against the CombatFeedback screen's handle -- the same "already-computed value in,
	presentation out" boundary that handle's own components already document, and the per-frame
	world-to-screen projection LockOnReticle.lua's header names as "a future client-side aim/camera
	module's job." Also listens for Combat_AttackStarted, driving FX/SwingEffect.lua's asset-free
	camera punch -- see that listener's own comment for why (a real windup/active/recovery-timed
	animation is still a future animation/FX module's job; this is a placeholder-quality stand-in
	for one, not a replacement).

	Also owns translating the SAME Combat_FeedbackEvent's Kind == "Death" case into calls against
	Screens/DeathFeed's own handle (ShowDeath/ClearDeath) and Client/FX/DeathEffect.lua's screen dip
	-- gated to the payload's TargetUserId being the local player, since confirmDeath
	(CombatSystem.lua) sends this exact payload to both the victim and the killer and only the
	victim's own screen should ever show the overlay or dip. ClearDeath/DeathEffect.Clear() are
	called from this file's own localPlayer.CharacterAdded handler, the same "respawn ends the
	per-life presentation state" hook clearLockOnPresentation and bindLocalCharacter's mirror
	reset already use.

	Logging (Logger.scope("CombatClient"), Studio-only per Logger.lua) covers remote lookups, every
	input->request mapping, every FireServer call, and every inbound feedback/lock-on/attack-started
	payload -- see this file's log call sites for the exact fields. None of it is gameplay logic;
	removing every log call would not change this module's behavior.

	Does not own: ClientState's Health/Posture wiring -- that's ClientState.Bootstrap()'s
	job (docs/ui-ux-philosophy.md: "every field... written to exclusively by a NetworkBridge remote
	handler inside Bootstrap()"). Does not own rendering -- CombatFeedback/HUD render whatever
	state this module (or Bootstrap) hands them; this module never creates an Instance itself.
	Does not own hit/damage computation -- every request here is just intent, and every feedback
	value rendered here is a server-reported fact, never a client guess.

	Input bindings are resolved through Client/Input/KeybindManager.lua (Constants.Keybinds.Defaults
	for the shipped defaults) rather than hardcoded here -- docs/ui-ux-philosophy.md governs the
	visual language these actions feed into, not the specific keys, and KeybindManager.lua is what
	lets those keys be rebound later without touching this module.

	Also owns the HotbarSlot1-5 keybinds (the number row) -- unlike every other action above, these
	carry no combat request of their own: a press just resolves which of the 5 hotbar slots matched
	and hands off to Client/Combat/HotbarMoveClient.lua's Fire(slot), the same call
	Client/UI/Screens/HUD/init.lua's AbilitySlot click handler makes, so the actual remote-call logic
	lives in exactly one place regardless of which input path triggered it. See HotbarMoveClient.lua's
	own header for why this is effectively admin-only despite having no admin check of its own here.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local Logger = require(ReplicatedStorage.Shared.Logger)

local CombatFeedbackModule = require(script.Parent.Parent.UI.Screens.CombatFeedback)
local DeathFeedModule = require(script.Parent.Parent.UI.Screens.DeathFeed)
local KeybindManager = require(script.Parent.Parent.Input.KeybindManager)
local CombatAudio = require(script.Parent.Parent.FX.CombatAudio)
local StunEffect = require(script.Parent.Parent.FX.StunEffect)
local DeathEffect = require(script.Parent.Parent.FX.DeathEffect)
local SwingEffect = require(script.Parent.Parent.FX.SwingEffect)
local CombatAnimator = require(script.Parent.Parent.FX.CombatAnimator)
local CameraShake = require(script.Parent.Parent.FX.CameraShake)
local HitStop = require(script.Parent.Parent.FX.HitStop)
local HitFlash = require(script.Parent.Parent.FX.HitFlash)
local FOVOffset = require(script.Parent.Parent.FX.FOVOffset)
local MovementVFX = require(script.Parent.Parent.FX.MovementVFX)
local SlamImpactVFX = require(script.Parent.Parent.FX.SlamImpactVFX)
local PredictionMirror = require(script.Parent.PredictionMirror)
local HotbarMoveClient = require(script.Parent.HotbarMoveClient)
local Tokens = require(script.Parent.Parent.UI.Tokens)
local EmoteWheelClient = require(script.Parent.Parent.Emotes.EmoteWheelClient)
-- The Parkour System's orchestrator. This module reaches into it for exactly two things -- pushing
-- sprint state (which this module still owns) and asking whether parkour is handling the Slide key --
-- and ParkourController deliberately does NOT require this module back, so there is no cycle: the
-- dependency runs combat -> parkour only. See ParkourController.lua's own header for why sprint stays
-- here rather than moving into that framework.
local ParkourController = require(script.Parent.Parent.Parkour.ParkourController)
-- The Run System's presentation owner. Same relationship as ParkourController above and for the same
-- reason: sprint ENGAGEMENT stays owned here (the remotes, hold-vs-toggle, Autorun), and the boolean
-- is pushed outward to every consumer that needs it -- the parkour framework, the dust trickle, and
-- now the run controller, which turns it into footsteps, the stage animation and the stage FOV pull.
-- RunController does not require this module back.
local RunController = require(script.Parent.Parent.Movement.RunController)

type CombatFeedbackHandle = CombatFeedbackModule.CombatFeedbackHandle
type DeathFeedHandle = DeathFeedModule.DeathFeedHandle

local RemoteNames = Constants.Combat.RemoteNames

local logger = Logger.scope("CombatClient")

-- Studs added on top of a target's root-part height when placing combat feedback (damage numbers,
-- "PARRIED") -- see this constant's use site for why a fixed offset rather than a real Head lookup.
-- Now Constants.Combat.FeedbackHeadOffset -- see that field's own header in Constants.lua.
local TARGET_HEAD_OFFSET = Constants.Combat.FeedbackHeadOffset

-- Slot number -> KeybindAction, for the hotbar InputBegan branch below -- index-keyed rather than
-- one elseif per slot, since all 5 branches do exactly the same lookup-and-fire (see
-- HotbarMoveClient.Fire) with nothing slot-specific about the logic itself.
local HOTBAR_SLOT_ACTIONS: { Types.KeybindAction } =
	{ "HotbarSlot1", "HotbarSlot2", "HotbarSlot3", "HotbarSlot4", "HotbarSlot5" }

local CombatClient = {}

local currentLockOnUserId: number? = nil

-- The Autorun setting (Types.PlayerSettings.Autorun), owned by Client/Settings/SettingsClient.lua and
-- pushed in through CombatClient.SetAutoSprint below. Module-level rather than a Start() parameter
-- because it can flip at any time from the Settings panel, long after Start has run. Sprint itself
-- stays entirely CombatClient's concern -- SettingsClient never touches a sprint remote, an
-- animation, or the FOV/dust fan-out; it only says whether the setting is on.
local autoSprintEnabled = false
-- Assigned by Start (to its own syncSprint) so SetAutoSprint can re-evaluate immediately against
-- live movement state. Nil before Start, which SetAutoSprint tolerates -- the restored value is
-- simply read on the first movement transition after Start instead.
local onAutoSprintChanged: (() -> ())? = nil

-- Turns auto-sprint (the Autorun setting) on/off. With it on, sprint engages automatically whenever
-- there's real movement input and disengages when movement stops, exactly as if the player were
-- holding the Sprint key -- same request, same running animation, dust and FOV zoom, and Slide stays
-- available throughout. Holding the Sprint key still works normally alongside it.
function CombatClient.SetAutoSprint(enabled: boolean): ()
	if autoSprintEnabled == enabled then
		return
	end
	autoSprintEnabled = enabled
	logger:debug("Auto-sprint setting changed", { enabled = enabled })
	if onAutoSprintChanged then
		onAutoSprintChanged()
	end
end

-- Hold-to-sprint versus toggle-to-sprint (Types.ParkourSettings.SprintMode), owned by
-- Client/Settings/SettingsClient.lua and pushed in here, exactly like autoSprintEnabled above and for
-- the same reason (it can flip from the Settings panel long after Start has run).
--
-- Lives in CombatClient rather than in the parkour framework even though it is surfaced under that
-- feature's Settings section, because sprint itself has always been this module's: it owns the sprint
-- remotes, the server-side WalkSpeed tier they drive, the running animation, the dust trickle, the FOV
-- zoom and the Slide gate. Interpreting the sprint KEY somewhere else would mean two modules deciding
-- whether a player is sprinting -- see ParkourController.lua's own header on why that split is the
-- thing this integration most needed to avoid.
local sprintToggleMode = false
-- Live toggle state, meaningful only while sprintToggleMode is true. Reset whenever the mode changes
-- so switching modes mid-session can never leave a player stuck sprinting with no key held.
local sprintToggledOn = false
local onSprintModeChanged: (() -> ())? = nil

-- Switches between hold-to-sprint (press = on, release = off) and toggle-to-sprint (press = flip).
function CombatClient.SetSprintMode(mode: Types.SprintMode): ()
	local nextToggleMode = mode == "Toggle"
	if sprintToggleMode == nextToggleMode then
		return
	end
	sprintToggleMode = nextToggleMode
	sprintToggledOn = false
	logger:debug("Sprint mode changed", { mode = mode })
	if onSprintModeChanged then
		onSprintModeChanged()
	end
end

-- Timestamp of the last W (forward-movement) key press, for the dedicated double-tap-W listener
-- further below -- os.clock() of 0 (module load time) is never within DoubleTapDashWindowSeconds
-- of any real press, so the very first W press in a session can never accidentally read as a
-- double-tap. The Dash KEYBIND (Q, gamepad ButtonB) never participates in this double-tap gesture
-- -- see that branch's own comment for why -- so there is no separate tracker for it.
local lastWPressTime = 0

local function getRemote(name: string): RemoteEvent
	logger:trace("Remote lookup start", { name = name })
	local remote = NetworkBridge.GetRemoteEvent(name)
	logger:debug("Remote lookup success", { name = name })
	return remote
end

local function fireRequest(remote: RemoteEvent, actionName: string): ()
	logger:debug("FireServer", { action = actionName })
	remote:FireServer()
end

local function getRootPart(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if rootPart and rootPart:IsA("BasePart") then
		return rootPart
	end
	return nil
end

-- Resolve a feedback payload's UserId to that player's live character Model, for HitFlash's
-- body-flash adornee. Returns nil for an absent player/character (a training dummy has no
-- TargetUserId to resolve from -- its flash is simply skipped, matching HitFlash's own contract).
local function getCharacter(userId: number?): Model?
	if not userId then
		return nil
	end
	local player = Players:GetPlayerByUserId(userId)
	local character = player and player.Character
	if character and character.Parent then
		return character
	end
	return nil
end

-- Scale-based (0-1 across the viewport) to match LockOnReticle.lua's LockOnTargetDisplay contract
-- and DamageNumberLabel's Position prop, both of which are UDim2 in scale-space so they stay
-- correct across resolutions. Returns nil if the position is behind the camera or the viewport
-- isn't ready yet -- callers treat that as "don't show this."
local function worldPositionToScreenUDim2(position: Vector3): UDim2?
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end

	local screenPoint, onScreen = camera:WorldToViewportPoint(position)
	if not onScreen then
		return nil
	end

	local viewportSize = camera.ViewportSize
	if viewportSize.X <= 0 or viewportSize.Y <= 0 then
		return nil
	end

	return UDim2.fromScale(screenPoint.X / viewportSize.X, screenPoint.Y / viewportSize.Y)
end

function CombatClient.Start(combatFeedback: CombatFeedbackHandle, deathFeed: DeathFeedHandle): ()
	logger:info("CombatClient.Start called")

	local localPlayer = Players.LocalPlayer

	-- Roblox's own default PlayerModule/ControlModule is left unmanaged by this project the same way
	-- the default "Animate"/"Health" character scripts are (see StarterCharacterScripts/
	-- Health.server.lua's own header) -- WASD movement never routes through this file at all, which
	-- is exactly why PlatformStand/WalkSpeed alone (CombatSystem.lua's confirmDeath, server-side)
	-- don't stop a dead player from still walking: the stock Animate script's walk/run loop watches
	-- Humanoid.MoveDirection, and the default ControlModule keeps feeding that from live WASD input
	-- completely independent of PlatformStand or WalkSpeed. Disabling/enabling the default Controls
	-- object around the death window is what actually stops that -- see setControlsEnabled below.
	-- pcall-guarded: PlayerModule is an engine default this project doesn't own or track in source,
	-- not something to trust blindly (a future Roblox engine change, or a project that later DOES
	-- replace PlayerModule, must degrade to "no lockout" here rather than erroring this whole module).
	local playerControls: any = nil
	do
		local ok, controlsOrError = pcall(function()
			local playerScripts = localPlayer:WaitForChild("PlayerScripts")
			local playerModule = require(playerScripts:WaitForChild("PlayerModule") :: ModuleScript)
			return (playerModule :: any):GetControls()
		end)
		if ok then
			playerControls = controlsOrError
		else
			logger:warn(
				"PlayerModule Controls unavailable -- dead-player movement lockout degraded",
				{ errorMessage = tostring(controlsOrError) }
			)
		end
	end

	-- See playerControls' own declaration above. Both directions are pcall-guarded the same way --
	-- Controls:Disable()/Enable() are engine API this module doesn't own the implementation of.
	local function setControlsEnabled(enabled: boolean): ()
		if not playerControls then
			return
		end
		pcall(function()
			if enabled then
				playerControls:Enable()
			else
				playerControls:Disable()
			end
		end)
	end

	local requestBasicAttack = getRemote(RemoteNames.RequestBasicAttack)
	local requestHeavyAttack = getRemote(RemoteNames.RequestHeavyAttack)
	local requestBlockStart = getRemote(RemoteNames.RequestBlockStart)
	local requestBlockStop = getRemote(RemoteNames.RequestBlockStop)
	local requestDash = getRemote(RemoteNames.RequestDash)
	local requestSlide = getRemote(RemoteNames.RequestSlide)
	local requestSprintStart = getRemote(RemoteNames.RequestSprintStart)
	local requestSprintStop = getRemote(RemoteNames.RequestSprintStop)
	local requestLockOn = getRemote(RemoteNames.RequestLockOn)
	local requestSwapWeapon = getRemote(RemoteNames.RequestSwapWeapon)
	local requestFeint = getRemote(RemoteNames.RequestFeint)

	local feedbackEvent = getRemote(RemoteNames.FeedbackEvent)
	local killFeedEvent = getRemote(RemoteNames.KillFeed)
	local lockOnChanged = getRemote(RemoteNames.LockOnChanged)
	local attackStarted = getRemote(RemoteNames.AttackStarted)
	local blockStarted = getRemote(RemoteNames.BlockStarted)
	local movementPerformed = getRemote(RemoteNames.MovementPerformed)
	local slidePerformed = getRemote(RemoteNames.SlidePerformed)
	local comboStateChanged = getRemote(RemoteNames.ComboStateChanged)
	local weaponChanged = getRemote(RemoteNames.WeaponChanged)
	local actionRejected = getRemote(RemoteNames.ActionRejected)
	local parryWindowOpened = getRemote(RemoteNames.ParryWindowOpened)
	local feintPerformed = getRemote(RemoteNames.FeintPerformed)

	-- Read-only local mirror of THIS client's own server-side action timeline, fed by the confirm/
	-- feedback remotes below and consulted at press time to decide whether to predict action-start
	-- feedback (see PredictionMirror.lua). Never authoritative; a wrong guess costs one rolled-back
	-- animation, never a gameplay outcome.
	local mirror = PredictionMirror.New()

	-- Rollback bookkeeping for a predicted action awaiting its server answer. Only one predictable
	-- action is ever mid-flight (the mirror holds the shared commitment gate closed for the
	-- round-trip via OnPredictionPending), so a single slot suffices. The generation guards the
	-- timeout fallback: an earlier prediction's timer must not roll back a newer prediction that has
	-- already been confirmed and re-predicted in the meantime (same pattern as jumpSuppressGeneration).
	local predictionGeneration = 0
	local pendingPrediction: { Generation: number, Kind: "Swing" | "Dash" | "Slide" }? = nil

	local function rollbackPrediction(kind: "Swing" | "Dash" | "Slide"): ()
		if kind == "Swing" then
			CombatAnimator.CancelPredictedSwing()
		elseif kind == "Dash" then
			CombatAnimator.CancelPredictedDash()
		else
			CombatAnimator.CancelPredictedSlide()
		end
	end

	-- Guards the deferred "Buffered" swing prediction below. A press whose gate opens within the
	-- server's input-buffer window arms a delayed prediction rather than an immediate one; a SECOND
	-- press inside that same window would otherwise arm a second delayed callback and both would
	-- fire at gate-open, playing the swing feedback twice for one server-side swing (the server
	-- buffers only one press). Every arm bumps this, and each callback runs only if it is still the
	-- newest -- the same generation-stamp pattern beginPrediction uses for its own timeout.
	local bufferedSwingGeneration = 0

	-- Records a just-played prediction and arms its timeout fallback. Holds the mirror's commitment
	-- gate closed so a second predictable press during the round-trip can't also predict. If neither
	-- the confirm echo nor a reject arrives within Prediction.TimeoutSeconds, the predicted feedback
	-- rolls back so a dropped/never-answered request can't strand a pose.
	local function beginPrediction(kind: "Swing" | "Dash" | "Slide"): ()
		predictionGeneration += 1
		local generation = predictionGeneration
		pendingPrediction = { Generation = generation, Kind = kind }
		mirror:OnPredictionPending(os.clock())
		task.delay(Constants.Combat.Prediction.TimeoutSeconds, function()
			if pendingPrediction and pendingPrediction.Generation == generation then
				logger:debug("Prediction timed out -- rolling back", { kind = kind, generation = generation })
				pendingPrediction = nil
				rollbackPrediction(kind)
			end
		end)
	end

	-- Consumes a pending prediction when its server confirmation arrives, returning whether one was
	-- actually pending for `kind` -- the confirm handlers use that to avoid re-firing the FOV punch
	-- (already fired at predict time) while still firing it for a NOT-predicted (buffered) press.
	local function consumePendingPrediction(kind: "Swing" | "Dash" | "Slide"): boolean
		if pendingPrediction and pendingPrediction.Kind == kind then
			pendingPrediction = nil
			return true
		end
		return false
	end

	-- The Dash prediction, shared by the Dash keybind and the double-tap-W trigger (both fire the
	-- same RequestDash). Predicts the Dash clip immediately when the mirror says the server will
	-- accept it; a reject/timeout rolls it back. viaDoubleTapForward mirrors what this same press
	-- will report to the server (rawViaDoubleTapForward) -- only the double-tap-W trigger passes
	-- true, matching handleDashRequest's own attemptedFrontDash gate: whenever it's true, the press
	-- unambiguously means forward intent (that's the whole gesture), so both the mirror's cooldown
	-- check and CombatAnimator's own animation pick trust the flag directly instead of re-deriving
	-- "is this a front dash" from a live MoveDirection read -- see CombatAnimator.PlayPredictedDash's
	-- own header for why that read is racy at exactly this instant.
	local function predictDash(viaDoubleTapForward: boolean): ()
		local now = os.clock()
		if mirror:EvaluateDash(now, viaDoubleTapForward) == "Predict" then
			CombatAnimator.PlayPredictedDash(viaDoubleTapForward)
			beginPrediction("Dash")
		end
	end

	-- Local record of whether THIS client's own Sprint key is currently held -- pure local input
	-- state, not server-echoed (see PredictionMirror.EvaluateSlide's own header for why this is a
	-- parameter rather than a mirrored field). Set by the Sprint InputBegan/InputEnded branches
	-- below. NOT the Slide gate on its own any more -- see sprintEngaged below.
	local sprintKeyHeld = false

	-- Whether sprint is actually engaged right now, by EITHER route: the held Sprint key above, or
	-- the Autorun setting (Client/Settings/SettingsClient.lua) auto-engaging it whenever there's real
	-- movement input. This -- not sprintKeyHeld -- is what Slide gates on and what predictSlide feeds
	-- PredictionMirror.EvaluateSlide, so a slide works identically whether the player is sprinting by
	-- holding the key or by having Autorun on. The server re-checks state.sprinting regardless.
	local sprintEngaged = false
	-- Whether the local humanoid currently has real movement input, tracked off MoveDirection so
	-- Autorun can engage/disengage sprint on the movement transition rather than polling per frame.
	local autoSprintMoving = false
	-- That MoveDirection subscription, held so it can be dropped and rebound per character.
	local autoSprintMoveConnection: RBXScriptConnection? = nil

	-- The Slide press: chained off Sprint, so the keybind branch below only calls this while
	-- sprintEngaged is already true. Fires the FX/camera fan-out (dust burst, FOV kick, camera
	-- shake) at PREDICT time, same as SwingEffect's own combat punch -- never rolled back on
	-- reject/timeout (only the animation track is), matching that existing "the FOV punch is
	-- deliberately never rolled back" precedent.
	local function predictSlide(): ()
		local now = os.clock()
		if mirror:EvaluateSlide(now, sprintEngaged) == "Predict" then
			CombatAnimator.PlayPredictedSlide()
			MovementVFX.PlaySlideBurst()
			FOVOffset.Punch(
				"SlideKick",
				Constants.Camera.Slide.FOVPunchDelta,
				Constants.Camera.Slide.FOVPunchOutSeconds,
				Constants.Camera.Slide.FOVPunchBackSeconds
			)
			CameraShake.Shake(Constants.FX.CameraShake.SlideStart)
			beginPrediction("Slide")
		end
	end

	-- Generation counters guard the delayed banner clears below (PostureBreak/Disarmed) against a
	-- stale timer stomping a fresher banner -- e.g. two posture-breaks landing within
	-- PostureBreakDuration of each other would otherwise let the first one's timer hide the
	-- second's banner early. Only the clear scheduled by the MOST RECENT trigger is allowed to fire.
	local postureBreakGeneration = 0
	local disarmedGeneration = 0

	-- Finisher jump-suppression. Three layers -- relying on only the first two still let the player
	-- actually jump right after a successful Uppercut, if they kept holding the jump button through
	-- the throw (a very natural thing to do, since it's also what selects Uppercut in the first
	-- place). "The jump button" is Space on keyboard OR gamepad ButtonA (Roblox's own default jump
	-- binding for each device -- see KeybindManager.IsJumpKeyDown) throughout this system:
	--
	-- 1. REACTIVE (authoritative): once the M1 combo's finisher is ready (server-synced over
	--    Combat_ComboStateChanged after 3 hits land), Jumping is disabled so pressing the jump
	--    button on the 4th hit fires the Uppercut (RequestBasicAttack with holdingJump = true)
	--    instead of a jump.
	-- 2. PROACTIVE (local prediction, UX only): the moment THIS client fires any Basic (non-heavy)
	--    attack request, Jumping is disabled immediately for Constants.Combat.ComboResetSeconds,
	--    refreshed on every subsequent Basic throw in the same string. Without this, a player who
	--    starts holding the jump button in anticipation of the finisher gets a real, visible jump
	--    the instant they press it, because layer 1 only activates AFTER the server confirms the
	--    3rd hit landed and that confirmation round-trips back over the network; holding the button
	--    even slightly before that lands a real jump first.
	-- 3. RELEASE-GATED RE-ENABLE: layers 1 and 2 both eventually want to turn Jumping back on (the
	--    finisher was thrown, or the prediction window lapsed) -- but if the player is STILL
	--    physically holding the jump button at that exact moment (extremely likely: they held it
	--    through the whole 4th-press gesture and haven't let go yet), Roblox's own default character
	--    controller sees "jump input still down, character grounded, Jumping just became allowed
	--    again" and jumps immediately, with no fresh press needed -- reads as "I jump right after he
	--    goes up." Re-enabling is deferred (tryReenableJump) until the jump button is actually
	--    released (InputEnded), closing this without needing anything from the server.
	local localHumanoid: Humanoid? = nil
	local finisherReady = false
	local jumpSuppressGeneration = 0
	local jumpKeyHeld = false
	-- True from the moment the LOCAL player's own Death feedback arrives (see the Kind == "Death"
	-- branch below) until their next CharacterAdded (respawn) -- gates the InputBegan handler below so
	-- a dead player's input does nothing at all: no wasted RequestX remotes for CombatSystem.lua to
	-- reject server-side, and no optimistic local prediction (swing animation/VFX/FOV punch) playing
	-- against a corpse the server has already confirmed dead. Server-side state.alive checks already
	-- make every one of these actions a no-op gameplay-wise; this is purely about not letting a dead
	-- player's screen/input still DO anything in the meantime.
	local isLocalPlayerDead = false

	-- Whether the LOCAL player is currently eligible to Slide: real held movement input AND that
	-- input isn't predominantly BACKWARD relative to facing. Mirrors the server's own
	-- Movement.IsMoving/ResolveDashDirection dot-product math (the server is still authoritative --
	-- handleSlideRequest independently re-checks both) -- this only exists so the client doesn't
	-- fire/predict a Slide doomed to reject, the same "don't show a slide that's about to be
	-- rejected" reasoning sprintKeyHeld's own header already documents. Closes two real gaps
	-- sprintKeyHeld alone left open: (1) holding Sprint and tapping C with NO movement key held at
	-- all still predicted a slide (sprintKeyHeld says nothing about actual movement), and (2) Slide
	-- is no longer a legal way to move backward at all -- see handleSlideRequest's own header for why.
	local function canSlideLocally(): boolean
		if not localHumanoid then
			return false
		end
		local rootPart = getRootPart(localPlayer)
		if not rootPart then
			return false
		end
		local moveDirection = localHumanoid.MoveDirection
		if moveDirection.Magnitude < Constants.Combat.MovementInputMagnitudeThreshold then
			return false
		end
		local rootCFrame = rootPart.CFrame
		local forwardComponent = moveDirection:Dot(rootCFrame.LookVector)
		local rightComponent = moveDirection:Dot(rootCFrame.RightVector)
		local isBackward = math.abs(forwardComponent) >= math.abs(rightComponent) and forwardComponent < 0
		return not isBackward
	end

	-- The single place sprint is turned on/off, whichever route asked for it (held Sprint key, or the
	-- Autorun setting reacting to movement). Both routes need the identical four-call fan-out --
	-- request + running animation + dust trickle + FOV zoom -- so neither one duplicates it.
	--
	-- Edge-triggered on purpose: only a real off->on/on->off transition sends anything. That keeps
	-- Autorun from re-firing RequestSprintStart every time MoveDirection wobbles, and means a sprint
	-- the server REJECTS (Ragdolled) isn't retried on the next wobble either -- it stays disengaged
	-- until movement actually stops and restarts, the direct analogue of the key path's own
	-- "until they release and re-press Sprint" limitation documented in the Sprint reject branch.
	local function syncSprint(): ()
		-- Three routes into "sprint is intended," resolved in one place: the held key (Hold mode), the
		-- toggle latch (Toggle mode -- see CombatClient.SetSprintMode), and Autorun. The two sprint-mode
		-- routes are mutually exclusive by construction (only one of the two flags is ever written,
		-- depending on the live mode), so they can safely be OR-ed rather than branched on here.
		local intended = sprintKeyHeld or sprintToggledOn or (autoSprintEnabled and autoSprintMoving)
		if intended == sprintEngaged then
			-- Still pushed even on a no-op transition: ParkourController re-reads this every frame and a
			-- missed push would leave the movement framework's own view of sprint stale for as long as
			-- the state happened not to change.
			ParkourController.SetSprinting(intended)
			-- Same reasoning for the run controller: its footstep loop gates on this every frame.
			RunController.SetSprinting(intended)
			return
		end
		sprintEngaged = intended
		-- The Parkour System and the Run System both read sprint rather than owning it -- see
		-- ParkourController.lua's and RunController.lua's own headers. Pushed here, in the one place
		-- sprint actually changes, so every consumer (MovementVFX below, the movement framework, the run
		-- presentation) is fed from the same transition.
		ParkourController.SetSprinting(intended)
		RunController.SetSprinting(intended)
		if intended then
			-- Client-predicted, same as the request itself -- see CombatAnimator.StartRunning's own
			-- comment for why this doesn't wait on a server round-trip.
			fireRequest(requestSprintStart, "RequestSprintStart")
			CombatAnimator.StartRunning()
			MovementVFX.SetSprinting(true)
			FOVOffset.SetContinuous("Sprint", Constants.Camera.Sprint.FOVDelta, Constants.Camera.Sprint.FOVEaseSpeed)
		else
			fireRequest(requestSprintStop, "RequestSprintStop")
			CombatAnimator.StopRunning()
			MovementVFX.SetSprinting(false)
			-- Smooth ease-out, not a hard cut -- ClearContinuous is reserved for teardown (see its own
			-- header); a normal stop should settle back to 0 the same way it eased up to FOVDelta.
			FOVOffset.SetContinuous("Sprint", 0, Constants.Camera.Sprint.FOVEaseSpeed)
		end
	end

	-- Lets CombatClient.SetAutoSprint (called by SettingsClient when the Autorun toggle flips, and
	-- once at boot from the restored profile) re-evaluate against live movement without reaching
	-- into this closure's locals.
	onAutoSprintChanged = syncSprint
	-- Same mechanism for the sprint-mode setting: flipping Hold <-> Toggle clears the toggle latch (see
	-- SetSprintMode), and this re-evaluates immediately so a player who was mid-toggle-sprint when they
	-- switched modes stops sprinting right away rather than on their next movement transition.
	onSprintModeChanged = syncSprint

	local function setJumpEnabled(enabled: boolean): ()
		if localHumanoid then
			localHumanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, enabled)
		end
	end

	-- Re-enables Jumping only if nothing is still holding it back -- the jump button must be
	-- physically released (see layer 3 above), and neither layer 1 nor 2 can currently want it
	-- suppressed either. Called from: the proactive window's own expiry, the reactive
	-- finisherReady-false transition, and the jump button's own InputEnded (so releasing it after
	-- everything else already cleared re-enables immediately instead of waiting on a timer).
	local function tryReenableJump(): ()
		if not jumpKeyHeld and not finisherReady then
			setJumpEnabled(true)
		end
	end

	-- Called on every accepted Basic-attack press. Keeps Jumping disabled through the whole combo
	-- string (not just the final finisher-ready instant), re-enabling only once neither this local
	-- prediction window nor the server-confirmed finisherReady state still wants it suppressed (and
	-- the jump button has actually been released -- see tryReenableJump).
	local function suppressJumpThroughCombo(): ()
		jumpSuppressGeneration += 1
		local generation = jumpSuppressGeneration
		setJumpEnabled(false)
		task.delay(Constants.Combat.ComboResetSeconds, function()
			if jumpSuppressGeneration == generation then
				tryReenableJump()
			end
		end)
	end

	local function bindLocalCharacter(character: Model): ()
		local humanoidInstance = character:WaitForChild("Humanoid", 5)
		-- WaitForChild yields; if the character was already replaced (rapid respawn) while we waited,
		-- don't bind the stale one over the newer character's handler.
		if not humanoidInstance or not humanoidInstance:IsA("Humanoid") or localPlayer.Character ~= character then
			return
		end
		localHumanoid = humanoidInstance
		finisherReady = false
		-- A fresh character has no combo/cooldown/threat state -- reset the mirror to the same
		-- fresh-spawn baseline the server's createFreshState uses, and drop any in-flight prediction
		-- bookkeeping so a pre-respawn timeout can't roll back a post-respawn action.
		mirror:Reset()
		pendingPrediction = nil
		jumpSuppressGeneration += 1 -- invalidate any pending re-enable scheduled for the old character
		-- Resync from ground truth rather than trusting the incrementally-tracked flag across a
		-- respawn -- an InputEnded could in principle be missed while no character existed to react
		-- to it (e.g. an addon/plugin swallowing the event during the death screen).
		jumpKeyHeld = KeybindManager.IsJumpKeyDown()
		-- A fresh character never has a combo in progress -- make sure jumping starts enabled.
		humanoidInstance:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
		-- Rebind combat animations to this character's own Animator -- a respawned character has a
		-- brand new one, so every AnimationTrack from the old body is stale.
		CombatAnimator.BindCharacter(character)
		-- Rebind the sprint/slide dust trickle's own humanoid/root-part cache to the new character.
		MovementVFX.BindCharacter(character)
		-- Same lifecycle for the run system: a fresh Humanoid means a fresh SprintStage watcher, a
		-- reset step clock, and one more attempt at muting the stock character run sound. Bound here,
		-- alongside the other two, so the whole presentation layer picks up a new life in one place and
		-- in a known order rather than through three independent CharacterAdded handlers.
		RunController.BindCharacter(character)

		-- Autorun's movement watcher, rebound to this character's own Humanoid (the old one's signal
		-- died with it). MoveDirection is the right source rather than raw WASD/thumbstick polling:
		-- it already reflects whatever the default ControlModule resolved for this device, so gamepad
		-- and keyboard both work with no per-device branching, and it's zero while the player is
		-- input-locked (death, onboarding) so Autorun can't sprint a body that isn't taking input.
		-- Same MovementInputMagnitudeThreshold canSlideLocally uses, so "moving enough to slide" and
		-- "moving enough to auto-sprint" can never disagree.
		if autoSprintMoveConnection then
			autoSprintMoveConnection:Disconnect()
		end
		autoSprintMoving = false
		autoSprintMoveConnection = humanoidInstance:GetPropertyChangedSignal("MoveDirection"):Connect(function()
			local moving = humanoidInstance.MoveDirection.Magnitude >= Constants.Combat.MovementInputMagnitudeThreshold
			if moving == autoSprintMoving then
				return
			end
			autoSprintMoving = moving
			syncSprint()
		end)
	end

	-- Defensively clears the local lock-on regardless of whether the server also sent
	-- Combat_LockOnChanged for this transition -- CombatSystem.lua's onCharacterAdded clears
	-- state.lockOnTarget on respawn but (as of this pass) doesn't always pair that with a
	-- notification, and confirmDeath doesn't clear/notify either. Without this, a player who dies
	-- or respawns while still locked onto a target keeps rendering that reticle indefinitely -- a
	-- real, persistent desync between server truth and client presentation.
	local function clearLockOnPresentation(): ()
		currentLockOnUserId = nil
		combatFeedback.LockOnTarget:set(nil)
	end

	if localPlayer.Character then
		task.spawn(bindLocalCharacter, localPlayer.Character)
	end
	localPlayer.CharacterAdded:Connect(function(character: Model)
		task.spawn(bindLocalCharacter, character)
		clearLockOnPresentation()
		-- Respawn ends the death-to-respawn presentation state, the same "a fresh character resets
		-- per-life presentation" reasoning as the mirror/jumpSuppressGeneration resets in
		-- bindLocalCharacter above -- see this file's header and Screens/DeathFeed's own header for
		-- why this (not a client-side timer) is what actually ends the overlay/dip.
		deathFeed.ClearDeath()
		DeathEffect.Clear()
		-- Also ends the input lockout -- see isLocalPlayerDead's own declaration above.
		isLocalPlayerDead = false
		-- Hand WASD back now that there's a live body to move -- see setControlsEnabled's own
		-- declaration above for why this (not PlatformStand/WalkSpeed) is what actually gated it.
		setControlsEnabled(true)
	end)
	localPlayer.CharacterRemoving:Connect(function()
		localHumanoid = nil
		finisherReady = false
		clearLockOnPresentation()
		-- Defensive reset, same reasoning as clearLockOnPresentation above: a player who dies/respawns
		-- mid-sprint shouldn't keep the dust trickle/FOV zoom running against a character that's gone.
		MovementVFX.SetSprinting(false)
		FOVOffset.ClearContinuous("Sprint")
		sprintKeyHeld = false
		-- Same defensive reset for Autorun's own state: the watcher's Humanoid is gone, and leaving
		-- sprintEngaged true would make the next character's first movement a no-op transition
		-- (syncSprint would think sprint was already running) -- silently costing that life its
		-- running animation, dust and FOV zoom until the player stopped and started moving again.
		if autoSprintMoveConnection then
			autoSprintMoveConnection:Disconnect()
			autoSprintMoveConnection = nil
		end
		autoSprintMoving = false
		sprintEngaged = false
		-- Both sprint-input latches too: a life that ended mid-sprint must not hand the next one a held
		-- key or a live toggle it never pressed. Same "respawn ends the per-life state" rule the resets
		-- above follow.
		sprintKeyHeld = false
		sprintToggledOn = false
		ParkourController.SetSprinting(false)
		-- The run system's own half of that same reset. Its per-life teardown (the SprintStage watcher,
		-- the stage FOV pull, the animator's run stage) runs off its own CharacterRemoving handler --
		-- this is only the sprint INTENT, which lives here.
		RunController.SetSprinting(false)
	end)

	-- Input: intent only. Every call below is a request; CombatSystem server-side decides what
	-- actually happens (validates range/facing/cooldowns/state before anything resolves).
	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		-- Dead players get no combat input at all -- see isLocalPlayerDead's own declaration above.
		-- Deliberately before the jumpKeyHeld resync below too: there's nothing for a dead player to
		-- jump-suppress, and re-syncing it here would just be discarded work.
		if isLocalPlayerDead then
			return
		end

		-- The radial emote wheel (Client/Emotes/EmoteWheelClient.lua) suppresses all combat input
		-- while open -- attacking, feinting, blocking, or dashing mid-wheel would be incoherent (the
		-- wheel already owns the mouse for its own segment-steering, and confirming an emote is the
		-- only thing a release should do). IsOpen() is a plain module-level read (safe even before
		-- that module's own Start() runs), not a Fusion Value -- see its own header.
		if EmoteWheelClient.IsOpen() then
			return
		end

		-- Tracked independently of the elseif chain below (neither Space nor ButtonA is bound to any
		-- KeybindAction -- both are read via KeybindManager.IsJumpKeyDown, not KeybindManager.Matches)
		-- so this always updates regardless of what else the same physical press matches. Resynced
		-- UNCONDITIONALLY on every InputBegan rather than gated on "was THIS press Space/ButtonA" --
		-- IsJumpKeyDown() polls the two KeyCodes' actual live down-state directly, which already
		-- correctly reflects reality no matter which key's press triggered this handler run (a
		-- same-frame "F" press while Space is still physically held still reads Space as down), so
		-- there's no need to filter on `input` at all. Feeds tryReenableJump's release gate above.
		jumpKeyHeld = KeybindManager.IsJumpKeyDown()

		-- Precomputed once per press, same reasoning as jumpKeyHeld above -- resolves to the 1-5 slot
		-- number the physical press matches (if any) so the elseif branch below can just fire it,
		-- rather than five nearly-identical `elseif KeybindManager.Matches("HotbarSlotN", input)`
		-- branches that all do the exact same lookup-and-fire (see HotbarMoveClient.Fire).
		local hotbarSlot: number? = nil
		for slotIndex, action in ipairs(HOTBAR_SLOT_ACTIONS) do
			if KeybindManager.Matches(action, input) then
				hotbarSlot = slotIndex
				break
			end
		end

		if KeybindManager.Matches("BasicAttack", input) then
			-- Report whether the jump button (Space or gamepad ButtonA) is held at the click so the
			-- server can pick the Uppercut finisher on the 4th combo hit. Non-authoritative -- a
			-- finisher must still land, so this flag at most chooses Uppercut over a plain finisher
			-- (see this file's header and CombatSystem.lua's handleAttackRequest). The rest of the
			-- combo is server-tracked; the client only sends "M1."
			local holdingJump = KeybindManager.IsJumpKeyDown()
			-- Jump + M1: the LOCAL character being airborne right now is what the server's own
			-- handleAttackRequest branches on to throw the standalone AirSlam attack instead of a
			-- grounded Basic/Finisher swing (see that function's/isAirborneForAirSlam's own headers)
			-- -- mirrored here with the SAME broadened check (not FloorMaterial alone, which lags a
			-- few ticks behind the actual jump input and was why a normally-timed jump+click often
			-- missed): Jumping/Freefall HumanoidStateType fires the instant the jump input is
			-- processed, before physics has moved the character at all. isAirborne is purely a LOCAL
			-- prediction hint; the server independently re-checks its own humanoid and never trusts
			-- this client's guess for anything authoritative.
			local isAirborne = localHumanoid ~= nil
				and (
					localHumanoid.FloorMaterial == Enum.Material.Air
					or localHumanoid:GetState() == Enum.HumanoidStateType.Jumping
					or localHumanoid:GetState() == Enum.HumanoidStateType.Freefall
				)
			logger:debug(
				"Input: BasicAttack keybind -> basic attack",
				{ holdingJump = holdingJump, isAirborne = isAirborne }
			)
			requestBasicAttack:FireServer(holdingJump)
			-- Committing to an attack drops an active guard server-side now too
			-- (CombatSystem.lua's commitAndThrowAttack/handleAirSlamRequest) -- stop the predicted
			-- BlockHold stance here so a player who fired this while still physically holding the
			-- Block key doesn't keep SEEING their own guard stance after the server has already
			-- dropped it. No-op if it wasn't playing. Same "client predicts the consequences of its
			-- own action" pattern the Dash/double-tap-W branches below already use for the identical
			-- server-side cancel.
			CombatAnimator.StopBlockHold()
			-- Predict the swing's own start feedback immediately when the local mirror says the
			-- server will accept this press (Predict). A Buffered/NoPredict press shows nothing now --
			-- a Buffered press's feedback arrives with the confirm echo when the server flushes its
			-- input buffer, exactly as every attack did before this pass. The FOV punch fires here for
			-- a predicted press (and in the AttackStarted handler for a non-predicted one) so it lands
			-- on the action's real start either way.
			local now = os.clock()
			-- Mirrors handleAttackRequest's own inAirCombo exemption server-side (CombatSystem.lua):
			-- HoldAloft parks the attacker's own body off the ground for the whole juggle, so
			-- isAirborne alone can't tell "just jumped" apart from "mid-air-combo" -- without this,
			-- a press meant to CONTINUE the combo would predict the Downslam swing instead of the
			-- correct combo-continuation one (still correctable by ConfirmSwing's crossfade, but
			-- worth avoiding). See PredictionMirror.IsInAirCombo's own header.
			if isAirborne and not mirror:IsInAirCombo(now) then
				-- AirSlam has its own mirrored cooldown and no combo/stage concept -- see
				-- PredictionMirror.EvaluateAirSlam/CombatAnimator.PlayPredictedAirSlam's own headers.
				-- Deliberately does NOT call suppressJumpThroughCombo below -- that's specific to the
				-- M1-finisher jump-uppercut interaction, which this standalone move has nothing to do
				-- with.
				if mirror:EvaluateAirSlam(now) == "Predict" then
					CombatAnimator.PlayPredictedAirSlam()
					SwingEffect.Play(false)
					beginPrediction("Swing")
				end
				return
			end
			local basicVerdict = mirror:EvaluateBasic(now)
			if basicVerdict == "Predict" then
				local swing = mirror:PredictedSwing(now)
				CombatAnimator.PlayPredictedSwing(swing.StageIndex, swing.IsFinisher)
				SwingEffect.Play(false)
				beginPrediction("Swing")
			elseif basicVerdict == "Buffered" then
				-- The server WILL throw this press when its gate opens (handleAttackRequest buffers
				-- it, onHeartbeat flushes it), so the swing is coming -- but nothing was shown for it
				-- until the confirm echo crossed the wire, leaving the whole buffered window visually
				-- and audibly dead. That window is the TRAILING slice of the previous swing's
				-- commitment, i.e. exactly where a player mashing a combo presses, so the dead frames
				-- landed on the most common input in the game.
				--
				-- This does NOT predict now -- predicting now is what evaluateAttack's own header
				-- correctly rejects, since it would play the feedback early and then double it on the
				-- echo. It schedules the same prediction for the instant the gate actually opens,
				-- which is when the server's flush throws the swing anyway. Re-evaluated at fire time
				-- rather than trusted: anything that happened during the wait (a stun, a parry, a
				-- reject) leaves the verdict non-Predict and the echo drives the visuals instead.
				bufferedSwingGeneration += 1
				local generation = bufferedSwingGeneration
				task.delay(math.max(0, mirror:GateOpensAt(now) - now), function()
					if generation ~= bufferedSwingGeneration then
						return
					end
					local fireAt = os.clock()
					if mirror:EvaluateBasic(fireAt) ~= "Predict" then
						return
					end
					local swing = mirror:PredictedSwing(fireAt)
					CombatAnimator.PlayPredictedSwing(swing.StageIndex, swing.IsFinisher)
					SwingEffect.Play(false)
					beginPrediction("Swing")
				end)
			end
			-- Proactively keep Jumping suppressed through this combo string -- see
			-- suppressJumpThroughCombo's own header for why the reactive-only version left a real
			-- jump-on-anticipation window. Harmless to call on a press the server ends up rejecting
			-- (cooldown/commitment/etc.) -- worst case jump is suppressed slightly longer than
			-- necessary, never gameplay-affecting.
			suppressJumpThroughCombo()
		elseif KeybindManager.Matches("Block", input) then
			-- Block doubles as a timed parry: this fires the same RequestBlockStart either way --
			-- CombatSystem.lua's handleBlockStart decides server-side whether the press also opens
			-- a parry window (see that function's header), so there's nothing extra to send here.
			logger:debug("Input: Block keybind -> block start")
			fireRequest(requestBlockStart, "RequestBlockStart")
			-- Client-predicted, same reasoning as Sprint's CombatAnimator.StartRunning() below: a
			-- BlockStart press always starts at least a plain block server-side (see
			-- handleBlockStart), so the guard stance doesn't need to wait on a round-trip. The
			-- parry-specific flash is different -- see the Combat_BlockStarted handler above for why
			-- that one DOES wait on server confirmation.
			CombatAnimator.PlayBlockHold()
			-- Instant, LOCAL-ONLY parry acknowledgment when the mirror says this press armed a parry
			-- window. Deliberately NOT the replicating character ParryFlash (that stays
			-- server-confirmed in the Combat_BlockStarted handler -- a mispredicted flash would
			-- misinform the attacker); this glint is on the presser's own screen only, so a wrong
			-- guess costs a harmless local flicker, never bad information to an opponent.
			if mirror:PredictParryAvailable(os.clock()) then
				combatFeedback.FlashParryReady()
			end
		elseif KeybindManager.Matches("HeavyAttack", input) then
			logger:debug("Input: HeavyAttack keybind -> heavy attack")
			fireRequest(requestHeavyAttack, "RequestHeavyAttack")
			-- See the BasicAttack branch's own comment above -- an attack drops an active guard
			-- server-side now too, so stop the predicted BlockHold stance here as well.
			CombatAnimator.StopBlockHold()
			-- Heavy prediction is FOV-punch-only: the mirror doesn't track the throw-based Heavy
			-- combo index (it mirrors the landing-based Basic string only), and Heavy has no swing
			-- clip yet, so there's no pose to predict -- but the instant camera punch still removes
			-- the round-trip lag on "did my heavy register." beginPrediction holds the commitment
			-- gate for the round-trip so a follow-up basic can't predict mid-heavy; there's no pose
			-- for a reject/timeout to roll back (the FOV punch is deliberately never rolled back).
			local nowHeavy = os.clock()
			if mirror:EvaluateHeavy(nowHeavy) == "Predict" then
				SwingEffect.Play(true)
				beginPrediction("Swing")
			end
		elseif KeybindManager.Matches("Feint", input) then
			-- Right-click: cancels whatever Basic/Heavy/Finisher/AirSlam swing is currently mid-
			-- windup (CombatSystem.lua's handleFeintRequest). Unlike every other predictable action in
			-- this file, this does NOT go through the mirror/beginPrediction/rollback pipeline -- see
			-- CombatAnimator.CancelActiveSwing's own header for why an unconditional local stop is
			-- always safe here (no gameplay outcome to mispredict): the request always fires, and the
			-- animation always stops immediately, regardless of whether the server ultimately accepts
			-- the feint (still in windup) or the swing was already too far along to cancel.
			logger:debug("Input: Feint keybind -> feint")
			fireRequest(requestFeint, "RequestFeint")
			CombatAnimator.CancelActiveSwing()
		elseif KeybindManager.Matches("Dash", input) then
			-- The Dash button (keyboard Q, gamepad ButtonB): a neutral-game positioning burst, no
			-- i-frames (handleDashRequest). Direction is never sent -- the server applies a WalkSpeed
			-- burst and the player's own already-held movement input carries them, so no displacement
			-- or direction vector crosses the wire. viaDoubleTapForward is always false here -- the
			-- Q/ButtonB keybind never claims the double-tap-W punch package (DashPunch's hitbox, the
			-- longer Front duration/commitment, and the air-combo launch -- see the double-tap-W
			-- branch below, the ONLY trigger for that move). A plain forward-resolved dash off THIS
			-- branch throws its own separate, smaller DashHit attack instead (no air-combo, no
			-- double-tap needed) -- see handleDashRequest's own header for the two-attacks split.
			logger:debug("Input: Dash keybind -> dash")
			logger:debug("FireServer", { action = "RequestDash", viaDoubleTapForward = false })
			requestDash:FireServer(false)
			-- Movement.ApplyDash already drops an active guard server-side -- stop the predicted
			-- BlockHold stance here too so the player isn't left SEEING their own guard after the
			-- server has already cleared it (no-op if it wasn't playing).
			CombatAnimator.StopBlockHold()
			predictDash(false)
		elseif KeybindManager.Matches("SwapWeapon", input) then
			-- One-shot toggle between Constants.Combat.Weapons.Primary/Secondary -- the server
			-- decides acceptance (cooldown/commitment) and which weapon results; see
			-- handleSwapWeaponRequest. Fire-and-forget, same shape as Dash/Sprint's requests.
			logger:debug("Input: SwapWeapon keybind -> swap weapon")
			fireRequest(requestSwapWeapon, "RequestSwapWeapon")
		elseif KeybindManager.Matches("Sprint", input) then
			-- Sprint is a held state in Hold mode (press = sprint on, release in InputEnded below =
			-- off), the same start/stop shape as Block -- or a flip per press in Toggle mode (see
			-- CombatClient.SetSprintMode). Either way the server tracks the intent and only actually
			-- raises WalkSpeed while combat state permits (see CombatSystem.lua's handleSprintStart).
			logger:debug("Input: Sprint keybind -> sprint start", { toggleMode = sprintToggleMode })
			if sprintToggleMode then
				sprintToggledOn = not sprintToggledOn
			else
				sprintKeyHeld = true
			end
			-- No-ops if Autorun already engaged sprint for this movement -- see syncSprint's own header.
			syncSprint()
		elseif KeybindManager.Matches("Slide", input) then
			-- TWO SLIDES LIVE HERE, and exactly one of them responds to any given press.
			--
			-- When the Parkour System is enabled and bound (the normal case), IT owns the slide: a real
			-- momentum slide with slope response, a crouch that fits under geometry, and exits into
			-- jumps/rolls/vaults. Client/Parkour/ParkourInput.lua has already recorded this same press
			-- into the parkour input buffer, so there is nothing to do here but stay out of the way.
			--
			-- When parkour is switched off in Settings, or has not bound a character yet, this legacy
			-- path runs unchanged -- the WalkSpeed-multiplier Slide the combat layer has always had,
			-- with its own server request, cooldown and prediction. Keeping it reachable is what makes
			-- the Settings toggle a genuine fallback rather than a switch that turns sliding off.
			if ParkourController.HandlesSlide() then
				logger:debug("Input: Slide keybind -> handled by Parkour System")
			elseif sprintEngaged and canSlideLocally() then
				-- Legacy path: Slide only fires while sprint is already engaged (this client's own local
				-- record -- sprintEngaged, which is true whether the player is holding the Sprint key or
				-- Autorun engaged it -- not the server's, which handleSlideRequest independently
				-- re-checks) AND canSlideLocally() says there's real, non-backward movement input -- see
				-- that function's own header. A press that fails either check is simply not sent.
				logger:debug("Input: Slide keybind -> slide")
				logger:debug("FireServer", { action = "RequestSlide" })
				requestSlide:FireServer()
				predictSlide()
			end
		elseif KeybindManager.Matches("LockOn", input) then
			logger:debug("Input: LockOn keybind -> lock-on")

			if currentLockOnUserId ~= nil then
				logger:debug("FireServer", { action = "RequestLockOn", targetUserId = "nil (clearing)" })
				requestLockOn:FireServer(nil)
				return
			end

			-- Nearest-target acquisition is a client-side UX convenience only -- the server
			-- independently re-validates distance/aliveness before accepting the lock (see
			-- CombatSystem.lua's handleLockOnRequest), so this hint is never trusted on its own.
			local localRoot = getRootPart(localPlayer)
			if not localRoot then
				logger:warn("Lock-on requested but local player has no root part")
				return
			end

			local nearestPlayer: Player? = nil
			local nearestDistance = Constants.Combat.LockOnRange
			for _, otherPlayer in ipairs(Players:GetPlayers()) do
				if otherPlayer == localPlayer then
					continue
				end
				local otherRoot = getRootPart(otherPlayer)
				if not otherRoot then
					continue
				end
				local distance = (otherRoot.Position - localRoot.Position).Magnitude
				if distance <= nearestDistance then
					nearestDistance = distance
					nearestPlayer = otherPlayer
				end
			end

			if nearestPlayer then
				logger:debug(
					"FireServer",
					{ action = "RequestLockOn", targetUserId = nearestPlayer.UserId, targetName = nearestPlayer.Name }
				)
				requestLockOn:FireServer(nearestPlayer.UserId)
			else
				logger:debug("Lock-on: no nearby target found", { range = Constants.Combat.LockOnRange })
			end
		elseif hotbarSlot then
			-- Admin-only in practice (see HotbarMoveClient.lua's own header) -- fires whatever
			-- Move-Editor-authored move is bound to this slot, or does nothing if the slot is empty.
			logger:debug("Input: hotbar slot keybind -> fire hotbar move", { slot = hotbarSlot })
			HotbarMoveClient.Fire(hotbarSlot)
		elseif input.KeyCode == Enum.KeyCode.E then
			-- Double-tap-W-to-dash: an alternate trigger for the same Dash request the Dash
			-- keybind fires (see that branch above), but the ONE trigger that reports
			-- viaDoubleTapForward = true -- the front-lunge-punch package (DashPunch's hitbox, the
			-- longer Front duration/commitment, and the air-combo it can launch) only ever happens off
			-- this path, never off a plain Q/ButtonB press (see handleDashRequest's own header for
			-- the full two-attacks reasoning). W isn't a KeybindManager action (movement is the
			-- engine's own default character controller), so this reads the raw KeyCode directly
			-- rather than going through KeybindManager.Matches.
			local now = os.clock()
			if now - lastWPressTime <= Constants.Keybinds.DoubleTapDashWindowSeconds then
				-- No special case for being held aloft as someone ELSE's air-combo target anymore -- a
				-- held victim keeps full Block/Parry capability (RequestBlockStart works normally,
				-- ACTION_GATES.HeldAloft exempts BlockStart) so there's nothing left for double-tap-W to
				-- do differently while held: this just fires the ordinary Dash request below, which the
				-- server harmlessly rejects (category "Dash" IS gated by HeldAloft -- a held victim
				-- can't move) the exact same way it rejects any other blocked action.
				logger:debug("Input: Double-tap W -> dash")
				logger:debug("FireServer", { action = "RequestDash", viaDoubleTapForward = true })
				requestDash:FireServer(true)
				-- Same server-side guard-cancel as the Dash keybind branch above -- see its own
				-- comment.
				CombatAnimator.StopBlockHold()
				predictDash(true)
				-- Consumed -- a third press right after shouldn't pair with the second and fire
				-- again (the server's own dashCooldownExpiry would reject it anyway, but this keeps
				-- the client-side detection's own semantics clean: pairs, not a sliding window).
				lastWPressTime = 0
			else
				lastWPressTime = now
			end
		end
	end)

	logger:debug("Input bindings connected")

	UserInputService.InputEnded:Connect(function(input: InputObject, gameProcessed: boolean)
		-- Deliberately NOT gated on gameProcessed like the branches below -- a release must always
		-- be honored (same "stop actions can't be dropped" reasoning as Block/Sprint's own stops),
		-- and skipping this would leave jumpKeyHeld stuck true (Jumping stuck suppressed) if the
		-- engine ever considered the key-up "processed" by something else.
		--
		-- Resynced UNCONDITIONALLY on every InputEnded, not gated on "was THIS release Space/
		-- ButtonA" -- that gate would actually be WRONG here: the moment the last-held jump key is
		-- released, IsJumpKeyDown() correctly reads false (neither key is down anymore), which is
		-- exactly the transition this block exists to catch, but a `was `input` the jump key`
		-- pre-check answers a different question. Re-deriving unconditionally instead makes this
		-- self-correcting no matter which input fired: a player with both a keyboard and a gamepad
		-- connected releasing one jump-mapped key while still holding the other reads correctly (an
		-- `or` of both), and re-running this on an unrelated key's release is a harmless no-op
		-- (jumpKeyHeld/tryReenableJump are already idempotent against redundant calls).
		jumpKeyHeld = KeybindManager.IsJumpKeyDown()
		tryReenableJump()

		if gameProcessed then
			return
		end
		if KeybindManager.Matches("Block", input) then
			logger:debug("Input: Block keybind released -> block stop")
			fireRequest(requestBlockStop, "RequestBlockStop")
			CombatAnimator.StopBlockHold()
			-- Mirror the guard reset the server charges on every release (handleBlockStop), so the
			-- parry-ready glint stops claiming a parry is available during it -- see
			-- PredictionMirror.OnBlockStopped's own header for why this one is predicted outright
			-- rather than driven off a confirm echo.
			mirror:OnBlockStopped(os.clock())
		elseif KeybindManager.Matches("Sprint", input) then
			-- Release only means anything in Hold mode. In Toggle mode the press already flipped the
			-- state and the release must not undo it -- returning early rather than guarding
			-- sprintKeyHeld keeps the two modes' behavior visibly separate.
			if sprintToggleMode then
				return
			end
			logger:debug("Input: Sprint keybind released -> sprint stop")
			sprintKeyHeld = false
			-- Keeps sprint engaged if Autorun still wants it (player released the key but is still
			-- moving) -- see syncSprint's own header.
			syncSprint()
		end
	end)

	-- Attack-started hook: the server's confirm echo for a swing (Types.AttackStartedPayload --
	-- IsHeavy/DebugName/timing/CooldownSeconds/FinisherVariant, never a target or damage value).
	-- Feeds the prediction mirror (real cooldown + commitment, collapsing the conservative
	-- OnPredictionPending horizon) and drives CombatAnimator.ConfirmSwing, which no-ops if this
	-- client already predicted the matching swing, crossfades if it predicted a different one, or
	-- plays fresh for a NOT-predicted (Buffered) press. The FOV punch fires here only when the press
	-- was NOT predicted (a predicted press already fired it at press time). Never a hit/damage
	-- decision.
	attackStarted.OnClientEvent:Connect(function(payload: Types.AttackStartedPayload)
		logger:debug("Combat_AttackStarted received", {
			isHeavy = payload.IsHeavy,
			debugName = payload.DebugName,
			windup = payload.WindupSeconds,
			active = payload.ActiveSeconds,
			recovery = payload.RecoverySeconds,
			finisherVariant = payload.FinisherVariant,
		})
		mirror:OnAttackStarted(payload, os.clock())
		local wasPredicted = consumePendingPrediction("Swing")
		if not wasPredicted then
			SwingEffect.Play(payload.IsHeavy)
		end
		-- A Move Creation System move (CombatSystem.ThrowCustomMove) carries its full authored
		-- Animations timeline instead of relying on DebugName's trailing-digit inference -- see
		-- Types.AttackStartedPayload.Animations' own header for why non-nil (even an EMPTY table) is
		-- itself the "this throw is a CustomMove" signal, not just "did the author set a clip": a
		-- custom move's DebugName is its MoveId, an admin-authored slug+suffix with no relationship to
		-- the M1 combo stage numbering ConfirmSwing's inference reads -- gating on AnimationId being
		-- non-empty instead (the bug this branch replaces) let a MoveId ending in "3" silently play
		-- the M1 combo's third swing. Every weapon-stage/standalone attack leaves Animations nil and
		-- falls through unchanged, first to the Object Stun follow-up's own legacy AnimationId/
		-- AnimationTrackName pair (see CombatAnimator.PlayExplicitAnimation's own header), then to
		-- ConfirmSwing.
		if payload.Animations then
			CombatAnimator.PlayCustomMoveTimeline(payload.Animations, {
				WindupSeconds = payload.WindupSeconds,
				ActiveSeconds = payload.ActiveSeconds,
				RecoverySeconds = payload.RecoverySeconds,
			}, payload.DebugName)
		elseif payload.AnimationId and payload.AnimationId ~= "" and payload.AnimationTrackName then
			CombatAnimator.PlayExplicitAnimation(payload.AnimationId, payload.AnimationTrackName)
		else
			CombatAnimator.ConfirmSwing(payload.DebugName, payload.IsHeavy, payload.FinisherVariant)
		end
	end)

	-- Block-started hook: fires the moment the server accepts a BlockStart request
	-- (Types.BlockStartedPayload -- ParryWindowOpened/ParryWindowSeconds only, never a target or
	-- damage value). ParryWindowOpened is the one piece of this the client cannot predict from raw
	-- input alone (parryCooldownExpiry is server-only state) -- when true, this press armed a real
	-- parry window server-side, so PlayParryFlash is timed to the server's actual confirmation
	-- rather than guessed at press time. The held guard stance itself (PlayBlockHold) is already
	-- started client-predicted, in the Block InputBegan branch below, same reasoning as Sprint.
	blockStarted.OnClientEvent:Connect(function(payload: Types.BlockStartedPayload)
		logger:debug("Combat_BlockStarted received", {
			parryWindowOpened = payload.ParryWindowOpened,
			parryWindowSeconds = payload.ParryWindowSeconds,
		})
		-- Mirror the parry cooldown this press armed (or not) so PredictParryAvailable's local cue
		-- stays in step with the server's real parryCooldownExpiry.
		mirror:OnBlockStarted(payload.ParryWindowOpened, os.clock())
		if payload.ParryWindowOpened then
			CombatAnimator.PlayParryFlash()
		end
	end)

	-- Movement-performed hook: the server's confirm echo for a Dash (Types.MovementPerformedPayload
	-- -- committed duration only). Feeds the mirror (Dash's real cooldown + commitment) and drives
	-- CombatAnimator.ConfirmDash, which reconciles against a predicted Dash: no-op if the confirmed
	-- direction matches what was predicted, crossfade if it mispredicted the direction, or play
	-- fresh for a NOT-predicted press.
	movementPerformed.OnClientEvent:Connect(function(payload: Types.MovementPerformedPayload)
		logger:debug("Combat_MovementPerformed received", { durationSeconds = payload.DurationSeconds })
		mirror:OnMovementPerformed(payload.DurationSeconds, os.clock(), payload.CooldownSeconds)
		consumePendingPrediction("Dash")
		CombatAnimator.ConfirmDash(payload.DurationSeconds)
	end)

	-- Slide-performed hook: the server's confirm echo for a Slide (Types.SlidePerformedPayload).
	-- Feeds the mirror (Slide's real cooldown + commitment) and drives CombatAnimator.ConfirmSlide.
	-- The FX/camera fan-out (dust/FOV/shake) already fired at predict time for a predicted press --
	-- only fire it here too for the NOT-predicted case (e.g. gameProcessed swallowed the input),
	-- same "confirm covers the non-predicted case" shape every other predicted action uses.
	slidePerformed.OnClientEvent:Connect(function(payload: Types.SlidePerformedPayload)
		logger:debug("Combat_SlidePerformed received", { durationSeconds = payload.DurationSeconds })
		mirror:OnSlidePerformed(payload.DurationSeconds, os.clock())
		local wasPredicted = consumePendingPrediction("Slide")
		CombatAnimator.ConfirmSlide()
		if not wasPredicted then
			MovementVFX.PlaySlideBurst()
			FOVOffset.Punch(
				"SlideKick",
				Constants.Camera.Slide.FOVPunchDelta,
				Constants.Camera.Slide.FOVPunchOutSeconds,
				Constants.Camera.Slide.FOVPunchBackSeconds
			)
			CameraShake.Shake(Constants.FX.CameraShake.SlideStart)
		end
	end)

	-- Feint-performed hook: the server's confirm echo for an accepted Feint (Types.
	-- FeintPerformedPayload -- RecoverySeconds only). Feeds the mirror so a follow-up press right
	-- after a feint reads the real (shorter) commitment instead of staying conservatively locked out
	-- for the cancelled swing's original, longer one -- see PredictionMirror.OnFeintPerformed's own
	-- header. No animation work here: CombatAnimator.CancelActiveSwing already fired unconditionally
	-- at press time (this file's Feint input branch), so there's nothing left to confirm visually.
	feintPerformed.OnClientEvent:Connect(function(payload: Types.FeintPerformedPayload)
		logger:debug("Combat_FeintPerformed received", { recoverySeconds = payload.RecoverySeconds })
		mirror:OnFeintPerformed(payload.RecoverySeconds, os.clock())
	end)

	-- Finisher-ready sync: toggle the local jump so Space on the 4th hit uppercuts instead of jumping.
	-- Authoritative -- always wins over the proactive suppression above regardless of its own
	-- pending timers (bumping the generation invalidates any stale re-enable already scheduled).
	comboStateChanged.OnClientEvent:Connect(function(payload: Types.ComboStatePayload)
		finisherReady = payload.FinisherReady == true
		logger:debug("Combat_ComboStateChanged received", { finisherReady = finisherReady })
		jumpSuppressGeneration += 1
		if finisherReady then
			setJumpEnabled(false)
		else
			-- Not an unconditional re-enable -- see tryReenableJump's header for why: if Space is
			-- still physically held (e.g. right after the finisher throw that just cleared
			-- finisherReady), turning Jumping back on here would fire a real jump immediately.
			tryReenableJump()
		end
	end)

	-- Weapon-changed sync: server-confirmed transition after a successful swap (handleSwapWeaponRequest).
	-- Logged as a "did my swap take effect" diagnostic today -- a persistent equipped-weapon HUD
	-- indicator is a follow-up UI task, not required for the mechanic itself to function (the
	-- moveset/cooldown change is already real and server-authoritative regardless of whether it's
	-- rendered anywhere), same status as the Combat_AttackStarted/Combat_MovementPerformed hooks
	-- above.
	weaponChanged.OnClientEvent:Connect(function(weaponId: Types.WeaponId)
		logger:debug("Combat_WeaponChanged received", { weaponId = weaponId })
		-- A swap resets both combo counters server-side (handleSwapWeaponRequest); mirror the basic
		-- string reset so a predicted post-swap swing starts at stage 1, not mid-combo.
		mirror:OnWeaponChanged()
	end)

	-- Parry-window-opened hook: broadcast to every NEARBY client (server-side
	-- broadcastToNearbyPlayers, within Constants.Combat.ParryTellBroadcastRadius studs -- no longer
	-- literally every connected client, see that constant's own header) the moment any combatant
	-- (player or bot) arms a parry window (Constants.Combat.RemoteNames.ParryWindowOpened). Shows the
	-- obvious, synced-for-all-nearby-viewers tell -- a bright highlight held on that character for
	-- the window duration so an attacker can read "they're parry-armed" no matter whose screen it is.
	-- A broadcast highlight rather than relying on the block/parry ANIMATION replicating (whose
	-- weight can lose to the default Animate script on remote viewers -- see CombatAnimator's
	-- DOMINANT_WEIGHT note).
	--
	-- durationSeconds is the server's REAL computed window (broadcastParryWindowOpened's own header) --
	-- for a laggy presser this is Constants.Combat.ParryWindowSeconds PLUS their ping, strictly longer
	-- than the flat constant. Using the flat constant here used to hold the highlight for exactly
	-- 0.35s regardless, so it visibly expired before state.Vitals.parryWindowExpiry actually closed on
	-- any player with non-trivial ping -- a hit landing in that gap still parried even though the
	-- target no longer looked parry-armed. `or Constants.Combat.ParryWindowSeconds` only guards an
	-- old/mismatched server build that hasn't sent the second argument yet.
	parryWindowOpened.OnClientEvent:Connect(function(character: Instance?, durationSeconds: number?)
		if typeof(character) == "Instance" and character:IsA("Model") then
			HitFlash.FlashHold(character, "ParryWindow", durationSeconds or Constants.Combat.ParryWindowSeconds)
		end
	end)

	-- Action-rejected hook: the rollback signal for a predicted action the server genuinely refused
	-- (Types.ActionRejectedPayload; never fired for a buffered attack or a Stop action -- see that
	-- type's header). Rolls back whatever predicted feedback the matching press started. The mirror
	-- itself needs no resync from the reason string: OnPredictionPending already holds its commitment
	-- gate closed for the rollback window, and the feedback stream (OnResolvedAgainstMe /
	-- OnMyAttackParried / OnMyPostureBroken) carries the authoritative lockout that caused the reject
	-- at about the same time, so the mirror self-corrects without parsing Reason (logged only).
	actionRejected.OnClientEvent:Connect(function(payload: Types.ActionRejectedPayload)
		logger:debug("Combat_ActionRejected received", { action = payload.Action, reason = payload.Reason })
		if payload.Action == "Basic" or payload.Action == "Heavy" then
			if consumePendingPrediction("Swing") then
				CombatAnimator.CancelPredictedSwing()
			end
		elseif payload.Action == "Dash" then
			if consumePendingPrediction("Dash") then
				CombatAnimator.CancelPredictedDash()
			end
		elseif payload.Action == "Slide" then
			if consumePendingPrediction("Slide") then
				CombatAnimator.CancelPredictedSlide()
			end
		elseif payload.Action == "BlockStart" then
			-- The block stance was client-predicted (PlayBlockHold); a reject means it didn't take
			-- server-side (stunned/posture-broken/committed), so drop it. Not tracked as a
			-- pending-prediction slot -- a plain block normally always succeeds, so there's no
			-- timeout arming for it, just this stance correction.
			CombatAnimator.StopBlockHold()
		elseif payload.Action == "Sprint" then
			-- Sprint's keydown branch above optimistically plays the running animation/VFX/FOV zoom
			-- before the server confirms (no PredictionMirror slot, no confirm echo -- see
			-- Types.RejectedActionKind's own header), so a genuine reject (Ragdolled) needs the exact
			-- same teardown handleSprintStop's own InputEnded branch already does, or the player is
			-- left visually "running" with no server-side effect until they release and re-press Sprint.
			CombatAnimator.StopRunning()
			MovementVFX.SetSprinting(false)
			-- And the run presentation's own half: the footstep loop is gated on this intent, so a
			-- rejected sprint that left it true would keep laying down footsteps for a run the server
			-- refused. The stage itself needs no rollback here -- the server simply never publishes one
			-- for a sprint it rejected.
			RunController.SetSprinting(false)
			FOVOffset.SetContinuous("Sprint", 0, Constants.Camera.Sprint.FOVEaseSpeed)
			-- The visuals above are now gone, so record that sprint is no longer engaged -- otherwise
			-- syncSprint still believes it is and the next transition that WANTS sprint reads as a
			-- no-op, leaving the player permanently un-sprinting until movement stops and restarts.
			-- Safe against re-fire loops because syncSprint is edge-triggered on real transitions, not
			-- polled: with the Sprint key still held or Autorun still moving, nothing re-sends until
			-- one of those actually changes -- the same recovery point the key path always had.
			sprintEngaged = false
		end
		-- No branch for Action == "CustomMove" (the hotbar's live-fire request) -- it plays no local
		-- prediction to roll back in the first place (see Types.RejectedActionKind's own header), so
		-- the unconditional debug log two lines above this elseif chain is already this reject's
		-- entire client-side handling.
	end)

	-- Monotonic per-entry LayoutOrder -- every entry otherwise shares LayoutOrder=0 AND the identical
	-- Name ("KillFeedEntry"), so display/eviction order fell back to GetChildren()'s own unenforced
	-- parenting-order tiebreak instead of a stamped, guaranteed ordering.
	local killFeedEntryCounter = 0

	killFeedEvent.OnClientEvent:Connect(function(payload: { KillerName: string, VictimName: string })
		local playerGui = localPlayer:WaitForChild("PlayerGui") :: PlayerGui
		local deathFeedScreen = playerGui:FindFirstChild("DeathFeed")
		if not deathFeedScreen then
			return
		end

		local killFeedList = deathFeedScreen:FindFirstChild("KillFeedList")
		if not killFeedList then
			return
		end

		local entryCount = 0
		for _, child in ipairs(killFeedList:GetChildren()) do
			if child:IsA("TextLabel") then
				entryCount += 1
			end
		end

		while entryCount >= 6 do
			for _, child in ipairs(killFeedList:GetChildren()) do
				if child:IsA("TextLabel") then
					child:Destroy()
					entryCount -= 1
					break
				end
			end
			if entryCount < 6 then
				break
			end
		end

		killFeedEntryCounter += 1

		local entry = Instance.new("TextLabel")
		entry.Name = "KillFeedEntry"
		entry.LayoutOrder = killFeedEntryCounter
		entry.BackgroundTransparency = 1
		entry.Text = string.format("%s defeated %s", payload.KillerName, payload.VictimName)
		entry.TextColor3 = Color3.fromRGB(255, 255, 255)
		entry.TextSize = 14
		entry.Font = Enum.Font.GothamMedium
		entry.Size = UDim2.fromOffset(280, 20)
		entry.AutomaticSize = Enum.AutomaticSize.Y
		entry.TextXAlignment = Enum.TextXAlignment.Right
		entry.Parent = killFeedList
	end)

	-- Feedback: server-driven presentation only, per this file's header.
	lockOnChanged.OnClientEvent:Connect(function(targetUserId: number?)
		logger:debug("Combat_LockOnChanged received", { targetUserId = targetUserId })
		currentLockOnUserId = targetUserId
		if targetUserId == nil then
			combatFeedback.LockOnTarget:set(nil)
		end
	end)

	-- Downslam ground-impact payoff (Client/FX/SlamImpactVFX.lua) -- fires on the dedicated
	-- "GroundSlam" event below, a SECOND, later beat than the hit-confirm reactions. Every
	-- Downslam-variant origin (the M1 finisher's own Downslam, the standalone AirSlam attack, and the
	-- air-combo's own MaxHits slam finisher) sends this same event once its knockback physics actually
	-- resolves server-side -- see CombatSystem.lua's sendGroundSlamFeedback for why it's a distinct
	-- Kind rather than a second "Hit". ImmediateGroundImpact (Types.CombatFeedbackPayload's own header)
	-- tells SlamImpactVFX.BeginWatch whether to expect an observable fall or an already-resolved one.
	-- Scoped to a target resolvable to a live Player character (getCharacter(payload.TargetUserId)) --
	-- a training dummy/bot target has no client-visible Instance to track (see SlamImpactVFX.lua's own
	-- header).
	local function beginDownslamWatch(payload: Types.CombatFeedbackPayload): ()
		if payload.FinisherVariant ~= "Downslam" then
			return
		end
		local slamCharacter = getCharacter(payload.TargetUserId)
		if not slamCharacter then
			return
		end
		local isLocalAttacker = payload.AttackerUserId == localPlayer.UserId
		local isLocalTarget = payload.TargetUserId == localPlayer.UserId
		SlamImpactVFX.BeginWatch(slamCharacter, function()
			-- Both parties who received this feedback event feel the ground impact -- same
			-- attacker/victim role split HitStop.FreezeAttacker/FreezeVictim already use for the
			-- hit-confirm beat. CameraShake.FinisherSlam reuses the same preset FlightController.lua
			-- already plays for a hard flight landing -- a heavy ground impact, whatever caused it.
			CameraShake.Shake(Constants.FX.CameraShake.FinisherSlam)
			if isLocalAttacker then
				HitStop.FreezeAttacker(true)
			end
			if isLocalTarget then
				HitStop.FreezeVictim(true)
			end
		end, payload.ImmediateGroundImpact)
	end

	feedbackEvent.OnClientEvent:Connect(function(payload: Types.CombatFeedbackPayload)
		logger:debug("Combat_FeedbackEvent received", {
			kind = payload.Kind,
			attackerUserId = payload.AttackerUserId,
			targetUserId = payload.TargetUserId,
			damage = payload.DamageAmount,
			posture = payload.PostureAmount,
			isHeavy = payload.IsHeavy,
		})

		-- Feed the prediction mirror from these server-validated resolutions (presentation only --
		-- never a gameplay decision). Done up front, before the Death/PostureBreak/Disarmed early
		-- returns below, so a returning branch can't skip its own feed:
		--   * my OWN swing connecting (I'm the attacker on a Hit/Blocked) advances the mirrored
		--     landing-based combo -- exactly what the server's basicComboLanded does.
		--   * ANY swing resolving against ME (I'm the target on Hit/Blocked/Parried) that was an
		--     unmitigated Hit mirrors the universal hit-stun.
		--   * my own attack being Parried, or my own posture breaking, mirror those lockouts.
		local nowFeedback = os.clock()
		if payload.AttackerUserId == localPlayer.UserId and (payload.Kind == "Hit" or payload.Kind == "Blocked") then
			mirror:OnOwnSwingConnected(payload.AttackDebugName, payload.IsHeavy, nowFeedback)
		end
		if payload.TargetUserId == localPlayer.UserId then
			if payload.Kind == "Hit" or payload.Kind == "Blocked" or payload.Kind == "Parried" then
				mirror:OnResolvedAgainstMe(payload.Kind == "Hit", nowFeedback)
			end
			if payload.Kind == "PostureBreak" then
				mirror:OnMyPostureBroken(nowFeedback)
			end
		end
		if payload.Kind == "Parried" and payload.AttackerUserId == localPlayer.UserId then
			mirror:OnMyAttackParried(nowFeedback, payload.AirComboPriorityShift)
		end
		-- The priority-switch redesign's OTHER side: I'm the parrier (TargetUserId), and this parry
		-- just seized attacker priority over an air-combo sequence (AirCombo.SwitchPriority) -- see
		-- Types.CombatFeedbackPayload.AirComboPriorityShift's own header.
		if
			payload.Kind == "Parried"
			and payload.AirComboPriorityShift
			and payload.TargetUserId == localPlayer.UserId
		then
			mirror:OnMyParrySeizedAirComboPriority(nowFeedback)
		end

		if payload.Kind == "Death" then
			-- This is the FeedbackEvent-carried Death payload, distinct from the dedicated
			-- Combat_KillFeed remote handled below (killFeedEvent.OnClientEvent), which is what
			-- renders into Screens/DeathFeed's KillFeedList -- that part is unchanged. This branch now
			-- drives the death-to-respawn overlay (Screens/DeathFeed's DeathOverlay) and the matching
			-- screen dip (Client/FX/DeathEffect.lua), but ONLY on the victim's own screen --
			-- confirmDeath (CombatSystem.lua) sends this exact payload to BOTH the victim and the
			-- killer (if any), and the killer's own client must never see their own screen dip or
			-- overlay for a kill they threw.
			if payload.TargetUserId == localPlayer.UserId then
				local killerName: string? = nil
				if payload.AttackerUserId then
					local killerPlayer = Players:GetPlayerByUserId(payload.AttackerUserId)
					killerName = if killerPlayer then killerPlayer.Name else nil
				end
				logger:debug("Local death confirmed", { killer = killerName or "none (environmental/other)" })
				deathFeed.ShowDeath(killerName)
				DeathEffect.Play()
				-- Locks out combat input for the rest of this corpse's life -- see isLocalPlayerDead's
				-- own declaration above. Cleared on the next CharacterAdded (respawn), not on a timer.
				isLocalPlayerDead = true
				-- Cuts WASD at the source -- see setControlsEnabled's own declaration above for why
				-- this, not PlatformStand/WalkSpeed, is what actually stops a dead player from still
				-- walking/animating.
				setControlsEnabled(false)
			end
			return
		end

		if payload.Kind == "PostureBreak" then
			-- Biggest impact beat in the exchange: whoever is involved (breaker or broken) gets the
			-- heaviest shake + freeze, and the broken body flashes in the posture-break colour.
			local involved = payload.TargetUserId == localPlayer.UserId or payload.AttackerUserId == localPlayer.UserId
			if involved then
				CameraShake.Shake(Constants.FX.CameraShake.PostureBreak)
				HitStop.FreezePostureBreak()
			end
			local brokenCharacter = getCharacter(payload.TargetUserId)
			if brokenCharacter then
				HitFlash.Flash(brokenCharacter, "PostureBreak")
			end

			local targetName: string? = nil
			if payload.TargetUserId then
				local targetPlayer = Players:GetPlayerByUserId(payload.TargetUserId)
				targetName = if targetPlayer then targetPlayer.Name else nil
			end

			postureBreakGeneration += 1
			local generation = postureBreakGeneration
			combatFeedback.PostureBreak:set({ TargetName = targetName })
			task.delay(Constants.Combat.PostureBreakDuration, function()
				-- Only the most recent posture-break's own timer clears the banner -- see
				-- postureBreakGeneration's own comment for why an unguarded clear here is a bug.
				if postureBreakGeneration == generation then
					combatFeedback.PostureBreak:set(nil)
				end
			end)
			return
		end

		if payload.Kind == "Disarmed" then
			-- AttackerUserId is who got disarmed (CombatSystem.lua's resolveHitAgainstTarget Parry
			-- branch disarms the attacker whose Heavy attack was parried) -- only show this to the
			-- disarmed player themselves; the defender who caused it already gets their own signal
			-- via the "Parried" feedback this always accompanies.
			if payload.AttackerUserId == localPlayer.UserId then
				disarmedGeneration += 1
				local generation = disarmedGeneration
				combatFeedback.Disarmed:set({
					Title = "DISARMED",
					Subtitle = "Cannot attack",
					Color = Tokens.Color.Danger,
				})
				task.delay(Constants.Combat.Disarm.DurationSeconds, function()
					if disarmedGeneration == generation then
						combatFeedback.Disarmed:set(nil)
					end
				end)
			end
			return
		end

		if payload.Kind == "GroundSlam" then
			-- The air-combo's own MaxHits ground slam -- see this event's own dispatch comment
			-- (CombatSystem.lua's onGroundSlam hook) for why it's a separate event instead of a
			-- second "Hit": the landed swing's own "Hit" event for this exchange already ran every
			-- other reaction (damage number, hit-flash, hit-stop, PredictionMirror) above; this only
			-- ever needs to start the ground-impact watch, nothing else.
			beginDownslamWatch(payload)
			return
		end

		-- TargetPosition is authoritative when present (e.g. a training dummy, which has no
		-- TargetUserId to resolve a Player/character from -- see Types.CombatFeedbackPayload's
		-- header). Player-vs-player feedback doesn't set it, so this falls back to the existing
		-- TargetUserId -> Player -> Character resolution for that case. TARGET_HEAD_OFFSET lifts
		-- either source from root-part height (roughly hip/torso) up to roughly head height -- a
		-- fixed offset rather than a real Head part lookup because TargetPosition is a bare Vector3
		-- reported by the server (no live Instance to look up a Head from), so both branches need to
		-- agree on the same approximation to avoid feedback jumping vertically depending on source.
		local position: UDim2? = nil
		if payload.TargetPosition then
			position = worldPositionToScreenUDim2(payload.TargetPosition + TARGET_HEAD_OFFSET)
		elseif payload.TargetUserId then
			local targetPlayer = Players:GetPlayerByUserId(payload.TargetUserId)
			local targetRoot = targetPlayer and getRootPart(targetPlayer)
			if targetRoot then
				position = worldPositionToScreenUDim2(targetRoot.Position + TARGET_HEAD_OFFSET)
			end
		end

		if payload.Kind == "ObjectStun" then
			-- Slammed into world geometry (Server/Combat/ObjectStunResolver.lua). This Kind used to have
			-- no branch of its own at all: it fell through to the Hit/Blocked tail below, which spawned
			-- the bonus-damage number and then matched NEITHER branch -- so the most violent thing that
			-- can happen to a body in this game arrived as a floating number with no shake, no flash, no
			-- freeze, and none of the presentation the Move Editor lets an author set. Everything the
			-- server bothers to put on payload.ObjectStun is consumed here.
			--
			-- Only the FIRST beat -- the contact with the surface itself. The drop that ends a pin
			-- arrives later as its own "GroundSlam" event once the server's own slam physics resolve,
			-- and gets the full SlamImpactVFX ground payoff through beginDownslamWatch above; nothing
			-- about that second beat belongs here.
			local stun = payload.ObjectStun
			if payload.DamageAmount and payload.DamageAmount > 0 then
				combatFeedback.AddDamageHit({ Amount = payload.DamageAmount, Kind = "Heavy", Position = position })
			end

			if payload.AttackerUserId == localPlayer.UserId or payload.TargetUserId == localPlayer.UserId then
				-- CameraShakeScale is the author's own multiplier on this impact's weight (0 disables it
				-- outright), applied to the same FinisherSlam preset every other heavy body-into-something
				-- impact already uses -- a wall slam is exactly that, whatever threw them into it. Built as
				-- a fresh table rather than mutating the preset, which is shared Constants data.
				local shakeScale = if stun then stun.CameraShakeScale else 1
				if shakeScale > 0 then
					local preset = Constants.FX.CameraShake.FinisherSlam
					CameraShake.Shake({
						Amplitude = preset.Amplitude * shakeScale,
						Frequency = preset.Frequency,
						DurationSeconds = preset.DurationSeconds,
					})
				end
			end

			-- isHeavy = true for both freezes: an object stun has no light variant, it is by construction
			-- the heaviest contact the move can produce.
			if payload.AttackerUserId == localPlayer.UserId then
				HitStop.FreezeAttacker(true)
				if stun and stun.AttackerAnimationId ~= "" then
					CombatAnimator.PlayExplicitAnimation(stun.AttackerAnimationId, "ObjectStunAttacker")
				end
			end
			if payload.TargetUserId == localPlayer.UserId then
				HitStop.FreezeVictim(true)
				-- stun.VictimAnimationId is deliberately NOT played. A target reaching an object stun is
				-- ragdolled by definition (that is what carried them into the surface) and the ragdoll owns
				-- the body -- PlatformStand plus disabled Motor6Ds means an AnimationTrack on it produces
				-- no visible pose at all. Playing it anyway would look wired while doing nothing; the
				-- reaction the victim actually sees is the ragdoll itself, the pin, and the drop.
			end

			-- Flashed in the posture-break colour rather than the plain hit white: this is the same
			-- register of event -- a body losing control entirely, not a hit landing on one that still has
			-- it. nil for a bot/dummy target with no TargetUserId, which HitFlash's own contract allows.
			local stunnedCharacter = getCharacter(payload.TargetUserId)
			if stunnedCharacter then
				HitFlash.Flash(stunnedCharacter, "PostureBreak")
			end
			return
		end

		if payload.Kind == "Parried" then
			-- A parry deals no damage -- keep its "PARRIED" text from sharing the screen with a
			-- chip-damage number from an adjacent hit in the same combo (the "PARRIED + a number"
			-- doubled-feedback the parry is meant to read cleanly past). See SuppressDamageNumbers.
			combatFeedback.SuppressDamageNumbers(Constants.Combat.ParryWindowSeconds)
			combatFeedback.SpawnDamageNumber({ Text = "PARRIED", Kind = "Critical", Position = position })
			-- BOTH parties hear the impact. This used to be gated on payload.TargetUserId alone (the
			-- parrier), which meant the player who got parried -- the one the whole beat is happening
			-- TO -- heard nothing at all: they got the stun effect, the shake and the freeze, but the
			-- clash itself was silent on their screen, so the single most important thing that just
			-- happened to them had no audio at all.
			--
			-- Ungated rather than duplicated per side because a parry is one shared event with one
			-- sound, and every other sensory channel on it already treats it that way: the camera
			-- shake and HitStop.FreezeParry a few lines below fire for attacker OR target, and the
			-- server sends this exact payload to both (resolveHitAgainstTarget's two sendFeedback
			-- calls). A bot-vs-player parry delivers only one side of the pair, and that side still
			-- hears it correctly under this.
			--
			-- The Heavy/Basic split is unchanged: a parried hand-to-hand strike (Basic attack, IsHeavy
			-- falsy) gets its own sound rather than the generic block/parry impact -- see
			-- CombatAudio.lua's PlayHandToHandParried header for why that isn't a catch-all parry
			-- sound.
			if payload.AttackerUserId == localPlayer.UserId or payload.TargetUserId == localPlayer.UserId then
				if payload.IsHeavy then
					CombatAudio.PlayBlockImpact()
				else
					CombatAudio.PlayHandToHandParried()
				end
			end
			-- The attacker is the one who gets stunned by a successful parry against them (see
			-- resolveHitAgainstTarget's targetIsParrying branch) -- AttackerUserId, not
			-- TargetUserId, is the local player to check here.
			if payload.AttackerUserId == localPlayer.UserId then
				StunEffect.Play()
			end
			-- A parry is a clash beat -- both parties feel the deflection (shake + a weightier
			-- freeze than a plain hit). The parried attacker's body flashes gold to sell "your
			-- strike bounced."
			if payload.AttackerUserId == localPlayer.UserId or payload.TargetUserId == localPlayer.UserId then
				CameraShake.Shake(Constants.FX.CameraShake.Parry)
				HitStop.FreezeParry()
			end
			local parriedAttacker = getCharacter(payload.AttackerUserId)
			if parriedAttacker then
				HitFlash.Flash(parriedAttacker, "Parry")
			end
			return
		end

		-- Hit / Blocked share the same presentation: a single stacking damage number (see
		-- CombatFeedback.lua's AddDamageHit header for why posture damage no longer gets its own
		-- separate number -- a single click landing both a health and a posture number read as "two
		-- attacks" with no animation system yet to show a single discrete swing).
		combatFeedback.AddDamageHit({
			Amount = payload.DamageAmount or 0,
			Kind = if payload.IsHeavy then "Heavy" else "Normal",
			Position = position,
		})

		local isHeavyHit = payload.IsHeavy == true
		local heavyShake = if isHeavyHit then Constants.FX.CameraShake.HitHeavy else Constants.FX.CameraShake.HitLight

		if payload.Kind == "Blocked" and payload.TargetUserId == localPlayer.UserId then
			CombatAudio.PlayBlockImpact()
			-- A blocked hit still transfers impact to the guard -- a light shake sells the absorbed
			-- blow. No hit-flash/freeze: the block sound + the modest shake are enough for a
			-- mitigated hit, and the block stance shouldn't hitch.
			CameraShake.Shake(Constants.FX.CameraShake.HitLight)
		elseif payload.Kind == "Hit" then
			-- Attacker's and defender's own reactions are independent (not elseif'd against each
			-- other) -- both are legitimately true for the same "Hit" payload, just checked against
			-- different UserId fields, and player-vs-player delivers this exact payload to both.
			if payload.AttackerUserId == localPlayer.UserId then
				-- Attacker's perspective: confirms YOUR hit landed. Unlike a player defender, a
				-- training dummy has no TargetUserId at all (it isn't a Player -- see
				-- resolveHitAgainstDummy's buildFeedbackPayload call), so gating this on
				-- TargetUserId the way Blocked does above would mean it could never fire while
				-- hitting a dummy, the only solo-testable target this combat system has right now.
				CombatAudio.PlayHit()
				-- Attacker impact: contact freeze on your own swing + a shake, and the target's body
				-- flashes (the target may be a dummy with no TargetUserId -- getCharacter returns nil
				-- and the flash is simply skipped, matching HitFlash's contract).
				HitStop.FreezeAttacker(isHeavyHit)
				CameraShake.Shake(heavyShake)
				local hitCharacter = getCharacter(payload.TargetUserId)
				if hitCharacter then
					HitFlash.Flash(hitCharacter, "Hit")
				end
			end
			if payload.TargetUserId == localPlayer.UserId then
				-- Defender's perspective: play OUR OWN Hit1/2/3 reaction, keyed off which Basic
				-- stage the attacker landed (Types.CombatFeedbackPayload.AttackDebugName) -- see
				-- CombatAnimator.PlayHitReaction's own header for the stage-number reuse. The freeze
				-- comes AFTER the reaction starts so it's that reaction's opening (contact) pose that
				-- holds, plus a shake and a flash on our own body.
				CombatAnimator.PlayHitReaction(payload.AttackDebugName)
				HitStop.FreezeVictim(isHeavyHit)
				CameraShake.Shake(heavyShake)
				local ownCharacter = localPlayer.Character
				if ownCharacter then
					HitFlash.Flash(ownCharacter, "Hit")
				end
			end
			-- No ground-impact-VFX dispatch here anymore -- every Downslam-variant origin now sends its
			-- own dedicated "GroundSlam" event once its knockback physics actually resolves (see
			-- beginDownslamWatch's own header above), so this "Hit" event calling it too would fire the
			-- watch a second time for the same landed swing.
		end
	end)

	-- Lock-on reticle tracking: purely presentational screen-space projection of a
	-- server-confirmed target, recomputed every render frame since it follows camera + character
	-- movement -- see LockOnReticle.lua's header for why this doesn't belong in ClientState.
	RunService.RenderStepped:Connect(function()
		local lockOnUserId = currentLockOnUserId
		if lockOnUserId == nil then
			return
		end

		local targetPlayer = Players:GetPlayerByUserId(lockOnUserId)
		local targetRoot = targetPlayer and getRootPart(targetPlayer)
		if not targetPlayer or not targetRoot then
			-- Trace + the Logger's own per-message rate limit (Constants.Debug.Logging.
			-- MaxRepeatsPerSecond) together keep this from flooding Output despite running at
			-- render-step frequency while a lock stays invalid.
			logger:trace("Lock-on target lost: player or root part missing", { targetUserId = lockOnUserId })
			combatFeedback.LockOnTarget:set(nil)
			return
		end

		local screenPosition = worldPositionToScreenUDim2(targetRoot.Position)
		if not screenPosition then
			logger:trace("Lock-on target lost: off-screen or behind camera", { targetUserId = lockOnUserId })
			combatFeedback.LockOnTarget:set(nil)
			return
		end

		combatFeedback.LockOnTarget:set({ ScreenPosition = screenPosition, Name = targetPlayer.Name })
	end)
end

return CombatClient
