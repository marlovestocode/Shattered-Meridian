--!strict
--[[
	IntroClient.lua

	Owns: the top-level cinematic-intro sequence, end to end -- replaces the direct
	OnboardingClient.Run() call Main.client.lua used to make. This is the "IntroController" the
	rework's design calls for: it drives the whole Stage sequence (lying pose -> camera pan timed to
	the cinematic -> character creation -> black screen -> [server-side race-keyed teleport, already
	complete by the time Finalize returns Success = true] -> first-person blur/blink reveal -> get-up
	animation with the camera following -> greeting banner -> handoff to normal gameplay), delegating
	the character-creation screens/input to Client/Onboarding/OnboardingClient.lua's own exports
	rather than duplicating any of that machinery, and delegating the camera/vision-FX/black-screen
	pieces to this same folder's IntroCamera.lua/VisionEffects.lua/BlackScreen.lua.

	IntroClient.Run() is a BLOCKING call from Main.client.lua's perspective, the same contract
	OnboardingClient.Run() used to have: it returns immediately if the player doesn't need onboarding
	(a returning player, or a failed OnboardingClient.FetchOnboardingState -- see that function's own
	header for why a failure there fails open rather than retrying), and otherwise does not return
	until the full awakening sequence -- including the greeting banner -- has played out. Main.client.
	lua calls this before UI.Mount() and falls through to the existing boot sequence unchanged once it
	returns; camera systems (ShiftLockCamera/FlightCamera/CameraShake) only start after this returns,
	which is what lets Client/Intro/IntroCamera.lua hold Scriptable camera control uncontested for the
	whole sequence and hand back to Custom cleanly at the end (see that module's own header).

	Creates its OWN temporary Fusion root scope (Fusion.scoped(Fusion)) -- the same narrow,
	temporally-exclusive exception to UI/init.lua's "nothing else creates its own root scope" rule
	OnboardingClient.lua used to take before this rework (see OnboardingClient.MountCreator's own
	comment). Mounts BOTH the Onboarding creator screens (via OnboardingClient.MountCreator) and the
	black screen cover (BlackScreen.Mount) under this ONE scope, and tears the whole thing down in one
	scope:doCleanup() at the very end -- the Onboarding ScreenGui is left mounted (not torn down early)
	once character creation finishes; it simply stays covered by BlackScreen's own higher DisplayOrder
	until everything is destroyed together, which is simpler than re-parenting or juggling two scope
	lifetimes for no player-visible benefit.

	Owns loading/playing the two intro AnimationTracks directly (via Shared/AnimatorUtil.lua, the same
	find-or-create-Animator plumbing Client/FX/CombatAnimator.lua/Server/Combat/BotAnimator.lua share)
	rather than routing through CombatAnimator.lua -- that module's own exclusive-action/dominant-track
	bookkeeping exists for COMBAT clips and isn't bound to a character yet at this point in boot
	(CombatClient.Start(), which calls CombatAnimator.BindCharacter, only runs after this whole
	function returns). These two clips are simple enough (one looped pose, one one-shot) that owning
	them here directly is less machinery than reaching into a system that isn't running yet.

	Does not own: validation (CharacterCreationSystem.lua re-validates everything server-side), the
	creator screens' own rendering, or the Frozen/Godmode/Invisible isolation lifecycle itself
	(CharacterCreationSystem.lua owns granting and clearing it server-side; this module only fires the
	CharacterCreation_AwakeningComplete signal that tells it to clear).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local AnimatorUtil = require(ReplicatedStorage.Shared.AnimatorUtil)
local Logger = require(ReplicatedStorage.Shared.Logger)

local OnboardingClient = require(script.Parent.Parent.Onboarding.OnboardingClient)
local IntroCamera = require(script.Parent.IntroCamera)
local VisionEffects = require(script.Parent.VisionEffects)
local BlackScreen = require(script.Parent.BlackScreen)
local PostureBreakBanner = require(script.Parent.Parent.UI.Components.PostureBreakBanner)
local Tokens = require(script.Parent.Parent.UI.Tokens)

type Scope = Fusion.Scope<typeof(Fusion)>

local peek = Fusion.peek
local Children = Fusion.Children

local logger = Logger.scope("IntroClient")

local IntroClient = {}

-- Blocks until `character` actually has a live body -- the RemoteFunction round-trip
-- OnboardingClient.FetchOnboardingState makes already triggered player:LoadCharacterAsync()
-- server-side (CharacterCreationSystem.handleGetOnboardingState), but that's no guarantee
-- Character has finished replicating to THIS client the instant the response arrives.
local function waitForCharacter(player: Player): Model
	return player.Character or player.CharacterAdded:Wait()
end

-- Loads and plays one of the two placeholder Constants.Intro.AnimationIds clips against `animator`.
-- Deliberately NOT cached/reused the way CombatAnimator.lua's `tracks` table is -- each of the two
-- clips this module ever plays is played exactly once per intro, so there's nothing to cache. Returns
-- nil (logged, never thrown) on a load failure -- callers treat that as "no track to wait on" rather
-- than stalling the sequence on a missing/invalid asset id.
local function loadAndPlay(animator: Animator, animationId: string, looped: boolean): AnimationTrack?
	local animation = Instance.new("Animation")
	animation.AnimationId = animationId
	local ok, trackOrError = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not ok then
		logger:warn(
			"Failed to load intro animation",
			{ animationId = animationId, errorMessage = tostring(trackOrError) }
		)
		return nil
	end
	local track = trackOrError :: AnimationTrack
	track.Looped = looped
	track:Play()
	return track
end

-- Blocks until `track` stops (naturally finishing, for a non-looped track) or `fallbackSeconds`
-- elapses, whichever comes first -- the fallback is what keeps a missing/failed-to-load GetUp clip
-- (track == nil, or one that never fires Stopped for some other reason) from stalling the whole
-- sequence forever, since Constants.Intro.AnimationIds ships with placeholder ids this pass. `finish`
-- is idempotent (same "either path wins exactly once" shape OnboardingClient.runHoldGesture's own
-- `finish` uses) so a late fallback firing after Stopped already resolved this is a harmless no-op.
local function waitForTrackStop(track: AnimationTrack?, fallbackSeconds: number): ()
	if not track then
		task.wait(fallbackSeconds)
		return
	end

	local wakeSignal = Instance.new("BindableEvent")
	local done = false
	local function finish(): ()
		if done then
			return
		end
		done = true
		wakeSignal:Fire()
	end

	local stoppedConnection = track.Stopped:Once(finish)
	task.delay(fallbackSeconds, finish)

	wakeSignal.Event:Wait()
	stoppedConnection:Disconnect()
	wakeSignal:Destroy()
end

-- Mounts the greeting banner (reusing UI/Components/PostureBreakBanner.lua's generic StatusBanner
-- directly -- see this feature's design notes) into its OWN ScreenGui under `scope`, holds it for
-- Constants.Intro.Greeting.HoldSeconds, then clears it. Display starts nil (not the real greeting)
-- so StatusBanner's own FadeSpring actually animates the entrance on the very next value -- mounting
-- already-non-nil would settle the spring at 1 on frame one with no visible fade.
local function showGreetingBanner(scope: Scope, playerGui: PlayerGui, raceId: Types.RaceId?, displayName: string): ()
	local Config = Constants.CharacterCreation

	local display: Fusion.Value<PostureBreakBanner.StatusBannerDisplay?> =
		scope:Value(nil :: PostureBreakBanner.StatusBannerDisplay?)

	scope:New "ScreenGui" {
		Name = "Greeting",
		ResetOnSpawn = false,
		Enabled = true,
		DisplayOrder = 5,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = playerGui,

		[Children] = PostureBreakBanner.StatusBanner(scope, { Display = display }),
	}

	local greetedName = if displayName ~= "" then displayName else "traveler"
	local subtitle = if raceId then `{raceId} -- {Config.RaceEpithets[raceId] or ""}` else ""

	display:set({
		Title = `Awaken, {greetedName}.`,
		Subtitle = subtitle,
		Color = Tokens.Color.AccentPrimary,
	})

	task.wait(Constants.Intro.Greeting.HoldSeconds)
	display:set(nil)
	-- Lets StatusBanner's own fade-out spring settle before this whole scope (and the banner with
	-- it) gets destroyed underneath it -- same reasoning OnboardingClient's SUCCESS_BEAT_SECONDS
	-- comment gives for holding past a fade rather than cutting it off mid-animation.
	task.wait(0.4)
end

-- AdminActionSystem.ApplyInvisible (server) sets real Transparency = 1 on every BasePart/Decal,
-- replicated to every client INCLUDING this one -- so without this, the local player would be
-- unable to see their own body rise during the get-up follow below, even though the camera is
-- right there watching it happen. LocalTransparencyModifier is the standard Roblox mechanism for
-- "hidden from everyone else, visible to me": it's added to a part's real Transparency but only
-- takes effect in this client's own render, never replicated, so other players still see nothing
-- (server Transparency stays 1, satisfying this feature's isolation requirement) while this client
-- renders the character normally. `modifier = -1` cancels ApplyInvisible's Transparency = 1 exactly;
-- resetting back to 0 once isolation is about to be cleared server-side avoids leaving a stray
-- override sitting on the character for the rest of the session.
--
-- Skips HumanoidRootPart deliberately: it's invisible by design in every Roblox rig (Transparency
-- = 1 from the moment the character loads, nothing to do with ApplyInvisible), not something
-- ApplyInvisible put there -- applying the same -1 cancel to it would force Roblox's own always-
-- hidden root collision box to render, showing up as a visible block at the character's torso.
local function setLocalOnlyVisible(character: Model, modifier: number): ()
	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("BasePart") then
			if descendant.Name ~= "HumanoidRootPart" then
				(descendant :: BasePart).LocalTransparencyModifier = modifier
			end
		elseif descendant:IsA("Decal") then
			(descendant :: Decal).LocalTransparencyModifier = modifier
		end
	end
end

-- The awakening beat: first-person anchor -> black hold -> blur/blink reveal -> get-up animation
-- with the camera following -> release camera -> tell the server the isolation window is over.
--
-- `onboardingRoot` is the character-creation ScreenGui (OnboardingHandle.Root) -- BlackScreen only
-- covers it by DisplayOrder while opaque, and BlackScreen goes transparent again a few lines below
-- (once the reveal begins) while the creator UI is still mounted underneath. Disabling it here,
-- before that fade-out, is what actually keeps "Before You Begin" from reappearing over the
-- awakening world for the rest of the sequence -- it was never torn down (see IntroClient.lua's own
-- header), only ever covered, and covering alone isn't enough once the cover itself goes away.
local function playAwakening(
	player: Player,
	blackScreen: BlackScreen.BlackScreenHandle,
	onboardingRoot: ScreenGui,
	lyingTrack: AnimationTrack?
): ()
	local character = waitForCharacter(player)
	local animator = AnimatorUtil.GetOrCreateAnimator(character)

	IntroCamera.EnterFirstPersonAnchor(player)

	VisionEffects.EnterBlackout()
	task.wait(Constants.Intro.Vision.BlackHoldSeconds)
	onboardingRoot.Enabled = false
	blackScreen.IsOpaque:set(false)
	VisionEffects.PlayReveal()

	if lyingTrack then
		lyingTrack:Stop()
	end

	-- Self-visible from here on -- see setLocalOnlyVisible's own header. Not enabled any earlier
	-- (the black/blur reveal is about the environment coming into focus, not the player's own body)
	-- and not delayed any later (the get-up follow's whole point is watching the body rise with it).
	setLocalOnlyVisible(character, -1)

	local followDuration = Constants.Intro.Camera.GetUpFollowDurationSeconds
	IntroCamera.BeginGetUpFollow(player, followDuration)

	local getUpTrack = if animator then loadAndPlay(animator, Constants.Intro.AnimationIds.GetUp, false) else nil
	waitForTrackStop(getUpTrack, followDuration)

	IntroCamera.Release()

	local awakeningCompleteRemote =
		NetworkBridge.GetRemoteEvent(Constants.CharacterCreation.RemoteNames.AwakeningComplete)
	awakeningCompleteRemote:FireServer()
	setLocalOnlyVisible(character, 0)
	logger:info("Awakening beat complete -- isolation release requested")
end

function IntroClient.Run(): ()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

	local stateResult = OnboardingClient.FetchOnboardingState()
	if not stateResult or not stateResult.NeedsOnboarding then
		logger:debug("No cinematic intro needed for this player")
		return
	end

	logger:info("First-time player detected -- running cinematic intro")

	local scope = Fusion.scoped(Fusion)
	local handle = OnboardingClient.MountCreator(scope, playerGui)
	local blackScreen = BlackScreen.Mount(scope, playerGui)

	local character = waitForCharacter(player)
	local animator = AnimatorUtil.GetOrCreateAnimator(character)
	local lyingTrack = if animator then loadAndPlay(animator, Constants.Intro.AnimationIds.LyingDown, true) else nil

	IntroCamera.BeginCinematic(player)
	OnboardingClient.RunCinematicStage(handle, IntroCamera.UpdateCinematicProgress)
	IntroCamera.HoldOverheadComposition()

	handle.Stage:set("RaceSelect")
	local navigationConnections = OnboardingClient.WireNavigation(handle)

	OnboardingClient.RunConfirmationLoop(handle, function()
		-- Fires the instant Finalize resolves Success = true -- concurrent with Confirmation.lua's
		-- own 1.2s fracture-out hold (BlackScreen's FadeSpring settles well inside that), per this
		-- feature's design.
		blackScreen.IsOpaque:set(true)
	end)

	for _, connection in navigationConnections do
		connection:Disconnect()
	end

	-- The server has already teleported this character into its race-keyed arrival spawn by now --
	-- CharacterCreationSystem.lua's own failure-handling contract requires the PivotTo to complete
	-- before Finalize ever returns Success = true, and RunConfirmationLoop only returns after that.
	local raceId = peek(handle.RaceSelect.SelectedRaceId)
	local displayName = peek(handle.NameEntry.DisplayName)

	playAwakening(player, blackScreen, handle.Root, lyingTrack)
	showGreetingBanner(scope, playerGui, raceId, displayName)

	scope:doCleanup()
	logger:info("Cinematic intro complete -- scope torn down")
end

return IntroClient
