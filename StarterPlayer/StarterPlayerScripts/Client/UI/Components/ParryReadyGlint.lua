--!strict
--[[
	ParryReadyGlint.lua

	Owns: the LOCAL-ONLY, instant screen-edge glint shown to a player the moment they press Block
	while their parry is off cooldown (Client/Combat/CombatClient.lua's Block branch, gated on
	PredictionMirror.PredictParryAvailable). It exists to make the parry press FEEL acknowledged
	the same frame it's pressed, without waiting the server round-trip the replicating character
	ParryFlash (CombatAnimator.PlayParryFlash) must wait for. Deliberately NOT the character flash:
	that one replicates to the attacker and is load-bearing information ("your swing was deflected"),
	so it stays server-confirmed -- a mispredicted flash would lie to the opponent. This glint never
	leaves the presser's own screen, so a wrong local guess costs a harmless flicker, nothing more.

	A single full-screen transparent Frame with a UIStroke drawn just inside its edges -- the stroke
	IS the edge glint, animated on the shared BorderAccent "steel/deflect" blue every other aim/parry
	surface uses (LockOnReticle/ShiftLockCrosshair ticks), so a parry read visually belongs to the
	same family as the reticle. Intensity (0 hidden .. 1 full) is eased through Tokens.Motion.
	GlintSpring so the flash pops and melts rather than snapping; CombatFeedback owns the one-shot
	drive (set to 1 on the press, back to 0 after a brief hold).

	Does not own: deciding WHETHER a parry is available (that's PredictionMirror's estimate, relayed
	by CombatClient) or the authoritative parry outcome (CombatSystem) -- this only renders the
	intensity it's handed, the same "value in, presentation out" boundary every component here uses.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Tokens = require(script.Parent.Parent.Tokens)

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

export type ParryReadyGlintProps = {
	-- 0 = hidden, 1 = full glint. One-shot drive owned by CombatFeedback; eased here.
	Intensity: UsedAs<number>,
}

local STROKE_THICKNESS = Tokens.Motion.GlintSpring.StrokeThickness
local GLINT_PEAK_TRANSPARENCY = Tokens.Motion.GlintSpring.PeakTransparency

local GLINT_SPRING_SPEED = Tokens.Motion.GlintSpring.Speed
local GLINT_SPRING_DAMPING = Tokens.Motion.GlintSpring.Damping

local function ParryReadyGlint(scope: Scope, props: ParryReadyGlintProps): Frame
	-- Ease the raw 0..1 intensity, then map it to a stroke transparency: intensity 1 -> the soft
	-- peak, intensity 0 -> fully invisible.
	local eased = scope:Spring(
		scope:Computed(function(use)
			return use(props.Intensity)
		end),
		GLINT_SPRING_SPEED,
		GLINT_SPRING_DAMPING
	)
	local strokeTransparency = scope:Computed(function(use)
		return 1 - use(eased) * (1 - GLINT_PEAK_TRANSPARENCY)
	end)

	return scope:New "Frame" {
		Name = "ParryReadyGlint",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		-- Above the HUD, below nothing that matters -- a whole-screen non-interactive overlay.
		ZIndex = 20,

		[Fusion.Children] = {
			scope:New "UIStroke" {
				Color = Tokens.Color.BorderAccent,
				Thickness = STROKE_THICKNESS,
				Transparency = strokeTransparency,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			},
		},
	} :: Frame
end

return ParryReadyGlint
