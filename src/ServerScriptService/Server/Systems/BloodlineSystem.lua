--!strict
--[[
	BloodlineSystem.lua

	Owns: a player's awakening state and stage progress through Bloodlines (Shared/Bloodline/
	BloodlineTypes.BloodlineDefinition, authored/held by Server/Managers/BloodlineManager.lua). The
	"System" half of the Race Traits + Bloodline Abilities plan's Bloodline layer -- mirrors
	RaceSystem's own role relative to RaceManager, and (more distantly) ArtSystem's relative to
	ArtTreeManager.

	HasAwakened/GetStage read Types.PlayerProfile.bloodlineIds/bloodlineStageProgress directly --
	nothing here is re-derived the way RaceSystem's own eligibility is; awakening is an EARNED,
	ONE-WAY event, not a standing computation over already-persisted facts. Awaken writes BOTH fields
	in a single PlayerDataSystem.Transform call, so a player is never left "awakened" (bloodlineIds
	carries the id) with no stage (bloodlineStageProgress has no entry) -- see that field's own header
	in Types.lua for the contract this upholds.

	INTERIM DISPATCH NOTE, mirroring MeridianSystem.lua's own header verbatim in spirit:
	software-architecture.md's documented flow is CombatSystem -> RewardSystem -> ProgressionSystem ->
	BloodlineSystem -- both RewardSystem and ProgressionSystem are still empty Init()s. Init() below
	subscribes directly to GameplayEvents.OnPlayerKilled for a first-pass awakening/advancement
	trigger on every confirmed PvP kill, the same interim shortcut MeridianSystem/RivalrySystem/
	BountySystem already took for the same reason (docs/architecture/2026-08-audit.md). This is a
	known, documented gap, not a permanent design decision: once RewardSystem/ProgressionSystem exist,
	THEY should own deciding fight-to-grow eligibility and call Awaken/AdvanceStage below -- this
	System's direct subscription should be removed at that point, not left as a second, competing
	trigger path.

	STAGE ADVANCEMENT REUSES THE SAME TRIGGER AS AWAKENING, deliberately, rather than inventing a
	second progression currency: each bloodline's AwakeningCondition (Kind + Params) is the single
	on-kill gate for BOTH the first awakening AND every subsequent stage-up -- "N additional qualifying
	kills since reaching this stage." The "since reaching this stage" count is kept as in-memory,
	SESSION-ONLY per-player-per-bloodline state (killsTowardNextStage below), never persisted -- the
	same "this whole mechanism is interim scaffolding, not permanent progression" reasoning that makes
	a rejoin restarting the count from zero an acceptable trade-off, not a bug. v1 ships exactly one
	Kind, "OnPlayerKilled", reading Params.RequiredKills (a positive number) and optionally
	Params.RequiresAscended (a truthy number gating the condition on profile.hasAscended, per
	BloodlineTypes.BloodlineAwakeningCondition's own header on a harder Human-Ascension threshold).

	Stage passives (and a Passive-kind GrantedAbility's own Effects) are applied via
	EffectSystem.SetBoundModifiers on awaken/advance and re-applied on profile load, the identical
	pattern RaceSystem.recomputeBoundEffects already establishes for its sibling content layer. An
	Active-kind GrantedAbility is never auto-bound -- it's reachable through CanUseAbility/UseAbility
	below instead, the same Passive-vs-Active split RaceSystem's own header documents.

	Does not own: bloodline content (BloodlineManager), the generic modifier engine (EffectSystem),
	the trigger/remote path a player's own ability request actually arrives through
	(KitAbilitySystem, a later phase of this plan -- BloodlineSystem exposes no remote of its own), or
	Qi/deviation themselves (QiSystem/QiDeviationSystem).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Types = require(ReplicatedStorage.Shared.Types)
local Constants = require(ReplicatedStorage.Shared.Constants)
local BloodlineTypes = require(ReplicatedStorage.Shared.Bloodline.BloodlineTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local GameplayEvents = require(ServerScriptService.Server.Events.GameplayEvents)
local PlayerDataSystem = require(script.Parent.PlayerDataSystem)
local QiSystem = require(script.Parent.QiSystem)
local QiDeviationSystem = require(script.Parent.QiDeviationSystem)
local EffectSystem = require(script.Parent.EffectSystem)
local CharacterSheetSystem = require(script.Parent.CharacterSheetSystem)
local BloodlineManager = require(script.Parent.Parent.Managers.BloodlineManager)
local BloodlineConstants = require(ReplicatedStorage.Shared.Bloodline.BloodlineConstants)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local RemoteHandler = require(ReplicatedStorage.Shared.RemoteHandler)

local logger = Logger.scope("BloodlineSystem")

local BloodlineSystem = {}

-- Per-player, per-trait cooldown expiry (os.clock() seconds) for an Active GrantedAbility -- same
-- "own per-ability cooldown tracked in the System itself" shape RaceSystem.lua's own cooldowns table
-- already establishes, keyed by BloodlineId rather than AbilityId since only one ability can ever be
-- reachable per bloodline at a time (whichever the player's CURRENT stage grants).
local cooldowns: { [Player]: { [string]: number } } = {}

-- Per-player, per-bloodline count of qualifying kills toward the NEXT awaken/advance threshold -- see
-- this file's own header on why this is interim, session-only state rather than a persisted field.
local killsTowardNextStage: { [Player]: { [string]: number } } = {}

-- Every public remote in this codebase has one -- see CLAUDE.md's own module table. The spin is
-- the first remote this System has ever exposed; everything else here is a server-side API other
-- Systems call directly.
local spinRateLimiter = RateLimiter.New(Constants.NetworkBudget.MaxRemoteCallsPerSecondPerPlayer)

local function isOnCooldown(player: Player, bloodlineId: string): boolean
	local playerCooldowns = cooldowns[player]
	if not playerCooldowns then
		return false
	end
	local readyAt = playerCooldowns[bloodlineId]
	return readyAt ~= nil and os.clock() < readyAt
end

local function setCooldown(player: Player, bloodlineId: string, cooldownSeconds: number): ()
	if cooldownSeconds <= 0 then
		return
	end
	local playerCooldowns = cooldowns[player]
	if not playerCooldowns then
		playerCooldowns = {}
		cooldowns[player] = playerCooldowns
	end
	playerCooldowns[bloodlineId] = os.clock() + cooldownSeconds
end

local function maxStageIndexOf(bloodline: BloodlineTypes.BloodlineDefinition): number
	local maxIndex = 0
	for _, stage in ipairs(bloodline.Stages) do
		maxIndex = math.max(maxIndex, stage.StageIndex)
	end
	return maxIndex
end

local function stageDefinitionAt(
	bloodline: BloodlineTypes.BloodlineDefinition,
	stageIndex: number
): BloodlineTypes.BloodlineStageDefinition?
	for _, stage in ipairs(bloodline.Stages) do
		if stage.StageIndex == stageIndex then
			return stage
		end
	end
	return nil
end

--
-- Reads
--

function BloodlineSystem.HasAwakened(player: Player, bloodlineId: string): boolean
	local profile = PlayerDataSystem.GetProfile(player)
	if not profile then
		return false
	end
	return table.find(profile.bloodlineIds, bloodlineId) ~= nil
end

-- 0 means not awakened -- BloodlineStageDefinition.StageIndex is always >= 1 (Constants.Kit.Limits.
-- StageIndex), so 0 can never collide with a real stage.
function BloodlineSystem.GetStage(player: Player, bloodlineId: string): number
	local profile = PlayerDataSystem.GetProfile(player)
	if not profile then
		return 0
	end
	return profile.bloodlineStageProgress[bloodlineId] or 0
end

-- Why `player` can't fire `bloodlineId`'s `abilityId` ability right now, or nil if they can.
-- Deliberately spends nothing -- same "CanUseAbility never commits" contract RaceSystem.
-- CanUseAbility already establishes. Disambiguated by the full (bloodlineId, abilityId) pair, not
-- bloodlineId alone -- a player may only ever use their CURRENT stage's GrantedAbility, and abilityId
-- is what confirms the caller (KitAbilitySystem, a later phase) is asking about that exact grant and
-- not a stale one from a stage already left behind.
function BloodlineSystem.CanUseAbility(player: Player, bloodlineId: string, abilityId: string): string?
	local bloodline = BloodlineManager.Get(bloodlineId)
	if not bloodline then
		return "UnknownBloodline"
	end
	local stageIndex = BloodlineSystem.GetStage(player, bloodlineId)
	if stageIndex == 0 then
		return "NotAwakened"
	end
	local stage = stageDefinitionAt(bloodline, stageIndex)
	if not stage or not stage.GrantedAbility then
		return "NoGrantedAbility"
	end
	if stage.GrantedAbility.Id ~= abilityId then
		return "WrongStage"
	end
	if stage.GrantedAbility.Kind ~= "Active" then
		return "NotActive"
	end
	if isOnCooldown(player, bloodlineId) then
		return "OnCooldown"
	end
	if QiDeviationSystem.IsLocked(player) then
		return "QiDeviationLocked"
	end
	if stage.GrantedAbility.QiCost > 0 and QiSystem.GetQi(player) < stage.GrantedAbility.QiCost then
		return "NotEnoughQi"
	end
	return nil
end

--
-- Mutations
--

-- Pushes every registered bloodline's CURRENT-stage effects through EffectSystem.SetBoundModifiers --
-- PassiveEffects always, plus a Passive-kind GrantedAbility's own Effects, empty for a bloodline the
-- player hasn't awakened (or whose current stage grants nothing) -- the identical "push every
-- registry entry, empty when not applicable" shape RaceSystem.recomputeBoundEffects already
-- establishes for its sibling content layer.
local function recomputeBoundEffects(player: Player): ()
	local profile = PlayerDataSystem.GetProfile(player)
	if not profile then
		return
	end
	for _, bloodline in ipairs(BloodlineManager.List()) do
		local currentStageIndex = profile.bloodlineStageProgress[bloodline.BloodlineId]
		local effects: { Types.ActiveModifierSpec } = {}
		local stage = if currentStageIndex then stageDefinitionAt(bloodline, currentStageIndex) else nil
		if stage then
			for _, effect in ipairs(stage.PassiveEffects) do
				table.insert(effects, effect)
			end
			if stage.GrantedAbility and stage.GrantedAbility.Kind == "Passive" then
				for _, effect in ipairs(stage.GrantedAbility.Effects) do
					table.insert(effects, effect)
				end
			end
		end
		EffectSystem.SetBoundModifiers(player, "BloodlineStage", bloodline.BloodlineId, effects)
	end
end

-- Awakens `bloodlineId` for `player` -- writes bloodlineIds/bloodlineStageProgress together in ONE
-- Transform (this file's own header on why), applies stage 1's Bound effects, replicates the change
-- through CharacterSheetSystem's existing channel (no new remote -- BloodlineStageProgress rides the
-- same Character_SheetUpdated push BloodlineIds always has), and fires GameplayEvents.
-- BloodlineAwakened only on a genuine success. Returns nil on success, a reason string otherwise.
function BloodlineSystem.Awaken(player: Player, bloodlineId: string, reason: string?): string?
	local bloodline = BloodlineManager.Get(bloodlineId)
	if not bloodline then
		return "UnknownBloodline"
	end
	if BloodlineSystem.HasAwakened(player, bloodlineId) then
		return "AlreadyAwakened"
	end
	local profile = PlayerDataSystem.GetProfile(player)
	if not profile then
		return "ProfileNotLoaded"
	end
	-- nil = obtainable by a player of any race (BloodlineDefinition.NativeRaceId's own header).
	if bloodline.NativeRaceId ~= nil and profile.raceId ~= bloodline.NativeRaceId then
		return "WrongRace"
	end

	local committed = PlayerDataSystem.Transform(player, function(mutableProfile)
		table.insert(mutableProfile.bloodlineIds, bloodlineId)
		mutableProfile.bloodlineStageProgress[bloodlineId] = 1
	end)
	if not committed then
		return "ProfileNotLoaded"
	end

	logger:info("Bloodline awakened", { player = player.Name, bloodlineId = bloodlineId, reason = reason })
	recomputeBoundEffects(player)
	CharacterSheetSystem.Refresh(player)
	GameplayEvents.FireBloodlineAwakened(player, bloodlineId, reason)
	return nil
end

-- Every bloodline this player could legitimately be given right now: authored, not already
-- awakened, and either race-agnostic or native to the race they picked. Exported for the spec and
-- for the client's own "what could I even roll" display -- and because a weighted draw over a set
-- is much easier to trust when the set itself is inspectable.
--
-- Deliberately mirrors Awaken's own three refusals rather than re-deciding them: anything this
-- returns must actually survive Awaken, or the spin would land on something and then fail.
function BloodlineSystem.EligibleForSpin(player: Player): { BloodlineTypes.BloodlineDefinition }
	local profile = PlayerDataSystem.GetProfile(player)
	if not profile then
		return {}
	end
	local eligible: { BloodlineTypes.BloodlineDefinition } = {}
	for _, bloodline in ipairs(BloodlineManager.List()) do
		local nativeOk = bloodline.NativeRaceId == nil or profile.raceId == bloodline.NativeRaceId
		if nativeOk and profile.bloodlineStageProgress[bloodline.BloodlineId] == nil then
			table.insert(eligible, bloodline)
		end
	end
	return eligible
end

-- Draws one bloodline from `candidates`, weighted by RarityTier. Pure apart from the RNG, and
-- separated from Spin below precisely so the weighting can be tested without a Player, a profile
-- or a DataStore -- `roll` is the [0, 1) sample, injected rather than taken from math.random here.
--
-- Standard cumulative-weight walk. The final `or` is not dead: floating-point summation means a
-- roll of 0.999... can land a hair past the accumulated total, and returning nil there would look
-- like "nothing eligible" to the caller rather than what it is (a rounding tail).
function BloodlineSystem.DrawWeighted(
	candidates: { BloodlineTypes.BloodlineDefinition },
	roll: number
): BloodlineTypes.BloodlineDefinition?
	if #candidates == 0 then
		return nil
	end
	local total = 0
	for _, bloodline in ipairs(candidates) do
		total += BloodlineConstants.WeightFor(bloodline.RarityTier)
	end
	if total <= 0 then
		return nil
	end

	local target = math.clamp(roll, 0, 1) * total
	local accumulated = 0
	for _, bloodline in ipairs(candidates) do
		accumulated += BloodlineConstants.WeightFor(bloodline.RarityTier)
		if target < accumulated then
			return bloodline
		end
	end
	return candidates[#candidates]
end

-- Rolls one bloodline for `player` and awakens it. Returns (bloodlineId, nil) on success or
-- (nil, reason) otherwise.
--
-- SPENDS BEFORE IT GRANTS, and the order is the point: the FIRST spin of a player's life is free
-- (they hold no bloodline yet), and every one after it costs a reroll. Charging first means a
-- player who somehow reaches Awaken and has it refuse has still paid -- so Awaken's refusals are
-- pre-checked by EligibleForSpin above instead, and the charge and the grant commit through the
-- same profile the same way ArtSystem.UseArt orders its own spend against a use.
--
-- The RNG is SERVER-SIDE and unseeded-per-call on purpose. Roblox seeds Random.new() from the
-- engine; a client-supplied roll, or a shared generator a client could observe the sequence of,
-- would make the odds negotiable.
function BloodlineSystem.Spin(player: Player): (string?, string?)
	local profile = PlayerDataSystem.GetProfile(player)
	if not profile then
		return nil, "ProfileNotLoaded"
	end
	-- A bloodline is character identity, and NativeRaceId eligibility is meaningless without a race
	-- -- so spinning before chargen has picked one would silently narrow the pool to race-agnostic
	-- bloodlines only. The creator gates the button on this too; this is the authority.
	if profile.raceId == nil then
		return nil, "NoRaceChosen"
	end

	-- "Has had the free roll" IS "holds a bloodline" -- see PlayerProfile.bloodlineRerolls' header
	-- on why that is not a second persisted flag.
	local isFreeRoll = #profile.bloodlineIds == 0
	if not isFreeRoll and profile.bloodlineRerolls <= 0 then
		return nil, "NoRerollsLeft"
	end

	-- Computed BEFORE the clear below, deliberately: EligibleForSpin excludes what the player
	-- already holds, so drawing first is what stops a reroll from handing back the exact bloodline
	-- it just replaced.
	local candidates = BloodlineSystem.EligibleForSpin(player)
	if #candidates == 0 then
		-- Reached today by every player, because nothing has authored a bloodline yet -- the registry
		-- is populated only through the Kit Editor. A named refusal rather than a crash or a silent
		-- no-op, so the creator can say something true instead of looking broken.
		return nil, "NoBloodlinesAvailable"
	end

	local drawn = BloodlineSystem.DrawWeighted(candidates, Random.new():NextNumber())
	if not drawn then
		return nil, "NoBloodlinesAvailable"
	end

	if not isFreeRoll then
		-- A REROLL REPLACES, it does not accumulate -- charge and clear in ONE Transform so a player
		-- can never be left having paid for a roll that then failed to take, or holding two
		-- bloodlines because the write tore in half.
		--
		-- Replacing is what the word means: you are rolling FOR your blood, not collecting it. Before
		-- this, Awaken's own table.insert meant every reroll added another bloodline, so a player with
		-- rerolls to spend would end up carrying the whole roster with every one of their Bound stat
		-- stacks live at once, while the card only ever showed the newest. The stage ladder goes with
		-- it -- rerolling away a bloodline you have ground up IS the cost, and it is what stops a
		-- reroll from being strictly free once you are deep in one.
		--
		-- Clearing bloodlineStageProgress is also what releases the old Bound effects:
		-- recomputeBoundEffects walks the whole registry and writes an EMPTY modifier set for any
		-- bloodline the player has no stage in, so Awaken's own call below does the release for free.
		local charged = PlayerDataSystem.Transform(player, function(mutableProfile)
			mutableProfile.bloodlineRerolls = math.max(0, mutableProfile.bloodlineRerolls - 1)
			table.clear(mutableProfile.bloodlineIds)
			table.clear(mutableProfile.bloodlineStageProgress)
		end)
		if not charged then
			return nil, "ProfileNotLoaded"
		end
	end

	-- Awaken owns the actual grant, the Bound effects, the sheet refresh and the GameplayEvents
	-- fire -- a spin is a new way to REACH awakening, never a second implementation of it.
	local refusal = BloodlineSystem.Awaken(player, drawn.BloodlineId, "Spin")
	if refusal then
		logger:warn(
			"Spin drew a bloodline Awaken then refused",
			{ player = player.Name, bloodlineId = drawn.BloodlineId, reason = refusal }
		)
		return nil, refusal
	end
	return drawn.BloodlineId, nil
end

-- Advances `player`'s stage in `bloodlineId` by exactly one. Refuses if not yet awakened, already at
-- the highest authored StageIndex, or the next StageIndex has no authored stage (a gap in the
-- authored list, BloodlineManager.AuditStages' own concern to have already flagged at boot -- this is
-- the runtime-side refusal that keeps a gap from silently stranding a player's progress).
-- Adds `amount` rerolls to `player`'s profile and returns the new total. Refuses rather than
-- clamping silently on a nonsense amount, so a caller passing garbage hears about it.
--
-- NOT REACHABLE BY A PLAYER, and the boundary is one layer up rather than here: this is a plain
-- server-side API like Awaken/AdvanceStage beside it, and the only thing that calls it is
-- DevMenuSystem's own AdminGate-checked handler. That is the same split every other admin-driven
-- mutation in this codebase uses (see AdminGate.lua's header) -- the System owns the rule, the
-- DevMenu handler owns "are you allowed to ask".
--
-- Exists because rerolls had exactly one source in the entire game: the 3 that
-- BloodlineConstants.StartingRerolls puts on a fresh profile. Once those were spent the reroll
-- control in the character menu was permanently disabled with no way for anyone -- including whoever
-- is testing the bloodline system -- to get another. PlayerProfile.bloodlineRerolls' own header
-- calls the missing grant path a deliberate stub; this fills in the developer half of it without
-- inventing the live-ops half (a shop, a quest reward, a tier-up grant) that is still a design
-- decision nobody has made.
function BloodlineSystem.GrantRerolls(player: Player, amount: number): (number?, string?)
	if typeof(amount) ~= "number" or amount ~= amount or amount < 1 or amount ~= math.floor(amount) then
		return nil, "InvalidAmount"
	end

	local granted: number? = nil
	local ok = PlayerDataSystem.Transform(player, function(mutableProfile)
		-- Clamped against the ceiling INSIDE the transform, off the profile's own live value, rather
		-- than computed from a value read before it -- two grants landing in the same frame would
		-- otherwise both add to the same stale total and overshoot.
		granted = math.min(mutableProfile.bloodlineRerolls + amount, BloodlineConstants.MaxHeldRerolls)
		mutableProfile.bloodlineRerolls = granted :: number
	end)
	if not ok then
		return nil, "ProfileNotLoaded"
	end

	-- The character menu reads its reroll count off the sheet, so without this the number on screen
	-- stays stale until something else happens to refresh it -- exactly the "worked, looked broken"
	-- gap Awaken's own Refresh call exists to close.
	CharacterSheetSystem.Refresh(player)
	logger:info("Rerolls granted", { player = player.Name, amount = amount, total = granted })
	return granted, nil
end

function BloodlineSystem.AdvanceStage(player: Player, bloodlineId: string): string?
	local bloodline = BloodlineManager.Get(bloodlineId)
	if not bloodline then
		return "UnknownBloodline"
	end
	local currentStage = BloodlineSystem.GetStage(player, bloodlineId)
	if currentStage == 0 then
		return "NotAwakened"
	end
	if currentStage >= maxStageIndexOf(bloodline) then
		return "AlreadyAtMaxStage"
	end
	local nextStage = currentStage + 1
	if not stageDefinitionAt(bloodline, nextStage) then
		return "StageGap"
	end

	local committed = PlayerDataSystem.Transform(player, function(profile)
		profile.bloodlineStageProgress[bloodlineId] = nextStage
	end)
	if not committed then
		return "ProfileNotLoaded"
	end

	logger:info("Bloodline stage advanced", { player = player.Name, bloodlineId = bloodlineId, stage = nextStage })
	recomputeBoundEffects(player)
	CharacterSheetSystem.Refresh(player)
	return nil
end

-- The server-authoritative "may this player fire their current stage's Active ability right now, and
-- charge/apply it" gate -- same independent-duplication shape RaceSystem.UseAbility's own header
-- explains: re-checks every gate itself rather than trusting an earlier CanUseAbility call, since Qi/
-- cooldown/deviation-lock state can change between the two.
function BloodlineSystem.UseAbility(player: Player, bloodlineId: string, abilityId: string): string?
	local bloodline = BloodlineManager.Get(bloodlineId)
	if not bloodline then
		return "UnknownBloodline"
	end
	local stageIndex = BloodlineSystem.GetStage(player, bloodlineId)
	if stageIndex == 0 then
		return "NotAwakened"
	end
	local stage = stageDefinitionAt(bloodline, stageIndex)
	if not stage or not stage.GrantedAbility then
		return "NoGrantedAbility"
	end
	if stage.GrantedAbility.Id ~= abilityId then
		return "WrongStage"
	end
	if stage.GrantedAbility.Kind ~= "Active" then
		return "NotActive"
	end
	if isOnCooldown(player, bloodlineId) then
		return "OnCooldown"
	end
	if QiDeviationSystem.IsLocked(player) then
		return "QiDeviationLocked"
	end

	local ability = stage.GrantedAbility
	if ability.QiCost > 0 and not QiSystem.Spend(player, ability.QiCost, `BloodlineStage:{bloodlineId}`) then
		return "NotEnoughQi"
	end

	for _, effect in ipairs(ability.Effects) do
		EffectSystem.Apply(player, "BloodlineStage", bloodlineId, effect)
	end
	setCooldown(player, bloodlineId, ability.CooldownSeconds)

	logger:info("Bloodline stage ability used", { player = player.Name, bloodlineId = bloodlineId })
	return nil
end

--
-- Interim on-kill dispatch (this file's own header)
--

-- Kind/Params reader for the one Kind v1 ships. Returns nil (never a fallback number) for a
-- different/malformed Kind or a missing/non-positive RequiredKills -- an unauthored or mis-authored
-- condition should never silently default to SOME threshold, since that would award a bloodline the
-- author never actually finished configuring.
local function requiredKillsFor(condition: BloodlineTypes.BloodlineAwakeningCondition): number?
	if condition.Kind ~= "OnPlayerKilled" then
		return nil
	end
	local required = condition.Params.RequiredKills
	if typeof(required) ~= "number" or required <= 0 then
		return nil
	end
	return required
end

-- The harder Human-Ascension threshold BloodlineAwakeningCondition's own header names: a truthy
-- Params.RequiresAscended additionally gates the condition on profile.hasAscended. Absent/zero means
-- no extra gate, which is the correct default for every ordinary bloodline.
local function meetsAscensionGate(
	condition: BloodlineTypes.BloodlineAwakeningCondition,
	profile: Types.PlayerProfile
): boolean
	local requiresAscended = condition.Params.RequiresAscended
	if typeof(requiresAscended) == "number" and requiresAscended > 0 then
		return profile.hasAscended
	end
	return true
end

local function onPlayerKilled(_victim: Player, killer: Player?): ()
	if killer == nil then
		return
	end
	local profile = PlayerDataSystem.GetProfile(killer)
	if not profile then
		return
	end

	-- ADVANCEMENT ONLY -- this loop never awakens anything any more, and that is the whole shape of
	-- the feature. A bloodline is OBTAINED by the roll at character creation (BloodlineSystem.Spin);
	-- combat is what carries it up its stage ladder. progression-systems.md pins the second half
	-- down ("a real in-combat achievement, not a purchase or timer -- reinforcing fight-to-grow") and
	-- says nothing about the first, because blood is not earned.
	--
	-- It used to Awaken here too, which was correct while on-kill was the ONLY acquisition path and
	-- became a real bug the moment the roll existed: this walks the whole registry, so a player who
	-- kept killing would have accumulated every bloodline in the game side by side, each with its own
	-- Bound stat stack, rather than carrying the one they drew.
	for _, bloodlineId in ipairs(profile.bloodlineIds) do
		local bloodline = BloodlineManager.Get(bloodlineId)
		if not bloodline then
			-- Held in the profile but no longer in the registry (an admin deleted it through the Kit
			-- Editor, say). Nothing to advance toward; the profile entry is left alone rather than
			-- cleaned up here, since this handler has no business rewriting what a player owns.
			continue
		end
		local requiredKills = requiredKillsFor(bloodline.AwakeningCondition)
		if not requiredKills or not meetsAscensionGate(bloodline.AwakeningCondition, profile) then
			-- RequiresAscended lands here: Tianlong sits in an un-ascended carrier and refuses to climb.
			-- See DefaultBloodlineRegistry's own note on why that gap IS the contested-authority story.
			continue
		end
		if BloodlineSystem.GetStage(killer, bloodlineId) >= maxStageIndexOf(bloodline) then
			-- Already at the top of this bloodline's ladder -- nothing left to count toward.
			continue
		end

		local playerKills = killsTowardNextStage[killer]
		if not playerKills then
			playerKills = {}
			killsTowardNextStage[killer] = playerKills
		end
		local kills = (playerKills[bloodlineId] or 0) + 1

		if kills < requiredKills then
			playerKills[bloodlineId] = kills
			continue
		end

		playerKills[bloodlineId] = 0
		BloodlineSystem.AdvanceStage(killer, bloodlineId)
	end
end

local function onProfileLoaded(player: Player): ()
	recomputeBoundEffects(player)
end

local function onPlayerRemoving(player: Player): ()
	cooldowns[player] = nil
	spinRateLimiter:Clear(player)
	killsTowardNextStage[player] = nil
end

-- Reads the reroll count straight off the profile rather than tracking it alongside -- see
-- BloodlineSpinResult on why every response carries it.
local function rerollsRemaining(player: Player): number
	local profile = PlayerDataSystem.GetProfile(player)
	return if profile then profile.bloodlineRerolls else 0
end

local function handleSpin(player: Player): BloodlineTypes.BloodlineSpinResult
	if spinRateLimiter:IsLimited(player) then
		return { Success = false, Reason = "RateLimited", RerollsRemaining = rerollsRemaining(player) }
	end
	local bloodlineId, reason = BloodlineSystem.Spin(player)
	if not bloodlineId then
		return { Success = false, Reason = reason, RerollsRemaining = rerollsRemaining(player) }
	end
	-- Guaranteed present: Spin only returns an id it just drew from the registry.
	local drawn = BloodlineManager.Get(bloodlineId)
	return {
		Success = true,
		BloodlineId = bloodlineId,
		DisplayName = if drawn then drawn.DisplayName else bloodlineId,
		RarityTier = if drawn then drawn.RarityTier else "",
		FlavorText = if drawn then drawn.FlavorText else "",
		RerollsRemaining = rerollsRemaining(player),
	}
end

function BloodlineSystem.Init(): ()
	cooldowns = {}
	killsTowardNextStage = {}

	PlayerDataSystem.OnProfileLoaded.Event:Connect(onProfileLoaded)
	GameplayEvents.OnPlayerKilled(onPlayerKilled)
	PlayerLifecycle.BindAllPlayers({ Scope = "BloodlineSystem", OnPlayerRemoving = onPlayerRemoving })

	-- Defensive pass for a profile that loaded before this Init() ran -- same reasoning QiSystem.
	-- Init()/ArtSystem.Init()/RaceSystem.Init() each document for their own GetPlayers() loops.
	for _, player in ipairs(Players:GetPlayers()) do
		if PlayerDataSystem.IsLoaded(player) then
			onProfileLoaded(player)
		end
	end

	-- The first and only remote this System exposes -- everything else here is a server-side API
	-- other Systems call directly. A RemoteFunction because the creator has to render what was
	-- rolled; see BloodlineTypes.BloodlineSpinResult.
	local spinRemote = NetworkBridge.CreateRemoteFunction(BloodlineConstants.RemoteNames.Spin)
	spinRemote.OnServerInvoke = RemoteHandler.WrapInvoke(
		logger,
		"Spin",
		{ Success = false, Reason = "InternalError", RerollsRemaining = 0 } :: BloodlineTypes.BloodlineSpinResult,
		handleSpin
	)

	logger:info("BloodlineSystem.Init() complete")
end

return BloodlineSystem :: Types.SystemModule
