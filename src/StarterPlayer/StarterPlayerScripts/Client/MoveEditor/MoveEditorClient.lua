--!strict
--[[
	MoveEditorClient.lua

	Owns: the local admin's Move Editor UX -- keybind toggle (OpenMoveEditor, resolved through
	Client/Input/KeybindManager.lua, same as DevMenuClient.lua's DevMenuToggle), the authorization
	round trip, and translating the MoveEditor screen's New/Select/Delete/DraftFieldChanged/
	TestFire/Save/Reset signals into Constants.MoveEditor.RemoteNames RemoteFunction calls. Holds no
	copy of the admin whitelist -- exactly DevMenuClient.lua's own reasoning, reused here: ListMoves
	doubles as the authorization check (any rejection means "not admin"), the same way
	DevMenuClient.lua reuses DevMenu_GetSidebarStats instead of a dedicated "am I an admin" remote.

	Also fetches ListDefaultMoves (Server/Combat/DefaultMoveRegistry.lua's projection of every
	hand-authored weapon stage/standalone attack, Category == "Default") alongside ListMoves on
	start and merges both into the one MovesDisplay array MoveList.lua's Default/Custom tabs filter
	over -- see this file's own startMoveEditor. DraftFieldChanged/SaveRequested/ResetRequested all
	route to UpdateDefaultMoveDraft/SaveDefaultMove/ResetDefaultMove instead of UpdateDraft/SaveMove
	whenever the current draft's Category == "Default" -- a Default move's Save persists its current
	live values to a DataStore override (MoveEditorSystem.lua's own header), not a client-submitted
	candidate, so SaveDefaultMove only needs the moveId. SelectMoveRequested for a Default move never
	round-trips at all (resolved straight from the already-fetched MovesDisplay cache -- there is no
	GetDefaultMove remote, since nothing about a Default move's data can go stale between fetch and
	selection the way a custom move edited by another admin concurrently could).

	DraftFieldChanged is DEBOUNCED (Constants.MoveEditor.DraftDebounceSeconds) before it becomes a
	real UpdateDraft call -- Screens/MoveEditor/init.lua already applied the edit to the screen's own
	Draft value optimistically the instant it happened, so debouncing the NETWORK call costs nothing
	visually; it only limits how often a rapidly-clicked NumericField stepper actually round-trips.
	A generation counter (mirrors DevMenuClient.lua's own statusGeneration idiom) guards a stale,
	superseded response from clobbering a newer edit that landed while the old one was still in
	flight.

	Test-fire results stream back over the EXISTING Combat_FeedbackEvent/Combat_AttackStarted remotes
	(already wired for every player via CombatClient.lua) rather than a new one -- DummyCombat.
	ResolveHit already sends feedback to the attacking player for any hit, custom move or not; this
	module only filters by AttackDebugName == the move currently awaiting a test result.

	Does not own: whether a request is actually allowed (MoveEditorSystem.lua re-checks
	server-side regardless), or the editor panel itself (UI/Screens/MoveEditor/init.lua) -- this
	module only drives that screen's handle from outside, the same "screen exposes state/signals,
	client module drives from outside" pattern DevMenuClient.lua already uses.

	Also mirrors Client/Combat/HotbarBindings.lua into handle.HotbarBindings and routes
	handle.BindHotbarSlotRequested into it (2026-08-10, the Move Creation System hotbar pass) --
	see this file's own wiring in startMoveEditor and HotbarBindings.lua's own header. Unlike every
	remote-backed signal above, this one never touches NetworkBridge -- binding a move to a hotbar
	slot is pure client-side bookkeeping; only firing the bound move round-trips to the server
	(Client/Combat/HotbarMoveClient.lua, a different module entirely -- this feature's actual
	live-fire path runs independently of whether the Move Editor screen is even open).
]]

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local MoveStats = require(ReplicatedStorage.Shared.MoveStats)
local Logger = require(ReplicatedStorage.Shared.Logger)

local MoveEditorModule = require(script.Parent.Parent.UI.Screens.MoveEditor)
local KeybindManager = require(script.Parent.Parent.Input.KeybindManager)
local HotbarBindings = require(script.Parent.Parent.Combat.HotbarBindings)

type MoveEditorHandle = MoveEditorModule.MoveEditorHandle

local peek = Fusion.peek

local logger = Logger.scope("MoveEditorClient")

local Config = Constants.MoveEditor
local CombatRemoteNames = Constants.Combat.RemoteNames

local MoveEditorClient = {}

-- Guards a debounced UpdateDraft response against clobbering a newer edit that landed while the
-- old one was still in flight -- same idiom as DevMenuClient.lua's own statusGeneration.
local draftUpdateGeneration = 0

-- True from the moment a field edit schedules a debounced UpdateDraft until that exact call
-- either lands or is superseded/flushed -- see flushPendingDraftUpdate's own header below for why
-- this exists. Without it, TestFireMove (and, transitively, a hotbar press that follows once the
-- panel closes) can read MoveRegistryManager's LIVE registry before the debounced UpdateDraft the
-- most recent field edit scheduled has actually reached the server: Config.DraftDebounceSeconds
-- (150ms) plus the RemoteFunction round trip on top of it is easily beaten by the completely
-- ordinary "edit a field, immediately click Test on Dummy" click cadence, which throws whatever
-- shape the server still has -- the move's PREVIOUS geometry, or defaultDraft's own Box for a
-- move that was only just created -- instead of what the editor's own (purely client-local,
-- zero-round-trip) PreviewViewport gizmo is already showing.
local pendingDraftSync = false

-- Forward-declared (same pattern as requestSave/requestDuplicate further down): setOpen needs to
-- call this on every close, but its real definition lives alongside DraftFieldChanged's own
-- handler further down, where sendDraftUpdateNow (which it shares) is defined.
local flushPendingDraftUpdate: () -> ()

-- Set right before firing TestFireMove, cleared when the collection window below closes (or when a
-- fresh test/selection supersedes it) -- lets the feedback listener (wired once, for the whole
-- session) know which move's result to report on.
local awaitingTestMoveId: string? = nil
-- os.clock() at the moment TestFireMove was invoked, and when this test stops collecting. Every
-- feedback payload naming awaitingTestMoveId that lands inside the window becomes one
-- MoveStats.TestSample, timestamped relative to the start.
--
-- A WINDOW rather than the "first payload wins, then clear" rule this used to have: a multi-hit move
-- fires one feedback payload PER HIT, and stopping at the first would report every move as a
-- one-hit move -- which is precisely what the stats graphs exist to disprove. The old rule was
-- sufficient only because LastTestResultText shows a single line.
local testWindowStartedAt = 0
local testWindowExpiresAt = 0

-- Bumped by every setOpen call (manual or automatic). TestFireRequested's auto-reopen (below)
-- captures the value right after it auto-closes the panel and only reopens if nothing else has
-- touched IsOpen since -- so an admin who manually reopens, closes, or fires another test during the
-- window supersedes the pending auto-reopen instead of fighting it.
local testReopenToken = 0

-- How long past the move's own authored duration the window stays open, covering the round trip plus
-- anything the move schedules after its recovery ends -- an Object Stun follow-up is the long pole
-- (its own DelaySeconds, then the follow-up's full windup/active), so this is generous on purpose:
-- a late sample that lands after the window is silently lost, which is a much worse failure than a
-- window that stayed open a second longer than it needed to.
local TEST_WINDOW_TRAILING_SECONDS = 4

-- Test on Dummy auto-closes the editor panel (see handle.TestFireRequested below) so the panel
-- itself isn't covering the one thing the admin just asked to see. Reopens automatically once the
-- move has finished playing out on the dummy -- the move's own authored Windup+Active+Recovery, plus
-- this small buffer so a fast move's hit reaction is still visible for a beat before the panel snaps
-- back, rather than reopening the instant Recovery ends.
local TEST_REOPEN_BUFFER_SECONDS = 0.75

-- How long a close request stays armed after being refused for unsaved changes -- same idea and
-- magnitude as MoveList.lua's own DELETE_ARM_SECONDS for its two-press delete.
local CLOSE_ARM_SECONDS = 3

-- Ctrl (or Cmd, on macOS) for the editor's own Save/Duplicate shortcuts. Read at the moment the key
-- lands rather than tracked as state, since InputBegan already tells us exactly when to ask.
local function isModifierDown(): boolean
	return UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
		or UserInputService:IsKeyDown(Enum.KeyCode.LeftMeta)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightMeta)
end

-- The wire shape MoveRegistryManager.Validate expects: Offset decomposed into flat OffsetX/Y/Z
-- numbers (v1 authors no rotation -- see MoveDefinition.Offset's own header), everything else
-- passed through unchanged. MoveId/Author/CreatedAt/UpdatedAt are sent as-is; MoveEditorSystem's
-- stampTrustedMetadata always overwrites them from trusted server context before Validate ever
-- runs, so whatever this function sends for those four fields is informational only.
local function encodeDraftForWire(draft: MoveTypes.MoveDefinition): { [string]: unknown }
	local wire: { [string]: unknown } = table.clone(draft :: any)
	wire.Offset = nil
	wire.OffsetX = draft.Offset.X
	wire.OffsetY = draft.Offset.Y
	wire.OffsetZ = draft.Offset.Z
	return wire
end

local function defaultDraft(): MoveTypes.MoveDefinition
	return {
		MoveId = "",
		DisplayName = "New Move",
		Category = "",
		Author = "",
		CreatedAt = 0,
		UpdatedAt = 0,
		Shape = "Box",
		Size = Vector3.new(4, 4, 4),
		Radius = nil,
		Offset = CFrame.new(0, 0, -3),
		WindupSeconds = 0.2,
		ActiveSeconds = 0.15,
		RecoverySeconds = 0.3,
		Cooldown = 0.6,
		Damage = 5,
		PostureDamage = 5,
		ArcDegrees = 100,
		MaxTargets = 5,
		AnimationId = "",
		Movement = nil,
		Knockback = nil,
	}
end

-- Replaces (or appends) ONE move in MovesDisplay by MoveId, producing a fresh top-level array
-- (required for Fusion.Value reactivity) while leaving every OTHER move's own table reference
-- untouched -- see MoveEditor/Types.lua's own header for why this patch-in-place approach (never a
-- blind full re-fetch) matters for MoveList's per-row local UI state (its own delete-Armed timer).
local function patchMovesDisplay(handle: MoveEditorHandle, updatedMove: MoveTypes.MoveDefinition): ()
	local current = peek(handle.MovesDisplay)
	local newList = table.clone(current)
	local foundIndex: number? = nil
	for index, move in ipairs(newList) do
		if move.MoveId == updatedMove.MoveId then
			foundIndex = index
			break
		end
	end
	if foundIndex then
		newList[foundIndex] = updatedMove
	else
		table.insert(newList, updatedMove)
	end
	handle.MovesDisplay:set(newList)
end

local function removeFromMovesDisplay(handle: MoveEditorHandle, moveId: string): ()
	local current = peek(handle.MovesDisplay)
	local newList = {}
	for _, move in ipairs(current) do
		if move.MoveId ~= moveId then
			table.insert(newList, move)
		end
	end
	handle.MovesDisplay:set(newList)
end

-- Asks the server whether this client may use the Move Editor -- reuses ListMoves rather than
-- adding a dedicated "am I an admin" remote, same reasoning as DevMenuClient.
-- requestServerAuthorization.
local function requestServerAuthorization(): (boolean, { MoveTypes.MoveDefinition }?)
	local ok, resultOrError = pcall(function()
		return NetworkBridge.GetRemoteFunction(Config.RemoteNames.ListMoves):InvokeServer()
	end)
	if not ok then
		logger:debug("MoveEditor authorization check errored", { errorMessage = tostring(resultOrError) })
		return false, nil
	end
	local result = resultOrError :: MoveTypes.MoveEditorListResult?
	if result == nil or result.Success ~= true then
		return false, nil
	end
	return true, result.Moves or {}
end

-- Fetches every Default move (Server/Combat/DefaultMoveRegistry.lua's projection) -- called only
-- AFTER requestServerAuthorization already succeeded (this remote is gated by the same
-- checkMoveEditorPreconditions, so there is no separate authorization question to answer here).
-- Failure degrades to an empty list rather than blocking the editor from opening at all -- the
-- Custom-move half of the screen should still work even if this one fetch has trouble.
local function fetchDefaultMoves(): { MoveTypes.MoveDefinition }
	local ok, resultOrError = pcall(function()
		return NetworkBridge.GetRemoteFunction(Config.RemoteNames.ListDefaultMoves):InvokeServer()
	end)
	if not ok then
		logger:debug("ListDefaultMoves errored", { errorMessage = tostring(resultOrError) })
		return {}
	end
	local result = resultOrError :: MoveTypes.MoveEditorListResult
	if not result.Success or not result.Moves then
		logger:debug("ListDefaultMoves rejected", { reason = result.Reason })
		return {}
	end
	return result.Moves
end

local function startMoveEditor(handle: MoveEditorHandle, initialMoves: { MoveTypes.MoveDefinition }): ()
	logger:info("MoveEditorClient started")
	handle.MovesDisplay:set(initialMoves)

	local getMoveRemote = NetworkBridge.GetRemoteFunction(Config.RemoteNames.GetMove)
	local updateDraftRemote = NetworkBridge.GetRemoteFunction(Config.RemoteNames.UpdateDraft)
	local saveMoveRemote = NetworkBridge.GetRemoteFunction(Config.RemoteNames.SaveMove)
	local deleteMoveRemote = NetworkBridge.GetRemoteFunction(Config.RemoteNames.DeleteMove)
	local testFireMoveRemote = NetworkBridge.GetRemoteFunction(Config.RemoteNames.TestFireMove)
	local spawnPreviewDummyRemote = NetworkBridge.GetRemoteFunction(Config.RemoteNames.SpawnPreviewDummy)
	local updateDefaultMoveDraftRemote = NetworkBridge.GetRemoteFunction(Config.RemoteNames.UpdateDefaultMoveDraft)
	local saveDefaultMoveRemote = NetworkBridge.GetRemoteFunction(Config.RemoteNames.SaveDefaultMove)
	local resetDefaultMoveRemote = NetworkBridge.GetRemoteFunction(Config.RemoteNames.ResetDefaultMove)
	local setEditorOpenRemote = NetworkBridge.GetRemoteEvent(Config.RemoteNames.SetEditorOpen)

	-- Live-mirrors Client/Combat/HotbarBindings.lua into handle.HotbarBindings for
	-- PropertyEditor.lua's toolbar to read reactively -- see that module's own header on why it's a
	-- plain Luau module rather than a Fusion.Value itself, and MoveEditor/Types.lua's own header on
	-- this field. Seeded immediately (an admin may have bound slots in an earlier open this same
	-- session) and never unsubscribed -- this client module runs for the life of the session, same
	-- lifetime as every other listener it sets up below.
	handle.HotbarBindings:set(HotbarBindings.GetAll())
	HotbarBindings.OnChanged(function()
		handle.HotbarBindings:set(HotbarBindings.GetAll())
	end)

	-- The ONE place IsOpen is ever written client-side (the keybind toggle and the screen's own "X"
	-- button both route through this) -- keeps the server-side freeze/unfreeze
	-- (AdminActionSystem.SetFrozen via MoveEditorSystem's SetEditorOpen handler) in lockstep with
	-- every open/close transition, not just the keybind one. Editing a move's numbers shouldn't leave
	-- the admin's own character free to walk/attack mid-edit.
	local function setOpen(open: boolean): ()
		-- Any explicit open/close (manual or automatic) supersedes a pending Test on Dummy
		-- auto-reopen -- see testReopenToken's own header.
		testReopenToken += 1
		if not open then
			-- Closing the panel is the moment every downstream consumer of the LIVE registry
			-- (TestFireMove directly, and a hotbar press that follows once the panel is gone)
			-- can next read it -- flush any edit still sitting inside the debounce window now,
			-- so that read sees the admin's actual last edit rather than whatever the server
			-- still had. See pendingDraftSync's own header for the race this closes.
			flushPendingDraftUpdate()
		end
		handle.IsOpen:set(open)
		setEditorOpenRemote:FireServer(open)
	end

	-- Guarded close, covering BOTH the screen's own "X" button and the Escape shortcut below, because
	-- both route through this one function. UpdateDraft has already pushed the admin's edits into the
	-- server's in-memory registry, but only Save writes the DataStore -- so closing on a dirty draft
	-- silently discards real work, which is exactly what this stops.
	--
	-- An os.clock() deadline rather than an armed BUTTON: arming the X visually would need reactive
	-- Text on a Button (whose Primary variant peeks its text once -- see Button.lua's header) and
	-- would leave Escape unguarded or duplicate the state across two paths. One deadline, no timer to
	-- cancel, and the status line is the feedback. Same two-press-to-confirm shape MoveList.lua's own
	-- DELETE_ARM_SECONDS already uses for its irreversible action.
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

	-- Extracted so the keyboard shortcuts below can invoke the exact same behaviour the toolbar
	-- buttons do. The screen owns those BindableEvents and this module can only connect to them, not
	-- fire them -- so the handler bodies live here as locals and both callers share them, rather than
	-- MoveEditorHandle growing a set of raw BindableEvents purely to satisfy a keybind.
	local requestSave: () -> ()
	local requestDuplicate: () -> ()

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if KeybindManager.Matches("OpenMoveEditor", input) then
			setOpen(not peek(handle.IsOpen))
			return
		end
		-- Every shortcut below is editor-scoped. Without this gate Ctrl+S would fire a save from
		-- anywhere in the game with the editor closed.
		if not peek(handle.IsOpen) then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape then
			requestClose()
		elseif input.KeyCode == Enum.KeyCode.S and isModifierDown() then
			requestSave()
		elseif input.KeyCode == Enum.KeyCode.D and isModifierDown() then
			requestDuplicate()
		end
	end)

	handle.CloseRequested:Connect(requestClose)

	handle.NewMoveRequested:Connect(function()
		local ok, resultOrError = pcall(function()
			return updateDraftRemote:InvokeServer(encodeDraftForWire(defaultDraft()))
		end)
		if not ok then
			handle.StatusText:set("Failed to create move: request error")
			return
		end
		local result = resultOrError :: MoveTypes.MoveEditorMoveResult
		if result.Success and result.Move then
			handle.Draft:set(result.Move)
			handle.SavedFingerprint:set(MoveTypes.Fingerprint(result.Move))
			patchMovesDisplay(handle, result.Move)
			handle.StatusText:set("New move created.")
		else
			handle.StatusText:set("Failed to create move: " .. (result.Reason or "Unknown"))
		end
	end)

	handle.SelectMoveRequested:Connect(function(moveId: string)
		-- Samples belong to the move that produced them, so switching moves drops them and closes any
		-- still-open collection window -- otherwise the Stats panel would keep plotting the PREVIOUS
		-- move's hits under the newly selected move's name, which is worse than plotting nothing.
		awaitingTestMoveId = nil
		handle.TestSamples:set({})

		-- A Default move is already fully known client-side from the initial ListDefaultMoves fetch
		-- (see MoveEditorClient.Start) -- there is no GetDefaultMove remote and no reason for one
		-- (nothing about a Default move's data can go stale between fetch and selection the way a
		-- custom move edited by another admin concurrently could -- see this file's own header), so
		-- resolve straight from the cache instead of a round trip.
		local cached = peek(handle.MovesDisplay)
		for _, move in ipairs(cached) do
			if move.MoveId == moveId and move.Category == MoveTypes.DefaultCategory then
				handle.Draft:set(move)
				handle.SavedFingerprint:set(MoveTypes.Fingerprint(move))
				return
			end
		end
		local ok, resultOrError = pcall(function()
			return getMoveRemote:InvokeServer(moveId)
		end)
		if not ok then
			handle.StatusText:set("Failed to load move: request error")
			return
		end
		local result = resultOrError :: MoveTypes.MoveEditorMoveResult
		if result.Success and result.Move then
			handle.Draft:set(result.Move)
			handle.SavedFingerprint:set(MoveTypes.Fingerprint(result.Move))
		else
			handle.StatusText:set("Failed to load move: " .. (result.Reason or "Unknown"))
		end
	end)

	handle.DeleteMoveRequested:Connect(function(moveId: string)
		local ok, resultOrError = pcall(function()
			return deleteMoveRemote:InvokeServer(moveId)
		end)
		if not ok then
			handle.StatusText:set("Failed to delete move: request error")
			return
		end
		local result = resultOrError :: MoveTypes.MoveEditorActionResult
		if result.Success then
			removeFromMovesDisplay(handle, moveId)
			local currentDraft = peek(handle.Draft)
			if currentDraft and currentDraft.MoveId == moveId then
				handle.Draft:set(nil)
				handle.SavedFingerprint:set("")
			end
			handle.StatusText:set("Move deleted.")
		else
			handle.StatusText:set("Failed to delete move: " .. (result.Reason or "Unknown"))
		end
	end)

	-- Pushes `newDraft` to the server's live registry RIGHT NOW (no debounce) and reconciles the
	-- response -- the one thing both the debounced DraftFieldChanged path below and
	-- flushPendingDraftUpdate must do identically, so the two can never drift into disagreeing
	-- about what an UpdateDraft round trip looks like. Yields (InvokeServer) -- every caller here
	-- is a signal handler or another already-yielding function, so that's safe.
	local function sendDraftUpdateNow(newDraft: MoveTypes.MoveDefinition, isDefaultMove: boolean): ()
		local ok, resultOrError = pcall(function()
			if isDefaultMove then
				-- UpdateDefaultMoveDraft takes an explicit moveId (unlike UpdateDraft, which
				-- derives identity from the candidate itself server-side) -- see
				-- MoveEditorSystem.handleUpdateDefaultMoveDraft's own header.
				return updateDefaultMoveDraftRemote:InvokeServer(newDraft.MoveId, encodeDraftForWire(newDraft))
			end
			return updateDraftRemote:InvokeServer(encodeDraftForWire(newDraft))
		end)
		if not ok then
			return
		end
		local result = resultOrError :: MoveTypes.MoveEditorMoveResult
		if result.Success and result.Move then
			-- Only reconcile Draft if the admin hasn't since selected/created a DIFFERENT move.
			local currentDraft = peek(handle.Draft)
			if currentDraft and currentDraft.MoveId == result.Move.MoveId then
				handle.Draft:set(result.Move)
			end
			patchMovesDisplay(handle, result.Move)
		end
	end

	handle.DraftFieldChanged:Connect(function(newDraft: MoveTypes.MoveDefinition)
		draftUpdateGeneration += 1
		local myGeneration = draftUpdateGeneration
		pendingDraftSync = true
		-- Captured now (not re-read inside the delayed closure below) -- a Default move's Category
		-- never changes mid-edit, so this is safe, and it keeps the routing decision tied to the
		-- exact edit that triggered it.
		local isDefaultMove = newDraft.Category == MoveTypes.DefaultCategory
		task.delay(Config.DraftDebounceSeconds, function()
			if draftUpdateGeneration ~= myGeneration then
				-- A newer edit (or an explicit flushPendingDraftUpdate) already superseded this
				-- one -- that later call owns pendingDraftSync and the actual send; this stale
				-- attempt is dropped, not sent.
				return
			end
			pendingDraftSync = false
			sendDraftUpdateNow(newDraft, isDefaultMove)
		end)
	end)

	-- Cancels any still-pending debounced UpdateDraft and sends it RIGHT NOW instead, blocking
	-- until the server's live registry actually reflects the current Draft. Called from setOpen
	-- (every panel close) and directly from TestFireRequested below -- see pendingDraftSync's own
	-- header for the "edit a field, immediately Test on Dummy" race this exists to close: without
	-- it, TestFireMove/the hotbar's live-fire path read MoveRegistryManager's registry by moveId
	-- alone, trusting it already reflects the admin's last edit, which the debounce alone can't
	-- guarantee.
	function flushPendingDraftUpdate(): ()
		if not pendingDraftSync then
			return
		end
		draftUpdateGeneration += 1 -- invalidate the scheduled debounce call above
		pendingDraftSync = false
		local currentDraft = peek(handle.Draft)
		if not currentDraft then
			return
		end
		sendDraftUpdateNow(currentDraft, currentDraft.Category == MoveTypes.DefaultCategory)
	end

	-- Default-move-only: fires from PropertyEditor.lua's toolbar in place of SaveRequested (see that
	-- file's header) -- restores the current draft's live Constants values to their captured
	-- defaults, patching the result back into Draft/MovesDisplay exactly like a successful Save does.
	handle.ResetRequested:Connect(function()
		local currentDraft = peek(handle.Draft)
		if not currentDraft or currentDraft.Category ~= MoveTypes.DefaultCategory then
			return
		end
		local ok, resultOrError = pcall(function()
			return resetDefaultMoveRemote:InvokeServer(currentDraft.MoveId)
		end)
		if not ok then
			handle.StatusText:set("Failed to reset: request error")
			return
		end
		local result = resultOrError :: MoveTypes.MoveEditorMoveResult
		if result.Success and result.Move then
			handle.Draft:set(result.Move)
			handle.SavedFingerprint:set(MoveTypes.Fingerprint(result.Move))
			patchMovesDisplay(handle, result.Move)
			handle.StatusText:set("Reset to default.")
		else
			handle.StatusText:set("Failed to reset: " .. (result.Reason or "Unknown"))
		end
	end)

	handle.TestFireRequested:Connect(function()
		-- Belt-and-suspenders alongside setOpen's own flush below (which fires when this handler's
		-- own auto-close runs, a few lines down): guarantees the server's live registry reflects
		-- the CURRENT draft before TestFireMove ever reads it by moveId alone, regardless of
		-- whether IsOpen happened to already be false. See pendingDraftSync's own header.
		flushPendingDraftUpdate()

		local currentDraft = peek(handle.Draft)
		if not currentDraft or currentDraft.MoveId == "" then
			handle.LastTestResultText:set("Nothing to test yet.")
			return
		end

		pcall(function()
			spawnPreviewDummyRemote:InvokeServer()
		end)

		awaitingTestMoveId = currentDraft.MoveId
		testWindowStartedAt = os.clock()
		testWindowExpiresAt = testWindowStartedAt
			+ currentDraft.WindupSeconds
			+ currentDraft.ActiveSeconds
			+ currentDraft.RecoverySeconds
			+ TEST_WINDOW_TRAILING_SECONDS
		-- Reset per FIRE, not per Clear-button press: SummarizeSamples reports HitCount/TotalDamage
		-- over whatever it is given, so carrying the previous fire's hits forward would read as one
		-- move dealing double damage. The panel's Clear button exists to blank the readout without
		-- firing at all (e.g. after switching moves), not to separate one fire from the next.
		handle.TestSamples:set({})

		-- Auto-close the panel so it isn't covering the dummy the admin just asked to watch, then
		-- auto-reopen once the move has finished playing out -- see TEST_REOPEN_BUFFER_SECONDS and
		-- testReopenToken's own headers.
		if peek(handle.IsOpen) then
			setOpen(false)
			local thisReopenToken = testReopenToken
			local visibleDuration = currentDraft.WindupSeconds
				+ currentDraft.ActiveSeconds
				+ currentDraft.RecoverySeconds
			task.delay(math.max(visibleDuration, 0) + TEST_REOPEN_BUFFER_SECONDS, function()
				if testReopenToken == thisReopenToken then
					setOpen(true)
				end
			end)
		end

		local ok, resultOrError = pcall(function()
			return testFireMoveRemote:InvokeServer(currentDraft.MoveId)
		end)
		if not ok then
			awaitingTestMoveId = nil
			handle.LastTestResultText:set("Test failed: request error")
			return
		end
		local result = resultOrError :: MoveTypes.MoveEditorActionResult
		if not result.Success then
			awaitingTestMoveId = nil
			handle.LastTestResultText:set("Test failed: " .. (result.Reason or "Unknown"))
		end
		-- On success, the real result (damage/hit-confirmed) streams back over the existing
		-- Combat_FeedbackEvent listener below -- this handler's own job (accept the throw) is done.
	end)

	function requestSave()
		local currentDraft = peek(handle.Draft)
		if not currentDraft then
			return
		end
		-- A Default move's identity is fixed and its live values are already the single source of
		-- truth (UpdateDefaultMoveDraft already mutated them in place) -- SaveDefaultMove takes just
		-- the moveId and persists whatever is currently live, unlike SaveMove which needs the full
		-- candidate. See MoveEditorSystem.handleSaveDefaultMove's own header.
		local isDefaultMove = currentDraft.Category == MoveTypes.DefaultCategory
		local ok, resultOrError = pcall(function()
			if isDefaultMove then
				return saveDefaultMoveRemote:InvokeServer(currentDraft.MoveId)
			end
			return saveMoveRemote:InvokeServer(encodeDraftForWire(currentDraft))
		end)
		if not ok then
			handle.StatusText:set("Failed to save: request error")
			return
		end
		local result = resultOrError :: MoveTypes.MoveEditorMoveResult
		if result.Success and result.Move then
			handle.Draft:set(result.Move)
			handle.SavedFingerprint:set(MoveTypes.Fingerprint(result.Move))
			patchMovesDisplay(handle, result.Move)
			handle.StatusText:set("Saved.")
		else
			handle.StatusText:set("Failed to save: " .. (result.Reason or "Unknown"))
		end
	end
	handle.SaveRequested:Connect(requestSave)

	-- Duplicate. Needs NO server change and no new remote: stampTrustedMetadata mints a fresh MoveId
	-- whenever the submitted one is empty or unknown, and overwrites Author/CreatedAt from trusted
	-- server context regardless -- so blanking all four here and sending the result through the
	-- existing UpdateDraft is exactly the path "+ New Move" already takes, just seeded from a real
	-- move instead of defaultDraft().
	function requestDuplicate()
		local currentDraft = peek(handle.Draft)
		if not currentDraft then
			return
		end
		if currentDraft.Category == MoveTypes.DefaultCategory then
			-- A Default move's identity is a fixed synthetic MoveId backed by a live Constants table
			-- (DefaultMoveRegistry.lua) -- there is nothing to mint a second copy of, and a duplicate
			-- claiming the reserved Category would now be rejected by Validate anyway.
			handle.StatusText:set("Default moves can't be duplicated.")
			return
		end
		-- MoveTypes.Clone, never table.clone: a shallow copy would leave the duplicate's Knockback/
		-- ObjectStun/Animations aliasing the ORIGINAL's, so the first edit to the copy would silently
		-- corrupt the move it came from -- which is still sitting in MovesDisplay.
		local copy = MoveTypes.Clone(currentDraft)
		copy.MoveId = "" -- what makes stampTrustedMetadata mint a fresh one
		copy.Author = "" -- overwritten server-side; blanked here to state that intent
		copy.CreatedAt = 0
		copy.UpdatedAt = 0
		copy.DisplayName = currentDraft.DisplayName .. " Copy"

		local ok, resultOrError = pcall(function()
			return updateDraftRemote:InvokeServer(encodeDraftForWire(copy))
		end)
		if not ok then
			handle.StatusText:set("Failed to duplicate: request error")
			return
		end
		local result = resultOrError :: MoveTypes.MoveEditorMoveResult
		if result.Success and result.Move then
			handle.Draft:set(result.Move)
			handle.SavedFingerprint:set(MoveTypes.Fingerprint(result.Move))
			patchMovesDisplay(handle, result.Move)
			-- Says "Save to persist" deliberately: the duplicate exists in the server's in-memory
			-- registry and is immediately test-fireable, but nothing has reached the DataStore yet.
			handle.StatusText:set("Duplicated -- Save to persist.")
		else
			handle.StatusText:set("Failed to duplicate: " .. (result.Reason or "Unknown"))
		end
	end
	handle.DuplicateMoveRequested:Connect(requestDuplicate)

	-- Client-only bookkeeping, no RemoteFunction involved -- see MoveEditor/Types.lua's own header
	-- on this signal. Toggles: binding the SAME move that's already on this slot clears it instead
	-- of re-binding it, the only way the UI offers to free a slot (HotbarBindings.Clear exists for
	-- exactly this).
	handle.BindHotbarSlotRequested:Connect(function(slot: number, moveId: string)
		if HotbarBindings.Get(slot) == moveId then
			HotbarBindings.Clear(slot)
			handle.StatusText:set(`Cleared hotbar slot {slot}.`)
		else
			HotbarBindings.Set(slot, moveId)
			handle.StatusText:set(`Bound to hotbar slot {slot}.`)
		end
	end)

	-- Test-fire results -- reuses the existing Combat_FeedbackEvent/Combat_AttackStarted remotes
	-- (already wired to every player, CombatClient.lua) rather than a new one. Filtered to the move
	-- currently awaiting a result via AttackDebugName == MoveId (ThrowCustomMove's DebugName is
	-- always the thrown move's own MoveId -- see MoveTypes.ToHitboxAttackDefinition).
	local feedbackEvent = NetworkBridge.GetRemoteEvent(CombatRemoteNames.FeedbackEvent)
	feedbackEvent.OnClientEvent:Connect(function(payload: Types.CombatFeedbackPayload)
		if not awaitingTestMoveId or payload.AttackDebugName ~= awaitingTestMoveId then
			return
		end
		-- Checked here rather than on a timer: nothing needs to happen AT the moment the window
		-- closes, so a payload arriving late is simply the thing that discovers it has, and the
		-- session needs no scheduled work of its own to keep this state honest.
		local now = os.clock()
		if now > testWindowExpiresAt then
			awaitingTestMoveId = nil
			return
		end

		local damage = payload.DamageAmount or 0
		local posture = payload.PostureAmount or 0

		-- Appended to a FRESH array, never mutated in place -- Fusion.Value only republishes on
		-- :set(), so growing the existing table would leave every reader on a stale render.
		local recorded: MoveStats.TestSample = {
			TimeSeconds = math.max(now - testWindowStartedAt, 0),
			Damage = damage,
			PostureDamage = posture,
			Kind = payload.Kind,
		}
		local samples = table.clone(peek(handle.TestSamples))
		table.insert(samples, recorded)
		handle.TestSamples:set(samples)

		-- Reports the RUNNING total, not just this payload: with a multi-hit move the single-line
		-- readout would otherwise flicker through each hit and settle on whichever landed last, which
		-- reads as the move dealing only that much.
		local hitCount = 0
		local totalDamage = 0
		for _, sample in ipairs(samples) do
			if sample.Kind == "Hit" then
				hitCount += 1
				totalDamage += sample.Damage
			end
		end

		if payload.Kind == "Hit" then
			local hitLabel = if hitCount == 1 then "hit" else "hits"
			handle.LastTestResultText:set(
				`Last test: {hitCount} {hitLabel}, {totalDamage} damage, {posture} posture on the last hit.`
			)
		elseif payload.Kind == "Blocked" then
			handle.LastTestResultText:set("Last test: blocked.")
		elseif payload.Kind == "PostureBreak" then
			handle.LastTestResultText:set("Last test: posture break.")
		else
			handle.LastTestResultText:set(`Last test: {payload.Kind}.`)
		end
	end)
end

-- Runs on a delay (task.spawn), same reasoning as DevMenuClient.Start: this is called synchronously
-- partway through Main.client.lua's boot sequence, and the authorization round trip yields.
function MoveEditorClient.Start(handle: MoveEditorHandle): ()
	task.spawn(function()
		local authorized, initialMoves = requestServerAuthorization()
		if not authorized then
			logger:debug("MoveEditorClient not started: server did not authorize this client")
			return
		end
		-- MovesDisplay is the UNION of custom (ListMoves, just fetched above) and Default
		-- (ListDefaultMoves) moves -- MoveList.lua's Default/Custom tabs filter this one merged array
		-- rather than the client juggling two separate lists. See this file's own header.
		local merged = table.clone(initialMoves or {})
		for _, move in ipairs(fetchDefaultMoves()) do
			table.insert(merged, move)
		end
		startMoveEditor(handle, merged)
	end)
end

return MoveEditorClient
