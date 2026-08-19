--!strict
--[[
	MoveEditorClient.lua

	Owns: the local admin's Move Editor UX -- keybind toggle (OpenMoveEditor, resolved through
	Client/Input/KeybindManager.lua, same as DevMenuClient.lua's DevMenuToggle), the authorization
	round trip, and translating the MoveEditor screen's New/Select/Delete/DraftFieldChanged/
	Save/Reset signals into Constants.MoveEditor.RemoteNames RemoteFunction calls. Holds no
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

	"TEST ON DUMMY" IS REAL AGAIN (2026-08-19, the Move Editor repair pass) -- rebuilt against the NEW
	4-layer combat stack (HitboxEngine -> DefenseSystem -> DamageSystem -> AttackRequestSystem) rather
	than revived as it was. The old TestFireMove/SpawnPreviewDummy remotes and Combat_FeedbackEvent are
	still gone -- CombatSystem.lua, their only creator, is gone with them -- but nothing needed to be
	rebuilt in their shape, because the pieces that survived the rewrite already cover the same ground:

	  * FIRING was never actually broken. AttackRequestSystem.resolveRequest's admin-trusted Hotbar
	    branch (`authorized == true`) still lets an admin bind ANY known move (AttackCatalog.Has) to a
	    hotbar slot and throw it for real -- see this file's own BindHotbarSlotRequested wiring below,
	    which was already live before this pass touched anything. What that swing needed was a target
	    and a way to hear back what happened to it, not a new way to throw it.
	  * THE TARGET is Server/Systems/DebugDummySystem.lua's training dummy (the DevMenu "Spawn" tab's
	    own tool) -- a real HitboxEngine/DefenseSystem combatant, not a Move-Editor-owned duplicate. The
	    toolbar's "Spawn Dummy"/"Despawn Dummy" button (handle.ToggleTestDummyRequested, handled below)
	    reuses DevMenuSystem's own DevMenu_SpawnDummy/DevMenu_DespawnAllDebugDummies remotes directly --
	    no new server code, per this codebase's own "search before duplicating" rule.
	  * THE FEEDBACK is DamageSystem's own Combat_Feedback event -- the same one
	    Client/Combat/CombatFeedbackClient.lua already subscribes to for hit-stop/shake/damage-number FX.
	    This module adds a second, independent subscriber (see onCombatFeedback below): filtered to
	    Role == "Attacker" and MoveId == the currently selected Draft's MoveId, each matching payload
	    becomes one MoveStats.TestSample appended to handle.TestSamples, timed from the most recent
	    matching Attack_Started this module observed via AttackInputClient.OnAttackStarted (t = 0 for
	    that swing). GuardDrain stands in for PostureDamage in that sample -- CombatFeedback never
	    carries the resolved DamageResult's own PostureDamage field, and GuardDrain (DamageConstants.
	    Guard's own "guard IS the posture pool" -- see that constant's header) is the closest real number
	    the client is actually told.

	Does not own: whether a request is actually allowed (MoveEditorSystem.lua re-checks
	server-side regardless), or the editor panel itself (UI/Screens/MoveEditor/init.lua) -- this
	module only drives that screen's handle from outside, the same "screen exposes state/signals,
	client module drives from outside" pattern DevMenuClient.lua already uses.

	Also mirrors Client/Combat/HotbarBindings.lua into handle.HotbarBindings and routes
	handle.BindHotbarSlotRequested into it (2026-08-10, the Move Creation System hotbar pass) --
	see this file's own wiring in startMoveEditor and HotbarBindings.lua's own header. Unlike every
	remote-backed signal above, this one never touches NetworkBridge -- binding a move to a hotbar
	slot is pure client-side bookkeeping; only firing the bound move round-trips to the server
	(Client/Combat/AttackInputClient.lua -- the same module every OTHER player's own hotbar press
	already goes through; this feature's actual live-fire path runs independently of whether the Move
	Editor screen is even open).
]]

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Lazy = require(ReplicatedStorage.Shared.Lazy)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local Constants = require(ReplicatedStorage.Shared.Constants)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local MoveStats = require(ReplicatedStorage.Shared.MoveStats)
local AttackTypes = require(ReplicatedStorage.Shared.Attack.AttackTypes)
local DamageConstants = require(ReplicatedStorage.Shared.Damage.DamageConstants)
local DamageTypes = require(ReplicatedStorage.Shared.Damage.DamageTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)

