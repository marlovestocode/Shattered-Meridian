--!strict
--[[
	OnboardingClient.lua

	Owns: the entire first-time-player onboarding DRIVE -- calling CharacterCreation_GetOnboardingState,
	mounting the cinematic + creator UI (only if NeedsOnboarding), driving the held-input skip/
	held-confirm interactions via its OWN UserInputService listening (deliberately NOT added to
	Types.KeybindAction/Constants.Keybinds -- this is a one-time session-start interaction, not a
	permanent rebindable action), staging the cinematic's text reveals, pointing the real Camera at
	the sky while the cinematic plays, collecting the race/attributes/name selections, and calling
	CharacterCreation_Finalize in a loop until it succeeds.

	OnboardingClient.Run() is a BLOCKING call from Main.client.lua's perspective: it returns
	immediately if NeedsOnboarding is false (a returning player), and otherwise does not return until
	Finalize resolves Success = true. Main.client.lua calls this before UI.Mount() and falls through
	to the existing boot sequence unchanged once it returns -- see that file's own header.

	Creates its OWN temporary Fusion root scope (Fusion.scoped(Fusion)), separate from UI/init.lua's
	session-long scope. This is a narrow, temporally-exclusive exception to "nothing else creates its
	own root scope" (UI/init.lua's header): the two scopes are never alive simultaneously -- this one
	mounts, runs the full flow, calls scope:doCleanup(), and returns BEFORE UI.Mount() is ever called.
	There is no handoff, no shared state, and no risk of two root scopes fighting over the same
	PlayerGui at once.

	Does not own: any validation (CharacterCreationSystem.lua re-validates everything server-side
	regardless of what this module sends), or the screens' own rendering (UI/Screens/Onboarding/*).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local Logger = require(ReplicatedStorage.Shared.Logger)

local OnboardingScreen = require(script.Parent.Parent.UI.Screens.Onboarding)
type OnboardingHandle = OnboardingScreen.OnboardingHandle
type Stage = OnboardingScreen.Stage

local peek = Fusion.peek

local logger = Logger.scope("OnboardingClient")

local Config = Constants.CharacterCreation

local OnboardingClient = {}

--
-- Hold-input gesture -- shared by the cinematic's hold-to-skip and the Confirmation screen's
-- held-commit (same "held input, ~1s" interaction language, per this feature's design). Deliberately
-- its own raw UserInputService listening rather than KeybindManager.Matches -- this is a one-time
-- session-start interaction, not a rebindable action.
--

type HoldGestureResult = "HeldToCompletion" | "TimedOut" | "Cancelled"

-- Keyboard/gamepad half of the gesture. Always global -- there is no ambiguity about what a held
-- Space is aimed at.
local function isHoldGestureKey(input: InputObject): boolean
	return input.KeyCode == Enum.KeyCode.Space
		or input.KeyCode == Enum.KeyCode.Return
		or input.KeyCode == Enum.KeyCode.ButtonA
end

-- Pointer half. Only honored when runHoldGesture is called WITHOUT a pointerHeld Value -- see that
-- function's own note on why the commit gesture can't accept these globally.
local function isHoldGesturePointer(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

-- Blocks the calling thread until the hold gesture completes (HeldToCompletion), `timeoutSeconds`
-- elapses if given (TimedOut), or `isActive()` reports false (Cancelled -- e.g. the player navigated
-- away from this stage via Back). Writes 0-1 progress into `holdProgress` every frame while held,
-- snapping back to 0 the instant the input is released (releasing early cancels progress entirely,
-- the clearest possible feedback that letting go resets the gesture). Always leaves
-- `holdProgress` at 0 on return, regardless of outcome.
--
-- `pointerHeld` scopes the MOUSE/TOUCH half of the gesture to a specific control, and passing it is
-- what separates "skip a cutscene" from "irreversibly create this character."
--
-- Without it, mouse and touch are accepted from anywhere on screen with no hit-testing. For the
-- cinematic skip that's correct and desirable -- tapping anywhere to skip is the expected idiom, and
-- the worst case is that a player skips lore they could have watched. For the Confirmation commit it
-- was a genuine hazard: holding a mouse button over empty space, or resting a thumb on a phone, for
-- one second permanently created the character. There is no re-spec path anywhere in the codebase
-- and CharacterCreationSystem gates purely on `profile.raceId == nil`, so that write is the single
-- least reversible action in the game and it had the loosest possible trigger.
--
-- When supplied, pointer input from UserInputService is ignored entirely and this Value -- driven by
-- the commit control's own press/release -- stands in for it. Keyboard and gamepad stay global
-- either way; a held Space is unambiguous in a way a held mouse button is not.
local function runHoldGesture(
	holdProgress: Fusion.Value<number>,
	holdSeconds: number,
	timeoutSeconds: number?,
	isActive: () -> boolean,
	pointerHeld: Fusion.Value<boolean>?
): HoldGestureResult
	local wakeSignal = Instance.new("BindableEvent")
	local result: HoldGestureResult? = nil
	local isKeyHeld = false
	local elapsed = 0

	local function finish(withResult: HoldGestureResult): ()
		if result == nil then
			result = withResult
			wakeSignal:Fire()
		end
	end

	local function acceptsPointer(input: InputObject): boolean
		return pointerHeld == nil and isHoldGesturePointer(input)
	end

	local inputBeganConnection = UserInputService.InputBegan:Connect(
		function(input: InputObject, gameProcessed: boolean)
			if not gameProcessed and (isHoldGestureKey(input) or acceptsPointer(input)) then
				isKeyHeld = true
			end
		end
	)
	local inputEndedConnection = UserInputService.InputEnded:Connect(function(input: InputObject)
		if isHoldGestureKey(input) or acceptsPointer(input) then
			isKeyHeld = false
		end
	end)

	local heartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime: number)
		if not isActive() then
			finish("Cancelled")
			return
		end

		elapsed += deltaTime
		if timeoutSeconds and elapsed >= timeoutSeconds then
			finish("TimedOut")
			return
		end

		local isHeld = isKeyHeld or (pointerHeld ~= nil and peek(pointerHeld))
		if isHeld then
			local newProgress = math.min(1, peek(holdProgress) + deltaTime / holdSeconds)
			holdProgress:set(newProgress)
			if newProgress >= 1 then
				finish("HeldToCompletion")
			end
		else
			holdProgress:set(0)
		end
	end)

	wakeSignal.Event:Wait()

	inputBeganConnection:Disconnect()
	inputEndedConnection:Disconnect()
	heartbeatConnection:Disconnect()
	wakeSignal:Destroy()
	holdProgress:set(0)
	if pointerHeld then
		-- Leave the control un-stuck for the next attempt: a Finalize failure loops straight back
		-- into another runHoldGesture, and a pointerHeld left true would carry the previous press
		-- into it and re-commit without the player touching anything.
		pointerHeld:set(false)
	end

	return result :: HoldGestureResult
end

--
-- Sky-facing cinematic camera -- Scriptable for the duration of the cinematic (the player is frozen
-- prone server-side with no HUD/input mounted yet), restored to Custom the instant the cinematic
-- ends so the normal camera systems Main.client.lua starts afterward (ShiftLockCamera/FlightCamera)
-- take over cleanly.
--

local function pointCameraAtSky(player: Player): () -> ()
	local camera = Workspace.CurrentCamera
	if not camera then
		return function() end
	end

	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	local origin = if rootPart and rootPart:IsA("BasePart") then (rootPart :: BasePart).Position else Vector3.zero

	camera.CameraType = Enum.CameraType.Scriptable

	local startClock = os.clock()
	local connection = RunService.RenderStepped:Connect(function()
		-- A slow ambient yaw drift while looking almost straight up -- a static shot would read as
		-- frozen/broken rather than deliberate; docs/ui-ux-philosophy.md's Animation Philosophy calls
		-- for controlled, intentional motion, not a hard lock.
		local yaw = (os.clock() - startClock) * 0.05
		camera.CFrame = CFrame.new(origin) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(-math.rad(78), 0, 0)
	end)

	return function()
		connection:Disconnect()
		camera.CameraType = Enum.CameraType.Custom
	end
end

--
-- Cinematic stage -- staged text reveals (Cinematic.lua's own CINEMATIC_LINES, four lines) paced
-- against Constants.CharacterCreation.CinematicDurationSeconds, skippable via the shared hold
-- gesture above. CINEMATIC_LINE_COUNT must match Cinematic.lua's own line count -- both are static,
-- authored content, so this is a documented coupling rather than a shared constant neither module
-- really needs to read at runtime.
--

local CINEMATIC_LINE_COUNT = 4

local function runCinematicStage(handle: OnboardingHandle): ()
	local revealInterval = Config.CinematicDurationSeconds / CINEMATIC_LINE_COUNT
	-- os.clock() is process-wide, not "since this stage started" -- every reveal-timing read below is
	-- relative to this captured baseline, not raw os.clock().
	local stageStart = os.clock()
	local revealConnection = RunService.Heartbeat:Connect(function()
		local elapsed = os.clock() - stageStart
		local nextIndex = math.min(CINEMATIC_LINE_COUNT, math.floor(elapsed / revealInterval) + 1)
		if peek(handle.Cinematic.RevealIndex) < nextIndex then
			handle.Cinematic.RevealIndex:set(nextIndex)
		end
		-- "The skip affordance should fade in at ~t=4s, not t=0" (designer direction) -- a one-way
		-- latch, never set back to false, so a slow frame that overshoots the threshold still catches
		-- it on the very next Heartbeat.
		if elapsed >= Config.SkipHintRevealSeconds and not peek(handle.Cinematic.SkipHintRevealed) then
			handle.Cinematic.SkipHintRevealed:set(true)
		end
	end)

	-- isActive always true: the only two ways out of the cinematic are a completed hold-to-skip or
	-- the CinematicDurationSeconds timeout, both already handled by runHoldGesture's own
	-- holdSeconds/timeoutSeconds parameters -- there is no "Back" out of the cinematic to cancel into.
	runHoldGesture(handle.Cinematic.HoldProgress, Config.HoldToSkipSeconds, Config.CinematicDurationSeconds, function()
		return true
	end)

	revealConnection:Disconnect()
end

--
-- Stage navigation -- ordinary Continue/Back button presses (not held gestures) between the four
-- creator screens.
--

-- .Event:Connect (not :Connect directly) on every one of these -- handle.RaceSelect.
-- ContinueRequested etc. are the raw BindableEvent Instances (see Onboarding/Types.lua's own header
-- on why), and only their .Event property is the connectable RBXScriptSignal.
local function wireNavigation(handle: OnboardingHandle): { RBXScriptConnection }
	return {
		handle.RaceSelect.ContinueRequested.Event:Connect(function()
			handle.Stage:set("Attributes")
		end),
		handle.Attributes.ContinueRequested.Event:Connect(function()
			handle.Stage:set("NameEntry")
		end),
		handle.Attributes.BackRequested.Event:Connect(function()
			handle.Stage:set("RaceSelect")
		end),
		handle.NameEntry.ContinueRequested.Event:Connect(function()
			handle.Stage:set("Confirmation")
		end),
		handle.NameEntry.BackRequested.Event:Connect(function()
			handle.Stage:set("Attributes")
		end),
		-- No handle.Confirmation.BackRequested -- that field no longer exists (Types.lua's own
		-- ConfirmationProps comment). Confirmation.lua's three labeled escape hatches fire
		-- StepRailNavigateRequested directly instead, handled by the connection below.
		-- StepRail.lua and Confirmation.lua's three escape hatches only ever fire this with a Stage
		-- that's already "behind" the current one (a real earlier stage, never Cinematic), so no
		-- re-validation of the target happens here -- same trust level as every other purely-local
		-- navigation signal above; the server re-validates everything real (race/attributes/name) at
		-- Finalize regardless of how the player got to Confirmation.
		handle.StepRailNavigateRequested.Event:Connect(function(targetStage: Stage)
			handle.Stage:set(targetStage)
		end),
	}
end

-- Same "InvokeServer errored or not, land on a message string" translation
-- BugReportClient.describeSubmitResult already establishes, one per CharacterCreationFinalizeResult.
-- Reason -- now also paired with the Stage that fixes it (docs/design/intro-redesign-handoff.md's
-- designer direction: "pair each Finalize failure with the jump that fixes it"). nil means there's
-- no earlier stage that would help (a raw request/filter/server failure -- retrying as-is is the
-- only real remedy), which also means it can never trigger the auto-jump in runConfirmationLoop
-- below, regardless of how many times it repeats.
local function describeFinalizeFailure(reason: string?): (string, Stage?)
	if reason == "InvalidRaceId" then
		return "Choose a race before confirming.", "RaceSelect"
	elseif reason == "AttributeBudgetInvalid" or reason == "OutOfRange" or reason == "BudgetMismatch" then
		return "Your attribute allocation isn't valid -- go back and check Points Remaining is 0.", "Attributes"
	elseif
		reason == "InvalidDisplayName"
		or reason == "TooShort"
		or reason == "TooLong"
		or reason == "InvalidCharacter"
	then
		return "Your name isn't valid -- go back and try a different one.", "NameEntry"
	elseif reason == "Denylisted" then
		return "That name isn't allowed -- please choose another.", "NameEntry"
	elseif reason == "FilterFailed" then
		return "Couldn't process your name -- please try again.", nil
	elseif reason == "AlreadyOnboarded" then
		return "You've already created a character.", nil
	end
	return "Something went wrong -- please try again.", nil
end

-- After this many CONSECUTIVE Finalize failures with the same Reason (and thus the same fix Stage),
-- runConfirmationLoop jumps there automatically instead of waiting for the player to notice the
-- message and act themselves -- the designer's own "after two consecutive failures of the same
-- reason, jump automatically."
local AUTO_JUMP_AFTER_CONSECUTIVE_FAILURES = 2

-- Success beat (designer direction: "on Success = true, fracture-out everything except the name,
-- hold it alone in the void for ~1.2s, then hand off to the arrival teleport"). The actual teleport
-- already happened server-side inside handleFinalize before this client ever sees Success = true
-- (CharacterCreationSystem.lua's own failure-handling contract requires the PivotTo to complete
-- before returning success) -- this beat is purely the client holding the reveal a moment longer
-- before tearing the onboarding UI down, not something that needs to race the teleport.
local SUCCESS_BEAT_SECONDS = 1.2

-- Blocking loop: drives Confirmation's held-commit gesture, calls CharacterCreation_Finalize, and
-- retries on a Success = false response (showing StatusText) rather than stranding the player --
-- same reject-and-retry UX BugReportClient.lua establishes for BugReport_Submit. Returns only once
-- Finalize resolves Success = true.
local function runConfirmationLoop(handle: OnboardingHandle): ()
	local finalizeRemote = NetworkBridge.GetRemoteFunction(Config.RemoteNames.Finalize)

	-- Tracks consecutive Finalize rejections with the SAME Reason, across attempts, regardless of
	-- what the player does in between (manually jumping away and back doesn't reset it) -- see
	-- AUTO_JUMP_AFTER_CONSECUTIVE_FAILURES's own comment.
	local lastFailureReason: string? = nil
	local consecutiveFailureCount = 0

	while true do
		local gestureResult = runHoldGesture(
			handle.Confirmation.HoldProgress,
			Config.HoldToConfirmSeconds,
			nil,
			function()
				return peek(handle.Stage) == "Confirmation" and not peek(handle.Confirmation.IsSubmitting)
			end,
			-- Scopes mouse/touch to the commit button itself -- see runHoldGesture's own note.
			handle.Confirmation.CommitPointerHeld
		)

		if gestureResult == "Cancelled" then
			-- The player navigated away (Back, an escape hatch, or an auto-jump below) mid-hold --
			-- nothing to submit; loop again once/if they return to this stage. task.wait() avoids a
			-- tight busy loop while parked here.
			task.wait()
			continue
		end

		handle.Confirmation.IsSubmitting:set(true)
		handle.Confirmation.StatusText:set("")

		local payload: Types.CharacterCreationFinalizePayload = {
			RaceId = peek(handle.RaceSelect.SelectedRaceId),
			DisplayName = peek(handle.NameEntry.DisplayName),
			Attributes = peek(handle.Attributes.Attributes),
		}

		local invokeOk, resultOrError = pcall(function()
			return finalizeRemote:InvokeServer(payload)
		end)

		handle.Confirmation.IsSubmitting:set(false)

		if not invokeOk then
			logger:error("Finalize request errored", { errorMessage = tostring(resultOrError) })
			handle.Confirmation.StatusText:set("Request failed -- please try again.")
			continue
		end

		local result = resultOrError :: Types.CharacterCreationFinalizeResult
		if result.Success then
			logger:info("Finalize succeeded -- onboarding complete")
			-- See SUCCESS_BEAT_SECONDS' own comment -- Confirmation.lua fades everything but the name
			-- out reactively off this flip; the wait here is the "hold" half of that beat, not
			-- something the fade animation itself needs to be awaited for.
			handle.Confirmation.IsSucceeding:set(true)
			task.wait(SUCCESS_BEAT_SECONDS)
			return
		end

		logger:warn("Finalize rejected", { reason = result.Reason })
		local message, fixStage = describeFinalizeFailure(result.Reason)
		handle.Confirmation.StatusText:set(message)

		if result.Reason == lastFailureReason then
			consecutiveFailureCount += 1
		else
			lastFailureReason = result.Reason
			consecutiveFailureCount = 1
		end

		if fixStage and consecutiveFailureCount >= AUTO_JUMP_AFTER_CONSECUTIVE_FAILURES then
			logger:info("Auto-jumping after repeated Finalize failures", {
				reason = result.Reason,
				fixStage = fixStage,
			})
			-- Reset rather than leave at the threshold -- the player gets another
			-- AUTO_JUMP_AFTER_CONSECUTIVE_FAILURES attempts before this fires again, instead of
			-- forcibly jumping them away on every single subsequent failure.
			consecutiveFailureCount = 0
			handle.StepRailNavigateRequested:Fire(fixStage)
		end
	end
end

function OnboardingClient.Run(): ()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

	local stateRemote = NetworkBridge.GetRemoteFunction(Config.RemoteNames.GetOnboardingState)
	local stateOk, stateResultOrError = pcall(function()
		return stateRemote:InvokeServer()
	end)
	if not stateOk then
		-- Fails open: this call is also the session's first LoadCharacter trigger server-side (see
		-- CharacterCreationSystem.lua's header), so a failure here is a genuine boot problem, not
		-- something this module can meaningfully retry into working. Logged loudly; the rest of
		-- Main.client.lua's boot sequence still runs rather than hanging forever.
		logger:error("GetOnboardingState request errored", { errorMessage = tostring(stateResultOrError) })
		return
	end

	local stateResult = stateResultOrError :: Types.CharacterCreationOnboardingStateResult
	if not stateResult.NeedsOnboarding then
		logger:debug("Returning player -- no onboarding needed")
		return
	end

	logger:info("First-time player detected -- running onboarding flow")

	local scope = Fusion.scoped(Fusion)
	local handle = OnboardingScreen.Mount(scope, playerGui)

	local restoreCamera = pointCameraAtSky(player)
	runCinematicStage(handle)
	restoreCamera()

	handle.Stage:set("RaceSelect")
	local navigationConnections = wireNavigation(handle)

	runConfirmationLoop(handle)

	for _, connection in navigationConnections do
		connection:Disconnect()
	end
	scope:doCleanup()

	logger:info("Onboarding complete -- Fusion scope torn down")
end

return OnboardingClient
