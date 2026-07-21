--!strict
--[[
	FlightAnimator.lua

	Owns: loading and playing the LOCAL player's own flight animations (a Hover idle loop, a
	CruiseLoop for forward flight, a BoostLoop while boosting, and one-shot Takeoff/LandingSoft/
	LandingHard clips) while their Humanoid's "Flying" Attribute is true. A sibling to
	Client/FX/CombatAnimator.lua, copying its proven shape (own animation-id registry, own
	BindCharacter-loads-everything-once, own persistent Heartbeat loop-eligibility evaluator built on
	the shared Client/FX/AnimationTrackUtil.lua evaluator/freeze-guard the two files now both use,
	DOMINANT_WEIGHT priority-forcing) rather than folding flight tracks into that module's shared
	`tracks` dict -- CombatAnimator.lua's own header scopes it to combat, triggered only by
	CombatClient.lua off server-confirmed combat events; flight is triggered by a Humanoid Attribute
	from an unrelated caller (Client/DevMenu/FlightController.lua), and CombatAnimator.
	FreezeActiveCombatTrack (combat hit-stop) would otherwise incidentally freeze flight animations
	and vice versa if the two shared one track dict (this is also why each file constructs its OWN
	FreezeGuard instance from that shared module rather than the two sharing one generation counter
	-- see FreezeGuard's own header).

	All six Constants.Flight.AnimationIds entries ship as empty-string placeholders (the same
	wired-but-unauthored convention Constants.Combat.AnimationIds already established for Heavy1/
	Heavy2/etc) -- every play path below degrades to a silent no-op until a real rbxassetid is
	supplied, no code change needed once one is.

	Does not own: deciding WHEN flight starts/stops or which loop state is active (FlightController.
	lua's stepFlight computes speed/isBoosting every frame and pushes it in via SetFlightMotion), or
	the takeoff/landing CLASSIFICATION (soft vs hard, grounded vs airborne -- FlightController.lua's
	own detection logic decides that and just calls PlayTakeoff/PlayLandingSoft/PlayLandingHard here).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local AnimatorUtil = require(ReplicatedStorage.Shared.AnimatorUtil)
local AnimationTrackUtil = require(script.Parent.AnimationTrackUtil)

local logger = Logger.scope("FlightAnimator")

local FlightAnimator = {}

local ANIMATION_IDS = Constants.Flight.AnimationIds

-- Same reasoning as CombatAnimator.lua's own DOMINANT_WEIGHT: a single Play()-time weight isn't
-- enough for a sustained/held track, since Roblox's default Animate script keeps re-asserting its
-- own track's weight on every Humanoid movement-state change -- the loop evaluator below re-calls
-- AdjustWeight every Heartbeat instead of trusting one Play() call to stick. Now Constants.FX.
-- Animation.DominantWeight/Flight -- shared with Server/Combat/BotAnimator.lua and Client/FX/
-- CombatAnimator.lua (DominantWeight) -- see that table's own header in Constants.lua for why these
-- were independently hand-typed here before (ONE_SHOT_FADE_TIME/LOOP_FADE_TIME).
local DOMINANT_WEIGHT = Constants.FX.Animation.DominantWeight
local ONE_SHOT_FADE_TIME = Constants.FX.Animation.Flight.OneShotFadeSeconds
local LOOP_FADE_TIME = Constants.FX.Animation.Flight.LoopFadeSeconds

local animationTemplates: { [string]: Animation } = {}
for name, id in pairs(ANIMATION_IDS) do
	if id ~= "" then
		local animation = Instance.new("Animation")
		animation.Name = name
		animation.AnimationId = id
		animationTemplates[name] = animation
	end
end

local tracks: { [string]: AnimationTrack } = {}
local currentHumanoid: Humanoid? = nil

-- Pushed every frame by FlightController.lua's stepFlight -- read only by the loop evaluator below.
local currentSpeed = 0
local currentlyBoosting = false

function FlightAnimator.BindCharacter(character: Model): ()
	tracks = {}
	currentHumanoid = nil

	-- Shared/AnimatorUtil.lua -- the same find-Humanoid/find-or-create-Animator plumbing this
	-- file's own sibling Client/FX/CombatAnimator.lua and ServerScriptService/Server/Combat/
	-- BotAnimator.lua need too; see that module's own header for why it's safe to share across the
	-- client/server boundary (pure Instance manipulation, no authoritative state).
	local animator = AnimatorUtil.GetOrCreateAnimator(character)
	if not animator then
		logger:warn("BindCharacter: no Humanoid/Animator available", { character = character.Name })
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	currentHumanoid = humanoid

	for name, animation in pairs(animationTemplates) do
		local ok, trackOrError = pcall(function()
			return animator:LoadAnimation(animation)
		end)
		if ok then
			local track = trackOrError :: AnimationTrack
			-- Core, matching CombatAnimator.lua's own reasoning: current default character rigs play
			-- their own cycle at Core priority, which otherwise wins over anything lower.
			track.Priority = Enum.AnimationPriority.Core
			if name == "Hover" or name == "CruiseLoop" or name == "BoostLoop" then
				track.Looped = true
			end
			tracks[name] = track
			logger:debug("Animation loaded", { name = name, length = track.Length })
		else
			logger:warn("Failed to load animation", { name = name, errorMessage = tostring(trackOrError) })
		end
	end
end

local function playOneShot(name: string): ()
	local track = tracks[name]
	if not track then
		logger:debug("Play: no track loaded yet (no asset id supplied)", { name = name })
		return
	end
	track:Play(ONE_SHOT_FADE_TIME, DOMINANT_WEIGHT)
end

function FlightAnimator.PlayTakeoff(): ()
	playOneShot("Takeoff")
end

function FlightAnimator.PlayLandingSoft(): ()
	playOneShot("LandingSoft")
end

function FlightAnimator.PlayLandingHard(): ()
	playOneShot("LandingHard")
end

-- Called every Heartbeat by FlightController.lua's stepFlight -- just records state for the
-- persistent loop evaluator below to read, same "push state, evaluator re-derives every frame"
-- division of labor as CombatAnimator.lua's StartRunning/StopRunning vs. its own evaluator.
function FlightAnimator.SetFlightMotion(speed: number, isBoosting: boolean): ()
	currentSpeed = speed
	currentlyBoosting = isBoosting
end

-- Own generation counter for THIS file's own flight-track freezes (Client/FX/AnimationTrackUtil.
-- lua's FreezeGuard) -- deliberately a separate instance from CombatAnimator.lua's own guard, so an
-- unrelated combat hit-stop can never supersede (or be superseded by) a flight landing-impact
-- freeze's restore timing. See FreezeGuard's own header for why sharing one counter across
-- unrelated track families would be wrong.
local flightFreezeGuard = AnimationTrackUtil.NewFreezeGuard()

-- Freezes whichever flight tracks are currently playing (landing-impact hit-stop) -- the
-- flight-domain counterpart to CombatAnimator.FreezeActiveCombatTrack, kept as a separate
-- FreezeGuard instance per this module's own header so a combat hit-stop never touches a flight
-- animation or vice versa. Freezes EVERY currently-playing track (not just the first one found --
-- an earlier version of this function `break`-ed after the first hit and restored unconditionally
-- with no generation guard, meaning an overlapping freeze here really could resume early or leave a
-- second frozen track stuck; FreezeGuard fixes both).
function FlightAnimator.FreezeActiveFlightTrack(seconds: number): ()
	local allTracks: { AnimationTrack } = {}
	for _, track in tracks do
		table.insert(allTracks, track)
	end
	flightFreezeGuard:FreezeTracks(allTracks, seconds)
end

-- The single, continuously-correct answer to "which flight loop should be playing THIS frame" --
-- same persistent-evaluator shape as CombatAnimator.lua's Walking/Running loop (re-derives from live
-- state every tick rather than being told on start/stop). Hover/CruiseLoop/BoostLoop are mutually
-- exclusive; all three go silent the instant Flying flips false (checked directly here rather than
-- needing FlightController to call an explicit Stop -- same self-contained-watch idiom
-- Client/Camera/ShiftLockCamera.lua uses for RootControlLocked).
RunService.Heartbeat:Connect(function()
	local hoverTrack = tracks.Hover
	local cruiseTrack = tracks.CruiseLoop
	local boostTrack = tracks.BoostLoop
	if not hoverTrack and not cruiseTrack and not boostTrack then
		return
	end

	local flying = currentHumanoid ~= nil and currentHumanoid:GetAttribute(Constants.Attributes.Flying) == true
	local shouldHover = flying and currentSpeed < Constants.Flight.HoverSpeedThreshold
	local shouldCruise = flying and not shouldHover and not currentlyBoosting
	local shouldBoost = flying and not shouldHover and currentlyBoosting

	-- Client/FX/AnimationTrackUtil.lua's shared evaluator -- the exact same per-Heartbeat
	-- Play/AdjustWeight/Stop mechanic CombatAnimator.lua's own Walking/Running crossfade uses; see
	-- that module's own header. All three loops here share one fade time both ways (no
	-- toggle-vs-interrupt distinction the way Combat's Walking<->Running has), so PlayFadeSeconds
	-- and StopFadeSeconds are both just LOOP_FADE_TIME.
	AnimationTrackUtil.DriveDominantLoop({
		{
			Track = hoverTrack,
			ShouldPlay = shouldHover,
			PlayFadeSeconds = LOOP_FADE_TIME,
			StopFadeSeconds = LOOP_FADE_TIME,
		},
		{
			Track = cruiseTrack,
			ShouldPlay = shouldCruise,
			PlayFadeSeconds = LOOP_FADE_TIME,
			StopFadeSeconds = LOOP_FADE_TIME,
		},
		{
			Track = boostTrack,
			ShouldPlay = shouldBoost,
			PlayFadeSeconds = LOOP_FADE_TIME,
			StopFadeSeconds = LOOP_FADE_TIME,
		},
	}, DOMINANT_WEIGHT)
end)

return FlightAnimator
