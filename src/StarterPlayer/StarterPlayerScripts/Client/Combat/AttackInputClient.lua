--!strict
--[[
	AttackInputClient.lua

	Owns: the LOCAL player's attack input -- the key/mouse/gamepad edge for the light string, the
	heavy string, the five hotbar slots and the weapon swap; the immediate local acknowledgment a
	press earns; and the swing animation the server's confirmation asks for.

	Replaces Client/Combat/TestAttackHarnessClient.lua, which fired one flat test swing at a
	temporary remote so the defence layer had something to classify. That module and its server half
	are deleted; this is the real input layer their own headers said would replace them.

	DECIDES NOTHING. Which move a press means, whether it is allowed, how deep the string is, what a
	landed hit costs -- every one of those is answered by Server/Combat/Attack/AttackRequestSystem.lua
	and the three layers beneath it. This module sends the press and presents the answer, which is the
	same split DefenseClient keeps with DefenseSystem and ParkourController keeps with ParkourSystem,
	and the one software-architecture.md states as "server owns truth, client owns feel."

	RESPONSIVE WITHOUT PREDICTION, and the distinction is the whole design. HitboxEngine's header
	rules out client prediction outright ("no rollback, no client mirror... the deleted
	PredictionMirror/CombatClient pair is not being rebuilt") and this module does not smuggle it back
	in. What it does instead is exactly what DefenseClient already does for the block press:

	  1. The request goes out on the frame the key goes down. Never gated on an animation, never
	     gated on a previous swing finishing -- the server owns "too early" and forgives it by
	     buffering (AttackConstants.Input.BufferSeconds), so holding the press back here would only
	     add latency to a swing the server was going to accept anyway.
	  2. A small local FOV punch plays immediately, as an acknowledgment that the input registered.
	     It is a camera nudge and nothing else: it never claims a hit, never moves a hitbox, and
	     never needs undoing. Worst case it plays and no attack follows, which is cosmetically
	     recoverable in a way a mispredicted HIT would not be.
	  3. Attack_Started is the confirmation and the correction. It carries what the server actually
	     scheduled -- which move, which stage, how long the windup is, which clip -- so the swing
	     animation plays against real numbers rather than a guess.

	THE SWING ANIMATION IS PREDICTED (2026-09-28), and that is presentation, not the hit prediction the
	stack rules out. Waiting for Attack_Started meant the attacker saw their own swing a full round trip
	after pressing -- and every OPPONENT saw it half a round trip later again, since they see the clip
	this client plays. At a real server's ping the victim watched a punch start at about the moment it
	landed. So a Basic/Heavy press now plays the move the server is about to confirm on the frame the key
	goes down:

	  * WHAT is predicted comes from a mirror of SwingSequencer's string (stage, lapse, the landed-combo
	    Finisher rule), updated from every Attack_Started and every Combat_Feedback this client gets.
	  * HOW it plays -- clip, speed, windup/active/recovery -- is the server's own last Attack_Started
	    for that exact MoveId, replayed (confirmedByMoveId), seeded for every stage of a weapon the moment
	    it is in hand (Attack_WeaponChanged's Moves). A move with no server copy is not predicted at all,
	    so a prediction never invents a number.
	  * WHEN: only while the body is free by every local measure the server also gates on (own swing and
	    chain beat over, not stunned, not guarding, neutral defence state, not grabbed/mounted/in a
	    traversal). A press made mid-swing mirrors the server's input buffer and is predicted at the
	    moment the server will throw it.
	  * THE CORRECTION: Attack_Started naming the predicted move confirms it (nothing replays); naming a
	    different one replaces the clip; never arriving cuts the swing after two pings plus the buffer
	    window, because the server refused it. The hitbox, damage and every gate never left the server.

	SPAMMING IS FILTERED HERE TOO, but only where this module genuinely knows the answer. A hotbar
	press whose own cooldown this module is already counting down is dropped locally rather than sent,
	because the server told it that cooldown itself. A Basic/Heavy press is ALWAYS sent, because which
	move it resolves to is server state this module deliberately does not mirror -- guessing would be
	the prediction the stack rules out.

	ANIMATION GOES THROUGH Shared/Animation/AnimationManager.lua, not a hand-rolled Animator:
	LoadAnimation call -- the same choice DefenseClient made and for the same reason (see that
	module's header, and AnimationManager's own, on why four modules each hand-rolling tracks was the
	original bug source). Clips are claimed as raw content ids rather than registry keys: which clip a
	swing plays is authored per move in the Move Editor and can change at runtime, so there is no
	fixed set to register at load. That also means swing clips CANNOT be preloaded at boot the way
	DefenseClient's single parry clip is -- the first use of a newly authored clip pays its own load,
	which is a known and accepted cost of the Move Editor being live rather than baked.

	Every Default move today has a blank AnimationId (DefaultMoveRegistry's own header on why), so
	until clips are authored a swing is felt through the FOV punch, the hit feedback, and the vitals
	moving -- not seen as a body animation. That is a content gap, not a wiring one; this module plays
	whatever the server names the moment a move names something.

	Does not own: the hit/parry/block presentation (Client/Combat/CombatFeedbackClient.lua), the
	block/parry input (Client/Defense/DefenseClient.lua), the hotbar's slot->MoveId binding
	(Client/Combat/HotbarBindings.lua), or what any of it costs (the server).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local AirComboAttributes = require(ReplicatedStorage.Shared.AirCombo.AirComboAttributes)
local AirComboConstants = require(ReplicatedStorage.Shared.AirCombo.AirComboConstants)
local AirComboMoves = require(ReplicatedStorage.Shared.AirCombo.AirComboMoves)
local AnimationManager = require(ReplicatedStorage.Shared.Animation.AnimationManager)
local AttackConstants = require(ReplicatedStorage.Shared.Attack.AttackConstants)
local AttackTypes = require(ReplicatedStorage.Shared.Attack.AttackTypes)
local CombatConstants = require(ReplicatedStorage.Shared.Combat.CombatConstants)
local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)
local CallbackList = require(ReplicatedStorage.Shared.CallbackList)
local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local WeaponConstants = require(ReplicatedStorage.Shared.Combat.WeaponConstants)
local Types = require(ReplicatedStorage.Shared.Types)

local HotbarBindings = require(script.Parent.HotbarBindings)
local LocalCombatState = require(script.Parent.LocalCombatState)
local CombatAnimator = require(script.Parent.Parent.FX.CombatAnimator)
local FOVOffset = require(script.Parent.Parent.FX.FOVOffset)
local InputRouter = require(script.Parent.Parent.Input.InputRouter)
local KeybindManager = require(script.Parent.Parent.Input.KeybindManager)

type AttackStartedPayload = AttackTypes.AttackStartedPayload

local logger = Logger.scope("AttackInputClient")

local AttackInputClient = {}

local PUNCH = AttackConstants.Presentation.SwingPunch
local SLOT_COUNT = AttackConstants.Hotbar.SlotCount

-- Named slots on the shared compositors, so this module's contribution is identifiable and its own
-- to clear -- the same discipline every other FOVOffset/AnimationManager caller keeps.
local FOV_SLOT = "AttackSwing"
local ATTACK_LAYER = "Attack"
local SWING_SOURCE = "Swing"
-- Client/FX/CombatAnimator.lua's own key for this source in its activeActionSources set -- see
-- CombatAnimator.SetActionAnimationActive's header for why the swing claim has to report itself there.
local ACTION_SOURCE = "Attack"

local started = false
local requestRemote: RemoteEvent? = nil
local feintRemote: RemoteEvent? = nil
local toggleDrawRemote: RemoteEvent? = nil
local selectNextRemote: RemoteEvent? = nil

-- The five hotbar keybind actions, resolved once. Types.KeybindAction is a closed union, so building
-- these names by concatenation would type as `string` and silently stop matching if the union were
-- ever renamed -- listing them is what keeps a rename a compile error instead of a dead hotbar.
local HOTBAR_ACTIONS: { Types.KeybindAction } =
	{ "HotbarSlot1", "HotbarSlot2", "HotbarSlot3", "HotbarSlot4", "HotbarSlot5" }

-- When each hotbar slot is usable again, from the server's own CooldownSeconds. This is a MIRROR of
-- something the server told this client, not a second authority: the server enforces the same
-- cooldown regardless, and this only exists so the HUD can draw it and so an obviously-doomed press
-- is not sent at all.
local slotReadyAt: { [number]: number } = {}
local slotListeners: CallbackList.CallbackList<number, number> =
	CallbackList.New(logger, "AttackInputClient.OnSlotCooldown")

-- Throttle for the local press cue -- see AttackConstants.Presentation.SwingPunch.MinIntervalSeconds
-- for why mashing must not strobe the camera.
local lastPunchAt = 0

-- The local player's weapon, as last reported by the server. Presentation only: nothing here decides
-- which weapon is held, and no request payload carries it.
--
-- nil for an empty hand. The server reports every change on Attack_WeaponChanged -- a swap, a draw or
-- sheathe, and every fresh life (AttackRequestSystem.notifyWeaponChanged) -- so this is only stale for
-- the one-way trip of that message.
local currentWeapon: Types.WeaponId? = nil

-- ONE manager for the local player's whole lifetime, bound/unbound per life -- the same "construct
-- once, Bind() per respawn" shape AnimationManager.new's own header recommends for a caller that owns
-- exactly one rig, and the same one DefenseClient already uses. Its claims are independent of
-- DefenseClient's: two managers, two layers, no shared arbitration (a known, pre-existing gap
-- documented in AnimationManager's own header, not one this module can close).
local manager = AnimationManager.new({ Name = "AttackInputClient" })

-- Assigned in the Prediction section below; declared here because the input handlers above it call it.
local predictPress: (kind: AttackTypes.AttackKind, pressId: number?) -> ()

-- This session's attack press ids (AttackTypes.AttackRequest.PressId), counted up from 1. The server echoes
-- one on Attack_Started or answers it with a "Refused" Attack_Cancelled, which is what cuts a prediction of a
-- press that will never throw -- the timeout in predictSwing is only the backstop now.
local nextPressId = 0
-- Assigned beside the jump suppression below, for the same reason.
local notePressForJump: (kind: AttackTypes.AttackKind, now: number) -> ()

-- Sending -------------------------------------------------------------------------------------------

-- The local Humanoid, cached at bind, for the one question below that needs it. Kept as a field
-- rather than looked up per press: this runs on the input edge, and a FindFirstChildOfClass on every
-- mouse click for a value that changes once a life is a lookup nobody needs to pay for.
local boundHumanoid: Humanoid? = nil

-- Whether the movement framework currently has this body in a committed traversal -- a vault, a
-- slide, a wall-run, a ledge hang. Refused HERE as well as server-side, and this is squarely inside
-- this module's "filtered only where it genuinely knows the answer" rule: the state machine that
-- decides this runs on this very client, so the answer is not a guess about server state the way
-- "which move does this press resolve to" would be.
--
-- The server's own gate in AttackRequestSystem.Throw is still the authority and still refuses these
-- independently -- see Shared/Parkour/ParkourOwnership on why the two see slightly different sets and
-- which one this is here to cover.
local function parkourOwnsBody(): boolean
	local currentHumanoid = boundHumanoid
	return currentHumanoid ~= nil and currentHumanoid:GetAttribute(AttributeConstants.ParkourActionOwned) == true
end

-- Returns the press id it stamped, or nil when the press never left this client.
local function sendRequest(request: AttackTypes.AttackRequest): number?
	if parkourOwnsBody() then
		-- Dropped outright, never buffered -- the same choice the server's own gate makes by keeping
		-- "ParkourAction" out of AttackConstants.Input.TransientRefusals. A press queued through a vault
		-- and flushed on landing is exactly the free hit the gate exists to remove.
		-- Gated the same way this layer's server half gates its own per-press lines: a mashed button
		-- during a long wall-run is many presses a second, and anything logged per press is its own
		-- performance problem (see AttackConstants.Debug.Enabled's header).
		if AttackConstants.Debug.Enabled and AttackConstants.Debug.LogRefused then
			logger:debug("Attack press dropped -- a parkour action owns the body")
		end
		return nil
	end
	local remote = requestRemote
	if not remote then
		-- Only reachable in the window between a keypress and Start() resolving the remote, which the
		-- boot sequence makes vanishingly small. Warned rather than silently dropped so a genuine
		-- ordering regression in Main.client.lua is visible rather than felt as "attacks sometimes
		-- don't work at boot."
		logger:warn("Attack pressed before the request remote was ready")
		return nil
	end
	nextPressId += 1
	request.PressId = nextPressId
	remote:FireServer(request)
	return nextPressId
end

-- The immediate, local "that registered" cue. Cosmetic in the strictest sense: a camera FOV nudge,
-- composed through the shared FOVOffset compositor so it sums with (rather than fights) the run
-- system's own zoom.
--
-- SKIPPED FOR BASIC (M1): the narrow-then-wider punch read as an unwanted "zoom out" on every M1
-- press, and M1 is throw-based and rapid (a string, mashed) where Heavy is a single deliberate,
-- telegraphed swing -- a press cue earns its keep on the one press a player throws occasionally, not
-- on the one they throw three times a second. Heavy keeps it.
local function playPressCue(kind: AttackTypes.AttackKind): ()
	if kind == "Basic" then
		return
	end
	local now = os.clock()
	if now - lastPunchAt < PUNCH.MinIntervalSeconds then
		return
	end
	lastPunchAt = now
	FOVOffset.Punch(FOV_SLOT, PUNCH.FOVDelta, PUNCH.OutSeconds, PUNCH.BackSeconds)
end

local function slotCooldownRemaining(slot: number, now: number): number
	local readyAt = slotReadyAt[slot]
	if not readyAt then
		return 0
	end
	return math.max(readyAt - now, 0)
end

-- Whether this press should skip the local swing prediction: an air-combo press (the attacker's Basic is an
-- air beat, not the ground string the prediction mirrors) or a press with the launcher modifier held (the
-- server may resolve it to the Launcher). Predicting either would play the wrong clip until the real one
-- arrived. The server's Attack_Started still plays the right one a round trip later.
local function skipsPrediction(modifierUp: boolean): boolean
	local humanoid = boundHumanoid
	return modifierUp or (humanoid ~= nil and AirComboAttributes.IsAttacker(humanoid))
end

local function requestWeaponAttack(kind: AttackTypes.AttackKind): ()
	-- ALWAYS SENT, never pre-filtered. The server is the authority on whether this press throws, and
	-- it forgives an early press by buffering it, which a local drop would throw away. The local swing
	-- prediction below is presentation layered on top, never a reason not to send.
	--
	-- THE AIR COMBO'S MODIFIER: the jump key held at the press (docs/design/air-combat-and-evade.md B2) --
	-- Space + M1 mid-string is the launcher branch, Space + Heavy in the air is the Spike. Sent as a request,
	-- never trusted: the server decides whether the string has earned what it asks for.
	local modifierUp = KeybindManager.IsJumpKeyDown()
	notePressForJump(kind, os.clock())
	playPressCue(kind)
	local pressId = sendRequest({ Kind = kind, Modifier = if modifierUp then "Up" else nil })
	if not skipsPrediction(modifierUp) then
		predictPress(kind, pressId)
	end
end

local function requestHotbar(slot: number): ()
	local moveId = HotbarBindings.Get(slot)
	if not moveId then
		-- Nothing bound. The HUD already renders this slot as Locked, so there is nothing to tell the
		-- player and nothing worth a remote call.
		return
	end
	if slotCooldownRemaining(slot, os.clock()) > 0 then
		-- The one place a local drop is honest: this cooldown is the server's own number, echoed back.
		return
	end
	playPressCue("Hotbar")
	sendRequest({ Kind = "Hotbar", Slot = slot, MoveId = moveId })
end

-- Input ---------------------------------------------------------------------------------------------

-- Every attack-layer action goes through Client/Input/InputRouter.lua on its "Gameplay" layer, which
-- is what drops a click that landed on the GUI (gameProcessed -- a HUD ability slot fires its own
-- OnActivated, which routes here through AttackInputClient.PressHotbarSlot) and every press while a
-- modal panel is open (AttributeConstants.UiModalOpen). This module used to hand-roll both checks
-- on its own raw InputBegan connection.
--
-- THE ROUTER IS ALSO THE ONLY THING THAT RESOLVES THE GAMEPAD CHORD LAYER, which is why the move was
-- not optional once Feint existed: L2+R1 is Feint, and a raw connection matching BasicAttack on R1
-- fired a Basic request alongside every chorded feint -- which the server then buffered and threw the
-- moment the feint's own recovery ended. The same raw connection never fired the chord-only
-- HotbarSlot1-5 on a pad at all.
local function bindInputs(): ()
	local function onBegan(action: Types.KeybindAction, handler: () -> ()): ()
		InputRouter.Bind(action, {
			Layer = "Gameplay",
			Began = function()
				handler()
			end,
		})
	end

	onBegan("BasicAttack", function()
		requestWeaponAttack("Basic")
	end)
	onBegan("HeavyAttack", function()
		requestWeaponAttack("Heavy")
	end)
	onBegan("Feint", function()
		AttackInputClient.PressFeint()
	end)
	onBegan("ToggleWeapon", function()
		local remote = toggleDrawRemote
		if remote then
			-- No payload: the server owns which weapon is selected and whether it is currently out, so
			-- there is nothing here for the client to name and nothing for the server to validate.
			remote:FireServer()
		end
	end)
	onBegan("SelectNextWeapon", function()
		local remote = selectNextRemote
		if remote then
			remote:FireServer()
		end
	end)
	for slot, action in HOTBAR_ACTIONS do
		onBegan(action, function()
			requestHotbar(slot)
		end)
	end
end

-- Presentation ---------------------------------------------------------------------------------------

-- The speed a payload asks its clip to play at, or 1 for a malformed one -- a bad value must not freeze
-- or reverse the clip.
local function speedOf(payload: AttackStartedPayload): number
	local speed = payload.PlaybackSpeed
	if typeof(speed) ~= "number" or speed ~= speed or speed <= 0 then
		return 1
	end
	return speed
end

local function swingSecondsOf(payload: AttackStartedPayload): number
	return payload.WindupSeconds + payload.ActiveSeconds + payload.RecoverySeconds
end

local function playSwing(payload: AttackStartedPayload): ()
	local animationId = payload.AnimationId
	if typeof(animationId) ~= "string" or animationId == "" then
		-- Every Default move today -- see this file's header. A blank id is an authoring gap, not an
		-- error, and AnimationManager would refuse the claim anyway; returning here keeps the layer
		-- free rather than leaving a refused claim parked on it.
		return
	end

	-- The ceiling for a one-shot whose own Length has not resolved yet. Derived from what the server
	-- actually scheduled rather than a fixed guess, plus the recovery tail, so a long move is never
	-- cut short and a short one is never left holding the layer.
	local scheduled = swingSecondsOf(payload)

	-- The speed the server built that schedule against (AttackCatalog.Get divides the clip's length by
	-- it). Played at anything else, the clip's strike lands somewhere the hitbox is not -- which is the
	-- whole desync AttackConstants.Windows.SyncToClipLength exists to remove.
	local speed = speedOf(payload)

	manager:SetClaim(ATTACK_LAYER, SWING_SOURCE, {
		Clip = animationId,
		Looped = false,
		Speed = speed,
		Priority = Enum.AnimationPriority.Action,
		FadeIn = AttackConstants.Presentation.SwingFadeSeconds,
		FadeOut = AttackConstants.Presentation.SwingFadeSeconds,
		MaxSeconds = scheduled,
		-- Tells Client/FX/CombatAnimator.lua's armed-idle loop to stand down for every way this claim
		-- can stop owning the layer (landed, got superseded by the next swing, got cancelled by
		-- CancelSwing below, expired, or failed to load) -- see CombatAnimator.
		-- SetActionAnimationActive's own header for why a Core-priority idle loop would otherwise mask
		-- an Action-priority swing rather than the other way around.
		OnFinished = function(_clip: string, _reason: AnimationManager.FinishReason)
			CombatAnimator.SetActionAnimationActive(ACTION_SOURCE, false)
		end,
	})
	-- Queried rather than assumed true: a claim whose track failed to load retires SYNCHRONOUSLY inside
	-- SetClaim above (calling OnFinished with "Failed" before this line ever runs), so asking
	-- AnimationManager what is actually active is what keeps this correct in that case too, instead of
	-- unconditionally re-asserting true over a claim that never actually started.
	CombatAnimator.SetActionAnimationActive(ACTION_SOURCE, manager:GetActiveClip(ATTACK_LAYER) ~= nil)
end

-- Cuts the LOCAL player's own in-flight swing animation short, the instant this client learns the
-- server just cut it. CombatFeedbackClient.lua is the only caller: as the Defender of one of the three
-- outcomes DamageResolver.Resolve grants DamageConstants.Hitstun for (Clean, Backstab, GuardBroken), and
-- as the Attacker of a Parried or Traded swing (DefenseSystem cancels the attacker's swing for both).
-- Also drops any pending or buffered prediction -- a body the server just interrupted is not about to
-- throw what this client guessed it would.
--
-- WHY THIS HAS TO EXIST AT ALL. DamageSystem.applyOutcome cancels the victim's swing SERVER-SIDE the
-- moment a qualifying hit resolves (cancelSwingOf -> HitboxEngine.CancelAttack), which stops the
-- hitbox and the attack state machine immediately -- but that cancellation has no remote of its own
-- and reaches no client. Attack_Started is the only message this layer ever sends about a swing, and
-- it is sent once, at the moment the swing began; nothing tells the swing's OWN client that the
-- server just cut it short. Left alone, a swing thrown a moment before taking a hit keeps playing on
-- this client all the way to its own MaxSeconds (playSwing's own ceiling) regardless of the character
-- now sitting in hitstun -- an M1 that visibly keeps swinging through a lockout that has already
-- started, which is exactly the "should be blocked by hitstun" gap this closes. The attack GATE itself
-- was always correct (DamageSystem.CanAttack already refuses a NEW throw for the same window); this is
-- the missing other half, cutting the swing that was already in flight when the window opened.
--
-- A plain SetClaim(nil): retiring a claim nothing currently holds is Clear's own documented no-op (see
-- AnimationManager.Clear), so calling this on every qualifying hit costs nothing when the victim was
-- not mid-swing at all -- there is no need to check GetActiveClip first.
-- PressId is the press the prediction answers, so a "Refused" verdict for it cuts exactly this one.
local pendingPrediction: { MoveId: string, Generation: number, PressId: number? }? = nil
local bufferedPress: { Kind: AttackTypes.AttackKind, Generation: number, PressId: number? }? = nil

-- Why a swing this client was playing stopped early. "Feint" is the server's Attack_Cancelled;
-- "Interrupted" is every other server-side cut this client infers (hitstun, parried, traded -- see
-- CancelSwing's own header); "Unconfirmed" is a prediction the server never confirmed.
export type SwingCancelReason = "Feint" | "Interrupted" | "Unconfirmed"

local swingCancelledListeners: CallbackList.CallbackList<SwingCancelReason> =
	CallbackList.New(logger, "AttackInputClient.OnSwingCancelled")

-- The MoveId of the swing most recently started on the attack layer, or nil once it is cut. What an
-- Attack_Cancelled is matched against, so a cancel that raced a newer swing does not cut the newer
-- one. NOT cleared when a swing ends on its own -- "is a swing playing" is always asked of
-- LocalCombatState's deadline, never of this.
local playingMoveId: string? = nil
-- The payload and start time of that same swing, for the hit-confirm cut point (NoteHitConfirmed).
local playingPayload: AttackStartedPayload? = nil
local playingStartedAt = 0

-- Tells every OnSwingCancelled listener, pcall'd per listener (CallbackList): this runs from remote
-- handlers and task.delay callbacks, and one FX module erroring must not stop the lunge being cancelled.
local function notifySwingCancelled(reason: SwingCancelReason): ()
	swingCancelledListeners:Fire(reason)
end

local function cutSwing(reason: SwingCancelReason): ()
	local wasPlaying = LocalCombatState.SwingEndsAt() > os.clock()
	pendingPrediction = nil
	playingMoveId = nil
	playingPayload = nil
	manager:SetClaim(ATTACK_LAYER, SWING_SOURCE, nil)
	LocalCombatState.ClearSwing()
	if wasPlaying then
		notifySwingCancelled(reason)
	end
end

function AttackInputClient.CancelSwing(): ()
	bufferedPress = nil
	cutSwing("Interrupted")
end

-- Records the cooldown the server just imposed, and tells whoever is drawing it. Fires once on start
-- and once on expiry rather than every frame -- a consumer that wants a smooth sweep animates
-- between the two edges itself, which is cheaper than pushing a value 60 times a second to a HUD that
-- is already re-rendering.
local function noteSlotCooldown(slot: number, seconds: number): ()
	if seconds <= 0 then
		return
	end
	local readyAt = os.clock() + seconds
	slotReadyAt[slot] = readyAt
	slotListeners:Fire(slot, seconds)

	task.delay(seconds, function()
		-- Guarded against a newer press: a second use of the same slot inside the first cooldown
		-- pushes readyAt out, and the first timer firing afterwards must not report the slot ready
		-- while the newer cooldown is still running.
		if slotReadyAt[slot] ~= readyAt then
			return
		end
		slotReadyAt[slot] = nil
		slotListeners:Fire(slot, 0)
	end)
end

-- Pcall'd per listener (CallbackList), so one FX listener erroring (trail, lunge, swing audio) cannot stop
-- the others -- or the rest of startSwing -- for a swing that is already on screen.
local attackStartedListeners: CallbackList.CallbackList<AttackStartedPayload> =
	CallbackList.New(logger, "AttackInputClient.OnAttackStarted")

-- Starts a swing locally -- the clip, the body's local commitment, and every OnAttackStarted listener
-- (trail, lunge, swing audio) -- from a payload that is either the server's confirmation or the cached
-- copy a prediction replays. One path for both, so a predicted swing looks exactly like a confirmed one.
local function startSwing(payload: AttackStartedPayload, now: number): ()
	playingMoveId = payload.MoveId
	playingPayload = payload
	playingStartedAt = now
	playSwing(payload)
	LocalCombatState.SetSwing(now + swingSecondsOf(payload))
	if AttackConstants.GuardCut.Enabled and AirComboMoves.RoleOf(payload.MoveId) == nil then
		LocalCombatState.SetGuardCutAt(
			AttackConstants.GuardCutAt(now, payload.WindupSeconds, payload.ActiveSeconds, payload.RecoverySeconds)
		)
	end
	attackStartedListeners:Fire(payload)
end

-- Prediction -----------------------------------------------------------------------------------------
--
-- See this file's header, THE SWING ANIMATION IS PREDICTED. Everything here mirrors server state from
-- messages this client already receives; nothing here is sent anywhere.

local PREDICTION = AttackConstants.Presentation.SwingPrediction

-- The server's own last Attack_Started for each MoveId -- what a prediction replays.
local confirmedByMoveId: { [string]: AttackStartedPayload } = {}

-- SwingSequencer's string for this player, mirrored from the last CONFIRMED throw.
local stringKind: AttackTypes.AttackKind? = nil
local stringStage = 0
local stringLapsesAt = -math.huge

local predictionGeneration = 0
local bufferGeneration = 0

-- When the server's feint recovery, or a trade's shared recovery, ends (AttackCancelledPayload.
-- RecoverySeconds), mirrored so a press inside it is buffered-and-predicted rather than predicted into a
-- refusal.
local cancelRecoveredAt = -math.huge

-- How many stages each string of the weapon in hand has, from its prediction seed: the server's own probe
-- (SwingSequencer.StageMoveIds), so a weapon whose string differs from the Baseline is mirrored exactly.
-- Replaced by every Attack_WeaponChanged that carries Moves (an empty hand's empty seed included); only a
-- message without Moves -- an older server -- leaves it nil, and the Baseline length stands in.
local seededStageCounts: { [string]: number }? = nil

local function stageCount(kind: AttackTypes.AttackKind): number
	local seeded = seededStageCounts
	if seeded then
		return seeded[kind] or 0
	end
	local stages = (CombatConstants.Weapons.Baseline.Stages :: any)[kind]
	return if typeof(stages) == "table" then #stages else 0
end

-- SwingSequencer.Resolve, restated against the mirror. Same rules in the same order: a live string of
-- the same kind continues, and running past the end wraps. (A press that may be the launcher -- the one
-- 4th hit, Space + M1 -- is never predicted: see skipsPrediction.)
local function predictMoveId(kind: AttackTypes.AttackKind, now: number): string?
	local weapon = currentWeapon
	if not weapon then
		return nil
	end
	local count = stageCount(kind)
	if count <= 0 then
		return nil
	end
	local live = stringKind ~= nil
		and now <= stringLapsesAt
		and (stringKind == kind or not AttackConstants.Sequence.ResetOnCategorySwitch)
	local nextStage = (if live then stringStage else 0) + 1
	if nextStage > count then
		nextStage = 1
	end
	return `default:{weapon}:{kind}:{nextStage}`
end

-- When this body can next start a swing by this client's own measure: its swing and the chain beat
-- after it over, and any hitstun spent. The server gates the same two things (HitboxEngine "Busy",
-- SwingSequencer "ChainDelay", DamageSystem "Hitstun").
--
-- `kind` is the press being judged. A kind that may take a landed swing's cut (AttackConstants.HitConfirm.
-- CancelInto) is free at the cut point, with no chain beat after it, exactly as the server's
-- confirmCancelReady treats it.
local function nextSwingAt(now: number, kind: AttackTypes.AttackKind?): number
	local tuning = AttackConstants.HitConfirm
	local cancelable = kind ~= nil and tuning.Enabled and tuning.CancelInto[kind] == true
	local swingEnd = LocalCombatState.SwingEndsAt()
	local cancelAt = LocalCombatState.CancelAt()
	local swingGate = if cancelable
			and cancelAt > 0
			and cancelAt < swingEnd
		then cancelAt
		else swingEnd + AttackConstants.Sequence.ChainDelaySeconds
	return math.max(LocalCombatState.FreeAt(now, cancelable), swingGate, cancelRecoveredAt)
end

-- Every other server gate this client can see the answer to: the guard (DefenseSystem "Guarding"), the
-- published defence state (Staggered/GuardBroken), a grab, a mount, a traversal, death.
local function bodyAllowsSwing(): boolean
	local humanoid = boundHumanoid
	if humanoid == nil or humanoid.Health <= 0 then
		return false
	end
	if parkourOwnsBody() or LocalCombatState.IsGuardHeld() then
		return false
	end
	local defenceState = humanoid:GetAttribute(DefenseConstants.DefenseStateAttribute)
	if defenceState ~= nil and defenceState ~= "Neutral" then
		return false
	end
	return humanoid:GetAttribute(AttributeConstants.Mounted) ~= true
		and humanoid:GetAttribute(AttributeConstants.Grabbed) ~= true
		and humanoid:GetAttribute(AttributeConstants.Grabbing) ~= true
end

local function cutUnconfirmedSwing(): ()
	cutSwing("Unconfirmed")
end

-- Plays the predicted move now, if every local gate agrees and the move has a confirmed copy to replay.
-- Returns whether it did.
local function predictSwing(kind: AttackTypes.AttackKind, pressId: number?): boolean
	if not PREDICTION.Enabled or pendingPrediction ~= nil then
		return false
	end
	local now = os.clock()
	if nextSwingAt(now, kind) > now or not bodyAllowsSwing() then
		return false
	end
	local moveId = predictMoveId(kind, now)
	local cached = if moveId then confirmedByMoveId[moveId] else nil
	if not cached then
		return false
	end

	predictionGeneration += 1
	local generation = predictionGeneration
	pendingPrediction = { MoveId = cached.MoveId, Generation = generation, PressId = pressId }
	startSwing(cached, now)

	-- Two pings covers the round trip; BufferSeconds covers a press the server held before throwing.
	local timeout = 2 * Players.LocalPlayer:GetNetworkPing()
		+ AttackConstants.Input.BufferSeconds
		+ PREDICTION.ConfirmGraceSeconds
	task.delay(timeout, function()
		local current = pendingPrediction
		if current and current.Generation == generation then
			if AttackConstants.Debug.Enabled and AttackConstants.Debug.LogRefused then
				logger:debug("Predicted swing never confirmed -- cut", { moveId = current.MoveId })
			end
			cutUnconfirmedSwing()
		end
	end)
	return true
end

predictPress = function(kind: AttackTypes.AttackKind, pressId: number?): ()
	if not PREDICTION.Enabled then
		return
	end
	if predictSwing(kind, pressId) then
		bufferedPress = nil
		return
	end

	-- Not free yet. The server buffers a press refused for being mid-swing, in the chain beat or in
	-- hitstun, keeps only the newest, and throws it the moment the body frees -- if that is within
	-- AttackConstants.Input.BufferSeconds. Mirrored exactly, so a mashed string is predicted swing after
	-- swing instead of only its first press.
	local now = os.clock()
	local freeAt = nextSwingAt(now, kind)
	if freeAt <= now or freeAt - now > AttackConstants.Input.BufferSeconds then
		return
	end
	bufferGeneration += 1
	local generation = bufferGeneration
	bufferedPress = { Kind = kind, Generation = generation, PressId = pressId }
	task.delay(freeAt - now, function()
		local current = bufferedPress
		if current and current.Generation == generation then
			bufferedPress = nil
			predictSwing(current.Kind, current.PressId)
		end
	end)
end

-- SPACE DOES NOT JUMP WHILE THE LAUNCHER IS EARNABLE (docs/design/air-combat-and-evade.md B2, approved): once
-- this player's Basic string is live at the launcher's stage, Space is the launcher MODIFIER, and a press of
-- it must not also hop the body off the ground. The same precedent the old finisher jump-suppression set.
-- Outside that window Space jumps exactly as always.
--
-- Done by standing the Humanoid's own Jumping state down until the string lapses: that one switch covers the
-- engine's default jump and every parkour path that goes through Humanoid:ChangeState, with no second
-- input interception to keep in step with the first.
local jumpSuppressGeneration = 0

-- THE CLICK, NOT THE CONFIRMATION, STARTS IT. The 3rd M1 is usually clicked while B2 is still swinging, and
-- the server holds that press in its buffer until B2 is over -- so B3's Attack_Started can arrive well after
-- the click. Suppressing only from that confirmation left Space jumping in exactly the window a player
-- reaches for it ("I can still jump at the 3rd M1"). So this client counts its own Basic presses into the
-- string, reconciled with the server's mirror whenever that is ahead, and suppresses from the press that
-- will be B3. The server's confirmation then extends the window to the string's real lapse.
local localBasicPresses = 0
local localStringLapsesAt = -math.huge

local function setJumpSuppressed(suppressed: boolean): ()
	local humanoid = boundHumanoid
	if humanoid and humanoid.Parent ~= nil then
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, not suppressed)
	end
end

local function suppressJumpUntil(deadline: number, now: number): ()
	jumpSuppressGeneration += 1
	local generation = jumpSuppressGeneration
	setJumpSuppressed(true)
	task.delay(math.max(deadline - now, 0), function()
		if jumpSuppressGeneration == generation then
			setJumpSuppressed(false)
		end
	end)
end

local function releaseJumpSuppression(): ()
	jumpSuppressGeneration += 1
	localBasicPresses = 0
	localStringLapsesAt = -math.huge
	setJumpSuppressed(false)
end

notePressForJump = function(kind: AttackTypes.AttackKind, now: number): ()
	if not AirComboConstants.Enabled then
		return
	end
	if kind ~= "Basic" then
		releaseJumpSuppression()
		return
	end
	if now > localStringLapsesAt then
		localBasicPresses = 0
	end
	-- The server's mirror is authoritative where it knows more (a press this client counted may have been
	-- refused); the local count only ever runs ahead of it, never behind. And a string the mirror shows
	-- COMPLETE is over: the press after B3 is a fresh string's B1 (or the launcher), so the count restarts
	-- rather than running on to a "4th" and suppressing Space through the next string.
	if stringKind == "Basic" and now <= stringLapsesAt then
		if stringStage >= stageCount("Basic") then
			localBasicPresses = 0
		else
			localBasicPresses = math.max(localBasicPresses, stringStage)
		end
	end
	localBasicPresses += 1
	-- Long enough to cover the press waiting in the server's buffer, the swing itself, and the string's
	-- reset window after it; B3's confirmation replaces it with the exact lapse.
	localStringLapsesAt = now
		+ AttackConstants.Input.BufferSeconds
		+ AirComboConstants.Launcher.JumpSuppressSwingAllowanceSeconds
		+ AttackConstants.Sequence.ResetSeconds
	if localBasicPresses >= AirComboConstants.Launcher.MinStringStage then
		suppressJumpUntil(localStringLapsesAt, now)
	end
end

-- Whether a value off the wire has the fields a swing is started from. One check for a confirmation and for
-- a seeded template, so a malformed one of either is never cached and replayed.
local function isStartedPayload(raw: unknown): boolean
	if typeof(raw) ~= "table" then
		return false
	end
	local payload = raw :: AttackStartedPayload
	return typeof(payload.MoveId) == "string"
		and typeof(payload.WindupSeconds) == "number"
		and typeof(payload.ActiveSeconds) == "number"
		and typeof(payload.RecoverySeconds) == "number"
end

local function onAttackStarted(raw: unknown): ()
	if not isStartedPayload(raw) then
		return
	end
	local payload = raw :: AttackStartedPayload

	local now = os.clock()
	confirmedByMoveId[payload.MoveId] = payload
	if payload.Kind ~= "Hotbar" then
		stringKind = payload.Kind
		stringStage = payload.StageIndex
		stringLapsesAt = now + swingSecondsOf(payload) + AttackConstants.Sequence.ResetSeconds
		local minStage = AirComboConstants.Launcher.MinStringStage
		-- An EARLIER stage's confirmation (B2's, arriving after the B3 click) must not cancel the suppression
		-- that click started -- which is still true only while the local count is at B3 or past it.
		local clickedAhead = payload.Kind == "Basic"
			and payload.StageIndex > 0
			and localBasicPresses >= minStage
			and now <= localStringLapsesAt
		if AirComboConstants.Enabled and payload.Kind == "Basic" and payload.StageIndex >= minStage then
			suppressJumpUntil(math.max(stringLapsesAt, localStringLapsesAt), now)
		elseif AirComboConstants.Enabled and AirComboMoves.IsLauncher(payload.MoveId) then
			-- THE LAUNCHER ITSELF: Space is still held from the Space + M1 that threw it, so Space must not
			-- jump through its windup either. Held for the swing; a launch that lands hands the body to the
			-- follow (platform-standing, where a jump means nothing), and a whiff gives Space back at its end.
			suppressJumpUntil(now + swingSecondsOf(payload), now)
		elseif not clickedAhead then
			-- A Heavy, a fresh string's B1, or an air move: Space is Space again.
			releaseJumpSuppression()
		end
	elseif stringKind ~= nil and now <= stringLapsesAt then
		-- AN ART WOVEN INTO A LIVE STRING holds its place (SwingSequencer.Weave): the server keeps the string
		-- alive until the art ends plus the ordinary grace, so the mirror does too. Otherwise the next M1
		-- is predicted as a fresh B1 and corrected a round trip later. If Space is currently the launcher
		-- modifier, it stays one through the art.
		stringLapsesAt = math.max(stringLapsesAt, now + swingSecondsOf(payload) + AttackConstants.Sequence.ResetSeconds)
		if
			AirComboConstants.Enabled
			and stringKind == "Basic"
			and stringStage >= AirComboConstants.Launcher.MinStringStage
		then
			localStringLapsesAt = math.max(localStringLapsesAt, stringLapsesAt)
			suppressJumpUntil(localStringLapsesAt, now)
		end
	end

	local prediction = pendingPrediction
	pendingPrediction = nil
	if prediction and prediction.MoveId == payload.MoveId then
		-- CONFIRMED: already playing, listeners already told. Only a speed the server changed since the
		-- cached copy (a clip read for the first time mid-session) is worth applying.
		if manager:GetActiveClip(ATTACK_LAYER) ~= nil then
			manager:SetSpeed(ATTACK_LAYER, speedOf(payload))
		end
	else
		-- Unpredicted, or predicted wrong (the server resolved a different stage): play what the server
		-- actually threw. The claim supersedes a wrong prediction's clip on the same layer.
		startSwing(payload, now)
	end

	if payload.Kind == "Hotbar" and typeof(payload.Slot) == "number" then
		noteSlotCooldown(payload.Slot :: number, payload.CooldownSeconds)
	end
end

-- The server cut one of this player's swings short (Attack_Cancelled). Stops the clip -- the stop
-- reaches every other client through this rig's Animator, which replicates -- and mirrors what the
-- server just did to the string: back to stage 1, with the next swing held for the recovery.
local function onAttackCancelled(raw: unknown): ()
	if typeof(raw) ~= "table" then
		return
	end
	local payload = raw :: AttackTypes.AttackCancelledPayload
	if typeof(payload.MoveId) ~= "string" then
		return
	end
	local recovery = if typeof(payload.RecoverySeconds) == "number" then payload.RecoverySeconds else 0
	local now = os.clock()

	-- THE PRESS VERDICT: this press will not throw. Cut its prediction now (or forget it, if it was still
	-- waiting on the local buffer) rather than leaving the swing on screen until the timeout. Only the press it
	-- names: a newer press's prediction is not this verdict's business.
	if payload.Reason == "Refused" then
		local pressId = payload.PressId
		if typeof(pressId) ~= "number" then
			return
		end
		local waiting = bufferedPress
		if waiting and waiting.PressId == pressId then
			bufferedPress = nil
		end
		local prediction = pendingPrediction
		if prediction and prediction.PressId == pressId and payload.RefusedReason == "Superseded" then
			-- Replaced in the server's buffer by a newer press, which is the one that will throw -- the swing on
			-- screen is now that press's prediction, not a refused one. (The server only supersedes with the
			-- newest press it has, which is the newest this client sent.)
			prediction.PressId = nextPressId
			return
		end
		if prediction and prediction.PressId == pressId then
			if AttackConstants.Debug.Enabled and AttackConstants.Debug.LogRefused then
				logger:debug("Predicted swing refused -- cut", {
					moveId = prediction.MoveId,
					reason = payload.RefusedReason,
				})
			end
			cutUnconfirmedSwing()
		end
		return
	end

	-- PARRIED / TRADED: the server kept this player's chain (AttackRequestSystem.KeepChainThroughParry /
	-- KeepChainThroughTrade) and held it through the stagger or the trade's recovery. Only the mirror moves.
	-- The clip was already cut by Combat_Feedback (CancelSwing). A stagger gates prediction through the
	-- published defence state; a trade has none, so its shared recovery gates it here instead.
	if payload.Reason == "Parried" or payload.Reason == "Traded" then
		if payload.Reason == "Traded" then
			cancelRecoveredAt = now + math.clamp(recovery, 0, 2)
		end
		local kind = payload.StringKind
		local stage = payload.StringStage
		if (kind == "Basic" or kind == "Heavy") and typeof(stage) == "number" and stage > 0 then
			stringKind = kind
			stringStage = stage
			stringLapsesAt = now + math.clamp(recovery, 0, 3) + AttackConstants.Sequence.ResetSeconds
		else
			stringKind = nil
			stringStage = 0
		end
		releaseJumpSuppression()
		-- Space stays the launcher modifier while the kept string is at the launcher's stage.
		if
			AirComboConstants.Enabled
			and stringKind == "Basic"
			and stringStage >= AirComboConstants.Launcher.MinStringStage
		then
			localBasicPresses = stringStage
			localStringLapsesAt = stringLapsesAt
			suppressJumpUntil(stringLapsesAt, now)
		end
		return
	end

	if payload.Reason ~= "Feint" then
		return
	end
	cancelRecoveredAt = now + math.clamp(recovery, 0, 2)
	stringKind = nil
	stringStage = 0
	releaseJumpSuppression()
	-- Only the swing it is about. A cancel that crossed a newer swing on the wire is stale for the clip,
	-- but its string reset and recovery above are still the server's truth.
	if playingMoveId == payload.MoveId and LocalCombatState.SwingEndsAt() > now then
		bufferedPress = nil
		cutSwing("Feint")
	end
end

local function onWeaponChanged(raw: unknown): ()
	if typeof(raw) ~= "table" then
		return
	end
	local payload = raw :: AttackTypes.WeaponChangedPayload
	-- Any non-empty string is accepted: weapon ids are roster model names now, so there is no closed
	-- set to check against here. Deliberately NOT re-validated client-side -- the server picked this
	-- id out of its own roster and is the only authority on it, and this value is used for
	-- presentation only. Anything else is an empty hand: nothing is predicted until a weapon is drawn.
	local weaponId = payload.WeaponId
	currentWeapon = if typeof(weaponId) == "string" and weaponId ~= "" then weaponId else nil
	-- THE PREDICTION SEED: a server copy of every stage of the weapon now in hand, so its very first press
	-- is predicted too (AttackTypes.WeaponChangedPayload.Moves). Later confirmations overwrite these.
	local moves = payload.Moves
	if typeof(moves) == "table" then
		local counts: { [string]: number } = {}
		for _, move in moves do
			if isStartedPayload(move) then
				confirmedByMoveId[move.MoveId] = move
				if typeof(move.StageIndex) == "number" then
					counts[move.Kind] = math.max(counts[move.Kind] or 0, move.StageIndex)
				end
			end
		end
		seededStageCounts = counts
	else
		seededStageCounts = nil
	end
	-- Every message is a server-side string reset, so the mirror always follows. ALWAYS, not only when the id
	-- differs: the swap key resets the string even onto the same weapon (SwingSequencer.SwapWeapon with a
	-- one-weapon roster), while a re-select that changes nothing is never sent (AttackRequestSystem.SetWeapon).
	stringKind = nil
	stringStage = 0
	releaseJumpSuppression()
	logger:debug("Weapon changed", { weaponId = currentWeapon })
end

-- Lifecycle ------------------------------------------------------------------------------------------

local function bindCharacter(character: Model, humanoid: Humanoid): ()
	-- A new life inherits no cooldowns: the server drops them on the same event (
	-- AttackRequestSystem's own unbindCharacter), so leaving them here would show a HUD sweep for a
	-- restriction that no longer exists.
	table.clear(slotReadyAt)
	for slot = 1, SLOT_COUNT do
		slotListeners:Fire(slot, 0)
	end

	-- Already waited out by Shared/PlayerLifecycle.lua, which is also what guarantees this is only
	-- ever called for a life whose Humanoid actually arrived -- manager:Bind below fails PERMANENTLY
	-- for a life bound without one (AnimationManager.Bind logs one warning and stays "Unbound" until
	-- the next CharacterAdded; nothing here ever retries), so "no Humanoid, no bind" is a correctness
	-- requirement of this module and not a defensive nicety.
	boundHumanoid = humanoid
	pendingPrediction = nil
	bufferedPress = nil
	playingMoveId = nil
	cancelRecoveredAt = -math.huge
	stringKind = nil
	stringStage = 0
	-- A fresh Humanoid jumps; a suppression scheduled against the last life must not reach this one.
	jumpSuppressGeneration += 1
	LocalCombatState.ResetForNewLife()

	-- Bind() runs Unbind() first thing internally, so the previous life's claims and tracks are
	-- dropped without this needing to clear ATTACK_LAYER separately.
	manager:Bind(character)
end

local function unbind(): ()
	-- Dropped with the body it describes. A stale Humanoid here would have the gate above reading a
	-- dead character's last Attribute value, which for a life that ended mid-vault reads true forever.
	boundHumanoid = nil
	pendingPrediction = nil
	bufferedPress = nil
	LocalCombatState.ResetForNewLife()
	manager:Unbind()
end

function AttackInputClient.Start(): ()
	if started then
		return
	end
	started = true

	requestRemote = NetworkBridge.GetRemoteEvent(AttackConstants.Network.RemoteNames.Request)
	feintRemote = NetworkBridge.GetRemoteEvent(AttackConstants.Network.RemoteNames.Feint)
	-- HIDES ROBLOX'S OWN BACKPACK HOTBAR. Weapons in this game are held through a Tool (see
	-- Server/Combat/Weapon/WeaponVisualSystem.lua on why a real Tool rather than a hand-rolled
	-- Motor6D), and the engine draws every Tool a character owns as a numbered slot along the bottom
	-- of the screen. That hotbar is Roblox's inventory UI, not this game's: drawing/sheathing is T,
	-- selection is Y, and both are server-owned -- so the built-in strip both duplicates state this
	-- game already presents and offers a second, unsynchronised way to un-equip.
	--
	-- pcall'd because SetCoreGuiEnabled throws if the CoreGui is not ready yet on a very early boot,
	-- and a cosmetic strip failing to hide must not take the whole attack input layer down with it.
	--
	-- AND ROBLOX'S OWN HEALTH DISPLAY, for the same "the game already presents this" reason plus a
	-- performance one. The HUD's vital pills draw health; the built-in CoreGui drew a second health bar
	-- in the corner AND, whenever health was down, a full-screen red damage overlay -- a translucent
	-- layer over every pixel for as long as the player was hurt, which in a fight is most of it. That
	-- overlay is pure GPU fill cost the game never asked for, and it read as the game's own hit effect.
	local ok, err = pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
	end)
	if not ok then
		logger:warn("Could not hide the Backpack/Health CoreGui", { errorMessage = tostring(err) })
	end

	toggleDrawRemote = NetworkBridge.GetRemoteEvent(WeaponConstants.Network.RemoteNames.ToggleDraw)
	selectNextRemote = NetworkBridge.GetRemoteEvent(WeaponConstants.Network.RemoteNames.SelectNext)

	local startedRemote = NetworkBridge.GetRemoteEvent(AttackConstants.Network.RemoteNames.Started)
	startedRemote.OnClientEvent:Connect(onAttackStarted)

	local weaponChanged = NetworkBridge.GetRemoteEvent(AttackConstants.Network.RemoteNames.WeaponChanged)
	weaponChanged.OnClientEvent:Connect(onWeaponChanged)

	local cancelledRemote = NetworkBridge.GetRemoteEvent(AttackConstants.Network.RemoteNames.Cancelled)
	cancelledRemote.OnClientEvent:Connect(onAttackCancelled)

	-- The parkour framework asks for the swing to stop when an evade takes a landed swing's cut
	-- (LocalCombatState.RequestSwingCut -- a leaf signal, because Client/Parkour may not require this).
	LocalCombatState.OnSwingCutRequested(function()
		bufferedPress = nil
		cutSwing("Interrupted")
	end)

	bindInputs()

	-- See Shared/PlayerLifecycle.lua. This module's own copy of the wait/spawn/re-check comment was one
	-- of fifteen; the behaviour it described is now the shared binder's, so there is one place left to
	-- get it right.
	PlayerLifecycle.BindLocalCharacter({
		Scope = "AttackInputClient",
		OnCharacter = bindCharacter,
		OnCharacterRemoving = unbind,
	})

	logger:info("AttackInputClient started")
