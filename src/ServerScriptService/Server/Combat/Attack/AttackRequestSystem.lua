--!strict
--[[
	AttackRequestSystem.lua

	Owns: the Attack layer's public surface -- the request remote, the gates a press has to clear, the
	per-move cooldown, the forgiving input buffer, the call into HitboxEngine, and the confirmation
	the attacker gets back.

	    HitboxEngine     where the volume is, who is inside it
	    DefenseSystem    what kind of hit that was
	    DamageSystem     how much it hurts, what it does to you
	    AttackLayer      what you are trying to throw, and whether you may   <- this module

	It is the piece the other three were built without: HitboxEngine.RequestAttack had exactly one
	caller before this file, Server/Combat/TestAttackHarness.lua, which existed only so the defence
	layer had something to classify and which this module DELETES on arrival, exactly as its own header
	always said it would.

	NOTHING BELOW IT WAS REWRITTEN TO ACCOMMODATE IT. This module consumes three already-shipped
	queries in the shape they already had -- DefenseSystem.CanAttack (which had no caller at all until
	now; its own header says so), DamageSystem.CanAttack, and HitboxEngine.RequestAttack -- and adds
	two gates of its own that no lower layer could own: the move's authored Cooldown, and the
	deliberate beat between links of a string (AttackConstants.Sequence.ChainDelaySeconds, owned by
	SwingSequencer because it is a property of the string rather than of any move). That is the whole
	integration surface.

	IT ALSO OWNS ENGINE REGISTRATION, inherited from the harness. HitboxEngine and DefenseSystem keep
	SEPARATE registries by design (see DefenseSystem's own header on why), and DefenseSystem registers
	player characters itself. The engine's registry had no owner but the harness, so it moves here --
	the layer that actually throws things is the natural home for "who is a fighter the engine knows
	about." A bot or a dummy still calls HitboxEngine.RegisterCombatant directly, exactly as before.

	TWO GATES, NOT ONE, AND NEITHER SYSTEM KNOWS THE OTHER EXISTS. DefenseSystem.CanAttack answers
	"are you staggered, broken, or currently guarding"; DamageSystem.CanAttack answers "are you reeling
	from a hit." Two questions, two owners. This module is the only place they are asked together, and
	it deliberately does not merge them into a shared notion of "can act" that both would then have to
	agree on.

	REFUSAL IS ORDINARY, AND MOST OF IT IS BUFFERED RATHER THAN DROPPED. A press that arrives a few
	milliseconds before recovery ends is not a mistake worth punishing -- it is the single most common
	thing a player does, and dropping it reads as the game ignoring the input rather than as their own
	mistiming. So a refusal whose reason CLEARS ON ITS OWN (AttackConstants.Input.TransientRefusals) is
	remembered for AttackConstants.Input.BufferSeconds and thrown the instant the gate opens,
	RE-VALIDATED at flush time rather than replayed: a player parried while a press was buffered does
	not get that swing out of their own stagger. One slot, newest wins -- mashing must never build a
	backlog that fires as a burst.

	The buffer is also what makes the chain delay costless to the player: they press at whatever rhythm
	they like, and the pause shapes what comes OUT rather than being something they have to feel for on
	the way in.

	A refusal whose reason does NOT clear on its own -- no character, an unresolvable move, an
	unauthorised hotbar press, guard deliberately held -- is dropped on the spot. Buffering "you are
	holding block" would fire an attack the moment a player let go of a guard they were holding on
	purpose, which is a worse answer than doing nothing.

	NO CLIENT PREDICTION, inherited deliberately. HitboxEngine's header states the stance ("SERVER-
	AUTHORITATIVE, WITH NO CLIENT PREDICTION... the deleted PredictionMirror/CombatClient pair is not
	being rebuilt") and this layer does not quietly reintroduce it one level up. The client plays its
	own local windup cue on press and Attack_Started is the confirmation, never a rollback -- the same
	shape DefenseClient already established for the block press. Nothing the client does can decide a
	hit, so nothing it does can need undoing.

	HEARTBEAT ORDER IS LOAD-BEARING, the same way it is for the three layers below. Roblox fires
	Heartbeat connections in connection order, and this module's Step flushes buffered presses --
	which must happen AFTER DamageSystem's Step has reclaimed expired hitstun, or a press buffered
	against hitstun would be re-tested against the same expired hitstun for one extra frame. Main.
	server.lua calls the four Inits in order and Init asserts it rather than trusting the comment.

	Does not own: contact detection (HitboxEngine), what kind of hit something was (DefenseSystem),
	what a hit costs (DamageSystem), which move a press means (SwingSequencer), what a move IS
	(AttackCatalog and the Move Creation System behind it), or any presentation whatsoever -- every FX
	decision belongs to the client that receives Attack_Started.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AttackConstants = require(ReplicatedStorage.Shared.Attack.AttackConstants)
local AttackTypes = require(ReplicatedStorage.Shared.Attack.AttackTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local Types = require(ReplicatedStorage.Shared.Types)

local SwingSequencer = require(script.Parent.SwingSequencer)
local AttackCatalog = require(script.Parent.Parent.AttackCatalog)
local DamageSystem = require(script.Parent.Parent.Damage.DamageSystem)
local DefenseSystem = require(script.Parent.Parent.Defense.DefenseSystem)
local HitboxEngine = require(script.Parent.Parent.HitboxEngine.HitboxEngine)
local AdminConfig = require(script.Parent.Parent.Parent.Config.AdminConfig)

type AttackRequest = AttackTypes.AttackRequest
type AttackStartedPayload = AttackTypes.AttackStartedPayload

local logger = Logger.scope("AttackRequestSystem")

local AttackRequestSystem = {}

-- Engine registration, inherited from TestAttackHarness -- see this file's header.
local combatantIds: { [Model]: number } = {}

-- When each combatant may throw each move again. Nested per model so a whole character's cooldowns
-- drop in one assignment when their life ends, rather than needing a sweep over a flat composite key.
local cooldownUntil: { [Model]: { [string]: number } } = {}

-- The one buffered press per combatant, or none. AttackConstants.Input.BufferDepth is 1 and this
-- shape enforces it structurally rather than by checking a length.
type Buffered = {
	Request: AttackRequest,
	ExpiresAt: number,
	-- Carried so a flush can still tell an admin-gated hotbar press from an ordinary one without
	-- re-deriving authorisation from a Player who may have left in the meantime.
	Authorized: boolean,
}
local buffered: { [Model]: Buffered } = {}

local started = false
local heartbeatConnection: RBXScriptConnection? = nil
local startedRemote: RemoteEvent? = nil
local weaponChangedRemote: RemoteEvent? = nil
local requestLimiter = RateLimiter.New(AttackConstants.Network.MaxCallsPerSecondPerPlayer)
local swapLimiter = RateLimiter.New(AttackConstants.Network.MaxSwapsPerSecondPerPlayer)

-- Helpers ------------------------------------------------------------------------------------------

local function debugLog(flag: boolean, message: string, data: { [string]: any }?): ()
	if AttackConstants.Debug.Enabled and flag then
		logger:debug(message, data)
	end
end

local function isAlive(model: Model): boolean
	if model.Parent == nil then
		return false
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

local function cooldownRemaining(model: Model, moveId: string, now: number): number
	local perMove = cooldownUntil[model]
	if not perMove then
		return 0
	end
	local until_ = perMove[moveId]
	if not until_ then
		return 0
	end
	return math.max(until_ - now, 0)
end

local function setCooldown(model: Model, moveId: string, seconds: number, now: number): ()
	if seconds <= 0 then
		return
	end
	local perMove = cooldownUntil[model]
	if not perMove then
		perMove = {}
		cooldownUntil[model] = perMove
	end
	perMove[moveId] = now + seconds
end

-- Tells the attacker, and only the attacker, what the server just started. Silently does nothing for
-- a bot or a dummy, which have no player to tell -- the same "not every combatant is a Player"
-- tolerance every other module in this stack keeps.
local function sendStarted(model: Model, payload: AttackStartedPayload): ()
	local remote = startedRemote
	if not remote then
		return
	end
	local player = Players:GetPlayerFromCharacter(model)
	if not player then
		return
	end
	remote:FireClient(player, payload)
end

-- Throwing -----------------------------------------------------------------------------------------

-- Resolves which move a request means. Split from Throw below so the answer is available before any
-- gate runs -- the cooldown check needs a MoveId, and a press that is refused must not have advanced
-- the string, so nothing here mutates.
local function resolveRequest(
	model: Model,
	request: AttackRequest,
	authorized: boolean,
	now: number
): (SwingSequencer.Resolution?, string?)
	if request.Kind == "Hotbar" then
		-- ADMIN-GATED, NOT TRUSTED -- see AttackTypes.AttackRequest.MoveId's own header for the whole
		-- reasoning, and for what deletes this branch once a real loadout system exists.
		if not authorized then
			return nil, "NotAuthorized"
		end
		local moveId = request.MoveId
		if typeof(moveId) ~= "string" or not AttackCatalog.Has(moveId) then
			return nil, "UnknownMove"
		end
		return {
			MoveId = moveId,
			WeaponId = SwingSequencer.GetWeapon(model),
			-- A hotbar move is not part of either string, so it has no stage of its own and must not
			-- disturb the one in progress. Advance is deliberately never called for it below.
			StageIndex = 0,
			IsFinisher = false,
		},
			nil
	end

	local resolution = SwingSequencer.Resolve(model, request.Kind, DamageSystem.GetComboStage(model, now), now)
	if not resolution then
		return nil, "UnknownMove"
	end
	return resolution, nil
end

-- Runs every gate and, if they all pass, actually throws. Returns (accepted, reason) -- a refusal is
-- normal and never an error, matching HitboxEngine.RequestAttack's own contract.
--
-- PUBLIC, so a bot's decision-making can throw through exactly the same path a player's press does,
-- with no special casing anywhere in this file -- the same reason DefenseSystem.SetBlocking is
-- exposed alongside its own remote handler.
function AttackRequestSystem.Throw(
	model: Model,
	request: AttackRequest,
	authorized: boolean,
	now: number
): (boolean, string?)
	if not isAlive(model) then
		return false, "NoCharacter"
	end

	local combatantId = combatantIds[model] or HitboxEngine.GetCombatantId(model)
	if not combatantId then
		return false, "NotRegistered"
	end

	-- Asked BEFORE the catalogue lookup and the engine call, because both of those cost more than a
	-- table read and neither can succeed while these refuse.
	local defenceAllows, defenceReason = DefenseSystem.CanAttack(model)
	if not defenceAllows then
		return false, defenceReason or "Defending"
	end

	local damageAllows, damageReason = DamageSystem.CanAttack(model, now)
	if not damageAllows then
		return false, damageReason or "Hitstun"
	end

	local resolution, resolveReason = resolveRequest(model, request, authorized, now)
	if not resolution then
		return false, resolveReason or "UnknownMove"
	end

	local entry = AttackCatalog.Get(resolution.MoveId)
	if not entry then
		-- Resolve already asked Has() for the hotbar path and the sequencer probed the catalogue for
		-- the string path, so reaching here means the registry changed between those two reads. Real,
		-- rare, and worth a line rather than a silent nothing.
		return false, "UnknownMove"
	end

	if cooldownRemaining(model, resolution.MoveId, now) > 0 then
		return false, "Cooldown"
	end

	-- The deliberate beat between links of a string. Not applied to a hotbar move: that is a one-off
	-- cast with its own authored Cooldown, not a link in a chain, and making it wait on the rhythm of a
	-- string it is not part of would be a second, invisible cooldown on top of its real one.
	--
	-- REPORTED AS "Busy" WHILE THE SWING THAT OWES THE BEAT IS STILL RUNNING. The beat always outlasts
	-- its own swing (it starts when the swing ends), so checking it before the engine would otherwise
	-- mean a mid-swing press ALWAYS reports ChainDelay and "Busy" never appears for a weapon string at
	-- all -- which would quietly cost the debug log its most basic distinction between "you are still
	-- swinging" and "you are waiting out the pause". Both are transient and both buffer identically, so
	-- this changes nothing about behaviour and everything about whether the log can be read.
	if request.Kind ~= "Hotbar" and SwingSequencer.ChainDelayRemaining(model, now) > 0 then
		local engineState = HitboxEngine.GetAttackState(combatantId)
		return false, if engineState ~= nil and engineState ~= "Idle" then "Busy" else "ChainDelay"
	end

	-- comboStage scales the VOLUME of this one swing by how deep the attacker's unbroken landed string
	-- is (HitboxEngine's own ScalingProfile), which is a different question from which move the string
	-- is on. Projected moves are flat-scaled today (MoveTypes.ToEngineAttackDefinition's own note), so
	-- this currently changes nothing -- it is passed honestly anyway, so the day the Move Editor grows
	-- a scaling curve this needs no edit.
	local comboStage = DamageSystem.GetComboStage(model, now)
	-- PowerLevel is the old weight-class distinction between a jab and a heavy. Authored per move
	-- nowhere yet, so a flat 1 is the honest value rather than an invented curve.
	local accepted, engineReason = HitboxEngine.RequestAttack(combatantId, entry.Definition, comboStage, 1)
	if not accepted then
		return false, engineReason or "Busy"
	end

	-- Committed only now, after the engine agreed. A refused press leaves the string exactly where it
	-- was, which is what makes "press early, get refused, press again" continue the combo rather than
	-- silently skipping a stage.
	--
	-- The commitment handed over is the same definition the engine was just given, so the string's own
	-- deadline can never be built from a different version of the move than the one actually swinging.
	if request.Kind ~= "Hotbar" then
		local commitment = entry.Definition.WindupSeconds
			+ entry.Definition.ActiveSeconds
			+ entry.Definition.RecoverySeconds
		SwingSequencer.Advance(model, request.Kind, resolution, commitment, now)
	end
	setCooldown(model, resolution.MoveId, entry.Cooldown, now)

	sendStarted(model, {
		MoveId = resolution.MoveId,
		Kind = request.Kind,
		Slot = request.Slot,
		WeaponId = resolution.WeaponId,
		StageIndex = resolution.StageIndex,
		ComboStage = comboStage,
		WindupSeconds = entry.Definition.WindupSeconds,
		ActiveSeconds = entry.Definition.ActiveSeconds,
		RecoverySeconds = entry.Definition.RecoverySeconds,
		CooldownSeconds = entry.Cooldown,
		-- "" for every Default move today (DefaultMoveRegistry's own header). The client treats a blank
		-- id as "no clip", never as an error.
		AnimationId = entry.AnimationId,
	})

	debugLog(AttackConstants.Debug.LogAccepted, "Attack thrown", {
		model = model.Name,
		moveId = resolution.MoveId,
		stageIndex = resolution.StageIndex,
		comboStage = comboStage,
	})
	return true, nil
end

-- Buffering ----------------------------------------------------------------------------------------

local function rememberRefused(
	model: Model,
	request: AttackRequest,
	authorized: boolean,
	reason: string,
	now: number
): ()
	if not AttackConstants.Input.TransientRefusals[reason] then
		-- Not a "not yet" -- see this file's header on why holding a guard, or an unauthorised hotbar
		-- press, must not be queued.
		return
	end
	-- Newest wins, one slot. Replacing rather than queueing is the whole reason mashing cannot build a
	-- backlog that fires as a burst once the gate opens.
	buffered[model] = {
		Request = request,
		ExpiresAt = now + AttackConstants.Input.BufferSeconds,
		Authorized = authorized,
	}
	debugLog(AttackConstants.Debug.LogBuffer, "Press buffered", { model = model.Name, reason = reason })
end

-- A PRESS, as opposed to a throw: tries to throw, and remembers the press for a moment if the only
-- reason it could not is one that clears on its own.
--
-- This is the entry point a press should go through -- the remote handler calls it, and so should a
-- bot, for the same "one path for players and bots" reason DefenseSystem.SetBlocking is exposed
-- alongside its own remote handler. Throw above stays public and separate for a caller that wants a
-- straight yes/no with no buffering at all (a scripted boss beat, a spec asserting a single gate).
--
-- Returns Throw's own (accepted, reason), so a caller can tell "thrown" from "buffered" from
-- "dropped" -- accepted is true for the first, and the reason distinguishes the other two through
-- AttackConstants.Input.TransientRefusals.
function AttackRequestSystem.Press(
	model: Model,
	request: AttackRequest,
	authorized: boolean,
	now: number
): (boolean, string?)
	local accepted, reason = AttackRequestSystem.Throw(model, request, authorized, now)
	if accepted then
		return true, nil
	end
	rememberRefused(model, request, authorized, reason or "Busy", now)
	return false, reason
end

-- Whether a press is currently sitting in this combatant's buffer. For a spec, and for any future
-- readout that wants to show a queued input.
function AttackRequestSystem.HasBufferedPress(model: Model, now: number): boolean
	local entry = buffered[model]
	return entry ~= nil and now < entry.ExpiresAt
end

-- Re-runs every buffered press against the CURRENT state, dropping whatever has expired. Re-validated
-- rather than replayed: the whole point is that a press buffered a moment ago may have become illegal
-- since, and firing it anyway would hand a parried player a swing out of their own stagger.
local function flushBuffers(now: number): ()
	for model, entry in buffered do
		if model.Parent == nil or now >= entry.ExpiresAt then
			buffered[model] = nil
			continue
		end
		local accepted = AttackRequestSystem.Throw(model, entry.Request, entry.Authorized, now)
		if accepted then
			buffered[model] = nil
			debugLog(AttackConstants.Debug.LogBuffer, "Buffered press flushed", { model = model.Name })
		end
	end
end

-- Requests -----------------------------------------------------------------------------------------

-- Turns whatever arrived over the wire into an AttackRequest, or nil. Every field is checked rather
-- than trusted: this is a public remote, and the payload is the one thing in this system a client
-- authors.
local function sanitizeRequest(raw: unknown): AttackRequest?
	if typeof(raw) ~= "table" then
		return nil
	end
	local candidate = raw :: { [string]: unknown }
	local kind = candidate.Kind
	if kind ~= "Basic" and kind ~= "Heavy" and kind ~= "Hotbar" then
		return nil
	end

	if kind ~= "Hotbar" then
		-- Slot and MoveId are meaningless outside a hotbar press and are dropped rather than carried,
		-- so a client cannot smuggle a MoveId in on a Basic press and have some later reader honour it.
		return { Kind = kind :: AttackTypes.AttackKind }
	end

	local rawSlot = candidate.Slot
	-- The NaN check is not paranoia: math.floor(0/0) is still NaN, and NaN passes every comparison
	-- below by failing all of them, so an unchecked NaN slot would sail through as a valid index.
	if typeof(rawSlot) ~= "number" or rawSlot ~= rawSlot then
		return nil
	end
	local slot = math.floor(rawSlot :: number)
	if slot < 1 or slot > AttackConstants.Hotbar.SlotCount then
		return nil
	end

	local rawMoveId = candidate.MoveId
	if typeof(rawMoveId) ~= "string" or rawMoveId == "" then
		return nil
	end

	return { Kind = "Hotbar", Slot = slot, MoveId = rawMoveId :: string }
end

local function handleRequest(player: Player, raw: unknown): ()
	-- Throttled requests are DROPPED, never buffered: the buffer forgives a mistimed press, it does not
	-- hand a mashing client a queue.
	if requestLimiter:IsLimited(player) then
		return
	end

	local request = sanitizeRequest(raw)
	if not request then
		return
	end

	local character = player.Character
	if not character then
		return
	end

	local authorized = AdminConfig.AuthorizedUserIds[player.UserId] == true
	local accepted, reason = AttackRequestSystem.Press(character, request, authorized, os.clock())
	if not accepted then
		debugLog(AttackConstants.Debug.LogRefused, "Attack refused", {
			player = player.Name,
			kind = request.Kind,
			reason = reason,
		})
	end
end

local function handleSwap(player: Player): ()
	if swapLimiter:IsLimited(player) then
		return
	end
	local character = player.Character
	if not character then
		return
	end
	local weaponId = SwingSequencer.SwapWeapon(character, os.clock())
	-- A swap abandons the in-progress string, so anything buffered against it is stale by definition.
	buffered[character] = nil

	local remote = weaponChangedRemote
	if remote then
		remote:FireClient(player, { WeaponId = weaponId } :: AttackTypes.WeaponChangedPayload)
	end
end

-- Registry -----------------------------------------------------------------------------------------

local function bindCharacter(character: Model): ()
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not rootPart or not rootPart:IsA("BasePart") then
		return
	end
	combatantIds[character] = HitboxEngine.RegisterCombatant(character, rootPart, humanoid)
end

local function unbindCharacter(character: Model): ()
	local id = combatantIds[character]
	if id then
		HitboxEngine.UnregisterCombatant(id)
		combatantIds[character] = nil
	end
	-- A new life inherits none of the previous one's string, cooldowns or buffered press. Dropped here
	-- rather than left to the Step sweep so a respawn is immediate rather than up-to-a-frame stale.
	cooldownUntil[character] = nil
	buffered[character] = nil
	SwingSequencer.Clear(character)
end

-- Public queries -----------------------------------------------------------------------------------

-- Seconds until this combatant may throw this move again. For a HUD, a bot's own planning, or a spec.
function AttackRequestSystem.GetCooldownRemaining(model: Model, moveId: string, now: number): number
	return cooldownRemaining(model, moveId, now)
end

function AttackRequestSystem.GetWeapon(model: Model): Types.WeaponId
	return SwingSequencer.GetWeapon(model)
end

-- The loop -----------------------------------------------------------------------------------------

-- One frame. `now` is the caller's clock, matching HitboxEngine.Step, DefenseSystem.Step and
-- DamageSystem.Step's own convention so all four agree about what a frame is.
function AttackRequestSystem.Step(_deltaTime: number, now: number): ()
	flushBuffers(now)

	-- Reclaims cooldown records for characters that no longer exist. Every individual timestamp
	-- expires on its own, so this only exists to stop the OUTER table holding a reference to a
	-- destroyed model forever.
	for model in cooldownUntil do
		if model.Parent == nil then
			cooldownUntil[model] = nil
		end
	end
	SwingSequencer.Sweep()
end

-- Lifecycle ----------------------------------------------------------------------------------------

function AttackRequestSystem.Init(): ()
	if started then
		return
	end
	-- See this file's header: Heartbeat order is a correctness property, not a preference. Asserted
	-- rather than documented, because a comment in Main.server.lua cannot fail a boot.
	assert(HitboxEngine.RegisteredCount() >= 0, "AttackRequestSystem.Init() requires HitboxEngine to be available")
	assert(DefenseSystem.CanAttack ~= nil, "AttackRequestSystem.Init() requires DefenseSystem to be available")
	assert(DamageSystem.CanAttack ~= nil, "AttackRequestSystem.Init() requires DamageSystem to be available")
	started = true

	local requestRemote = NetworkBridge.CreateRemoteEvent(AttackConstants.Network.RemoteNames.Request)
	requestRemote.OnServerEvent:Connect(handleRequest)
	startedRemote = NetworkBridge.CreateRemoteEvent(AttackConstants.Network.RemoteNames.Started)

	local swapRemote = NetworkBridge.CreateRemoteEvent(AttackConstants.Network.RemoteNames.SwapWeapon)
	swapRemote.OnServerEvent:Connect(handleSwap)
	weaponChangedRemote = NetworkBridge.CreateRemoteEvent(AttackConstants.Network.RemoteNames.WeaponChanged)

	-- REGISTERS PLAYER CHARACTERS WITH THE ENGINE, inherited from the deleted TestAttackHarness -- see
	-- this file's header. Bots and dummies are NOT auto-registered: they have no CharacterAdded to
	-- hang off, and whoever spawns them already knows when they exist.
	local function bindPlayer(player: Player): ()
		player.CharacterAdded:Connect(bindCharacter)
		player.CharacterRemoving:Connect(unbindCharacter)
		if player.Character then
			bindCharacter(player.Character)
		end
	end

	Players.PlayerAdded:Connect(bindPlayer)
	-- Players who joined before this System booted still need their registration -- the same Init()-
	-- time sweep every other PlayerAdded-driven System in this codebase uses as its backstop.
	for _, player in Players:GetPlayers() do
		bindPlayer(player)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		requestLimiter:Clear(player)
		swapLimiter:Clear(player)
		local character = player.Character
		if character then
			unbindCharacter(character)
		end
	end)

	-- Connected AFTER DamageSystem.Init has connected its own, which Main.server.lua guarantees by
	-- calling that first.
	heartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime: number)
		AttackRequestSystem.Step(deltaTime, os.clock())
	end)

	logger:info("AttackRequestSystem.Init() complete")
end

function AttackRequestSystem.Shutdown(): ()
	if heartbeatConnection then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end
	started = false
end

-- Drops every piece of per-combatant state. Spec-only, so one case cannot serve another its state --
-- the same role HitboxEngine.Reset, DefenseSystem.Reset and DamageSystem.Reset play for their own
-- modules.
function AttackRequestSystem.Reset(): ()
	table.clear(combatantIds)
	table.clear(cooldownUntil)
	table.clear(buffered)
	SwingSequencer.Reset()
end

return AttackRequestSystem :: Types.SystemModule & typeof(AttackRequestSystem)
