--!strict
--[[
	WorldArchitectClient.lua

	Owns: the local admin's World Architect -- the authorization probe and the OpenWorldArchitect key, opening and
	closing the console, the mirror of the server's world (kept in step by WorldArchitect_Delta pushes, re-synced on any
	gap), and turning every Intent the console and the viewport fire into a WorldArchitect_* request and its result into
	what the console shows.

	THE SERVER DECIDES EVERYTHING. Every edit here is a REQUEST carrying the revisions this mirror holds; the mirror itself
	only changes when the server pushes a delta, so what the admin sees is what the server accepted. A refusal comes back
	as a reason and is shown in plain words (REASON_TEXT), never swallowed.

	PURE TRANSFORMS, SHARED. Align, distribute, mirror, scale, array and the gizmo's results are computed with
	Shared/WorldArchitect/ArchitectTransform -- the same module the server's own expansions use -- and sent as ordinary
	Update / Create requests the server validates like any other.

	Does not own: authorization (WorldArchitectSystem re-checks every request), the panels (UI/Screens/DevTools/
	WorldArchitect), or the 3D interaction (EditorViewport).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Lazy = require(ReplicatedStorage.Shared.Lazy)
local Logger = require(ReplicatedStorage.Shared.Logger)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local ArchitectConstants = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectConstants)
local ArchitectRecord = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectRecord)
local ArchitectTransform = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectTransform)
local StarterTemplates = require(ReplicatedStorage.Shared.WorldArchitect.StarterTemplates)

local WorldArchitectModule = require(script.Parent.Parent.Parent.UI.Screens.DevTools.WorldArchitect)
local WorldArchitectTypes = require(script.Parent.Parent.Parent.UI.Screens.DevTools.WorldArchitect.Types)
local InputRouter = require(script.Parent.Parent.Parent.Input.InputRouter)
local Chrome = require(script.Parent.Parent.Parent.UI.Shell.Chrome)
local RemoteInvoker = require(script.Parent.Parent.Parent.Network.RemoteInvoker)
local EditorViewport = require(script.Parent.EditorViewport)

type Handle = WorldArchitectTypes.Handle
type NodeRecord = ArchitectRecord.NodeRecord
type Result = { [string]: any }

local peek = Fusion.peek
local Names = ArchitectConstants.RemoteNames
local Limits = ArchitectConstants.Limits

local logger = Logger.scope("WorldArchitectClient")

local WorldArchitectClient = {}

local REASON_TEXT: { [string]: string } = {
	NotAuthorized = "Not authorized.",
	RateLimited = "Too many requests; slow down a moment.",
	Loading = "The server is still loading the Live world.",
	Busy = "Another save or load is in progress.",
	StaleNode = "Someone changed that first. Your view is up to date now; try again.",
	UndoConflict = "Can't undo: another edit has changed those nodes since. That step was dropped.",
	RedoConflict = "Can't redo: those nodes have changed since. That step was dropped.",
	ProtectedArea = "Refused: that would intrude on a protected area (a spawn or a tagged zone).",
	OutOfBounds = "Refused: outside the buildable world bounds.",
	InvalidSize = "Refused: a part size is outside the limits.",
	Locked = "Refused: something in the selection is locked.",
	WorldFull = `Refused: the world would exceed {Limits.MaxNodes} nodes.`,
	TooManyNodes = "Refused: too many nodes in one operation.",
	TooDeep = `Refused: groups may nest at most {Limits.MaxDepth} deep.`,
	NestedTargets = "Refused: the selection contains a group and something inside it.",
	NotAGroup = "Ungroup needs a group selected.",
	NothingToUndo = "Nothing to undo.",
	NothingToRedo = "Nothing to redo.",
	NothingPlaced = "The layout placed nothing. Widen the area or lower the spacing.",
	NothingToApply = "Nothing to apply.",
	UnknownTemplate = "That template no longer exists.",
	StorageUnavailable = "Storage is unavailable on this server; nothing can be saved.",
	StorageError = "The save store did not answer. Nothing was changed; try again.",
	EmptySlot = "That slot has no saves.",
	WorldTooLarge = "That world is larger than the save limit.",
	TerrainLogFull = "The terrain stroke log is full.",
	CannotDeleteLive = "The Live slot cannot be deleted.",
	LibraryFull = "The template library is full.",
	TemplateTooLarge = `A template holds at most {Limits.MaxTemplateNodes} nodes.`,
	InternalError = "The server hit an error handling that. It has been logged.",
}

