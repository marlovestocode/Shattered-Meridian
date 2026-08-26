--!strict
--[[
	QiDeviationConstants.lua

	Owns: every Qi Deviation tunable number. Its own dedicated Shared module rather than a
	QiConstants sub-table -- QiConstants.lua's own header already refuses to own this ("Does not
	own... Qi Deviation risk/trigger/consequence logic (that's QiDeviationSystem.lua)"), and folding
	the numbers back in there would just relocate the coupling QiConstants was written to avoid.

	THE DYNAMIC-TUNING CONTRACT: same shape as QiConstants.lua -- QiDeviationSystem.lua reads every
	value here fresh on every call, nothing is cached at Init time, and retuning is a data edit plus
	a Rojo re-sync, never a QiDeviationSystem.lua code change.

	Does not own: live per-player risk/lockout state (QiDeviationSystem.lua), or Qi itself
	(QiSystem.lua/QiConstants.lua) -- this file only prices the failure state, never the resource it
	is a failure state FOR.
]]

local QiDeviationConstants = {}

-- Below this fraction of a player's own current Max Qi (progression-systems.md: "should scale in
-- severity with how far a player is overreaching their current tier/mastery" -- Max Qi is already
-- tier-priced by QiConstants.MaxQiByTier, so a fraction of it is inherently tier-relative without
-- this file needing to compare against another player's tier at all), a spend counts as an
-- overreach and accrues risk. Above it, a spend is safe and accrues nothing.
QiDeviationConstants.SafeQiFraction = 0.25

-- Risk accrued per point of "how far below SafeQiFraction this spend left you", e.g. a spend that
-- leaves a player at 0% Qi (the maximum possible deficit, 0.25) accrues 0.25 * 140 = 35 risk in one
-- hit -- three such spends in a row cross TriggerThreshold. A spend that leaves a player exactly at
-- the safe line accrues nothing. First-pass number, retune freely.
QiDeviationConstants.RiskPerDeficitFraction = 140

-- Risk decayed per second of real time between spends, computed lazily off the gap since a
-- player's last qualifying spend rather than a Heartbeat tick -- CharacterSheetSystem.lua's own
-- header already frames qiDeviationRisk as a field that "changes a handful of times per session,"
-- not a live combat-frequency meter, so there is no tick to hook decay into. Paced so a player who
-- stops overreaching recovers a full TriggerThreshold's worth of risk in ~50 seconds -- a real
-- downtime cost, not a rounding error, the same pacing philosophy QiConstants.BaseRegenPerSecond's
-- own header cites from combat-philosophy.md.
QiDeviationConstants.RiskDecayPerSecond = 2

-- Risk at or above this fires a Deviation event: risk resets to 0 and a lockout begins. 100 keeps
-- the number legible as a plain 0-100 meter, matching how qiDeviationRisk is rendered today
-- (CharacterTab.lua: a bare tostring(), not yet a percentage-formatted bar).
QiDeviationConstants.TriggerThreshold = 100

-- How long ArtSystem.CanUse/UseArt refuse with "QiDeviationLocked" after a trigger. Short and
-- telegraphed on purpose -- combat-philosophy.md's "no true unblockable... without an explicit,
-- telegraphed cost": a player who deviates loses their arts for a real but brief window, with a
-- machine-readable reason the client can show, never a silent or open-ended lock.
QiDeviationConstants.LockoutSeconds = 8

return QiDeviationConstants
