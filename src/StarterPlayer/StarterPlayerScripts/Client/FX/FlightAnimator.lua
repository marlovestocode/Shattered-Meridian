--!strict
--[[
	FlightAnimator.lua

	Owns: the LOCAL player's own flight animations (a Hover idle loop, a CruiseLoop for forward flight, a
	BoostLoop while boosting, and one-shot Takeoff/LandingSoft/LandingHard clips) while their Humanoid's "Flying"
	Attribute is true -- as claims on Client/FX/LocalAnimator.lua's AnimationManager. The loops are one exclusive
	layer (FlightLoop: only one plays), the one-shots another (FlightOneShot: they play over the loop), so the
	crossfade between loops is the manager's resolution rather than a hand-written evaluator.

	It stays apart from CombatAnimator's tracks on purpose: flight is triggered by a Humanoid Attribute from an
	unrelated caller (Client/Flight/FlightController.lua), and the combat hit-stop must not incidentally freeze a
	flight clip or the reverse. Combat's hit-stop freezes by animation priority (Action*), and these claims are
	Core; the landing-impact freeze below names its own layers.

	All six Constants.Flight.AnimationIds entries ship as placeholders (the same wired-but-unauthored convention
	CombatConstants.AnimationIds established); an empty id registers as absent, so every play path degrades to a
	silent no-op until a real rbxassetid is supplied, no code change needed once one is.

	Does not own: deciding WHEN flight starts/stops or which loop state is active (FlightController.lua's stepFlight
	computes speed/isBoosting every frame and pushes it in via SetFlightMotion), or the takeoff/landing
	CLASSIFICATION (soft vs hard, grounded vs airborne -- FlightController.lua's own detection logic decides that and
	just calls PlayTakeoff/PlayLandingSoft/PlayLandingHard here).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)
