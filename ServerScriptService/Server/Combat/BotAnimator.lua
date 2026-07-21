--!strict
--[[
	BotAnimator.lua

	Owns: loading and playing a training bot's own combat animations, server-side -- the bot
	equivalent of Client/FX/CombatAnimator.lua, necessary because a bot has no owning Player/client
	to run that module for it. Unlike CombatAnimator.lua (a client-side singleton bound to exactly
	one character at a time), this module supports any number of concurrent bots, keyed by their own
	Model, since a single player can have multiple bots active at once (CombatSystem.lua's
	createTrainingBot/despawnBot). Reads the SAME ids CombatAnimator.lua does
	(Constants.Combat.AnimationIds), so a bot and a player always look identical for the same move --
	a training bot should feel like a real opponent (see createTrainingBot's own comment on bot
	vitals reusing Constants.Combat directly), which includes moving like one.

	Roblox replicates a server-played AnimationTrack to every client automatically, exactly like a
	client-played one -- no remote/broadcast needed for a bot's animation to be visible.

	Bots have no dash/sprint AI today (TrainingBotSystem.lua's own header: no
	pathfinding/movement-AI infrastructure exists yet, bots are stationary sparring partners) --
	this module only ever plays Swing/BlockHold/ParryFlash/Hit1-3, never Dash or Running.

	Does not own: deciding WHEN to play one of these, or whether an action is legal --
	CombatSystem.lua's bot-attack/bot-block/bot-hit-resolution call sites are the only callers.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local Logger = require(ReplicatedStorage.Shared.Logger)
local AnimatorUtil = require(ReplicatedStorage.Shared.AnimatorUtil)
local CombatDebugNames = require(ReplicatedStorage.Shared.CombatDebugNames)

local logger = Logger.scope("BotAnimator")

local BotAnimator = {}

-- Same fade times/weight as Client/FX/CombatAnimator.lua -- both now read from the single shared
-- Constants.FX.Animation.Combat/DominantWeight table (see that table's own header in Constants.lua
-- for why these used to be two independently hand-typed copies, and why DOMINANT_WEIGHT is necessary
-- at all: Roblox's default character rig plays its own walk/run cycle at Core priority too, so
-- same-priority tracks blend by Weight rather than either cleanly winning).
local SWING_FADE_TIME = Constants.FX.Animation.Combat.SwingFadeSeconds
local BLOCK_HOLD_FADE_TIME = Constants.FX.Animation.Combat.BlockHoldFadeSeconds
local PARRY_FLASH_FADE_TIME = Constants.FX.Animation.Combat.ParryFlashFadeSeconds
local HIT_REACTION_FADE_TIME = Constants.FX.Animation.Combat.HitReactionFadeSeconds
local DOMINANT_WEIGHT = Constants.FX.Animation.DominantWeight

local ANIMATION_IDS = Constants.Combat.AnimationIds

local animationTemplates: { [string]: Animation } = {}
for name, id in pairs(ANIMATION_IDS) do
	-- Skip empty-id slots, same as Client/FX/CombatAnimator.lua's loader -- Constants.Combat.
	-- AnimationIds lists wired-but-unauthored clips as "", and building a template for one would only
	-- invite a LoadAnimation warning for a clip we already know isn't supplied.
	if id ~= "" then
		local animation = Instance.new("Animation")
		animation.Name = name
		animation.AnimationId = id
		animationTemplates[name] = animation
	end
end

type BotTracks = { [string]: AnimationTrack }
local tracksByBot: { [Model]: BotTracks } = {}

-- Per-bot weight-reassert loop for BlockHold (the one looped/held bot track) -- same reasoning as
-- Client/FX/CombatAnimator.lua's runningWeightConnection: a single Play()-time weight isn't
-- reliable enough for every viewing client to render the same dominant blend over the track's
-- whole held duration. Keyed by Model since multiple bots can be held-blocking at once.
local blockHoldConnections: { [Model]: RBXScriptConnection } = {}

-- Loads every AnimationTrack for this bot's own Animator. Call once, right after the bot Model is
-- created (CombatSystem.lua's createTrainingBot) -- bots don't respawn (TrainingBotSystem.lua's own
-- header), so there's no CharacterAdded-equivalent to reload on later.
function BotAnimator.BindBot(model: Model): ()
	-- Shared/AnimatorUtil.lua -- the same find-Humanoid/find-or-create-Animator plumbing
	-- Client/FX/CombatAnimator.lua and Client/FX/FlightAnimator.lua need too; see that module's own
	-- header for why it's safe to share across the client/server boundary (pure Instance
	-- manipulation, no authoritative state).
	local animator = AnimatorUtil.GetOrCreateAnimator(model)
	if not animator then
		logger:warn("BindBot: no Humanoid/Animator available", { bot = model.Name })
		return
	end

	local tracks: BotTracks = {}
	for name, animation in pairs(animationTemplates) do
		local ok, trackOrError = pcall(function()
			return animator:LoadAnimation(animation)
		end)
		if ok then
			local track = trackOrError :: AnimationTrack
			track.Priority = Enum.AnimationPriority.Core
			if name == "BlockHold" then
				track.Looped = true
			end
			tracks[name] = track
			logger:debug("Animation loaded", { bot = model.Name, name = name, length = track.Length })
		else
			logger:warn(
				"Failed to load animation",
				{ bot = model.Name, name = name, errorMessage = tostring(trackOrError) }
			)
		end
	end
	tracksByBot[model] = tracks
end

-- Releases this bot's tracks -- call from CombatSystem.lua's despawnBot so a despawned bot's entry
-- doesn't leak forever in tracksByBot (or its BlockHold weight-reassert connection, if one was
-- still running).
function BotAnimator.UnbindBot(model: Model): ()
	tracksByBot[model] = nil
	local connection = blockHoldConnections[model]
	if connection then
		connection:Disconnect()
		blockHoldConnections[model] = nil
	end
end

-- Bot equivalent of CombatAnimator.PlaySwing -- called right after CombatSystem.lua accepts a bot's
-- attack (RequestBotAttack). Bots never throw a Finisher (BotState has no basicComboLanded/landing
-- combo tracking -- see CombatTypes.lua), so finisherVariant is always nil in practice; the
-- parameter exists for signature symmetry with the player-facing PlaySwing. Plays at the clip's own
-- authored (native) speed -- same "animation and hitbox timing are independent" decision as
-- Client/FX/CombatAnimator.lua's PlaySwing; see that module's own "Animation/hitbox sync" note.
function BotAnimator.PlaySwing(model: Model, debugName: string, finisherVariant: Types.FinisherVariant?): ()
	local tracks = tracksByBot[model]
	if not tracks then
		return
	end

	local track: AnimationTrack?
	if finisherVariant then
		track = tracks.Uppercut
	else
		local stage = CombatDebugNames.SwingStageFromDebugName(debugName)
		track = if stage then tracks["Swing" .. tostring(stage)] else nil
	end

	if track then
		track:Play(SWING_FADE_TIME, DOMINANT_WEIGHT)
	else
		logger:debug("PlaySwing: no track to play", { bot = model.Name, debugName = debugName })
	end
end

-- Held-Block stance -- called from CombatSystem.RequestBotBlockStart/Stop, the bot AI's own
-- equivalent of a player's Block keypress (TrainingBotSystem.lua's rerollStance/updateParryWatch).
function BotAnimator.PlayBlockHold(model: Model): ()
	local tracks = tracksByBot[model]
	local track = tracks and tracks.BlockHold
	if not track then
		return
	end
	if not track.IsPlaying then
		track:Play(BLOCK_HOLD_FADE_TIME, DOMINANT_WEIGHT)
	end
	if not blockHoldConnections[model] then
		blockHoldConnections[model] = RunService.Heartbeat:Connect(function()
			if track.IsPlaying then
				track:AdjustWeight(DOMINANT_WEIGHT)
			end
		end)
	end
