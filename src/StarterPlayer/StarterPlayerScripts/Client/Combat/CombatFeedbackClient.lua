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
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AttackConstants = require(ReplicatedStorage.Shared.Attack.AttackConstants)
local Constants = require(ReplicatedStorage.Shared.Constants)
local DamageConstants = require(ReplicatedStorage.Shared.Damage.DamageConstants)
local DamageTypes = require(ReplicatedStorage.Shared.Damage.DamageTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)

local CameraShake = require(script.Parent.Parent.FX.CameraShake)
local CombatFeedbackModule = require(script.Parent.Parent.UI.Screens.CombatFeedback)
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

-- Whether `moveId` is a weapon's Basic (M1) string hit. LIVE MoveIds never match the hand-authored
-- DebugName fields on Constants.Combat.Weapons[...].Stages.Basic ("Basic1", "Dagger1", ...) -- every
-- attack actually thrown resolves through DefaultMoveRegistry's synthetic scheme instead
-- (Server/Combat/DefaultMoveRegistry.lua's weaponStageMoveId, restated client-side here the same way
-- SwingSequencer.lua restates it server-side, per that module's own header on why the coupling is to
-- the naming convention and not to a shared function). A custom Move-Editor move can never match this
-- shape (its MoveId is an author-assigned slug), so this also correctly excludes those. Only Basic --
-- Heavy and Finisher throw the same shake as any other move and get no forward pull (see shakeFor).
local function isBasicMoveId(moveId: string): boolean
	return string.match(moveId, "^default:%a+:Basic:%d+$") ~= nil
end

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
	local preset = (Constants.FX.CameraShake :: any)[presetName]

	-- A landed M1 (Basic weapon-string) hit gets an extra forward lunge layered onto its ordinary
	-- shake -- Parried is excluded because nothing of the attacker's own swing actually connected.
	local pushForward: number? = nil
	if payload.Role == "Attacker" and payload.Kind ~= "Parried" and isBasicMoveId(payload.MoveId) then
		pushForward = Constants.FX.CameraShake.M1PushForwardStuds
	end

	CameraShake.Shake(preset, pushForward)
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
	Players.LocalPlayer.CharacterAdded:Connect(function()
		feedbackHandle.Outcome:set(nil)
	end)

	logger:info("CombatFeedbackClient started")
end

return CombatFeedbackClient