end

-- Public ---------------------------------------------------------------------------------------------

-- The local player's swing `moveId` LANDED (Combat_Feedback, attacker role, a HitConfirm.ConfirmKinds
-- outcome -- CombatFeedbackClient is the caller). Marks its recovery as cancelable from the same cut point
-- the server computes (AttackConstants.HitConfirmCancelAt), so a follow-up press is predicted, and the
-- evade allowed, at the moment the server will take it. Ignored for any swing but the one playing, and
-- for an air move, which never cancels.
function AttackInputClient.NoteHitConfirmed(moveId: string): ()
	local payload = playingPayload
	if not AttackConstants.HitConfirm.Enabled or payload == nil or payload.MoveId ~= moveId then
		return
	end
	if AirComboMoves.RoleOf(moveId) ~= nil then
		return
	end
	LocalCombatState.SetCancelAt(
		AttackConstants.HitConfirmCancelAt(
			playingStartedAt,
			payload.WindupSeconds,
			payload.ActiveSeconds,
			payload.RecoverySeconds
		)
	)
end

-- The feint press. Sent only while this client has a swing of its own playing -- the one local filter
-- that is honest, since with no swing there is nothing to feint -- and never predicted: the server
-- alone knows whether the swing is still inside AttackConstants.Feint.WindowFraction of its windup,
-- and a clip cut on a guess would leave a swing the server kept landing with no animation at all.
-- Attack_Cancelled is what stops the clip.
function AttackInputClient.PressFeint(): ()
	local remote = feintRemote
	if not remote or LocalCombatState.SwingEndsAt() <= os.clock() then
		return
	end
	remote:FireServer()
