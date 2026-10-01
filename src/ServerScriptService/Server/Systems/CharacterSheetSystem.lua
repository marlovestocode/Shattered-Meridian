--!strict
--[[
	CharacterSheetSystem.lua

	Owns: replicating the identity/standing half of a player's own profile to that player's own
	client -- the character name they chose at chargen, their race, faction, attribute block,
	bloodlines, corruption, Qi-deviation risk, faction standing, and whether they have ascended.
	Read-only in both directions: nothing here mutates a profile, and there is no client-facing
	request that could.

	WHY THIS EXISTS AT ALL, given PlayerDataSystem already owns the profile: PlayerDataSystem is
	server-side storage with no remotes of its own (see its header -- it is the DataStore-backed
	owner, not a replication layer), and a client that wants to render a character sheet has no way
	to reach it. Every other progression System that a UI needs already solved this the same way, by
	owning its own narrow remote (QiSystem's Progression_QiUpdated, TierSystem's
	Progression_TierUpdated, ArtSystem's Art_StateUpdated). This is that same shape for the fields
	none of them cover.

	OWNS ONLY WHAT NOTHING ELSE REPLICATES, and that boundary is the whole design. Tier, tier name,
	Meridian XP, Qi and art mastery are all deliberately absent from Types.CharacterSheetPayload even
	though they are on the same profile, because each already has a live channel that updates on its
	own cadence -- tier and XP move on every kill, this sheet moves only when a profile-level field
	changes. Sending them twice would give the client two sources for one fact, and the staler one
	would win whenever it happened to arrive last. The character menu reads those from ClientState
	and these from here.

	PUSH AND PULL, both needed for the same reason BountyMenu needs both: the push (on profile load,
	and on any later Refresh) keeps an already-open panel honest, and the pull covers a client whose
	profile-load push fired long before it ever opened the menu -- nothing caches an unheard
	RemoteEvent.

	Does not own: any of these values (PlayerDataSystem holds them; CharacterCreationSystem writes
	the chargen ones, FactionManager/BloodlineManager will write the rest once they stop being
	stubs), nor any decision about what a client may see -- a player only ever receives their OWN
	sheet, because both paths key off the calling/owning Player and never take a target id.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local Constants = require(ReplicatedStorage.Shared.Constants)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local RemoteHandler = require(ReplicatedStorage.Shared.RemoteHandler)
local PlayerDataSystem = require(script.Parent.PlayerDataSystem)

local logger = Logger.scope("CharacterSheetSystem")

local CharacterSheetSystem = {}

local sheetRemote: RemoteEvent? = nil
-- The sheet each player was last pushed, so a Refresh that would send the same thing sends nothing.
local lastSent: { [Player]: Types.CharacterSheetPayload } = {}
local requestRateLimiter = RateLimiter.New(Constants.CharacterSheet.RequestMaxCallsPerSecond)

-- The pure profile -> payload projection, exported so TestEZ can exercise it against a plain
-- profile literal with no live Player and no DataStore -- the same "pure logic gets its own export"
-- precedent PlayerDataSystem.EncodeProfile/BugReportSystem.ValidateCategory already established.
--
-- Copies the two container fields rather than passing the profile's own tables through: GetProfile
-- already hands back a copy today, but a payload that aliases anything a caller might later mutate
-- is a bug waiting for the day that changes.
function CharacterSheetSystem.BuildSheet(profile: Types.PlayerProfile): Types.CharacterSheetPayload
	return {
		DisplayName = profile.displayName,
		RaceId = profile.raceId,
		Faction = profile.faction,
		Attributes = if profile.attributes then table.clone(profile.attributes) else nil,
		BloodlineIds = table.clone(profile.bloodlineIds),
		BloodlineStageProgress = table.clone(profile.bloodlineStageProgress),
		BloodlineRerolls = profile.bloodlineRerolls,
		Corruption = profile.corruption,
		QiDeviationRisk = profile.qiDeviationRisk,
		FactionStanding = profile.factionStanding,
		HasAscended = profile.hasAscended,
	}
end

-- This player's current sheet, or nil if their profile isn't loaded. nil rather than a blank sheet
-- on purpose: a panel can tell "not loaded yet" apart from "loaded, and genuinely has no race" only
-- if this refuses to fabricate the second from the first.
function CharacterSheetSystem.GetSheet(player: Player): Types.CharacterSheetPayload?
	local profile = PlayerDataSystem.GetProfile(player)
	if not profile then
		return nil
	end
	return CharacterSheetSystem.BuildSheet(profile)
end

-- Whether two values are the same, tables compared by content. The sheet is a shallow record of scalars
-- and small arrays/dicts of scalars, so this is a few comparisons -- far cheaper than what a client does
-- with a sheet it is handed.
local function valuesEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if typeof(a) ~= "table" or typeof(b) ~= "table" then
		return false
	end
	for key, value in a do
		if not valuesEqual(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

-- Whether two sheets say the same thing. Exported for TestEZ.
function CharacterSheetSystem.SheetsEqual(a: Types.CharacterSheetPayload, b: Types.CharacterSheetPayload): boolean
	return valuesEqual(a, b)
end

-- Pushes `player`'s sheet to their own client -- unless it is the sheet they already have.
--
-- ONLY WHAT CHANGED IS PUSHED (2026-09-30). Qi Deviation refreshes the sheet after every Qi spend, and a
-- realm's upkeep is a steady stream of spends; nearly all of them leave every field identical. The client
-- cannot tell an identical sheet from a new one (it arrives as a fresh table), so each one re-ran every
-- Computed the character menu hangs off it -- ~55ms a push. A client that has never heard a push still
-- gets its sheet by the pull (GetSheet, on boot and whenever the menu opens), so skipping a repeat
-- loses nothing. Public so any System that writes one of these fields
-- (CharacterCreationSystem finalizing a chargen, a future FactionManager assigning a faction, a
-- future corruption tick) can announce the change without this module having to watch for it --
-- there is no change-notification hook on PlayerDataSystem.Transform to subscribe to, and polling a
-- profile every few seconds to spot a field that changes a handful of times per session would be
-- the wrong trade.
function CharacterSheetSystem.Refresh(player: Player): ()
	if not sheetRemote then
		return
	end
	local sheet = CharacterSheetSystem.GetSheet(player)
	if not sheet then
		return
	end
	local previous = lastSent[player]
	if previous ~= nil and valuesEqual(previous, sheet) then
		return
	end
	lastSent[player] = sheet
	sheetRemote:FireClient(player, sheet)
end

local function handleGetSheet(player: Player): Types.CharacterSheetPayload?
	if requestRateLimiter:IsLimited(player) then
		return nil
	end
	return CharacterSheetSystem.GetSheet(player)
end

function CharacterSheetSystem.Init(): ()
	sheetRemote = NetworkBridge.CreateRemoteEvent(Constants.CharacterSheet.RemoteNames.SheetUpdated)

	local getSheetRemote = NetworkBridge.CreateRemoteFunction(Constants.CharacterSheet.RemoteNames.GetSheet)
	getSheetRemote.OnServerInvoke =
		RemoteHandler.WrapInvoke(logger, "GetSheet", nil :: Types.CharacterSheetPayload?, handleGetSheet)

	PlayerDataSystem.OnProfileLoaded.Event:Connect(function(player: Player)
		CharacterSheetSystem.Refresh(player)
	end)
	PlayerLifecycle.BindAllPlayers({
		Scope = "CharacterSheetSystem",
		OnPlayerRemoving = function(player: Player)
			requestRateLimiter:Clear(player)
			lastSent[player] = nil
		end,
	})

	-- Defensive pass for a profile that loaded before this Init() ran -- same reasoning
	-- QiSystem.Init()/TierSystem.Init()/ArtSystem.Init() all document for their own GetPlayers() loops.
	for _, player in ipairs(Players:GetPlayers()) do
		if PlayerDataSystem.IsLoaded(player) then
			CharacterSheetSystem.Refresh(player)
		end
	end

	logger:info("CharacterSheetSystem.Init() complete")
end

-- Not cast to Types.SystemModule -- same reasoning PlayerDataSystem.lua/CharacterCreationSystem.lua
-- give for their own returns: TestEZ needs BuildSheet visible, not just Init.
return CharacterSheetSystem
