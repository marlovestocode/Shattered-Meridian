--!strict
--[[
	KitEditorClient.lua

	Owns: the local admin's Kit Editor UX -- keybind toggle (OpenKitEditor, resolved through
	Client/Input/KeybindManager.lua, same as MoveEditorClient.lua's OpenMoveEditor), the authorization
	round trip, and translating the KitEditor screen's New/Select/Delete/DraftFieldChanged/Save
	signals into Constants.KitEditor.RemoteNames RemoteFunction calls. Holds no copy of the admin
	whitelist -- ListRaceTraits doubles as the authorization check (any rejection means "not admin"),
	the same reasoning MoveEditorClient.lua's own requestServerAuthorization gives for reusing
	ListMoves.

	GENUINELY SIMPLER THAN MoveEditorClient.lua, and deliberately so -- this editor has no test-fire
	feedback, no hotbar binding, no undo/redo, and no rename-from-list (PropertyEditor.lua's own
	Identity section is where a TraitId/DisplayName/BloodlineId is edited). Only ONE draft is ever
	open at a time, so the pending-debounced-update state is a single slot (pendingUpdate below), not
	MoveEditorClient's own per-MoveId map -- switching away from the open draft (a different Select, a
	New, a Delete, or closing the panel) always flushes or cancels that one slot first, so there is
	nothing else it could ever need to track.

	DraftFieldChanged is DEBOUNCED (Constants.KitEditor.DraftDebounceSeconds) before it becomes a real
	UpdateRaceTraitDraft/UpdateBloodlineDraft call -- KitEditor/init.lua already applied the edit to
	the screen's own Draft value optimistically the instant it happened, so debouncing the NETWORK
	call costs nothing visually; it only limits how often a rapidly-clicked NumericField stepper
	actually round-trips. See MoveEditor/MoveEditorClient.lua's own DraftFieldChanged header for the
	fuller reasoning this mirrors.

	Does not own: whether a request is actually allowed (KitEditorSystem.lua re-checks server-side
	regardless), or the editor panel itself (UI/Screens/DevTools/KitEditor/init.lua) -- this module only drives
	that screen's handle from outside, the same "screen exposes state/signals, client module drives
	from outside" pattern MoveEditorClient.lua/DevMenuClient.lua already use.
]]

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Lazy = require(ReplicatedStorage.Shared.Lazy)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Constants = require(ReplicatedStorage.Shared.Constants)
local RaceTraitTypes = require(ReplicatedStorage.Shared.Race.RaceTraitTypes)
local BloodlineTypes = require(ReplicatedStorage.Shared.Bloodline.BloodlineTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)

local KitEditorModule = require(script.Parent.Parent.Parent.UI.Screens.DevTools.KitEditor)
local KitEditorTypes = require(script.Parent.Parent.Parent.UI.Screens.DevTools.KitEditor.Types)
local KeybindManager = require(script.Parent.Parent.Parent.Input.KeybindManager)
local Chrome = require(script.Parent.Parent.Parent.UI.Shell.Chrome)

type KitEditorHandle = KitEditorModule.KitEditorHandle
type KitDraft = KitEditorTypes.KitDraft

local peek = Fusion.peek

local logger = Logger.scope("KitEditorClient")

local Config = Constants.KitEditor

local KitEditorClient = {}

