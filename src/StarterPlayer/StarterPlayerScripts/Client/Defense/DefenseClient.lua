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

	A PRESS THAT WILL PARRY PLAYS TWO CLIPS IN SEQUENCE; A PRESS THAT WILL ONLY BLOCK PLAYS ONE. The
	parry swing-up (whose markers separately arm the server's parry window -- entirely unaffected by this
	client-side sequencing) plays once and hands the layer to the block-hold loop when the parry window
	closes -- not when the clip happens to end, which left the guard pose arriving well after the guard
	itself was up. A press that will not arm a parry (guard dropped too recently, a whiffed tap's lockout,
	a press held through a swing or a stun, no window at all) skips the swing-up and raises the held guard
	directly. Which one a press is gets predicted on the key edge by Client/Defense/ParryPrediction.lua and
	corrected by the server's verdict on that press (DefenseTypes.PressVerdict). Before, every press played
	the swing-up, so a press the server had turned into a plain block LOOKED like a parry -- which is how a
	block reads as "it should have parried". See claimGuardPress for the claims and the handoff.

	BOTH CLIPS ARE PER-WEAPON. Which pair a press plays is resolved by
	Shared/Defense/WeaponDefenseAnimations.lua off the drawn weapon's own Animations/PARRY and
	Animations/BLOCK folders, falling back to DefenseConstants.ParryAnimationId/BlockHoldAnimationId
	when a weapon authors neither (see that module's header on why it falls back where the IDLE slot's
	equivalent deliberately does not). The drawn weapon comes from this module's own
	Weapon_InventoryChanged listener -- see setArmedWeapon and onInventoryChanged below.

	THE SERVER RESOLVES THE PARRY CLIP SEPARATELY AND MUST AGREE WITH THIS MODULE ABOUT IT. A parry
	window is the ParryStart/ParryClose markers on the parry clip, so a per-weapon parry clip is a
	per-weapon parry TIMING -- Server/Main.server.lua wires AttackRequestSystem.OnWeaponChanged into
	DefenseSystem.SetParryAnimation through the same WeaponDefenseAnimations.GetParry this module
	calls. Two callers of one resolver, deliberately, rather than the server trusting a client-sent id.

	BLOCK AND PARRY SHARE ONE INPUT, as Constants.Keybinds.Defaults.Block has documented since before
	either existed: a press opens a short parry window, holding past it is a plain block. There is no
	separate parry key and there should not be -- the whole mechanic is that committing to a block
	early is the parry.

	Does not own: the window's timing (the animation asset does), whether a press arms anything
	(DefenseSystem), or the HUD's guard readout (a future consumer of the DefenseState Attribute).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnimationManager = require(ReplicatedStorage.Shared.Animation.AnimationManager)
local Constants = require(ReplicatedStorage.Shared.Constants)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Trove = require(ReplicatedStorage.Shared.Trove)
local WeaponConstants = require(ReplicatedStorage.Shared.Combat.WeaponConstants)
local WeaponDefenseAnimations = require(ReplicatedStorage.Shared.Defense.WeaponDefenseAnimations)
local AirComboAttributes = require(ReplicatedStorage.Shared.AirCombo.AirComboAttributes)
local DefenseTypes = require(ReplicatedStorage.Shared.Defense.DefenseTypes)

local LocalCombatState = require(script.Parent.Parent.Combat.LocalCombatState)
local CombatAnimator = require(script.Parent.Parent.FX.CombatAnimator)
local InputRouter = require(script.Parent.Parent.Input.InputRouter)
local ParryPrediction = require(script.Parent.ParryPrediction)

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

-- Whether the next press arms a parry, predicted from this client's own key edges and corrected by the
-- server -- see ParryPrediction's header. One for the player's whole session, Reset per life.
local predictor = ParryPrediction.New()

