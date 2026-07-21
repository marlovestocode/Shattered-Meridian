--!strict
--[[
	RewardSystem.lua

	Owns: reward composition -- decides which reward types a completed gameplay event is
	structurally eligible for (a PvP kill, a boss kill, a quest, a discovery) and delegates each
	type's magnitude to the system that owns it, then hands the composed reward manifest to
	ProgressionSystem. Coordinates; does not calculate. See software-architecture.md's
	"RewardSystem and AbsorbSystem" section for the full responsibility list and the resolved
	boundary against AbsorbSystem specifically.

	Does not own: absorb essence calculation/application (AbsorbSystem, which this System calls
	into for the absorb component of a PvP-kill reward), Meridian XP calculation (not yet
	formalized), whether a reward contributes to progression (ProgressionSystem's fight-to-grow
	legitimacy check, not duplicated here), or combat resolution/kill confirmation (CombatSystem).

	Sits between CombatSystem and ProgressionSystem in the progression pipeline: CombatSystem
	reports a confirmed kill here (not to AbsorbSystem directly), this System composes the reward
	-- calling AbsorbSystem for the absorb component -- and hands the result to ProgressionSystem.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

local RewardSystem = {}

function RewardSystem.Init(): ()
end

return RewardSystem :: Types.SystemModule
