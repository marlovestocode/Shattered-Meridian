--!strict
--[[
	EmoteAnimator.lua

	Owns: playing the LOCAL player's own Emote animations, as claims on the "Emote" layer of Client/FX/
	LocalAnimator.lua's AnimationManager. Roblox replicates a played AnimationTrack to every OTHER client
	automatically once it is loaded and played through the OWNING player's own Animator, so triggering these from
	this client (Client/Emotes/EmoteController.lua, reacting to the server-confirmed Emote_Started echo) is enough
	for every other player to see the emote too -- no server involvement needed for the animation itself, only for
	deciding whether playing it was legal, which Server/Systems/EmoteSystem.lua already owns and this module
	never touches.

	Entries in Shared/Emotes/EmoteDefinitions.lua without a clip yet author AnimationId = "" (this codebase never
	fabricates a plausible-looking asset id -- see CombatConstants.AnimationIds' own header for the precedent).
	AnimationManager registers an empty id as absent, so every play path degrades to a no-op for one. Note that
	`AnimationId ~= ""` is a load-bearing test on BOTH sides of the wire, not just a local optimisation here:
	Server/Systems/EmoteSystem.lua derives the same hasClip() predicate from the same content to decide whether an
	emote's length is owned by this client's track or by its authored Duration, which is why a prefix-only
	"rbxassetid://" placeholder is a bug in that data rather than a harmless stand-in.

	WHY THIS MODULE REPORTS BACK. AnimationTrack.Length is client-only, so this is the one place that can know
	when an emote's animation is genuinely over. SetFinishedCallback below routes that moment to EmoteController ->
	Emote_NotifyFinished, which is what ends a clip-bearing one-shot emote server-side. Before that existed, the
	server ended every emote at the hand-authored Duration instead, so an emote whose real clip ran longer than
	that number was visibly guillotined mid-motion -- see EmoteSystem.lua's WHAT ENDS A ONE-SHOT EMOTE header.

	WHAT COUNTS AS A FINISH. The claim's OnFinished reports why it ended. Completed (the clip ran out) and Expired
	(the watchdog finalised a one-shot that outlived its Length) are the clip ending on its own; Failed (the clip
	could not be loaded or played) is reported the same way so the server never holds an emote -- and, for a
	MovementLocked one, a zeroed WalkSpeed -- all the way to EmoteConstants.MaxOneShotSeconds waiting for an
	animation that is never going to play. Superseded, Cleared and Stopped (a new emote, the server's Emote_Stopped
	echo, death) are induced and are NOT reported, so the server never acts on a finish twice. A claim the manager
	refuses outright (a dead rig, no clip authored) never starts, and is reported as an immediate finish.

	The dominant weight and its per-frame re-assert against Roblox's default Animate script are AnimationManager's
	(a Weight above 1 implies HoldWeight); this module only asks for FXConstants.Animation.DominantWeight, shared
	with CombatAnimator and FlightAnimator.

	Does not own: deciding WHEN to play an emote or whether it's legal -- Client/Emotes/EmoteController.lua is the
	only caller, translating a server-confirmed Emote_Started/Emote_Stopped into a call here.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local FXConstants = require(ReplicatedStorage.Shared.FXConstants)
local EmoteConstants = require(ReplicatedStorage.Shared.EmoteConstants)
local EmoteRegistry = require(ReplicatedStorage.Shared.Emotes.EmoteRegistry)
local Logger = require(ReplicatedStorage.Shared.Logger)
local LocalAnimator = require(script.Parent.LocalAnimator)

local logger = Logger.scope("EmoteAnimator")

local EmoteAnimator = {}

local DOMINANT_WEIGHT = FXConstants.Animation.DominantWeight
local ONE_SHOT_FADE_TIME = EmoteConstants.AnimationFade.OneShotFadeSeconds
local LOOP_FADE_TIME = EmoteConstants.AnimationFade.LoopFadeSeconds
local STOP_FADE_TIME = EmoteConstants.AnimationFade.StopFadeSeconds

-- How far an authored Duration may sit from the real clip length before Play() warns. A file-local
-- rather than an EmoteConstants entry on purpose: it is a diagnostic threshold for a log line, not a
-- number anyone retunes for feel, and nothing outside this file reads it. Loose enough that ordinary
-- rounding in an authored number stays quiet, tight enough that a stale placeholder (a 2-second
-- Duration against a 5-second clip) is called out by name.
local DURATION_DRIFT_TOLERANCE = 0.25

local LAYER = LocalAnimator.Layers.Emote
local SOURCE = "Emote"
-- Prefixed so an emote id can never collide with another claimant's clip key on the shared manager.
local CLIP_PREFIX = "Emote/"

-- Registered once at module load, keyed by EmoteId; an entry whose AnimationId is still "" registers as absent.
for id, definition in pairs(EmoteRegistry.GetAll()) do
	LocalAnimator.Manager():Register(CLIP_PREFIX .. id, definition.AnimationId)
end

-- Client/Loading/AssetPreloader.lua's boot-time preload pass. Raw content ids, the same contract
-- DefenseClient.GetPreloadInstances has: AnimationManager pools its own templates and does not hand them out.
function EmoteAnimator.GetPreloadIds(): { string }
	local ids: { string } = {}
	local seen: { [string]: true } = {}
	for _, definition in pairs(EmoteRegistry.GetAll()) do
		if definition.AnimationId ~= "" and not seen[definition.AnimationId] then
			seen[definition.AnimationId] = true
			table.insert(ids, definition.AnimationId)
		end
	end
	return ids
end

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

-- A new life of the character. Tracks are loaded lazily by the manager on the first claim, and every claim from
-- the previous life went with its Unbind, so there is nothing to reset here beyond making sure it is bound.
function EmoteAnimator.BindCharacter(character: Model): ()
	if not LocalAnimator.Bind(character) then
		logger:warn("BindCharacter: no Humanoid/Animator available", { character = character.Name })
	end
end

-- Plays `emoteId`, if a clip is authored for it -- for an entry whose AnimationId is still "" there is nothing to
-- play, which stays an expected, non-error path until a real clip is supplied for it. Stops whatever emote was
-- previously playing first -- EmoteSystem's own re-trigger semantics (Server/Systems/EmoteSystem.lua's header)
-- already guarantee at most one emote is ever active per player at a time, so this is defense in depth, not
-- load-bearing.
function EmoteAnimator.Play(emoteId: string): ()
	EmoteAnimator.Stop()

	local manager = LocalAnimator.Manager()
	local definition = EmoteRegistry.Get(emoteId)
	local isLoop = definition ~= nil and definition.Loop
	local clip = CLIP_PREFIX .. emoteId

	-- Reported at most once per play: a refused claim and a Failed finish can both be true of the same one.
	local reported = false
	local function reportFinished(): ()
		if reported then
			return
		end
		reported = true
		if finishedCallback then
			finishedCallback(emoteId)
		end
	end

	manager:Claim(LAYER, SOURCE, {
		Clip = clip,
		Looped = isLoop,
		FadeIn = if isLoop then LOOP_FADE_TIME else ONE_SHOT_FADE_TIME,
		FadeOut = STOP_FADE_TIME,
		Weight = DOMINANT_WEIGHT,
		-- Core, matching CombatAnimator's own tracks -- current default character rigs play their own walk/run
		-- cycle at Core priority, which otherwise wins over anything lower.
		Priority = Enum.AnimationPriority.Core,
		OnFinished = function(_, reason)
			if reason == "Completed" or reason == "Expired" or reason == "Failed" then
				reportFinished()
			end
		end,
	})

	if manager:GetActiveClip(LAYER) ~= clip then
		-- Reported as an immediate natural finish, not just logged. For an emote whose AnimationId is still ""
		-- the server never accepts the notification anyway (it falls back to the authored Duration -- see
		-- EmoteSystem.handleNotifyFinished's own clip guard), but for a clip-bearing emote the manager refused
		-- or could not load, this is what keeps the server from holding it.
		logger:debug("Play: no clip playing (none authored yet, or never bound)", { emoteId = emoteId })
		reportFinished()
		return
	end

	-- Dev-time only. The authored Duration and the real clip are two independent numbers nothing else
	-- forces to agree, and a disagreement is invisible in play except as an emote that ends at the
	-- wrong moment -- exactly the bug Emote_NotifyFinished now prevents from mattering. Length is 0
	-- until the asset finishes loading, so a cold first play legitimately skips this.
	if not isLoop and definition and definition.Duration then
		local _, length = manager:GetPlayback(LAYER)
		if length > 0 then
			local drift = length - definition.Duration
			if math.abs(drift) > DURATION_DRIFT_TOLERANCE then
				logger:warn("Authored Duration disagrees with the real clip length -- retune EmoteDefinitions", {
					emoteId = emoteId,
					authoredDuration = definition.Duration,
					actualClipLength = length,
				})
			end
		end
	end
end

-- Stops whatever emote is currently playing -- called on the server's Emote_Stopped echo, and defensively at the
-- top of Play() above. The withdrawn claim reports Cleared, which is not a finish, so an induced stop is never
-- sent back to the server.
function EmoteAnimator.Stop(): ()
	LocalAnimator.Manager():Clear(LAYER, SOURCE)
end

return EmoteAnimator
