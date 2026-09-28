--!strict
--[[
	CombatFeedbackClient.lua

	Owns: turning DamageSystem's Combat_Feedback event into something the local player can actually
	see and feel -- a camera shake scaled to the outcome, a floating damage number at the contact, and
	a banner for the outcomes a player must not miss (PARRIED, GUARD BROKEN, BACKSTAB).

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
	twice. The defender's feedback is the health bar, the shake and the banner.

	CONTACT POSITION IS PROJECTED HERE, per frame of the hit, not carried as a screen position: a
	world position is what the server can honestly know, and turning it into a UDim2 is a camera
	question ("client owns feel"). A contact behind the camera projects to nothing and simply falls
	back to a centred number rather than drawing off-screen.

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
local Constants = require(ReplicatedStorage.Shared.Constants)
local DamageConstants = require(ReplicatedStorage.Shared.Damage.DamageConstants)
local DamageTypes = require(ReplicatedStorage.Shared.Damage.DamageTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)

local AttackInputClient = require(script.Parent.AttackInputClient)
local LocalCombatState = require(script.Parent.LocalCombatState)
local KnockbackClient = require(script.Parent.KnockbackClient)
local CameraShake = require(script.Parent.Parent.FX.CameraShake)
local CombatAudio = require(script.Parent.Parent.FX.CombatAudio)
local CombatFeedbackModule = require(script.Parent.Parent.UI.Screens.CombatFeedback)
local HitFlash = require(script.Parent.Parent.FX.HitFlash)
local HitStop = require(script.Parent.Parent.FX.HitStop)
local Tokens = require(script.Parent.Parent.UI.Tokens)

type CombatFeedback = DamageTypes.CombatFeedback
type Handle = CombatFeedbackModule.CombatFeedbackHandle

local logger = Logger.scope("CombatFeedbackClient")

local CombatFeedbackClient = {}

local started = false
local handle: Handle? = nil

-- Bumped on every banner so a stale clear timer cannot cut a fresher banner short -- the same
-- generation guard HUD's own tier-promotion pulse uses, for the same reason.
local outcomeGeneration = 0

-- Combo depth at which a damage number switches to the heavier visual weight. Derived from the
-- escalation ceiling rather than authored separately, so retuning DamageConstants.Combo.MaxStage
-- moves this with it instead of leaving a threshold that outlives its own scale.
local HEAVY_COMBO_STAGE = math.max(math.ceil(DamageConstants.Combo.MaxStage / 2), 2)

-- The outcomes that get a banner, and what it says. Deliberately NOT every outcome: a Clean hit is
-- already fully described by the damage number and the shake, and banner-ing the common case would
-- train players to ignore the banner exactly when an uncommon one needs reading.
--
-- Blocked appears for the DEFENDER only (see bannerFor below) -- "your block worked" is worth saying
-- to the person who pressed the button, while "they blocked" is already obvious to an attacker whose
-- damage number never appeared.
local BANNER_TEXT: { [string]: { Title: string, AttackerSubtitle: string, DefenderSubtitle: string, Color: Color3 } } =
	{
		Parried = {
			Title = "PARRIED",
			AttackerSubtitle = "Your swing was turned aside",
			DefenderSubtitle = "Perfect timing",
			Color = Tokens.Color.AccentPrimaryBright,
		},
		GuardBroken = {
			Title = "GUARD BROKEN",
			AttackerSubtitle = "Their guard is gone",
			DefenderSubtitle = "Your guard is gone",
			Color = Tokens.Color.Danger,
		},
		Backstab = {
			Title = "BACKSTAB",
			AttackerSubtitle = "Caught them from behind",
			DefenderSubtitle = "Caught from behind",
			Color = Tokens.Color.Danger,
		},
		Trade = {
			Title = "TRADE",
			AttackerSubtitle = "Both swings landed",
			DefenderSubtitle = "Both swings landed",
			Color = Tokens.Color.Warning,
		},
		Blocked = {
			Title = "BLOCKED",
			AttackerSubtitle = "",
			DefenderSubtitle = "Guard held",
			Color = Tokens.VitalColor.Posture,
		},
	}

-- Which outcomes clear the damage-number stack when they land -- see the screen's own
-- SuppressDamageNumbers. A defensive result and a chip-damage number arriving together read as
-- contradictory feedback, and the banner owns that moment.
local SUPPRESSES_DAMAGE_NUMBERS: { [string]: boolean } = {
	Parried = true,
	Trade = true,
}

-- Presentation -------------------------------------------------------------------------------------

local function shakeFor(payload: CombatFeedback): ()
	local table_ = if payload.Role == "Defender"
		then AttackConstants.Presentation.ShakePresets.Defender
		else AttackConstants.Presentation.ShakePresets.Attacker
	local presetName = table_[payload.Kind] or AttackConstants.Presentation.DefaultShakePreset
	-- Indexed rather than switched, so a preset renamed in Constants.FX is a nil (no shake) rather
	-- than a runtime error -- Constants.FX's own "a missing preset degrades to no shake, never to a
	-- wrong hit" rule, which CameraShake.Shake already tolerates on its own side too.
	CameraShake.Shake((Constants.FX.CameraShake :: any)[presetName])
end

-- Which of Constants.FX.HitFlash's three named colors a resolution pops on the defender -- the same
-- "white = a plain hit, gold = a parry deflection, red-gold = a posture break" family that config's own
-- header describes. Fewer buckets than DefenseTypes.OutcomeKind has entries, deliberately: Backstab and
-- Trade already get their own answer through the shake presets and the banner above, so they read here
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
local function flashFor(payload: CombatFeedback): ()
	local color = HIT_FLASH_COLORS[payload.Kind]
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
}

local function freezeExchangeFor(payload: CombatFeedback): ()
	local seconds = EXCHANGE_SECONDS_BY_KIND[payload.Kind]
	if not seconds then
		return
	end
	if typeof(payload.MoveId) == "string" and string.find(payload.MoveId, ":Heavy:", 1, true) then
		seconds += Constants.FX.HitStop.HeavyBonusSeconds
	end
	HitStop.FreezeExchange(payload.Attacker, payload.Defender, seconds)
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

-- Outcomes that cancel the ATTACKER's own swing server-side: DefenseSystem.applyContact calls
-- HitboxEngine.CancelAttack on a parried attacker ("Parried") and on both sides of a trade ("Traded").
local ATTACKER_SWING_CANCELLED_BY_KIND: { [string]: boolean } = {
	Parried = true,
	Trade = true,
}

-- Keeps this client's own swing, and its record of being stunned, in step with what the server just
-- did to this player -- the local mirror Client/Combat/LocalCombatState.lua holds for the swing
-- prediction (AttackInputClient) and the held guard (DefenseClient).
local function cancelSwingFor(payload: CombatFeedback): ()
	if payload.Role == "Defender" then
		if not FREEZE_SECONDS_BY_KIND[payload.Kind] then
			return
		end
		-- The same three kinds DamageResolver grants DamageConstants.Hitstun for -- recorded so no swing
		-- is predicted, and no guard animation started, while the server is refusing both.
		LocalCombatState.NoteHitstun(os.clock() + DamageConstants.Hitstun.Seconds)
		AttackInputClient.CancelSwing()
	elseif ATTACKER_SWING_CANCELLED_BY_KIND[payload.Kind] then
		-- Without this a parried swing kept playing to its end on the attacker's screen while the
		-- server had already stopped it and staggered them.
		AttackInputClient.CancelSwing()
	end
end

-- The attacker's landed combo depth rides on every Combat_Feedback it receives, and the swing
-- prediction needs it to know when the Basic string tips into the Finisher.
local function noteComboFor(payload: CombatFeedback): ()
	if payload.Role == "Attacker" and typeof(payload.ComboStage) == "number" then
		AttackInputClient.NoteLandedCombo(payload.ComboStage)
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

local function showBanner(payload: CombatFeedback): ()
	local surfaces = handle
	if not surfaces then
		return
	end
	local text = BANNER_TEXT[payload.Kind]
	if not text then
		return
	end

	local subtitle = if payload.Role == "Defender" then text.DefenderSubtitle else text.AttackerSubtitle
	if subtitle == "" then
		-- The attacker's half of Blocked -- see BANNER_TEXT's own header. An empty subtitle is the
		-- authored way of saying "this side gets no banner", not a missing string.
		return
	end

	surfaces.Outcome:set({ Title = text.Title, Subtitle = subtitle, Color = text.Color })

	-- Cleared on its own timer rather than latching -- an outcome is a moment, not a mode.
	outcomeGeneration += 1
	local generation = outcomeGeneration
	task.delay(AttackConstants.Presentation.OutcomeTextSeconds, function()
		if outcomeGeneration == generation then
			surfaces.Outcome:set(nil)
		end
	end)
end

local function onFeedback(raw: unknown): ()
	if typeof(raw) ~= "table" then
		return
	end
	local payload = raw :: CombatFeedback
	if typeof(payload.Kind) ~= "string" or typeof(payload.Damage) ~= "number" then
		return
	end

	shakeFor(payload)
	-- payload.Defender, not the local character: the block/parry sound belongs to the weapon that
	-- CAUGHT the swing, and this same event reaches the attacker's machine too -- see CombatAudio's own
	-- header. It resolves the weapon itself; this module hands it the participant and nothing more.
	CombatAudio.PlayImpact(payload.Kind, payload.Defender)
	flashFor(payload)
	freezeExchangeFor(payload)
	freezeVictimFor(payload)
	launchFor(payload)
	cancelSwingFor(payload)
	noteComboFor(payload)

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

	showBanner(payload)
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

	-- A new life must not inherit the previous one's banner. The screen is mounted once for the
	-- session (ResetOnSpawn = false), so nothing else would clear it.
	--
	-- Routed through Shared/PlayerLifecycle.lua rather than a bare CharacterAdded connect, for one
	-- shape rather than sixteen. The Humanoid wait it adds is not needed here (a banner does not care
	-- about a Humanoid) and costs nothing -- a life whose Humanoid never arrives is a life the player
	-- has bigger problems with than a stale outcome banner.
	PlayerLifecycle.BindLocalCharacter({
		Scope = "CombatFeedbackClient",
		OnCharacter = function()
			feedbackHandle.Outcome:set(nil)
		end,
	})

	logger:info("CombatFeedbackClient started")
end

return CombatFeedbackClient
