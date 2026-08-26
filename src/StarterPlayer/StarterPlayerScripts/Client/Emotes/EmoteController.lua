--!strict
--[[
	EmoteController.lua

	Owns: the client-side request/response plumbing for the Emote System -- the SOLE thing the radial
	wheel UI is allowed to call. RequestPlay/RequestStop/RequestSetLoadoutSlot fire the corresponding
	client->server remotes; this module listens for the server's own Emote_Started/Emote_Stopped
	echoes, drives Client/FX/EmoteAnimator.lua from them, and publishes the one bit those echoes carry
	that an input module needs (IsPlaying -- see activeEmoteId below).

	Phase 1 of 2 -- this file has to work correctly with ZERO UI attached (per this pass's own
	binding requirement): Start() alone is enough for a bare RequestPlay call to actually play and
	replicate an emote, exactly like CombatClient.lua's own combat requests need no HUD to function.

	Mirrors Client/Combat/CombatClient.lua's own CharacterAdded/BindCharacter wiring shape: bind
	immediately if a Character already exists at Start() time (a mid-session script reload/relog
	case), then rebind on every subsequent CharacterAdded (a respawn needs a fresh Animator).

	FINISH REPORTING. One thing does flow client -> server without being a player input:
	Emote_NotifyFinished, fired from the EmoteAnimator.SetFinishedCallback hook wired in Start()
	below. AnimationTrack.Length exists on the client only, so this client is the only side that can
	tell the server when a one-shot emote's animation is ACTUALLY over rather than when a
	hand-authored EmoteDefinitions.Duration guessed it would be. This is a report, not a command --
	EmoteSystem re-validates it against its own active emote and still enforces its own ceiling, per
	that file's own STOP SCHEDULING header.

	No client-side prediction: unlike combat's Basic/Heavy/Dash (Client/Combat/PredictionMirror.lua),
	an emote press has no gameplay outcome to predict ahead of the round trip, and per-frame input
	lag on a purely cosmetic/social action isn't worth the rollback machinery that buys combat its
	responsiveness -- RequestPlay simply fires and waits for Emote_Started before EmoteAnimator.Play
	ever runs.

	Does not own: validating whether a play/loadout request is legal (Server/Systems/EmoteSystem.lua
	re-validates everything server-side regardless of what this module sends), or loading/playing any
	AnimationTrack itself (Client/FX/EmoteAnimator.lua).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local EmoteConstants = require(ReplicatedStorage.Shared.EmoteConstants)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local EmoteAnimator = require(script.Parent.Parent.FX.EmoteAnimator)

local logger = Logger.scope("EmoteController")

local EmoteController = {}

local requestPlayRemote: RemoteEvent? = nil
local requestSetLoadoutSlotRemote: RemoteEvent? = nil
local notifyFinishedRemote: RemoteEvent? = nil
local requestStopRemote: RemoteEvent? = nil

-- The emote the SERVER last told this client it is playing, or nil -- written only from the
-- Emote_Started/Emote_Stopped echoes below, never optimistically from RequestPlay/RequestStop (this
-- module predicts nothing; see this file's header). Exists so an input module can ask "is there
-- anything to cancel" without either keeping its own shadow copy of that state or reaching into
-- EmoteAnimator, which knows about a TRACK and would answer "no" for a clipless emote that is very
-- much still running and still holding a movement lock.
local activeEmoteId: string? = nil

-- One slot, one owner -- exactly the shape EmoteAnimator.SetFinishedCallback already uses, and set
-- for the same reason: the module that OWNS the fact publishes it, and whoever needs to react
-- registers rather than polling. Client/Emotes/EmoteWheelClient.lua is the only registrant today
-- (it arms and disarms the movement-cancel watch off these edges).
local activeChangedCallback: ((emoteId: string?) -> ())? = nil

-- Assigns activeEmoteId and reports the edge, once, only when it actually changed. Every write to
-- that variable goes through here so a future one cannot forget to report: a missed nil edge leaves
-- an input watch armed for an emote that is over, and a missed non-nil edge leaves a locked pose
-- with no way out, which is the exact bug RequestStop exists to fix.
local function setActiveEmote(emoteId: string?): ()
	if activeEmoteId == emoteId then
		return
	end
	activeEmoteId = emoteId
	if activeChangedCallback then
		activeChangedCallback(emoteId)
	end
end

-- Fires the client->server play request -- the one entry point a future wheel UI calls when the
-- player picks a slot. Does nothing else locally: EmoteAnimator.Play only ever runs off the server's
-- own Emote_Started echo below, never optimistically here.
function EmoteController.RequestPlay(emoteId: string): ()
	if not requestPlayRemote then
		return
	end
	requestPlayRemote:FireServer(emoteId)
end

-- Fires the client->server loadout-slot request -- the one entry point a future wheel UI's
-- edit/assign flow calls. slotIndex is 1-based, matching Types.PlayerProfile.emoteLoadout's own
-- indexing.
function EmoteController.RequestSetLoadoutSlot(slotIndex: number, emoteId: string): ()
	if not requestSetLoadoutSlotRemote then
		return
	end
	requestSetLoadoutSlotRemote:FireServer(slotIndex, emoteId)
end

-- True while an emote is running as far as the SERVER is concerned -- see activeEmoteId above for
-- why that, and not EmoteAnimator's track, is the fact being reported. Safe to call before Start()
-- (always false until the first Emote_Started arrives), matching EmoteWheelClient.IsOpen()'s own
-- contract.
function EmoteController.IsPlaying(): boolean
	return activeEmoteId ~= nil
end

-- Registers the one listener for "the emote the server says I am playing changed" -- called with the
-- new EmoteId, or nil when nothing is running. Fires only on a real change, never once per echo. See
-- activeChangedCallback above.
--
-- Registered AFTER this module's own Start(), unlike EmoteAnimator's finished hook, purely because
-- of who registers it: Client/Emotes/EmoteWheelClient.lua boots one step later than this module does
-- (Main.client.lua's own ordering comment says why). Nothing is missed by that -- the only edges this
-- reports are ones the server sends in answer to a RequestPlay, and nothing can have made one in the
-- microseconds between the two Start() calls at boot.
function EmoteController.SetActiveChangedCallback(callback: ((emoteId: string?) -> ())?): ()
	activeChangedCallback = callback
end

-- Asks the server to end whatever this player is currently emoting. Fires nothing when there is
-- nothing running -- the server would treat it as a no-op anyway (EmoteSystem.handleRequestStop),
-- but a remote call that can never accomplish anything should not spend the shared play budget that
-- gates the NEXT real RequestPlay. Does not clear activeEmoteId itself: like RequestPlay, this is a
-- request, and the Emote_Stopped echo is what makes it true here.
function EmoteController.RequestStop(): ()
	if not requestStopRemote or activeEmoteId == nil then
		return
	end
	requestStopRemote:FireServer()
end

function EmoteController.Start(): ()
	requestPlayRemote = NetworkBridge.GetRemoteEvent(EmoteConstants.RemoteNames.RequestPlay)
	requestSetLoadoutSlotRemote = NetworkBridge.GetRemoteEvent(EmoteConstants.RemoteNames.RequestSetLoadoutSlot)
	notifyFinishedRemote = NetworkBridge.GetRemoteEvent(EmoteConstants.RemoteNames.NotifyFinished)
	requestStopRemote = NetworkBridge.GetRemoteEvent(EmoteConstants.RemoteNames.RequestStop)

	-- The one report of "this emote's animation is genuinely over" -- fires only on a NATURAL track
	-- end (EmoteAnimator.SetFinishedCallback's own header explains why the client is the only side
	-- that can know that), never when the server's own Emote_Stopped echo cut the track short, so this
	-- can't bounce a stop the server already performed back at it.
	EmoteAnimator.SetFinishedCallback(function(emoteId: string)
		if not notifyFinishedRemote then
			return
		end
		logger:debug("Emote animation finished naturally", { emoteId = emoteId })
		notifyFinishedRemote:FireServer(emoteId)
	end)

	local startedRemote = NetworkBridge.GetRemoteEvent(EmoteConstants.RemoteNames.Started)
	startedRemote.OnClientEvent:Connect(function(payload: Types.EmoteStartedPayload)
		if typeof(payload) ~= "table" or typeof(payload.EmoteId) ~= "string" then
			logger:warn("Malformed Emote_Started payload ignored", { payload = tostring(payload) })
			return
		end
		logger:debug("Emote started", { emoteId = payload.EmoteId })
		setActiveEmote(payload.EmoteId)
		EmoteAnimator.Play(payload.EmoteId)
	end)

	local stoppedRemote = NetworkBridge.GetRemoteEvent(EmoteConstants.RemoteNames.Stopped)
	stoppedRemote.OnClientEvent:Connect(function(payload: Types.EmoteStoppedPayload)
		if typeof(payload) ~= "table" or typeof(payload.EmoteId) ~= "string" then
			logger:warn("Malformed Emote_Stopped payload ignored", { payload = tostring(payload) })
			return
		end
		logger:debug("Emote stopped", { emoteId = payload.EmoteId })
		setActiveEmote(nil)
		EmoteAnimator.Stop()
	end)

	-- See Shared/PlayerLifecycle.lua. EmoteAnimator.BindCharacter does its own Humanoid/Animator
	-- lookup, so waiting for the Humanoid first is not new behaviour here -- it just moves the wait to
	-- the one place that also re-checks the character is still current afterwards.
	PlayerLifecycle.BindLocalCharacter({
		Scope = "EmoteController",
		OnCharacter = function(character: Model)
			-- A new body is proof the old emote is over, whether or not an Emote_Stopped echo for it
			-- ever lands: EmoteSystem clears its own activeEmotes entry on death (GameplayEvents.
			-- OnPlayerKilled) and fires Stopped at the dying character's owner, but a respawn that
			-- races that echo would otherwise leave this flag latched true forever -- and a latched
			-- true is the one failure mode that matters here, since it makes EmoteController.
			-- RequestStop keep firing a remote for an emote nobody is playing. The same backstop
			-- reflex, for the same reason, as BlimpController's own CharacterAdded prompt restore.
			setActiveEmote(nil)
			EmoteAnimator.BindCharacter(character)
		end,
	})

	logger:info("EmoteController.Start() complete")
end

return EmoteController