-- Registered once, at module load, under manager-local keys rather than the raw asset ids -- lets
-- ParryAnimationId/BlockHoldAnimationId change (or land blank, pre-asset) with nothing here needing
-- to change. Two clips, not one: BLOCK_CLIP is the parry swing-up (plays once), BLOCK_HOLD_CLIP is
-- the held-guard loop it hands off to -- see setBlockHeld below for the sequencing.
--
-- THESE TWO ARE THE BASELINE PAIR, NOT NECESSARILY WHAT PLAYS. A drawn weapon that authors its own
-- Animations/PARRY and Animations/BLOCK clips overrides them per weapon -- see setArmedWeapon below,
-- which is what actually decides which key each claim names. Resolved through
-- Shared/Defense/WeaponDefenseAnimations.Get* rather than read straight off DefenseConstants so the
-- baseline goes through the SAME normalisation a per-weapon override does; a bare digits-only id in
-- either place would otherwise resolve here and not there (or the reverse), which is a difference
-- nothing would report.
local BLOCK_CLIP = "Parry"
local BLOCK_HOLD_CLIP = "BlockHold"
local baselineParryId = WeaponDefenseAnimations.GetParry(nil)
local baselineBlockId = WeaponDefenseAnimations.GetBlock(nil)
manager:Register(BLOCK_CLIP, baselineParryId)
manager:Register(BLOCK_HOLD_CLIP, baselineBlockId)

-- The two keys the NEXT press will claim. Start as the baseline pair and are re-pointed by
-- setArmedWeapon on every draw/sheathe/select push.
--
-- PER-WEAPON KEYS, NOT ONE KEY RE-REGISTERED, and that is a correctness requirement rather than a
-- style choice: AnimationManager caches loaded tracks by CLIP KEY for the life of a bind (its own
-- getTrack), so re-pointing a single "Parry" key at a second weapon's asset id would leave the first
-- weapon's track cached under it and the wrong clip playing until the next respawn. A weapon whose
-- clip resolves to the baseline anyway keeps the baseline key rather than getting a redundant second
-- registration of the same id, which would load and hold a duplicate AnimationTrack per weapon.
--
-- The one thing this does NOT survive is an author editing a weapon's Animation.AnimationId LIVE in
-- Studio mid-session: the registry updates, the already-loaded track under that key does not. Redraw
-- after a respawn to see the change. Every other animation path in this codebase has the same
-- property, and paying a per-press cache bust to close it is the wrong trade for an authoring-only nit.
local parryClipKey = BLOCK_CLIP
local blockClipKey = BLOCK_HOLD_CLIP

local DEFENSE_LAYER = "Defense"
local BLOCK_SOURCE = "Block"
-- Client/FX/CombatAnimator.lua's own key for this source in its activeActionSources set -- see
-- CombatAnimator.SetActionAnimationActive's header for why the block/parry hold has to report itself
-- there the same way AttackInputClient's swing claim does.
local ACTION_SOURCE = "Defense"

-- Client/Loading/AssetPreloader.lua's manifest -- see that module's header: "an asset missing from
-- here doesn't fail loudly, it just cold-loads at first use," which for a block/parry animation means
-- the FIRST press of a session eating a hitch instead of the loading screen. Returns raw content ids
-- despite the name, the same contract Client/Parkour/ParkourAnimator.lua's own GetPreloadInstances
-- uses -- AnimationManager pools its own template Instances internally and does not hand them out,
-- so ids are the only thing this module has to preload with. AssetPreloader wraps each one in a
-- throwaway Animation before preloading, because PreloadAsync rejects a bare content id outright;
-- see animationFor's header there.
function DefenseClient.GetPreloadInstances(): { string }
	return manager:GetPreloadIds()
end

-- Weapon -------------------------------------------------------------------------------------------

-- Points parryClipKey/blockClipKey at whichever pair `weaponId` should defend with, registering the
-- weapon's own clips under per-weapon keys the first time it is seen. See those two fields' own header
-- for why a per-weapon key rather than one re-registered key.
--
-- A SHEATHED WEAPON TAKES THE BASELINE, which is why `drawn` is a parameter rather than this reading
-- Selected alone: an unarmed player still blocks, and blocking bare-handed with a sword's guard pose
-- would be a pose with no sword in it. Same rule the server applies from its own side --
-- AttackRequestSystem reports a nil weapon on sheathe, and WeaponDefenseAnimations resolves nil to the
-- baseline.
--
-- DOES NOT TOUCH A CLAIM IN FLIGHT. A swap mid-block re-points the keys and nothing else; the parry
-- clip already playing plays out, and claimBlockHold's own deferred read of blockClipKey is what picks
-- the new weapon up at the handoff. Re-claiming here instead would restart the parry swing-up from
-- frame zero on a guard that is already up -- a fresh parry window's worth of animation for an input
-- the player never made.
-- One slot's key: the shared baseline key when this weapon resolves to the baseline clip anyway (so
-- the two never get a duplicate registration of the same id), a per-weapon key otherwise.
local function clipKeyFor(baselineKey: string, armed: string?, resolved: string, baselineId: string): string
	if armed == nil or resolved == baselineId then
		return baselineKey
	end
	local key = `{baselineKey}:{armed}`
	manager:Register(key, resolved)
	return key
