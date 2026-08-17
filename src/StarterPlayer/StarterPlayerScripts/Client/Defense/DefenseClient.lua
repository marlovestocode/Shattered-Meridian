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
	This is that module's first real caller: register the clip, then SetClaim/Clear a "Defense" layer
	on press/release. Bind/Unbind track the character lifecycle exactly like a per-rig manager is
	meant to; markers and manual track bookkeeping are deliberately NOT reached for here -- the
	manager owns the AnimationTrack and nothing outside it is supposed to touch one directly.

	BLOCK AND PARRY SHARE ONE INPUT, as Constants.Keybinds.Defaults.Block has documented since before
	either existed: a press opens a short parry window, holding past it is a plain block. There is no
	separate parry key and there should not be -- the whole mechanic is that committing to a block
	early is the parry.

	Does not own: the window's timing (the animation asset does), whether a press arms anything
	(DefenseSystem), or the HUD's guard readout (a future consumer of the DefenseState Attribute).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local AnimationManager = require(ReplicatedStorage.Shared.Animation.AnimationManager)
local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)
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

-- ONE manager for the local player's whole lifetime, bound/unbound per life -- the same "construct
-- once, Bind() per respawn" shape AnimationManager.new's own header recommends for a caller that owns
-- exactly one rig. Nothing else in this codebase has migrated to this module yet (CombatAnimator/
-- FlightAnimator/EmoteAnimator/ParkourAnimator still each hand-roll their own tracks dict), so this
-- manager arbitrates only among ITS OWN claims for now -- a known, pre-existing gap (see
-- AnimationManager's own header on the four modules it is meant to eventually replace), not one this
-- module can close by itself.
local manager = AnimationManager.new({ Name = "DefenseClient" })

-- Registered once, at module load, under a manager-local key rather than the raw asset id -- lets
-- ParryAnimationId change (or land blank, pre-asset) with nothing here needing to change.
local BLOCK_CLIP = "Parry"
manager:Register(BLOCK_CLIP, DefenseConstants.ParryAnimationId)

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
	local fadeSeconds = DefenseConstants.Presentation.BlockAnimationFadeSeconds
	manager:SetClaim(
		DEFENSE_LAYER,
		BLOCK_SOURCE,
		if held
			then {
				Clip = BLOCK_CLIP,
				Looped = true,
				Priority = Enum.AnimationPriority.Action,
				FadeIn = fadeSeconds,
				FadeOut = fadeSeconds,
			}
			else nil
	)
end

local function onInputBegan(input: InputObject, gameProcessed: boolean): ()
	if gameProcessed then
		return
	end
	if KeybindManager.Matches("Block", input) then
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

local function bindCharacter(nextCharacter: Model): ()
	local root = nextCharacter:FindFirstChild("HumanoidRootPart")
	rootPart = if root and root:IsA("BasePart") then root else nil

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

	local localPlayer = Players.LocalPlayer
	localPlayer.CharacterAdded:Connect(bindCharacter)
	localPlayer.CharacterRemoving:Connect(unbind)
	if localPlayer.Character then
		bindCharacter(localPlayer.Character)
	end

	logger:info("DefenseClient started")
end

-- Whether the guard key is currently held. For the HUD and for any future consumer that wants the
-- local, zero-latency answer rather than waiting for the server's published DefenseState.
function DefenseClient.IsBlockHeld(): boolean
	return blockHeld
end

return DefenseClient
