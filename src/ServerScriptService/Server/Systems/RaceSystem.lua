--!strict
--[[
	RaceSystem.lua

	Owns: a player's ELIGIBILITY for and USE of Race Trait abilities (Shared/Race/RaceTraitTypes.
	RaceTraitDefinition, authored/held by Server/Managers/RaceManager.lua). The "System" half of the
	Race Traits + Bloodline Abilities plan's Race layer -- mirrors ArtSystem's own role relative to
	ArtTreeManager.

	ZERO NEW PlayerProfile FIELDS. Eligibility is fully DERIVED, every time it's asked: raceId (already
	persisted since chargen) plus TierSystem.GetTier(player) >= trait.RequiredTier. Nothing about which
	traits a player currently qualifies for is itself stored -- there is nothing to migrate, and
	nothing to desync from the ladder's own truth. Recomputed on PlayerDataSystem.OnProfileLoaded (a
	fresh session) and GameplayEvents.OnTierChanged (a promotion) -- never a tier-DOWN case to handle,
	since TierSystem's own tier is never-demote (TierSystem.lua's own header).

	PASSIVE VS. ACTIVE, AND WHAT RECOMPUTE ACTUALLY PUSHES. An eligible trait's Ability may be
	Kind == "Passive" (held for as long as eligibility holds -- recomputeBoundEffects below pushes its
	Effects through EffectSystem.SetBoundModifiers, keyed per-trait so an eligibility change for one
	trait never disturbs another's) or Kind == "Active" (fired on demand through CanUseAbility/
	UseAbility below, contributing NOTHING to the Bound set -- an eligible-but-unused Active ability is
	simply reachable, not continuously applying anything). recomputeBoundEffects pushes EVERY trait
	authored for the player's race on every call, not just the currently-eligible ones -- an
	ineligible or Active-kind trait gets an EMPTY effects list, which is what actually clears a stale
	Bound grant the one time this matters: a registry edit (KitEditorSystem, not built yet) that
	changes RequiredTier or Kind after a player was already granted the old shape.

	CanUseAbility vs. UseAbility is the same deliberate split ArtSystem.CanUse/UseArt already
	establishes, and for the identical reason: CanUseAbility spends nothing, so a caller probing
	whether an ability WOULD be usable never costs Qi; UseAbility re-checks every gate itself rather
	than trusting an earlier CanUseAbility call, because state (Qi, cooldown, deviation lock) can
	change between the two. They are two independent functions with duplicated gate logic, not one
	sharing a private helper -- the same shape ArtSystem.lua itself uses, for the same reason: neither
	may quietly come to trust the other having "already checked."

	Does not own: trait content (RaceManager), the generic modifier engine (EffectSystem), the
	trigger/remote path a player's request actually arrives through (KitAbilitySystem, a later phase
	of this plan -- RaceSystem exposes no remote of its own), or Qi/tier/deviation themselves (QiSystem/
	TierSystem/QiDeviationSystem).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Types = require(ReplicatedStorage.Shared.Types)
