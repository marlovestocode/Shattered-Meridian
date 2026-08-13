--!strict
--[[
	OnboardingClient.lua

	Owns: driving the character-creation SCREENS -- fetching whether this session's player needs
	onboarding at all (FetchOnboardingState), mounting the cinematic + creator UI into a scope the
	caller provides (MountCreator), staging the cinematic's text reveals and its hold-to-skip gesture
	(RunCinematicStage), wiring Continue/Back/step-rail navigation between the four creator screens
	(WireNavigation), and the held-confirm gesture + CharacterCreation_Finalize retry loop
	(RunConfirmationLoop). Every one of these is now an explicit, separately-callable export rather
	than one internal, top-level Run() -- Client/Intro/IntroClient.lua is the orchestrator that calls
	each in sequence, interleaving them with the lying pose / camera pan / black screen / teleport /
	first-person reveal / get-up / greeting banner it owns instead. This module has no idea any of
	that surrounds it; it only knows how to drive the four creator screens themselves.

	Does NOT create its own Fusion scope anymore (the pre-rework version did -- see MountCreator's own
	comment for why that narrow exception moved up to IntroClient.lua instead) and does NOT point the
	camera anywhere (pointCameraAtSky is deleted -- Client/Intro/IntroCamera.lua owns the camera for
	the whole intro now, including the cinematic stage this module still drives the TEXT/gesture side
	of).

	Does not own: any validation (CharacterCreationSystem.lua re-validates everything server-side
	regardless of what this module sends), the screens' own rendering (UI/Screens/Onboarding/*), or
	anything about the sequence around character creation (Client/Intro/IntroClient.lua).
]]

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local Logger = require(ReplicatedStorage.Shared.Logger)

local OnboardingScreen = require(script.Parent.Parent.UI.Screens.Onboarding)
type OnboardingHandle = OnboardingScreen.OnboardingHandle
type Stage = OnboardingScreen.Stage
type Scope = Fusion.Scope<typeof(Fusion)>

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

-- Fetches whether the local player needs onboarding, also triggering this SESSION's first
-- Player:LoadCharacter() server-side (CharacterCreationSystem.handleGetOnboardingState) for every
-- player, onboarding or not. Returns nil on a request error -- logged here, since a failure here is
-- a genuine boot problem this module can't meaningfully retry into working; Client/Intro/
-- IntroClient.lua treats nil the same as "no onboarding needed" and lets the rest of the client boot
-- sequence proceed rather than hanging forever.
function OnboardingClient.FetchOnboardingState(): Types.CharacterCreationOnboardingStateResult?
	local stateRemote = NetworkBridge.GetRemoteFunction(Config.RemoteNames.GetOnboardingState)
	local ok, resultOrError = pcall(function()
		return stateRemote:InvokeServer()
	end)
	if not ok then
		logger:error("GetOnboardingState request errored", { errorMessage = tostring(resultOrError) })
		return nil
	end
	return resultOrError :: Types.CharacterCreationOnboardingStateResult
end

-- Mounts the cinematic + creator UI into `scope` -- a scope the CALLER owns and tears down (Client/
-- Intro/IntroClient.lua creates one Fusion.scoped(Fusion) root for the whole intro sequence and
-- mounts this alongside Client/Intro/BlackScreen.lua under it). This module no longer creates its
-- own root scope the way the pre-rework version did: that was a narrow, temporally-exclusive
-- exception to UI/init.lua's "nothing else creates its own root scope" rule, justified because the
-- whole onboarding flow mounted, ran, and tore down before UI.Mount() ever ran. The exception itself
-- still holds -- it just belongs to IntroClient.lua now, since IT is the top-level blocking call
-- Main.client.lua makes before UI.Mount(), the same relationship OnboardingClient.Run() used to have.
function OnboardingClient.MountCreator(scope: Scope, playerGui: PlayerGui): OnboardingHandle
	return OnboardingScreen.Mount(scope, playerGui)
end

--
-- Cinematic stage -- staged text reveals (Cinematic.lua's own CINEMATIC_LINES, four lines) paced
-- against Constants.CharacterCreation.CinematicDurationSeconds, skippable via the shared hold
-- gesture above. CINEMATIC_LINE_COUNT must match Cinematic.lua's own line count -- both are static,
-- authored content, so this is a documented coupling rather than a shared constant neither module
-- really needs to read at runtime.
--

local CINEMATIC_LINE_COUNT = 4

-- Blocks until the cinematic stage ends (played out fully, or hold-to-skipped). `onProgress`, if
-- given, is called every Heartbeat with the same elapsed/CinematicDurationSeconds fraction (clamped
-- to [0, 1]) this function already computes for its own text-reveal pacing -- Client/Intro/
-- IntroCamera.UpdateCinematicProgress is the one caller, so the cinematic's camera pan and its text
-- reveals are driven off the identical clock rather than two independently-drifting timers.
function OnboardingClient.RunCinematicStage(
	handle: OnboardingHandle,
	onProgress: ((elapsedFraction: number) -> ())?
): ()
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
		if onProgress then
			onProgress(math.clamp(elapsed / Config.CinematicDurationSeconds, 0, 1))
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
function OnboardingClient.WireNavigation(handle: OnboardingHandle): { RBXScriptConnection }
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
-- only real remedy), which also means it can never trigger the auto-jump in RunConfirmationLoop
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
-- before Client/Intro/IntroClient.lua moves on to the black screen, not something that needs to race
-- the teleport.
local SUCCESS_BEAT_SECONDS = 1.2

-- Blocking loop: drives Confirmation's held-commit gesture, calls CharacterCreation_Finalize, and
-- retries on a Success = false response (showing StatusText) rather than stranding the player --
-- same reject-and-retry UX BugReportClient.lua establishes for BugReport_Submit. Returns only once
-- Finalize resolves Success = true, after holding SUCCESS_BEAT_SECONDS.
--
-- `onSuccess`, if given, fires the INSTANT Finalize resolves Success = true -- before the
-- SUCCESS_BEAT_SECONDS hold -- so a caller can start something meant to run CONCURRENTLY with
-- Confirmation.lua's own fracture-out (e.g. Client/Intro/IntroClient.lua fading BlackScreen.lua's
-- cover in) rather than only after this function fully returns.
function OnboardingClient.RunConfirmationLoop(handle: OnboardingHandle, onSuccess: (() -> ())?): ()
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
			if onSuccess then
				onSuccess()
			end
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

return OnboardingClient
