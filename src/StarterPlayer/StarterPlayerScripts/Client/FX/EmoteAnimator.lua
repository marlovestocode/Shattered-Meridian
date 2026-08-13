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

	Every entry in Shared/Emotes/EmoteDefinitions.lua currently authors AnimationId = "" (this
	codebase never fabricates a plausible-looking asset id -- see Constants.Combat.AnimationIds' own
	header for the precedent) -- every play/preload path below already degrades safely to a no-op for
	an empty id, the same way CombatAnimator's own Heavy1/Heavy2 slots do until a real clip is
	supplied.

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

local logger = Logger.scope("EmoteAnimator")

local EmoteAnimator = {}

-- Shared with CombatAnimator.lua/BotAnimator.lua/FlightAnimator.lua -- see Constants.FX.Animation's
-- own header for why every combat/flight/emote track in this codebase asserts the same dominant
-- weight rather than each picking its own number.
local DOMINANT_WEIGHT = Constants.FX.Animation.DominantWeight
local ONE_SHOT_FADE_TIME = EmoteConstants.AnimationFade.OneShotFadeSeconds
local LOOP_FADE_TIME = EmoteConstants.AnimationFade.LoopFadeSeconds
local STOP_FADE_TIME = EmoteConstants.AnimationFade.StopFadeSeconds

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
local weightConnection: RBXScriptConnection? = nil
local stoppedConnection: RBXScriptConnection? = nil

local function stopWeightReassert(): ()
	if weightConnection then
		weightConnection:Disconnect()
		weightConnection = nil
	end
end

-- Disconnects the Stopped watch a Play() call sets up (see Play's own header) -- split out from
-- Stop() only to give BindCharacter's own rebind teardown and Stop() a single shared implementation,
-- the same split stopWeightReassert already has for the sibling connection.
local function stopStoppedWatch(): ()
	if stoppedConnection then
		stoppedConnection:Disconnect()
		stoppedConnection = nil
	end
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

-- Plays `emoteId`'s track, if one is loaded -- a silent no-op otherwise (every entry in
-- EmoteDefinitions.lua currently has AnimationId = "", so this is the expected path until real clips
-- are supplied). Stops whatever emote was previously playing first -- EmoteSystem's own re-trigger
-- semantics (Server/Systems/EmoteSystem.lua's header) already guarantee at most one emote is ever
-- active per player at a time, so this is defense in depth, not load-bearing.
function EmoteAnimator.Play(emoteId: string): ()
	EmoteAnimator.Stop()

	local track = tracks[emoteId]
	if not track then
		logger:debug("Play: no track loaded (no animation authored yet, or never bound)", { emoteId = emoteId })
		return
	end

	local definition = EmoteRegistry.Get(emoteId)
	local fadeTime = if definition and definition.Loop then LOOP_FADE_TIME else ONE_SHOT_FADE_TIME
	track:Play(fadeTime, DOMINANT_WEIGHT)
	currentTrack = track

	-- See this file's header -- a single Play()-time weight isn't reliable for a track that needs to
	-- hold dominance for its own duration against Roblox's own re-asserting default Animate script.
	weightConnection = RunService.Heartbeat:Connect(function()
		if track.IsPlaying then
			track:AdjustWeight(DOMINANT_WEIGHT)
		end
	end)

	stoppedConnection = track.Stopped:Connect(function()
		if currentTrack == track then
			stopWeightReassert()
			currentTrack = nil
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
-- (which always starts by calling this function -- see Play's own header) overwrote the
-- `stoppedConnection` local with a fresh connection while the PREVIOUS one stayed live and
-- unreachable, leaking one connection per emote cycle until the next full BindCharacter rebind.
function EmoteAnimator.Stop(): ()
	stopWeightReassert()
	stopStoppedWatch()
	if currentTrack and currentTrack.IsPlaying then
		currentTrack:Stop(STOP_FADE_TIME)
	end
	currentTrack = nil
end

return EmoteAnimator