local MoveEditorModule = require(script.Parent.Parent.UI.Screens.MoveEditor)
local KeybindManager = require(script.Parent.Parent.Input.KeybindManager)
local HotbarBindings = require(script.Parent.Parent.Combat.HotbarBindings)
local AttackInputClient = require(script.Parent.Parent.Combat.AttackInputClient)
local RemoteInvoker = require(script.Parent.Parent.Network.RemoteInvoker)

type MoveEditorHandle = MoveEditorModule.MoveEditorHandle

local peek = Fusion.peek

local logger = Logger.scope("MoveEditorClient")

local Config = Constants.MoveEditor

local MoveEditorClient = {}

-- Guards a debounced UpdateDraft response against clobbering a newer edit that landed while the
-- old one was still in flight -- same idiom as DevMenuClient.lua's own statusGeneration.
local draftUpdateGeneration = 0

-- True from the moment a field edit schedules a debounced UpdateDraft until that exact call
-- either lands or is superseded/flushed -- see flushPendingDraftUpdate's own header below for why
-- this exists. Without it, a hotbar press that follows once the panel closes (Client/Combat/
-- AttackInputClient.lua's live-fire path, which reads MoveRegistryManager's registry by moveId alone)
-- can beat the debounced UpdateDraft the most recent field edit scheduled to the server:
-- Config.DraftDebounceSeconds (150ms) plus the RemoteFunction round trip on top of it is easily beaten
-- by the completely ordinary "edit a field, immediately close the panel" cadence, which would leave
-- the live registry holding the move's PREVIOUS geometry instead of what the editor's own (purely
-- client-local, zero-round-trip) PreviewViewport gizmo was already showing.
local pendingDraftSync = false

-- Forward-declared (same pattern as requestSave/requestDuplicate further down): setOpen needs to
-- call this on every close, but its real definition lives alongside DraftFieldChanged's own
-- handler further down, where sendDraftUpdateNow (which it shares) is defined.
local flushPendingDraftUpdate: () -> ()

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

-- Test-fire feedback ---------------------------------------------------------------------------------

-- The moment (os.clock()) this client last observed an Attack_Started for a HOTBAR throw of whatever
-- move is CURRENTLY selected in the editor -- t = 0 for the TestSample(s) that throw's own
-- Combat_Feedback event(s) get timed against. nil until a matching throw has actually been observed
-- this session; a Combat_Feedback that arrives with no known throw start (the admin fighting something
-- unrelated to the editor's own test-fire flow, or a follow-up landing after the editor has since
-- selected a different move) is simply not recorded -- see onCombatFeedback below.
local lastTestThrowAt: number? = nil

-- AttackInputClient.OnAttackStarted fires for every server-confirmed throw this client makes, not just
-- hotbar ones -- narrowed to Hotbar AND a MoveId matching the CURRENTLY selected draft, so an ordinary
-- Basic/Heavy swing thrown while the editor happens to be open (or a hotbar press of some OTHER bound
-- move) never resets the test-fire clock a real test wasn't waiting on.
local function onTestAttackStarted(handle: MoveEditorHandle, payload: AttackTypes.AttackStartedPayload): ()
	if payload.Kind ~= "Hotbar" then
		return
	end
	local draft = peek(handle.Draft)
	if not draft or draft.MoveId ~= payload.MoveId then
		return
	end
	lastTestThrowAt = os.clock()
end