end

function BotAnimator.StopBlockHold(model: Model): ()
	local connection = blockHoldConnections[model]
	if connection then
		connection:Disconnect()
		blockHoldConnections[model] = nil
	end
	local tracks = tracksByBot[model]
	local track = tracks and tracks.BlockHold
	if track and track.IsPlaying then
		track:Stop(BLOCK_HOLD_FADE_TIME)
	end
end

-- One-shot parry-deflect flash -- called from CombatSystem.RequestBotBlockStart only when it
-- actually armed a parry window (parryAvailable), the same "only on a real server-confirmed parry
-- window" gating CombatClient.lua applies for a player's own ParryFlash.
function BotAnimator.PlayParryFlash(model: Model): ()
	local tracks = tracksByBot[model]
	local track = tracks and tracks.ParryFlash
	if track then
		track:Play(PARRY_FLASH_FADE_TIME, DOMINANT_WEIGHT)
	end
end

-- Plays this bot's own hit-reaction for an unmitigated attack that just landed on it -- called from
-- CombatSystem.lua's resolveHitAgainstBot with the attacker's definition.DebugName, the bot-defender
-- counterpart of CombatAnimator.PlayHitReaction. Only fires for an unmitigated hit (never while the
-- bot is blocking -- same reasoning as the player-facing version: a blocking bot is already showing
-- BlockHold and shouldn't flinch out of it).
function BotAnimator.PlayHitReaction(model: Model, debugName: string?): ()
	local tracks = tracksByBot[model]
	if not tracks then
		return
	end
	-- Same Basic-stage-digit mapping as the player-facing CombatAnimator.PlayHitReaction, with the
	-- same "HitGeneric" fallback for a landing with no Basic stage digit (Finisher/DashPunch/Heavy),
	-- so a bot flinches to those too instead of a silent no-op. HitGeneric is an empty-id slot until
	-- supplied (Constants.Combat.AnimationIds), so the fallback is itself a no-op until then.
	local stage = if debugName then CombatDebugNames.SwingStageFromDebugName(debugName) else nil
	local trackName = if stage then "Hit" .. tostring(stage) else "HitGeneric"
	local track = tracks[trackName]
	if track then
		track:Play(HIT_REACTION_FADE_TIME, DOMINANT_WEIGHT)
	end
end

return BotAnimator
