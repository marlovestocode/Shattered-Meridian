--!strict
--[[
	StunEffect.lua

	Owns: a slight, smoothly-eased screen dip that plays when the local player becomes stunned --
	currently: their own attack got parried (CombatSystem.lua's resolveHitAgainstTarget sets
	attackerState.stunExpiry to Constants.Combat.StunDuration on a successful parry against them).
	Fills a real gap animation-systems.md's "Sync with combat state" section calls out explicitly --
	every combat state with "a visible player-facing moment" (it names parry window and posture
	break outright) "needs a corresponding animation and VFX cue" -- Stun had a real server-side
	lockout with zero player-facing visual until this module.

	Implementation: a Lighting.ColorCorrectionEffect brightness/saturation dip, tweened in then back
	out (TweenService), not a camera shake -- deliberately subtle ("slight") per
	docs/ui-ux-philosophy.md's Critical States rule ("controlled animation... never excessive
	flashing"), and asset-free, since this repo has no VFX/particle asset to spend on this yet (see
	CombatAudio.lua's header for the same "no asset-upload pipeline" reasoning applied to sound).

	Does not own: deciding WHEN the player is stunned -- CombatClient.lua's feedback listener is the
	only caller, translating a server-confirmed "Parried" event where the local player was the
	attacker into a call here. This module only knows how to play the effect once told to.
]]

local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)

local logger = Logger.scope("StunEffect")

local StunEffect = {}

-- "Slight": a small dip, not a jarring flash. "Smooth": eased in and back out rather than
-- snapping, timed close to Constants.Combat.StunDuration so the visual reads as "this is how long
-- you're locked out," not an arbitrary flourish. Now Constants.FX.Stun -- see that table's own
-- header in Constants.lua.
local DIP_BRIGHTNESS = Constants.FX.Stun.DipBrightness
local DIP_SATURATION = Constants.FX.Stun.DipSaturation
local EASE_IN_SECONDS = Constants.FX.Stun.EaseInSeconds
local EASE_OUT_SECONDS = Constants.FX.Stun.EaseOutSeconds

local colorCorrection: ColorCorrectionEffect? = nil

local function getColorCorrection(): ColorCorrectionEffect
	if colorCorrection and colorCorrection.Parent then
		return colorCorrection
	end

	local effect = Instance.new("ColorCorrectionEffect")
	effect.Name = "StunEffect"
	effect.Brightness = 0
	effect.Saturation = 0
	effect.Parent = Lighting

	colorCorrection = effect
	return effect
end

-- Plays the stun dip. Safe to call again mid-effect -- TweenService cancels whatever tween is
-- currently running on Brightness/Saturation the moment a new one targeting them starts, so a
-- second stun landing before the first has finished just restarts the dip rather than stacking.
-- The ease-in's own Completed only chains to the ease-out when it actually finished
-- (Enum.PlaybackState.Completed), not when a second Play() cancelled it first (PlaybackState.
-- Cancelled) -- Tween.Completed fires either way, and without this check a rapid second stun would
-- let the FIRST call's stale continuation fire an ease-out that immediately fights the second
-- call's own ease-in, cutting its dip short instead of "just restarting" it as documented above.
function StunEffect.Play(): ()
	local effect = getColorCorrection()

	local easeIn = TweenService:Create(
		effect,
		TweenInfo.new(EASE_IN_SECONDS, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
		{ Brightness = DIP_BRIGHTNESS, Saturation = DIP_SATURATION }
	)
	local easeOut = TweenService:Create(
		effect,
		TweenInfo.new(EASE_OUT_SECONDS, Enum.EasingStyle.Sine, Enum.EasingDirection.In),
		{ Brightness = 0, Saturation = 0 }
	)

	easeIn:Play()
	easeIn.Completed:Once(function(playbackState: Enum.PlaybackState)
		if playbackState == Enum.PlaybackState.Completed then
			easeOut:Play()
		end
	end)

	logger:debug("Stun effect played")
end

return StunEffect
