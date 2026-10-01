--!strict
--[[
	CombatFeedbackClient.lua

	Owns: turning DamageSystem's Combat_Feedback event into something the local player can actually
	see and feel -- a camera shake scaled to the outcome, a floating damage number at the contact, the
	impact sound, sparks and freeze.

	NO OUTCOME BANNER ANY MORE (PARRIED / BLOCKED / GUARD BROKEN text). It was the single most expensive
	step of handling a hit -- 1.6-2.7ms of script per resolved contact, measured by the per-hit breakdown
	below, several times the rest combined -- and it said what the sound, the sparks and the shake
	already say.

	THE ONE THING THAT MAKES THE COMBAT STACK LEGIBLE. Everything below it works today with no visible
	trace: HitboxEngine finds a contact, DefenseSystem classifies it, DamageSystem applies it, and
	from the player's seat a successful parry and a clean hit look identical. This module is the
	difference between a combat system that is correct and one a player can learn.

	READS ONE EVENT AND DECIDES NOTHING. Combat_Feedback fires once per RESOLVED contact, to both
	participants, carrying the outcome, the amounts, the combo stage, the move and the contact
	position (DamageTypes.CombatFeedback). Everything in it is already decided by the time it leaves
	the server -- there is nothing here a client could act on to change an outcome, which is exactly
	why the payload is safe to hand a client at all.

	ROLE COMES FROM THE SERVER, not from comparing character models. The same event is delivered to
	two different players and means something different to each, so DamageTypes.CombatFeedback carries
	a Role field rather than leaving every client to re-derive it -- see that type's own header. This
	module honours that: the attacker's cues and the defender's cues are two separate tables in
	AttackConstants.Presentation.ShakePresets, and being hit is always the louder of the pair.

	DAMAGE NUMBERS ARE ATTACKER-SIDE ONLY. A number floating off the thing you hit is information; the
	same number floating off yourself while your own health bar is already dropping is the same fact
	twice. The defender's feedback is the health bar, the shake and the impact sound.

	CONTACT POSITION IS PROJECTED HERE, per frame of the hit, not carried as a screen position: a
	world position is what the server can honestly know, and turning it into a UDim2 is a camera
	question ("client owns feel"). A contact behind the camera projects to nothing and simply falls
	back to a centred number rather than drawing off-screen.

	TWO VARIANTS RIDE ON TOP OF THE OUTCOME KIND, both flagged by the server on the payload rather than
	being kinds of their own (the server's vocabulary stays the seven OutcomeKinds):
	  * Perfect (a Parried contact inside DefenseConstants.PerfectParry's first 50ms) -- a longer clash
	    freeze, the PerfectParry shake, a harder camera punch, a denser burst and a brighter ring. See
	    VARIANTS below.
	  * GuardCracking (a Blocked contact that left the guard under DefenseConstants.GuardCrack) -- hotter,
	    heavier sparks and a lower strained clang. The strained pose itself is not here -- it is on every
	    client, off the replicated tag (Client/FX/GuardStrainPose.lua).

	A MOVE MAY RESHAPE ALL OF IT (2026-09-30). The attacking move's Hit cue for the outcome
	(Shared/Combat/MovePresentationTypes.lua -- HitClean ... HitEvaded, HitPerfectParry for the Perfect
	variant) is resolved ONCE per contact (MovePresentation.CueFor, off payload.MoveId) and handed to each
	step below, which lays it over its own default: the shake preset and scale, the stinger (CombatAudio's
	move > weapon > shared precedence), the flash colour, the spark burst and its punch, the exchange
	freeze and an authored template at the contact. No cue is exactly the behaviour before it existed.
	Only the COSMETIC steps read it (PresentHit): the victim's movement freeze, the knockback launch, the
	cancelled swing and the damage number mirror what the server already decided, and a move's
	presentation must never reach them. PresentHit is exported so the Move Editor's per-moment Preview
	plays a hit through this exact path rather than an editor-only copy of it.

	Does not own: the surfaces themselves (Client/UI/Screens/CombatFeedback), the shake compositor
	(Client/FX/CameraShake.lua) or the FOV compositor (Client/FX/FOVOffset.lua), the press-side cue
	(Client/Combat/AttackInputClient.lua), or the HUD's own vitals (Client/UI/State/ClientState.lua
	reflects those from their own sources).

	ALSO OWNS the two other per-resolution cues that read off this same event, alongside the shake:
	CombatAudio.PlayImpact (the landed-contact stinger) and HitFlash.Flash (the victim's pooled-Highlight
	pop). Both are pure, domain-agnostic FX primitives -- see their own headers -- and this module is
	where DefenseTypes.OutcomeKind gets turned into "which sound" and "which color" for both of them,
	the same way it already turns Kind into "which shake preset." One place answering what an outcome
	MEANS, not three FX modules each re-deriving it.

	PlayImpact is handed payload.Defender along with the outcome, because a Blocked/Parried result is
	made by a WEAPON and should sound like the specific one that made it -- CombatAudio resolves the
	defender's drawn weapon and reaches for its own SFX/Block or SFX/Parry, falling back to the shared
	per-outcome stinger for a bare-handed guard or a weapon that authored none. Deliberately the
	defender's and not the local player's: this event reaches BOTH participants (that is what Role is
	for), so "my weapon" would be the wrong answer on the attacker's machine and the two clients would
	hear two different swords for one clang. This module supplies the participant; deciding what to do
	with it stays inside the audio module, the same division of labour flashFor already keeps with
	HitFlash.

	AND NOW A FOURTH: the combat hit-stop, in two halves. HitStop.FreezeExchange freezes the playing
	animation of BOTH combatants on EVERY role's client (Clean/Backstab/GuardBroken, plus Parried as a
	clash freeze, plus HeavyBonusSeconds for a Heavy move) -- the shared "the hit landed" stop.
	HitStop.FreezeVictimMovement is DEFENDER-ONLY and stops the local body in place; it is fired for
	exactly the three outcomes that grant
	DamageConstants.Hitstun server-side (Clean, Backstab, GuardBroken): the freeze is a cosmetic stinger
	riding alongside a lockout that is already real and already server-enforced (DamageSystem.CanAttack),
	never a new source of truth about whether the victim is stunned. THIS is the module that has to fire
	it rather than some new subscriber, because Role already answers the one question a freeze trigger
	needs ("was this client the one hit") that a second listener on the same event would otherwise have
	to re-derive.

	A FIFTH, gated identically to the fourth: AttackInputClient.CancelSwing, which cuts this client's OWN
	in-flight swing animation short the instant a landed hit puts its owner into real hitstun.
	DamageSystem.applyOutcome already cancels that same swing SERVER-SIDE on the same three outcomes
	(cancelSwingOf -> HitboxEngine.CancelAttack), but that cancellation has no remote of its own -- this
	is the first (and, today, only) place a defender's own client learns its swing was just cut short,
	so it is the only place that can also tell AttackInputClient to stop showing it. Reuses
	FREEZE_SECONDS_BY_KIND as its own gate rather than a second hand-written kind list: "does this
	outcome grant real hitstun" is one question, and the freeze above already answers it correctly.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AttackConstants = require(ReplicatedStorage.Shared.Attack.AttackConstants)
local CombatConstants = require(ReplicatedStorage.Shared.Combat.CombatConstants)
local Constants = require(ReplicatedStorage.Shared.Constants)
local DamageConstants = require(ReplicatedStorage.Shared.Damage.DamageConstants)
local DamageTypes = require(ReplicatedStorage.Shared.Damage.DamageTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)
local MovePresentationTypes = require(ReplicatedStorage.Shared.Combat.MovePresentationTypes)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)

local AttackInputClient = require(script.Parent.AttackInputClient)
local LocalCombatState = require(script.Parent.LocalCombatState)
local KnockbackClient = require(script.Parent.KnockbackClient)
local AirComboFX = require(script.Parent.Parent.FX.AirComboFX)
local CameraShake = require(script.Parent.Parent.FX.CameraShake)
local CombatAudio = require(script.Parent.Parent.FX.CombatAudio)
local CombatFeedbackModule = require(script.Parent.Parent.UI.Screens.CombatFeedback)
local HitFlash = require(script.Parent.Parent.FX.HitFlash)
local HitStop = require(script.Parent.Parent.FX.HitStop)
local ImpactSparks = require(script.Parent.Parent.FX.ImpactSparks)
local MovePresentation = require(script.Parent.Parent.FX.MovePresentation)
local RollAfterimage = require(script.Parent.Parent.FX.RollAfterimage)

type CombatFeedback = DamageTypes.CombatFeedback
type Cue = MovePresentationTypes.Cue
type Handle = CombatFeedbackModule.CombatFeedbackHandle

local logger = Logger.scope("CombatFeedbackClient")

local CombatFeedbackClient = {}

local started = false
local handle: Handle? = nil

-- Combo depth at which a damage number switches to the heavier visual weight. Derived from the
-- escalation ceiling rather than authored separately, so retuning DamageConstants.Combo.MaxStage
-- moves this with it instead of leaving a threshold that outlives its own scale.
local HEAVY_COMBO_STAGE = math.max(math.ceil(DamageConstants.Combo.MaxStage / 2), 2)

-- The variant a payload is, or nil for a plain outcome. Doubles as the ImpactSparks preset key, so
-- "which variant is this" is answered once.
local function variantOf(payload: CombatFeedback): string?
	if payload.Kind == "Parried" and payload.Perfect == true then
		return "ParriedPerfect"
	end
	if payload.Kind == "Blocked" and payload.GuardCracking == true then
		return "BlockedCracking"
	end
	return nil
end

-- A variant's pitch on the impact stinger (CombatAudio.PlayImpact): a strained guard clangs lower, a
-- perfect parry rings higher. Presentation only, so it lives with the rest of this file's mapping.
local VARIANT_PITCH: { [string]: number } = {
	ParriedPerfect = 1.12,
	BlockedCracking = 0.82,
}

-- Which outcomes clear the damage-number stack when they land -- see the screen's own
-- SuppressDamageNumbers. A defensive result and a chip-damage number arriving together read as
-- contradictory feedback, and the parry sound and sparks own that moment.
local SUPPRESSES_DAMAGE_NUMBERS: { [string]: boolean } = {
	Parried = true,
	Trade = true,
}

-- Presentation -------------------------------------------------------------------------------------

local function shakeFor(payload: CombatFeedback, cue: Cue?): ()
	local table_ = if payload.Role == "Defender"
		then AttackConstants.Presentation.ShakePresets.Defender
		else AttackConstants.Presentation.ShakePresets.Attacker
	local presetName = if variantOf(payload) == "ParriedPerfect"
		then "PerfectParry"
		else table_[payload.Kind] or AttackConstants.Presentation.DefaultShakePreset
	-- Indexed rather than switched, so a preset renamed in Constants.FX is a nil (no shake) rather
	-- than a runtime error -- Constants.FX's own "a missing preset degrades to no shake, never to a
	-- wrong hit" rule, which CameraShake.Shake already tolerates on its own side too. A move's cue may
	-- name its own preset for both roles, scale this one, or say None.
	CameraShake.Shake(MovePresentation.Shake(cue, (Constants.FX.CameraShake :: any)[presetName]) :: any)
end

-- Which of Constants.FX.HitFlash's three named colors a resolution pops on the defender -- the same
-- "white = a plain hit, gold = a parry deflection, red-gold = a posture break" family that config's own
-- header describes. Fewer buckets than DefenseTypes.OutcomeKind has entries, deliberately: Backstab and
-- Trade already get their own answer through the shake presets and the impact sounds, so they read here
-- as "a plain hit" rather than earning a fourth/fifth color with nothing else to distinguish it by.
local HIT_FLASH_COLORS: { [string]: Color3 } = {
	Clean = Constants.FX.HitFlash.HitColor,
	Blocked = Constants.FX.HitFlash.HitColor,
	Backstab = Constants.FX.HitFlash.HitColor,
	Trade = Constants.FX.HitFlash.HitColor,
	Parried = Constants.FX.HitFlash.ParryColor,
	GuardBroken = Constants.FX.HitFlash.PostureBreakColor,
}

-- Victim-only, per HitFlash's own header -- fired on outcome.Defender's body regardless of which
-- participant's client is running this, since a Highlight reads the same for both. Evaded is the one
-- OutcomeKind with no entry, deliberately: nothing touched the defender, and a hit-flash on a body the
-- swing went through would say it had.
local function flashFor(payload: CombatFeedback, cue: Cue?): ()
	local color = MovePresentation.FlashColor(cue, HIT_FLASH_COLORS[payload.Kind])
	if not color then
		return
	end
	HitFlash.Flash(payload.Defender, color)
end

-- How long the DEFENDER's own client freezes its body's movement on this outcome -- see
-- HitStop.lua's own header for what the freeze actually does and why it is movement rather than
-- animation. Deliberately the SAME three keys DamageResolver.AdvancesCombo/Resolve grant
-- DamageConstants.Hitstun for (Clean, Backstab, GuardBroken) and no others: Blocked, Parried and Trade
-- never stun the defender server-side, so freezing their movement on one of those would be a purely
-- cosmetic lie about a lockout that was never real.
--
-- Clean gets the base VictimSeconds; Backstab and GuardBroken share the heavier PostureBreakSeconds --
-- the same grouping ShakePresets.Defender above already draws between these three kinds, reused here
-- rather than re-derived so the two tables cannot quietly disagree about which outcomes read as
-- "heavier" to the player being hit.
local FREEZE_SECONDS_BY_KIND: { [string]: number } = {
	Clean = Constants.FX.HitStop.VictimSeconds,
	Backstab = Constants.FX.HitStop.PostureBreakSeconds,
	GuardBroken = Constants.FX.HitStop.PostureBreakSeconds,
}

-- Victim-only, unlike shakeFor/flashFor/CombatAudio.PlayImpact above which fire for both roles (or are
-- role-aware internally). Checked against payload.Role directly rather than against a Kind-only table
-- lookup, because an attacker's own client also receives this same Combat_Feedback event (with
-- Role == "Attacker") for the hit it just landed, and an attacker freezing their own movement on a
-- swing that connected would read as the game stuttering on a successful hit rather than as feedback.
local function freezeVictimFor(payload: CombatFeedback): ()
	if payload.Role ~= "Defender" then
		return
	end
	local seconds = FREEZE_SECONDS_BY_KIND[payload.Kind]
	if not seconds then
		return
	end
	HitStop.FreezeVictimMovement(seconds)
