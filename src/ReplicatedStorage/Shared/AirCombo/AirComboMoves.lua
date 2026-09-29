--!strict
--[[
	AirComboMoves.lua

	Owns: the air moves' id scheme -- building default:{weapon}:Launcher / :Air:{n} / :AirFinisher:{kind},
	and reading a move id back into the role it plays in the air. Pure: strings in, strings out.

	ONE DEFINITION, FOUR READERS. DefaultMoveRegistry names the moves with it, SwingSequencer resolves a
	press to one, AirComboSystem reads a landed hit's role back out of it, and DamageSystem prices them flat --
	and DamageSystem is a layer BELOW the air combo that may not require it. Every other part of the id scheme is restated
	per module on purpose (SwingSequencer's header), because those ids are stable and each module only
	needs its own slice; these are new, used by four modules at once, and a typo in any one of four copies
	would be a move that silently never resolves.

	A CUSTOM move can also launch -- MoveKnockback.StartsAirCombo, authored in the Move Editor -- and that is
	answered by IsLauncher's second argument, not by the id: a custom move's id is an author's slug.

	Does not own: what the moves do (AirComboConstants, the Baseline stages), or when a press means one
	(SwingSequencer).
]]

local AirComboTypes = require(script.Parent.AirComboTypes)

type MoveRole = AirComboTypes.MoveRole
type FinisherKind = AirComboTypes.FinisherKind

local AirComboMoves = {}

-- The finisher kinds, in display order. The Baseline stage table is keyed by these names.
AirComboMoves.FinisherKinds = { "Slam", "Spike" } :: { FinisherKind }

function AirComboMoves.LauncherId(weaponId: string): string
	return `default:{weaponId}:Launcher`
end

function AirComboMoves.AirId(weaponId: string, beat: number): string
	return `default:{weaponId}:Air:{beat}`
end

function AirComboMoves.FinisherId(weaponId: string, kind: FinisherKind): string
	return `default:{weaponId}:AirFinisher:{kind}`
end

-- What `moveId` is in the air, or nil for a move with no air role at all.
function AirComboMoves.RoleOf(moveId: string): MoveRole?
	if typeof(moveId) ~= "string" then
		return nil
	end
	if string.match(moveId, "^default:[^:]+:Launcher$") then
		return { Role = "Launcher" }
	end
	local beat = string.match(moveId, "^default:[^:]+:Air:(%d+)$")
	if beat then
		return { Role = "Air", Beat = tonumber(beat) }
	end
	local kind = string.match(moveId, "^default:[^:]+:AirFinisher:(%a+)$")
	if kind == "Slam" or kind == "Spike" then
		return { Role = "Finisher", Finisher = kind :: FinisherKind }
	end
	return nil
end

-- Whether a landed hit of `moveId` launches. A Default Launcher always does; any other move does when its
-- authored knockback says StartsAirCombo (the Move Editor's toggle, which already validates, encodes and
-- persists -- it was read by nothing until this).
function AirComboMoves.IsLauncher(moveId: string, startsAirCombo: boolean?): boolean
	if startsAirCombo == true then
		return true
	end
	local role = AirComboMoves.RoleOf(moveId)
	return role ~= nil and role.Role == "Launcher"
end

-- Whether DamageSystem prices this move flat (pricing stage pinned to 1, like an M1) rather than by the
-- attacker's ComboEscalation stage. Every air hit and finisher is: the air combo scales them itself
-- (AirComboConstants.Damage), and the two scalings must never stack. The launcher is NOT -- it is the
-- ground string's own payoff and escalates like a Heavy does.
function AirComboMoves.IsFlatPriced(moveId: string): boolean
	local role = AirComboMoves.RoleOf(moveId)
	return role ~= nil and role.Role ~= "Launcher"
end

return AirComboMoves