end

local function setArmedWeapon(weaponId: string?, drawn: boolean): ()
	local armed = if drawn then weaponId else nil
	parryClipKey = clipKeyFor(BLOCK_CLIP, armed, WeaponDefenseAnimations.GetParry(armed), baselineParryId)
	blockClipKey = clipKeyFor(BLOCK_HOLD_CLIP, armed, WeaponDefenseAnimations.GetBlock(armed), baselineBlockId)
end

-- Feeds setArmedWeapon straight off the server's own inventory push. Read here directly rather than
-- through Client/Combat/WeaponInventoryClient.lua or by borrowing CombatAnimator's copy, for the
-- reason CombatAnimator's own identical listener records: that module documents itself as the whole
-- module for driving the inventory HUD and nothing else, and Roblox remotes support any number of
-- independent listeners for free.
--
-- THIS REMOTE, NOT AttackConstants' WeaponChanged, and the difference is not cosmetic: the combat
-- layer's WeaponChanged remote fires only from handleSwap (the swap key), NOT from
-- AttackRequestSystem.SetWeapon (draw/sheathe) and NOT from bindCharacter (spawn) -- so a client
-- listening to it would miss the two events that matter most here. Weapon_InventoryChanged is
-- re-pushed on every pickup/draw/sheathe/select and on every bind, which is the complete signal.
local function onInventoryChanged(raw: unknown): ()
	if typeof(raw) ~= "table" then
		return
	end
	local payload = raw :: WeaponConstants.InventoryPayload
	if typeof(payload.Drawn) ~= "boolean" then
		return
	end
	setArmedWeapon(payload.Selected, payload.Drawn)
end

-- Input --------------------------------------------------------------------------------------------

-- `pressId` rides a press only, so the server's verdict on it can be matched to the press it answers.
local function sendBlocking(blocking: boolean, pressId: number?): ()
	local remote = setBlockingRemote
	if not remote then
		return
	end
	remote:FireServer(blocking, pressId)
end

