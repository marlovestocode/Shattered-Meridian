--!strict
--[[
	VisionEffects.lua

	Owns: the first-person "eyes opening" reveal played once the local player is teleported into the
	arrival world -- a Lighting.ColorCorrectionEffect (brightness/saturation) PLUS a Lighting.
	BlurEffect, both lazily created the first time they're needed. Same asset-free, lazy-singleton
	approach Client/FX/StunEffect.lua/DeathEffect.lua already establish (this repo has no VFX/particle
	asset to spend on this yet -- see those modules' own headers), extended with a second effect
	(BlurEffect has no equivalent in either of those) and a multi-stage sequence instead of a single
	dip: an instant blackout snap, two partial "eyes cracking open" reveals each followed by a quick
	re-dip ("blink") back toward the blackout values, then one final ease to fully neutral.

	PlayReveal BLOCKS the calling thread until fully clear, unlike Stun/Death's fire-and-forget Play()
	-- this matches every other staged beat in Client/Intro/IntroClient.lua's own sequence
	(OnboardingClient.RunCinematicStage/RunConfirmationLoop are blocking too), so the whole intro stays
	one readable top-to-bottom orchestration rather than mixing blocking and callback-driven stages.

	Does not own: deciding WHEN the reveal starts (Client/Intro/IntroClient.lua calls EnterBlackout the
	moment BlackScreen.lua's own opaque cover is in place, holds for Constants.Intro.Vision.
	BlackHoldSeconds, fades BlackScreen out, then calls PlayReveal), or the black screen UI layer
	itself (BlackScreen.lua) -- this module only ever touches Lighting effects, never a ScreenGui.
]]

local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)

local logger = Logger.scope("VisionEffects")

local Config = Constants.Intro.Vision

local VisionEffects = {}

local colorCorrection: ColorCorrectionEffect? = nil
local blur: BlurEffect? = nil

local function getColorCorrection(): ColorCorrectionEffect
	if colorCorrection and colorCorrection.Parent then
		return colorCorrection
	end

	local effect = Instance.new("ColorCorrectionEffect")
	effect.Name = "VisionEffects"
	effect.Brightness = 0
	effect.Saturation = 0
	effect.Parent = Lighting

	colorCorrection = effect
	return effect
end

local function getBlur(): BlurEffect
	if blur and blur.Parent then
		return blur
	end

	local effect = Instance.new("BlurEffect")
	effect.Name = "VisionEffects"
	effect.Size = 0
	effect.Parent = Lighting

	blur = effect
	return effect
end

-- Instant snap to the blackout state -- no tween. This is meant to happen while BlackScreen.lua's own
-- opaque UI layer already hides the transition, so a tweened dip here would be motion nobody can see.
function VisionEffects.EnterBlackout(): ()
	local colorCorrectionEffect = getColorCorrection()
	local blurEffect = getBlur()
	colorCorrectionEffect.Brightness = Config.BlackoutBrightness
	colorCorrectionEffect.Saturation = Config.BlackoutSaturation
	blurEffect.Size = Config.BlackoutBlurSize
	logger:debug("Vision blackout entered")
end

-- Tweens both effects toward one target simultaneously and blocks until they arrive -- both tweens
-- share the same TweenInfo/duration, so waiting on the color tween's own Completed is sufficient.
local function tweenTo(brightness: number, saturation: number, blurSize: number, durationSeconds: number): ()
	local colorCorrectionEffect = getColorCorrection()
	local blurEffect = getBlur()
	local tweenInfo = TweenInfo.new(durationSeconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)

	local colorTween = TweenService:Create(colorCorrectionEffect, tweenInfo, {
		Brightness = brightness,
		Saturation = saturation,
	})
	local blurTween = TweenService:Create(blurEffect, tweenInfo, { Size = blurSize })

	colorTween:Play()
	blurTween:Play()
	colorTween.Completed:Wait()
end

-- A quick dip back toward the blackout values and back to `returnBrightness/Saturation/BlurSize` --
-- the "blink" beat between the two partial reveals in PlayReveal below. Split the total duration
-- evenly between the two halves.
local function playBlink(
	totalDurationSeconds: number,
	returnBrightness: number,
	returnSaturation: number,
	returnBlurSize: number
): ()
	local half = totalDurationSeconds / 2
	tweenTo(Config.BlackoutBrightness, Config.BlackoutSaturation, Config.BlackoutBlurSize, half)
	tweenTo(returnBrightness, returnSaturation, returnBlurSize, half)
end

-- Blocks the calling thread through the full "eyes opening" reveal -- see file header for the stage
-- breakdown and why this blocks rather than taking a completion callback. Expects EnterBlackout to
-- have already been called (this only eases FROM whatever state the effects are currently in).
function VisionEffects.PlayReveal(): ()
	tweenTo(Config.Reveal1Brightness, Config.Reveal1Saturation, Config.Reveal1BlurSize, Config.Reveal1DurationSeconds)
	playBlink(Config.Blink1DurationSeconds, Config.Reveal1Brightness, Config.Reveal1Saturation, Config.Reveal1BlurSize)

	tweenTo(Config.Reveal2Brightness, Config.Reveal2Saturation, Config.Reveal2BlurSize, Config.Reveal2DurationSeconds)
	playBlink(Config.Blink2DurationSeconds, Config.Reveal2Brightness, Config.Reveal2Saturation, Config.Reveal2BlurSize)

	tweenTo(0, 0, 0, Config.FinalClearDurationSeconds)
	logger:debug("Vision reveal complete")
end

-- Hard, instant reset to neutral -- mirrors DeathEffect.Clear()'s "safe to call even if Play was
-- never called" contract. Not part of PlayReveal's own normal path (which already ends at neutral);
-- exists for Client/Intro/IntroClient.lua to call defensively if the awakening sequence is ever
-- interrupted before PlayReveal finishes on its own.
function VisionEffects.Clear(): ()
	local colorCorrectionEffect = getColorCorrection()
	local blurEffect = getBlur()
	colorCorrectionEffect.Brightness = 0
	colorCorrectionEffect.Saturation = 0
	blurEffect.Size = 0
	logger:debug("Vision effects cleared")
end

return VisionEffects