local RaceTraitTypes = require(ReplicatedStorage.Shared.Race.RaceTraitTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local GameplayEvents = require(ServerScriptService.Server.Events.GameplayEvents)
local PlayerDataSystem = require(script.Parent.PlayerDataSystem)
local QiSystem = require(script.Parent.QiSystem)
local TierSystem = require(script.Parent.TierSystem)
local QiDeviationSystem = require(script.Parent.QiDeviationSystem)
local EffectSystem = require(script.Parent.EffectSystem)
local RaceManager = require(script.Parent.Parent.Managers.RaceManager)

local logger = Logger.scope("RaceSystem")

local RaceSystem = {}

-- Per-player, per-trait cooldown expiry (os.clock() seconds) -- "own per-ability cooldown tracked in
-- RaceSystem itself" (this plan's own phrasing), a genuinely separate concept from EffectSystem's own
-- Timed-modifier expiry: a cooldown gates the NEXT UseAbility call, it grants nothing and has no
-- Spec of its own.
local cooldowns: { [Player]: { [string]: number } } = {}

local function isOnCooldown(player: Player, traitId: string): boolean
	local playerCooldowns = cooldowns[player]
	if not playerCooldowns then
		return false
	end
	local readyAt = playerCooldowns[traitId]
	return readyAt ~= nil and os.clock() < readyAt
end

local function setCooldown(player: Player, traitId: string, cooldownSeconds: number): ()
	if cooldownSeconds <= 0 then
		return
	end
	local playerCooldowns = cooldowns[player]
	if not playerCooldowns then
		playerCooldowns = {}
		cooldowns[player] = playerCooldowns
	end
	playerCooldowns[traitId] = os.clock() + cooldownSeconds
end

--
-- Reads
--

-- Every trait `player`'s current race/tier makes eligible RIGHT NOW (RequiredTier already met),
-- regardless of Ability.Kind -- {} for a player with no raceId yet (chargen not completed). Read-
-- only; never touches EffectSystem.
function RaceSystem.GetEligibleTraits(player: Player): { RaceTraitTypes.RaceTraitDefinition }
	local profile = PlayerDataSystem.GetProfile(player)
	if not profile or not profile.raceId then
		return {}
	end
	local tier = TierSystem.GetTier(player)
	local eligible: { RaceTraitTypes.RaceTraitDefinition } = {}
	for _, trait in ipairs(RaceManager.GetTraitsForRace(profile.raceId)) do
		if tier >= trait.RequiredTier then
			table.insert(eligible, trait)
		end
	end
	return eligible
end

-- Why `player` can't fire `traitId`'s ability right now, or nil if they can. Deliberately spends
-- nothing -- see this file's own header for why UseAbility does not call this internally.
function RaceSystem.CanUseAbility(player: Player, traitId: string): string?
	local trait = RaceManager.Get(traitId)
	if not trait then
		return "UnknownTrait"
	end
	if trait.Ability.Kind ~= "Active" then
		return "NotActive"
	end
	local profile = PlayerDataSystem.GetProfile(player)
	if not profile then
		return "ProfileNotLoaded"
	end
	if profile.raceId ~= trait.RaceId then
		return "WrongRace"
	end
	if TierSystem.GetTier(player) < trait.RequiredTier then
		return "TierTooLow"
	end
	if isOnCooldown(player, traitId) then
		return "OnCooldown"
	end
	if QiDeviationSystem.IsLocked(player) then
		return "QiDeviationLocked"
	end
	if trait.Ability.QiCost > 0 and QiSystem.GetQi(player) < trait.Ability.QiCost then
		return "NotEnoughQi"
	end
	return nil
end

--
-- Mutations
--

-- Pushes every trait authored for `player`'s race through EffectSystem.SetBoundModifiers -- see this
-- file's header for why every trait is pushed (not just the eligible ones) and why only a Passive
-- Ability's Effects are ever non-empty. Silent no-op for a player with no raceId yet.
local function recomputeBoundEffects(player: Player): ()
	local profile = PlayerDataSystem.GetProfile(player)
	if not profile or not profile.raceId then
		return
	end
	local tier = TierSystem.GetTier(player)
	for _, trait in ipairs(RaceManager.GetTraitsForRace(profile.raceId)) do
		local effects: { Types.ActiveModifierSpec } = {}
		if tier >= trait.RequiredTier and trait.Ability.Kind == "Passive" then
			effects = trait.Ability.Effects
		end
		EffectSystem.SetBoundModifiers(player, "RaceTrait", trait.TraitId, effects)
	end
end

-- The server-authoritative "may this player fire this Active trait ability right now, and charge/
-- apply it" gate. Returns nil if the use is allowed AND paid for; a reason string otherwise, in which
-- case nothing has been spent or applied.
--
-- Order matters, mirroring ArtSystem.UseArt's own: every non-Qi gate first (never charge for
-- something refused anyway), then Qi is spent, and only a SUCCESSFUL spend applies the ability's
-- Effects and starts its cooldown. QiSystem.Spend is itself all-or-nothing, so there is no
-- partial-payment state to unwind.
function RaceSystem.UseAbility(player: Player, traitId: string): string?
	local trait = RaceManager.Get(traitId)
	if not trait then
		return "UnknownTrait"
	end
	if trait.Ability.Kind ~= "Active" then
		return "NotActive"
	end
	local profile = PlayerDataSystem.GetProfile(player)
	if not profile then
		return "ProfileNotLoaded"
	end
	if profile.raceId ~= trait.RaceId then
		return "WrongRace"
	end
	if TierSystem.GetTier(player) < trait.RequiredTier then
		return "TierTooLow"
	end
	if isOnCooldown(player, traitId) then
		return "OnCooldown"
	end
	if QiDeviationSystem.IsLocked(player) then
		return "QiDeviationLocked"
	end

	local ability = trait.Ability
	if ability.QiCost > 0 and not QiSystem.Spend(player, ability.QiCost, `RaceTrait:{traitId}`) then
		return "NotEnoughQi"
	end

	for _, effect in ipairs(ability.Effects) do
		EffectSystem.Apply(player, "RaceTrait", traitId, effect)
	end
	setCooldown(player, traitId, ability.CooldownSeconds)

	logger:info("Race trait ability used", { player = player.Name, traitId = traitId })
	return nil
end

local function onProfileLoaded(player: Player): ()
	recomputeBoundEffects(player)
end

local function onTierChanged(player: Player): ()
	recomputeBoundEffects(player)
end

local function onPlayerRemoving(player: Player): ()
	cooldowns[player] = nil
end

function RaceSystem.Init(): ()
	cooldowns = {}

	PlayerDataSystem.OnProfileLoaded.Event:Connect(onProfileLoaded)
	GameplayEvents.OnTierChanged(function(player: Player, _newTier: number, _previousTier: number)
		onTierChanged(player)
	end)
	PlayerLifecycle.BindAllPlayers({ Scope = "RaceSystem", OnPlayerRemoving = onPlayerRemoving })

	-- Defensive pass for a profile that loaded before this Init() ran -- same reasoning QiSystem.
	-- Init()/ArtSystem.Init()/TierSystem.Init() each document for their own GetPlayers() loops.
	for _, player in ipairs(Players:GetPlayers()) do
		if PlayerDataSystem.IsLoaded(player) then
			onProfileLoaded(player)
		end
	end

	logger:info("RaceSystem.Init() complete")
end

return RaceSystem :: Types.SystemModule
