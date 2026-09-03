--!strict
--[[
	QiConstants.lua

	Owns: every Qi-system tunable number and lookup table, and now the system's own RemoteEvent
	names too. Deliberately its own dedicated Shared module rather than a Constants.Qi sub-table --
	so tuning Qi never grows the already-flagged "Constants.lua holds content, not tunables" problem
	(docs/architecture/2026-08-audit.md section 5, carried over from
	docs/architecture/2026-07-audit.md section 5.3) any further.

	Constants.Qi now re-exports this module rather than holding a table of its own, so every
	existing Constants.Qi.RemoteNames call site keeps working; new code should require this module
	directly. Note what that re-export widens: Constants.Qi used to be RemoteNames and nothing else,
	and is now this whole module. Nothing reads Constants.Qi wholesale (only Constants.Qi
	.RemoteNames, at three call sites), so no consumer sees a difference -- but a future one
	iterating Constants.Qi would now walk the tuning numbers too.

	THE DYNAMIC-TUNING CONTRACT: this file is the ENTIRE tuning surface for Qi balance.
	QiSystem.lua reads every value here fresh on every call -- nothing is cached into a module-level
	local at Init time, and nothing here is computed from anything other than the player's own
	live tier/attributes. Editing a number below and re-syncing (Rojo) IS the full tuning loop: no
	QiSystem.lua code change is ever required to retune Max Qi, regen pace, or Qi Conflict risk.
	Keep it that way -- if a future change needs QiSystem.lua's own logic to shift, that's a sign
	the tunable belongs in a formula shape this file doesn't yet have, not a reason to hardcode a
	number back into QiSystem.lua directly.

	Does not own: any live per-player Qi state (that's QiSystem.lua) or Qi Deviation
	risk/trigger/consequence logic (that's QiDeviationSystem.lua, still a stub -- when it's built it
	should read Qi state through QiSystem's public API rather than duplicating anything here).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

local QiConstants = {}

-- Server-owned RemoteEvent names (Server/Systems/QiSystem.lua creates every one of these via
-- NetworkBridge.CreateRemoteEvent at boot), same per-subsystem RemoteNames sub-table convention as
-- Constants.Meridian/Constants.Rivalry and the same "Progression_" prefix style.
--
-- Moved here from Constants.Qi, which held nothing else. TierConstants.lua's own header called out
-- the two disagreeing precedents this codebase carried -- Constants.Qi.RemoteNames (a wire name in
-- Constants.lua) versus EmoteConstants/TierConstants (a dedicated module owning its own wire
-- names) -- and picked the latter, on the grounds that a module owning its feature's tuning should
-- own its feature's wire names too, so adding a Qi remote never means editing Constants.lua. This
-- is that rule applied to the older precedent it was written against; there is now one convention,
-- not two.
QiConstants.RemoteNames = {
	QiUpdated = "Progression_QiUpdated",
}

-- Qi types map 1:1 onto Faction -- progression-systems.md: "Qi types map to faction/race
-- identity"; world-bible.md names the three fractured inheritances of power as exactly these three
-- factions (Celestial/Demonic/Unbound), and its own Qi Conflict example ("mixing Celestial and
-- Demonic techniques") is phrased in faction terms, not race terms. QiSystem.GetQiType falls back
-- to this default for any player whose profile.faction is still nil -- FactionManager
-- (Server/Managers/FactionManager.lua) is still a stub and nothing currently assigns a real
-- faction, so this keeps Qi fully functional today; QiSystem never caches the type, so it starts
-- reflecting real faction choices automatically the moment something starts setting
-- profile.faction. "Unbound" is the correct default, not an arbitrary placeholder -- world-bible.md
-- already frames Unbound as the path for those outside both sects, which is exactly what an
-- unassigned player is.
QiConstants.DefaultQiType = "Unbound" :: Types.Faction

-- Max Qi at each of the nine power tiers (progression-systems.md: "Nine power tiers form the
-- backbone all other systems hook into"), BEFORE the MeridianFlow attribute bonus below. A table,
-- not a formula, so a designer can shape a non-linear curve per tier directly -- e.g. widen the
-- gap at a specific tier to make that tier-up feel bigger -- without touching QiSystem.lua at all.
-- First-pass placeholder curve (mild acceleration); retune freely.
QiConstants.MaxQiByTier = {
	[1] = 100,
	[2] = 140,
	[3] = 185,
	[4] = 235,
	[5] = 290,
	[6] = 350,
	[7] = 415,
	[8] = 485,
	[9] = 560,
} :: { [number]: number }

-- Highest tier MaxQiByTier defines -- a tier above this clamps to the table's top entry rather than
-- indexing nil, so QiSystem never has to special-case "tier N+1 doesn't exist yet" if TierSystem's
-- own ladder ever changes independently of this table.
QiConstants.MaxTierDefined = 9

-- MeridianFlow attribute bonus -- Constants.CharacterCreation.AttributeEffects already promises
-- "Max Qi + regen" for this attribute; these two constants are what makes that promise real.
-- BaselineMeridianFlow matches Constants.CharacterCreation.AttributeBudget.BaseValuePerAttribute
-- (10) -- a player at the baseline gets exactly MaxQiByTier's number with no bonus/penalty; every
-- point above or below (the attribute's real range is 10-20 post-chargen, but this formula is not
-- clamped to that range so it stays correct if a future Attunement screen raises the ceiling)
-- shifts Max Qi and regen by these per-point amounts.
QiConstants.BaselineMeridianFlow = 10
QiConstants.MaxQiPerMeridianFlowPoint = 4
QiConstants.RegenPerSecondPerMeridianFlowPoint = 0.1

-- Base regen, before the MeridianFlow bonus above -- paced to refill an empty Tier 1 pool (100) in
-- 40 seconds, a "meaningful downtime cost, not a rounding error" pace consistent with
-- combat-philosophy.md's stance on resource costs mattering.
QiConstants.BaseRegenPerSecond = 2.5

-- How often QiSystem pushes a Progression_QiUpdated replication to a regenerating player, seconds.
-- Deliberately throttled -- docs/architecture/2026-08-audit.md section 4 (Tier 2.2) flagged
-- CombatSystem's own passive-regen vitals sync as a per-tick-state performance problem; QiSystem is
-- built to not repeat that mistake from day one rather than needing the same fix retrofitted later.
-- A Spend/Refund still replicates immediately regardless of this interval (see QiSystem.lua) --
-- this interval only throttles the PASSIVE regen tick's replication.
QiConstants.PassiveSyncIntervalSeconds = 0.5

-- Qi Conflict (progression-systems.md: mechanical friction from combining incompatible qi types,
-- "should always carry a real risk, not just a soft inefficiency"). Keyed by an unordered pair
-- (QiSystem.CheckQiConflict sorts the two types before reading this, so "Celestial,Demonic" and
-- "Demonic,Celestial" are the same lookup) to "None" | "Risky" | "Severe". Any pair not listed
-- (i.e. a type against itself) defaults to "None" -- see QiSystem.CheckQiConflict.
QiConstants.ConflictMatrix = {
	-- Celestial's ordered/disciplined qi against Demonic's aggressive/corrupting qi is the flagship
	-- incompatible pair progression-systems.md names explicitly -- the two philosophies world-bible.md
	-- frames as opposed sects, not just different flavors.
	["Celestial,Demonic"] = "Severe",
	-- Unbound is flexible by design (world-bible.md: "most build-flexible... least forgiving of
	-- mistakes") -- real friction against either sect's qi, but not the severe, sect-vs-sect clash
	-- Celestial/Demonic represents.
	["Celestial,Unbound"] = "Risky",
	["Demonic,Unbound"] = "Risky",
} :: { [string]: "Risky" | "Severe" }

return QiConstants