-- Combat_Feedback fires to BOTH participants of every resolved contact server-wide (DamageSystem's own
-- header) -- this is a SECOND, independent subscriber alongside Client/Combat/CombatFeedbackClient.lua's
-- FX one, filtered down to exactly the hits this editor's own test-fire flow produced: this client was
-- the attacker, and the move that landed is the one currently open in the editor. Everything else
-- (ordinary combat elsewhere on the server, a hit on some other admin's own dummy) is silently ignored.
--
-- GuardDrain stands in for MoveStats.TestSample.PostureDamage -- CombatFeedback never carries the
-- resolved DamageResult's own PostureDamage (DamageSystem.applyOutcome's own feedback table only ever
-- sends Damage/GuardDrain, see DamageTypes.CombatFeedback), and GuardDrain (DamageConstants.Guard's own
-- "guard IS the posture pool") is the closest real number this client is actually told -- an honest
-- approximation, not the exact authored PostureDamage a Blocked/GuardBroken contact would otherwise
-- already have priced through DefenseSystem's own guard pool instead.
local function onCombatFeedback(handle: MoveEditorHandle, raw: unknown): ()
	if typeof(raw) ~= "table" then
		return
	end
	local payload = raw :: DamageTypes.CombatFeedback
	if payload.Role ~= "Attacker" then
		return
	end
	local draft = peek(handle.Draft)
	if not draft or draft.MoveId ~= payload.MoveId then
		return
	end
	local throwAt = lastTestThrowAt
	if not throwAt then
		-- This move landed a hit without this client ever observing a matching test-fire throw --
		-- most likely a Basic/Heavy weapon-string hit that happens to share a MoveId format, or a
		-- follow-up from before the editor was opened. Nothing honest to time it against.
		return
	end

	local sample: MoveStats.TestSample = {
		TimeSeconds = math.max(os.clock() - throwAt, 0),
		Damage = payload.Damage,
		PostureDamage = payload.GuardDrain,
		Kind = payload.Kind,
	}
	local updated = table.clone(peek(handle.TestSamples))
	table.insert(updated, sample)
	handle.TestSamples:set(updated)

	handle.LastTestResultText:set(
		string.format("Last test: %s -- %.0f dmg, %.0f posture", payload.Kind, payload.Damage, payload.GuardDrain)
	)
end

-- Describes a DevMenuSystem-shaped {Success, Reason?} result for the toolbar's toggling Spawn/Despawn
-- Dummy button -- same "invoke -> describe -> setStatus" shape RemoteInvoker.InvokeAndReport already
-- codifies, reused here rather than hand-rolled.
local function describeDummyToggleResult(actionText: string, resultOrError: unknown): string
	local result = resultOrError :: { Success: boolean, Reason: string? }
	if typeof(result) == "table" and result.Success then
		return actionText .. "."
	end
	local reason = if typeof(result) == "table" then result.Reason else nil
	return "Failed: " .. actionText .. " (" .. (reason or "Unknown") .. ")"
end

