--!strict
--[[
	BootManifest.lua

	Owns: the declared answer to "what is this server supposed to have booted, and what network
	surface is that supposed to produce" -- and the two checks that catch it drifting.

	WHY THIS EXISTS. Main.server.lua is a hand-ordered boot sequence with a real ordering argument in
	a comment above almost every line, and that is the right shape for it -- the ordering IS the
	documentation, and turning it into a data table would delete the part that matters. What it could
	not do is fail. A System dropped from that list, or one whose module was renamed, or a new System
	that nobody remembered to add, produced a server that booted perfectly and was simply missing a
	feature: its remotes never got created, so its clients sat in WaitForChild until the timeout and
	then asserted, one player at a time, in a playtest. NetworkBridge.DescribeSurface() made the live
	surface readable for the first time; this file is what there is to compare it against.

	TWO CHECKS, DELIBERATELY IN TWO PLACES, because they catch different mistakes:

	1. AT BOOT (AssertBootComplete, called at the end of Main.server.lua). Compares what actually
	   happened against what is declared here: every System in Entries reported Init, every declared
	   remote exists, no remote was claimed twice, nothing undeclared appeared. This is the only check
	   that can see a System that was dropped from the boot list, because that is not visible in any
	   file -- it is visible in the absence of a call.

	2. IN A SPEC (Tests/Boot/BootManifest.spec.lua). Compares this file against the modules actually
	   on disk: every ModuleScript under Server/Systems and Server/Managers is declared here, every
	   declared entry resolves to a real module exposing Init, and no remote name is claimed by two
	   entries. This is the only check that can see a System that exists but was never added to the
	   boot list at all, because such a System never runs and so cannot be missed at runtime.

	Neither check subsumes the other, and a manifest with only one of them rots.

	MarkBooted IS THE INSTRUMENTATION, and it is why Main.server.lua's numbered steps read
	`boot("PlayerDataSystem", PlayerDataSystem)` rather than `PlayerDataSystem.Init()`. Deriving
	"did this boot" from its side effects was the alternative and it does not work: half these Systems
	own no remote at all, so for them there is no observable trace of having booted other than saying
	so.

	RETIRED REMOTES are names that still sit in a Constants.*.RemoteNames table but that no System
	creates any more -- four Dev Menu entries and two Move Editor entries, all left behind when the
	old combat system was removed. They are listed rather than deleted because deleting a name from a
	Constants table and deleting the feature are different decisions with different blast radii; what
	this file does is stop them reading as "a remote that should exist", and make the spec fail if one
	is quietly resurrected on one side only.

	Does NOT own: boot ORDER (Main.server.lua's own comments, and nothing here should ever be read as
	a reason to reorder that file), what any System does, or client-side remotes -- a client resolves
	remotes it never creates, so a client-side surface would be a list of things other people own.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ArtConstants = require(ReplicatedStorage.Shared.ArtConstants)
local WeaponConstants = require(ReplicatedStorage.Shared.Combat.WeaponConstants)
local BloodlineConstants = require(ReplicatedStorage.Shared.Bloodline.BloodlineConstants)
local AttackConstants = require(ReplicatedStorage.Shared.Attack.AttackConstants)
local BlimpConstants = require(ReplicatedStorage.Shared.Blimp.BlimpConstants)
local BoatConstants = require(ReplicatedStorage.Shared.Boat.BoatConstants)
local BountyConstants = require(ReplicatedStorage.Shared.BountyConstants)
local Constants = require(ReplicatedStorage.Shared.Constants)
local DamageConstants = require(ReplicatedStorage.Shared.Damage.DamageConstants)
local DeathConstants = require(ReplicatedStorage.Shared.Death.DeathConstants)
local DomainConstants = require(ReplicatedStorage.Shared.Domain.DomainConstants)
local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local EmoteConstants = require(ReplicatedStorage.Shared.EmoteConstants)
local EngagementConstants = require(ReplicatedStorage.Shared.Engagement.EngagementConstants)
local EnvironmentConstants = require(ReplicatedStorage.Shared.Combat.EnvironmentConstants)
local GatheringConstants = require(ReplicatedStorage.Shared.Gathering.GatheringConstants)
local GrabConstants = require(ReplicatedStorage.Shared.Grab.GrabConstants)
local MovePresentationTypes = require(ReplicatedStorage.Shared.Combat.MovePresentationTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local RunConstants = require(ReplicatedStorage.Shared.Run.RunConstants)
local TierConstants = require(ReplicatedStorage.Shared.TierConstants)
local VehicleConstants = require(ReplicatedStorage.Shared.Vehicle.VehicleConstants)

local BootManifest = {}

export type BootEntry = {
	Name: string,
	-- Path from ServerScriptService.Server down to the module, so the spec can resolve an entry back
	-- to a real ModuleScript instead of holding a second hand-maintained copy of the folder tree.
	Path: { string },
	-- Every remote name this System creates inside its own Init. Empty for the many Systems that own
	-- no network surface -- an empty list is a real declaration here, not a gap.
	Remotes: { string },
}

-- Every value in a RemoteNames table, sorted so the manifest is stable to read and to diff.
local function namesOf(source: { [string]: string }): { string }
	local names: { string } = {}
	for _, name in source do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

-- namesOf minus the keys named in `excluded` -- for the two tables that still carry names nothing
-- creates. Keyed by the table's KEY, not its value, because the key is what a reader of the Constants
-- table is looking at when they wonder whether an entry is live.
local function namesExcept(source: { [string]: string }, excluded: { string }): { string }
	local names: { string } = {}
	for key, name in source do
		if not table.find(excluded, key) then
			table.insert(names, name)
		end
	end
	table.sort(names)
	return names
end

-- Removed with the old combat system, and never re-owned: the Dev Menu's two combat-target actions (a
-- third, SpawnTrainingBot, was re-owned by the rebuilt Server/Combat/TrainingBot on 2026-09-28). Their
-- names are still in the Constants table, so without this list the boot check below would report
-- phantom missing remotes on every healthy server. (The Move Editor's two retired names went with its
-- 2026-09-29 rebuild, which deleted them from its table outright.)
local DEV_MENU_RETIRED = { "ResetTargetCombatState", "SetTargetHealth" }

-- Ordered to MIRROR Main.server.lua's boot sequence, purely so the two files read against each other.
-- The order here is documentation and nothing enforces it -- see this file's header on why boot order
-- stays Main.server.lua's business.
local ENTRIES: { BootEntry } = {
	{ Name = "ModerationSystem", Path = { "Systems", "ModerationSystem" }, Remotes = {} },
	{
		Name = "ServerHopSystem",
		Path = { "Systems", "ServerHopSystem" },
		Remotes = namesOf(Constants.StartMenu.RemoteNames),
	},
	{ Name = "VersionWatchSystem", Path = { "Systems", "VersionWatchSystem" }, Remotes = {} },
	{ Name = "PlayerDataSystem", Path = { "Systems", "PlayerDataSystem" }, Remotes = {} },
	{
		Name = "SettingsSystem",
		Path = { "Systems", "SettingsSystem" },
		Remotes = namesOf(Constants.Settings.RemoteNames),
	},
	-- Blimp Fuel System's gathering half. Owns CarriedFuelUpdated (server -> the owning player, pushed
	-- on a successful gather, on profile load, and by BlimpSystem.depositFuel's own narrow callback in)
	-- -- see GatheringConstants.RemoteNames' own comment.
	{
		Name = "ResourceGatheringSystem",
		Path = { "Systems", "ResourceGatheringSystem" },
		Remotes = namesOf(GatheringConstants.RemoteNames),
	},
	{
		Name = "MeridianSystem",
		Path = { "Systems", "MeridianSystem" },
		Remotes = namesOf(Constants.Meridian.RemoteNames),
	},
	{ Name = "QiSystem", Path = { "Systems", "QiSystem" }, Remotes = namesOf(Constants.Qi.RemoteNames) },
	-- Owns no remote -- EffectSystem is a pure server-side modifier engine with no network surface of
	-- its own; RaceSystem/BloodlineSystem/KitAbilitySystem (later phases of the Race Traits +
	-- Bloodline Abilities plan) are its callers, not clients.
	{ Name = "EffectSystem", Path = { "Systems", "EffectSystem" }, Remotes = {} },
	{ Name = "TierSystem", Path = { "Systems", "TierSystem" }, Remotes = namesOf(TierConstants.RemoteNames) },
	-- The fight-to-grow spine (Main.server.lua step 7b). Neither owns a remote, and neither ever may: a
	-- progression grant a client could request is exactly what project-vision.md's first pillar
	-- forbids. Both are reached only through GameplayEvents.PlayerKilled.
	{ Name = "ProgressionSystem", Path = { "Systems", "ProgressionSystem" }, Remotes = {} },
	{ Name = "RewardSystem", Path = { "Systems", "RewardSystem" }, Remotes = {} },
	{ Name = "ArtTreeManager", Path = { "Managers", "ArtTreeManager" }, Remotes = {} },
	{ Name = "ArtSystem", Path = { "Systems", "ArtSystem" }, Remotes = namesOf(ArtConstants.RemoteNames) },
	-- Race Traits + Bloodline Abilities plan. Neither owns a remote of its own -- KitAbilitySystem (a
	-- later phase of that plan) is the shared trigger/remote path both this and BloodlineSystem
	-- dispatch through.
	{ Name = "RaceManager", Path = { "Managers", "RaceManager" }, Remotes = {} },
	{ Name = "RaceSystem", Path = { "Systems", "RaceSystem" }, Remotes = {} },
	{
		Name = "CharacterSheetSystem",
		Path = { "Systems", "CharacterSheetSystem" },
		Remotes = namesOf(Constants.CharacterSheet.RemoteNames),
	},
	-- Owns no remote -- QiDeviationSystem replicates through CharacterSheetSystem's existing
	-- SheetUpdated push (Refresh) rather than a remote of its own; see that module's own header.
	{ Name = "QiDeviationSystem", Path = { "Systems", "QiDeviationSystem" }, Remotes = {} },
	-- Race Traits + Bloodline Abilities plan -- same "no remote of its own, KitAbilitySystem is the
	-- shared dispatch path" reasoning RaceManager/RaceSystem's own entries above give. BloodlineSystem
	-- also replicates through CharacterSheetSystem's existing SheetUpdated push, same as
	-- QiDeviationSystem immediately above -- no new remote for bloodlineStageProgress either.
	--
	-- The ONE remote it does own is the bloodline spin, called by the onboarding creator. Everything
	-- else on this System is a server-side API other Systems call directly.
	{ Name = "BloodlineManager", Path = { "Managers", "BloodlineManager" }, Remotes = {} },
	-- Content, not a System: seeds world-bible.md's canon thirteen into the Manager above. Its own
	-- step rather than folded into that Init, which is a pure reset -- see its own header.
	{
		Name = "DefaultBloodlineRegistry",
		Path = { "Managers", "DefaultBloodlineRegistry" },
		Remotes = {},
	},
	{
		Name = "BloodlineSystem",
		Path = { "Systems", "BloodlineSystem" },
		Remotes = namesOf(BloodlineConstants.RemoteNames),
	},
	{
		Name = "KitAbilitySystem",
		Path = { "Systems", "KitAbilitySystem" },
		Remotes = namesOf(Constants.Kit.RemoteNames),
	},
	{ Name = "MoveRegistryManager", Path = { "Combat", "MoveRegistryManager" }, Remotes = {} },
	-- The per-move presentation catalogue clients read (MovePresentationTypes' header). Not a combat
	-- layer: it only reads the two registries, through their OnChanged seams.
	{
		Name = "MovePresentationSystem",
		Path = { "Combat", "MovePresentationSystem" },
		Remotes = namesOf(MovePresentationTypes.Network.RemoteNames),
	},
	{ Name = "HitboxEngine", Path = { "Combat", "HitboxEngine", "HitboxEngine" }, Remotes = {} },
	{
		Name = "DefenseSystem",
		Path = { "Combat", "Defense", "DefenseSystem" },
		Remotes = namesOf(DefenseConstants.Network.RemoteNames),
	},
	{
		Name = "DamageSystem",
		Path = { "Combat", "Damage", "DamageSystem" },
		Remotes = namesOf(DamageConstants.Network.RemoteNames),
	},
	-- Not a combat layer: the sole death confirmer and PlayerKilled publisher. Declared here because
	-- Main.server.lua boots it here -- after DamageSystem, whose OnApplied it attributes kills from,
	-- and before AttackRequestSystem, the first thing that lets a blow land. Owns the Death_Notice
	-- broadcast (the same confirmed fact, for the death overlay and the kill feed).
	{
		Name = "PlayerDeathSystem",
		Path = { "Systems", "PlayerDeathSystem" },
		Remotes = namesOf(DeathConstants.Network.RemoteNames),
	},
	{
		Name = "AttackRequestSystem",
		Path = { "Combat", "Attack", "AttackRequestSystem" },
		Remotes = namesOf(AttackConstants.Network.RemoteNames),
	},
	{
		Name = "GrabSystem",
		Path = { "Combat", "Grab", "GrabSystem" },
		Remotes = namesOf(GrabConstants.Network.RemoteNames),
	},
	-- Air combos (docs/design/air-combat-and-evade.md, Part B). The same sibling shape as GrabSystem: it
	-- subscribes to DamageSystem.OnApplied and is read by AttackRequestSystem.Throw as a fourth
	-- CanAttack-shaped gate. NO REMOTE of its own -- the launcher modifier rides Attack_Request, state rides
	-- Humanoid Attributes, and hit/clash feedback rides Combat_Feedback's optional AirCombo field.
	{ Name = "AirComboSystem", Path = { "Combat", "AirCombo", "AirComboSystem" }, Remotes = {} },
	-- The combat tag. A sibling of the attack layer like GrabSystem above, subscribing to the same
	-- DamageSystem.OnApplied extension point -- see its own header. Boots after GrabSystem for no
	-- ordering reason beyond reading in dependency order; its Step reclaims only its own rows, so an
	-- out-of-order boot costs one stale frame rather than a wrong outcome.
	{
		Name = "EngagementSystem",
		Path = { "Combat", "Engagement", "EngagementSystem" },
		Remotes = namesOf(EngagementConstants.Network.RemoteNames),
	},
	-- The anti-knockback detector, a third OnApplied sibling. Owns no remote: the launch itself rides
	-- DamageSystem's existing Combat_Feedback, and a flag goes through ModerationSystem.
	{ Name = "KnockbackAudit", Path = { "Combat", "Damage", "KnockbackAudit" }, Remotes = {} },
	-- The wall splat and the swing scuff, a sibling on OnApplied and OnSwingAccepted. Owns the one
	-- server-to-nearby-clients remote both ride on.
	{
		Name = "EnvironmentReactionSystem",
		Path = { "Combat", "Environment", "EnvironmentReactionSystem" },
		Remotes = namesOf(EnvironmentConstants.Network.RemoteNames),
	},
	-- The combat trace (Live Console, scope CombatTrace): a read-only sibling on the layers' signals. No remote:
	-- its lines ride the Logger capture LiveConsoleSystem already streams.
	{ Name = "CombatTrace", Path = { "Combat", "CombatTrace" }, Remotes = {} },
	-- Realms. Owns Domain_State (server -> clients: open/phase/clash/pulse/snapshot, and a player's own
	-- impulse) and Domain_Request (a client asking for every live realm, rate-limited).
	{
		Name = "DomainSystem",
		Path = { "Combat", "Domain", "DomainSystem" },
		Remotes = namesOf(DomainConstants.Network.RemoteNames),
	},
	-- Owns no remote -- purely cosmetic, replicates for free as a Tool parented under the character
	-- rather than through NetworkBridge. See its own header for why it is a sibling of the attack
	-- layer, not a combat-legality gate.
	{ Name = "WeaponVisualSystem", Path = { "Combat", "Weapon", "WeaponVisualSystem" }, Remotes = {} },
	-- Owns the pickup prompts and the draw/sheath state. Boots after WeaponVisualSystem because a draw
	-- reaches the hand THROUGH that System (SwingSequencer.SetWeapon -> OnWeaponChanged -> EquipVisual),
	-- so its subscription has to already exist or the very first draw of a session changes the record
	-- and draws nothing.
	{
		Name = "WeaponInventorySystem",
		Path = { "Combat", "Weapon", "WeaponInventorySystem" },
		Remotes = namesOf(WeaponConstants.Network.RemoteNames),
	},
	{
		Name = "ParkourSystem",
		Path = { "Systems", "ParkourSystem" },
		Remotes = namesOf(ParkourConstants.Network.RemoteNames),
	},
	{ Name = "RunSystem", Path = { "Systems", "RunSystem" }, Remotes = namesOf(RunConstants.Network.RemoteNames) },
	{
		Name = "BlimpSystem",
		Path = { "Systems", "BlimpSystem" },
		Remotes = namesOf(BlimpConstants.Network.RemoteNames),
	},
	{
		Name = "BoatSystem",
		Path = { "Systems", "BoatSystem" },
		Remotes = namesOf(BoatConstants.Network.RemoteNames),
	},
	{
		Name = "VehicleManager",
		Path = { "Systems", "VehicleManager" },
		Remotes = namesOf(VehicleConstants.RemoteNames),
	},
	{ Name = "EmoteUnlockService", Path = { "Systems", "EmoteUnlockService" }, Remotes = {} },
	{ Name = "EmoteSystem", Path = { "Systems", "EmoteSystem" }, Remotes = namesOf(EmoteConstants.RemoteNames) },
	{ Name = "RespawnSystem", Path = { "Systems", "RespawnSystem" }, Remotes = {} },
	{ Name = "RivalrySystem", Path = { "Systems", "RivalrySystem" }, Remotes = namesOf(Constants.Rivalry.RemoteNames) },
	{ Name = "BountySystem", Path = { "Systems", "BountySystem" }, Remotes = namesOf(BountyConstants.RemoteNames) },
	{
		Name = "BugReportSystem",
		Path = { "Systems", "BugReportSystem" },
		Remotes = namesOf(Constants.BugReport.RemoteNames),
	},
	{ Name = "AdminActionSystem", Path = { "Systems", "AdminActionSystem" }, Remotes = {} },
	{ Name = "DebugDummySystem", Path = { "Systems", "DebugDummySystem" }, Remotes = {} },
	-- The AI sparring partner. Owns no remotes of its own -- it is spawned through DevMenuSystem's
	-- SpawnTrainingBot/DespawnTrainingBots, which is where those names are declared.
	{ Name = "TrainingBotSystem", Path = { "Combat", "TrainingBot", "TrainingBotSystem" }, Remotes = {} },
	{
		Name = "DevMenuSystem",
		Path = { "Systems", "DevMenuSystem" },
		Remotes = namesExcept(Constants.Debug.DevMenu.RemoteNames, DEV_MENU_RETIRED),
	},
	{
		Name = "MoveEditorSystem",
		Path = { "Systems", "MoveEditorSystem" },
		Remotes = namesOf(Constants.MoveEditor.RemoteNames),
	},
	{
		Name = "KitEditorSystem",
		Path = { "Systems", "KitEditorSystem" },
		Remotes = namesOf(Constants.KitEditor.RemoteNames),
	},
	{
		Name = "LiveConsoleSystem",
		Path = { "Systems", "LiveConsoleSystem" },
		Remotes = namesOf(Constants.LiveConsole.RemoteNames),
	},
	{
		Name = "CharacterCreationSystem",
		Path = { "Systems", "CharacterCreationSystem" },
		Remotes = namesOf(Constants.CharacterCreation.RemoteNames),
	},

	-- PLANNED SYSTEMS -- Main.server.lua boots these through one loop outside its numbered sequence,
	-- because every one of their Init() bodies is currently empty and none participates in the
	-- dependency ordering the numbered steps document. They are declared here on exactly the same
	-- terms as everything above: the day one of them stops being empty and grows a remote, the boot
	-- check starts holding it to that.
	{ Name = "FactionManager", Path = { "Managers", "FactionManager" }, Remotes = {} },
	{ Name = "AchievementSystem", Path = { "Systems", "AchievementSystem" }, Remotes = {} },
	{ Name = "AbsorbSystem", Path = { "Systems", "AbsorbSystem" }, Remotes = {} },
	{ Name = "AwakeningSystem", Path = { "Systems", "AwakeningSystem" }, Remotes = {} },
	{ Name = "TerritorySystem", Path = { "Systems", "TerritorySystem" }, Remotes = {} },
	{ Name = "WorldSystem", Path = { "Systems", "WorldSystem" }, Remotes = {} },
}

BootManifest.Entries = ENTRIES

-- The entries that boot through Main.server.lua's PLANNED loop: roadmap placeholders with empty Inits,
-- none of which anything requires. Exposed so Tests/Boot/BootManifest.spec.lua can hold both halves of
-- that claim to account -- a planned System that grows a body or an inbound require has stopped being
-- planned, and should move to a numbered step the way ProgressionSystem and RewardSystem did.
BootManifest.Planned = table.freeze({
	"FactionManager",
	"AchievementSystem",
	"AbsorbSystem",
	"AwakeningSystem",
	"TerritorySystem",
	"WorldSystem",
})

-- The retired names themselves, for the spec to assert are NOT created by anyone. Exposed rather than
-- kept file-local so "is this name dead" has one answer instead of two.
BootManifest.RetiredRemotes = {
	Constants.Debug.DevMenu.RemoteNames.ResetTargetCombatState,
	Constants.Debug.DevMenu.RemoteNames.SetTargetHealth,
}

-- Which Systems have reported Init this VM. A set, not a count: the useful question at the end of boot
-- is "which one is missing", and a count can only answer "one of them is".
local booted: { [string]: boolean } = {}

-- Called by Main.server.lua's own boot helper immediately after a System's Init returns -- see this
-- file's header on why this is recorded rather than inferred.
function BootManifest.MarkBooted(name: string): ()
	booted[name] = true
end

-- Every declared remote name mapped to the System that claims it. Asserts as it builds: two entries
-- declaring one name is the ownership bug NetworkBridge.claimName can only warn about at runtime,
-- caught here at the one moment it is a static fact rather than a race.
function BootManifest.RemoteOwners(): { [string]: string }
	local owners: { [string]: string } = {}
	for _, entry in ENTRIES do
		for _, remoteName in entry.Remotes do
			local existing = owners[remoteName]
			if existing ~= nil then
				error(
					`BootManifest declares "{remoteName}" for both {existing} and {entry.Name} -- one remote, one owner`
				)
			end
			owners[remoteName] = entry.Name
		end
	end
	return owners
end

export type BootDrift = {
	-- Declared here but never reported Init: dropped from Main.server.lua's boot list, or renamed.
	MissingSystems: { string },
	-- Declared here but absent from the live network surface: the owning System booted but did not
	-- create it, or its Constants entry drifted from the name it actually creates.
	MissingRemotes: { string },
	-- Present on the live surface but declared by nobody: a new remote whose manifest entry was never
	-- added, or one created by a module that is not a declared System at all.
	UndeclaredRemotes: { string },
	-- Claimed by Create* more than once in this VM -- two owning Systems, or a re-entrant Init.
	DuplicateClaims: { string },
}

-- The whole comparison, as data. Split out from AssertBootComplete so a spec, the Dev Menu, or a
-- future diagnostics panel can read the same answer without triggering the failure behaviour.
function BootManifest.DescribeDrift(): BootDrift
	local drift: BootDrift = {
		MissingSystems = {},
		MissingRemotes = {},
		UndeclaredRemotes = {},
		DuplicateClaims = {},
	}

	for _, entry in ENTRIES do
		if not booted[entry.Name] then
			table.insert(drift.MissingSystems, entry.Name)
		end
	end

	local owners = BootManifest.RemoteOwners()
	local live: { [string]: number } = {}
	for _, surfaceEntry in NetworkBridge.DescribeSurface() do
		live[surfaceEntry.Name] = surfaceEntry.CreateCount
		if surfaceEntry.CreateCount > 1 then
			table.insert(drift.DuplicateClaims, surfaceEntry.Name)
		end
		-- CreateCount of 0 means this VM only RESOLVED the remote (a server-side consumer of another
		-- System's remote), which is not a claim and not something the manifest declares.
		if surfaceEntry.CreateCount > 0 and owners[surfaceEntry.Name] == nil then
			table.insert(drift.UndeclaredRemotes, surfaceEntry.Name)
		end
	end

	for remoteName in owners do
		if (live[remoteName] or 0) == 0 then
			table.insert(drift.MissingRemotes, remoteName)
		end
	end

	table.sort(drift.MissingSystems)
	table.sort(drift.MissingRemotes)
	table.sort(drift.UndeclaredRemotes)
	table.sort(drift.DuplicateClaims)
	return drift
end

-- True when nothing drifted.
function BootManifest.IsClean(drift: BootDrift): boolean
	return #drift.MissingSystems == 0
		and #drift.MissingRemotes == 0
		and #drift.UndeclaredRemotes == 0
		and #drift.DuplicateClaims == 0
end

-- The end-of-boot check. Called once from the last line of Main.server.lua.
--
-- ASSERTS IN STUDIO, LOGS AN ERROR ON A LIVE SERVER, and the asymmetry is the whole design. In Studio
-- the person who just broke the boot list is sitting in front of it, and a hard failure at the moment
-- of the mistake is worth more than every downstream symptom put together. On a live server the same
-- failure would take a running game down over a diagnostic -- a server missing one System is degraded,
-- but a server that refuses to boot is not serving anyone, and drift severe enough to matter will
-- already be breaking that feature loudly on its own. So production gets the same information, at
-- error level, in the capture buffer, where an admin's Live Console (F5) can read it live.
function BootManifest.AssertBootComplete(logger: Logger.LoggerScope): ()
	local drift = BootManifest.DescribeDrift()
	if BootManifest.IsClean(drift) then
		logger:info("Boot surface verified", {
			systems = #ENTRIES,
			remotes = #NetworkBridge.DescribeSurface(),
		})
		return
	end

	local detail = {
		missingSystems = table.concat(drift.MissingSystems, ", "),
		missingRemotes = table.concat(drift.MissingRemotes, ", "),
		undeclaredRemotes = table.concat(drift.UndeclaredRemotes, ", "),
		duplicateClaims = table.concat(drift.DuplicateClaims, ", "),
	}
	logger:error("Boot surface DRIFTED from Server/Config/BootManifest.lua", detail)
	if RunService:IsStudio() then
		error(
			"Boot surface drift -- missing systems: ["
				.. detail.missingSystems
				.. "] missing remotes: ["
				.. detail.missingRemotes
				.. "] undeclared remotes: ["
				.. detail.undeclaredRemotes
				.. "] duplicate claims: ["
				.. detail.duplicateClaims
				.. "]"
		)
	end
end

return BootManifest
