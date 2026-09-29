--!strict
--[[
	MoveEditorClient.lua

	Owns: driving the Move Editor screen (UI/Screens/DevTools/MoveEditor) from outside -- the open key,
	authorization, and every signal on its handle turned into a Constants.MoveEditor.RemoteNames call,
	with the server's answer written back into the handle's Values.

	AUTHORIZATION IS THE FIRST Open. There is no "am I an admin" remote: Open is admin-gated, so a client
	whose first Open is refused is simply not an admin, and this module never builds the screen (the
	Lazy is never forced, so a player's client does not even mount it).

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
local Copy = require(script.Parent.Parent.Parent.UI.Screens.DevTools.MoveEditor.Copy)
local HotbarBindings = require(script.Parent.Parent.Parent.Combat.HotbarBindings)
local KeybindManager = require(script.Parent.Parent.Parent.Input.KeybindManager)
local MoveEditorScreenTypes = require(script.Parent.Parent.Parent.UI.Screens.DevTools.MoveEditor.Types)
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

local function startEditor(handle: MoveEditorHandle, chrome: Chrome.ChromeHandle, initial: { MoveEntry }): ()
	handle.Entries:set(initial)
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
		if failure.Tab then
			handle.CurrentTab:set(failure.Tab)
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
		handle.CurrentTab:set("Identity")
		handle.StatusText:set(`{entry.Move.DisplayName} created -- live, not saved yet.`)
	end

	handle.NewRequested:Connect(function()
		create(newMoveDraft(), "create the move")
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

	-- Keys -------------------------------------------------------------------------------------------

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
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
		-- Editor-scoped: Ctrl+S must not save from anywhere in the game.
		if not peek(handle.IsOpen) or not modifierDown() then
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
		startEditor(deferredHandle.Get(), chrome, answer.Entries or {})
	end)
end

return MoveEditorClient