end

-- Subscribes to every early end of a swing this client started -- a feint, a server-side interrupt,
-- or a prediction the server never confirmed. For presentation that was scheduled off
-- OnAttackStarted and must not play for a swing that no longer exists (SwingLunge's step,
-- AttackTrail's trail). Returns an unsubscribe function.
function AttackInputClient.OnSwingCancelled(listener: (SwingCancelReason) -> ()): () -> ()
	return swingCancelledListeners:Connect(listener)
end

-- Fires the hotbar slot as if its key had been pressed. The HUD's ability slots are real buttons
-- (AbilitySlot.lua's own header on why it is a TextButton), and "the button does the same thing as
-- its keybind" is the contract the keybind number in its corner already implies -- so both routes
-- land on one function rather than the click path growing its own copy of the binding lookup, the
-- cooldown check and the payload shape.
function AttackInputClient.PressHotbarSlot(slot: number): ()
	if typeof(slot) ~= "number" or slot < 1 or slot > SLOT_COUNT then
		return
	end
	requestHotbar(math.floor(slot))
end

-- Seconds until `slot` is usable again, 0 when it is ready. The server's number, echoed -- see
-- slotReadyAt's own note on why this is a mirror and not an authority.
function AttackInputClient.GetSlotCooldown(slot: number): number
	return slotCooldownRemaining(slot, os.clock())
end

-- Fires with (slot, seconds) when a slot goes on cooldown, and with (slot, 0) when it comes off.
-- Returns an unsubscribe function, the same contract HotbarBindings.OnChanged and every server-side
-- signal in this stack already use.
function AttackInputClient.OnSlotCooldown(listener: (slot: number, seconds: number) -> ()): () -> ()
	return slotListeners:Connect(listener)
end

-- Fires on every server-confirmed throw. For a consumer that wants to react to what actually started
-- -- a combo counter, a stage readout, an audio cue per move -- without connecting its own listener
-- to the same remote and having to re-validate the payload.
function AttackInputClient.OnAttackStarted(listener: (AttackStartedPayload) -> ()): () -> ()
	return attackStartedListeners:Connect(listener)
end

-- The weapon the server last said this player is holding. Presentation only.
function AttackInputClient.GetWeapon(): Types.WeaponId?
	return currentWeapon
end

return AttackInputClient
