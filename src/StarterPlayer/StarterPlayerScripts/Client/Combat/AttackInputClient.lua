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
	     animation plays against real numbers rather than a guess. Nothing it says is ever a rollback,
	     because the client never claimed anything it could be wrong about.

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
local UserInputService = game:GetService("UserInputService")

local AnimationManager = require(ReplicatedStorage.Shared.Animation.AnimationManager)
local AttackConstants = require(ReplicatedStorage.Shared.Attack.AttackConstants)
local AttackTypes = require(ReplicatedStorage.Shared.Attack.AttackTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Types = require(ReplicatedStorage.Shared.Types)

local HotbarBindings = require(script.Parent.HotbarBindings)
local FOVOffset = require(script.Parent.Parent.FX.FOVOffset)
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

local started = false
local requestRemote: RemoteEvent? = nil
local swapRemote: RemoteEvent? = nil

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
local slotListeners: { (slot: number, seconds: number) -> () } = {}

-- Throttle for the local press cue -- see AttackConstants.Presentation.SwingPunch.MinIntervalSeconds
-- for why mashing must not strobe the camera.
local lastPunchAt = 0

-- The local player's weapon, as last reported by the server. Presentation only: nothing here decides
-- which weapon is held, and no request payload carries it.
local currentWeapon: Types.WeaponId = AttackConstants.Weapons.Default

-- ONE manager for the local player's whole lifetime, bound/unbound per life -- the same "construct
-- once, Bind() per respawn" shape AnimationManager.new's own header recommends for a caller that owns
-- exactly one rig, and the same one DefenseClient already uses. Its claims are independent of
-- DefenseClient's: two managers, two layers, no shared arbitration (a known, pre-existing gap
-- documented in AnimationManager's own header, not one this module can close).
local manager = AnimationManager.new({ Name = "AttackInputClient" })

-- Sending -------------------------------------------------------------------------------------------

local function sendRequest(request: AttackTypes.AttackRequest): ()
	local remote = requestRemote
	if not remote then
		-- Only reachable in the window between a keypress and Start() resolving the remote, which the
		-- boot sequence makes vanishingly small. Warned rather than silently dropped so a genuine
		-- ordering regression in Main.client.lua is visible rather than felt as "attacks sometimes
		-- don't work at boot."
		logger:warn("Attack pressed before the request remote was ready")
		return
	end
	remote:FireServer(request)
end

-- The immediate, local "that registered" cue. Cosmetic in the strictest sense: a camera FOV nudge,
-- composed through the shared FOVOffset compositor so it sums with (rather than fights) the run
-- system's own zoom.
local function playPressCue(): ()
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

local function requestWeaponAttack(kind: AttackTypes.AttackKind): ()
	-- ALWAYS SENT, never pre-filtered. Which move a Basic/Heavy press resolves to is server state this
	-- module does not mirror, so there is no honest local answer to "would this be refused" -- and the
	-- server forgives an early press by buffering it, which a local drop would throw away.
	playPressCue()
	sendRequest({ Kind = kind })
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
	playPressCue()
	sendRequest({ Kind = "Hotbar", Slot = slot, MoveId = moveId })
end

-- Input ---------------------------------------------------------------------------------------------

local function onInputBegan(input: InputObject, gameProcessed: boolean): ()
	-- gameProcessed covers both halves of the obvious double-fire: a click that landed on a HUD
	-- ability slot (that button fires its own OnActivated, which routes here through
	-- AttackInputClient.PressHotbarSlot), and a number key typed into a TextBox.
	if gameProcessed then
		return
	end

	if KeybindManager.Matches("BasicAttack", input) then
		requestWeaponAttack("Basic")
		return
	end
	if KeybindManager.Matches("HeavyAttack", input) then
		requestWeaponAttack("Heavy")
		return
	end
	if KeybindManager.Matches("SwapWeapon", input) then
		local remote = swapRemote
		if remote then
			remote:FireServer()
		end
		return
	end

	for slot, action in HOTBAR_ACTIONS do
		if KeybindManager.Matches(action, input) then
			requestHotbar(slot)
			return
		end
	end
end

-- Presentation ---------------------------------------------------------------------------------------

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
	local scheduled = payload.WindupSeconds + payload.ActiveSeconds + payload.RecoverySeconds

	manager:SetClaim(ATTACK_LAYER, SWING_SOURCE, {
		Clip = animationId,
		Looped = false,
		Priority = Enum.AnimationPriority.Action,
		FadeIn = AttackConstants.Presentation.SwingFadeSeconds,
		FadeOut = AttackConstants.Presentation.SwingFadeSeconds,
		MaxSeconds = scheduled,
	})
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
	for _, listener in slotListeners do
		listener(slot, seconds)
	end

	task.delay(seconds, function()
		-- Guarded against a newer press: a second use of the same slot inside the first cooldown
		-- pushes readyAt out, and the first timer firing afterwards must not report the slot ready
		-- while the newer cooldown is still running.
		if slotReadyAt[slot] ~= readyAt then
			return
		end
		slotReadyAt[slot] = nil
		for _, listener in slotListeners do
			listener(slot, 0)
		end
	end)
end

local attackStartedListeners: { (AttackStartedPayload) -> () } = {}

local function onAttackStarted(raw: unknown): ()
	if typeof(raw) ~= "table" then
		return
	end
	local payload = raw :: AttackStartedPayload
	if typeof(payload.MoveId) ~= "string" then
		return
	end

	playSwing(payload)

	if payload.Kind == "Hotbar" and typeof(payload.Slot) == "number" then
		noteSlotCooldown(payload.Slot :: number, payload.CooldownSeconds)
	end

	for _, listener in attackStartedListeners do
		listener(payload)
	end
end

local function onWeaponChanged(raw: unknown): ()
	if typeof(raw) ~= "table" then
		return
	end
	local payload = raw :: AttackTypes.WeaponChangedPayload
	if payload.WeaponId ~= "Primary" and payload.WeaponId ~= "Secondary" then
		return
	end
	currentWeapon = payload.WeaponId
	logger:debug("Weapon changed", { weaponId = currentWeapon })
end

-- Lifecycle ------------------------------------------------------------------------------------------

local function bindCharacter(character: Model): ()
	-- A new life inherits no cooldowns: the server drops them on the same event (
	-- AttackRequestSystem's own unbindCharacter), so leaving them here would show a HUD sweep for a
	-- restriction that no longer exists.
	table.clear(slotReadyAt)
	for slot = 1, SLOT_COUNT do
		for _, listener in slotListeners do
			listener(slot, 0)
		end
	end

	-- Bind() runs Unbind() first thing internally, so the previous life's claims and tracks are
	-- dropped without this needing to clear ATTACK_LAYER separately.
	manager:Bind(character)
end

local function unbind(): ()
	manager:Unbind()
end

function AttackInputClient.Start(): ()
	if started then
		return
	end
	started = true

	requestRemote = NetworkBridge.GetRemoteEvent(AttackConstants.Network.RemoteNames.Request)
	swapRemote = NetworkBridge.GetRemoteEvent(AttackConstants.Network.RemoteNames.SwapWeapon)

	local startedRemote = NetworkBridge.GetRemoteEvent(AttackConstants.Network.RemoteNames.Started)
	startedRemote.OnClientEvent:Connect(onAttackStarted)

	local weaponChanged = NetworkBridge.GetRemoteEvent(AttackConstants.Network.RemoteNames.WeaponChanged)
	weaponChanged.OnClientEvent:Connect(onWeaponChanged)

	UserInputService.InputBegan:Connect(onInputBegan)

	local localPlayer = Players.LocalPlayer
	localPlayer.CharacterAdded:Connect(bindCharacter)
	localPlayer.CharacterRemoving:Connect(unbind)
	if localPlayer.Character then
		bindCharacter(localPlayer.Character)
	end

	logger:info("AttackInputClient started")
end

-- Public ---------------------------------------------------------------------------------------------

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
	table.insert(slotListeners, listener)
	return function()
		local index = table.find(slotListeners, listener)
		if index then
			table.remove(slotListeners, index)
		end
	end
end

-- Fires on every server-confirmed throw. For a consumer that wants to react to what actually started
-- -- a combo counter, a stage readout, an audio cue per move -- without connecting its own listener
-- to the same remote and having to re-validate the payload.
function AttackInputClient.OnAttackStarted(listener: (AttackStartedPayload) -> ()): () -> ()
	table.insert(attackStartedListeners, listener)
	return function()
		local index = table.find(attackStartedListeners, listener)
		if index then
			table.remove(attackStartedListeners, index)
		end
	end
end

-- The weapon the server last said this player is holding. Presentation only.
function AttackInputClient.GetWeapon(): Types.WeaponId
	return currentWeapon
end

return AttackInputClient
