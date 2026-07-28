--!strict
--[[
	ProgressionSystem.lua

	Owns: progression orchestration -- receives progression events from gameplay systems, decides
	whether they contribute to progression, routes accepted events to the subsystem that owns the
	relevant mechanic (TierSystem, BloodlineSystem, ArtSystem, etc.), and triggers milestone
	checks once those updates land. Coordinates the progression pipeline; does not calculate it.
	See software-architecture.md's "ProgressionSystem: orchestration, not ownership" section for
	the full responsibility list, the explicit non-ownership table, and the documented
	communication pattern (inbound events are in-process calls, never NetworkBridge remotes;
	outbound calls are one-directional -- routed subsystems never call back into this module).

	Does not own: combat calculations, damage, Meridian XP calculations, tier formulas, bloodline
	logic, or art logic -- each of those belongs to the System that owns that mechanic. This
	module only decides *that* an event should become progression and routes it to *who*
	computes it.

	Note: the documented "typical progression flow" in software-architecture.md references
	RewardSystem, MeridianSystem, and AchievementSystem as upstream/downstream collaborators --
	none of those exist yet in this codebase. This module's Init() has nothing to route to until
	they (or their equivalents) are built.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

local ProgressionSystem = {}

function ProgressionSystem.Init(): () end

return ProgressionSystem :: Types.SystemModule
