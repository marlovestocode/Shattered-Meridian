--!strict
--[[
	EmoteController.lua

	Owns: the client-side request/response plumbing for the Emote System -- the SOLE thing a future
	radial wheel UI (a later session) is allowed to call. RequestPlay/RequestSetLoadoutSlot fire the
	corresponding client->server remotes; this module listens for the server's own Emote_Started/
	Emote_Stopped echoes and drives Client/FX/EmoteAnimator.lua from them.

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

function EmoteController.Start(): ()
	requestPlayRemote = NetworkBridge.GetRemoteEvent(EmoteConstants.RemoteNames.RequestPlay)
	requestSetLoadoutSlotRemote = NetworkBridge.GetRemoteEvent(EmoteConstants.RemoteNames.RequestSetLoadoutSlot)
	notifyFinishedRemote = NetworkBridge.GetRemoteEvent(EmoteConstants.RemoteNames.NotifyFinished)

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
		EmoteAnimator.Play(payload.EmoteId)
	end)

	local stoppedRemote = NetworkBridge.GetRemoteEvent(EmoteConstants.RemoteNames.Stopped)
	stoppedRemote.OnClientEvent:Connect(function(payload: Types.EmoteStoppedPayload)
		if typeof(payload) ~= "table" or typeof(payload.EmoteId) ~= "string" then
			logger:warn("Malformed Emote_Stopped payload ignored", { payload = tostring(payload) })
			return
		end
		logger:debug("Emote stopped", { emoteId = payload.EmoteId })
		EmoteAnimator.Stop()
	end)

	-- See Shared/PlayerLifecycle.lua. EmoteAnimator.BindCharacter does its own Humanoid/Animator
	-- lookup, so waiting for the Humanoid first is not new behaviour here -- it just moves the wait to
	-- the one place that also re-checks the character is still current afterwards.
	PlayerLifecycle.BindLocalCharacter({
		Scope = "EmoteController",
		OnCharacter = function(character: Model)
			EmoteAnimator.BindCharacter(character)
		end,
	})

	logger:info("EmoteController.Start() complete")
end

return EmoteController