end

-- Victim-only, same shape and same gate as freezeVictimFor directly above -- see this file's header
-- for why FREEZE_SECONDS_BY_KIND is the right table to reuse rather than a second list of the same
-- three kinds. Stops this client's own in-flight swing animation (AttackInputClient.CancelSwing) the
-- instant this hit is one that put the LOCAL player into real, server-enforced hitstun -- see that
-- function's own header for why nothing else in this codebase ever tells that client its swing was
-- cut short otherwise.
-- The shared pose-freeze of a hit-stop, on BOTH roles' clients (unlike the movement freeze above):
-- the attacker's own body stopping on contact is half of what makes a hit feel heavy. Same outcome
-- table as the victim freeze, plus a clash-freeze on a parry, plus the tuned heavy bonus for a Heavy
-- move. See HitStop.FreezeExchange.
local EXCHANGE_SECONDS_BY_KIND: { [string]: number } = {
	Clean = Constants.FX.HitStop.VictimSeconds,
	Backstab = Constants.FX.HitStop.PostureBreakSeconds,
	GuardBroken = Constants.FX.HitStop.PostureBreakSeconds,
	Parried = Constants.FX.HitStop.ParrySeconds,
	-- Two swings meeting (DefenseConstants.Clash) is the same clash beat as a parry: both bodies stop,
	-- then both are shoved apart.
	Trade = Constants.FX.HitStop.ParrySeconds,
}

