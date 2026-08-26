--!strict
--[[
	CombatAudio.lua

	Owns: combat's sound registrations and the verb-named play functions its callers use -- the same
	"domain module owns WHICH sounds exist and gives them a typed API" shape Client/FX/RunAudio.lua and
	Client/FX/FlightAudio.lua already establish.

	TWO LAYERS OF DEFINITION, ONE PRECEDENCE, and this module is the only place they meet:

	  1. THE WEAPON'S OWN, from Shared/Combat/WeaponSounds.lua -- the real Sound instances a weapon
	     builder authored in their model's SFX/Swing, SFX/Block, SFX/Parry, SFX/Equip and SFX/Sheathe
	     folders in Workspace.Weapons. Tried FIRST for every moment that has a weapon behind it.
	  2. CombatConstants.Sound, the SHARED fallback -- the weapon-agnostic swing whoosh and the
	     per-outcome impact stingers. Used when the moment has no weapon (an unarmed swing), when the
	     weapon authored nothing for that slot, or for the outcomes no weapon slot describes at all
	     (Clean/Backstab/Trade/GuardBroken -- see IMPACT_WEAPON_SLOTS below).

	That is EXACTLY the precedence Shared/Attack/AttackAnimations.lua already runs for swing clips
	(weapon override first, shared baseline second) and it is deliberately the same one: a weapon
	builder who has posed M1/M2/M3 on their sword and dropped a whoosh next to them should not have to
	learn that the clips are per-weapon but the sounds are global. See WeaponSounds.lua's own header for
	the folder layout and for why the ids get parsed rather than trusted.

	NEVER GUESSES AN ASSET ID. Every SoundId in CombatConstants.Sound is "" except Swing.Basic -- there
	is still no uploaded impact/parry/guard-break sound in the Lua config. That is fine and always was:
	SoundManager.Register warns rather than errors on a blank id, Play no-ops on one, and the WEAPON
	layer above is now the path by which a real sword actually gets a voice without anyone pasting an id
	into a Lua file at all.

	FOUR HOOK POINTS. The first two predate the weapon layer and keep their shapes unchanged; the third
	and fourth arrived with it.

	  * PlaySwing is driven from THIS module's own Attack_Started subscription
	    (AttackInputClient.OnAttackStarted), started/stopped exactly like Client/Combat/SwingLunge.lua
	    already does for the same event. The subscriber (onAttackStarted below) does not call PlaySwing
	    immediately -- it schedules it against the swing's own windup (CombatConstants.Sound.SwingDelaySeconds,
	    via SwingLunge.DelayFor) so the sound lands when the arm actually swings forward, not on the
	    frame the button went down. The payload carries WeaponId, so the swing already knows whose
	    whoosh to reach for with no lookup of its own.

	  * PlayImpact has NO subscription of its own -- Client/Combat/CombatFeedbackClient.lua's own
	    onFeedback calls it directly, alongside that function's existing shakeFor/flashFor calls, all
	    keyed off the same DefenseTypes.OutcomeKind. Combat_Feedback already has exactly one subscriber
	    by design (see that module's own header), and a second Connect from here would be a second,
	    competing place deciding what a resolved contact means.

	  * PlayEquip/PlaySheathe are driven from THIS module's own Weapon_InventoryChanged subscription,
	    for the same reason the swing keeps its own: there is no per-frame owner of the draw moment to
	    call out to us, and Client/Combat/WeaponInventoryClient.lua's own header declares itself to be
	    about the inventory HUD and nothing else. Client/FX/CombatAnimator.lua already sets the second
	    independent listener precedent on that same remote and explains why that is free.

	THE BLOCK/PARRY SOUND IS THE DEFENDER'S WEAPON, NOT THE LOCAL PLAYER'S. Combat_Feedback reaches BOTH
	participants (see DamageTypes.CombatFeedback's Role field), so on an attacker's machine "my weapon"
	is the wrong answer for the clang their swing just made against someone else's guard. The defender's
	weapon is read off the Tool the server put in their hand -- WeaponConstants.Visual, the one statement
	of "which weapon is this character holding" that replicates to every client (Weapon_InventoryChanged
	is owner-only by design). Both machines therefore play the same weapon's block sound, which is the
	whole point: a parry should sound like the thing that parried.

	Pitch jitter (CombatConstants.Sound.PitchJitter) is applied per play, the identical "a fixed sample
	replayed on every hit reads as a metronome" fix Client/FX/RunAudio.lua's own PitchJitter documents.
	It rides on the weapon layer too -- an authored sword whoosh is one sample and repeats just as
	audibly as a shared one.

	Does not own: WHEN an attack starts or a contact resolves (AttackInputClient/CombatFeedbackClient
	decide that, this module only reacts), which weapon anyone is holding (the server does; this module
	only reads what it is told or what is stamped on the Tool), the camera shake or damage numbers that
	accompany the same moments (CameraShake.lua, Client/UI/Screens/CombatFeedback), or the Sound-instance
	mechanics (SoundManager.lua). Purely local presentation; nothing here crosses the network or affects
	an outcome.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AttackTypes = require(ReplicatedStorage.Shared.Attack.AttackTypes)
local CombatConstants = require(ReplicatedStorage.Shared.Combat.CombatConstants)
local Constants = require(ReplicatedStorage.Shared.Constants)
local DefenseTypes = require(ReplicatedStorage.Shared.Defense.DefenseTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local WeaponConstants = require(ReplicatedStorage.Shared.Combat.WeaponConstants)
local WeaponSounds = require(ReplicatedStorage.Shared.Combat.WeaponSounds)

local SoundManager = require(script.Parent.SoundManager)
local AttackInputClient = require(script.Parent.Parent.Combat.AttackInputClient)
-- Reused for exactly one function, DelayFor(windupSeconds, delaySeconds) -- see this file's own
-- onAttackStarted for why the swing sound schedules against the same windup the lunge step does,
-- through the identical pure formula rather than a second copy of it.
local SwingLunge = require(script.Parent.Parent.Combat.SwingLunge)

type AttackKind = AttackTypes.AttackKind
type OutcomeKind = DefenseTypes.OutcomeKind
type SoundDefinition = Constants.SoundDefinition

local logger = Logger.scope("CombatAudio")

local CombatAudio = {}

local SOUND_CONFIG = CombatConstants.Sound
local PITCH_JITTER = SOUND_CONFIG.PitchJitter
local SWING_DELAY = SOUND_CONFIG.SwingDelaySeconds

local SLOTS = WeaponSounds.Slots

-- One shared generator, the same isolation reasoning Client/FX/RunAudio.lua's own `random` upvalue
-- documents: combat's pitch jitter must never perturb, or be perturbed by, an unrelated caller's draw
-- from math.random's global state.
local random = Random.new()

-- Registered at load -- what puts these in SoundManager.GetPreloadInstances, which
-- Client/Loading/AssetPreloader.lua sweeps at boot (once real assets exist) so the first swing/impact
-- of a session doesn't pay CDN streaming latency mid-fight. The WEAPON layer cannot be registered here
-- (Workspace.Weapons is content, resolved per weapon on demand -- see ensureWeaponSound), so the
-- preloader reaches those ids through WeaponSounds.GetPreloadIds instead.
local SWING_SOUND_NAMES: { [string]: string } = {}
for kind, definition in SOUND_CONFIG.Swing do
	local name = `Swing{kind}`
	SWING_SOUND_NAMES[kind] = name
	SoundManager.Register(name, definition)
end

local IMPACT_SOUND_NAMES: { [string]: string } = {}
for outcomeKind, definition in SOUND_CONFIG.Impact do
	local name = `Impact{outcomeKind}`
	IMPACT_SOUND_NAMES[outcomeKind] = name
	SoundManager.Register(name, definition)
end

-- Outcomes that share Impact's registered sound rather than carrying their own -- see
-- CombatConstants.Sound.Impact's own header for why Backstab/Trade were not given separate
-- placeholders yet. Both resolve here rather than being left unmapped, so a Trade or a Backstab is
-- never silently silent.
IMPACT_SOUND_NAMES.Backstab = IMPACT_SOUND_NAMES.Clean
IMPACT_SOUND_NAMES.Trade = IMPACT_SOUND_NAMES.Clean

-- Which outcomes a WEAPON can speak for, and with which of its own slots. Only two, and deliberately:
-- Blocked and Parried are the outcomes where a weapon physically made the sound -- steel caught steel
-- -- so the weapon that caught it is the right thing to hear. Clean/Backstab/Trade/GuardBroken are
-- statements about a BODY and a guard meter, not about a blade, and they keep the shared per-outcome
-- stingers CombatConstants.Sound.Impact already owns. An outcome absent from this table is not a gap
-- to fill later; it is the answer.
local IMPACT_WEAPON_SLOTS: { [string]: string } = {
	Blocked = SLOTS.Block,
	Parried = SLOTS.Parry,
}

-- Per-slot pool depth for the lazily-registered weapon sounds. A Sound instance has no PoolSize of its
-- own for a weapon builder to author, so these are chosen here on the same "can this genuinely
-- re-trigger before its own predecessor finishes" grounds CombatConstants.Sound.Impact's own header
-- reasons about: a Basic string throws a swing every 0.3-0.6s and a blocked flurry lands about as
-- often, while a draw or a sheathe is a once-per-few-seconds gesture that can never overlap itself.
local WEAPON_POOL_SIZES: { [string]: number } = {
	[SLOTS.Swing] = 3,
	[SLOTS.Block] = 3,
	[SLOTS.Parry] = 2,
	[SLOTS.Equip] = 1,
	[SLOTS.Sheathe] = 1,
}

local function jitteredSpeed(): number
	if PITCH_JITTER <= 0 then
		return 1
	end
	return 1 + random:NextNumber(-PITCH_JITTER, PITCH_JITTER)
end

-- Weapon layer ---------------------------------------------------------------------------------------

-- What has already been handed to SoundManager, keyed by the registered name, holding the definition it
-- was last given. Two jobs, both needed: it is how a second swing of the same sword skips re-registering
-- (SoundManager.Register warns and rebuilds on a duplicate name -- correct for a genuine collision, wrong
-- as a per-swing event), and it is how a weapon builder EDITING a SoundId live in Studio still gets
-- heard, since a changed definition takes the Reconfigure path instead of being ignored.
local registeredWeaponDefinitions: { [string]: SoundDefinition } = {}

-- Resolves `weaponId`'s own sound for `slot`, registering it with SoundManager on first use, and
-- returns the registered name -- or nil when that weapon authored nothing usable there, which every
-- caller reads as "fall through to the shared sound."
--
-- LAZY, not swept at load, unlike the CombatConstants registrations above. These live on models in
-- Workspace.Weapons, which is replicated content: a client's copy may not exist yet at module-load
-- time, a weapon may be added to the roster while a session is running, and most sessions will only
-- ever touch the two or three weapons that player actually draws. Resolving on demand costs a handful
-- of FindFirstChild calls on the swing path and needs no invalidation story at all. The asset itself is
-- still warm by then -- Client/Loading/AssetPreloader.lua preloads every weapon's ids at boot through
-- WeaponSounds.GetPreloadIds, independently of whether this function has ever run.
local function ensureWeaponSound(weaponId: string?, slot: string): string?
	local definition = WeaponSounds.Get(weaponId, slot)
	if not definition or definition.SoundId == "" then
		return nil
	end

	local name = `Weapon:{weaponId}:{slot}`
	local pooled: SoundDefinition = {
		SoundId = definition.SoundId,
		Volume = definition.Volume,
		PoolSize = WEAPON_POOL_SIZES[slot],
	}

	local existing = registeredWeaponDefinitions[name]
	if not existing then
		SoundManager.Register(name, pooled)
	elseif existing.SoundId ~= pooled.SoundId or existing.Volume ~= pooled.Volume then
		-- Reconfigure, not Register: it repoints the pooled instances in place rather than stranding
		-- them in SoundService, which is the difference between a Studio iteration loop and a leak of
		-- one Sound per edit. See SoundManager.Reconfigure's own header.
		SoundManager.Reconfigure(name, pooled)
	else
		return name
	end

	registeredWeaponDefinitions[name] = pooled
	return name
end

-- Plays `weaponId`'s own sound for `slot` if it has one, and reports whether it did -- the single
-- "try the weapon first" step every play function below starts with.
local function playWeaponSlot(weaponId: string?, slot: string): boolean
	local name = ensureWeaponSound(weaponId, slot)
	if not name then
		return false
	end
	SoundManager.Play(name, jitteredSpeed())
	return true
end

-- Which weapon `character` currently has DRAWN, read off the Tool the server put in their hand. nil
-- when they are empty-handed or sheathed -- the Tool is destroyed on a sheath (see
-- Server/Combat/Weapon/WeaponVisualSystem.EquipVisual), so its absence is the answer rather than a
-- failed lookup.
--
-- The only cross-player weapon read available to a client, which is exactly why it exists here: see
-- this file's header on why a block sound must follow the DEFENDER's weapon and not the local player's.
-- Kept private rather than promoted to a shared helper because this is its one call site; a second
-- caller is when it earns a home of its own.
local function drawnWeaponIdOf(character: Instance?): string?
	if not character then
		return nil
	end
	local tool = character:FindFirstChild(WeaponConstants.Visual.ToolName)
	if not tool then
		return nil
	end
	local weaponId = tool:GetAttribute(WeaponConstants.Visual.WeaponIdAttribute)
	if typeof(weaponId) ~= "string" or weaponId == "" then
		return nil
	end
	return weaponId
end

-- Play functions -------------------------------------------------------------------------------------

-- The swing whoosh. `weaponId` is the sword that threw it (AttackStartedPayload.WeaponId) -- its own
-- SFX/Swing wins if it has one, and the shared per-kind whoosh answers otherwise.
--
-- THE WEAPON OVERRIDE IS GATED ON THE KIND HAVING A SHARED ENTRY, not consulted for every AttackKind.
-- CombatConstants.Sound.Swing deliberately covers only Basic/Heavy -- see its own header on why Hotbar
-- is absent rather than zeroed -- and "is this kind a weapon swing at all" is the same question both
-- layers are answering. Gating on that one table keeps it a single switch: the day Hotbar earns a
-- shared entry it opts into weapon overrides at the same moment, rather than needing a second list here
-- that could quietly disagree with the first.
function CombatAudio.PlaySwing(kind: AttackKind, weaponId: string?): ()
	local name = SWING_SOUND_NAMES[kind]
	if not name then
		return
	end
	if playWeaponSlot(weaponId, SLOTS.Swing) then
		return
	end
	SoundManager.Play(name, jitteredSpeed())
end

-- The landed-contact stinger. `outcomeKind` is keyed the same way
-- Client/Combat/CombatFeedbackClient.lua's own shakeFor already indexes
-- AttackConstants.Presentation.ShakePresets -- an outcome this module has no entry for (a future
-- OutcomeKind added upstream with nothing registered for it yet) degrades to silence rather than an
-- error, the identical "a missing preset degrades to no shake, never to a wrong hit" rule
-- Constants.FX's own header states for CameraShake.
--
-- `defender` is the character that was hit, straight off the same payload -- passed as the MODEL rather
-- than as a resolved weapon id so the caller stays out of the business of knowing that a drawn weapon is
-- discoverable through a Tool attribute at all. Only consulted for the two outcomes a weapon can speak
-- for (IMPACT_WEAPON_SLOTS); everything else goes straight to the shared stinger, and so does a defender
-- who was blocking bare-handed.
function CombatAudio.PlayImpact(outcomeKind: OutcomeKind, defender: Instance?): ()
	local slot = IMPACT_WEAPON_SLOTS[outcomeKind]
	if slot and playWeaponSlot(drawnWeaponIdOf(defender), slot) then
		return
	end
	local name = IMPACT_SOUND_NAMES[outcomeKind]
	if not name then
		return
	end
	SoundManager.Play(name, jitteredSpeed())
end

-- Draw and sheathe. NO SHARED FALLBACK, unlike the two above, and that asymmetry is the honest one: a
-- swing and an impact happen whether or not a weapon is involved (fists swing, bodies take hits), so
-- both need a weapon-agnostic answer. Drawing has no unarmed equivalent to fall back TO -- there is
-- nothing in CombatConstants.Sound describing "the sound of pulling out a weapon in general", and
-- inventing a shared one would be a placeholder standing in for content that belongs on the model.
-- A weapon with no SFX/Equip is simply drawn in silence, exactly as a weapon with no Animations/IDLE
-- stands in Roblox's own default idle.
function CombatAudio.PlayEquip(weaponId: string?): ()
	playWeaponSlot(weaponId, SLOTS.Equip)
end

function CombatAudio.PlaySheathe(weaponId: string?): ()
	playWeaponSlot(weaponId, SLOTS.Sheathe)
end

-- Lifecycle -------------------------------------------------------------------------------------------

local started = false
local attackStartedDisconnect: (() -> ())? = nil
local inventoryConnection: RBXScriptConnection? = nil

-- The last inventory state this client was told about, so a push can be read as a TRANSITION (a draw,
-- a sheathe) rather than as a state. The remote carries only "here is the whole inventory now" and is
-- re-pushed on pickup, draw, sheath, select AND every character bind, so without this pair a respawn
-- would be indistinguishable from putting a sword away.
local lastDrawn = false
local lastSelected: string? = nil

-- SCHEDULED AGAINST THE SWING'S OWN WINDUP, exactly like Client/Combat/SwingLunge.lua's own step --
-- see that file's header for the fuller argument, which applies unchanged here: a sound fired on the
-- frame the button goes down plays before the arm has moved at all, which reads as detached from the
-- swing rather than as part of it. windupSeconds comes off the payload (the value the server actually
-- scheduled for THIS swing, which may have come from the clip's own marker rather than a hand-typed
-- constant -- see AttackStartedPayload's own header) plus the per-kind SwingDelaySeconds offset,
-- through DelayFor's shared floor-at-zero math.
--
-- A plain task.delay rather than SwingLunge's own re-derived-every-frame Window: that shape earns its
-- keep there because a step is continuous state a NEW swing must be able to replace outright (see its
-- header). A sound is a discrete, one-shot event -- a second swing's windup finishing while the first
-- swing's sound is still pending should still play BOTH, not silently drop the first one, so there is
-- nothing here for a newer swing to need to cancel.
--
-- WeaponId is captured off the payload and carried into the delayed call rather than re-read when it
-- fires: the weapon that threw this swing is a fact about the swing, and a player who swaps during the
-- windup should still hear the sword they actually swung.
local function onAttackStarted(payload: AttackTypes.AttackStartedPayload): ()
	local windupSeconds = if typeof(payload.WindupSeconds) == "number" then payload.WindupSeconds else 0
	local weaponId = if typeof(payload.WeaponId) == "string" then payload.WeaponId else nil
	local delaySeconds = SwingLunge.DelayFor(windupSeconds, SWING_DELAY[payload.Kind] or 0)
	if delaySeconds <= 0 then
		CombatAudio.PlaySwing(payload.Kind, weaponId)
		return
	end
	task.delay(delaySeconds, function()
		CombatAudio.PlaySwing(payload.Kind, weaponId)
	end)
end

-- Turns the server's whole-inventory push into the two edges that make a sound.
--
-- ASYMMETRIC ON PURPOSE, and this is the part worth reading before changing it. A draw plays whenever
-- Drawn arrives true and was not true before -- including from the "we have no idea yet" state a fresh
-- session or a fresh life starts in -- while a sheathe plays ONLY on a known true -> false edge. The
-- reason is the character-bind push: the server re-sends the full payload with Drawn = false every time
-- a player spawns, so a symmetric reading would sheathe a weapon on every respawn that followed a death
-- mid-fight. Resetting the record per life (below) fixes that, and the asymmetry makes the fix safe
-- against losing the race: if a reset lands AFTER the bind push rather than before it, the worst case is
-- a draw that still plays, never one that is silently swallowed.
--
-- A SWAP WHILE DRAWN (Selected changes, Drawn stays true) is treated as a draw of the new weapon and
-- nothing else -- the player is looking at a different sword in their hand, and that is the sound of
-- that. No sheathe for the old one: the two would land on the same frame and read as one muddled noise
-- rather than as two gestures.
local function onInventoryChanged(raw: unknown): ()
	if typeof(raw) ~= "table" then
		return
	end
	local payload = raw :: WeaponConstants.InventoryPayload
	if typeof(payload.Drawn) ~= "boolean" then
		return
	end
	local selected = if typeof(payload.Selected) == "string" then payload.Selected else nil

	if payload.Drawn then
		if not lastDrawn or selected ~= lastSelected then
			CombatAudio.PlayEquip(selected)
		end
	elseif lastDrawn then
		-- The weapon being PUT AWAY is the one that was out, which the payload no longer names once it
		-- is sheathed -- lastSelected is the only record of it.
		CombatAudio.PlaySheathe(lastSelected)
	end

	lastDrawn = payload.Drawn
	lastSelected = selected
end

-- Subscribes to Attack_Started for the swing whoosh and to Weapon_InventoryChanged for the draw/sheathe
-- gestures -- see this file's header for why this module keeps its own subscriptions rather than being
-- called out to, unlike PlayImpact. Idempotent, the same shape Client/Combat/SwingLunge.lua's own
-- Start/Stop pair uses for the identical event.
function CombatAudio.Start(): ()
	if started then
		return
	end
	started = true
	attackStartedDisconnect = AttackInputClient.OnAttackStarted(onAttackStarted)

	local inventoryRemote = NetworkBridge.GetRemoteEvent(WeaponConstants.Network.RemoteNames.InventoryChanged)
	inventoryConnection = inventoryRemote.OnClientEvent:Connect(onInventoryChanged)

	-- A new life starts sheathed and empty-handed, so the record has to start there too -- see
	-- onInventoryChanged's own header on why this reset exists and why losing its race with the bind
	-- push is harmless. Routed through Shared/PlayerLifecycle.lua rather than a bare CharacterAdded
	-- connect, for one shape rather than sixteen; the Humanoid wait it adds is irrelevant here and
	-- costs nothing.
	PlayerLifecycle.BindLocalCharacter({
		Scope = "CombatAudio",
		OnCharacter = function()
			lastDrawn = false
			lastSelected = nil
		end,
	})

	logger:debug("CombatAudio started")
end

function CombatAudio.Stop(): ()
	if not started then
		return
	end
	started = false
	if attackStartedDisconnect then
		attackStartedDisconnect()
		attackStartedDisconnect = nil
	end
	if inventoryConnection then
		inventoryConnection:Disconnect()
		inventoryConnection = nil
	end
end

return CombatAudio
