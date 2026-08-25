--!strict
--[[
	CharacterMenuClient.lua

	Owns: the local player's character-menu UX -- the panel's open/close keybind (KeybindManager.
	Matches("CharacterMenuToggle", ...), the same pattern SettingsClient/DevMenuClient/
	BugReportClient already use), every network round trip the menu needs (the character sheet, the
	art catalogue, unlock, equip, emote-slot assignment), and one thing that isn't UI at all: keeping
	Client/Combat/HotbarBindings.lua in sync with the arts the server says are equipped.

	THAT LAST PART IS WHAT MAKES AN EQUIPPED ART PRESSABLE. HotbarBindings is the slot -> ArtId mirror
	the HUD renders and AttackInputClient.lua reads to build a hotbar press; this module (mirrorToHotbar,
	via HotbarBindings.SyncFromServer) is its ONLY writer -- see that module's own header on why the
	Move Editor's "bind to slot" control is no longer a second one, now that it equips through
	ArtSystem.DevGrantAndEquip server-side instead of writing here directly. Mirroring the server's
	equippedArts means slot N fires the art in slot N through the SAME AttackRequestSystem.resolveRequest
	path an admin's Move-Editor test-fire uses, with no second fire path to keep in sync -- and
	resolveRequest re-resolves the slot against ArtSystem.GetEquipped server-side regardless of what
	this client happens to hold, so the mirror is a convenience, never an authority.

	FETCH ON OPEN, not on a timer and not once at boot. The catalogue carries per-row LockedReason
	values computed server-side at fetch time (Types.ArtCatalogueEntry), so a catalogue held across a
	tier-up would show stale gates -- refetching every time the panel opens costs one call per open
	and is always current. Art mastery and equipped slots are the exception: those arrive pushed over
	Art_StateUpdated, because they change mid-fight while the panel may already be open.

	Does not own: whether any of it is allowed (ArtSystem re-checks every unlock/equip server-side
	against the same rules), the panel itself (UI/Screens/Menus/init.lua), or the bounty board's own
	two remotes (Screens/Menus/BountyTab.lua keeps those -- see its header).
]]

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Constants = require(ReplicatedStorage.Shared.Constants)
local ArtConstants = require(ReplicatedStorage.Shared.ArtConstants)
local BloodlineConstants = require(ReplicatedStorage.Shared.Bloodline.BloodlineConstants)
local BloodlineTypes = require(ReplicatedStorage.Shared.Bloodline.BloodlineTypes)
local EmoteConstants = require(ReplicatedStorage.Shared.EmoteConstants)
local Types = require(ReplicatedStorage.Shared.Types)
local Logger = require(ReplicatedStorage.Shared.Logger)

local MenusModule = require(script.Parent.Parent.UI.Screens.Menus)
local KeybindManager = require(script.Parent.Parent.Input.KeybindManager)
local HotbarBindings = require(script.Parent.Parent.Combat.HotbarBindings)
local RemoteInvoker = require(script.Parent.Parent.Network.RemoteInvoker)
local Chrome = require(script.Parent.Parent.UI.Shell.Chrome)

type MenusHandle = MenusModule.MenusHandle

local peek = Fusion.peek

local logger = Logger.scope("CharacterMenuClient")

local STATUS_CLEAR_DELAY = 4

local CharacterMenuClient = {}

-- Reason CODE -> the sentence a player reads, for the two action remotes. Every key is a string
-- ArtSystem can actually return from Unlock/Equip; an unknown code falls through to itself rather
-- than to a blank status, so a new server-side refusal is visible instead of silent.
local function describeArtFailure(reason: string?): string
	if reason == "AlreadyUnlocked" then
		return "You already know that art."
	elseif reason == "WrongFaction" then
		return "Your faction cannot walk that tree."
	elseif reason == "TierTooLow" then
		return "Your tier is too low for that art."
	elseif reason == "PrerequisiteNotMastered" then
		return `Master the form below it first ({ArtConstants.MasteryToUnlockNext} uses).`
	elseif reason == "BrokenPrerequisite" then
		return "That art's prerequisite is missing -- report it."
	elseif reason == "NotUnlocked" then
		return "Unlock that art before equipping it."
	elseif reason == "InvalidSlot" then
		return "That isn't a valid hotbar slot."
	elseif reason == "ProfileNotLoaded" then
		return "Your profile is still loading."
	elseif reason == "RateLimited" then
		return "Too many requests -- try again in a moment."
	end
	return "Failed: " .. (reason or "Unknown")
