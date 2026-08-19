--!strict
--[[
	DefenseClient.lua

	Owns: the LOCAL player's half of block and parry -- the input edge, the local animation, the
	marker-driven presentation, and the facing snap a successful parry earns.

	DECIDES NOTHING. Every gameplay question -- whether a parry armed, whether a contact was parried,
	how much guard a block cost -- is answered by Server/Combat/Defense/DefenseSystem.lua. This module
	sends the press and displays the answer, which is the same split
	Client/Parkour/ParkourController.lua keeps with ParkourSystem and the same one
	software-architecture.md states as "server owns truth, client owns feel."

	ANIMATION GOES THROUGH Shared/Animation/AnimationManager.lua, not a hand-rolled Animator:
	LoadAnimation call -- that module is the codebase's shared claim/layer arbitrator (see its own
	header for why four earlier modules each hand-rolling this was the actual bug source: nobody
	arbitrated who owned the body, a stopped track stayed stopped, and death/reset were nobody's job).
	This is that module's first real caller: register the clips, then SetClaim/Clear a "Defense" layer
	on press/release. Bind/Unbind track the character lifecycle exactly like a per-rig manager is
	meant to; markers and manual track bookkeeping are deliberately NOT reached for here -- the
	manager owns the AnimationTrack and nothing outside it is supposed to touch one directly.

	A PRESS PLAYS TWO CLIPS IN SEQUENCE, not one: DefenseConstants.ParryAnimationId (the swing-up,
	whose markers separately arm the server's parry window -- entirely unaffected by this client-side
	sequencing) plays once, then AnimationManager's OnFinished hands the layer to
	DefenseConstants.BlockHoldAnimationId on a loop for as long as the key stays down. See
	setBlockHeld's own comment for the two-phase claim and the guards around the handoff.

	BLOCK AND PARRY SHARE ONE INPUT, as Constants.Keybinds.Defaults.Block has documented since before
	either existed: a press opens a short parry window, holding past it is a plain block. There is no
	separate parry key and there should not be -- the whole mechanic is that committing to a block
	early is the parry.

	Does not own: the window's timing (the animation asset does), whether a press arms anything
	(DefenseSystem), or the HUD's guard readout (a future consumer of the DefenseState Attribute).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local AnimationManager = require(ReplicatedStorage.Shared.Animation.AnimationManager)
local Constants = require(ReplicatedStorage.Shared.Constants)
local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)

local KeybindManager = require(script.Parent.Parent.Input.KeybindManager)

local logger = Logger.scope("DefenseClient")

local DefenseClient = {}

local started = false
local setBlockingRemote: RemoteEvent? = nil

-- Whether the guard key is currently held, tracked here so a release that arrives while a UI element
-- had focus still reaches the server. Without it a player who tabbed away mid-block would be left
-- holding a guard they had let go of.
local blockHeld = false

-- Only the root part is held, not the character: the facing snap is the sole thing this module does
-- to the body, and a cached character reference nothing reads is a field that goes stale silently.
local rootPart: BasePart? = nil
-- The local Humanoid, cached at bind for the parkour gate below. Cached rather than looked up per
-- press for the same reason AttackInputClient caches its own: this runs on the input edge.
local boundHumanoid: Humanoid? = nil

-- ONE manager for the local player's whole lifetime, bound/unbound per life -- the same "construct
-- once, Bind() per respawn" shape AnimationManager.new's own header recommends for a caller that owns
-- exactly one rig. Nothing else in this codebase has migrated to this module yet (CombatAnimator/
-- FlightAnimator/EmoteAnimator/ParkourAnimator still each hand-roll their own tracks dict), so this
-- manager arbitrates only among ITS OWN claims for now -- a known, pre-existing gap (see
-- AnimationManager's own header on the four modules it is meant to eventually replace), not one this
-- module can close by itself.
local manager = AnimationManager.new({ Name = "DefenseClient" })

-- Registered once, at module load, under manager-local keys rather than the raw asset ids -- lets
-- ParryAnimationId/BlockHoldAnimationId change (or land blank, pre-asset) with nothing here needing
-- to change. Two clips, not one: BLOCK_CLIP is the parry swing-up (plays once), BLOCK_HOLD_CLIP is
-- the held-guard loop it hands off to -- see setBlockHeld below for the sequencing.
local BLOCK_CLIP = "Parry"
local BLOCK_HOLD_CLIP = "BlockHold"
manager:Register(BLOCK_CLIP, DefenseConstants.ParryAnimationId)
manager:Register(BLOCK_HOLD_CLIP, DefenseConstants.BlockHoldAnimationId)

local DEFENSE_LAYER = "Defense"
local BLOCK_SOURCE = "Block"

-- Client/Loading/AssetPreloader.lua's manifest -- see that module's header: "an asset missing from
-- here doesn't fail loudly, it just cold-loads at first use," which for a block/parry animation means
-- the FIRST press of a session eating a hitch instead of the loading screen. Returns raw content ids,
-- the same contract Client/Parkour/ParkourAnimator.lua's own GetPreloadInstances uses (see that
-- function's own note in AssetPreloader.lua for why some providers hand back ids instead of Animation
-- instances) -- AnimationManager pools its own template Instances internally and does not hand them
-- out, so ids are the only thing this module has to preload with.
function DefenseClient.GetPreloadInstances(): { string }
	return manager:GetPreloadIds()
end

-- Input --------------------------------------------------------------------------------------------

local function sendBlocking(blocking: boolean): ()
	local remote = setBlockingRemote
	if not remote then
		return
	end
	remote:FireServer(blocking)
end

-- Claims the held-guard loop -- the second half of the press sequence below, and also what a
-- released-then-instantly-repressed block re-enters through if the parry clip's OnFinished fires
-- after a fresh press already re-claimed BLOCK_CLIP (the `blockHeld` guard at the call site is what
-- actually prevents that race; this function only ever runs when it's still wanted).
local function claimBlockHold(): ()
	local fadeSeconds = DefenseConstants.Presentation.BlockAnimationFadeSeconds
	manager:SetClaim(DEFENSE_LAYER, BLOCK_SOURCE, {
		Clip = BLOCK_HOLD_CLIP,
		Looped = true,
		Priority = Enum.AnimationPriority.Action,
		FadeIn = fadeSeconds,
		FadeOut = fadeSeconds,
	})
end

local function setBlockHeld(held: boolean): ()
	if held == blockHeld then
		return
	end
	blockHeld = held
	sendBlocking(held)

	-- Claimed off the LOCAL press/release, not the server's StateChanged echo -- the same "client
	-- predicts its own press for feel" split this file's header describes for the parry facing snap.
	-- A press that never arms a parry still raises the guard (DefenseStateMachine.Press's own
	-- fail-soft rule), so claiming here is correct for a plain block too, not just an armed parry.
	-- SetClaim(layer, source, nil) clears -- AnimationManager.Register already made BLOCK_CLIP resolve
	-- to nothing if ParryAnimationId is blank, so a claim with no asset yet is a safe, silent no-op
	-- rather than something this module needs to guard against separately.
	--
	-- TWO-PHASE ON PRESS: BLOCK_CLIP plays ONCE (Looped = false) -- the parry swing-up, whose own
	-- markers are still what arms the server's parry window, completely unaffected by how this client
	-- sequences its OWN presentation on top of it. OnFinished only chains into the held-guard loop
	-- when the reason is "Completed" (the clip actually played out) AND the key is still down --
	-- either guard alone is not enough: a release mid-swing retires the entry with "Cleared"/
	-- "Superseded", never "Completed", but a same-frame release-then-repress could otherwise still
	-- land a stale hold claim after the key had already gone back down, which the blockHeld check
	-- closes. On release there is nothing to chain: SetClaim(nil) below clears whichever of the two
	-- clips is currently active.
	local fadeSeconds = DefenseConstants.Presentation.BlockAnimationFadeSeconds
	manager:SetClaim(
		DEFENSE_LAYER,
		BLOCK_SOURCE,
		if held
			then {
				Clip = BLOCK_CLIP,
				Looped = false,
				Priority = Enum.AnimationPriority.Action,
				FadeIn = fadeSeconds,
				FadeOut = fadeSeconds,
				OnFinished = function(_clip: string, reason: AnimationManager.FinishReason)
					if reason == "Completed" and blockHeld then
						claimBlockHold()
					end
				end,
			}
			else nil
	)
end

-- Whether the movement framework has this body in a committed traversal. Mirrors the identical gate
-- in Client/Combat/AttackInputClient.lua, off the same client-written Attribute, and is refused
-- server-side in DefenseSystem.SetBlocking regardless -- see Shared/Parkour/ParkourOwnership.
local function parkourOwnsBody(): boolean
	local currentHumanoid = boundHumanoid
	return currentHumanoid ~= nil and currentHumanoid:GetAttribute(Constants.Attributes.ParkourActionOwned) == true
end

local function onInputBegan(input: InputObject, gameProcessed: boolean): ()
	if gameProcessed then
		return
	end
	if KeybindManager.Matches("Block", input) then
		-- Only the PRESS is gated. The release below is not, for the same reason it is not gated on
		-- gameProcessed and for the same reason the server refuses only a Press: a guard already up when
		-- a traversal started must still be able to come down, and a gate that can strand it raised is
		-- worse than the one it closes.
		if parkourOwnsBody() then
			return
		end
		setBlockHeld(true)
	end
end

-- Deliberately NOT gated on gameProcessed, unlike the press above. A press that a text box swallowed
-- should not raise the guard; a RELEASE that one swallowed must still lower it, or the character is
-- left blocking with nothing held.
local function onInputEnded(input: InputObject): ()
	if KeybindManager.Matches("Block", input) then
		setBlockHeld(false)
	end
end

-- Presentation --------------------------------------------------------------------------------------

-- Turns the defender to face their attacker. Fired by the server only on a successful parry.
--
-- A parry that leaves you facing the wrong way feels broken even when it worked, and this is the
-- cheapest possible fix for it. Done HERE rather than by writing CFrame from the server because the
-- client owns its own character's physics -- a server rotation write on a player-owned body is
-- fought and then overwritten within a frame.
--
-- Yaw only: pitching the whole body toward an attacker on a ledge above would look like a glitch,
-- not a parry. Falls back to doing nothing rather than to an arbitrary facing if the two positions
-- are stacked, which is the one case where "which way" has no answer.
local function faceTowards(position: Vector3): ()
	local root = rootPart
	if not root or root.Parent == nil then
		return
	end
	local origin = root.Position
	local flattened = Vector3.new(position.X - origin.X, 0, position.Z - origin.Z)
	if flattened.Magnitude <= 0 then
		return
	end
	root.CFrame = CFrame.lookAt(origin, origin + flattened.Unit)
end

type StatePayload = {
	State: string,
	Guard: number,
	GuardMax: number,
	FaceTowards: Vector3?,
}

local function onStateChanged(rawPayload: unknown): ()
	if typeof(rawPayload) ~= "table" then
		return
	end
	local payload = rawPayload :: StatePayload
	if typeof(payload.FaceTowards) == "Vector3" then
		faceTowards(payload.FaceTowards :: Vector3)
	end
end

-- Lifecycle -----------------------------------------------------------------------------------------

local function bindCharacter(nextCharacter: Model, humanoid: Humanoid): ()
	-- The Humanoid was already waited out by Shared/PlayerLifecycle.lua before this is called. The
	-- HumanoidRootPart is NOT, and still needs its own wait here: it is this module's own extra
	-- requirement, replicates independently of the Humanoid, and PlayerLifecycle deliberately knows
	-- about exactly one part of a character so that every caller does not inherit every caller's
	-- requirements. A missing root is survivable for a life (the gate that reads it simply refuses),
	-- which is why it warns nothing and does not abort the bind.
	local root = nextCharacter:WaitForChild("HumanoidRootPart", Constants.Network.WaitForChildTimeoutSeconds)
	rootPart = if root and root:IsA("BasePart") then root else nil
	boundHumanoid = humanoid

	-- A new life never inherits the previous one's guard. The server rebuilds its own state on
	-- registration; this is the client half of the same reset, and without it a player who died
	-- mid-block would respawn with this module believing the key was still down.
	if blockHeld then
		blockHeld = false
		sendBlocking(false)
	end

	-- AnimationManager.Bind() drops the previous life's claims/tracks itself (Unbind() runs first
	-- thing inside Bind()) -- nothing here needs to clear DEFENSE_LAYER separately.
	manager:Bind(nextCharacter)
end

local function unbind(): ()
	rootPart = nil
	-- Dropped with the body it describes -- a stale Humanoid would leave the gate above reading a dead
	-- character's last Attribute, which for a life that ended mid-vault reads true forever.
	boundHumanoid = nil
	-- Cleared without telling the server: the character this guard belonged to is gone, and the
	-- server drops its own registration on the same event. Firing a release for a body that no longer
	-- exists would be a remote call with nothing to act on.
	blockHeld = false

	manager:Unbind()
end

function DefenseClient.Start(): ()
	if started then
		return
	end
	started = true

	setBlockingRemote = NetworkBridge.GetRemoteEvent(DefenseConstants.Network.RemoteNames.SetBlocking)
	local stateChanged = NetworkBridge.GetRemoteEvent(DefenseConstants.Network.RemoteNames.StateChanged)
	stateChanged.OnClientEvent:Connect(onStateChanged)

	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputEnded:Connect(onInputEnded)

	-- See Shared/PlayerLifecycle.lua: the Humanoid wait, the boot-thread task.spawn and the
	-- post-yield "is this still the current character" re-check are its job now, not this file's.
	PlayerLifecycle.BindLocalCharacter({
		Scope = "DefenseClient",
		OnCharacter = bindCharacter,
		OnCharacterRemoving = unbind,
	})

	logger:info("DefenseClient started")
end

-- Whether the guard key is currently held. For the HUD and for any future consumer that wants the
-- local, zero-latency answer rather than waiting for the server's published DefenseState.
function DefenseClient.IsBlockHeld(): boolean
	return blockHeld
end

return DefenseClient