local FXConstants = require(ReplicatedStorage.Shared.FXConstants)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local FlightConstants = require(ReplicatedStorage.Shared.Flight.FlightConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local AnimationManager = require(ReplicatedStorage.Shared.Animation.AnimationManager)
local LocalAnimator = require(script.Parent.LocalAnimator)

local logger = Logger.scope("FlightAnimator")

local FlightAnimator = {}

-- Roblox's default Animate script keeps re-asserting its own track's weight on every Humanoid movement-state
-- change, so a weight above 1 is asked for and the manager holds it every frame (a Weight above 1 implies
-- HoldWeight). Shared with CombatAnimator and EmoteAnimator -- see FXConstants.Animation's own header.
local DOMINANT_WEIGHT = FXConstants.Animation.DominantWeight
local ONE_SHOT_FADE_TIME = FXConstants.Animation.Flight.OneShotFadeSeconds
local LOOP_FADE_TIME = FXConstants.Animation.Flight.LoopFadeSeconds

local LOOP_LAYER = LocalAnimator.Layers.FlightLoop
local ONE_SHOT_LAYER = LocalAnimator.Layers.FlightOneShot
local SOURCE = "Flight"
-- Prefixed so a flight clip name can never collide with another claimant's clip key on the shared manager.
local CLIP_PREFIX = "Flight/"

local ANIMATION_IDS = FlightConstants.AnimationIds

for name, id in pairs(ANIMATION_IDS) do
	LocalAnimator.Manager():Register(CLIP_PREFIX .. name, id)
end

-- Core, matching CombatAnimator's own reasoning: current default character rigs play their own cycle at Core
-- priority, which otherwise wins over anything lower.
local function loopSpec(name: string): AnimationManager.ClipSpec
	return {
		Clip = CLIP_PREFIX .. name,
		Looped = true,
		FadeIn = LOOP_FADE_TIME,
		FadeOut = LOOP_FADE_TIME,
		Weight = DOMINANT_WEIGHT,
		Priority = Enum.AnimationPriority.Core,
	}
end

local function oneShotSpec(name: string): AnimationManager.ClipSpec
	return {
		Clip = CLIP_PREFIX .. name,
		Looped = false,
		FadeIn = ONE_SHOT_FADE_TIME,
		Weight = DOMINANT_WEIGHT,
		Priority = Enum.AnimationPriority.Core,
	}
end

-- Built once: the loop evaluator below runs every Heartbeat and must not allocate a spec per frame.
local HOVER_SPEC = loopSpec("Hover")
local CRUISE_SPEC = loopSpec("CruiseLoop")
local BOOST_SPEC = loopSpec("BoostLoop")
local TAKEOFF_SPEC = oneShotSpec("Takeoff")
local LANDING_SOFT_SPEC = oneShotSpec("LandingSoft")
local LANDING_HARD_SPEC = oneShotSpec("LandingHard")

-- Client/Loading/AssetPreloader.lua's boot-time preload pass: raw content ids, the same contract
-- DefenseClient.GetPreloadInstances has (AnimationManager pools its own templates and does not hand them out).
function FlightAnimator.GetPreloadIds(): { string }
	local ids: { string } = {}
	local seen: { [string]: true } = {}
	for _, id in pairs(ANIMATION_IDS) do
		if id ~= "" and not seen[id] then
			seen[id] = true
			table.insert(ids, id)
		end
	end
	return ids
end

local currentHumanoid: Humanoid? = nil

-- Pushed every frame by FlightController.lua's stepFlight -- read only by the loop evaluator below.
local currentSpeed = 0
local currentlyBoosting = false

function FlightAnimator.BindCharacter(character: Model): ()
	currentHumanoid = nil

	if not LocalAnimator.Bind(character) then
		logger:warn("BindCharacter: no Humanoid/Animator available", { character = character.Name })
		return
	end
	currentHumanoid = CharacterUtil.HumanoidOf(character)
end

local function playOneShot(spec: AnimationManager.ClipSpec): ()
	LocalAnimator.Manager():Claim(ONE_SHOT_LAYER, SOURCE, spec)
end

function FlightAnimator.PlayTakeoff(): ()
	playOneShot(TAKEOFF_SPEC)
end

function FlightAnimator.PlayLandingSoft(): ()
	playOneShot(LANDING_SOFT_SPEC)
end

function FlightAnimator.PlayLandingHard(): ()
	playOneShot(LANDING_HARD_SPEC)
end

-- Called every Heartbeat by FlightController.lua's stepFlight -- just records state for the
-- persistent loop evaluator below to read.
function FlightAnimator.SetFlightMotion(speed: number, isBoosting: boolean): ()
	currentSpeed = speed
	currentlyBoosting = isBoosting
end

-- Freezes whichever flight clips are currently playing (landing-impact hit-stop). Named layers rather than a
-- priority set, so a combat hit-stop never touches a flight animation and this never touches a swing. The
-- manager holds the freeze generation-guarded, so overlapping freezes extend the hold rather than restoring
-- each other early.
function FlightAnimator.FreezeActiveFlightTrack(seconds: number): ()
	LocalAnimator.Manager():Freeze(seconds, { LOOP_LAYER, ONE_SHOT_LAYER })
end

-- The single, continuously-correct answer to "which flight loop should be playing THIS frame": re-derived from
-- live state every tick rather than being told on start/stop. Hover/CruiseLoop/BoostLoop are mutually exclusive;
-- all three go silent the instant Flying flips false (checked directly here rather than needing FlightController
-- to call an explicit Stop -- same self-contained-watch idiom Client/Camera/CombatCamera.lua uses for
-- RootControlLocked).
--
-- A claim is sticky, so this only pushes one when the wanted clip differs from the one playing. Compared against
-- the manager's active clip rather than a cached "last pushed" value, so a claim lost to a death-and-revive is
-- simply pushed again.
RunService.Heartbeat:Connect(function()
	local manager = LocalAnimator.Manager()
	local flying = currentHumanoid ~= nil and currentHumanoid:GetAttribute(AttributeConstants.Flying) == true

	local wanted: AnimationManager.ClipSpec? = nil
	if flying then
		if currentSpeed < FlightConstants.HoverSpeedThreshold then
			wanted = HOVER_SPEC
		elseif currentlyBoosting then
			wanted = BOOST_SPEC
		else
			wanted = CRUISE_SPEC
		end
	end

	local active = manager:GetActiveClip(LOOP_LAYER)
	if wanted == nil then
		if active ~= nil then
			manager:Clear(LOOP_LAYER, SOURCE)
		end
	elseif active ~= wanted.Clip then
		manager:Claim(LOOP_LAYER, SOURCE, wanted)
	end
end)

return FlightAnimator
