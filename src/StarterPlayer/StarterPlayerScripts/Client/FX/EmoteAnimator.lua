--!strict
--[[
	EmoteAnimator.lua

	Owns: loading and playing the LOCAL player's own Emote animations on their current character's
	Animator. Mirrors Client/FX/CombatAnimator.lua's structure closely -- same AnimatorUtil.
	GetOrCreateAnimator usage, same "skip building a template for an empty AnimationId" preload
	pattern, same BindCharacter-reloads-on-respawn contract -- because it solves the identical
	problem: Roblox replicates a played AnimationTrack to every OTHER client automatically once it's
	loaded and played through the OWNING player's own Animator, so triggering these from this client
	(Client/Emotes/EmoteController.lua, reacting to the server-confirmed Emote_Started echo) is
	enough for every other player to see the emote too -- no server involvement needed for the
	animation itself, only for deciding whether playing it was legal, which Server/Systems/
	EmoteSystem.lua already owns and this module never touches.

	Entries in Shared/Emotes/EmoteDefinitions.lua without a clip yet author AnimationId = "" (this
	codebase never fabricates a plausible-looking asset id -- see Constants.Combat.AnimationIds' own
	header for the precedent) -- every play/preload path below already degrades safely to a no-op for
	an empty id, the same way CombatAnimator's own Heavy1/Heavy2 slots do until a real clip is
	supplied. Note that `AnimationId ~= ""` is a load-bearing test on BOTH sides of the wire, not just
	a local optimisation here: Server/Systems/EmoteSystem.lua derives the same hasClip() predicate from
	the same content to decide whether an emote's length is owned by this client's track or by its
	authored Duration, which is why a prefix-only "rbxassetid://" placeholder is a bug in that data
	rather than a harmless stand-in.

	WHY THIS MODULE REPORTS BACK. AnimationTrack.Length is client-only, so this is the one place that
	can know when an emote's animation is genuinely over. SetFinishedCallback below routes that moment
	to EmoteController -> Emote_NotifyFinished, which is what ends a clip-bearing one-shot emote
	server-side. Before that existed, the server ended every emote at the hand-authored Duration
	instead, so an emote whose real clip ran longer than that number was visibly guillotined
	mid-motion -- see EmoteSystem.lua's WHAT ENDS A ONE-SHOT EMOTE header.

	DOMINANT_WEIGHT / per-Heartbeat reassert: reuses the exact mechanism (and the exact shared
	Constants.FX.Animation.DominantWeight value) CombatAnimator.lua's own header documents at length
	-- Roblox's default character rig keeps re-asserting its own walk/run cycle's track weight at the
	same Core priority this module also uses, which can otherwise win the tie for a REMOTE viewer even
	when the LOCAL (emoting) player's own screen already shows the emote correctly. A single
	Play()-time weight isn't reliable for a track that needs to hold dominance for its own duration --
	see CombatAnimator's identical reasoning, restated here rather than re-derived because emotes are
	exactly the "does a remote viewer actually see this" feature this fix matters most for.

	Does not own: deciding WHEN to play an emote or whether it's legal -- Client/Emotes/
	EmoteController.lua is the only caller, translating a server-confirmed Emote_Started/Emote_Stopped
	into a call here.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Constants = require(ReplicatedStorage.Shared.Constants)
local EmoteConstants = require(ReplicatedStorage.Shared.EmoteConstants)
local EmoteRegistry = require(ReplicatedStorage.Shared.Emotes.EmoteRegistry)
local Logger = require(ReplicatedStorage.Shared.Logger)
local AnimatorUtil = require(ReplicatedStorage.Shared.AnimatorUtil)
local Trove = require(ReplicatedStorage.Shared.Trove)

local logger = Logger.scope("EmoteAnimator")

local EmoteAnimator = {}

-- Shared with CombatAnimator.lua/BotAnimator.lua/FlightAnimator.lua -- see Constants.FX.Animation's
-- own header for why every combat/flight/emote track in this codebase asserts the same dominant
-- weight rather than each picking its own number.
local DOMINANT_WEIGHT = Constants.FX.Animation.DominantWeight
local ONE_SHOT_FADE_TIME = EmoteConstants.AnimationFade.OneShotFadeSeconds
local LOOP_FADE_TIME = EmoteConstants.AnimationFade.LoopFadeSeconds
local STOP_FADE_TIME = EmoteConstants.AnimationFade.StopFadeSeconds

-- How far an authored Duration may sit from the real clip length before Play() warns. A file-local
-- rather than an EmoteConstants entry on purpose: it is a diagnostic threshold for a log line, not a
-- number anyone retunes for feel, and nothing outside this file reads it. Loose enough that ordinary
-- rounding in an authored number stays quiet, tight enough that a stale placeholder (a 2-second
-- Duration against a 5-second clip) is called out by name.
local DURATION_DRIFT_TOLERANCE = 0.25

-- Built once at module load, keyed by EmoteId -- skips any entry whose AnimationId is still "" (see
-- this file's header), the same guard CombatAnimator's own animationTemplates loop applies.
local animationTemplates: { [string]: Animation } = {}
for id, definition in pairs(EmoteRegistry.GetAll()) do
	if definition.AnimationId ~= "" then
		local animation = Instance.new("Animation")
		animation.Name = id
		animation.AnimationId = definition.AnimationId
		animationTemplates[id] = animation
	end
end

-- Client/Loading/AssetPreloader.lua's boot-time preload pass reuses these SAME template instances --
-- see CombatAnimator.GetPreloadInstances' identical header for why a second construction path here
-- would just duplicate this module's one source of truth.
function EmoteAnimator.GetPreloadInstances(): { Instance }
	local instances: { Instance } = {}
	for _, animation in pairs(animationTemplates) do
		table.insert(instances, animation)
	end
	return instances
end

local tracks: { [string]: AnimationTrack } = {}
local currentTrack: AnimationTrack? = nil
-- Two independent one-connection scopes rather than two nil-able fields. Both are pure handles --
-- neither is ever read as "is something playing" (currentTrack is that) -- so there is nothing here
-- that wants to stay a field, and Shared/Trove.lua's Clean is idempotent, which is what the two
-- stop* helpers below were hand-writing as an if-Disconnect-nil each.
local weightTrove = Trove.New()
local stoppedTrove = Trove.New()

-- Set once by Client/Emotes/EmoteController.lua's Start(). Invoked with the EmoteId whenever a
-- one-shot track reaches its own NATURAL end (never when Stop() cut it short) -- see SetFinished's
-- own header for why this module, and only this module, can detect that.
local finishedCallback: ((emoteId: string) -> ())? = nil

-- Registers the "this emote's animation actually finished" hook. This module is the only place in
-- the codebase that can raise that signal at the right moment: AnimationTrack.Length exists on the
-- client only (the server never loads the clip at all), so the authored Duration in EmoteDefinitions
-- .lua is the server's ONLY other estimate of when an emote ends -- and a hand-authored number is
-- guaranteed to drift from whatever clip an artist actually uploads. Routing the real end back
-- through EmoteController -> Emote_NotifyFinished is what lets Server/Systems/EmoteSystem.lua stop a
-- clip-bearing emote when the animation is genuinely over instead of at a stale guess.
function EmoteAnimator.SetFinishedCallback(callback: (emoteId: string) -> ()): ()
	finishedCallback = callback
end

local function stopWeightReassert(): ()
	weightTrove:Clean()
end

-- Disconnects the Stopped watch a Play() call sets up (see Play's own header) -- split out from
-- Stop() only to give BindCharacter's own rebind teardown and Stop() a single shared implementation,
-- the same split stopWeightReassert already has for the sibling connection.
local function stopStoppedWatch(): ()
	stoppedTrove:Clean()
end

-- Rebuilds every AnimationTrack against `character`'s own Animator -- a Track is tied to the
-- specific Animator instance it was loaded from, so a respawned character needs a brand new set;
-- see CombatAnimator.BindCharacter's identical contract.
function EmoteAnimator.BindCharacter(character: Model): ()
	stopWeightReassert()
	stopStoppedWatch()
	tracks = {}
	currentTrack = nil

	local animator = AnimatorUtil.GetOrCreateAnimator(character)
	if not animator then
		logger:warn("BindCharacter: no Humanoid/Animator available", { character = character.Name })
		return
	end

	for id, animation in pairs(animationTemplates) do
		local ok, trackOrError = pcall(function()
			return animator:LoadAnimation(animation)
		end)
		if ok then
			local track = trackOrError :: AnimationTrack
			-- Core, matching CombatAnimator's own tracks -- current default character rigs play
			-- their own walk/run cycle at Core priority, which otherwise wins over anything lower.
			track.Priority = Enum.AnimationPriority.Core
			local definition = EmoteRegistry.Get(id)
			track.Looped = definition ~= nil and definition.Loop
			tracks[id] = track
			logger:debug("Animation loaded", { emoteId = id, length = track.Length })
		else
			logger:warn("Failed to load animation", { emoteId = id, errorMessage = tostring(trackOrError) })
		end
	end
end

-- Plays `emoteId`'s track, if one is loaded -- for an entry whose AnimationId is still "" there is no
-- track to load, which stays an expected, non-error path until a real clip is supplied for it.
-- Stops whatever emote was previously playing first -- EmoteSystem's own re-trigger
-- semantics (Server/Systems/EmoteSystem.lua's header) already guarantee at most one emote is ever
-- active per player at a time, so this is defense in depth, not load-bearing.
function EmoteAnimator.Play(emoteId: string): ()
	EmoteAnimator.Stop()

	local track = tracks[emoteId]
	if not track then
		-- Reported as an immediate natural finish, not just logged. For an emote whose AnimationId is
		-- still "" the server never accepts the notification anyway (it falls back to the authored
		-- Duration -- see EmoteSystem.handleNotifyFinished's own clip guard), but for a clip-bearing
		-- emote whose LoadAnimation call failed in BindCharacter this is what keeps the server from
		-- holding the emote (and, for a MovementLocked one, a zeroed WalkSpeed) all the way to
		-- EmoteConstants.MaxOneShotSeconds waiting for an animation that is never going to play.
		logger:debug("Play: no track loaded (no animation authored yet, or never bound)", { emoteId = emoteId })
		if finishedCallback then
			finishedCallback(emoteId)
		end
		return
	end

	local definition = EmoteRegistry.Get(emoteId)
	local isLoop = definition ~= nil and definition.Loop
	local fadeTime = if isLoop then LOOP_FADE_TIME else ONE_SHOT_FADE_TIME
	track:Play(fadeTime, DOMINANT_WEIGHT)
	currentTrack = track

	-- Dev-time only. The authored Duration and the real clip are two independent numbers nothing else
	-- forces to agree, and a disagreement is invisible in play except as an emote that ends at the
	-- wrong moment -- exactly the bug Emote_NotifyFinished now prevents from mattering. Length is 0
	-- until the asset finishes loading, so a cold first play legitimately skips this.
	if not isLoop and definition and definition.Duration and track.Length > 0 then
		local drift = track.Length - definition.Duration
		if math.abs(drift) > DURATION_DRIFT_TOLERANCE then
			logger:warn("Authored Duration disagrees with the real clip length -- retune EmoteDefinitions", {
				emoteId = emoteId,
				authoredDuration = definition.Duration,
				actualClipLength = track.Length,
			})
		end
	end

	-- See this file's header -- a single Play()-time weight isn't reliable for a track that needs to
	-- hold dominance for its own duration against Roblox's own re-asserting default Animate script.
	weightTrove:Connect(RunService.Heartbeat, function()
		if track.IsPlaying then
			track:AdjustWeight(DOMINANT_WEIGHT)
		end
	end)

	-- Reaching here means the track ended on its OWN -- Stop() disconnects this watch BEFORE it calls
	-- track:Stop(), so an induced stop (a superseding emote, the server's Emote_Stopped echo) never
	-- runs this and never reports a finish the server would then act on twice.
	stoppedTrove:Connect(track.Stopped, function()
		if currentTrack ~= track then
			return
		end
		stopWeightReassert()
		currentTrack = nil
		if finishedCallback then
			finishedCallback(emoteId)
		end
	end)
end

-- Stops whatever emote is currently playing (a natural non-loop finish already clears currentTrack
-- via the Stopped connection above, so this is a no-op then) -- called on the server's Emote_Stopped
-- echo, and defensively at the top of Play() above.
--
-- Also tears down the Stopped watch itself, not just the weight-reassert one -- a track's Stopped
-- connection outlives its own single firing (the natural-finish callback above clears currentTrack
-- but never disconnects itself), and every entry in `tracks` is a cached AnimationTrack reused across
-- repeat plays of the same emote rather than rebuilt each time. Without this, every Play() call
-- (which always starts by calling this function -- see Play's own header) added a fresh connection
-- to a scope the previous one was still live in, leaking one connection per emote cycle until the
-- next full BindCharacter rebind.
function EmoteAnimator.Stop(): ()
	stopWeightReassert()
	stopStoppedWatch()
	if currentTrack and currentTrack.IsPlaying then
		currentTrack:Stop(STOP_FADE_TIME)
	end
	currentTrack = nil
end

return EmoteAnimator