local function explain(reason: string?): string
	if reason == nil then
		return "Refused."
	end
	return REASON_TEXT[reason] or REASON_TEXT[string.match(reason, "^(%w+)") or ""] or `Refused: {reason}`
end

local function startEditor(handle: Handle, chrome: Chrome.ChromeHandle, templates: { any }): ()
	handle.Templates:set(templates)

	local remotes: { [string]: RemoteFunction } = {}
	local function remote(key: string): RemoteFunction
		local found = remotes[key]
		if found == nil then
			found = NetworkBridge.GetRemoteFunction((Names :: any)[key])
			remotes[key] = found
		end
		return found
	end

	local function say(text: string, tone: WorldArchitectTypes.Tone?): ()
		handle.Message:set(text)
		handle.Tone:set(tone or "Info")
	end

	-- One request; nil (with the reason shown) on any failure.
	local function request(key: string, ...: any): Result?
		local ok, result = RemoteInvoker.Invoke(remote(key), ...)
		if not ok then
			say("The request failed to reach the server.", "Bad")
			logger:warn("Request errored", { remote = key, errorMessage = tostring(result) })
			return nil
		end
		local answer = result :: Result?
		if answer == nil then
			say("No answer from the server.", "Bad")
			return nil
		end
		-- Only the history-bearing remotes answer with the labels (a refused undo too: its entry was dropped).
		if key == "Edit" or key == "Undo" or key == "Redo" or key == "Terrain" then
			if answer.Success or key ~= "Edit" then
				handle.UndoLabel:set(answer.Undo)
				handle.RedoLabel:set(answer.Redo)
			end
		end
		if answer.Status then
			handle.Server:set(answer.Status)
		end
		if not answer.Success then
			say(explain(answer.Reason), if answer.Reason == "StaleNode" then "Warn" else "Bad")
			return nil
		end
		return answer
	end

	--
	-- The mirror
	--
	local records: { [string]: NodeRecord } = {}
	local revision = -1
	local viewport: EditorViewport.Session? = nil
	local resyncing = false

	local function publishRecords()
		handle.Records:set(table.clone(records))
		-- Drop selected / hidden ids that no longer exist.
		local selection = peek(handle.Selection)
		local kept: { string } = {}
		for _, id in selection do
			if records[id] then
				table.insert(kept, id)
			end
		end
		if #kept ~= #selection then
			handle.Selection:set(kept)
		end
	end

	local function resync(): ()
		if resyncing then
			return
		end
		resyncing = true
		local opened = request("Open")
		if opened then
			table.clear(records)
			for _, record in opened.Records do
				records[record.Id] = record
			end
			for page = 2, opened.Pages do
				local more = request("Page", page)
				if more then
					for _, record in more.Records do
						records[record.Id] = record
					end
				end
			end
			revision = opened.Revision
			handle.Templates:set(opened.Templates)
			handle.UndoLabel:set(opened.Undo)
			handle.RedoLabel:set(opened.Redo)
			publishRecords()
		end
		resyncing = false
	end

	local deltaRemote = NetworkBridge.GetRemoteEvent(Names.Delta)
	deltaRemote.OnClientEvent:Connect(function(payload: { [string]: any })
		if not peek(handle.IsOpen) then
			return
		end
		if payload.Status then
			handle.Server:set(payload.Status)
		end
		local localName = Players.LocalPlayer.Name
		if payload.By and payload.By ~= localName and payload.Label then
			say(`{payload.By}: {payload.Label}`, "Info")
		end
		if payload.Reset then
			say(`World replaced: {payload.Label or "load"}. History cleared.`, "Warn")
			handle.UndoLabel:set(nil)
			handle.RedoLabel:set(nil)
			task.spawn(resync)
			return
		end
		if payload.StatusOnly or resyncing then
			-- A delta that lands mid-resync is covered by the snapshot or caught by the next delta's gap check.
			return
		end
		-- Revisions advance by exactly one per transaction; a gap means something was missed, so re-read the whole
		-- world rather than guess. A transaction's pages arrive back to back, so only its first page is checked.
		if payload.Page == 1 and revision >= 0 and payload.Revision ~= revision + 1 then
			task.spawn(resync)
			return
		end
		for _, id in payload.Removes do
			records[id] = nil
		end
		for _, record in payload.Upserts do
			records[record.Id] = record
		end
		if payload.Page == payload.Pages then
			revision = payload.Revision
			publishRecords()
		end
	end)

	--
	-- Helpers over the mirror
	--
	local function selected(): { NodeRecord }
		local out: { NodeRecord } = {}
		for _, id in peek(handle.Selection) do
			if records[id] then
				table.insert(out, records[id])
			end
		end
		return out
	end

	local function targets(list: { NodeRecord }): { { Id: string, Rev: number } }
		local out = {}
		for _, record in list do
			table.insert(out, { Id = record.Id, Rev = record.Rev })
		end
		return out
	end

	-- Update requests for every record in `changed` whose transform differs from the mirror's.
	local function sendTransforms(changed: { NodeRecord }, label: string): Result?
		local changes = {}
		for _, record in changed do
			local current = records[record.Id]
			if current then
				local patch: { [string]: any } = {}
				if current.Position ~= record.Position then
					patch.Position = record.Position
				end
				if current.Orientation ~= record.Orientation then
					patch.Orientation = record.Orientation
				end
				if current.Kind == "Part" and current.Size ~= record.Size then
					patch.Size = record.Size
				end
				if next(patch) then
					table.insert(changes, { Id = current.Id, Rev = current.Rev, Patch = patch })
				end
			end
		end
		if #changes == 0 then
			return nil
		end
		if #changes > Limits.MaxNodesPerRequest then
			say(explain("TooManyNodes"), "Bad")
			return nil
		end
		local result = request("Edit", { Kind = "Update", Changes = changes, Label = label })
		if result then
			say(`{label}: {#changes} nodes.`, "Good")
		end
		return result
	end

	-- Create requests copying `list` (a selection with its descendants), each moved through `map`.
	local function sendCopies(
		list: { NodeRecord },
		map: (NodeRecord) -> NodeRecord,
		label: string,
		copies: number?
	): Result?
		local inSet: { [string]: boolean } = {}
		for _, record in list do
			inSet[record.Id] = true
		end
		local nodes = {}
		for copy = 1, copies or 1 do
			for _, record in list do
				local moved = map(record)
				local node = table.clone(moved) :: any
				node.Locked = false
				table.insert(nodes, {
					Ref = `{copy}_{record.Id}`,
					ParentRef = if record.Parent and inSet[record.Parent]
						then `{copy}_{record.Parent}`
						else record.Parent,
					Node = node,
				})
			end
		end
		if #nodes > Limits.MaxNodesPerRequest then
			say(explain("TooManyNodes"), "Bad")
			return nil
		end
		local result = request("Edit", { Kind = "Create", Nodes = nodes, Label = label })
		if result then
			handle.Selection:set(result.Created or {})
			say(`{label}: {#nodes} nodes.`, "Good")
		end
		return result
	end

	local function topLevelItems(): { { NodeRecord } }
		local items = {}
		for _, id in peek(handle.Selection) do
			table.insert(items, WorldArchitectTypes.WithDescendants(records, { id }))
		end
		return items
	end

	local function fetchTemplate(id: string): ()
		if StarterTemplates.Get(id) or WorldArchitectTypes.IsPrimitive(id) or peek(handle.TemplateCache)[id] then
			return
		end
		local result = request("Template", { Kind = "Get", Id = id })
		if result and result.Template then
			local cache = table.clone(peek(handle.TemplateCache))
			cache[id] = result.Template
			handle.TemplateCache:set(cache)
		end
	end

	local function remember(asset: string)
		local recent = { asset }
		for _, key in peek(handle.Recent) do
			if key ~= asset and #recent < ArchitectConstants.Editor.RecentCount then
				table.insert(recent, key)
			end
		end
		handle.Recent:set(recent)
	end

	local function setTemplates(result: Result?)
		if result and result.Templates then
			handle.Templates:set(result.Templates)
			-- A rename or overwrite changed the nodes: forget the cached copy.
			handle.TemplateCache:set({})
		end
	end

	local previewConfig: { [string]: any }? = nil

	local function clearPreview()
		previewConfig = nil
		handle.GenerationPreview:set(nil)
		if viewport then
			(viewport :: EditorViewport.Session).ShowGeneration(nil)
		end
	end

	local function analyze()
		local result = request("Analyze")
		if result then
			handle.Report:set(result.Report)
			local included: { [string]: boolean } = {}
			for _, finding in result.Report.Findings do
				if (finding.SafeCount or 0) > 0 then
					included[finding.Id] = true
				end
			end
			handle.PreviewFindings:set(included)
			say(
				`Analysis: {#result.Report.Findings} findings, {result.Report.SafeChanges} safe changes proposed.`,
				"Info"
			)
		end
	end

	local function listSlots()
		local result = request("World", { Kind = "ListSlots" })
		if result then
			handle.Slots:set(result.Slots)
		end
	end

	--
	-- Intents
	--
	local handlers: { [string]: (intent: { [string]: any }) -> () } = {}

	handlers.SetTool = function(intent)
		local tool = intent.Tool :: WorldArchitectTypes.Tool
		if tool == "Place" and peek(handle.ActiveAsset) == nil then
			handle.LeftTab:set("Assets")
			handle.LeftOpen:set(true)
			say("Pick an asset to place: click it twice in Assets.", "Info")
		end
		if tool == "Terrain" then
			handle.RightTab:set("Terrain")
			handle.RightOpen:set(true)
		end
		handle.Tool:set(tool)
	end

	handlers.FocusAsset = function(intent)
		handle.FocusedAsset:set(intent.Asset)
		fetchTemplate(intent.Asset)
	end

	handlers.BeginPlace = function(intent)
		handle.FocusedAsset:set(intent.Asset)
		fetchTemplate(intent.Asset)
		handle.ActiveAsset:set(intent.Asset)
		handle.Tool:set("Place")
		say("Click to place. R turns it; Escape stops placing.", "Info")
	end

	handlers.ToggleFavorite = function(intent)
		local favorites = table.clone(peek(handle.Favorites))
		favorites[intent.Asset] = not favorites[intent.Asset] or nil
		handle.Favorites:set(favorites)
	end

	handlers.PlaceAt = function(intent)
		local asset = peek(handle.ActiveAsset)
		if asset == nil then
			return
		end
		local pivot = intent.Pivot :: CFrame
		local result: Result?
		if WorldArchitectTypes.IsPrimitive(asset) then
			local assetRecords = WorldArchitectTypes.AssetRecords(asset, {}) :: { NodeRecord }
			local placed = ArchitectTransform.TransformSet(assetRecords, CFrame.identity, pivot)[1]
			result = request("Edit", {
				Kind = "Create",
				Label = `Place {placed.Shape}`,
				Nodes = { { Ref = "p", Node = placed } },
			})
		else
			local _, yaw = pivot:ToOrientation()
			result = request("Edit", {
				Kind = "PlaceTemplate",
				TemplateId = asset,
				Position = pivot.Position,
				Yaw = math.deg(yaw),
			})
		end
		if result then
			remember(asset)
			handle.Selection:set(result.Created or {})
			say("Placed.", "Good")
		end
	end

	handlers.Pick = function(intent)
		local id = if intent.Deep then intent.Id else WorldArchitectTypes.TopOf(records, intent.Id)
		local selection = peek(handle.Selection)
		if intent.Additive then
			local copy = table.clone(selection)
			local index = table.find(copy, id)
			if index then
				table.remove(copy, index)
			else
				table.insert(copy, id)
			end
			handle.Selection:set(copy)
		else
			handle.Selection:set({ id })
		end
		if peek(handle.Tool) == "Select" or peek(handle.Tool) == "Place" or peek(handle.Tool) == "Terrain" then
			handle.RightTab:set("Inspect")
		end
		-- Picking a part selected its whole group: say how to reach the piece itself, since that is what a Scale or
		-- Rotate would otherwise surprise you with.
		local picked = records[id]
		if picked and picked.Kind == "Group" and not intent.Deep and not intent.Additive then
			say(
				`Selected all of {picked.Name}. To change one piece: double-click it, Alt-click it, or turn on PICK PART (P).`,
				"Info"
			)
		elseif picked and intent.Deep and records[intent.Id] and records[intent.Id].Parent then
			say(`Selected {picked.Name} on its own. Scale and Rotate now change only this piece.`, "Info")
		end
	end

	handlers.ToggleDeepPick = function()
		local on = not peek(handle.DeepPick)
		handle.DeepPick:set(on)
		say(
			if on
				then "PICK PART on: clicks select the single piece under the cursor (Alt-click selects the whole item)."
				else "PICK PART off: clicks select the whole placed item (Alt-click or double-click selects one piece).",
			"Info"
		)
	end

	handlers.SelectFromList = function(intent)
		handlers.Pick({ Id = intent.Id, Additive = intent.Additive, Deep = true })
	end

	handlers.SelectAll = function()
		local roots: { string } = {}
		for id, record in records do
			if record.Parent == nil or records[record.Parent] == nil then
				table.insert(roots, id)
			end
		end
		table.sort(roots)
		handle.Selection:set(roots)
	end

	handlers.Deselect = function()
		handle.Selection:set({})
	end

	handlers.TransformCommit = function(intent)
		local result = sendTransforms(intent.Records, `{intent.Label or "Transform"}`)
		if viewport then
			-- Refused (stale, locked, protected...): the dragged parts go back to where they were.
			(viewport :: EditorViewport.Session).EndPending(result ~= nil)
		end
	end

	handlers.Patch = function(intent)
		local patch = intent.Patch :: { [string]: any }
		local changes = {}
		for _, record in selected() do
			local applied: { [string]: any } = {}
			for field, value in patch do
				-- A group takes only what a group has.
				if record.Kind == "Part" or field == "Name" or field == "Locked" then
					applied[field] = value
				end
			end
			if next(applied) then
				table.insert(changes, { Id = record.Id, Rev = record.Rev, Patch = applied })
			end
		end
		if #changes > 0 and request("Edit", { Kind = "Update", Changes = changes, Label = "Edit" }) then
			say(`Updated {#changes} nodes.`, "Good")
		end
	end

	handlers.SetRole = function(intent)
		local flags = ArchitectRecord.RoleFlags(intent.Role)
		handlers.Patch({
			Patch = {
				Role = intent.Role,
				Anchored = flags.Anchored,
				CanCollide = flags.CanCollide,
				CanTouch = flags.CanTouch,
				CanQuery = flags.CanQuery,
			},
		})
	end

	handlers.SetAxis = function(intent)
		local list = selected()
		local primary = list[1]
		if primary == nil then
			return
		end
		local field, axis, value = intent.Field, intent.Axis, intent.Value :: number
		local function with(v: Vector3): Vector3
			return Vector3.new(
				if axis == "X" then value else v.X,
				if axis == "Y" then value else v.Y,
				if axis == "Z" then value else v.Z
			)
		end
		if field == "Position" then
			local offset = with(primary.Position) - primary.Position
			local moved = ArchitectTransform.Translate(
				WorldArchitectTypes.WithDescendants(records, peek(handle.Selection)),
				offset
			)
			sendTransforms(moved, "Move")
		elseif field == "Orientation" then
			-- Each selected item turns about its own pivot to the new orientation; its contents turn with it.
			local out: { NodeRecord } = {}
			for _, item in list do
				local from = ArchitectRecord.CFrameOf(item)
				local o = with(item.Orientation)
				local to = CFrame.new(item.Position)
					* CFrame.fromOrientation(math.rad(o.X), math.rad(o.Y), math.rad(o.Z))
				for _, record in
					ArchitectTransform.TransformSet(WorldArchitectTypes.WithDescendants(records, { item.Id }), from, to)
				do
					table.insert(out, record)
				end
			end
			sendTransforms(out, "Rotate")
		elseif field == "Size" then
			local out: { NodeRecord } = {}
			for _, record in list do
				if record.Kind == "Part" then
					local copy = table.clone(record)
					copy.Size = with(record.Size)
					table.insert(out, copy)
				end
			end
			sendTransforms(out, "Resize")
		end
	end

	handlers.Turn = function(intent)
		local list = WorldArchitectTypes.WithDescendants(records, peek(handle.Selection))
		if #list == 0 then
			return
		end
		local pivot = ArchitectTransform.PivotOf(list)
		sendTransforms(ArchitectTransform.RotateAbout(list, pivot, Vector3.yAxis, intent.Degrees), "Turn")
	end

	handlers.Duplicate = function()
		local list = WorldArchitectTypes.WithDescendants(records, peek(handle.Selection))
		if #list == 0 then
			return
		end
		local low, high = ArchitectTransform.Bounds(list)
		local grid = math.max(peek(handle.Grid), 1)
		local width = if low and high then (high - low).X else 4
		local offset = Vector3.new(ArchitectTransform.Snap(width, grid) + grid, 0, 0)
		sendCopies(list, function(record)
			local copy = table.clone(record)
			copy.Position += offset
			return copy
		end, "Duplicate")
	end

	handlers.Mirror = function(intent)
		local list = WorldArchitectTypes.WithDescendants(records, peek(handle.Selection))
		local low, high = ArchitectTransform.Bounds(list)
		if low == nil or high == nil then
			return
		end
		local axis = intent.Axis :: ArchitectTransform.Axis
		-- The mirror plane is the selection's far face, so the copy lands beside it, not inside it.
		local plane = if axis == "X" then Vector3.new(high.X, 0, 0) else Vector3.new(0, 0, high.Z)
		sendCopies(list, function(record)
			return ArchitectTransform.Mirror(record, plane, axis)
		end, `Mirror {axis}`)
	end

	handlers.Array = function(intent)
		local list = WorldArchitectTypes.WithDescendants(records, peek(handle.Selection))
		if #list == 0 then
			return
		end
		local offsets = ArchitectTransform.ArrayOffsets(intent.Count, intent.Offset)
		local nodes = {}
		local inSet: { [string]: boolean } = {}
		for _, record in list do
			inSet[record.Id] = true
		end
		for copy, offset in offsets do
			for _, record in list do
				local node = table.clone(record) :: any
				node.Position += offset
				node.Locked = false
				table.insert(nodes, {
					Ref = `{copy}_{record.Id}`,
					ParentRef = if record.Parent and inSet[record.Parent]
						then `{copy}_{record.Parent}`
						else record.Parent,
					Node = node,
				})
			end
		end
		if #nodes > Limits.MaxNodesPerRequest then
			say(explain("TooManyNodes"), "Bad")
			return
		end
		local result = request("Edit", { Kind = "Create", Nodes = nodes, Label = "Array" })
		if result then
			say(`Array: {#offsets} copies, {#nodes} nodes.`, "Good")
		end
	end

	handlers.ScaleSet = function(intent)
		local list = WorldArchitectTypes.WithDescendants(records, peek(handle.Selection))
		if #list == 0 then
			return
		end
		sendTransforms(ArchitectTransform.ScaleSet(list, ArchitectTransform.PivotOf(list), intent.Factor), "Scale")
	end

	handlers.Align = function(intent)
		sendTransforms(ArchitectTransform.Align(topLevelItems(), intent.Axis, intent.Mode), "Align")
	end

	handlers.Distribute = function(intent)
		sendTransforms(ArchitectTransform.Distribute(topLevelItems(), intent.Axis), "Distribute")
	end

	handlers.Delete = function()
		local list = selected()
		if #list == 0 then
			return
		end
		local result = request("Edit", { Kind = "Delete", Targets = targets(list) })
		if result then
			handle.Selection:set({})
			say(`Deleted. Ctrl+Z restores it.`, "Good")
		end
	end

	handlers.Group = function()
		local list = selected()
		if #list == 0 then
			return
		end
		local result = request("Edit", { Kind = "Group", Targets = targets(list), Name = "Group" })
		if result then
			handle.Selection:set(result.Created or {})
			say("Grouped.", "Good")
		end
	end

	handlers.Ungroup = function()
		for _, record in selected() do
			if record.Kind == "Group" then
				if request("Edit", { Kind = "Ungroup", Target = { Id = record.Id, Rev = record.Rev } }) then
					handle.Selection:set({})
					say("Ungrouped.", "Good")
				end
				return
			end
		end
		say(explain("NotAGroup"), "Warn")
	end

	handlers.SetLocked = function(intent)
		local ids = intent.Ids or peek(handle.Selection)
		local changes = {}
		for _, id in ids do
			local record = records[id]
			if record and record.Locked ~= intent.Locked then
				table.insert(changes, { Id = id, Rev = record.Rev, Patch = { Locked = intent.Locked } })
			end
		end
		if
			#changes > 0
			and request(
				"Edit",
				{ Kind = "Update", Changes = changes, Label = if intent.Locked then "Lock" else "Unlock" }
			)
		then
			say(if intent.Locked then `Locked {#changes}.` else `Unlocked {#changes}.`, "Good")
		end
	end

	handlers.SetHidden = function(intent)
		local ids = intent.Ids or peek(handle.Selection)
		local hidden = table.clone(peek(handle.Hidden))
		for _, id in ids do
			hidden[id] = if intent.Hidden then true else nil
		end
		handle.Hidden:set(hidden)
		if intent.Hidden then
			handle.Selection:set({})
		end
	end

	handlers.ShowAll = function()
		handle.Hidden:set({})
	end

	handlers.Focus = function()
		local list = WorldArchitectTypes.WithDescendants(records, peek(handle.Selection))
		local low, high = ArchitectTransform.Bounds(list)
		if viewport and low and high then
			(viewport :: EditorViewport.Session).FocusOn((low + high) / 2)
		end
	end

	handlers.Undo = function()
		local result = request("Undo")
		if result then
			say(`Undid {result.Label}.`, "Good")
		end
	end

	handlers.Redo = function()
		local result = request("Redo")
		if result then
			say(`Redid {result.Label}.`, "Good")
		end
	end

	local function templateRequest(fields: { [string]: any }, done: string)
		local result = request("Template", fields)
		setTemplates(result)
		if result then
			say(done, "Good")
			if result.Template then
				handle.FocusedAsset:set(result.Template.Id)
			end
		end
	end

	local function withMeta(base: { [string]: any }, meta: { [string]: any }): { [string]: any }
		for key, value in meta do
			base[key] = value
		end
		return base
	end

	handlers.SaveTemplate = function(intent)
		local list = selected()
		if #list == 0 then
			return
		end
		templateRequest(
			withMeta({ Kind = "Save", Targets = targets(list), ReplaceId = intent.ReplaceId }, intent.Meta),
			if intent.ReplaceId then "Template overwritten with the selection." else "Selection saved as a template."
		)
	end

	handlers.DuplicateTemplate = function(intent)
		templateRequest(withMeta({ Kind = "Duplicate", Id = intent.Id }, intent.Meta), "Template duplicated.")
	end

	handlers.RenameTemplate = function(intent)
		templateRequest(withMeta({ Kind = "Rename", Id = intent.Id }, intent.Meta), "Template updated.")
	end

	handlers.DeleteTemplate = function(intent)
		local result = request("Template", { Kind = "Delete", Id = intent.Id })
		setTemplates(result)
		if result then
			handle.FocusedAsset:set(nil)
			if peek(handle.ActiveAsset) == intent.Id then
				handle.ActiveAsset:set(nil)
			end
			say("Template deleted.", "Good")
		end
	end

	handlers.PreviewGeneration = function()
		local settings = peek(handle.Generation)
		local focus = if viewport then (viewport :: EditorViewport.Session).Focus() else Vector3.zero
		local config: { [string]: any } = {
			Type = settings.Type,
			Seed = settings.Seed,
			Center = Vector3.new(math.round(focus.X), math.round(focus.Y), math.round(focus.Z)),
			AreaX = settings.AreaX,
			AreaZ = settings.AreaZ,
			Yaw = settings.Yaw,
			Spacing = settings.Spacing,
			Density = settings.Density,
			RotationJitter = settings.RotationJitter,
			Pack = if settings.Pack == "" then nil else settings.Pack,
			Exclusions = {},
			FollowGround = settings.FollowGround,
			Faction = settings.Faction,
		}
		local result = request("Preview", config)
		if result == nil then
			clearPreview()
			return
		end
		previewConfig = config
		handle.GenerationPreview:set({
			Placed = #result.Placements,
			Requested = result.Requested,
			Refused = result.Refused,
			NodeCount = result.NodeCount,
			OverBudget = result.OverBudget,
		})
		if viewport then
			(viewport :: EditorViewport.Session).ShowGeneration({
				Placements = result.Placements,
				Corners = result.Corners,
			})
		end
		say(`Preview: {#result.Placements} placements (seed {config.Seed}). Commit to build it.`, "Info")
	end

	handlers.CancelPreview = function(intent)
		clearPreview()
		if not intent.Quiet then
			say("Preview cancelled. Nothing was built.", "Info")
		end
	end

	handlers.CommitGeneration = function()
		local config = previewConfig
		if config == nil then
			return
		end
		local result = request("Edit", { Kind = "Generate", Config = config })
		if result then
			clearPreview()
			handle.Selection:set(result.Created or {})
			say(`Generated {result.Placed} placements as one group. Ctrl+Z removes it.`, "Good")
		end
	end

	handlers.Analyze = function()
		analyze()
	end

	handlers.Optimize = function(intent)
		local ids: { string } = {}
		for id in peek(handle.PreviewFindings) do
			table.insert(ids, id)
		end
		if #ids == 0 then
			say("Include at least one finding.", "Warn")
			return
		end
		local result =
			request("Edit", { Kind = "Optimize", FindingIds = ids, IncludeDestructive = intent.IncludeDestructive })
		if result then
			say(`Optimized: {result.Changed} changed, {result.Deleted} deleted. Ctrl+Z reverts it all.`, "Good")
			analyze()
		end
	end

	handlers.Stroke = function(intent)
		local settings = peek(handle.Terrain)
		request("Terrain", {
			Mode = settings.Mode,
			Material = settings.Material,
			Radius = settings.Radius,
			Strength = settings.Strength,
			Center = intent.Center,
			Height = intent.Height,
		})
	end

	handlers.ListSlots = function()
		listSlots()
	end

	handlers.SaveSlot = function(intent)
		say(`Saving to {intent.Slot}...`, "Info")
		local result = request("World", { Kind = "Save", Slot = intent.Slot, Note = intent.Note })
		if result then
			say(`Saved to {intent.Slot} (#{result.Generation.Gen}, {result.Generation.Nodes} nodes).`, "Good")
			listSlots()
		end
	end

	handlers.LoadSlot = function(intent)
		say(`Loading {intent.Slot}...`, "Info")
		local result = request("World", { Kind = "Load", Slot = intent.Slot, Gen = intent.Gen })
		if result then
			local skipped = if (result.Skipped or 0) > 0 then ` {result.Skipped} invalid records were skipped.` else ""
			say(
				`Loaded {intent.Slot}. The previous world is in Autosave.{skipped}`,
				if skipped ~= "" then "Warn" else "Good"
			)
			handle.Selection:set({})
			listSlots()
		end
	end

	handlers.DeleteSlot = function(intent)
		if request("World", { Kind = "Delete", Slot = intent.Slot }) then
			say(`Deleted slot {intent.Slot}.`, "Good")
			listSlots()
		end
	end

	handle.Intent:Connect(function(intent: { [string]: any })
		local handler = handlers[intent.Kind]
		if handler == nil then
			logger:warn("Unhandled intent", { kind = tostring(intent.Kind) })
			return
		end
		handler(intent)
	end)

	--
	-- Open / close
	--
	local function close()
		if not peek(handle.IsOpen) then
			return
		end
		clearPreview()
		if viewport then
			(viewport :: EditorViewport.Session).Stop()
			viewport = nil
		end
		handle.IsOpen:set(false)
		task.spawn(request, "Close")
	end

	local function open()
		if peek(handle.IsOpen) then
			return
		end
		handle.IsOpen:set(true)
		say("Loading the world...", "Info")
		resync()
		local root = Workspace:WaitForChild(ArchitectConstants.RootFolderName, 10)
		if root == nil then
			say("The managed world folder did not replicate.", "Bad")
			return
		end
		if peek(handle.IsOpen) and viewport == nil then
			viewport = EditorViewport.Start(handle, root)
		end
		listSlots()
		say("World Architect open. 1-6 tools · right-drag orbit · WASDQE pan · F focus · Ctrl+Z undo.", "Info")
	end

	-- Escape peels one layer at a time: a drag, a generation preview, a placing or brushing tool, the selection, and
	-- only then the console itself.
	chrome:BindEscape("WorldArchitect", handle.IsOpen, function()
		if viewport and (viewport :: EditorViewport.Session).CancelDrag() then
			say("Transform cancelled.", "Info")
			return
		end
		if peek(handle.GenerationPreview) then
			handlers.CancelPreview({})
			return
		end
		local tool = peek(handle.Tool)
		if tool == "Place" or tool == "Terrain" then
			handle.Tool:set("Select")
			return
		end
		if #peek(handle.Selection) > 0 then
			handle.Selection:set({})
			return
		end
		close()
	end)

	InputRouter.Bind("OpenWorldArchitect", {
		Layer = "System",
		Began = function(gameProcessed: boolean)
			if gameProcessed then
				return
			end
			if peek(handle.IsOpen) then
				close()
			else
				task.spawn(open)
			end
		end,
	})
end

-- Asks the server whether this client may use the World Architect: Template List is admin-gated like every
-- WorldArchitect remote, so any refusal means "not an admin" and no key is bound.
local function requestAuthorization(): (boolean, { any }?)
	local ok, result = RemoteInvoker.Invoke(NetworkBridge.GetRemoteFunction(Names.Template), { Kind = "List" })
	if not ok or result == nil or (result :: Result).Success ~= true then
		return false, nil
	end
	return true, (result :: Result).Templates
end

-- Runs on its own thread: the authorization round trip yields. The screen is a Lazy thunk, forced only for an admin.
function WorldArchitectClient.Start(
	deferredHandle: Lazy.Lazy<WorldArchitectModule.WorldArchitectHandle>,
	chrome: Chrome.ChromeHandle
): ()
	task.spawn(function()
		local authorized, templates = requestAuthorization()
		if not authorized then
			logger:debug("WorldArchitectClient not started: server did not authorize this client")
			return
		end
		startEditor(deferredHandle.Get(), chrome, templates or {})
	end)
end

return WorldArchitectClient