local function startMoveEditor(handle: MoveEditorHandle, initialMoves: { MoveTypes.MoveDefinition }): ()
	logger:info("MoveEditorClient started")
	handle.MovesDisplay:set(initialMoves)

	local getMoveRemote = NetworkBridge.GetRemoteFunction(Config.RemoteNames.GetMove)
	local updateDraftRemote = NetworkBridge.GetRemoteFunction(Config.RemoteNames.UpdateDraft)
	local saveMoveRemote = NetworkBridge.GetRemoteFunction(Config.RemoteNames.SaveMove)
	local deleteMoveRemote = NetworkBridge.GetRemoteFunction(Config.RemoteNames.DeleteMove)
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

	-- Test-fire feedback -- see this file's own header and onTestAttackStarted/onCombatFeedback's own
	-- headers above. Both subscriptions run for the life of the session, same as HotbarBindings.OnChanged
	-- immediately above -- there is nothing move-editor-specific about the underlying remotes that would
	-- make either safe to only listen to while the editor screen is open.
	AttackInputClient.OnAttackStarted(function(payload: AttackTypes.AttackStartedPayload)
		onTestAttackStarted(handle, payload)
	end)
	NetworkBridge.GetRemoteEvent(DamageConstants.Network.RemoteNames.Feedback).OnClientEvent
		:Connect(function(raw: unknown)
			onCombatFeedback(handle, raw)
		end)

	-- The ONE place IsOpen is ever written client-side (the keybind toggle and the screen's own "X"
	-- button both route through this) -- keeps the server-side freeze/unfreeze
	-- (AdminActionSystem.SetFrozen via MoveEditorSystem's SetEditorOpen handler) in lockstep with
	-- every open/close transition, not just the keybind one. Editing a move's numbers shouldn't leave
	-- the admin's own character free to walk/attack mid-edit.
	local function setOpen(open: boolean): ()
		if not open then
			-- Closing the panel is the moment every downstream consumer of the LIVE registry (a
			-- hotbar press, once the panel is gone) can next read it -- flush any edit still sitting
			-- inside the debounce window now, so that read sees the admin's actual last edit rather
			-- than whatever the server still had. See pendingDraftSync's own header for the race this
			-- closes.
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
		-- Samples belong to the move that produced them, so switching moves drops them -- otherwise
		-- the Stats panel would keep showing the PREVIOUS move's samples under the newly selected
		-- move's name, which is worse than showing none. onCombatFeedback's own MoveId check would
		-- already stop new samples from landing under the wrong move, but old ones already in the
		-- array need clearing explicitly.
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
	-- (every panel close) -- see pendingDraftSync's own header for the race this exists to close:
	-- without it, the hotbar's live-fire path reads MoveRegistryManager's registry by moveId alone,
	-- trusting it already reflects the admin's last edit, which the debounce alone can't guarantee.
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

	-- Reuses DevMenuSystem's own DevMenu_SpawnDummy/DevMenu_DespawnAllDebugDummies remotes
	-- (Server/Systems/DebugDummySystem.lua) -- see this file's own header on why the Move Editor never
	-- grows a second dummy implementation. handle.HasTestDummy is this client's own optimistic guess
	-- (flipped only on a Success response), not polled from the server -- see that field's own header
	-- in MoveEditor/Types.lua on why a wrong guess here is harmless.
	handle.ToggleTestDummyRequested:Connect(function()
		local spawning = not peek(handle.HasTestDummy)
		local remote = NetworkBridge.GetRemoteFunction(
			if spawning
				then Constants.Debug.DevMenu.RemoteNames.SpawnDummy
				else Constants.Debug.DevMenu.RemoteNames.DespawnAllDebugDummies
		)
		RemoteInvoker.InvokeAndReport(
			function(status: string)
				handle.StatusText:set(status)
			end,
			remote,
			{},
			function(resultOrError: unknown)
				local result = resultOrError :: { Success: boolean, Reason: string? }
				if typeof(result) == "table" and result.Success then
					handle.HasTestDummy:set(spawning)
				end
				return describeDummyToggleResult(
					if spawning then "Spawned test dummy" else "Despawned test dummy",
					result
				)
			end
		)
	end)

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
end

-- Runs on a delay (task.spawn), same reasoning as DevMenuClient.Start: this is called synchronously
-- partway through Main.client.lua's boot sequence, and the authorization round trip yields.
--
-- TAKES A Shared/Lazy.lua THUNK, same as DevMenuClient.Start and for the same reason -- this is the
-- BIGGEST of the three deferred admin panels at ~143 Instances, and UI.Mount() used to build all of
-- them on the boot path for every player. Forced only once the server has said yes AND both move
-- lists are in hand, so the panel is mounted with real data rather than mounted empty and then filled.
function MoveEditorClient.Start(deferredHandle: Lazy.Lazy<MoveEditorHandle>): ()
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
		startMoveEditor(deferredHandle.Get(), merged)
	end)
end

return MoveEditorClient