end

-- Reason CODE -> the sentence a player reads, for the bloodline reroll. Its own copy rather than
-- shared with OnboardingClient's identically-named helper: the two are worded for genuinely
-- different moments (that one is giving you blood for the first time, this one is replacing blood
-- you already carry), and requiring that module from here to save five strings would drag the
-- whole onboarding flow into the character menu's dependency graph.
local function describeSpinFailure(reason: string?): string
	if reason == "NoRerollsLeft" then
		return "No rerolls left -- what you carry is yours."
	elseif reason == "NoBloodlinesAvailable" then
		return "Nothing else answers. There is no other blood to take."
	elseif reason == "NoRaceChosen" then
		return "Your origin has not settled yet."
	elseif reason == "ProfileNotLoaded" then
		return "Your profile is still loading."
	elseif reason == "RateLimited" then
		return "Too many requests -- try again in a moment."
	end
	return "The reroll failed: " .. (reason or "Unknown")
end

local statusGeneration = 0

local function setStatus(handle: MenusHandle, message: string): ()
	statusGeneration += 1
	local generation = statusGeneration
	handle.StatusText:set(message)
	task.delay(STATUS_CLEAR_DELAY, function()
		-- Only the LATEST message clears itself -- an older delayed clear must never wipe a newer
		-- message, the same generation guard SettingsClient.setStatus already uses.
		if statusGeneration == generation then
			handle.StatusText:set("")
		end
	end)
end

-- Forwards the server's equipped-arts push straight to HotbarBindings.SyncFromServer -- see that
-- module's own header on why this is now its only writer.
local function mirrorToHotbar(equipped: { [number]: string }): ()
	HotbarBindings.SyncFromServer(equipped)
end

-- Validated at the boundary for the same reason ClientState.Bootstrap validates its own payloads --
-- a Types annotation is not enforced across a remote, and a malformed row should be dropped rather
-- than reaching a Fusion ForPairs and taking the panel down with it.
local function sanitizeArtState(payload: unknown): ({ [string]: number }, { [number]: string })
	local mastery: { [string]: number } = {}
	local equipped: { [number]: string } = {}
	if typeof(payload) ~= "table" then
		return mastery, equipped
	end
	local table_ = payload :: { [string]: any }
	if typeof(table_.Mastery) == "table" then
		for artId, value in pairs(table_.Mastery :: { [any]: any }) do
			if typeof(artId) == "string" and typeof(value) == "number" then
				mastery[artId] = value
			end
		end
	end
	if typeof(table_.Equipped) == "table" then
		for slot, artId in pairs(table_.Equipped :: { [any]: any }) do
			if typeof(slot) == "number" and typeof(artId) == "string" then
				equipped[slot] = artId
			end
		end
	end
	return mastery, equipped
end

local function isValidSheet(payload: unknown): boolean
	if typeof(payload) ~= "table" then
		return false
	end
	local candidate = payload :: { [string]: any }
	return typeof(candidate.BloodlineIds) == "table"
		and typeof(candidate.Corruption) == "number"
		and typeof(candidate.QiDeviationRisk) == "number"
		and typeof(candidate.FactionStanding) == "number"
		and typeof(candidate.HasAscended) == "boolean"
end