local function freezeExchangeFor(payload: CombatFeedback, cue: Cue?): ()
	local seconds = EXCHANGE_SECONDS_BY_KIND[payload.Kind]
	if seconds then
		if variantOf(payload) == "ParriedPerfect" then
			-- The perfect parry replaces the clash beat outright rather than adding to it: the whole
			-- exchange stops for PerfectParrySeconds, on both bodies, on both clients.
			seconds = Constants.FX.HitStop.PerfectParrySeconds
		elseif typeof(payload.MoveId) == "string" and string.find(payload.MoveId, ":Heavy:", 1, true) then
			seconds += Constants.FX.HitStop.HeavyBonusSeconds
		end
	end
	-- A move's authored freeze replaces the whole computed beat (0 is none). Pose only: the victim's
	-- movement freeze below mirrors real server hitstun and no cue reaches it.
	local resolved = MovePresentation.HitStopSeconds(cue, seconds)
	if not resolved or resolved <= 0 then
		return
	end
	HitStop.FreezeExchange(payload.Attacker, payload.Defender, resolved)
end

-- Victim-only, like the freeze above, and deliberately sequenced AFTER it: the launch the server put on
-- this Defender copy starts once the freeze this same event just began has run out, because the freeze
-- writes zero velocity every frame it holds and would erase a launch written any earlier. See
-- KnockbackClient.lua's header for the shape of the launch itself.
local function launchFor(payload: CombatFeedback): ()
	if payload.Role ~= "Defender" or typeof(payload.Knockback) ~= "Vector3" then
		return
	end
	KnockbackClient.Launch(payload.Knockback :: Vector3, FREEZE_SECONDS_BY_KIND[payload.Kind] or 0)
