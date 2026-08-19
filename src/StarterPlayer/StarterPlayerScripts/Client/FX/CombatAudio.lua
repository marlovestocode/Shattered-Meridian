--!strict
--[[
	CombatAudio.lua

	Owns: combat's sound registrations and the verb-named play functions its two callers use -- the
	same "domain module owns WHICH sounds exist and gives them a typed API" shape Client/FX/RunAudio.lua
	and Client/FX/FlightAudio.lua already establish. Definitions come from CombatConstants.Sound (empty
	SoundId placeholders until real assets are supplied -- SoundManager.Play already no-ops safely on
	those, the same convention Constants.Flight.Sound and Constants.Run.Footsteps.Stages ship with).

	RESTORED, NOT NEW. This module (and CombatConstants.Sound) existed before the combat rewrite --
	SoundManager.lua's own header still credits it as the thing that pattern was generalized FROM
	("originally hand-rolled for a single sound (BlockImpact)") -- and was deleted alongside the rest of
	CombatSystem.lua/CombatClient.lua. Every other FX module in this folder that mentions it
	(SoundManager.lua, RunAudio.lua, FlightAudio.lua, Client/Loading/AssetPreloader.lua,
	Client/Main.client.lua) kept referring to it as a living sibling the whole time it was gone. This
	rebuild is that reference finally made true again, covering the full outcome set a resolved contact
	can carry rather than one flat "hit" sound.

	NEVER GUESSES AN ASSET ID. Every SoundId in CombatConstants.Sound is "" today -- there is no
	uploaded swing/impact/parry/guard-break sound anywhere in this codebase (checked: the only two real
	sound ids in the whole tree are Constants.Run's footstep/whoosh assets, which are tightly sliced via
	PlaybackRegion to that specific recording's layout and would be a hidden coupling to repurpose here,
	not a generic whoosh). So this module is fully wired -- registered, hooked, silent -- until real
	assets are pasted into CombatConstants.Sound, the same wired-but-unauthored state
	AttackCatalogEntry.AnimationId and CombatConstants.AnimationIds.RunningStage3 already ship in.
	SoundManager.Register already warns rather than errors on a blank id, and Play already no-ops on
	one, so there is nothing here to break by shipping ahead of the assets.

	TWO HOOK POINTS, TWO SHAPES, both mirroring an existing precedent rather than inventing a third:

	  * PlaySwing is driven from THIS module's own Attack_Started subscription
	    (AttackInputClient.OnAttackStarted), started/stopped exactly like Client/Combat/SwingLunge.lua
	    already does for the same event -- "hook off Attack_Started" means "subscribe the way SwingLunge
	    subscribes," not "have AttackInputClient call out to a fourth presentation module directly."
	    RunAudio/FlightAudio need no such subscription of their own because their callers (RunController,
	    FlightController) already own a per-frame loop that calls their Play functions directly; combat's
	    swing moment has no equivalent per-frame owner, so this module owns its own edge instead. The
	    subscriber (onAttackStarted below) does not call PlaySwing immediately -- it schedules it against
	    the swing's own windup (CombatConstants.Sound.SwingDelaySeconds, via SwingLunge.DelayFor) so the
	    sound lands when the arm actually swings forward, not on the frame the button went down.

	  * PlayImpact has NO subscription of its own -- Client/Combat/CombatFeedbackClient.lua's own
	    onFeedback calls it directly, parallel to that function's existing shakeFor call, both keyed off
	    the same DefenseTypes.OutcomeKind the shake presets already use. Combat_Feedback already has
	    exactly one subscriber by design (see that module's own header), and a second Connect from here
	    would just be a second, competing place deciding what a resolved contact means.

	Pitch jitter (CombatConstants.Sound.PitchJitter) is applied per play, the identical "a fixed
	sample replayed on every hit reads as a metronome" fix Client/FX/RunAudio.lua's own PitchJitter
	documents.

	Does not own: WHEN an attack starts or a contact resolves (AttackInputClient/CombatFeedbackClient
	decide that, this module only reacts), the camera shake or damage numbers that accompany the same
	moments (CameraShake.lua, Client/UI/Screens/CombatFeedback), or the Sound-instance mechanics
	(SoundManager.lua). Purely local presentation; nothing here crosses the network or affects an
	outcome.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AttackTypes = require(ReplicatedStorage.Shared.Attack.AttackTypes)
local CombatConstants = require(ReplicatedStorage.Shared.Combat.CombatConstants)
local DefenseTypes = require(ReplicatedStorage.Shared.Defense.DefenseTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)

local SoundManager = require(script.Parent.SoundManager)
local AttackInputClient = require(script.Parent.Parent.Combat.AttackInputClient)
-- Reused for exactly one function, DelayFor(windupSeconds, delaySeconds) -- see this file's own
-- onAttackStarted for why the swing sound schedules against the same windup the lunge step does,
-- through the identical pure formula rather than a second copy of it.
local SwingLunge = require(script.Parent.Parent.Combat.SwingLunge)

type AttackKind = AttackTypes.AttackKind
type OutcomeKind = DefenseTypes.OutcomeKind

local logger = Logger.scope("CombatAudio")

local CombatAudio = {}

local SOUND_CONFIG = CombatConstants.Sound
local PITCH_JITTER = SOUND_CONFIG.PitchJitter
local SWING_DELAY = SOUND_CONFIG.SwingDelaySeconds

-- One shared generator, the same isolation reasoning Client/FX/RunAudio.lua's own `random` upvalue
-- documents: combat's pitch jitter must never perturb, or be perturbed by, an unrelated caller's draw
-- from math.random's global state.
local random = Random.new()

-- Registered at load -- what puts these in SoundManager.GetPreloadInstances, which
-- Client/Loading/AssetPreloader.lua sweeps at boot (once real assets exist) so the first swing/impact
-- of a session doesn't pay CDN streaming latency mid-fight.
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

local function jitteredSpeed(): number
	if PITCH_JITTER <= 0 then
		return 1
	end
	return 1 + random:NextNumber(-PITCH_JITTER, PITCH_JITTER)
end

-- The swing whoosh. Silent for Hotbar (and for any AttackKind added later with no entry in
-- CombatConstants.Sound.Swing) rather than borrowing Basic's -- the same "this move does not step"
-- silence Client/Combat/SwingLunge.lua's own onAttackStarted documents for the identical gap, not a
-- fallback to guess at.
function CombatAudio.PlaySwing(kind: AttackKind): ()
	local name = SWING_SOUND_NAMES[kind]
	if not name then
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
function CombatAudio.PlayImpact(outcomeKind: OutcomeKind): ()
	local name = IMPACT_SOUND_NAMES[outcomeKind]
	if not name then
		return
	end
	SoundManager.Play(name, jitteredSpeed())
end

-- Lifecycle -------------------------------------------------------------------------------------------

local started = false
local attackStartedDisconnect: (() -> ())? = nil

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
local function onAttackStarted(payload: AttackTypes.AttackStartedPayload): ()
	local windupSeconds = if typeof(payload.WindupSeconds) == "number" then payload.WindupSeconds else 0
	local delaySeconds = SwingLunge.DelayFor(windupSeconds, SWING_DELAY[payload.Kind] or 0)
	if delaySeconds <= 0 then
		CombatAudio.PlaySwing(payload.Kind)
		return
	end
	task.delay(delaySeconds, function()
		CombatAudio.PlaySwing(payload.Kind)
	end)
end

-- Subscribes to Attack_Started for the swing whoosh -- see this file's header for why this module
-- keeps its own subscription rather than being called out to, unlike PlayImpact above. Idempotent, the
-- same shape Client/Combat/SwingLunge.lua's own Start/Stop pair uses for the identical event.
function CombatAudio.Start(): ()
	if started then
		return
	end
	started = true
	attackStartedDisconnect = AttackInputClient.OnAttackStarted(onAttackStarted)
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
end

return CombatAudio
