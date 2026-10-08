--!strict
--[[
	MoveEditorClient.lua

	Owns: driving the Move Editor screen (UI/Screens/DevTools/MoveEditor) from outside -- the open key,
	authorization, and every signal on its handle turned into a Constants.MoveEditor.RemoteNames call,
	with the server's answer written back into the handle's Values.

	AUTHORIZATION IS THE FIRST Open. There is no "am I an admin" remote: Open is admin-gated, so a client
	whose first Open is refused is simply not an admin, and this module never builds the screen (the
	Lazy is never forced, so a player's client does not even mount it).

	THE SCREEN IS BUILT ON THE FIRST PRESS OF ITS KEY, NOT ON AUTHORIZATION (2026-09-30). An authorized
	admin used to have the whole editor mounted one round trip after joining -- a 1.0-1.4 second freeze
	in every capture (1355, 1141, 1123, 1047ms at "MoveEditorClient started"), plus its per-frame
	hitbox-preview loop running for the whole session whether or not the editor was ever opened. Now
	Start only binds the key; the first press mounts, wires and opens it, paying the build at the moment
	the author asked for the editor. `skipInput` keeps the editor's own key handler from seeing that same
	press and toggling it straight back shut -- for a quarter of a second only: an identity check alone once
	swallowed every later press too, and the editor would not reopen after its first close.

	THE DRAFT, AND WHO WINS. The screen sets Draft optimistically on every edit; this module debounces
	those into one Preview (Constants.MoveEditor.DraftDebounceSeconds). The server's answer is the
	authority -- it may have clamped a number or normalised an animation id -- so it is written back into
	Draft, BUT only when no newer local edit has happened since that Preview was sent. Otherwise a slow
	answer to an old edit would snap a field back under the author's cursor. `editSerial` is that check:
	every local edit bumps it, and an answer only lands in Draft if the serial it was sent at is still
	the latest. The entry list takes every answer regardless -- it is the server's truth about the move,
	not the author's in-progress view of it.

	ANYTHING THAT READS THE LIVE MOVE FLUSHES FIRST. Save, Test, bind-to-slot, switching moves and
	closing all send a pending Preview immediately rather than letting the debounce drop it: each of them
	is about the move as the author last saw it, and the debounce window is exactly the gap in which the
	server's copy is one edit behind.

	TEST REPORTS WHAT LANDED. After a Test the next Combat_Feedback naming this move with this client as
	the attacker becomes the status line ("Landed: Clean -- 12 damage, 9 guard") -- a second listener on
	DamageSystem's own feedback event, filtered to the open move -- and every such contact is also
	prepended to the readout's HIT LOG, timed from the swing's own Attack_Started (AttackInputClient
	.OnAttackStarted), so a contact's delay after the swing began is what the log shows.

	THE BENCH IS THE DEV MENU'S. Dummy, dummy guard, sparring bot and clear-all all call the Dev Menu's
	own remotes (Constants.Debug.DevMenu.RemoteNames), gated by DevMenuSystem; the editor adds no server
	code for them.

	Does not own: whether any of it is allowed (MoveEditorSystem re-checks every call), or the screen.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Constants = require(ReplicatedStorage.Shared.Constants)
local DamageConstants = require(ReplicatedStorage.Shared.Damage.DamageConstants)
local DamageTypes = require(ReplicatedStorage.Shared.Damage.DamageTypes)
local Lazy = require(ReplicatedStorage.Shared.Lazy)
local Logger = require(ReplicatedStorage.Shared.Logger)
local MoveEditorTypes = require(ReplicatedStorage.Shared.Authoring.MoveEditorTypes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)

local AttackInputClient = require(script.Parent.Parent.Parent.Combat.AttackInputClient)
local Chrome = require(script.Parent.Parent.Parent.UI.Shell.Chrome)
local ClipScrubber = require(script.Parent.ClipScrubber)
local Copy = require(script.Parent.Parent.Parent.UI.Screens.DevTools.MoveEditor.Copy)
local HitboxWorldPreview = require(script.Parent.HitboxWorldPreview)
local HotbarBindings = require(script.Parent.Parent.Parent.Combat.HotbarBindings)
local KeybindManager = require(script.Parent.Parent.Parent.Input.KeybindManager)
local MoveEditorScreenTypes = require(script.Parent.Parent.Parent.UI.Screens.DevTools.MoveEditor.Types)
local PresentationPreview = require(script.Parent.PresentationPreview)
local RemoteInvoker = require(script.Parent.Parent.Parent.Network.RemoteInvoker)

local peek = Fusion.peek

type MoveEditorHandle = MoveEditorScreenTypes.MoveEditorHandle
type MoveEntry = MoveEditorTypes.MoveEntry
type Move = MoveTypes.MoveDefinition

local MoveEditorClient = {}

local logger = Logger.scope("MoveEditorClient")

local Config = Constants.MoveEditor
local DEV_MENU_REMOTES = Constants.Debug.DevMenu.RemoteNames

-- How long after a Test a landed hit is still reported as that test's.
local TEST_REPORT_WINDOW_SECONDS = 3
-- Rows the hit log keeps; older contacts fall off the bottom.
local HIT_LOG_CAPACITY = 20

local function modifierDown(): boolean
	return UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
		or UserInputService:IsKeyDown(Enum.KeyCode.LeftSuper)
end

-- The one New-move template, from Constants so the server spec can pin it inside Limits.
local function newMoveDraft(): Move
	local template = Config.NewMoveTemplate
	return {
		MoveId = "",
		DisplayName = template.DisplayName,
		Description = "",
		Category = "",
		Author = "",
		CreatedAt = 0,
		UpdatedAt = 0,
		Shape = template.Shape :: MoveTypes.MoveShape,
		Dimensions = table.clone(template.Dimensions),
		Offset = CFrame.new(0, 0, template.OffsetZ),
		OffsetRotation = Vector3.zero,
		AttachmentPart = "Root",
		LocksMovement = false,
		LocksWindup = false,
		WindupSeconds = template.WindupSeconds,
		ActiveSeconds = template.ActiveSeconds,
		RecoverySeconds = template.RecoverySeconds,
		Cooldown = template.Cooldown,
		Damage = template.Damage,
		PostureDamage = template.PostureDamage,
		MaxTargets = template.MaxTargets,
		AnimationId = "",
	}
end

local function invoke(remoteName: string, ...: any): (boolean, any)
	return RemoteInvoker.Invoke(NetworkBridge.GetRemoteFunction(remoteName), ...)
end

-- Returns the editor's `setOpen`, so the caller that built it on a first key press can open it. `skipInput`
-- is that press: the key handler below ignores it (see this file's header).
local function startEditor(
	handle: MoveEditorHandle,
	chrome: Chrome.ChromeHandle,
	initial: { MoveEntry },
	skipInput: InputObject?
): (open: boolean) -> ()
	handle.Entries:set(initial)
	-- `skipInput` is only meant to swallow the press that BUILT the editor. Roblox may hand the same InputObject
	-- back for every later press of that key, so an identity test alone would swallow them all and the editor
	-- could never be opened again after its first close -- the skip lapses a moment after the build instead.
	local skipUntil = os.clock() + 0.25
	local names = Config.RemoteNames
	local setEditorOpenRemote = NetworkBridge.GetRemoteEvent(names.SetEditorOpen)

	-- Entries ---------------------------------------------------------------------------------------

	local function findEntry(moveId: string): MoveEntry?
		for _, entry in ipairs(peek(handle.Entries)) do
			if entry.Move.MoveId == moveId then
				return entry
			end
		end
		return nil
	end

	-- Replaces the entry for its move, or appends it. A new list every time: Fusion only notices a new
	-- table.
	local function upsertEntry(entry: MoveEntry): ()
		local list = table.clone(peek(handle.Entries))
		for index, existing in ipairs(list) do
			if existing.Move.MoveId == entry.Move.MoveId then
				list[index] = entry
				handle.Entries:set(list)
				return
			end
		end
		table.insert(list, entry)
		handle.Entries:set(list)
	end

	local function removeEntry(moveId: string): ()
		local list = {}
		for _, existing in ipairs(peek(handle.Entries)) do
			if existing.Move.MoveId ~= moveId then
				table.insert(list, existing)
			end
		end
		handle.Entries:set(list)
	end

	local function report(action: string, reason: string?): ()
		local failure = Copy.Failure(reason)
		handle.StatusText:set(`{action}: {failure.Message}`)
		-- A realm's damage lives on Effects, not Impact (it has no Impact tab): Copy says which.
		local tab = Copy.FailureTab(failure, peek(handle.IsDomain))
		if tab then
			handle.ShowPage(tab)
		end
	end

	local function openMove(entry: MoveEntry?): ()
		if entry then
			handle.SelectedId:set(entry.Move.MoveId)
			handle.Draft:set(MoveTypes.Clone(entry.Move))
		else
			handle.SelectedId:set(nil)
			handle.Draft:set(nil)
		end
	end

	-- Preview (debounced) -------------------------------------------------------------------------------

	local editSerial = 0
	local pendingDraft: Move? = nil
	local pendingToken = 0

	-- Sends `draft` now and applies the answer. Yields for the round trip.
	local function preview(draft: Move): ()
		local sentAt = editSerial
		local ok, result = invoke(names.Preview, MoveTypes.ToWire(draft))
		if not ok then
			handle.StatusText:set("Preview: the request failed.")
			return
		end
		local answer = result :: MoveEditorTypes.EntryResult
		if not answer.Success or not answer.Entry then
			report("Not applied", answer.Reason)
			return
		end
		local entry = answer.Entry :: MoveEntry
		upsertEntry(entry)
		local current = peek(handle.Draft)
		if sentAt == editSerial and current and current.MoveId == entry.Move.MoveId then
			if MoveTypes.Fingerprint(current) ~= MoveTypes.Fingerprint(entry.Move) then
				handle.Draft:set(MoveTypes.Clone(entry.Move))
			end
		end
	end

	-- Sends whatever is still waiting in the debounce, synchronously. Every action that reads the live
	-- move calls this first -- see this file's header.
	local function flush(): ()
		local draft = pendingDraft
		pendingDraft = nil
		pendingToken += 1
		if draft then
			preview(draft)
		end
	end

	handle.DraftEdited:Connect(function(draft: Move)
		editSerial += 1
		pendingDraft = draft
		pendingToken += 1
		local token = pendingToken
		task.delay(Config.DraftDebounceSeconds, function()
			if token == pendingToken then
				flush()
			end
		end)
	end)

	-- Open / close --------------------------------------------------------------------------------------

	local function refresh(): ()
		local ok, result = invoke(names.Open)
		local answer = if ok then result :: MoveEditorTypes.OpenResult else nil
		if not answer or not answer.Success then
			report("Could not load moves", if answer then answer.Reason else nil)
			return
		end
		handle.Entries:set(answer.Entries or {})
		local selected = peek(handle.SelectedId)
		if selected then
			openMove(findEntry(selected))
		end
	end

	local function refreshVolumes(): ()
		local ok, result = invoke(DEV_MENU_REMOTES.GetHitboxDebug)
		if ok and typeof(result) == "table" and result.Success then
			handle.VolumesVisible:set(result.Enabled == true)
		end
	end

	local function refreshDummyGuard(): ()
		local ok, result = invoke(DEV_MENU_REMOTES.GetDebugDummyState)
		if ok and typeof(result) == "table" and result.Success then
			handle.DummyGuard:set(result.GuardEnabled == true)
		end
	end

	local function setOpen(open: boolean): ()
		if not open then
			flush()
			handle.PlacementMode:set(false)
		end
		handle.IsOpen:set(open)
		setEditorOpenRemote:FireServer(open)
		if open then
			task.spawn(refresh)
			task.spawn(refreshVolumes)
			task.spawn(refreshDummyGuard)
		end
	end

	-- Closing with unsaved work arms first; a second close inside the window commits. The live registry
	-- keeps the unsaved edits either way -- only a restart loses them -- which the prompt says.
	local closeArmedUntil = 0
	local function requestClose(): ()
		if peek(handle.IsDirty) and os.clock() > closeArmedUntil then
			closeArmedUntil = os.clock() + Config.ConfirmWindowSeconds
			handle.StatusText:set("Unsaved changes stay live until a restart -- close again to leave them unsaved.")
			return
		end
		closeArmedUntil = 0
		setOpen(false)
	end

	chrome:BindEscape("MoveEditor", handle.IsOpen, requestClose)
	handle.CloseRequested:Connect(requestClose)

	-- Place mode pushes its own Escape entry on entry, so it sits above the editor's: the first Escape
	-- leaves placement and brings the modal back; only the next one closes the editor.
	HitboxWorldPreview.Start(handle)
	chrome:BindEscape("MoveEditorPlacement", handle.PlacementMode, function()
		handle.PlacementMode:set(false)
	end)

	-- Selection, creation ----------------------------------------------------------------------------------

	handle.SelectRequested:Connect(function(moveId: string)
		if moveId == peek(handle.SelectedId) then
			return
		end
		flush()
		openMove(findEntry(moveId))
		handle.StatusText:set("")
		-- The log is about the open move's tests; another move's contacts would read as this one's.
		handle.HitLog:set({})
		handle.HistoryVersions:set(nil)
		handle.ExportText:set(nil)
	end)

	-- Creating is a Preview with no MoveId: the server assigns one and answers with the entry.
	local function create(draft: Move, verb: string): ()
		flush()
		local ok, result = invoke(names.Preview, MoveTypes.ToWire(draft))
		local answer = if ok then result :: MoveEditorTypes.EntryResult else nil
		if not answer or not answer.Success or not answer.Entry then
			report(`Could not {verb}`, if answer then answer.Reason else nil)
			return
		end
		local entry = answer.Entry :: MoveEntry
		upsertEntry(entry)
		openMove(entry)
		-- Land on the tab the type is about: its volume, or its realm. Naming it is Identity's, one tab over.
		handle.ShowPage(if entry.Move.Domain then "Realm" else "Hitbox")
		handle.StatusText:set(`{entry.Move.DisplayName} created -- live, not saved yet.`)
	end

	-- The browser asks the type up front (Melee, Projectile, Domain); the draft is seeded as that type
	-- before its first preview, so the server names a move that is already what it was asked to be.
	handle.NewRequested:Connect(function(kind: string)
		local draft = newMoveDraft()
		handle.SetMoveType(draft, kind or "Melee")
		create(draft, "create the move")
	end)

	local function duplicate(): ()
		local source = peek(handle.Draft)
		local entry = peek(handle.SelectedEntry)
		if not source then
			return
		end
		local copy = MoveTypes.Clone(source)
		copy.MoveId = ""
		copy.DisplayName = string.sub(source.DisplayName .. " copy", 1, Config.Limits.DisplayNameLength)
		-- A copy of a weapon move becomes an ordinary custom move. It keeps the clip it was playing --
		-- otherwise the catalogue would find no clip for its new id -- and its weapon anchor.
		if entry and entry.Source == "Default" and entry.Effective then
			copy.AnimationId = entry.Effective.AnimationId
		end
		-- An art's place in its tree is its own; a copy starts outside every tree.
		copy.Art = nil
		create(copy, "duplicate the move")
	end
	handle.DuplicateRequested:Connect(duplicate)

	-- Commit, revert, delete -------------------------------------------------------------------------------

	local function save(): ()
		local draft = peek(handle.Draft)
		if not draft then
			return
		end
		pendingDraft = nil
		pendingToken += 1
		local sentAt = editSerial
		local ok, result = invoke(names.Save, MoveTypes.ToWire(draft))
		local answer = if ok then result :: MoveEditorTypes.EntryResult else nil
		if not answer or not answer.Success or not answer.Entry then
			report("Not saved", if answer then answer.Reason else nil)
			return
		end
		local entry = answer.Entry :: MoveEntry
		upsertEntry(entry)
		if sentAt == editSerial then
			openMove(entry)
		end
		handle.StatusText:set(`Saved {entry.Move.DisplayName}.`)
		-- A loaded history just gained a version; drop it rather than show a list missing the newest.
		handle.HistoryVersions:set(nil)
	end
	handle.SaveRequested:Connect(save)

	handle.RevertRequested:Connect(function()
		local moveId = peek(handle.SelectedId)
		if not moveId then
			return
		end
		pendingDraft = nil
		pendingToken += 1
		editSerial += 1
		local ok, result = invoke(names.Revert, moveId)
		local answer = if ok then result :: MoveEditorTypes.EntryResult else nil
		if not answer or not answer.Success then
			report("Not reverted", if answer then answer.Reason else nil)
			return
		end
		-- The stack holds drafts from before the revert; stepping into one would undo the revert itself.
		handle.ClearHistory(moveId)
		local entry = answer.Entry
		if entry then
			upsertEntry(entry)
			openMove(entry)
			handle.StatusText:set("Reverted to the saved version.")
		else
			removeEntry(moveId)
			openMove(nil)
			handle.StatusText:set("Reverted: the move was never saved, so it is gone.")
		end
	end)

	handle.DeleteRequested:Connect(function()
		local moveId = peek(handle.SelectedId)
		if not moveId then
			return
		end
		pendingDraft = nil
		pendingToken += 1
		local ok, result = invoke(names.Delete, moveId)
		local answer = if ok then result :: MoveEditorTypes.ActionResult else nil
		if not answer or not answer.Success then
			report("Not deleted", if answer then answer.Reason else nil)
			return
		end
		handle.ClearHistory(moveId)
		removeEntry(moveId)
		openMove(nil)
		handle.StatusText:set("Deleted.")
	end)

	handle.ResetDefaultRequested:Connect(function()
		local moveId = peek(handle.SelectedId)
		if not moveId then
			return
		end
		pendingDraft = nil
		pendingToken += 1
		editSerial += 1
		local ok, result = invoke(names.ResetDefault, moveId)
		local answer = if ok then result :: MoveEditorTypes.EntryResult else nil
		if not answer or not answer.Success or not answer.Entry then
			report("Not reset", if answer then answer.Reason else nil)
			return
		end
		handle.ClearHistory(moveId)
		local entry = answer.Entry :: MoveEntry
		upsertEntry(entry)
		openMove(entry)
		handle.StatusText:set("Reset to the weapon's own values.")
	end)

	-- Version history -----------------------------------------------------------------------------------

	local function loadHistory(): ()
		local moveId = peek(handle.SelectedId)
		if not moveId then
			return
		end
		local ok, result = invoke(names.History, moveId)
		local answer = if ok then result :: MoveEditorTypes.HistoryResult else nil
		if not answer or not answer.Success then
			report("History", if answer then answer.Reason else nil)
			return
		end
		-- A slow answer for a move the admin has since left belongs to nobody.
		if peek(handle.SelectedId) == moveId then
			handle.HistoryVersions:set(answer.Versions or {})
		end
	end
	handle.LoadHistoryRequested:Connect(loadHistory)

	handle.RestoreVersionRequested:Connect(function(version: number)
		local moveId = peek(handle.SelectedId)
		if not moveId then
			return
		end
		pendingDraft = nil
		pendingToken += 1
		editSerial += 1
		local ok, result = invoke(names.RestoreVersion, moveId, version)
		local answer = if ok then result :: MoveEditorTypes.EntryResult else nil
		if not answer or not answer.Success or not answer.Entry then
			report("Not restored", if answer then answer.Reason else nil)
			return
		end
		handle.ClearHistory(moveId)
		local entry = answer.Entry :: MoveEntry
		upsertEntry(entry)
		openMove(entry)
		handle.StatusText:set(`Restored v{version} -- live, not saved.`)
	end)

	-- Source (Studio only) --------------------------------------------------------------------------------

	-- Write and Remove act on the LIVE move, so a pending edit is sent first -- the file must be what the
	-- author is looking at.
	local function sourceAction(
		remoteName: string,
		verb: string,
		describe: (MoveEditorTypes.SourceResult) -> string
	): ()
		local moveId = peek(handle.SelectedId)
		if not moveId then
			return
		end
		flush()
		local ok, result = invoke(remoteName, moveId)
		local answer = if ok then result :: MoveEditorTypes.SourceResult else nil
		if not answer or not answer.Success then
			report(verb, if answer then answer.Reason else nil)
			return
		end
		if answer.Entry then
			upsertEntry(answer.Entry)
			if peek(handle.SelectedId) == moveId then
				openMove(answer.Entry)
			end
		end
		handle.StatusText:set(describe(answer))
	end

	handle.WriteToSourceRequested:Connect(function()
		sourceAction(names.WriteToSource, "Not written", function(answer)
			local warning = if answer.Reason then ` (but: {Copy.Failure(answer.Reason).Message})` else ""
			return `Written to {answer.Path or "source"}{warning}`
		end)
	end)

	handle.RemoveFromSourceRequested:Connect(function()
		sourceAction(names.RemoveFromSource, "Not removed", function(answer)
			return `Removed {answer.Path or "the file"} -- the move stays live, unsaved, until a restart.`
		end)
	end)

	handle.ExportSourceRequested:Connect(function()
		local moveId = peek(handle.SelectedId)
		if not moveId then
			return
		end
		flush()
		local ok, result = invoke(names.ExportSource, moveId)
		local answer = if ok then result :: MoveEditorTypes.SourceResult else nil
		if not answer or not answer.Success or not answer.Source then
			report("Not exported", if answer then answer.Reason else nil)
			return
		end
		handle.ExportText:set(answer.Source)
		handle.StatusText:set(`Exported -- copy it into {answer.Path or "the AuthoredMoves folder"}.`)
	end)

	-- Presentation preview ----------------------------------------------------------------------------

	-- Plays the DRAFT's cue, locally, through the runtime's own path (PresentationPreview's header) -- no
	-- flush and no remote: what is previewed is exactly what is on screen, saved or not.
	handle.PreviewCueRequested:Connect(function(moment: string)
		local draft = peek(handle.Draft)
		if not draft then
			return
		end
		local entry = peek(handle.SelectedEntry)
		local isWeaponStage = entry ~= nil and entry.Source == "Default" and entry.Stage ~= nil
		handle.StatusText:set(PresentationPreview.Play(draft, moment, {
			Stage = if isWeaponStage and entry then entry.Stage else nil,
			WeaponId = if isWeaponStage and entry then entry.Group else nil,
		}))
	end)

	-- Bulk edit ------------------------------------------------------------------------------------------

	handle.BulkScaleRequested:Connect(function(request: MoveEditorTypes.BulkScaleRequest)
		flush()
		local ok, result = invoke(names.BulkScale, request)
		local answer = if ok then result :: MoveEditorTypes.BulkScaleResult else nil
		if not answer or not answer.Success or not answer.Entries then
			report("Not scaled", if answer then answer.Reason else nil)
			return
		end
		local selected = peek(handle.SelectedId)
		for _, entry in answer.Entries do
			upsertEntry(entry)
			if entry.Move.MoveId == selected then
				-- The open move changed under the draft: its undo stack holds states from before the
				-- scale, and stepping into one would silently undo part of a bulk edit.
				editSerial += 1
				handle.ClearHistory(entry.Move.MoveId)
				if request.Save then
					handle.HistoryVersions:set(nil)
				end
				openMove(entry)
			end
		end
		local count = #answer.Entries
		local verb = if request.Save then "Scaled and saved" else "Scaled"
		local tail = if answer.Reason then `, but not all: {Copy.Failure(answer.Reason).Message}` else "."
		handle.StatusText:set(`{verb} {count} move{if count == 1 then "" else "s"}{tail}`)
	end)

	-- Test ---------------------------------------------------------------------------------------------

	local lastTest: { MoveId: string, At: number }? = nil
	-- When the tested move's swing actually started on the server, for the hit log's timing.
	local swingStartedAt: number? = nil

	local function test(): ()
		local moveId = peek(handle.SelectedId)
		if not moveId then
			return
		end
		flush()
		local ok, result = invoke(names.TestFire, moveId)
		local answer = if ok then result :: MoveEditorTypes.ActionResult else nil
		if not answer or not answer.Success then
			report("Test refused", if answer then answer.Reason else nil)
			return
		end
		lastTest = { MoveId = moveId, At = os.clock() }
		swingStartedAt = nil
		handle.StatusText:set("Thrown -- nothing landed yet.")
	end
	handle.TestRequested:Connect(test)

	AttackInputClient.OnAttackStarted(function(payload)
		local pending = lastTest
		if pending and payload.MoveId == pending.MoveId then
			swingStartedAt = os.clock()
		end
	end)

	local function logHit(feedback: DamageTypes.CombatFeedback): ()
		local startedAt = swingStartedAt or (lastTest and lastTest.At) or os.clock()
		local entry: MoveEditorScreenTypes.HitLogEntry = {
			MoveId = feedback.MoveId,
			Kind = tostring(feedback.Kind),
			Damage = feedback.Damage,
			GuardDrain = feedback.GuardDrain,
			ComboStage = feedback.ComboStage,
			SinceSwing = os.clock() - startedAt,
			Target = if typeof(feedback.Defender) == "Instance" then feedback.Defender.Name else "?",
		}
		local log = { entry }
		for _, existing in ipairs(peek(handle.HitLog)) do
			if #log >= HIT_LOG_CAPACITY then
				break
			end
			table.insert(log, existing)
		end
		handle.HitLog:set(log)
	end

	handle.ClearHitLogRequested:Connect(function()
		handle.HitLog:set({})
	end)

	NetworkBridge.GetRemoteEvent(DamageConstants.Network.RemoteNames.Feedback).OnClientEvent
		:Connect(function(raw: unknown)
			local pending = lastTest
			if not pending or typeof(raw) ~= "table" or os.clock() - pending.At > TEST_REPORT_WINDOW_SECONDS then
				return
			end
			local feedback = raw :: DamageTypes.CombatFeedback
			if feedback.Role ~= "Attacker" or feedback.MoveId ~= pending.MoveId then
				return
			end
			logHit(feedback)
			handle.StatusText:set(
				string.format(
					"Landed: %s -- %.0f damage, %.0f guard",
					tostring(feedback.Kind),
					feedback.Damage,
					feedback.GuardDrain
				)
			)
		end)

	-- Hotbar -------------------------------------------------------------------------------------------

	handle.HotbarBindings:set(HotbarBindings.GetAll())
	HotbarBindings.OnChanged(function()
		handle.HotbarBindings:set(HotbarBindings.GetAll())
	end)

	handle.BindSlotRequested:Connect(function(slot: number)
		local moveId = peek(handle.SelectedId)
		if not moveId then
			return
		end
		flush()
		-- Pressing the slot the art already holds clears it.
		local target: string? = if peek(handle.HotbarBindings)[slot] == moveId then nil else moveId
		local ok, result = invoke(names.EquipArtSlot, slot, target)
		local answer = if ok then result :: MoveEditorTypes.ActionResult else nil
		if not answer or not answer.Success then
			report("Not bound", if answer then answer.Reason else nil)
			return
		end
		handle.StatusText:set(if target then `Bound to slot {slot}.` else `Slot {slot} cleared.`)
	end)

	-- The bench: the Dev Menu's own dummy and volume visualiser, reused rather than duplicated. -------

	handle.SpawnDummyRequested:Connect(function()
		RemoteInvoker.InvokeAndReport(
			function(status: string)
				handle.StatusText:set(status)
			end,
			NetworkBridge.GetRemoteFunction(DEV_MENU_REMOTES.SpawnDummy),
			{},
			function(result: unknown)
				local answer = result :: MoveEditorTypes.ActionResult
				return if typeof(result) == "table" and answer.Success
					then "Dummy spawned in front of you."
					else `Dummy refused: {if typeof(result) == "table" then answer.Reason else "unknown"}`
			end
		)
	end)

	local function benchStatus(action: string, ok: boolean, result: any, success: string): ()
		if ok and typeof(result) == "table" and result.Success then
			handle.StatusText:set(success)
		else
			local reason = if typeof(result) == "table" then result.Reason else nil
			handle.StatusText:set(`{action} refused: {Copy.Failure(reason).Message}`)
		end
	end

	handle.DummyGuardToggled:Connect(function(enabled: boolean)
		local ok, result = invoke(DEV_MENU_REMOTES.SetDummyGuard, enabled)
		if ok and typeof(result) == "table" and result.Success then
			handle.DummyGuard:set(result.GuardEnabled == true)
			handle.StatusText:set(
				if result.GuardEnabled then "Dummies are guarding." else "Dummies dropped their guard."
			)
		else
			benchStatus("Dummy guard", ok, result, "")
		end
	end)

	handle.SpawnBotRequested:Connect(function()
		local style, difficulty = peek(handle.BotStyle), peek(handle.BotDifficulty)
		local ok, result = invoke(DEV_MENU_REMOTES.SpawnTrainingBot, style, difficulty, nil)
		benchStatus("Bot", ok, result, `{difficulty} {style} bot spawned in front of you.`)
	end)

	-- Both kinds at once: a bench is cleared to start the next test from nothing.
	handle.ClearBenchRequested:Connect(function()
		local dummiesOk, dummies = invoke(DEV_MENU_REMOTES.DespawnAllDebugDummies)
		local botsOk, bots = invoke(DEV_MENU_REMOTES.DespawnTrainingBots)
		if not (dummiesOk and typeof(dummies) == "table" and dummies.Success) then
			benchStatus("Clear dummies", dummiesOk, dummies, "")
		elseif not (botsOk and typeof(bots) == "table" and bots.Success) then
			benchStatus("Clear bots", botsOk, bots, "")
		else
			handle.StatusText:set("Bench cleared: no dummies, no bots.")
		end
	end)

	handle.VolumesToggled:Connect(function(visible: boolean)
		local ok, result = invoke(DEV_MENU_REMOTES.SetHitboxDebug, visible)
		if ok and typeof(result) == "table" and result.Success then
			handle.VolumesVisible:set(result.Enabled == true)
		else
			handle.StatusText:set("The volume visualiser did not change.")
		end
	end)

	-- Clip scrub and asset previews -------------------------------------------------------------------

	local previews = ClipScrubber.Start(handle)
	handle.PreviewAssetRequested:Connect(function(kind: string, id: string)
		if kind == "Animation" then
			handle.StatusText:set(previews.PreviewAnimation(id))
		elseif kind == "Sound" then
			handle.StatusText:set(previews.PreviewSound(id))
		end
	end)

	-- Keys -------------------------------------------------------------------------------------------

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed or (input == skipInput and os.clock() < skipUntil) then
			return
		end
		if KeybindManager.Matches("OpenMoveEditor", input) then
			if peek(handle.IsOpen) then
				requestClose()
			else
				setOpen(true)
			end
			return
		end
		if not peek(handle.IsOpen) then
			return
		end
		-- Up / Down step through the move list. Not while typing (a focused box is gameProcessed above, and a
		-- NumericField's open entry box uses the same keys to nudge its number), and not in Place mode.
		if not modifierDown() then
			if peek(handle.PlacementMode) then
				return
			end
			if input.KeyCode == Enum.KeyCode.Up then
				handle.StepSelection(-1)
			elseif input.KeyCode == Enum.KeyCode.Down then
				handle.StepSelection(1)
			end
			return
		end
		-- Ctrl+F finds a move: it takes you to the browser's filter.
		if input.KeyCode == Enum.KeyCode.F then
			handle.FocusFilter()
			return
		end
		-- A focused text field keeps its own native undo; gameProcessed already covers most of these, this
		-- covers the rest.
		if UserInputService:GetFocusedTextBox() then
			return
		end
		local shiftDown = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
			or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
		if input.KeyCode == Enum.KeyCode.Z then
			if shiftDown then
				handle.Redo()
			else
				handle.Undo()
			end
		elseif input.KeyCode == Enum.KeyCode.Y then
			handle.Redo()
		elseif input.KeyCode == Enum.KeyCode.S then
			save()
		elseif input.KeyCode == Enum.KeyCode.D then
			duplicate()
		elseif input.KeyCode == Enum.KeyCode.T then
			test()
		end
	end)

	logger:info("MoveEditorClient started", { moves = #initial })
	return setOpen
end

function MoveEditorClient.Start(deferredHandle: Lazy.Lazy<MoveEditorHandle>, chrome: Chrome.ChromeHandle): ()
	task.spawn(function()
		-- Resolved inside the protected call: GetRemoteFunction asserts on a missing remote, and an
		-- assert here would be a thrown error on the path that only decides whether this client is an
		-- admin at all.
		local ok, result = pcall(function()
			return NetworkBridge.GetRemoteFunction(Config.RemoteNames.Open):InvokeServer()
		end)
		local answer = if ok then result :: MoveEditorTypes.OpenResult? else nil
		if not answer or answer.Success ~= true then
			logger:debug("Move Editor not started: this client is not authorized")
			return
		end
		-- Authorized: bind the key and build NOTHING yet (this file's header).
		local entries = answer.Entries or {}
		local connection: RBXScriptConnection? = nil
		connection = UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
			if gameProcessed or not KeybindManager.Matches("OpenMoveEditor", input) then
				return
			end
			local waiting = connection
			connection = nil
			if waiting == nil then
				return
			end
			waiting:Disconnect()
			local setOpen = startEditor(deferredHandle.Get(), chrome, entries, input)
			setOpen(true)
		end)
	end)
end

return MoveEditorClient