end

-- The spacing push (DamageConstants.Spacing), on EITHER role: the defender sliding back, the attacker
-- following a hit or rebounding off a block. Started after this client's freeze for the same reason as
-- the launch above -- the victim's movement freeze, or the exchange's pose freeze for the attacker.
local function pushFor(payload: CombatFeedback, cue: Cue?): ()
	if typeof(payload.Push) ~= "Vector3" or typeof(payload.Knockback) == "Vector3" then
		return
	end
	-- The attacker's push waits out the exchange freeze -- the move's own, when it authored one.
	-- A trade is even, so both sides wait out the same clash freeze before they part.
	local delay = if payload.Role == "Defender" and payload.Kind ~= "Trade"
		then FREEZE_SECONDS_BY_KIND[payload.Kind] or 0
		else MovePresentation.HitStopSeconds(cue, EXCHANGE_SECONDS_BY_KIND[payload.Kind]) or 0
	KnockbackClient.Push(payload.Push :: Vector3, delay)
end

-- Outcomes that cancel the ATTACKER's own swing server-side: DefenseSystem.applyContact calls
-- HitboxEngine.CancelAttack on a parried attacker ("Parried") and on both sides of a trade ("Traded") --
-- for a clash, on the DEFENDER's swing too, which cancelSwingFor handles on the Defender copy.
local ATTACKER_SWING_CANCELLED_BY_KIND: { [string]: boolean } = {
	Parried = true,
	Trade = true,
}