function CharacterMenuClient.Start(handle: MenusHandle, chrome: Chrome.ChromeHandle): ()
	logger:info("CharacterMenuClient.Start called")

	-- ADOPTED, not migrated: this screen had no Escape handling at all, so M was the only way out of
	-- the biggest panel in the game. See Shell/Chrome.lua's Escape-stack header for the four screens
	-- that did have one and the five, this one first, that did not.
	chrome:BindEscape("CharacterMenu", handle.IsOpen, function()
		handle.IsOpen:set(false)
		logger:debug("Character menu closed on Escape")
	end)

	local sheetUpdated = NetworkBridge.GetRemoteEvent(Constants.CharacterSheet.RemoteNames.SheetUpdated)
	local getSheet = NetworkBridge.GetRemoteFunction(Constants.CharacterSheet.RemoteNames.GetSheet)
	local artStateUpdated = NetworkBridge.GetRemoteEvent(ArtConstants.RemoteNames.ArtStateUpdated)
	local getCatalogue = NetworkBridge.GetRemoteFunction(ArtConstants.RemoteNames.GetArtCatalogue)
	local unlockArt = NetworkBridge.GetRemoteFunction(ArtConstants.RemoteNames.UnlockArt)
	local equipArt = NetworkBridge.GetRemoteFunction(ArtConstants.RemoteNames.EquipArt)
	local spinBloodline = NetworkBridge.GetRemoteFunction(BloodlineConstants.RemoteNames.Spin)
	local setEmoteSlot = NetworkBridge.GetRemoteEvent(EmoteConstants.RemoteNames.RequestSetLoadoutSlot)

	sheetUpdated.OnClientEvent:Connect(function(payload: Types.CharacterSheetPayload)
		if not isValidSheet(payload) then
			logger:warn("Malformed Character_SheetUpdated payload ignored", { payload = tostring(payload) })
			return
		end
		handle.Sheet:set(payload)
	end)

	artStateUpdated.OnClientEvent:Connect(function(payload: Types.ArtStatePayload)
		local mastery, equipped = sanitizeArtState(payload)
		handle.ArtMastery:set(mastery)
		handle.EquippedArts:set(equipped)
		mirrorToHotbar(equipped)
	end)

	-- Every RemoteFunction call below is wrapped and spawned: an invoke yields, and a server that
	-- drops one must cost a status line rather than the whole handler -- the same pcall+task.spawn
	-- shape BountyTab.lua's own initial fetch uses.
	local function refreshSheet(): ()
		task.spawn(function()
			local ok, result = RemoteInvoker.Invoke(getSheet)
			if not ok then
				logger:warn("Character sheet fetch failed", { error = tostring(result) })
				return
			end
			-- nil is a legitimate answer (profile not loaded yet) and is left alone rather than
			-- overwriting a sheet that already arrived over the push channel.
			if isValidSheet(result) then
				handle.Sheet:set(result :: Types.CharacterSheetPayload)
			end
		end)
	end

	local function refreshCatalogue(): ()
		task.spawn(function()
			local ok, result = RemoteInvoker.Invoke(getCatalogue)
			if not ok then
				logger:warn("Art catalogue fetch failed", { error = tostring(result) })
				setStatus(handle, "Couldn't reach the art trees -- try reopening.")
				return
			end
			local catalogue = result :: Types.ArtCatalogueResult
			if typeof(catalogue) ~= "table" or not catalogue.Success or typeof(catalogue.Trees) ~= "table" then
				local reason = if typeof(catalogue) == "table" then catalogue.Reason else nil
				logger:warn("Art catalogue refused", { reason = tostring(reason) })
				setStatus(handle, describeArtFailure(reason))
				return
			end
			handle.ArtTrees:set(catalogue.Trees :: { Types.ArtCatalogueTree })
		end)
	end

	handle.Opened:Connect(function()
		refreshSheet()
		refreshCatalogue()
	end)

	handle.UnlockArtRequested:Connect(function(artId: string)
		task.spawn(function()
			local ok, result = RemoteInvoker.Invoke(unlockArt, artId)
			if not ok then
				logger:warn("Art unlock failed", { artId = artId, error = tostring(result) })
				setStatus(handle, "Couldn't reach the server.")
				return
			end
			local action = result :: Types.ArtActionResult
			if typeof(action) ~= "table" or not action.Success then
				local reason = if typeof(action) == "table" then action.Reason else nil
				setStatus(handle, describeArtFailure(reason))
				return
			end
			setStatus(handle, "Art unlocked.")
			-- The unlock changed every OTHER row's LockedReason too (a prerequisite is now owned), so
			-- the whole catalogue is refetched rather than the one row being patched locally -- the
			-- server is the only thing that knows what just became reachable.
			refreshCatalogue()
		end)
	end)

	-- THE SAME REMOTE the onboarding creator's own spin uses. A reroll from this menu and a roll
	-- during character creation are the identical server operation -- BloodlineSystem.Spin decides
	-- whether it is free (you hold nothing) or costs a reroll, so neither caller has to know.
	handle.RerollBloodlineRequested:Connect(function()
		task.spawn(function()
			local ok, result = RemoteInvoker.Invoke(spinBloodline)
			if not ok then
				logger:warn("Bloodline reroll failed", { error = tostring(result) })
				setStatus(handle, "Couldn't reach the server.")
				return
			end
			local spin = result :: BloodlineTypes.BloodlineSpinResult
			if typeof(spin) ~= "table" or not spin.Success then
				local reason = if typeof(spin) == "table" then spin.Reason else nil
				setStatus(handle, describeSpinFailure(reason))
				return
			end
			-- No local write to the sheet: Awaken calls CharacterSheetSystem.Refresh, and that push is
			-- what updates the bloodline line AND the reroll count. Writing optimistically would risk
			-- showing blood the server hadn't accepted -- the same desync the equip handler below
			-- avoids for the identical reason.
			setStatus(handle, `The blood answers: {spin.DisplayName or spin.BloodlineId}.`)
		end)
	end)

	handle.EquipArtRequested:Connect(function(slot: number, artId: string?)
		task.spawn(function()
			local ok, result = RemoteInvoker.Invoke(equipArt, slot, artId)
			if not ok then
				logger:warn("Art equip failed", { slot = slot, artId = artId, error = tostring(result) })
				setStatus(handle, "Couldn't reach the server.")
				return
			end
			local action = result :: Types.ArtActionResult
			if typeof(action) ~= "table" or not action.Success then
				local reason = if typeof(action) == "table" then action.Reason else nil
				setStatus(handle, describeArtFailure(reason))
				return
			end
			-- No local write to EquippedArts here: the server pushes Art_StateUpdated on every
			-- successful equip, and that push is what updates the panel AND the hotbar mirror. Setting
			-- it optimistically would risk showing a slot the server hadn't actually accepted, which is
			-- exactly the desync ui-ux-philosophy.md's HUD sync rule forbids.
			setStatus(handle, if artId then `Equipped to slot {slot}.` else `Slot {slot} cleared.`)
		end)
	end)

	handle.EmoteSlotAssigned:Connect(function(slot: number, emoteId: string)
		-- Fire-and-forget, unlike the art remotes above: Emote_RequestSetLoadoutSlot is a RemoteEvent
		-- whose confirmation is the Emote_LoadoutUpdated push ClientState already listens for, so the
		-- slot strip updates from the server's own answer with nothing for this module to await.
		setEmoteSlot:FireServer(slot, emoteId)
		setStatus(handle, `Slot {slot} set.`)
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if KeybindManager.Matches("CharacterMenuToggle", input) then
			local nowOpen = not peek(handle.IsOpen)
			handle.IsOpen:set(nowOpen)
			logger:debug("Character menu toggled", { open = nowOpen })
		end
	end)

	-- One fetch at start, ahead of any open: the profile-load push may have fired before this client
	-- ever connected its listener above, and a player who opens the Character tab first should not
	-- watch it say "waiting" while a perfectly good sheet sits on the server. The equipped-art mirror
	-- has the same need for a different reason -- the hotbar should hold this player's arts from
	-- spawn, not from the first time they happen to open the menu.
	refreshSheet()
	refreshCatalogue()

	logger:debug("CharacterMenuClient bindings connected")
end

return CharacterMenuClient
