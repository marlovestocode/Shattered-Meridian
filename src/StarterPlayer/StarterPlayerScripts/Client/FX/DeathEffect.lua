--!strict
--[[
	DeathEffect.lua

	Owns: the local player's own death-to-respawn screen dip -- a Lighting.ColorCorrectionEffect
	brightness/saturation pull played for the whole corpse-viewing window between a confirmed death
	and the replacement character's CharacterAdded (Client/Combat/CombatClient.lua's Kind == "Death"
	branch calls Play(); its localPlayer.CharacterAdded handler calls Clear()). Same asset-free
	ColorCorrectionEffect approach as StunEffect.lua (this repo has no VFX/particle asset to spend on
	this yet -- see that module's header), but a HELD effect rather than a fixed-duration one-shot:
	Play()/Clear() are two explicit entry points because the real duration is "however long this
	life's corpse-viewing window lasts." This module never assumes Constants.Respawn.DelaySeconds
	itself -- CombatClient.lua drives the clear off the actual respawned CharacterAdded, not a
	client-side timer, so a respawn that lands early or late (admin ForceRespawnTarget, a slower
	death-confirmation round trip, a future tuning change to DelaySeconds) never leaves the dip
	hanging past the corpse view or clears it early against a stale guess.

	Both entry points are safe to call redundantly, the same way StunEffect.Play() already is:
	calling Play() again while already dipped, or calling Clear() before Play()'s own ease-in tween
	finished, just cancels whichever tween was running and starts the new one -- TweenService cancels
	any tween already targeting the same properties the moment a new one starts, so there is no
	separate generation-guard needed here (unlike Screens/DeathFeed's own countdown, which IS a
	task.delay chain and does need one -- see that module's header for why the two mechanisms differ).

	Does not own: deciding WHEN the local player died or respawned -- CombatClient.lua is the only
	caller, translating the server-confirmed "Death" feedback event (gated there to the payload's
	TargetUserId being the local player -- the killer's own client receives the same event and must
	never see their own screen dip for a kill they threw) and the local CharacterAdded into calls
	here. This module only knows how to play/clear the effect once told to.
]]

local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)

local logger = Logger.scope("DeathEffect")

local DeathEffect = {}

-- "Deeper than Stun, still restrained": see Constants.FX.Death's own header in Constants.lua.
local DIP_BRIGHTNESS = Constants.FX.Death.DipBrightness
local DIP_SATURATION = Constants.FX.Death.DipSaturation
local EASE_IN_SECONDS = Constants.FX.Death.EaseInSeconds
local EASE_OUT_SECONDS = Constants.FX.Death.EaseOutSeconds

local colorCorrection: ColorCorrectionEffect? = nil

local function getColorCorrection(): ColorCorrectionEffect
	if colorCorrection and colorCorrection.Parent then
		return colorCorrection
	end

	local effect = Instance.new("ColorCorrectionEffect")
	effect.Name = "DeathEffect"
	effect.Brightness = 0
	effect.Saturation = 0
	effect.Parent = Lighting

	colorCorrection = effect
	return effect
end

-- Eases the dip IN and holds -- see file header for why this doesn't also schedule its own
-- ease-out the way StunEffect.Play() does.
function DeathEffect.Play(): ()
	local effect = getColorCorrection()
	TweenService:Create(
		effect,
		TweenInfo.new(EASE_IN_SECONDS, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
		{ Brightness = DIP_BRIGHTNESS, Saturation = DIP_SATURATION }
	):Play()
	logger:debug("Death effect played")
end

-- Eases the dip back OUT to neutral -- called once the local player has a new body
-- (CombatClient.lua's localPlayer.CharacterAdded), never off a timer. Safe to call even if Play()
-- was never called this life (e.g. the very first spawn of a session) -- getColorCorrection lazily
-- creates a neutral effect and this just tweens it from 0 to 0, a harmless no-op.
function DeathEffect.Clear(): ()
	local effect = getColorCorrection()
	TweenService:Create(
		effect,
		TweenInfo.new(EASE_OUT_SECONDS, Enum.EasingStyle.Sine, Enum.EasingDirection.In),
		{ Brightness = 0, Saturation = 0 }
	):Play()
	logger:debug("Death effect cleared")
end

return DeathEffect