-- Keeps this client's own swing, and its record of being stunned, in step with what the server just
-- did to this player -- the local mirror Client/Combat/LocalCombatState.lua holds for the swing
-- prediction (AttackInputClient) and the held guard (DefenseClient).
local function cancelSwingFor(payload: CombatFeedback): ()
	if payload.Role == "Defender" then
		if payload.Kind == "Trade" then
			-- A clash cut this player's own swing as well as the attacker's (DefenseSystem.applyContact); no
			-- stun, so nothing is recorded -- the shared recovery arrives on Attack_Cancelled ("Traded").
			-- For a mutual parry this client was parrying, not swinging, and cutting nothing is a no-op.
			AttackInputClient.CancelSwing()
			return
		end
		if not FREEZE_SECONDS_BY_KIND[payload.Kind] then
			return
		end
		-- The same three kinds DamageResolver grants DamageConstants.Hitstun for -- recorded so no swing
		-- is predicted, and no guard animation started, while the server is refusing both. The length is
		-- the server's own for this contact (it varies by weapon); the shared one only covers an older server.
		local stun = if typeof(payload.HitstunSeconds) == "number"
			then payload.HitstunSeconds
			else DamageConstants.Hitstun.Seconds
		LocalCombatState.NoteHitstun(os.clock() + stun)
		-- And the body cannot simply walk out of the next swing while it is stunned (HitStop's header).
		HitStop.SlowVictimMovement(stun, CombatConstants.HitSlowMultiplier)
		AttackInputClient.CancelSwing()
	elseif ATTACKER_SWING_CANCELLED_BY_KIND[payload.Kind] then
		-- Without this a parried swing kept playing to its end on the attacker's screen while the
		-- server had already stopped it and staggered them.
		AttackInputClient.CancelSwing()
	elseif AttackConstants.HitConfirm.ConfirmKinds[payload.Kind] and typeof(payload.MoveId) == "string" then
		-- The swing LANDED: its recovery may now be cut into a follow-up (AttackConstants.HitConfirm).
		AttackInputClient.NoteHitConfirmed(payload.MoveId)
	end
end

-- Projects the world contact onto the screen. Returns nil when the contact is behind the camera or
-- there is no camera at all, which the caller treats as "put it in the middle" rather than as an
-- error -- DamageNumberLabel already defaults to centre for exactly this case.
local function screenPositionOf(contact: Vector3): UDim2?
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end
	local viewportPoint, onScreen = camera:WorldToViewportPoint(contact)
	if not onScreen then
		return nil
	end
	local viewport = camera.ViewportSize
	if viewport.X <= 0 or viewport.Y <= 0 then
		return nil
	end
	return UDim2.fromScale(viewportPoint.X / viewport.X, viewportPoint.Y / viewport.Y)
end

-- Which visual weight the number carries. Derived from the outcome and the combo depth rather than
-- from a raw damage threshold: a threshold would need retuning every time a move's authored damage
-- changed, where "this was a punish" and "this is deep into a string" stay true regardless.
local function damageKindFor(payload: CombatFeedback): "Normal" | "Heavy" | "Critical"
	if payload.Kind == "Backstab" or payload.Kind == "GuardBroken" then
		return "Critical"
	end
	if payload.ComboStage >= HEAVY_COMBO_STAGE then
		return "Heavy"
	end
	return "Normal"
end

-- PER-HIT COST BREAKDOWN (Constants.Debug.FpsCounter.HitCostLogMs). Every step of onFeedback runs
-- inside a MicroProfiler label and is timed; a hit whose script work passes the threshold logs what each
-- step cost, so "my frame rate drops when I get hit" points at a module rather than at a guess.
-- Script time only: a render cost (a Highlight, particles) lands in FpsCounter's frame spike log.
local HIT_COST_LOG_MS = Constants.Debug.FpsCounter.HitCostLogMs
local stepLabels: { string } = {}
local stepSeconds: { number } = {}

local function timed(label: string, fn: () -> ()): ()
	debug.profilebegin(label)
	local stepStartedAt = os.clock()
	fn()
	table.insert(stepLabels, label)
	table.insert(stepSeconds, os.clock() - stepStartedAt)
	debug.profileend()
end

local function reportHitCost(payload: CombatFeedback): ()
	local total = 0
	for _, seconds in stepSeconds do
		total += seconds
	end
	if total * 1000 >= HIT_COST_LOG_MS then
		local parts = table.create(#stepLabels)
		for index, label in stepLabels do
			table.insert(parts, `{label} {string.format("%.2f", stepSeconds[index] * 1000)}`)
		end
		logger:info("Hit feedback cost", {
			totalMs = string.format("%.2f", total * 1000),
			role = payload.Role,
			kind = payload.Kind,
			steps = table.concat(parts, " | "),
		})
	end
	table.clear(stepLabels)
	table.clear(stepSeconds)
end

-- The cue a contact plays: the attacking move's Hit cue for this outcome (and variant), or nil.
function CombatFeedbackClient.CueFor(payload: CombatFeedback): Cue?
	local moment = MovePresentationTypes.HitMomentFor(payload.Kind, payload.Perfect)
	return if moment then MovePresentation.CueFor(payload.MoveId, moment) else nil
end

-- The COSMETIC half of a resolved contact -- shake, stinger, flash, sparks, the exchange freeze and a
-- move's template -- with `cue` laid over each step's default (this file's header). Everything that
-- mirrors a server decision stays in onFeedback.
local function presentHit(payload: CombatFeedback, cue: Cue?): ()
	timed("Hit.Shake", function()
		shakeFor(payload, cue)
	end)
	timed("Hit.Audio", function()
		if payload.Kind == "Evaded" then
			-- A contact that never happened: no impact stinger, no hit-flash, no number (Damage is 0). The
			-- dodger hears the bright whiff and the attacker the muted one (CombatAudio.PlayEvaded), and
			-- BOTH see one bright ghost on the dodger's rig -- the swing went through where they were, and
			-- the attacker is the one who most needs to read that it did.
			CombatAudio.PlayEvaded(payload.Role == "Defender", cue, payload.ContactPosition)
			if typeof(payload.Defender) == "Instance" and payload.Defender:IsA("Model") then
				RollAfterimage.FlashEvade(payload.Defender)
			end
		else
			-- payload.Defender, not the local character: the block/parry sound belongs to the weapon that
			-- CAUGHT the swing, and this same event reaches the attacker's machine too -- see CombatAudio's
			-- own header. It resolves the weapon itself; this module hands it the participant and nothing
			-- more.
			local variant = variantOf(payload)
			CombatAudio.PlayImpact(
				payload.Kind,
				payload.Defender,
				if variant then VARIANT_PITCH[variant] else nil,
				cue,
				payload.ContactPosition
			)
		end
	end)
	timed("Hit.Flash", function()
		flashFor(payload, cue)
	end)
	-- Sparks at the blades for the steel-on-steel outcomes (parry, block, trade, guard break), and the
	-- parry's camera punch -- see ImpactSparks' own header. A body-only outcome has no preset and no-ops,
	-- unless the move's cue names one. The cue's own punch and template land at the same contact.
	timed("Hit.Sparks", function()
		if typeof(payload.ContactPosition) == "Vector3" then
			local preset, overrides = MovePresentation.Sparks(cue, variantOf(payload) or payload.Kind)
			if preset then
				ImpactSparks.Play(preset, payload.ContactPosition, overrides)
			end
			MovePresentation.PlayPunch(cue)
			MovePresentation.PlayTemplate(
				cue,
				CFrame.new(payload.ContactPosition),
				payload.MoveId,
				MovePresentationTypes.HitMomentFor(payload.Kind, payload.Perfect) or payload.Kind
			)
		end
	end)
	timed("Hit.FreezeExchange", function()
		freezeExchangeFor(payload, cue)
	end)
end

-- presentHit for the Move Editor's Preview, which hands it a local payload and the DRAFT's cue, so a
-- previewed hit takes this exact path. Its step timings are dropped rather than reported: a preview is
-- not a hit, and they would otherwise pad the next real hit's cost line.
function CombatFeedbackClient.PresentHit(payload: CombatFeedback, cue: Cue?): ()
	presentHit(payload, cue)
	table.clear(stepLabels)
	table.clear(stepSeconds)
end

-- Predicted hits -----------------------------------------------------------------------------------------
--
-- AttackConstants.Presentation.HitPrediction's header has the whole contract. Two small ledgers, keyed by
-- the defender: hits this client PREDICTED and is waiting on a verdict for, and verdicts that arrived
-- FIRST, so a prediction that fires late (the server was quicker, e.g. in Studio) never repeats one.

local HIT_PREDICTION = AttackConstants.Presentation.HitPrediction

type ContactRecord = { MoveId: string, At: number }

local predictedContacts: { [Model]: ContactRecord } = {}
local confirmedContacts: { [Model]: ContactRecord } = {}

local function matchesContact(record: ContactRecord?, moveId: string, now: number): boolean
	return record ~= nil and record.MoveId == moveId and now - record.At <= HIT_PREDICTION.MatchSeconds
end

-- Drops records past their match window, so a despawned body is never held by either ledger.
local function pruneContacts(ledger: { [Model]: ContactRecord }, now: number): ()
	for model, record in ledger do
		if now - record.At > HIT_PREDICTION.MatchSeconds then
			ledger[model] = nil
		end
	end
end

-- Plays the attacker's side of a Clean hit that has not been confirmed yet -- the thud, the flash, the
-- exchange freeze, the shake -- and records it so the server's matching verdict does not play it twice.
-- Returns whether it played (false when this contact was already presented, predicted or confirmed).
-- Client/Combat/HitPrediction.lua is the caller.
function CombatFeedbackClient.PresentPredictedHit(
	attacker: Model,
	defender: Model,
	contactPosition: Vector3,
	moveId: string
): boolean
	local now = os.clock()
	if
		matchesContact(confirmedContacts[defender], moveId, now)
		or matchesContact(predictedContacts[defender], moveId, now)
	then
		return false
	end
	pruneContacts(predictedContacts, now)
	predictedContacts[defender] = { MoveId = moveId, At = now }
	local payload: CombatFeedback = {
		Kind = "Clean",
		Role = "Attacker",
		Attacker = attacker,
		Defender = defender,
		Damage = 0,
		GuardDrain = 0,
		ComboStage = 0,
		MoveId = moveId,
		ContactPosition = contactPosition,
	}
	presentHit(payload, CombatFeedbackClient.CueFor(payload))
	return true
end

-- Whether this verdict's impact presentation was already played by a prediction. Only a Clean verdict
-- is skipped: a Backstab or GuardBroken is heavier than what was predicted, and a Blocked/Parried/Evaded
-- verdict contradicts it -- both play in full, which is what tells the attacker what really happened.
local function consumePrediction(payload: CombatFeedback): boolean
	if payload.Role ~= "Attacker" or typeof(payload.Defender) ~= "Instance" then
		return false
	end
	local defender = payload.Defender
	local now = os.clock()
	local predicted = matchesContact(predictedContacts[defender], payload.MoveId, now)
	if predicted then
		predictedContacts[defender] = nil
	end
	pruneContacts(confirmedContacts, now)
	confirmedContacts[defender] = { MoveId = payload.MoveId, At = now }
	return predicted and payload.Kind == "Clean"
end

local function onFeedback(raw: unknown): ()
	if typeof(raw) ~= "table" then
		return
	end
	local payload = raw :: CombatFeedback
	if typeof(payload.Kind) ~= "string" or typeof(payload.Damage) ~= "number" then
		return
	end

	debug.profilebegin("CombatFeedback")
	local cue = CombatFeedbackClient.CueFor(payload)
	if not consumePrediction(payload) then
		presentHit(payload, cue)
	end
	-- The air combo's weight on top of the ordinary hit presentation: a camera punch per air hit, the
	-- finisher hardest, and the air parry's own clash (docs/design/air-combat-and-evade.md B4).
	if payload.AirCombo ~= nil then
		timed("Hit.AirCombo", function()
			AirComboFX.OnFeedback(payload)
		end)
	end
	timed("Hit.FreezeVictim", function()
		freezeVictimFor(payload)
	end)
	timed("Hit.Knockback", function()
		launchFor(payload)
		pushFor(payload, cue)
	end)
	timed("Hit.CancelSwing", function()
		cancelSwingFor(payload)
	end)

	timed("Hit.DamageNumbers", function()
		local surfaces = handle
		if surfaces then
			if SUPPRESSES_DAMAGE_NUMBERS[payload.Kind] then
				surfaces.SuppressDamageNumbers(AttackConstants.Presentation.OutcomeTextSeconds)
			elseif payload.Role == "Attacker" and payload.Damage > 0 then
				surfaces.AddDamageHit({
					Amount = payload.Damage,
					Kind = damageKindFor(payload),
					Position = screenPositionOf(payload.ContactPosition),
				})
			end
		end
	end)

	debug.profileend()
	reportHitCost(payload)
end

-- Lifecycle -----------------------------------------------------------------------------------------

-- `feedbackHandle` is the CombatFeedback screen's own handle, from UI.Mount(). Passed in rather than
-- looked up so this module never reaches into the UI tree -- the same shape every other
-- screen-driving client module in this codebase keeps (DevMenuClient, BugReportClient,
-- AnnouncementClient).
function CombatFeedbackClient.Start(feedbackHandle: Handle): ()
	if started then
		return
	end
	started = true
	handle = feedbackHandle

	local remote = NetworkBridge.GetRemoteEvent(DamageConstants.Network.RemoteNames.Feedback)
	remote.OnClientEvent:Connect(onFeedback)

	logger:info("CombatFeedbackClient started")
end

return CombatFeedbackClient
