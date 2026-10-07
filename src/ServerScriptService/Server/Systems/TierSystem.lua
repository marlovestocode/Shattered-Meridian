--!strict
--[[
	TierSystem.lua

	Owns: the tier ladder's evaluation and promotion -- deciding when a player's persisted Meridian
	XP total has crossed a TierConstants threshold, committing the new tier to their profile, and
	announcing it (to the owning client over Progression_TierUpdated, and to other Systems over
	GameplayEvents.TierChanged). This is the consumer that closes the Meridian loop: before it,
	MeridianSystem awarded XP, persisted it, and replicated it to a client field nothing rendered and
	no System read -- a correct chain that terminated one link short of meaning anything.

	Does not own: awarding Meridian XP (MeridianSystem), persisting it (PlayerDataSystem -- this
	System, like MeridianSystem, mutates only through Transform and never writes a DataStore itself),
	the tier ladder's NUMBERS (Shared/TierConstants.lua owns every one, see that file's own
	dynamic-tuning contract), or what a tier is worth mechanically. It PUBLISHES the tier as a Player
	Attribute (AttributeConstants.CultivationTier) and Shared/Progression/CombatPower.lua decides what a
	gap between two of them is worth in a fight -- the same signal-not-call boundary as Max Qi. That last one is the important
	boundary: QiConstants.MaxQiByTier already prices tier into Max Qi and owns that curve on its own,
	and this System never reads it -- it fires TierChanged and QiSystem decides what its own ceiling
	should be (GameplayEvents.FireTierChanged's own header on why that's a signal, not a call).

	PROMOTION IS ONE-WAY -- Evaluate never demotes. Meridian XP is grant-only by construction
	(MeridianSystem.AwardMeridianXP's header: there is deliberately no SubtractMeridianXP), so the
	only way a loaded profile's stored tier can exceed what its XP computes to is a designer raising
	a TierConstants threshold after that player was already promoted. Taking a tier back from a
	player because a number was retuned under them is the worst possible reading of that edit, so
	Evaluate applies `math.max(stored, computed)` and a retune upward simply makes the NEXT tier
	cost more. Retuning downward promotes everyone it should, on their next profile load, for free.

	NO PER-PLAYER STATE -- deliberately, and it's the whole reason this file has no PlayerRemoving
	hook. Every read goes through PlayerDataSystem.GetProfile; there is no tierStates table to leak
	Player references into. docs/architecture/2026-08-audit.md flagged that exact leak class twice
	(section 3.2 in RivalrySystem, section 3.6.2 in BountySystem, both keyed by departed players),
	and the cheapest way to not be the third is to hold no keyed state at all. The tradeoff is real
	and accepted: GetProfile is a deep copy (~9 heap tables per call, see PlayerDataSystem's own
	header), so this System must never read from a per-frame path -- and it doesn't. Evaluate runs on
	exactly two edges, a profile load and a confirmed XP grant, both of which are already doing far
	more expensive work.

	CATCH-UP ON LOAD is not redundant with the XP subscription. A profile can arrive already owed a
	promotion -- thresholds were lowered between sessions, or (once RewardSystem/AchievementSystem
	exist) XP was granted through a path that predates this System. Evaluating once at load means the
	ladder is self-correcting rather than depending on every historical grant having fired an event
	this System was listening for.

	Boots after MeridianSystem and QiSystem in Main.server.lua, but does not require that order to be
	correct: it subscribes to GameplayEvents (which has no Init() and no boot order at all) rather
	than to either module directly, and its own defensive GetPlayers() loop covers any profile that
	loaded before this Init() ran -- the same pattern QiSystem.Init() documents for itself.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)
local Types = require(ReplicatedStorage.Shared.Types)
local TierConstants = require(ReplicatedStorage.Shared.TierConstants)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Logger = require(ReplicatedStorage.Shared.Logger)
local GameplayEvents = require(ServerScriptService.Server.Events.GameplayEvents)
local PlayerDataSystem = require(script.Parent.PlayerDataSystem)

local logger = Logger.scope("TierSystem")

local TierSystem = {}

local tierUpdatedRemote: RemoteEvent? = nil

--
-- Pure ladder math. Plain numbers in, plain numbers out -- no Player, no profile, no Instance -- so
-- the regression suite exercises the real promotion curve headlessly rather than a reimplementation
-- of it. Same "extract the pure math so it's TestEZ-coverable" split Shared/FlightMath.lua
-- established and QiSystem.ComputeMaxQi already follows.
--

-- The highest tier whose cumulative threshold `meridianXp` has met. Clamped into the ladder at both
-- ends: negative/NaN XP resolves to tier 1 rather than 0 or an error, and XP beyond the last
-- threshold stays at TierConstants.MaxTier rather than running off the end of the table.
function TierSystem.ComputeTierForXP(meridianXp: number): number
	if typeof(meridianXp) ~= "number" or meridianXp ~= meridianXp then
		-- NaN fails every comparison below, including `>=`, so it would otherwise fall through the
		-- loop and return tier 1 by accident rather than by decision. Say so explicitly.
		return 1
	end

	local resolved = 1
	for tier = 2, TierConstants.MaxTier do
		if meridianXp >= TierConstants.Tiers[tier].MeridianXP then
			resolved = tier
		else
			-- Thresholds ascend strictly (TierConstants.Validate), so the first one not met means no
			-- later one is either -- stop rather than scanning the rest of the ladder.
			break
		end
	end
	return resolved
end

-- Cumulative Meridian XP required to hold `tier`. Returns the tier-1 floor (0) for anything below
-- the ladder and the top threshold for anything above it, so a caller never has to bounds-check
-- before asking.
function TierSystem.GetThresholdForTier(tier: number): number
	local clamped = math.clamp(math.floor(tier), 1, TierConstants.MaxTier)
	return TierConstants.Tiers[clamped].MeridianXP
end

-- Display name for `tier`. Out-of-ladder tiers get TierConstants.UnknownTierName rather than an
-- error -- see that constant's own header on why a corrupted tier number should degrade to a wrong
-- label instead of breaking the HUD mount.
function TierSystem.GetTierName(tier: number): string
	if typeof(tier) ~= "number" or tier ~= tier then
		return TierConstants.UnknownTierName
	end
	local floored = math.floor(tier)
	if floored < 1 or floored > TierConstants.MaxTier then
		return TierConstants.UnknownTierName
	end
	return TierConstants.Tiers[floored].Name
end

-- The XP window `tier` occupies: (floor, ceiling). Ceiling is nil at TierConstants.MaxTier -- there
-- is no next threshold, and returning the same number twice (or a fake one) would make a progress
-- bar at max tier either divide by zero or render permanently empty. nil forces the caller to decide
-- what "no next tier" looks like, which is a presentation question (see this System's replication
-- payload and Components/TierBadge.lua).
function TierSystem.GetTierWindow(tier: number): (number, number?)
	local clamped = math.clamp(math.floor(tier), 1, TierConstants.MaxTier)
	local floor = TierConstants.Tiers[clamped].MeridianXP
	if clamped >= TierConstants.MaxTier then
		return floor, nil
	end
	return floor, TierConstants.Tiers[clamped + 1].MeridianXP
end

--
-- Player-facing reads. Every one goes through PlayerDataSystem live -- nothing is cached here (see
-- this file's header on holding no per-player state).
--

-- The player's persisted tier, or Tier 1's floor for a profile that isn't loaded yet -- the same
-- "safe default, never an error" contract MeridianSystem.GetMeridianXP already returns 0 under.
function TierSystem.GetTier(player: Player): number
	local profile = PlayerDataSystem.GetProfile(player)
	return if profile then profile.tier else 1
end

local function buildPayload(tier: number, previousTier: number?): Types.TierUpdatePayload
	local floor, ceiling = TierSystem.GetTierWindow(tier)
	return {
		Tier = tier,
		TierName = TierSystem.GetTierName(tier),
		TierFloorXP = floor,
		TierNextXP = ceiling,
		PreviousTier = previousTier,
	}
end

-- Publishes `tier` on the Player (AttributeConstants.CultivationTier): the one place combat reads a tier
-- from (Shared/Progression/CombatPower.lua -- a combat layer must never call into this System, and a
-- profile read per hit would be a deep copy per hit), and what an opponent's client can show. Written on
-- the same two edges as the remote below, so it is never newer or older than what the owner was told.
local function publishTier(player: Player, tier: number): ()
	player:SetAttribute(AttributeConstants.CultivationTier, tier)
end

-- Replicates `tier` to its owning client only. `previousTier` is passed ONLY for a real promotion --
-- it is what lets the client tell "here is your tier, you just logged in" apart from "you just ranked
-- up" without having to remember its own previous value and guess. See Types.TierUpdatePayload.
local function sendTierUpdate(player: Player, tier: number, previousTier: number?): ()
	publishTier(player, tier)
	if not tierUpdatedRemote then
		return
	end
	tierUpdatedRemote:FireClient(player, buildPayload(tier, previousTier))
end

-- Recomputes the tier `player`'s current Meridian XP entitles them to and promotes if it's higher
-- than what they hold. Returns true only when a promotion actually happened, so a caller can tell a
-- real tier-up from a no-op check -- and so the two callers below don't have to re-read the profile
-- to find out.
--
-- A single grant crossing two thresholds promotes straight to the final tier in one step rather than
-- walking the ladder one rung per event: the intermediate tiers were never held, so announcing them
-- would be announcing a state that never existed. TierChanged carries `previousTier` precisely so a
-- subscriber can see the full jump (GameplayEvents.FireTierChanged's own header).
function TierSystem.Evaluate(player: Player): boolean
	local profile = PlayerDataSystem.GetProfile(player)
	if not profile then
		return false
	end

	local previousTier = profile.tier
	local computed = TierSystem.ComputeTierForXP(profile.meridianXp)
	if computed <= previousTier then
		-- Already at or above what this XP earns -- including the deliberate never-demote case (see
		-- this file's header).
		return false
	end

	local committed = PlayerDataSystem.Transform(player, function(liveProfile)
		liveProfile.tier = computed
	end)
	if not committed then
		-- GetProfile returned a copy a moment ago but Transform refused -- the profile unloaded
		-- between the two (the player left mid-evaluation). Not an error worth escalating, but worth
		-- a record: the promotion did not happen and nothing downstream should think it did.
		logger:warn("Tier promotion not committed: profile no longer loaded", {
			player = player.Name,
			tier = computed,
		})
		return false
	end

	logger:info("Tier promotion", {
		player = player.Name,
		previousTier = previousTier,
		newTier = computed,
		meridianXp = profile.meridianXp,
	})

	-- Client first, then the server-internal signal: the promotion is already persisted by this
	-- point, so neither ordering is a correctness question, and the owning player seeing their own
	-- tier-up on the same frame it commits is the one part of this that's latency-visible.
	sendTierUpdate(player, computed, previousTier)
	GameplayEvents.FireTierChanged(player, computed, previousTier)
	return true
end

local function onProfileLoaded(player: Player): ()
	-- Catch-up first (see this file's header) -- if it promotes, Evaluate has already replicated the
	-- new tier and there is nothing left to send.
	if TierSystem.Evaluate(player) then
		return
	end
	sendTierUpdate(player, TierSystem.GetTier(player), nil)
end

function TierSystem.Init(): ()
	local ladderOk, ladderProblem = TierConstants.Validate()
	if not ladderOk then
		-- Never fatal: a mis-edited ladder should degrade to a wrong-feeling progression curve on a
		-- live server, not a failed require that takes every System booting after this one down with
		-- it (TierConstants.Validate's own header). The regression suite is where this is meant to
		-- be caught; this log is the backstop for a hand-edit that never ran it.
		logger:warn("TierConstants ladder failed validation -- promotions may behave unexpectedly", {
			problem = ladderProblem,
		})
	end

	tierUpdatedRemote = NetworkBridge.CreateRemoteEvent(TierConstants.RemoteNames.TierUpdated)

	PlayerDataSystem.OnProfileLoaded.Event:Connect(onProfileLoaded)

	-- The promotion trigger: react to the XP total changing, not to the kill that changed it. See
	-- GameplayEvents.FireMeridianXPAwarded's header for why this subscription is deliberately one
	-- step removed from OnPlayerKilled.
	GameplayEvents.OnMeridianXPAwarded(function(player: Player)
		TierSystem.Evaluate(player)
	end)

	-- Defensive pass for any profile that finished loading before this Init() ran -- same reasoning
	-- as QiSystem.Init()'s and PlayerDataSystem.Init()'s own GetPlayers() loops.
	for _, player in ipairs(Players:GetPlayers()) do
		if PlayerDataSystem.IsLoaded(player) then
			onProfileLoaded(player)
		end
	end

	logger:info("TierSystem.Init() complete", { maxTier = TierConstants.MaxTier })
end

return TierSystem :: Types.SystemModule