-- The one edit scheduled but not yet sent -- see this file's own header for why a single slot is
-- correct here (unlike MoveEditorClient's per-MoveId map).
type PendingUpdate = {
	Draft: KitDraft,
}
local pendingUpdate: PendingUpdate? = nil
-- Monotonic, bumped on every send -- sendDraftUpdateNow reconciles a response into Draft only when
-- nothing newer has been sent since, the same "a slow earlier round trip must not clobber a newer
-- edit" guard MoveEditorClient.lua's own draftSendSequenceByMoveId establishes.
local draftSendSequence = 0

-- How long a close request stays armed after being refused for unsaved changes -- same idea and
-- magnitude as MoveEditor/MoveEditorClient.lua's own CLOSE_ARM_SECONDS.
local CLOSE_ARM_SECONDS = 3

-- Replaces (or appends) ONE entry in `list` by its own id-extracting function, producing a fresh
-- top-level array (Fusion.Value reactivity) -- same "patch in place, never a blind full re-fetch"
-- reasoning MoveEditor/init.lua's own patchMovesDisplay follows.
local function patchList<T>(list: Fusion.Value<{ T }>, idOf: (T) -> string, updated: T): ()
	local current = peek(list)
	local newList = table.clone(current)
	local id = idOf(updated)
	local foundIndex: number? = nil
	for index, entry in ipairs(newList) do
		if idOf(entry) == id then
			foundIndex = index
			break
		end
	end
	if foundIndex then
		newList[foundIndex] = updated
	else
		table.insert(newList, updated)
	end
	list:set(newList)
end

local function removeFromList<T>(list: Fusion.Value<{ T }>, idOf: (T) -> string, id: string): ()
	local current = peek(list)
	local newList = {}
	for _, entry in ipairs(current) do
		if idOf(entry) ~= id then
			table.insert(newList, entry)
		end
	end
	list:set(newList)
end

local function defaultRaceTrait(): RaceTraitTypes.RaceTraitDefinition
	return {
		TraitId = "",
		RaceId = "Human",
		RequiredTier = 1,
		Ability = {
			Id = "",
			DisplayName = "New Trait",
			Description = "",
			Kind = "Passive",
			CooldownSeconds = 0,
			QiCost = 0,
			Effects = {},
		},
	}
end

local function defaultBloodline(): BloodlineTypes.BloodlineDefinition
	return {
		BloodlineId = "",
		DisplayName = "New Bloodline",
		RarityTier = "Common",
		FlavorText = "",
		NativeRaceId = nil,
		AwakeningCondition = { Kind = "OnPlayerKilled", Params = { RequiredKills = 10 } },
		Stages = {
			{ StageIndex = 1, DisplayName = "Stage 1", PassiveEffects = {} },
		},
	}
end

-- Asks the server whether this client may use the Kit Editor -- reuses ListRaceTraits rather than
-- adding a dedicated "am I an admin" remote, same reasoning MoveEditorClient.requestServerAuthorization
-- gives for ListMoves.
local function requestServerAuthorization(): (boolean, { RaceTraitTypes.RaceTraitDefinition }?)
	local listRaceTraitsRemote = NetworkBridge.GetRemoteFunction(Config.RemoteNames.ListRaceTraits)
	local ok, resultOrError = pcall(function()
		return listRaceTraitsRemote:InvokeServer()
	end)
	if not ok then
		logger:debug("KitEditor authorization check errored", { errorMessage = tostring(resultOrError) })
		return false, nil
	end
	local result = resultOrError :: RaceTraitTypes.RaceTraitEditorListResult?
	if result == nil or result.Success ~= true then
		return false, nil
	end
	return true, result.Traits or {}
end

-- Called only AFTER requestServerAuthorization already succeeded (gated by the same
-- checkKitEditorPreconditions, so there is no separate authorization question here). Failure degrades
-- to an empty list rather than blocking the editor from opening -- the Race Trait half should still
-- work even if this one fetch has trouble.
local function fetchBloodlines(): { BloodlineTypes.BloodlineDefinition }
	local ok, resultOrError = pcall(function()
		return NetworkBridge.GetRemoteFunction(Config.RemoteNames.ListBloodlines):InvokeServer()
	end)
	if not ok then
		logger:debug("ListBloodlines errored", { errorMessage = tostring(resultOrError) })
		return {}
	end
	local result = resultOrError :: BloodlineTypes.BloodlineEditorListResult
	if not result.Success or not result.Bloodlines then
		logger:debug("ListBloodlines rejected", { reason = result.Reason })
		return {}
	end
	return result.Bloodlines
end

local function startKitEditor(
	handle: KitEditorHandle,
	chrome: Chrome.ChromeHandle,
	initialRaceTraits: { RaceTraitTypes.RaceTraitDefinition },
	initialBloodlines: { BloodlineTypes.BloodlineDefinition }
): ()
	logger:info("KitEditorClient started")
	handle.RaceTraits:set(initialRaceTraits)
	handle.Bloodlines:set(initialBloodlines)

	local getRaceTraitRemote = NetworkBridge.GetRemoteFunction(Config.RemoteNames.GetRaceTrait)
	local updateRaceTraitDraftRemote = NetworkBridge.GetRemoteFunction(Config.RemoteNames.UpdateRaceTraitDraft)
	local saveRaceTraitRemote = NetworkBridge.GetRemoteFunction(Config.RemoteNames.SaveRaceTrait)
	local deleteRaceTraitRemote = NetworkBridge.GetRemoteFunction(Config.RemoteNames.DeleteRaceTrait)
	local getBloodlineRemote = NetworkBridge.GetRemoteFunction(Config.RemoteNames.GetBloodline)
	local updateBloodlineDraftRemote = NetworkBridge.GetRemoteFunction(Config.RemoteNames.UpdateBloodlineDraft)
	local saveBloodlineRemote = NetworkBridge.GetRemoteFunction(Config.RemoteNames.SaveBloodline)
	local deleteBloodlineRemote = NetworkBridge.GetRemoteFunction(Config.RemoteNames.DeleteBloodline)

	local function setOpenDraft(draft: KitDraft?): ()
		handle.Draft:set(draft)
	end

	local flushPendingUpdate: () -> ()
	local cancelPendingUpdate: () -> ()

	local function setOpen(open: boolean): ()
		if not open then
			flushPendingUpdate()
		end
		handle.IsOpen:set(open)
	end

	local closeArmedUntil = 0
	local function requestClose(): ()
		if peek(handle.IsDirty) and os.clock() > closeArmedUntil then
			closeArmedUntil = os.clock() + CLOSE_ARM_SECONDS
			handle.StatusText:set("Unsaved changes -- press again to close without saving.")
			return
		end
		closeArmedUntil = 0
		setOpen(false)
	end

	-- Escape belongs to Shell/Chrome.lua's one stack now, not to a branch of this module's own
	-- InputBegan. The BEHAVIOUR is unchanged, including the second-press-cancels arm below -- what
	-- changed is that Escape with this editor open underneath another panel closes that panel rather
	-- than both, and that this entry is pushed and popped off handle.IsOpen rather than off an edge
	-- somebody has to remember.
	chrome:BindEscape("KitEditor", handle.IsOpen, function()
		if os.clock() <= closeArmedUntil then
			closeArmedUntil = 0
			handle.StatusText:set("Close cancelled.")
		else
			requestClose()
		end
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if KeybindManager.Matches("OpenKitEditor", input) then
			setOpen(not peek(handle.IsOpen))
		end
	end)

	handle.CloseRequested:Connect(requestClose)

	handle.NewRaceTraitRequested:Connect(function()
		cancelPendingUpdate()
		local ok, resultOrError = pcall(function()
			return updateRaceTraitDraftRemote:InvokeServer(defaultRaceTrait())
		end)
		if not ok then
			handle.StatusText:set("Failed to create trait: request error")
			return
		end
		local result = resultOrError :: RaceTraitTypes.RaceTraitEditorTraitResult
		if result.Success and result.Trait then
			setOpenDraft({ Kind = "RaceTrait", Trait = result.Trait })
			handle.SavedFingerprint:set(KitEditorTypes.Fingerprint(result.Trait :: any))
			patchList(handle.RaceTraits, function(t)
				return t.TraitId
			end, result.Trait)
			handle.StatusText:set("New trait created.")
		else
			handle.StatusText:set(`Could not create trait: {result.Reason or "Unknown"}`)
		end
	end)

	handle.NewBloodlineRequested:Connect(function()
		cancelPendingUpdate()
		local ok, resultOrError = pcall(function()
			return updateBloodlineDraftRemote:InvokeServer(defaultBloodline())
		end)
		if not ok then
			handle.StatusText:set("Failed to create bloodline: request error")
			return
		end
		local result = resultOrError :: BloodlineTypes.BloodlineEditorBloodlineResult
		if result.Success and result.Bloodline then
			setOpenDraft({ Kind = "Bloodline", Bloodline = result.Bloodline })
			handle.SavedFingerprint:set(KitEditorTypes.Fingerprint(result.Bloodline :: any))
			patchList(handle.Bloodlines, function(b)
				return b.BloodlineId
			end, result.Bloodline)
			handle.StatusText:set("New bloodline created.")
		else
			handle.StatusText:set(`Could not create bloodline: {result.Reason or "Unknown"}`)
		end
	end)

	handle.SelectRaceTraitRequested:Connect(function(traitId: string)
		flushPendingUpdate()
		local ok, resultOrError = pcall(function()
			return getRaceTraitRemote:InvokeServer(traitId)
		end)
		if not ok then
			handle.StatusText:set("Failed to load trait: request error")
			return
		end
		local result = resultOrError :: RaceTraitTypes.RaceTraitEditorTraitResult
		if result.Success and result.Trait then
			setOpenDraft({ Kind = "RaceTrait", Trait = result.Trait })
			handle.SavedFingerprint:set(KitEditorTypes.Fingerprint(result.Trait :: any))
		else
			handle.StatusText:set(`Could not load trait: {result.Reason or "Unknown"}`)
		end
	end)

	handle.SelectBloodlineRequested:Connect(function(bloodlineId: string)
		flushPendingUpdate()
		local ok, resultOrError = pcall(function()
			return getBloodlineRemote:InvokeServer(bloodlineId)
		end)
		if not ok then
			handle.StatusText:set("Failed to load bloodline: request error")
			return
		end
		local result = resultOrError :: BloodlineTypes.BloodlineEditorBloodlineResult
		if result.Success and result.Bloodline then
			setOpenDraft({ Kind = "Bloodline", Bloodline = result.Bloodline })
			handle.SavedFingerprint:set(KitEditorTypes.Fingerprint(result.Bloodline :: any))
		else
			handle.StatusText:set(`Could not load bloodline: {result.Reason or "Unknown"}`)
		end
	end)

	handle.DeleteRaceTraitRequested:Connect(function(traitId: string)
		local currentDraft = peek(handle.Draft)
		if currentDraft and currentDraft.Kind == "RaceTrait" and currentDraft.Trait.TraitId == traitId then
			cancelPendingUpdate()
		end
		local ok, resultOrError = pcall(function()
			return deleteRaceTraitRemote:InvokeServer(traitId)
		end)
		if not ok then
			handle.StatusText:set("Failed to delete trait: request error")
			return
		end
		local result = resultOrError :: RaceTraitTypes.RaceTraitEditorActionResult
		if result.Success then
			removeFromList(handle.RaceTraits, function(t)
				return t.TraitId
			end, traitId)
			if currentDraft and currentDraft.Kind == "RaceTrait" and currentDraft.Trait.TraitId == traitId then
				setOpenDraft(nil)
				handle.SavedFingerprint:set("")
			end
			handle.StatusText:set("Trait deleted.")
		else
			handle.StatusText:set(`Could not delete trait: {result.Reason or "Unknown"}`)
		end
	end)

	handle.DeleteBloodlineRequested:Connect(function(bloodlineId: string)
		local currentDraft = peek(handle.Draft)
		if currentDraft and currentDraft.Kind == "Bloodline" and currentDraft.Bloodline.BloodlineId == bloodlineId then
			cancelPendingUpdate()
		end
		local ok, resultOrError = pcall(function()
			return deleteBloodlineRemote:InvokeServer(bloodlineId)
		end)
		if not ok then
			handle.StatusText:set("Failed to delete bloodline: request error")
			return
		end
		local result = resultOrError :: BloodlineTypes.BloodlineEditorActionResult
		if result.Success then
			removeFromList(handle.Bloodlines, function(b)
				return b.BloodlineId
			end, bloodlineId)
			if
				currentDraft
				and currentDraft.Kind == "Bloodline"
				and currentDraft.Bloodline.BloodlineId == bloodlineId
			then
				setOpenDraft(nil)
				handle.SavedFingerprint:set("")
			end
			handle.StatusText:set("Bloodline deleted.")
		else
			handle.StatusText:set(`Could not delete bloodline: {result.Reason or "Unknown"}`)
		end
	end)

	-- Pushes `newDraft` to the server's live registry RIGHT NOW (no debounce) and reconciles the
	-- response -- the one thing both the debounced DraftFieldChanged path and flushPendingUpdate must
	-- do identically. Yields (InvokeServer) -- every caller is a signal handler or another
	-- already-yielding function, so that's safe.
	local function sendDraftUpdateNow(newDraft: KitDraft): ()
		draftSendSequence += 1
		local sequence = draftSendSequence
		local ok, resultOrError = pcall(function()
			if newDraft.Kind == "RaceTrait" then
				return updateRaceTraitDraftRemote:InvokeServer(newDraft.Trait)
			end
			return updateBloodlineDraftRemote:InvokeServer(newDraft.Bloodline)
		end)
		if not ok then
			return
		end
		if newDraft.Kind == "RaceTrait" then
			local result = resultOrError :: RaceTraitTypes.RaceTraitEditorTraitResult
			if result.Success and result.Trait then
				if draftSendSequence ~= sequence then
					return
				end
				-- Kind checked FIRST, not just the id -- a TraitId and a BloodlineId are independently
				-- admin-typed strings with no uniqueness relationship to each other, so comparing ids
				-- alone risks a coincidental match reconciling this response into an open draft of the
				-- OTHER content type.
				local currentDraft = peek(handle.Draft)
				if
					currentDraft
					and currentDraft.Kind == "RaceTrait"
					and currentDraft.Trait.TraitId == result.Trait.TraitId
				then
					setOpenDraft({ Kind = "RaceTrait", Trait = result.Trait })
				end
				patchList(handle.RaceTraits, function(t)
					return t.TraitId
				end, result.Trait)
			end
		else
			local result = resultOrError :: BloodlineTypes.BloodlineEditorBloodlineResult
			if result.Success and result.Bloodline then
				if draftSendSequence ~= sequence then
					return
				end
				local currentDraft = peek(handle.Draft)
				if
					currentDraft
					and currentDraft.Kind == "Bloodline"
					and currentDraft.Bloodline.BloodlineId == result.Bloodline.BloodlineId
				then
					setOpenDraft({ Kind = "Bloodline", Bloodline = result.Bloodline })
				end
				patchList(handle.Bloodlines, function(b)
					return b.BloodlineId
				end, result.Bloodline)
			end
		end
	end

	handle.DraftFieldChanged:Connect(function(newDraft: KitDraft)
		local entry: PendingUpdate = { Draft = newDraft }
		pendingUpdate = entry
		task.delay(Config.DraftDebounceSeconds, function()
			if pendingUpdate ~= entry then
				return
			end
			pendingUpdate = nil
			sendDraftUpdateNow(entry.Draft)
		end)
	end)

	function flushPendingUpdate(): ()
		local entry = pendingUpdate
		if not entry then
			return
		end
		pendingUpdate = nil
		sendDraftUpdateNow(entry.Draft)
	end

	function cancelPendingUpdate(): ()
		pendingUpdate = nil
	end

	handle.SaveRequested:Connect(function()
		local currentDraft = peek(handle.Draft)
		if not currentDraft then
			return
		end
		local ok, resultOrError = pcall(function()
			if currentDraft.Kind == "RaceTrait" then
				return saveRaceTraitRemote:InvokeServer(currentDraft.Trait)
			end
			return saveBloodlineRemote:InvokeServer(currentDraft.Bloodline)
		end)
		if not ok then
			handle.StatusText:set("Failed to save: request error")
			return
		end
		if currentDraft.Kind == "RaceTrait" then
			local result = resultOrError :: RaceTraitTypes.RaceTraitEditorTraitResult
			if result.Success and result.Trait then
				setOpenDraft({ Kind = "RaceTrait", Trait = result.Trait })
				handle.SavedFingerprint:set(KitEditorTypes.Fingerprint(result.Trait :: any))
				patchList(handle.RaceTraits, function(t)
					return t.TraitId
				end, result.Trait)
				handle.StatusText:set("Saved.")
			else
				handle.StatusText:set(`Could not save: {result.Reason or "Unknown"}`)
			end
		else
			local result = resultOrError :: BloodlineTypes.BloodlineEditorBloodlineResult
			if result.Success and result.Bloodline then
				setOpenDraft({ Kind = "Bloodline", Bloodline = result.Bloodline })
				handle.SavedFingerprint:set(KitEditorTypes.Fingerprint(result.Bloodline :: any))
				patchList(handle.Bloodlines, function(b)
					return b.BloodlineId
				end, result.Bloodline)
				handle.StatusText:set("Saved.")
			else
				handle.StatusText:set(`Could not save: {result.Reason or "Unknown"}`)
			end
		end
	end)
end

-- Runs on a delay (task.spawn), same reasoning as MoveEditorClient.Start: this is called
-- synchronously partway through Main.client.lua's boot sequence, and the authorization round trip
-- yields. Takes a Shared/Lazy.lua thunk for the identical reason -- forced only once the server has
-- said yes AND both lists are in hand, so the panel is mounted with real data rather than mounted
-- empty and then filled.
function KitEditorClient.Start(deferredHandle: Lazy.Lazy<KitEditorHandle>, chrome: Chrome.ChromeHandle): ()
	task.spawn(function()
		local authorized, initialRaceTraits = requestServerAuthorization()
		if not authorized then
			logger:debug("KitEditorClient not started: server did not authorize this client")
			return
		end
		local initialBloodlines = fetchBloodlines()
		startKitEditor(deferredHandle.Get(), chrome, initialRaceTraits or {}, initialBloodlines)
	end)
end

return KitEditorClient
