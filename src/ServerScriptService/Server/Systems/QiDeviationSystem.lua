--!strict
--[[
	QiDeviationSystem.lua

	Owns: Qi Deviation risk/trigger/consequence (software-architecture.md; progression-systems.md
	-- "the primary 'power has a cost' mechanic outside of pure Corruption", scaling with how far
	a player overreaches their current tier/mastery).

	OVERREACH IS "SPENDING QI AND LANDING BELOW QiDeviationConstants.SafeQiFraction OF YOUR OWN
	MAX QI." Max Qi is already tier-priced (QiConstants.MaxQiByTier via QiSystem.ComputeMaxQi), so a
	fraction of a player's OWN current max is inherently tier-relative without this System ever
	comparing against another player or hardcoding a tier number itself.

	RISK IS COMPUTED LAZILY, NOT ON A HEARTBEAT. CharacterSheetSystem.lua's own header already frames
	qiDeviationRisk as a field that "changes a handful of times per session," not a live
	combat-frequency meter -- so there is no tick to hook into. Every GameplayEvents.OnQiSpent event
	first decays risk by the real time elapsed since this player's last qualifying spend, then
	accrues more if THIS spend left them below the safe line. A player who stops spending Qi below
	the line simply stops accruing; their risk sits frozen (not actively decayed) until their next
	spend, at which point the elapsed-time decay catches it up in one step. See
	QiDeviationConstants.RiskDecayPerSecond's own header for the pacing this is tuned to.

	THE CONSEQUENCE IS A TELEGRAPHED, TIME-BOXED ART LOCKOUT, never a silent or open-ended one --
	combat-philosophy.md's "no true unblockable/unparryable without an explicit telegraphed cost."
	Crossing QiDeviationConstants.TriggerThreshold resets risk to 0 and starts a deadline
	(QiDeviationSystem.IsLocked reads `os.clock() < lockedUntil[player]`, a timestamp rather than a
	boolean flag someone has to remember to clear -- the same "deadlines, not booleans" discipline
	this project's other cross-system gates already follow, since a stale boolean here would mean a
	permanently art-locked player with no way to notice or recover). ArtSystem.CanUse/UseArt read
	IsLocked as a third gate, the same "CanAttack-shaped gate" idiom GrabSystem already established
	for reading a sibling System's permission through a narrow, read-only seam (CLAUDE.md's Combat
	stack layering section) -- this System never reaches INTO ArtSystem; ArtSystem reaches into this
	one, by requiring it, exactly the same direction GrabSystem is read by AttackRequestSystem.

	Does not own: Corruption's Demonic-power cost model -- that's a separate, related cost model
	(progression-systems.md's Corruption section) this System doesn't own but should stay legible
	alongside. Also does not own the Qi resource itself (QiSystem), Tier-up validation (TierSystem),
	Art unlock/use permission (ArtSystem -- this System only answers "is this player currently
	locked out", never "may they use this specific art"), or canonical persistence mechanics
	(PlayerDataSystem -- this System, like every other progression System, mutates only through
	Transform and never writes a DataStore itself).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local QiDeviationConstants = require(ReplicatedStorage.Shared.QiDeviationConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local SlowWatch = require(ReplicatedStorage.Shared.SlowWatch)
local GameplayEvents = require(ServerScriptService.Server.Events.GameplayEvents)
local PlayerDataSystem = require(script.Parent.PlayerDataSystem)
local CharacterSheetSystem = require(script.Parent.CharacterSheetSystem)

local logger = Logger.scope("QiDeviationSystem")

local QiDeviationSystem = {}

-- os.clock() a player last had a qualifying (i.e. any) Qi spend processed -- what
-- ComputeRiskAfterSpend's `elapsedSeconds` is measured against. Absent entirely for a player who
-- has never spent Qi this session, which onQiSpent below reads as "no time has passed yet."
local lastSpendAt: { [Player]: number } = {}

-- os.clock() a player's ArtSystem lockout ends. Absent (not merely false) for a player who has
-- never triggered a Deviation this session -- see this file's header on why this is a deadline,
-- not a boolean.
local lockedUntil: { [Player]: number } = {}

-- Pure formula: given the risk a player already had, how far below the safe line THIS spend left
-- them (0 when safe or better), and how long it has been since their last processed spend, returns
-- the new risk value and whether it crossed TriggerThreshold. Exported specifically so this
-- System's regression tests can exercise the actual curve headlessly -- no Player, no profile --
-- the same "extract the pure math so it's TestEZ-coverable" split QiSystem.ComputeMaxQi/
-- TierSystem.ComputeTierForXP/BountySystem.ComputeReward already established.
--
-- On a trigger, the returned risk is always 0 -- Deviating pays off the whole meter, not just the
-- portion over the threshold, so the client sees a clean reset rather than a confusing remainder.
function QiDeviationSystem.ComputeRiskAfterSpend(
	currentRisk: number,
	remainingFraction: number,
	elapsedSeconds: number
): (number, boolean)
	local safeCurrentRisk = if typeof(currentRisk) == "number" and currentRisk == currentRisk then currentRisk else 0
	local safeElapsed = if typeof(elapsedSeconds) == "number" and elapsedSeconds > 0 then elapsedSeconds else 0
	local decayed = math.max(0, safeCurrentRisk - (QiDeviationConstants.RiskDecayPerSecond * safeElapsed))

	local deficit = math.max(0, QiDeviationConstants.SafeQiFraction - remainingFraction)
	local accrued = decayed + (deficit * QiDeviationConstants.RiskPerDeficitFraction)

	if accrued >= QiDeviationConstants.TriggerThreshold then
		return 0, true
	end
	return accrued, false
end

-- Whether `player` is currently locked out of Art use by an active Deviation consequence. Absent
-- from lockedUntil reads as "never locked", the same "table read as safe default" shape
-- QiSystem.GetQi/GetMaxQi already use for a player this System hasn't processed a spend for yet.
function QiDeviationSystem.IsLocked(player: Player): boolean
	local deadline = lockedUntil[player]
	return deadline ~= nil and os.clock() < deadline
end

local function onQiSpent(player: Player, _amount: number, remaining: number, max: number, _reason: string?): ()
	if typeof(max) ~= "number" or max <= 0 then
		-- No real Qi state to evaluate against yet (or a malformed event) -- nothing to accrue or
		-- decay against a zero/undefined ceiling.
		return
	end
	local remainingFraction = remaining / max

	local now = os.clock()
	local elapsedSeconds = now - (lastSpendAt[player] or now)
	lastSpendAt[player] = now

	debug.profilebegin("QiDeviation.GetProfile")
	local profile = PlayerDataSystem.GetProfile(player)
	debug.profileend()
	if not profile then
		return
	end

	local newRisk, triggered =
		QiDeviationSystem.ComputeRiskAfterSpend(profile.qiDeviationRisk, remainingFraction, elapsedSeconds)

	debug.profilebegin("QiDeviation.Transform")
	local committed = PlayerDataSystem.Transform(player, function(liveProfile)
		liveProfile.qiDeviationRisk = newRisk
	end)
	debug.profileend()
	if not committed then
		return
	end

	if triggered then
		lockedUntil[player] = now + QiDeviationConstants.LockoutSeconds
		logger:info("Qi Deviation triggered", {
			player = player.Name,
			lockoutSeconds = QiDeviationConstants.LockoutSeconds,
		})
	end

	debug.profilebegin("QiDeviation.SheetRefresh")
	CharacterSheetSystem.Refresh(player)
	debug.profileend()
end

local function onPlayerRemoving(player: Player): ()
	lastSpendAt[player] = nil
	lockedUntil[player] = nil
end

function QiDeviationSystem.Init(): ()
	-- Watched (Shared/SlowWatch.lua): this handler runs once per Qi spend, and a realm's upkeep is a steady
	-- stream of them -- a slow one here shows as a burst the frame counter's scripts figure never sees.
	GameplayEvents.OnQiSpent(SlowWatch.Handler(logger, "QiDeviation.onQiSpent", onQiSpent))
	PlayerLifecycle.BindAllPlayers({
		Scope = "QiDeviationSystem",
		OnPlayerRemoving = onPlayerRemoving,
	})

	logger:info("QiDeviationSystem.Init() complete")
end

-- Not cast to Types.SystemModule -- same reasoning QiSystem.lua/TierSystem.lua/BountySystem.lua
-- give for their own returns: TestEZ needs ComputeRiskAfterSpend/IsLocked visible, not just Init.
return QiDeviationSystem
