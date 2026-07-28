--!strict
--[[
	CombatDebugNames.lua

	Owns: the one bit of pure string logic three separate combat modules independently needed --
	deriving a swing's combo "stage" from its DebugName's trailing digit ("Basic2"/"Dagger2" -> 2;
	"Heavy1" -> 1; "Finisher"/"DashPunch" -> nil, no trailing digit to read). Every weapon's
	Basic-stage DebugNames are deliberately suffixed this way (Constants.lua's Weapons.Primary/
	Secondary.Stages.Basic), so this single regex is the one place that convention gets read back
	out. Pure by construction (a string in, a number or nil out -- no Instance, Player, or remote
	touched anywhere near it), which is exactly what makes it safe for Client/FX/CombatAnimator.lua,
	Client/Combat/PredictionMirror.lua, AND server-side ServerScriptService/Server/Combat/
	BotAnimator.lua to all share verbatim instead of three (previously: two duplicates plus one
	inline reimplementation) independent copies of the same one-line regex.

	Does not own: what a caller DOES with the resulting stage number -- CombatAnimator/BotAnimator
	pick an animation track name from it ("Swing" .. stage, "Hit" .. stage); PredictionMirror
	advances its own local combo mirror from it. Also does not own excluding Heavy-stage names
	(which end in a digit too, e.g. "Heavy1") from a caller's OWN "is this a Basic swing" question
	-- this function has no way to know a caller's basic-vs-heavy distinction from the string
	alone, so that filtering stays the caller's job (see e.g. PredictionMirror.OnOwnSwingConnected's
	own isHeavy guard, or CombatAnimator.resolveSwingTrackName's own isHeavy branch).
]]

local CombatDebugNames = {}

-- Extracts the trailing combo-stage digit from a swing's DebugName. Returns nil for anything
-- without one (Finisher/DaggerFinisher variants, DashPunch, AirSlam, or any other non-staged
-- DebugName).
function CombatDebugNames.SwingStageFromDebugName(debugName: string): number?
	local digit = debugName:match("(%d)$")
	return digit and tonumber(digit) or nil
end

return CombatDebugNames