-- Claims the held-guard loop -- the second half of the press sequence below, and also what a
-- released-then-instantly-repressed block re-enters through if the parry clip's OnFinished fires
-- after a fresh press already re-claimed BLOCK_CLIP (the `blockHeld` guard at the call site is what
-- actually prevents that race; this function only ever runs when it's still wanted).
--
-- Also the WHOLE of a press predicted to only block -- see claimGuardPress. `fadeIn` is the press fade for
-- that case and the (longer) handoff fade when it follows the parry swing-up.
local function claimBlockHold(fadeIn: number): ()
	manager:SetClaim(DEFENSE_LAYER, BLOCK_SOURCE, {
		-- Read at claim time, not captured when the press started: a weapon swapped DURING a held
		-- guard should hand off into the weapon the player is actually holding now.
		Clip = blockClipKey,
		Looped = true,
		Priority = Enum.AnimationPriority.Action,
		FadeIn = fadeIn,
		FadeOut = DefenseConstants.Presentation.BlockAnimationFadeSeconds,
		-- See ACTION_SOURCE's own header -- this is the second of the two-phase claim's clips, so it
		-- needs the same stand-down-CombatAnimator's-armed-idle wiring the first phase gets below.
		OnFinished = function(_clip: string, _reason: AnimationManager.FinishReason)
			CombatAnimator.SetActionAnimationActive(ACTION_SOURCE, false)
		end,
	})
	CombatAnimator.SetActionAnimationActive(ACTION_SOURCE, manager:GetActiveClip(DEFENSE_LAYER) ~= nil)
end

-- Bumped by every new press claim and every release, so a scheduled parry-to-hold handoff that belongs to
-- an earlier press finds itself stale and does nothing.
local handoffGeneration = 0

-- Hands the parry swing-up over to the held-guard loop at the moment the parry window closes -- the moment
-- the server's guard stops being a parry and becomes a block. The swing-up is usually longer than the
-- window, and waiting for it to finish (the old handoff) left the held-guard pose arriving a good while
-- after the guard it depicts. A clip SHORTER than the window still hands off early through its own
-- OnFinished (claimGuardPress), whichever comes first.
local function scheduleHandoff(press: ParryPrediction.Press, parryClip: string): ()
	local window = press.Window
	if window == nil then
		return
	end
	handoffGeneration += 1
	local generation = handoffGeneration
	local delaySeconds = math.max(press.At + window.Close - os.clock(), 0)
	task.delay(delaySeconds, function()
		if generation ~= handoffGeneration or not blockHeld then
			return
		end
		-- Only if the swing-up is still what is playing: a correction or a Completed chain may already
		-- have moved the layer on.
		if manager:GetActiveClip(DEFENSE_LAYER) == parryClip then
			claimBlockHold(DefenseConstants.Presentation.BlockAnimationFadeSeconds)
		end
	end)
end

-- Plays the guard press. Only ever called while the key is down and the body is free -- see
-- raiseGuardWhenFree.
--
-- A PRESS PREDICTED TO ONLY BLOCK goes straight to the held-guard loop: no swing-up, because the swing-up
-- is the parry and this press is not one. A PRESS PREDICTED TO PARRY plays the swing-up once and hands off
-- to the loop at the window's close (scheduleHandoff) or at the clip's own end, whichever is first. Either
-- way the first clip fades in over Presentation.PressFadeInSeconds, the short press fade -- the pose on the
-- key edge is the latency the player feels.
local function claimGuardPress(): ()
	local press = predictor:GetHeldPress()
	-- Any handoff scheduled by an earlier claim is for a swing-up this call is about to replace.
	handoffGeneration += 1
	local pressFade = DefenseConstants.Presentation.PressFadeInSeconds
	if press == nil or not press.Armed then
		claimBlockHold(pressFade)
		return
	end

	-- Claimed off the LOCAL press/release, not the server's StateChanged echo -- the same "client
	-- predicts its own press for feel" split this file's header describes for the parry facing snap.
	-- SetClaim(layer, source, nil) clears -- AnimationManager.Register already made BLOCK_CLIP resolve
	-- to nothing if ParryAnimationId is blank, so a claim with no asset yet is a safe, silent no-op
	-- rather than something this module needs to guard against separately.
	--
	-- OnFinished only chains into the held-guard loop when the reason is "Completed" (the clip actually
	-- played out) AND the key is still down -- either guard alone is not enough: a release mid-swing
	-- retires the entry with "Cleared"/"Superseded", never "Completed", but a same-frame
	-- release-then-repress could otherwise still land a stale hold claim after the key had already gone
	-- back down, which the blockHeld check closes. On release there is nothing to chain: setBlockHeld's
	-- SetClaim(nil) clears whichever of the two clips is currently active.
	local parryClip = parryClipKey
	manager:SetClaim(DEFENSE_LAYER, BLOCK_SOURCE, {
		Clip = parryClip,
		Looped = false,
		Priority = Enum.AnimationPriority.Action,
		FadeIn = pressFade,
		FadeOut = DefenseConstants.Presentation.BlockAnimationFadeSeconds,
		OnFinished = function(_clip: string, reason: AnimationManager.FinishReason)
			-- Cleared unconditionally, for every reason -- see ACTION_SOURCE's own header. If
			-- this chains into claimBlockHold below, that call re-asserts true for the second
			-- phase; if it doesn't, nothing is holding Enum.AnimationPriority.Action on this
			-- layer any more and the armed-idle loop is correctly free to resume.
			CombatAnimator.SetActionAnimationActive(ACTION_SOURCE, false)
			if reason == "Completed" and blockHeld then
				claimBlockHold(DefenseConstants.Presentation.BlockAnimationFadeSeconds)
			elseif reason == "Failed" and blockHeld then
				-- No swing-up to show (no asset yet, or it failed to load): the guard still goes up.
				-- Fires synchronously inside the SetClaim above, so this is the press fade, not a handoff.
				claimBlockHold(pressFade)
			end
		end,
	})
	-- Queried rather than assumed true -- see AttackInputClient.playSwing's identical comment on
	-- why a claim whose track failed to load (retiring synchronously inside SetClaim above, before
	-- this line runs) must not be re-asserted active.
	CombatAnimator.SetActionAnimationActive(ACTION_SOURCE, manager:GetActiveClip(DEFENSE_LAYER) ~= nil)
	scheduleHandoff(press, parryClip)
end

-- Whether the local body is held in an air combo right now. Read off the same replicated Attribute the
-- server reads (Shared/AirCombo/AirComboAttributes), because an air-held press is the one press the server
-- never defers: the parry is an air-held body's one way out, and it arms through the stun.
local function isAirHeld(): boolean
	local humanoid = boundHumanoid
	return humanoid ~= nil and AirComboAttributes.IsHeld(humanoid)
end

-- The ground half of the same rule (DefenseConstants.StunParry): stunned by a hit, not running a swing of
-- its own. The server's DefenseSystem.isStunHeld, mirrored off LocalCombatState.
local function isStunHeld(now: number): boolean
	local config = DefenseConstants.StunParry
	return config.Enabled
		and config.WindowScale > 0
		and LocalCombatState.IsStunned(now)
		and LocalCombatState.SwingEndsAt() <= now
end

-- A held body -- air-held or stunned on the ground -- parries through the stun rather than waiting it out.
local function parriesThroughStun(now: number): boolean
	return isAirHeld() or isStunHeld(now)
end

-- Whether a press made at `now` reaches the server on a free body -- the same rule as its bodyCommitted
-- gate, read off this client's own mirror of the swing and the stun.
local function bodyIsFree(now: number): boolean
	return LocalCombatState.FreeAt(now) <= now or parriesThroughStun(now)
end

-- A guard animation waiting for the body to be free: pressed mid-swing or while stunned. See
-- raiseGuardWhenFree.
local guardAnimationDeferred = false
local guardGeneration = 0

-- Starts the guard animation the moment this body is free of its own swing and any hitstun -- the
-- same rule Server/Combat/Defense/DefenseSystem.lua now enforces on the guard itself (it holds the
-- press until then; see its bodyCommitted). Before this, the guard animation started on the key edge
-- no matter what: holding F mid-swing played the block over the attack while the swing's hitbox was
-- still live. Rescheduled rather than polled, and re-checked when it fires, since a new hit can extend
-- the stun in the meantime; LocalCombatState.OnReleased also calls it, so a swing cut short (a parry)
-- frees the guard on that frame rather than at the deadline it was scheduled against.
local function raiseGuardWhenFree(): ()
	if not blockHeld or not guardAnimationDeferred then
		return
	end
	local now = os.clock()
	-- GuardFreeAt, not FreeAt: a guard may cut the tail of this body's own swing (AttackConstants.GuardCut),
	-- and the server does exactly that. bodyIsFree above keeps the full swing -- a guard raised by the cut is
	-- a BLOCK, so it must not be predicted as a parry.
	local freeAt = LocalCombatState.GuardFreeAt(now)
	if freeAt > now and not parriesThroughStun(now) then
		guardGeneration += 1
		local generation = guardGeneration
		task.delay(freeAt - now, function()
			if generation == guardGeneration then
				raiseGuardWhenFree()
			end
		end)
		return
	end
	guardAnimationDeferred = false
	-- The guard came up by cutting this body's own swing: stop that swing's clip here, as the server has.
	if LocalCombatState.SwingEndsAt() > now then
		LocalCombatState.RequestSwingCut()
	end
	predictor:NoteGuardRaised()
	claimGuardPress()
end

local function setBlockHeld(held: boolean): ()
	if held == blockHeld then
		return
	end
	blockHeld = held
	LocalCombatState.SetGuardHeld(held)
	local now = os.clock()

	-- Sent on the edge, whatever the body is doing: the server holds a press it cannot honour yet and
	-- raises the guard itself the moment the body is free, so waiting here would only add a round trip.
	if held then
		-- Predicted BEFORE the claim below reads it: the prediction is what picks the clip.
		local pressId = predictor:Press(now, bodyIsFree(now))
		sendBlocking(true, pressId)
		guardAnimationDeferred = true
		raiseGuardWhenFree()
	else
		predictor:Release(now)
		sendBlocking(false)
		guardAnimationDeferred = false
		guardGeneration += 1
		handoffGeneration += 1
		-- SetClaim(layer, source, nil) clears whichever of the two clips is currently active -- and is a
		-- no-op for a guard that never got as far as animating.
		manager:SetClaim(DEFENSE_LAYER, BLOCK_SOURCE, nil)
	end
end

-- Whether the movement framework has this body in a committed traversal. Mirrors the identical gate
-- in Client/Combat/AttackInputClient.lua, off the same client-written Attribute, and is refused
-- server-side in DefenseSystem.SetBlocking regardless -- see Shared/Parkour/ParkourOwnership.
local function parkourOwnsBody(): boolean
	local currentHumanoid = boundHumanoid
	return currentHumanoid ~= nil and currentHumanoid:GetAttribute(Constants.Attributes.ParkourActionOwned) == true
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

-- The server's verdict disagreed with the press's prediction. Puts the right clip on the layer -- but only
-- while the guard animation is actually up: a press still waiting on a committed body reads the corrected
-- prediction when it rises (claimGuardPress), so there is nothing to swap yet.
local function correctPressPresentation(): ()
	local press = predictor:GetHeldPress()
	if press == nil or not blockHeld or guardAnimationDeferred then
		return
	end
	if press.Armed then
		-- Late news that this press IS a parry. Worth showing only while the window it armed could still
		-- be open; past that, the swing-up would be a parry animation for a window already spent.
		local window = press.Window
		if window and os.clock() < press.At + window.Close then
			claimGuardPress()
		end
	elseif manager:GetActiveClip(DEFENSE_LAYER) ~= blockClipKey then
		-- Predicted a parry the server turned into a plain block: drop the swing-up for the guard it is.
		handoffGeneration += 1
		claimBlockHold(DefenseConstants.Presentation.BlockAnimationFadeSeconds)
	end
end

-- The Window field, checked rather than trusted: three finite numbers or it is treated as absent.
local function readWindow(raw: unknown): DefenseTypes.WindowShape?
	if typeof(raw) ~= "table" then
		return nil
	end
	local window = raw :: { [string]: unknown }
	local open, close, recoveryEnd = window.Open, window.Close, window.RecoveryEnd
	if typeof(open) ~= "number" or typeof(close) ~= "number" or typeof(recoveryEnd) ~= "number" then
		return nil
	end
	return { Open = open, Close = close, RecoveryEnd = recoveryEnd }
end

local function onStateChanged(rawPayload: unknown): ()
	if typeof(rawPayload) ~= "table" then
		return
	end
	local payload = rawPayload :: { [string]: unknown }

	-- Every push carries the window the next press would arm (absent when none would) and the state.
	predictor:SetWindow(readWindow(payload.Window))
	if typeof(payload.State) == "string" then
		predictor:NoteServerState(payload.State :: string)
	end

	-- Sent only on a parry: the snap, and the prediction learning its press landed.
	if typeof(payload.FaceTowards) == "Vector3" then
		faceTowards(payload.FaceTowards :: Vector3)
		predictor:NoteParryLanded()
	end

	local verdict = payload.Press
	if typeof(verdict) == "table" then
		local id = (verdict :: { [string]: unknown }).Id
		local armed = (verdict :: { [string]: unknown }).Armed
		if typeof(id) == "number" and typeof(armed) == "boolean" and predictor:Confirm(id, armed) then
			correctPressPresentation()
		end
	end
end

-- Lifecycle -----------------------------------------------------------------------------------------

-- EVADE-FROM-GUARD. The server drops a raised guard the moment it accepts an evade (DefenseSystem.BeginEvade
-- -> DefenseStateMachine.BeginEvade's Release), but nothing tells THIS client: the key is still
-- physically down, so blockHeld stays true and the guard pose keeps playing over a guard that no longer
-- exists. The server's own ParkourState Attribute turning "Evade" is exactly the "your evade was accepted"
-- signal, already replicated, so this mirrors the server's release off it rather than adding a remote
-- or reaching into the parkour framework. The release it sends is redundant (the server has already
-- released) and harmless -- Release on a machine whose guard is down is a no-op. Re-pressing the key
-- after the evade raises the guard as normal.
local function onParkourStateChanged(humanoid: Humanoid): ()
	if blockHeld and humanoid:GetAttribute(Constants.Attributes.ParkourState) == "Evade" then
		setBlockHeld(false)
	end
end

local function bindCharacter(nextCharacter: Model, humanoid: Humanoid, life: Trove.TroveInstance): ()
	-- The Humanoid was already waited out by Shared/PlayerLifecycle.lua before this is called. The
	-- HumanoidRootPart is NOT, and still needs its own wait here: it is this module's own extra
	-- requirement, replicates independently of the Humanoid, and PlayerLifecycle deliberately knows
	-- about exactly one part of a character so that every caller does not inherit every caller's
	-- requirements. A missing root is survivable for a life (the gate that reads it simply refuses),
	-- which is why it warns nothing and does not abort the bind.
	rootPart = CharacterUtil.AwaitRoot(nextCharacter)
	boundHumanoid = humanoid

	-- A new life never inherits the previous one's guard. The server rebuilds its own state on
	-- registration; this is the client half of the same reset, and without it a player who died
	-- mid-block would respawn with this module believing the key was still down.
	if blockHeld then
		blockHeld = false
		sendBlocking(false)
	end
	-- The server's fresh machine has no lockout and no recent guard; neither does the prediction.
	predictor:Reset()

	-- AnimationManager.Bind() drops the previous life's claims/tracks itself (Unbind() runs first
	-- thing inside Bind()) -- nothing here needs to clear DEFENSE_LAYER separately.
	manager:Bind(nextCharacter)

	life:Connect(humanoid:GetAttributeChangedSignal(Constants.Attributes.ParkourState), function()
		onParkourStateChanged(humanoid)
	end)
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

	-- Connected in Start() rather than at module load, for the reason CombatAnimator's own listener
	-- has to task.spawn instead: NetworkBridge.GetRemoteEvent WaitForChild's the first time a name is
	-- resolved, and a blocking wait at require time would stall the client boot behind this one remote
	-- existing. This module already has a Start() to hang it off, so no task.spawn is needed here.
	local inventoryChanged = NetworkBridge.GetRemoteEvent(WeaponConstants.Network.RemoteNames.InventoryChanged)
	inventoryChanged.OnClientEvent:Connect(onInventoryChanged)

	-- Bound through InputRouter's "Gameplay" layer, which now owns both the gameProcessed check and
	-- the Constants.Attributes.UiModalOpen gate this used to hand-roll -- right-clicking inside your
	-- own character sheet should not raise your guard any more than left-clicking there should throw
	-- a punch, the same reasoning Client/Combat/AttackInputClient.lua's identical gate documents for
	-- itself. parkourOwnsBody() stays here, inline, because it is a parkour-ownership question, not a
	-- generic modal/gameProcessed one -- InputRouter has no opinion about it.
	--
	-- The Ended callback is unconditional on purpose, and is exactly what InputRouter guarantees for
	-- every "Gameplay" binding regardless of gameProcessed or the modal Attribute at release time: a
	-- guard already up when a traversal started -- or when a menu opened over it -- must still be
	-- able to come down, and a gate that can strand it raised is worse than the one it closes.
	-- A swing cut short frees the body before the deadline raiseGuardWhenFree scheduled against.
	LocalCombatState.OnReleased(raiseGuardWhenFree)

	InputRouter.Bind("Block", {
		Layer = "Gameplay",
		Began = function()
			if parkourOwnsBody() then
				return
			end
			setBlockHeld(true)
		end,
		Ended = function()
			setBlockHeld(false)
		end,
	})

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
