--!strict
--[[
	CharacterCreationSystem.lua

	Owns: first-time-player onboarding end to end -- detecting a first-time player (purely
	`profile.raceId == nil`, no new boolean flag on PlayerProfile), this SESSION's first
	`Player:LoadCharacter()` call for EVERY player (Players.CharacterAutoLoads = false, set in
	default.project.json -- Roblox no longer spawns anyone automatically, so something has to, and
	this is that something for both onboarding and returning players), freezing a first-time player in
	the isolated "Waking Threshold" pocket space for the intro cinematic + character creator,
	attribute/name validation (pure functions, exported for TestEZ -- same "pure logic gets its own
	export" precedent as PlayerDataSystem.CreateDefaultProfile/BugReportSystem.ValidateCategory), the
	CharacterCreation_Finalize handler, and the Threshold-to-real-spawn teleport.

	Does not own: authorization (this feature has no whitelist -- every player goes through it exactly
	once, gated only by their own profile's raceId, not an admin check like DevMenuSystem's actions),
	the cinematic/creator UI itself (Client/Onboarding/OnboardingClient.lua + UI/Screens/Onboarding/*
	own presentation and the held-input skip/confirm interactions), or Workspace geometry -- the
	Waking Threshold and the real arrival spawn are Studio/place-file content this module references
	by name (Constants.CharacterCreation.ThresholdSpawnPath/ArrivalSpawnPath) via WaitForChild, never
	fabricated here (there is no Workspace tree in default.project.json for Rojo to author).

	Boots in Main.server.lua after PlayerDataSystem (WaitForProfile/Transform) and AdminActionSystem
	(SetFrozen) are already initialized -- see that file's own boot-order comment for this System.

	Failure-handling contract (non-negotiable, per this feature's own design review):
	  - Transform must succeed before any teleport is attempted. A Transform failure returns
	    Success = false immediately -- no teleport, no unfreeze, so a rare Transform failure can never
	    silently strand a player half-onboarded (raceId written but never actually moved/unfrozen).
	  - Once Transform succeeds, the real-spawn Workspace lookup retries via WaitForChild, then falls
	    back to any SpawnLocation already in the game rather than ever returning Success = true without
	    completing SOME teleport out of the Threshold.
	  - Success = true is never returned while the player is still physically stuck in the Threshold.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")

local Types = require(ReplicatedStorage.Shared.Types)
local Constants = require(ReplicatedStorage.Shared.Constants)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Logger = require(ReplicatedStorage.Shared.Logger)

local ServerScriptService = game:GetService("ServerScriptService")
local Systems = ServerScriptService.Server.Systems
local PlayerDataSystem = require(Systems.PlayerDataSystem)
local AdminActionSystem = require(Systems.AdminActionSystem)

local CharacterCreationSystem = {}

local logger = Logger.scope("CharacterCreationSystem")

local Config = Constants.CharacterCreation

--
-- Pure logic -- attribute/name validation. Every function in this section is exported specifically
-- so TestEZ can exercise it with no live Player, no DataStore, and no Workspace -- same "pure logic
-- gets its own export" precedent PlayerDataSystem.CreateDefaultProfile/BugReportSystem.
-- ValidateCategory/ValidateDescription already established.
--

local RACE_ID_SET: { [string]: Types.RaceId } = {}
for _, raceId in ipairs(Config.RaceIds) do
	RACE_ID_SET[raceId] = raceId
end

function CharacterCreationSystem.ValidateRaceId(raw: unknown): Types.RaceId?
	if typeof(raw) ~= "string" then
		return nil
	end
	return RACE_ID_SET[raw]
end

-- Fixed field order, matching Types.AttributeBlock exactly -- every validation/summation loop below
-- walks this list rather than `pairs()`-ing an untrusted table, so a client can never sneak in an
-- extra, unrecognized field and have it silently ignored-but-uncounted (or worse, counted). Shared
-- with the client's Onboarding screens (Constants.CharacterCreation.AttributeFields) so both sides
-- agree on the six field names from one source.
local ATTRIBUTE_FIELDS: { string } = Config.AttributeFields

-- Validates a client-submitted attribute allocation against a specific race's own floor: every one
-- of the six fixed fields must be present, a whole number, and within
-- [Constants.CharacterCreation.AttributeFloors[raceId][field], MaxPerAttribute], AND the six must
-- sum to exactly TotalBudget (78) -- the same "no partial default for a stat block" reasoning
-- PlayerDataSystem.DecodeProfile's own attributes-decode applies to a STORED record applies here to a
-- SUBMITTED one: a malformed/out-of-budget allocation is rejected wholesale, never clamped or
-- partially accepted. Returns the validated block (a real Types.AttributeBlock, safe to persist) or
-- nil plus a machine-readable reason.
--
-- raceId is Types.RaceId, not unknown -- unlike `raw`, this parameter is never untrusted client
-- input on its own; every real caller (handleFinalize below) has already run it through
-- ValidateRaceId first. AttributeFloors is keyed by every member of Types.RaceId (built from
-- Constants.CharacterCreation.RaceIds), so indexing it here can't miss.
function CharacterCreationSystem.ValidateAttributeBlock(
	raw: unknown,
	raceId: Types.RaceId
): (Types.AttributeBlock?, string?)
	if typeof(raw) ~= "table" then
		return nil, "InvalidType"
	end
	local rawTable = raw :: { [string]: unknown }
	local budget = Config.AttributeBudget
	local floors = Config.AttributeFloors[raceId]

	local block: { [string]: number } = {}
	local sum = 0
	for _, field in ipairs(ATTRIBUTE_FIELDS) do
		local value = rawTable[field]
		if typeof(value) ~= "number" then
			return nil, "MissingField"
		end
		if value ~= math.floor(value) then
			return nil, "NotInteger"
		end
		if value < floors[field] or value > budget.MaxPerAttribute then
			return nil, "OutOfRange"
		end
		block[field] = value
		sum += value
	end

	if sum ~= budget.TotalBudget then
		return nil, "BudgetMismatch"
	end

	return block :: Types.AttributeBlock, nil
end

-- Codepoint-level charset gate for CharacterCreationSystem.ValidateDisplayName below. Luau has no
-- built-in Unicode Letter/Digit category table to check against (unlike, say, ICU), so this is a
-- deliberately SCOPED heuristic, not a full classifier: ASCII letters/digits/space/apostrophe/hyphen
-- are allowed explicitly, and any other codepoint is allowed UNLESS it falls in a named range known
-- to cause a concrete problem for a displayed name -- C0/C1 control characters, zero-width/
-- direction-override characters (used to spoof or hide name content), non-standard whitespace
-- variants (this feature's own "single spaces only" rule would otherwise be bypassable via e.g.
-- U+00A0 NBSP or U+2003 EM SPACE), the Private Use Area (codepoints with no standard glyph at all),
-- and a few Unicode "specials." This intentionally permits a broad range of multi-script letters
-- (Latin-with-diacritics, Cyrillic, CJK, etc.) as "unicode letters" per this feature's spec, at the
-- cost of also permitting some non-letter symbols outside these denied ranges -- a real gap, flagged
-- here rather than silently accepted, and the studio Denylist (Config.DisplayName.Denylist) plus the
-- TextService moderation filter below are what catch abusive content this charset gate lets through.
local function isAllowedNameCodepoint(codepoint: number): boolean
	if codepoint == 0x20 or codepoint == 0x27 or codepoint == 0x2D then
		return true
	end
	if codepoint >= 0x30 and codepoint <= 0x39 then
		return true
	end
	if (codepoint >= 0x41 and codepoint <= 0x5A) or (codepoint >= 0x61 and codepoint <= 0x7A) then
		return true
	end

	-- Everything up to and including 0xA0 (NBSP) beyond the ASCII ranges above is either an ASCII
	-- symbol/punctuation character (denied -- only apostrophe/hyphen/space are allowed punctuation)
	-- or a C1 control/NBSP (denied outright).
	if codepoint <= 0xA0 then
		return false
	end

	-- General Punctuation block (zero-width spaces/joiners, direction marks, quotation marks, dashes,
	-- non-ASCII space variants) and its immediate neighbors up through Unicode "specials" -- denied
	-- even though it sits outside the ASCII punctuation check above, since it's exactly where
	-- name-spoofing characters (invisible/direction-override) and non-standard whitespace live.
	if (codepoint >= 0x2000 and codepoint <= 0x206F) or codepoint == 0xFEFF then
		return false
	end

	-- Private Use Area -- no standard glyph exists for any codepoint in this range.
	if codepoint >= 0xE000 and codepoint <= 0xF8FF then
		return false
	end

	-- Interlinear annotation characters and the "specials" block.
	if codepoint >= 0xFFF9 and codepoint <= 0xFFFF then
		return false
	end

	return true
end

-- Validates a client-submitted display name: length (counted in codepoints via utf8.len, not
-- bytes -- a 3-20 "character" rule should mean visible characters, not UTF-8 byte count), charset
-- (isAllowedNameCodepoint above), no leading/trailing space, no consecutive spaces, and the studio
-- Denylist (Config.DisplayName.Denylist, empty today -- real content to fill in later). Does NOT run
-- TextService:FilterStringAsync -- that's a live Roblox API call, so it stays in handleFinalize
-- (Studio/live-server only, same "Player-keyed wiring is verification-only" split
-- PlayerDataSystem.lua's own header documents for its Transform/WaitForProfile pair vs. its pure
-- CreateDefaultProfile/DecodeProfile section). Returns the validated name (untrimmed -- leading/
-- trailing space is a REJECTION here, never silently trimmed) or nil plus a machine-readable reason.
function CharacterCreationSystem.ValidateDisplayName(raw: unknown): (string?, string?)
	if typeof(raw) ~= "string" then
		return nil, "InvalidType"
	end
	local name = raw :: string

	local length = utf8.len(name)
	if not length then
		return nil, "InvalidEncoding"
	end
	if length < Config.DisplayName.MinLength then
		return nil, "TooShort"
	end
	if length > Config.DisplayName.MaxLength then
		return nil, "TooLong"
	end

	if name:sub(1, 1) == " " or name:sub(-1) == " " then
		return nil, "LeadingOrTrailingSpace"
	end
	if string.find(name, "  ", 1, true) then
		return nil, "ConsecutiveSpaces"
	end

	for _, codepoint in utf8.codes(name) do
		if not isAllowedNameCodepoint(codepoint) then
			return nil, "InvalidCharacter"
		end
	end

	local lowered = name:lower()
	for _, deniedTerm in ipairs(Config.DisplayName.Denylist) do
		if string.find(lowered, deniedTerm, 1, true) then
			return nil, "Denylisted"
		end
	end

	return name, nil
end

--
-- Per-player wiring -- Player-keyed, so (per AdminActionSystem.spec.lua/ModerationSystem.spec.lua's
-- own already-accepted precedent) this section is Studio/live-server verification only; the pure
-- logic it's built on is fully covered above.
--

-- True once this player's session-first LoadCharacter has already happened -- guards against a
-- modified client calling CharacterCreation_GetOnboardingState more than once, which would otherwise
-- call Player:LoadCharacter() again and destroy/replace an already-spawned (possibly mid-chargen,
-- frozen) character. Never trust a RemoteFunction to be called exactly once just because the normal
-- client only calls it once.
local spawnedThisSession: { [Player]: boolean } = {}

-- Walks `path` (a list of instance names) down from Workspace via WaitForChild, honoring
-- Constants.Network.WaitForChildTimeoutSeconds at each step -- returns nil (logged loudly, never
-- thrown) the instant any segment is missing, rather than assuming Studio content exists. Used for
-- both the Waking Threshold spawn and the real arrival spawn -- see Config.ThresholdSpawnPath/
-- ArrivalSpawnPath's own header for what a human needs to place at each.
local function resolveNamedInstance(path: { string }): Instance?
	local current: Instance = Workspace
	for _, name in ipairs(path) do
		local found = current:WaitForChild(name, Constants.Network.WaitForChildTimeoutSeconds)
		if not found then
			logger:error("resolveNamedInstance: WaitForChild timed out", {
				fullPath = table.concat(path, "/"),
				missingSegment = name,
			})
			return nil
		end
		current = found
	end
	return current
end

-- Resolves the CFrame to teleport a freshly-onboarded player to: the named ArrivalSpawnPath instance
-- if it exists and is a BasePart, otherwise ANY SpawnLocation already in the game (Roblox's own
-- default spawn-selection fallback), otherwise nil -- see this file's header, failure-handling
-- contract: a nil here means handleFinalize must NOT return Success = true, since there is genuinely
-- nowhere confirmed-safe to put the player.
local function resolveArrivalCFrame(): CFrame?
	local named = resolveNamedInstance(Config.ArrivalSpawnPath)
	if named and named:IsA("BasePart") then
		return (named :: BasePart).CFrame
	end
	if named then
		logger:error("resolveArrivalCFrame: ArrivalSpawnPath instance exists but is not a BasePart", {
			fullPath = table.concat(Config.ArrivalSpawnPath, "/"),
			className = named.ClassName,
		})
	end

	local fallbackSpawn = Workspace:FindFirstChildWhichIsA("SpawnLocation", true)
	if fallbackSpawn then
		logger:warn("resolveArrivalCFrame: falling back to an arbitrary SpawnLocation", {
			fallbackName = fallbackSpawn.Name,
		})
		return (fallbackSpawn :: SpawnLocation).CFrame
	end

	logger:error("resolveArrivalCFrame: no ArrivalSpawnPath instance AND no SpawnLocation exists anywhere", {})
	return nil
end

-- CharacterCreation_GetOnboardingState handler -- see this file's header for the full contract. Also
-- this SESSION's first Player:LoadCharacter() call for every player (onboarding or not), since
-- Players.CharacterAutoLoads = false (default.project.json) means nothing else in this codebase spawns anyone.
local function handleGetOnboardingState(player: Player): Types.CharacterCreationOnboardingStateResult
	logger:debug("GetOnboardingState received", { player = player.Name, userId = player.UserId })

	local profile = PlayerDataSystem.WaitForProfile(player)
	if not profile then
		logger:error("GetOnboardingState: profile never loaded -- cannot determine onboarding state", {
			player = player.Name,
		})
		return { NeedsOnboarding = false }
	end

	local needsOnboarding = profile.raceId == nil

	if spawnedThisSession[player] then
		return { NeedsOnboarding = needsOnboarding }
	end
	spawnedThisSession[player] = true

	if needsOnboarding then
		local thresholdSpawn = resolveNamedInstance(Config.ThresholdSpawnPath)
		if thresholdSpawn and thresholdSpawn:IsA("SpawnLocation") then
			player.RespawnLocation = thresholdSpawn :: SpawnLocation
		else
			logger:error(
				"GetOnboardingState: Waking Threshold spawn missing or not a SpawnLocation -- spawning at the "
					.. "engine's own default instead",
				{ fullPath = table.concat(Config.ThresholdSpawnPath, "/") }
			)
		end

		player:LoadCharacterAsync()
		AdminActionSystem.SetFrozen(player, true)
		logger:info("First-time player spawned into onboarding", { player = player.Name })
	else
		player:LoadCharacterAsync()
		logger:info("Returning player spawned", { player = player.Name })
	end

	return { NeedsOnboarding = needsOnboarding }
end

-- CharacterCreation_Finalize handler -- see this file's header for the non-negotiable
-- failure-handling contract. Order: re-check onboarding is still legitimate -> validate every field
-- server-side regardless of client checks -> filter the display name -> ONE atomic Transform ->
-- resolve the real spawn -> PivotTo -> unfreeze -> only then Success = true.
local function handleFinalize(player: Player, payload: unknown): Types.CharacterCreationFinalizeResult
	logger:debug("Finalize received", { player = player.Name, userId = player.UserId })

	if typeof(payload) ~= "table" then
		return { Success = false, Reason = "InvalidRequest" }
	end
	local rawPayload = payload :: { [string]: unknown }

	local profile = PlayerDataSystem.GetProfile(player)
	if not profile then
		return { Success = false, Reason = "ProfileNotLoaded" }
	end
	if profile.raceId ~= nil then
		-- Either a replay of an already-completed Finalize, or a modified client calling this outside
		-- the normal onboarding flow -- never re-run chargen against an already-onboarded profile.
		logger:warn("Finalize rejected: profile is already onboarded", { player = player.Name })
		return { Success = false, Reason = "AlreadyOnboarded" }
	end

	local raceId = CharacterCreationSystem.ValidateRaceId(rawPayload.RaceId)
	if not raceId then
		return { Success = false, Reason = "InvalidRaceId" }
	end

	local attributes, attributeFailReason =
		CharacterCreationSystem.ValidateAttributeBlock(rawPayload.Attributes, raceId)
	if not attributes then
		return { Success = false, Reason = attributeFailReason or "InvalidAttributes" }
	end

	local validatedName, nameFailReason = CharacterCreationSystem.ValidateDisplayName(rawPayload.DisplayName)
	if not validatedName then
		return { Success = false, Reason = nameFailReason or "InvalidDisplayName" }
	end

	local filterOk, filteredOrError = pcall(function(): string
		local filterResult =
			TextService:FilterStringAsync(validatedName, player.UserId, Enum.TextFilterContext.PublicChat)
		return filterResult:GetNonChatStringForBroadcastAsync()
	end)
	if not filterOk then
		logger:warn("Finalize rejected: name filtering failed", {
			player = player.Name,
			errorMessage = tostring(filteredOrError),
		})
		return { Success = false, Reason = "FilterFailed" }
	end
	local finalDisplayName = filteredOrError :: string

	local transformed = PlayerDataSystem.Transform(player, function(mutableProfile)
		mutableProfile.raceId = raceId
		mutableProfile.displayName = finalDisplayName
		mutableProfile.attributes = attributes
	end)
	if not transformed then
		-- Per this file's header: never attempt a teleport/unfreeze after a failed Transform. Rare
		-- (the profile is already known-loaded above), but must never corrupt state if it happens.
		logger:error("Finalize: Transform failed -- profile left unonboarded, no teleport attempted", {
			player = player.Name,
		})
		return { Success = false, Reason = "TransformFailed" }
	end

	local character = player.Character
	if not character then
		logger:error("Finalize: Transform succeeded but player has no live character to teleport", {
			player = player.Name,
		})
		return { Success = false, Reason = "NoCharacter" }
	end

	local arrivalCFrame = resolveArrivalCFrame()
	if not arrivalCFrame then
		-- Transform already succeeded -- the player IS onboarded on their next join even if this
		-- particular teleport can't complete right now (a genuine map-configuration problem, not a
		-- per-player failure). Still honestly reports Success = false rather than claiming a teleport
		-- that didn't happen, per this file's header.
		logger:error("Finalize: no arrival spawn available anywhere -- player stays in the Threshold", {
			player = player.Name,
		})
		return { Success = false, Reason = "NoSpawnAvailable" }
	end

	character:PivotTo(arrivalCFrame)
	AdminActionSystem.SetFrozen(player, false)

	-- Points future natural respawns (death in normal gameplay) at the real world instead of back into
	-- the Threshold -- player.RespawnLocation was pointed at the Threshold's own SpawnLocation earlier
	-- this session (handleGetOnboardingState). Only reassigned if the arrival instance is itself a
	-- SpawnLocation; otherwise cleared to nil so Roblox's own default spawn-selection takes over,
	-- rather than leaving the stale Threshold RespawnLocation in place.
	local arrivalNamed = resolveNamedInstance(Config.ArrivalSpawnPath)
	if arrivalNamed and arrivalNamed:IsA("SpawnLocation") then
		player.RespawnLocation = arrivalNamed :: SpawnLocation
	else
		player.RespawnLocation = nil :: any
	end

	logger:info("Finalize accepted -- player onboarded", {
		player = player.Name,
		raceId = raceId,
		displayName = finalDisplayName,
	})
	return { Success = true }
end

local function onPlayerRemoving(player: Player): ()
	spawnedThisSession[player] = nil
end

function CharacterCreationSystem.Init(): ()
	local onboardingStateRemote = NetworkBridge.CreateRemoteFunction(Config.RemoteNames.GetOnboardingState)
	logger:debug("Remote created", { name = Config.RemoteNames.GetOnboardingState })
	onboardingStateRemote.OnServerInvoke = function(player: Player)
		local ok, resultOrError = pcall(handleGetOnboardingState, player)
		if not ok then
			logger:error("GetOnboardingState handler errored", {
				player = player.Name,
				errorMessage = tostring(resultOrError),
			})
			return { NeedsOnboarding = false }
		end
		return resultOrError
	end
	logger:debug("Handler connected", { remote = Config.RemoteNames.GetOnboardingState })

	local finalizeRemote = NetworkBridge.CreateRemoteFunction(Config.RemoteNames.Finalize)
	logger:debug("Remote created", { name = Config.RemoteNames.Finalize })
	finalizeRemote.OnServerInvoke = function(player: Player, rawPayload: unknown)
		local ok, resultOrError = pcall(handleFinalize, player, rawPayload)
		if not ok then
			logger:error("Finalize handler errored", { player = player.Name, errorMessage = tostring(resultOrError) })
			return { Success = false, Reason = "InternalError" }
		end
		return resultOrError
	end
	logger:debug("Handler connected", { remote = Config.RemoteNames.Finalize })

	Players.PlayerRemoving:Connect(onPlayerRemoving)

	logger:info("CharacterCreationSystem.Init() complete")
end

-- Not cast to Types.SystemModule -- same reasoning as PlayerDataSystem.lua/BugReportSystem.lua's own
-- return: TestEZ needs ValidateRaceId/ValidateAttributeBlock/ValidateDisplayName visible, not just
-- Init.
return CharacterCreationSystem
