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
local AttackConstants = require(ReplicatedStorage.Shared.Attack.AttackConstants)
local BountyConstants = require(ReplicatedStorage.Shared.BountyConstants)
local Constants = require(ReplicatedStorage.Shared.Constants)
local DamageConstants = require(ReplicatedStorage.Shared.Damage.DamageConstants)
local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local EmoteConstants = require(ReplicatedStorage.Shared.EmoteConstants)
local GrabConstants = require(ReplicatedStorage.Shared.Grab.GrabConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)
local RunConstants = require(ReplicatedStorage.Shared.Run.RunConstants)
local TierConstants = require(ReplicatedStorage.Shared.TierConstants)

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

-- Removed with the old combat system, and never re-owned: the Dev Menu's three combat-target actions
-- plus its own Announcement RemoteEvent's odd sibling, and the Move Editor's two "test on a dummy"
-- calls (see MoveEditorClient.lua's own header on that removal). Their names are still in the
-- Constants tables, so without this list the boot check below would report four-plus phantom missing
-- remotes on every healthy server.
local DEV_MENU_RETIRED = { "ResetTargetCombatState", "SetTargetHealth", "SpawnTrainingBot" }
local MOVE_EDITOR_RETIRED = { "TestFireMove", "SpawnPreviewDummy" }

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
	{
		Name = "MeridianSystem",
		Path = { "Systems", "MeridianSystem" },
		Remotes = namesOf(Constants.Meridian.RemoteNames),
	},
	{ Name = "QiSystem", Path = { "Systems", "QiSystem" }, Remotes = namesOf(Constants.Qi.RemoteNames) },
	{ Name = "TierSystem", Path = { "Systems", "TierSystem" }, Remotes = namesOf(TierConstants.RemoteNames) },
	{ Name = "ArtTreeManager", Path = { "Managers", "ArtTreeManager" }, Remotes = {} },
	{ Name = "ArtSystem", Path = { "Systems", "ArtSystem" }, Remotes = namesOf(ArtConstants.RemoteNames) },
	{
		Name = "CharacterSheetSystem",
		Path = { "Systems", "CharacterSheetSystem" },
		Remotes = namesOf(Constants.CharacterSheet.RemoteNames),
	},
	{ Name = "MoveRegistryManager", Path = { "Combat", "MoveRegistryManager" }, Remotes = {} },
	{ Name = "PlayerDeathSystem", Path = { "Systems", "PlayerDeathSystem" }, Remotes = {} },
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
	{
		Name = "ParkourSystem",
		Path = { "Systems", "ParkourSystem" },
		Remotes = namesOf(ParkourConstants.Network.RemoteNames),
	},
	{ Name = "RunSystem", Path = { "Systems", "RunSystem" }, Remotes = namesOf(RunConstants.Network.RemoteNames) },
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
	{
		Name = "DevMenuSystem",
		Path = { "Systems", "DevMenuSystem" },
		Remotes = namesExcept(Constants.Debug.DevMenu.RemoteNames, DEV_MENU_RETIRED),
	},
	{
		Name = "MoveEditorSystem",
		Path = { "Systems", "MoveEditorSystem" },
		Remotes = namesExcept(Constants.MoveEditor.RemoteNames, MOVE_EDITOR_RETIRED),
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
	{ Name = "BloodlineManager", Path = { "Managers", "BloodlineManager" }, Remotes = {} },
	{ Name = "BloodlineSystem", Path = { "Systems", "BloodlineSystem" }, Remotes = {} },
	{ Name = "ProgressionSystem", Path = { "Systems", "ProgressionSystem" }, Remotes = {} },
	{ Name = "AchievementSystem", Path = { "Systems", "AchievementSystem" }, Remotes = {} },
	{ Name = "QiDeviationSystem", Path = { "Systems", "QiDeviationSystem" }, Remotes = {} },
	{ Name = "AbsorbSystem", Path = { "Systems", "AbsorbSystem" }, Remotes = {} },
	{ Name = "RewardSystem", Path = { "Systems", "RewardSystem" }, Remotes = {} },
	{ Name = "AwakeningSystem", Path = { "Systems", "AwakeningSystem" }, Remotes = {} },
	{ Name = "TerritorySystem", Path = { "Systems", "TerritorySystem" }, Remotes = {} },
	{ Name = "WorldSystem", Path = { "Systems", "WorldSystem" }, Remotes = {} },
}

BootManifest.Entries = ENTRIES

-- The retired names themselves, for the spec to assert are NOT created by anyone. Exposed rather than
-- kept file-local so "is this name dead" has one answer instead of two.
BootManifest.RetiredRemotes = {
	Constants.Debug.DevMenu.RemoteNames.ResetTargetCombatState,
	Constants.Debug.DevMenu.RemoteNames.SetTargetHealth,
	Constants.Debug.DevMenu.RemoteNames.SpawnTrainingBot,
	Constants.MoveEditor.RemoteNames.TestFireMove,
	Constants.MoveEditor.RemoteNames.SpawnPreviewDummy,
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
