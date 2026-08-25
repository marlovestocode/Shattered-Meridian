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
	That pending edit is tracked PER MOVE (pendingDraftByMoveId below), not as one shared slot, and a
	per-move send sequence guards a stale, superseded response from clobbering a newer edit that landed
	while the old one was still in flight. Both replaced a single module-level generation counter that
	silently dropped an edit whenever the admin switched moves inside the debounce window, and let a
	late edit resurrect a just-deleted move -- see pendingDraftByMoveId's own header for both.

	"TEST ON DUMMY" IS REAL AGAIN (2026-08-19, the Move Editor repair pass) -- rebuilt against the NEW
	4-layer combat stack (HitboxEngine -> DefenseSystem -> DamageSystem -> AttackRequestSystem) rather
	than revived as it was. The old TestFireMove/SpawnPreviewDummy remotes and Combat_FeedbackEvent are
	still gone -- CombatSystem.lua, their only creator, is gone with them -- but nothing needed to be
	rebuilt in their shape, because the pieces that survived the rewrite already cover the same ground:

	  * FIRING was never actually broken. AttackRequestSystem.resolveRequest's Hotbar case resolves
	    every press -- admin or not -- against ArtSystem.GetEquipped and throws it for real; see this
	    file's own BindHotbarSlotRequested wiring below, which was already live before this pass
	    touched anything (it originally routed through a trusted arbitrary-MoveId branch that let an
	    admin bind ANY known move; that branch is gone -- see ArtSystem.lua's own header -- and binding
	    now equips a real, persisted Art through ArtSystem.DevGrantAndEquip instead). What that swing
	    needed was a target and a way to hear back what happened to it, not a new way to throw it.
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

	Also mirrors Client/Combat/HotbarBindings.lua into handle.HotbarBindings for PropertyEditor.lua's
	toolbar to read, and routes handle.BindHotbarSlotRequested into Constants.MoveEditor.RemoteNames.
	EquipArtSlot (2026-08-10, the Move Creation System hotbar pass; rewired 2026-08-19 when
	HotbarBindings stopped being a second, writable slot map -- see that module's own header and
	ArtSystem.lua's on why) -- see this file's own wiring in startMoveEditor. Binding to a slot IS an
	equip now (ArtSystem.DevGrantAndEquip server-side), so unlike the client-only bookkeeping this
	used to be, it round-trips like every other remote-backed signal above; only firing the bound art
	still goes through a separate path (Client/Combat/AttackInputClient.lua -- the same module every
	OTHER player's own hotbar press already goes through; that live-fire path runs independently of
	whether the Move Editor screen is even open).
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
-- The screen's own prose module, reached the same way the screen itself is. Nothing else on this
-- side of the boundary reads it -- this file needs exactly one thing from it, Copy.Failure, which
-- turns a server reason code into something an admin can read and act on.
local Copy = require(script.Parent.Parent.UI.Screens.MoveEditor.Copy)
local KeybindManager = require(script.Parent.Parent.Input.KeybindManager)
local HotbarBindings = require(script.Parent.Parent.Combat.HotbarBindings)
local AttackInputClient = require(script.Parent.Parent.Combat.AttackInputClient)
local RemoteInvoker = require(script.Parent.Parent.Network.RemoteInvoker)
local MoveEditState = require(script.Parent.MoveEditState)
local Chrome = require(script.Parent.Parent.UI.Shell.Chrome)

type MoveEditorHandle = MoveEditorModule.MoveEditorHandle

local peek = Fusion.peek

local logger = Logger.scope("MoveEditorClient")

local Config = Constants.MoveEditor

local MoveEditorClient = {}

-- The edit for one move that is scheduled but has not been sent yet -- one entry per MoveId, live
-- only between a field edit and the end of its Config.DraftDebounceSeconds window.
--
-- WHY THIS EXISTS AT ALL. A hotbar press that follows once the panel closes (Client/Combat/
-- AttackInputClient.lua's live-fire path, which reads MoveRegistryManager's registry by moveId alone)
-- can beat the debounced UpdateDraft the most recent field edit scheduled to the server:
-- Config.DraftDebounceSeconds (150ms) plus the RemoteFunction round trip on top of it is easily beaten
-- by the completely ordinary "edit a field, immediately close the panel" cadence, which would leave
-- the live registry holding the move's PREVIOUS geometry instead of what the editor's own (purely
-- client-local, zero-round-trip) PreviewViewport gizmo was already showing. flushPendingDraftUpdates
-- below is what closes that.
--
-- WHY PER-MOVE, and not the single module-level generation counter plus `pendingDraftSync` boolean
-- this replaced -- two real bugs, both silent:
--   * Editing move A and then selecting move B INSIDE the debounce window bumped the one shared
--     counter, so A's scheduled send saw a generation mismatch and dropped itself. No error, no
--     status line, and the UNSAVED chip had already been reconciled away -- the edit was simply gone.
--   * Delete never flushed OR cancelled, so a debounced edit landing after the delete completed
--     reached MoveEditorSystem.stampTrustedMetadata with a MoveId the registry no longer knew. That
--     takes its "unknown move" branch and MINTS A FRESH MoveId -- resurrecting the move that was
--     just deleted, under a new identity. See cancelPendingDraftUpdate below.
--
-- Entry IDENTITY is what a scheduled task.delay closure checks (task.delay has no cancel), rather
-- than a per-move generation number: the closure captured its own entry table, so "is the entry
-- still mine?" is one comparison and needs no second map to hold the counters.
type PendingDraftUpdate = {
	Draft: MoveTypes.MoveDefinition,
	-- Captured at schedule time rather than re-read at send time -- a move's Category never changes
	-- mid-edit, and this keeps the routing decision tied to the exact edit that triggered it.
	IsDefaultMove: boolean,
}
local pendingDraftByMoveId: { [string]: PendingDraftUpdate } = {}

-- Monotonic per move, bumped on every send. sendDraftUpdateNow reconciles a response into Draft only
-- when nothing newer has been sent for that move since -- otherwise a slow earlier round trip landing
-- last overwrites the admin's newer edit with older server state. The generation counter this
-- replaced claimed to do exactly this in its own header but only ever guarded SCHEDULING, never the
-- response, so the case it described was never actually covered.
local draftSendSequenceByMoveId: { [string]: number } = {}

-- Undo/redo history, undo baselines, and which moves have unsaved work -- all per-MoveId, all
-- owned by MoveEditState.lua rather than by four parallel maps here. See that module's header for
-- why the state is shaped the way it is; it lives there because it is a small state machine whose
-- failures are silent, and separating it from every Fusion Value and remote in this file is what
-- makes it testable without a mounted screen.
local editState = MoveEditState.New()

-- How long a just-saved move's row keeps its green outline. Long enough to be seen if the eye was
-- elsewhere when Save landed, short enough that two saves in a row read as two separate events.
local SAVED_FLASH_SECONDS = 1.5

-- Forward-declared (same pattern as requestSave/requestDuplicate further down): setOpen and the
-- navigate-away handlers need to call these, but their real definitions live alongside
-- DraftFieldChanged's own handler further down, where sendDraftUpdateNow (which they all share) is
-- defined.
local flushPendingDraftUpdates: () -> ()
local flushPendingDraftUpdateFor: (moveId: string) -> ()
local flushCurrentDraft: () -> ()
local cancelPendingDraftUpdate: (moveId: string) -> ()

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
		Description = "",
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

-- The client's own view of a move that is NOT the open draft. Safe to edit from (after a clone):
-- MovesDisplay is patched in place on every successful UpdateDraft/Save/Reset reconcile, so an
-- entry here is as current as the server's live registry was at the last round trip.
local function findInMovesDisplay(handle: MoveEditorHandle, moveId: string): MoveTypes.MoveDefinition?
	for _, move in ipairs(peek(handle.MovesDisplay)) do
		if move.MoveId == moveId then
			return move
		end
	end
	return nil
end

local function countCustomMoves(handle: MoveEditorHandle): number
	local total = 0
	for _, move in ipairs(peek(handle.MovesDisplay)) do
		if move.Category ~= MoveTypes.DefaultCategory then
			total += 1
		end
	end
	return total
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

-- Mirrors editState's own count onto the handle, which is what the title bar reads. Called after
-- every operation that can change it rather than recomputed reactively: editState is plain tables
-- with no change signal of its own, deliberately (see its header).
local function publishUnsavedCount(handle: MoveEditorHandle): ()
	handle.UnsavedCount:set(editState:UnsavedCount())
end

-- The green row outline, cleared on a timer here rather than by the row itself -- see
-- MoveEditorHandle.LastSavedMoveId. Guarded on the id still being the one this call set, so a
-- second save inside the window restarts the flash rather than having the first one's timer cut
-- the second one short.
local function flashSaved(handle: MoveEditorHandle, moveId: string): ()
	handle.LastSavedMoveId:set(moveId)
	task.delay(SAVED_FLASH_SECONDS, function()
		if peek(handle.LastSavedMoveId) == moveId then
			handle.LastSavedMoveId:set("")
		end
	end)
end

-- The one place a rejected request becomes something on screen. Sets the status line to
-- Copy.Failures' plain sentence for that code and, when the code names an authoring section,
-- JUMPS the nav to it.
--
-- Jumping matters more than the wording does. A Save validates the whole record at once, so the
-- section that failed is very often not the one the admin is looking at -- "Failed to save:
-- InvalidShapeField" left them to work out both which field and which of thirteen sections it
-- lives in. Nothing else about the draft changes: this only moves the view.
local function reportFailure(handle: MoveEditorHandle, action: string, reason: string?): ()
	local failure = Copy.Failure(reason)
	handle.StatusText:set(`{action}: {failure.Message}`)
	if failure.Section then
		handle.SelectedSection:set(failure.Section)
	end
end

local function startMoveEditor(
	handle: MoveEditorHandle,
	chrome: Chrome.ChromeHandle,
	initialMoves: { MoveTypes.MoveDefinition }
): ()
	logger:info("MoveEditorClient started")
	handle.MovesDisplay:set(initialMoves)

	-- EVERY write to Draft from this module goes through here, and that is the point: the undo
	-- baseline has to be whatever was last actually on screen for that move, and Draft is set from
	-- seven different places (a fresh load, a cached Default move, a save, a reset, a duplicate, a
	-- debounced reconcile, an undo). Missing one of them fails SILENTLY -- history keeps working and
	-- just restores a state that was never displayed -- so there is deliberately no second way to do
	-- it. The screen's own optimistic write (init.lua's OnFieldChanged) is the one exception, and it
	-- is covered instead by DraftFieldChanged, which fires immediately after it.
	local function setOpenDraft(move: MoveTypes.MoveDefinition): ()
		handle.Draft:set(move)
		editState:SetBaseline(move.MoveId, move)
	end

	local getMoveRemote = NetworkBridge.GetRemoteFunction(Config.RemoteNames.GetMove)
	local updateDraftRemote = NetworkBridge.GetRemoteFunction(Config.RemoteNames.UpdateDraft)
	local saveMoveRemote = NetworkBridge.GetRemoteFunction(Config.RemoteNames.SaveMove)
	local deleteMoveRemote = NetworkBridge.GetRemoteFunction(Config.RemoteNames.DeleteMove)
	local updateDefaultMoveDraftRemote = NetworkBridge.GetRemoteFunction(Config.RemoteNames.UpdateDefaultMoveDraft)
	local saveDefaultMoveRemote = NetworkBridge.GetRemoteFunction(Config.RemoteNames.SaveDefaultMove)
	local resetDefaultMoveRemote = NetworkBridge.GetRemoteFunction(Config.RemoteNames.ResetDefaultMove)
	local setEditorOpenRemote = NetworkBridge.GetRemoteEvent(Config.RemoteNames.SetEditorOpen)
	local equipArtSlotRemote = NetworkBridge.GetRemoteFunction(Config.RemoteNames.EquipArtSlot)

	-- Live-mirrors Client/Combat/HotbarBindings.lua into handle.HotbarBindings for
	-- PropertyEditor.lua's toolbar to read reactively -- see that module's own header on why it's a
	-- plain Luau module rather than a Fusion.Value itself, and MoveEditor/Types.lua's own header on
	-- this field. HotbarBindings itself is now a read-only mirror of the server's equippedArts
	-- (CharacterMenuClient.lua's own writer) -- this is a second, read-side mirror one level up,
	-- never a write path. Seeded immediately (the server may have pushed Art_StateUpdated before
	-- this screen ever mounted) and never unsubscribed -- this client module runs for the life of
	-- the session, same lifetime as every other listener it sets up below.
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
			-- than whatever the server still had. See pendingDraftByMoveId's own header for the race
			-- this closes. EVERY pending move, not just the selected one: the admin may have edited A,
			-- switched to B, then closed -- A's edit still has to reach the live registry.
			flushPendingDraftUpdates()
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

	-- Escape backs out of ONE thing at a time, outermost first, rather than always meaning "close
	-- the editor". Without the layering, dismissing the shortcut list also closed the editor
	-- underneath it -- and after a first press armed the unsaved-changes confirmation, a second
	-- press meant to cancel that confirmation was instead read as accepting it, discarding the work
	-- it was there to protect.
	--
	-- A NumericField's own typed entry is a further layer that is deliberately NOT handled here: the
	-- half-typed text is that component's private state, invisible from outside it, so Escape while
	-- a field has focus is cancelled inside NumericField.lua. Shell/Chrome.lua now also declines
	-- Escape outright while any TextBox has focus, so that field never has to race this.
	--
	-- THE LAYERING IS THE STACK'S NOW, NOT AN if-CHAIN'S. The two layers above are two entries on
	-- Shell/Chrome.lua's Escape stack -- the editor pushed while it is open, the shortcuts overlay
	-- pushed on top of it while F1 has it up -- so "outermost first" falls out of the stack's own
	-- ordering rather than out of the order of branches in one function. Each entry still owns
	-- exactly the behaviour it always did.
	--
	-- The unsaved-changes arm stays inside the editor's OWN entry rather than becoming a third push,
	-- and that is deliberate: an arm is not a surface the player can see and back out of, it is a
	-- state of the close itself. See requestClose above for why it is a deadline and not a widget.
	chrome:BindEscape("MoveEditor", handle.IsOpen, function()
		if os.clock() <= closeArmedUntil then
			closeArmedUntil = 0
			handle.StatusText:set("Close cancelled.")
			return
		end
		requestClose()
	end)
	chrome:BindEscape("MoveEditorShortcuts", handle.ShortcutsOpen, function()
		handle.ShortcutsOpen:set(false)
	end)

	-- Extracted so the keyboard shortcuts below can invoke the exact same behaviour the toolbar
	-- buttons do. The screen owns those BindableEvents and this module can only connect to them, not
	-- fire them -- so the handler bodies live here as locals and both callers share them, rather than
	-- MoveEditorHandle growing a set of raw BindableEvents purely to satisfy a keybind.
	local requestSave: () -> ()
	local requestDuplicate: (moveId: string?) -> ()
	local requestUndo: () -> ()
	local requestRedo: () -> ()

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
		if input.KeyCode == Enum.KeyCode.F1 then
			handle.ShortcutsOpen:set(not peek(handle.ShortcutsOpen))
		elseif input.KeyCode == Enum.KeyCode.S and isModifierDown() then
			requestSave()
		elseif input.KeyCode == Enum.KeyCode.D and isModifierDown() then
			requestDuplicate()
		elseif input.KeyCode == Enum.KeyCode.Z and isModifierDown() then
			-- Ctrl+Shift+Z is redo everywhere else, so it is redo here -- an admin who reaches for it
			-- out of habit should not silently undo one more step instead.
			if
				UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
				or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
			then
				requestRedo()
			else
				requestUndo()
			end
		elseif input.KeyCode == Enum.KeyCode.Y and isModifierDown() then
			requestRedo()
		end
	end)

	handle.CloseRequested:Connect(requestClose)

	handle.NewMoveRequested:Connect(function()
		-- Draft is about to be replaced by the new move, so an edit still sitting inside the current
		-- one's debounce window has to land first or it is silently dropped -- see flushCurrentDraft.
		flushCurrentDraft()
		local ok, resultOrError = pcall(function()
			return updateDraftRemote:InvokeServer(encodeDraftForWire(defaultDraft()))
		end)
		if not ok then
			handle.StatusText:set("Failed to create move: request error")
			return
		end
		local result = resultOrError :: MoveTypes.MoveEditorMoveResult
		if result.Success and result.Move then
			setOpenDraft(result.Move)
			handle.SavedFingerprint:set(MoveTypes.Fingerprint(result.Move))
			patchMovesDisplay(handle, result.Move)
			handle.StatusText:set("New move created.")
		else
			reportFailure(handle, "Could not create move", result.Reason)
		end
	end)

	handle.SelectMoveRequested:Connect(function(moveId: string)
		-- Flush FIRST, before anything about the outgoing move is discarded: clicking a different row
		-- inside the 150ms debounce window used to drop that edit outright -- see flushCurrentDraft.
		-- Selecting the already-open move flushes it too, which is harmless (one extra round trip that
		-- sends exactly what the debounce was about to send anyway).
		flushCurrentDraft()

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
				setOpenDraft(move)
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
			setOpenDraft(result.Move)
			handle.SavedFingerprint:set(MoveTypes.Fingerprint(result.Move))
		else
			reportFailure(handle, "Could not load move", result.Reason)
		end
	end)

	handle.DeleteMoveRequested:Connect(function(moveId: string)
		-- Refuses to empty the custom list. The state it prevents IS recoverable ("+ New Move" is
		-- right there, and the empty-state card says so), so this is a guard against an accident
		-- rather than against an invalid state -- deleting the one move you have is almost always a
		-- mis-aimed second press on a two-press confirm, and the cost of being wrong is a DataStore
		-- record that no longer exists anywhere.
		if countCustomMoves(handle) <= 1 then
			handle.StatusText:set("That's the last custom move -- create another before deleting it.")
			return
		end
		-- CANCEL, not flush -- see cancelPendingDraftUpdate's own header. A pending edit for a move
		-- being deleted must never reach the server: landing after the delete, it is an UpdateDraft
		-- for an unknown MoveId, which mints a fresh id and resurrects the move. An undo stack for a
		-- deleted move would do exactly the same thing one Ctrl+Z later, so it goes too.
		cancelPendingDraftUpdate(moveId)
		editState:Forget(moveId)
		publishUnsavedCount(handle)
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
			reportFailure(handle, "Could not delete move", result.Reason)
		end
	end)

	-- Pushes `newDraft` to the server's live registry RIGHT NOW (no debounce) and reconciles the
	-- response -- the one thing both the debounced DraftFieldChanged path below and
	-- flushPendingDraftUpdateFor must do identically, so the two can never drift into disagreeing
	-- about what an UpdateDraft round trip looks like. Yields (InvokeServer) -- every caller here
	-- is a signal handler or another already-yielding function, so that's safe.
	local function sendDraftUpdateNow(newDraft: MoveTypes.MoveDefinition, isDefaultMove: boolean): ()
		local moveId = newDraft.MoveId
		local sequence = (draftSendSequenceByMoveId[moveId] or 0) + 1
		draftSendSequenceByMoveId[moveId] = sequence
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
			if draftSendSequenceByMoveId[moveId] ~= sequence then
				-- A newer UpdateDraft for this SAME move was sent while this one was in flight (or the
				-- move was deleted, which clears the sequence outright). That newer round trip owns the
				-- reconcile; applying this older response would put the admin's newer edit back to what
				-- the server held one round trip ago.
				return
			end
			-- Only reconcile Draft if the admin hasn't since selected/created a DIFFERENT move.
			local currentDraft = peek(handle.Draft)
			if currentDraft and currentDraft.MoveId == result.Move.MoveId then
				setOpenDraft(result.Move)
			end
			patchMovesDisplay(handle, result.Move)
		end
	end

	-- Schedules ONE move's debounced UpdateDraft. Split out of DraftFieldChanged's handler below
	-- because undo/redo need exactly this and nothing else around it: they must not record history
	-- (they are moving through history), and they have already written Draft themselves.
	local function scheduleDraftUpdate(newDraft: MoveTypes.MoveDefinition): ()
		-- Keyed by the edited move's OWN id, so a second move edited inside this window gets its own
		-- entry instead of invalidating this one -- see pendingDraftByMoveId's own header. A blank
		-- MoveId can't reach here (Draft is only ever set from a server response, which always carries
		-- a stamped one); if one somehow did, every such draft would share a single key, which is
		-- exactly the single-slot behaviour this replaced rather than something worse.
		local moveId = newDraft.MoveId
		local entry: PendingDraftUpdate = {
			Draft = newDraft,
			IsDefaultMove = newDraft.Category == MoveTypes.DefaultCategory,
		}
		pendingDraftByMoveId[moveId] = entry
		task.delay(Config.DraftDebounceSeconds, function()
			if pendingDraftByMoveId[moveId] ~= entry then
				-- A newer edit to this same move replaced the entry, or a flush/cancel already consumed
				-- it. Whoever did that owns the send; this stale closure drops itself.
				return
			end
			pendingDraftByMoveId[moveId] = nil
			sendDraftUpdateNow(entry.Draft, entry.IsDefaultMove)
		end)
	end

	-- Files one edit into the move's history and republishes the unsaved count. Wrapped rather than
	-- called directly because a rename from the move list is an ordinary field edit that simply did
	-- not arrive through the property form, and it has to do both of these too.
	local function recordHistory(newDraft: MoveTypes.MoveDefinition): ()
		editState:Record(newDraft)
		publishUnsavedCount(handle)
	end

	handle.DraftFieldChanged:Connect(function(newDraft: MoveTypes.MoveDefinition)
		recordHistory(newDraft)
		scheduleDraftUpdate(newDraft)
	end)

	-- A rename is a DisplayName edit authored from the move list rather than from the Basic Info
	-- field, so it deliberately takes the SAME two routes any field edit does -- history, then the
	-- debounced UpdateDraft -- and needs no remote of its own.
	--
	-- The one thing it has to handle that a property-form edit never does is renaming a move that is
	-- NOT open. That record lives in MovesDisplay rather than Draft, has no undo history worth
	-- keeping (nothing else about it was edited this session), and cannot go through the debounce
	-- either -- the debounce map is keyed to drafts the editor is holding. It is sent immediately.
	handle.RenameMoveRequested:Connect(function(moveId: string, newName: string)
		local trimmed = newName:match("^%s*(.-)%s*$") or ""
		if trimmed == "" then
			handle.StatusText:set("A move needs a name.")
			return
		end

		local currentDraft = peek(handle.Draft)
		local isOpenDraft = currentDraft ~= nil and (currentDraft :: MoveTypes.MoveDefinition).MoveId == moveId
		local source = if isOpenDraft then currentDraft else findInMovesDisplay(handle, moveId)
		if not source then
			handle.StatusText:set("That move is no longer in the list.")
			return
		end
		if source.Category == MoveTypes.DefaultCategory then
			-- Belt and braces: MoveList never renders a rename tile for a Default row, and
			-- MoveRegistryManager would refuse the write anyway. Saying so beats a silent no-op.
			handle.StatusText:set("A built-in move's name can't be changed.")
			return
		end
		if source.DisplayName == trimmed then
			return
		end

		local renamed = MoveTypes.Clone(source)
		renamed.DisplayName = trimmed
		-- Filed as an edit either way -- a rename reaches the live registry and not the DataStore, which
		-- is exactly what "unsaved" means, and Ctrl+Z on that move should walk the name back like any
		-- other field. Only the DELIVERY differs below.
		recordHistory(renamed)
		if isOpenDraft then
			setOpenDraft(renamed)
			scheduleDraftUpdate(renamed)
		else
			-- No Draft to write and no debounce entry keyed to this move -- the debounce map only ever
			-- holds drafts the editor has open. Sent straight out; the response patches MovesDisplay,
			-- which is what the renamed row re-renders from.
			sendDraftUpdateNow(renamed, false)
		end
		handle.StatusText:set(`Renamed to "{trimmed}" -- Save to persist.`)
	end)

	-- The restored state goes out through the ordinary debounced UpdateDraft, NOT a new remote: an
	-- undone move has to reach the server's live registry exactly like any other edit, or the next
	-- test fire swings the version the admin just undid.
	local function stepHistory(
		stepper: (
			MoveEditState.MoveEditStateInstance,
			MoveTypes.MoveDefinition
		) -> MoveTypes.MoveDefinition?,
		nothingToDo: string
	): ()
		local currentDraft = peek(handle.Draft)
		if not currentDraft then
			return
		end
		local restored = stepper(editState, currentDraft)
		if not restored then
			handle.StatusText:set(nothingToDo)
			return
		end
		-- Draft only, NOT setOpenDraft: the step already moved the baseline to the restored state,
		-- and re-setting it here would be harmless today but would silently break the moment either
		-- side of that agreement changed.
		handle.Draft:set(restored)
		publishUnsavedCount(handle)
		scheduleDraftUpdate(restored)
	end

	function requestUndo(): ()
		stepHistory(MoveEditState.Undo, "Nothing left to undo on this move.")
	end

	function requestRedo(): ()
		stepHistory(MoveEditState.Redo, "Nothing to redo on this move.")
	end

	-- Takes ONE move's still-pending debounced UpdateDraft out of the map and sends it RIGHT NOW
	-- instead, blocking until the server's live registry actually reflects it. Removing the entry is
	-- also what cancels the scheduled closure (task.delay has no cancel -- see pendingDraftByMoveId's
	-- own header), so this can never double-send.
	function flushPendingDraftUpdateFor(moveId: string): ()
		local entry = pendingDraftByMoveId[moveId]
		if not entry then
			return
		end
		pendingDraftByMoveId[moveId] = nil
		sendDraftUpdateNow(entry.Draft, entry.IsDefaultMove)
	end

	-- Every pending move at once. Called from setOpen (every panel close) -- see
	-- pendingDraftByMoveId's own header for the race this exists to close: without it, the hotbar's
	-- live-fire path reads MoveRegistryManager's registry by moveId alone, trusting it already
	-- reflects the admin's last edit, which the debounce alone can't guarantee. Snapshots the keys
	-- first because each flush yields (InvokeServer) and mutates the map it would otherwise be
	-- iterating.
	function flushPendingDraftUpdates(): ()
		local moveIds: { string } = {}
		for moveId in pairs(pendingDraftByMoveId) do
			table.insert(moveIds, moveId)
		end
		for _, moveId in ipairs(moveIds) do
			flushPendingDraftUpdateFor(moveId)
		end
	end

	-- What every path that navigates AWAY from the open draft calls first (select another move,
	-- create one, duplicate). Without it an edit still inside the 150ms debounce window when the
	-- admin clicks a different row is simply lost: the switch replaces Draft, and the pending send
	-- was keyed to a draft nobody will look at again.
	function flushCurrentDraft(): ()
		local currentDraft = peek(handle.Draft)
		if currentDraft then
			flushPendingDraftUpdateFor(currentDraft.MoveId)
		end
	end

	-- Drops a move's pending edit WITHOUT sending it, and forgets its send sequence so a round trip
	-- already in flight can't reconcile either. Exactly one caller, and the reason this exists:
	-- DeleteMoveRequested. A debounced edit landing after the delete completes reaches
	-- MoveEditorSystem.stampTrustedMetadata with a MoveId the registry no longer knows, which takes
	-- its "unknown move" branch and mints a FRESH MoveId -- resurrecting the just-deleted move under
	-- a new identity. Flushing would be equally wrong here (it writes the deleted move straight
	-- back); the edit is discarded on purpose.
	function cancelPendingDraftUpdate(moveId: string): ()
		pendingDraftByMoveId[moveId] = nil
		draftSendSequenceByMoveId[moveId] = nil
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
			setOpenDraft(result.Move)
			handle.SavedFingerprint:set(MoveTypes.Fingerprint(result.Move))
			patchMovesDisplay(handle, result.Move)
			editState:MarkSaved(result.Move.MoveId)
			publishUnsavedCount(handle)
			flashSaved(handle, result.Move.MoveId)
			handle.StatusText:set("Reset to default.")
		else
			reportFailure(handle, "Could not reset", result.Reason)
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
			setOpenDraft(result.Move)
			handle.SavedFingerprint:set(MoveTypes.Fingerprint(result.Move))
			patchMovesDisplay(handle, result.Move)
			editState:MarkSaved(result.Move.MoveId)
			publishUnsavedCount(handle)
			flashSaved(handle, result.Move.MoveId)
			handle.StatusText:set("Saved.")
		else
			reportFailure(handle, "Could not save", result.Reason)
		end
	end
	handle.SaveRequested:Connect(requestSave)

	-- Duplicate. Needs NO server change and no new remote: stampTrustedMetadata mints a fresh MoveId
	-- whenever the submitted one is empty or unknown, and overwrites Author/CreatedAt from trusted
	-- server context regardless -- so blanking all four here and sending the result through the
	-- existing UpdateDraft is exactly the path "+ New Move" already takes, just seeded from a real
	-- move instead of defaultDraft().
	-- `moveId` nil or "" means the OPEN DRAFT (the toolbar button and Ctrl+D); a real id means that
	-- row of the move list, which need not be the selected one.
	function requestDuplicate(moveId: string?)
		local openDraft = peek(handle.Draft)
		local wantsOpenDraft = moveId == nil
			or moveId == ""
			or (openDraft ~= nil and (openDraft :: MoveTypes.MoveDefinition).MoveId == moveId)
		-- A row's own record comes from MovesDisplay -- as current as the last round trip, which for a
		-- move nobody is editing is exactly current. The OPEN draft has to come from Draft instead,
		-- since it may hold edits that have not been sent yet.
		local currentDraft = if wantsOpenDraft then openDraft else findInMovesDisplay(handle, moveId :: string)
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
		-- Duplicating navigates away from whatever is open (Draft becomes the copy), so an edit still
		-- inside that move's debounce window has to land first -- otherwise it is dropped, AND a copy
		-- of the OPEN move would be seeded from a state the server never heard about. Re-peeked after
		-- for that case only, because the flush's own response reconciles Draft and replaces the table
		-- peeked above; a copy of some OTHER row is unaffected by that reconcile.
		flushCurrentDraft()
		local source = if wantsOpenDraft then (peek(handle.Draft) or currentDraft) else currentDraft

		-- MoveTypes.Clone, never table.clone: a shallow copy would leave the duplicate's Knockback/
		-- ObjectStun/Animations aliasing the ORIGINAL's, so the first edit to the copy would silently
		-- corrupt the move it came from -- which is still sitting in MovesDisplay.
		local copy = MoveTypes.Clone(source)
		copy.MoveId = "" -- what makes stampTrustedMetadata mint a fresh one
		copy.Author = "" -- overwritten server-side; blanked here to state that intent
		copy.CreatedAt = 0
		copy.UpdatedAt = 0
		-- " Copy", with the space: the reference design writes "_Copy", but every DisplayName in this
		-- editor is prose an admin reads in a list ("Rising Dragon Palm"), not an identifier -- the
		-- underscore convention belongs to MoveId, which is server-stamped and never authored here.
		copy.DisplayName = source.DisplayName .. " Copy"

		local ok, resultOrError = pcall(function()
			return updateDraftRemote:InvokeServer(encodeDraftForWire(copy))
		end)
		if not ok then
			handle.StatusText:set("Failed to duplicate: request error")
			return
		end
		local result = resultOrError :: MoveTypes.MoveEditorMoveResult
		if result.Success and result.Move then
			setOpenDraft(result.Move)
			handle.SavedFingerprint:set(MoveTypes.Fingerprint(result.Move))
			patchMovesDisplay(handle, result.Move)
			-- Says "Save to persist" deliberately: the duplicate exists in the server's in-memory
			-- registry and is immediately test-fireable, but nothing has reached the DataStore yet.
			handle.StatusText:set("Duplicated -- Save to persist.")
		else
			reportFailure(handle, "Could not duplicate", result.Reason)
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

	-- Routes into ArtSystem.DevGrantAndEquip server-side (Constants.MoveEditor.RemoteNames.
	-- EquipArtSlot) -- see MoveEditor/Types.lua's own header on this signal and HotbarBindings.lua's
	-- own header on why binding IS equipping now, not a second client-side map. Toggles: binding the
	-- SAME move that's already on this slot clears it instead of re-binding it, the only way the UI
	-- offers to free a slot. No local write to HotbarBindings here -- the server's own
	-- Art_StateUpdated push is what updates it (CharacterMenuClient.lua's mirrorToHotbar), the same
	-- "no optimistic write" rule CharacterMenuClient's own EquipArtRequested handler already follows,
	-- so a slot's Selected state only ever reflects what the server actually accepted.
	handle.BindHotbarSlotRequested:Connect(function(slot: number, moveId: string)
		local clearing = HotbarBindings.Get(slot) == moveId
		local artId: string? = if clearing then nil else moveId
		task.spawn(function()
			local ok, resultOrError = RemoteInvoker.Invoke(equipArtSlotRemote, slot, artId)
			if not ok then
				handle.StatusText:set("Failed to bind hotbar slot: request error")
				return
			end
			local result = resultOrError :: MoveTypes.MoveEditorActionResult
			if not result.Success then
				reportFailure(handle, "Failed to bind hotbar slot", result.Reason)
				return
			end
			handle.StatusText:set(if clearing then `Cleared hotbar slot {slot}.` else `Bound to hotbar slot {slot}.`)
		end)
	end)
end

-- Runs on a delay (task.spawn), same reasoning as DevMenuClient.Start: this is called synchronously
-- partway through Main.client.lua's boot sequence, and the authorization round trip yields.
--
-- TAKES A Shared/Lazy.lua THUNK, same as DevMenuClient.Start and for the same reason -- this is the
-- BIGGEST of the three deferred admin panels at ~143 Instances, and UI.Mount() used to build all of
-- them on the boot path for every player. Forced only once the server has said yes AND both move
-- lists are in hand, so the panel is mounted with real data rather than mounted empty and then filled.
function MoveEditorClient.Start(deferredHandle: Lazy.Lazy<MoveEditorHandle>, chrome: Chrome.ChromeHandle): ()
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
		startMoveEditor(deferredHandle.Get(), chrome, merged)
	end)
end

return MoveEditorClient
