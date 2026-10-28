--!strict
--[[
	WorldArchitectSystem.lua

	Owns: the server half of the World Architect, the admin world-construction tool -- every WorldArchitect_* remote,
	each admin's undo/redo history and editor subscription, the delta pushes that keep every open editor in step, the
	terrain stroke log, and loading the Live world when the server boots.

	THE TRUST BOUNDARY. Every remote is an admin Endpoint (AdminGate: whitelist re-checked per request, then this
	System's own rate limiter for that traffic category), every argument is decoded here through ArchitectRecord /
	ArchitectGenerator / Schema shapes, and every resulting change goes through WorldState.Apply, which re-checks the
	world rules (bounds, protected areas, parents, locks, the node budget, revisions). A client addresses nodes only by
	the server-issued ids WorldState hands out; it can name no other Instance, so the Studio map and its spawns cannot be
	reached. Undo, redo, saves, loads, generation and optimisation go through the same gates -- there is no second path.

	WHAT A CLIENT IS NEVER TRUSTED FOR: its generation preview (a commit re-runs the seeded layout here), its optimiser
	plan (re-analysed here at apply time), a template's contents when the template is saved (captured here from the
	records the ids name), or any node's current revision (it names the revision it saw; a mismatch is StaleNode).

	THREE TIERS OF STATE (docs/architecture/2026-10-28-world-architect.md): the working world (this server's Workspace,
	changed immediately), draft slots, and the Live slot every server loads at boot. Publishing is saving to Live.
	Loading a slot first saves the working world to the Autosave slot, so a load is never the end of anything.

	CONCURRENT ADMINS. Edits carry the revisions they were made against; undo refuses rather than overwrite a node
	another admin changed since (UndoConflict). Saves and loads are serialised by one in-flight flag (Busy).

	Does not own: the world rules (WorldState), Instances (WorldMaterializer), storage layout (WorldPersistence),
	terrain maths (TerrainBrush), or anything outside Workspace.ArchitectWorld.
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Constants = require(ReplicatedStorage.Shared.Constants)
local DataStoreRetry = require(ReplicatedStorage.Shared.DataStoreRetry)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerScoped = require(ReplicatedStorage.Shared.PlayerScoped)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local Schema = require(ReplicatedStorage.Shared.Schema)
local ArchitectCodec = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectCodec)
local ArchitectConstants = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectConstants)
local ArchitectGenerator = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectGenerator)
local ArchitectHistory = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectHistory)
local ArchitectOptimizer = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectOptimizer)
local ArchitectRecord = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectRecord)
local ArchitectTemplates = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectTemplates)
local ArchitectTransform = require(ReplicatedStorage.Shared.WorldArchitect.ArchitectTransform)
local StarterTemplates = require(ReplicatedStorage.Shared.WorldArchitect.StarterTemplates)

local StorageConfig = require(script.Parent.Parent.Config.StorageConfig)
local Endpoint = require(script.Parent.Parent.Network.Endpoint)
local AdminGate = require(script.Parent.Parent.Network.AdminGate)
local WorldState = require(script.Parent.Parent.WorldArchitect.WorldState)
local WorldMaterializer = require(script.Parent.Parent.WorldArchitect.WorldMaterializer)
local WorldPersistence = require(script.Parent.Parent.WorldArchitect.WorldPersistence)
local ProtectedZones = require(script.Parent.Parent.WorldArchitect.ProtectedZones)
local TerrainBrush = require(script.Parent.Parent.WorldArchitect.TerrainBrush)

type NodeRecord = ArchitectRecord.NodeRecord
type Op = ArchitectHistory.Op
type Stroke = ArchitectCodec.Stroke

local Names = ArchitectConstants.RemoteNames
local Limits = ArchitectConstants.Limits
local PersistenceConfig = ArchitectConstants.Persistence

local WorldArchitectSystem = {}

local logger = Logger.scope("WorldArchitectSystem")

local readLimiter = RateLimiter.New(ArchitectConstants.RateLimits.Read)
local editLimiter = RateLimiter.New(ArchitectConstants.RateLimits.Edit)
local heavyLimiter = RateLimiter.New(ArchitectConstants.RateLimits.Heavy)

local histories: { [Player]: ArchitectHistory.History } = PlayerScoped.New("WorldArchitectSystem.histories")
local subscribers: { [Player]: boolean } = PlayerScoped.New("WorldArchitectSystem.subscribers")

export type Result = { [string]: any }

type TerrainEntry = { Stroke: Stroke, Snapshot: TerrainBrush.Snapshot? }

type Runtime = {
	State: WorldState.State,
	Materializer: WorldMaterializer.Materializer,
	Persistence: WorldPersistence.Persistence?,
	Terrain: Terrain?,
	Container: Instance,
	-- Applied strokes, oldest first, each with the voxels it replaced.
	Strokes: { TerrainEntry },
	-- Every stroke ever made this session by id (data only), so a redo can re-apply one that was undone.
	StrokeArchive: { [number]: Stroke },
	NextStrokeId: number,
	-- Bumped on every change, node or terrain; compared with LiveChange to tell the panel there is unpublished work.
	Change: number,
	LiveChange: number,
	LiveGeneration: number?,
	Busy: boolean,
	Ready: boolean,
	Push: (player: Player, payload: { [string]: any }) -> (),
	Retry: WorldPersistence.Retry,
}

local runtime: Runtime? = nil
local deltaRemote: RemoteEvent? = nil

local withRetry = DataStoreRetry.Scoped(logger, Constants.Storage.RetryPolicy)

local function rt(): Runtime
	assert(runtime, "WorldArchitectSystem used before Init")
	return runtime :: Runtime
end

local function fail(reason: string): Result
	return { Success = false, Reason = reason }
end

local function historyOf(player: Player): ArchitectHistory.History
	local history = histories[player]
	if history == nil then
		history = ArchitectHistory.New()
		histories[player] = history
	end
	return history
end

local function labels(player: Player): (string?, string?)
	return ArchitectHistory.Peek(historyOf(player))
end

local function status(): { [string]: any }
	local r = rt()
	return {
		Revision = r.State.Revision,
		Count = r.State.Count,
		Strokes = #r.Strokes,
		Unpublished = r.Change ~= r.LiveChange,
		LiveGeneration = r.LiveGeneration,
		Ready = r.Ready,
		StorageAvailable = r.Persistence ~= nil,
	}
end

-- Sends a delta to every open editor, split into pages so no one push is oversized.
local function broadcast(delta: WorldState.Delta, by: string, label: string): ()
	local r = rt()
	local pageSize = Limits.PageSize
	local pages = math.max(math.ceil(#delta.Upserts / pageSize), math.ceil(#delta.Removes / pageSize), 1)
	for player in subscribers do
		if not AdminGate.IsAuthorized(player) then
			subscribers[player] = nil
			continue
		end
		for page = 1, pages do
			local first = (page - 1) * pageSize + 1
			local last = page * pageSize
			r.Push(player, {
				Revision = delta.Revision,
				Page = page,
				Pages = pages,
				Upserts = table.move(delta.Upserts, first, math.min(last, #delta.Upserts), 1, {}),
				Removes = table.move(delta.Removes, first, math.min(last, #delta.Removes), 1, {}),
				By = by,
				Label = label,
				Status = if page == pages then status() else nil,
			})
		end
	end
end

local function broadcastReset(by: string, label: string): ()
	local r = rt()
	for player in subscribers do
		r.Push(player, { Reset = true, Revision = r.State.Revision, By = by, Label = label, Status = status() })
	end
end

local function broadcastStatus(by: string, label: string): ()
	local r = rt()
	for player in subscribers do
		r.Push(player, { StatusOnly = true, Revision = r.State.Revision, By = by, Label = label, Status = status() })
	end
end

-- Applies ops, materialises and broadcasts. Returns the ops as applied, or nil and the reason.
local function commit(player: Player, ops: { Op }, label: string): ({ Op }?, WorldState.Delta?, string?)
	local r = rt()
	local applied, delta, reason = WorldState.Apply(r.State, ops)
	if applied == nil or delta == nil then
		logger:info("Edit refused", { admin = player.Name, label = label, reason = reason })
		return nil, nil, reason
	end
	WorldMaterializer.Apply(r.Materializer, delta.Upserts, delta.Removes)
	r.Change += 1
	broadcast(delta, player.Name, label)
	return applied, delta, nil
end

-- An ordinary edit: commit, then record it in the admin's history.
local function edit(player: Player, ops: { Op }, label: string, extra: { [string]: any }?): Result
	local applied, delta, reason = commit(player, ops, label)
	if applied == nil or delta == nil then
		return fail(reason or "Refused")
	end
	ArchitectHistory.Record(historyOf(player), { Label = label, Ops = applied })
	logger:info("Edit", { admin = player.Name, label = label, upserts = #delta.Upserts, removes = #delta.Removes })
	local undo, redo = labels(player)
	local result: Result = { Success = true, Revision = delta.Revision, Undo = undo, Redo = redo }
	if extra then
		for key, value in extra do
			result[key] = value
		end
	end
	return result
end

local function ready(): string?
	local r = rt()
	if not r.Ready then
		return "Loading"
	end
	return nil
end

--
-- Request decoding
--

local TargetShape = Schema.Record({
	{ "Id", ArchitectRecord.IdShape },
	{ "Rev", Schema.Number(0, 1e9) },
})
local TargetsShape = Schema.Array(TargetShape, Limits.MaxNodesPerRequest)

-- The current records for a list of targets, each checked against the revision the client saw.
local function resolveTargets(raw: unknown): ({ NodeRecord }?, string?)
	local targets, reason = Schema.Decode(TargetsShape, raw)
	if targets == nil then
		return nil, reason
	end
	local r = rt()
	local out: { NodeRecord } = {}
	local seen: { [string]: boolean } = {}
	for _, target in targets do
		if not seen[target.Id] then
			seen[target.Id] = true
			local record = WorldState.Get(r.State, target.Id)
			if record == nil then
				return nil, "MissingNode"
			end
			if record.Rev ~= target.Rev then
				return nil, "StaleNode"
			end
			table.insert(out, record)
		end
	end
	if #out == 0 then
		return nil, "NoTargets"
	end
	return out, nil
end

local function depthOf(id: string?): number
	local r = rt()
	local depth = 0
	local current = id
	while current and depth <= Limits.MaxDepth do
		depth += 1
		local record = WorldState.Get(r.State, current)
		current = if record then record.Parent else nil
	end
	return depth
end

local function heightOf(id: string): number
	local r = rt()
	local deepest = 0
	local rootDepth = depthOf(id)
	for _, record in WorldState.Subtree(r.State, id) do
		deepest = math.max(deepest, depthOf(record.Id) - rootDepth + 1)
	end
	return deepest
end

local function isAncestor(ancestorId: string, id: string): boolean
	local r = rt()
	local current = WorldState.Get(r.State, id)
	local steps = 0
	while current and current.Parent and steps <= Limits.MaxDepth do
		if current.Parent == ancestorId then
			return true
		end
		current = WorldState.Get(r.State, current.Parent :: string)
		steps += 1
	end
	return false
end

local PendingShape = Schema.Record({
	{ "Ref", Schema.NonEmptyString(24) },
	{ "ParentRef", Schema.Optional(Schema.String(24)) },
})

local function handleCreate(player: Player, request: { [string]: any }): Result
	if not Schema.IsTable(request.Nodes) then
		return fail("Nodes: expected array")
	end
	local pending: { ArchitectTemplates.PendingNode } = {}
	for index, raw in ipairs(request.Nodes :: { unknown }) do
		if index > Limits.MaxNodesPerRequest then
			return fail("TooManyNodes")
		end
		local header, headerReason = Schema.Decode(PendingShape, raw)
		if header == nil then
			return fail(`Nodes.{index}: {headerReason}`)
		end
		local record, reason = ArchitectRecord.DecodeNew((raw :: any).Node)
		if record == nil then
			return fail(`Nodes.{index}: {reason}`)
		end
		table.insert(pending, { Ref = header.Ref, ParentRef = header.ParentRef, Record = record })
	end
	if #pending == 0 then
		return fail("NoNodes")
	end
	local records, reason = WorldState.Number(rt().State, pending)
	if records == nil then
		return fail(reason or "Refused")
	end
	local created: { string } = {}
	for _, record in records do
		if record.Parent == nil or WorldState.Get(rt().State, record.Parent) == nil then
			table.insert(created, record.Id)
		elseif depthOf(record.Parent) + 1 > Limits.MaxDepth then
			return fail("TooDeep")
		end
	end
	local label = Schema.StringOr(request.Label, "Create")
	return edit(player, { { Kind = "Create", Records = records } }, string.sub(label, 1, 32), { Created = created })
end

local ChangeShape = Schema.Record({
	{ "Id", ArchitectRecord.IdShape },
	{ "Rev", Schema.Number(0, 1e9) },
	{ "Patch", ArchitectRecord.PatchShape },
})
local ChangesShape = Schema.Array(ChangeShape, Limits.MaxNodesPerRequest)

local function handleUpdate(player: Player, request: { [string]: any }): Result
	local changes, reason = Schema.Decode(ChangesShape, request.Changes)
	if changes == nil then
		return fail(reason or "MalformedRequest")
	end
	local r = rt()
	local before: { NodeRecord } = {}
	local after: { NodeRecord } = {}
	local seen: { [string]: boolean } = {}
	for _, change in changes do
		if seen[change.Id] then
			return fail("DuplicateTarget")
		end
		seen[change.Id] = true
		local current = WorldState.Get(r.State, change.Id)
		if current == nil then
			return fail("MissingNode")
		end
		if current.Rev ~= change.Rev then
			return fail("StaleNode")
		end
		if not ArchitectRecord.IsNoop(current, change.Patch) then
			table.insert(before, current)
			table.insert(after, ArchitectRecord.Apply(current, change.Patch))
		end
	end
	if #after == 0 then
		local undo, redo = labels(player)
		return { Success = true, Revision = r.State.Revision, Undo = undo, Redo = redo }
	end
	local label = string.sub(Schema.StringOr(request.Label, "Edit"), 1, 32)
	return edit(player, { { Kind = "Update", Before = before, After = after } }, label)
end

local function handleDelete(player: Player, request: { [string]: any }): Result
	local targets, reason = resolveTargets(request.Targets)
	if targets == nil then
		return fail(reason or "MalformedRequest")
	end
	local ids: { string } = {}
	for _, target in targets do
		table.insert(ids, target.Id)
	end
	local records = WorldState.Subtrees(rt().State, ids)
	if #records > Limits.MaxNodesPerTransaction then
		return fail("TooManyNodes")
	end
	return edit(player, { { Kind = "Delete", Records = records } }, `Delete {#records}`)
end

local function handleGroup(player: Player, request: { [string]: any }): Result
	local targets, reason = resolveTargets(request.Targets)
	if targets == nil then
		return fail(reason or "MalformedRequest")
	end
	for _, a in targets do
		for _, b in targets do
			if a.Id ~= b.Id and isAncestor(a.Id, b.Id) then
				return fail("NestedTargets")
			end
		end
	end
	local parent = targets[1].Parent
	local tallest = 0
	for _, target in targets do
		tallest = math.max(tallest, heightOf(target.Id))
	end
	if depthOf(parent) + 1 + tallest > Limits.MaxDepth then
		return fail("TooDeep")
	end
	local r = rt()
	local ids: { string } = {}
	for _, target in targets do
		table.insert(ids, target.Id)
	end
	local group = ArchitectRecord.Default("Group")
	group.Name = string.sub(Schema.StringOr(request.Name, "Group"), 1, Limits.MaxNameLength)
	group.Position = ArchitectTransform.PivotOf(WorldState.Subtrees(r.State, ids))
	group.Parent = parent
	group.Id = WorldState.AllocateId(r.State)
	local after: { NodeRecord } = {}
	for _, target in targets do
		local moved = ArchitectRecord.Clone(target)
		moved.Parent = group.Id
		table.insert(after, moved)
	end
	return edit(player, {
		{ Kind = "Create", Records = { group } },
		{ Kind = "Update", Before = targets, After = after },
	}, "Group", { Created = { group.Id } })
end

local function handleUngroup(player: Player, request: { [string]: any }): Result
	local targets, reason = resolveTargets({ request.Target })
	if targets == nil then
		return fail(reason or "MalformedRequest")
	end
	local group = targets[1]
	if group.Kind ~= "Group" then
		return fail("NotAGroup")
	end
	if group.Locked then
		return fail("Locked")
	end
	local r = rt()
	local before: { NodeRecord } = {}
	local after: { NodeRecord } = {}
	for _, record in WorldState.Subtree(r.State, group.Id) do
		if record.Parent == group.Id then
			table.insert(before, record)
			local moved = ArchitectRecord.Clone(record)
			moved.Parent = group.Parent
			table.insert(after, moved)
		end
	end
	return edit(player, {
		{ Kind = "Update", Before = before, After = after },
		{ Kind = "Delete", Records = { group } },
	}, "Ungroup")
end

local function resolveTemplate(id: unknown): ArchitectTemplates.Template?
	if not Schema.IsString(id) then
		return nil
	end
	local builtin = StarterTemplates.Get(id :: string)
	if builtin then
		return builtin
	end
	local r = rt()
	return if r.Persistence then (r.Persistence :: WorldPersistence.Persistence).Templates[id :: string] else nil
end

local PlaceShape = Schema.Record({
	{ "Position", ArchitectRecord.PositionShape },
	{ "Yaw", Schema.Default(Schema.Number(-360, 360), 0) },
	{ "Parent", Schema.Optional(ArchitectRecord.IdShape) },
})

local function handlePlaceTemplate(player: Player, request: { [string]: any }): Result
	local template = resolveTemplate(request.TemplateId)
	if template == nil then
		return fail("UnknownTemplate")
	end
	local place, reason = Schema.Decode(PlaceShape, request)
	if place == nil then
		return fail(reason or "MalformedRequest")
	end
	local r = rt()
	local pivot = CFrame.new(place.Position) * CFrame.fromOrientation(0, math.rad(place.Yaw), 0)
	local pending = ArchitectTemplates.Instantiate(template, pivot, nil)
	if place.Parent then
		local parent = WorldState.Get(r.State, place.Parent)
		if parent == nil or parent.Kind ~= "Group" then
			return fail("InvalidParent")
		end
		pending[1].ParentRef = place.Parent
	end
	local records, numberReason = WorldState.Number(r.State, pending)
	if records == nil then
		return fail(numberReason or "Refused")
	end
	return edit(
		player,
		{ { Kind = "Create", Records = records } },
		`Place {template.Name}`,
		{ Created = { records[1].Id } }
	)
end

-- The world the generator sees: ground under a point (characters excluded), and the footprints of what is already
-- built near the area plus every protected zone.
local function generationWorld(
	config: ArchitectGenerator.Config
): ((number, number) -> number?, { ArchitectGenerator.Circle })
	local r = rt()
	local params = RaycastParams.new()
	local characters: { Instance } = {}
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(characters, player.Character)
		end
	end
	params.FilterDescendantsInstances = characters
	params.FilterType = Enum.RaycastFilterType.Exclude
	local top = config.Center.Y + 256
	local function heightAt(x: number, z: number): number?
		local hit = Workspace:Raycast(Vector3.new(x, top, z), Vector3.new(0, -768, 0), params)
		return if hit then hit.Position.Y else nil
	end
	local blockers = ProtectedZones.Circles(r.State.Zones)
	local reach = math.max(config.AreaX, config.AreaZ)
	for _, record in WorldState.List(r.State) do
		if record.Parent == nil then
			local low, high = ArchitectTransform.Bounds(WorldState.Subtree(r.State, record.Id))
			if low and high then
				local center = (low + high) / 2
				if Vector2.new(center.X - config.Center.X, center.Z - config.Center.Z).Magnitude < reach then
					local half = (high - low) / 2
					table.insert(blockers, { Center = center, Radius = Vector2.new(half.X, half.Z).Magnitude * 0.8 })
				end
			end
		end
	end
	return heightAt, blockers
end

local function layoutFor(rawConfig: unknown): (ArchitectGenerator.Config?, ArchitectGenerator.Layout?, string?)
	local config, reason = ArchitectGenerator.Decode(rawConfig)
	if config == nil then
		return nil, nil, reason
	end
	local heightAt, blockers = generationWorld(config)
	return config, ArchitectGenerator.Generate(config, heightAt, blockers, resolveTemplate), nil
end

local function handleGenerate(player: Player, request: { [string]: any }): Result
	local config, layout, reason = layoutFor(request.Config)
	if config == nil or layout == nil then
		return fail(reason or "InvalidConfig")
	end
	if #layout.Placements == 0 then
		return fail("NothingPlaced")
	end
	local pending = ArchitectGenerator.Expand(layout, config, resolveTemplate)
	local records, numberReason = WorldState.Number(rt().State, pending)
	if records == nil then
		return fail(numberReason or "Refused")
	end
	return edit(player, { { Kind = "Create", Records = records } }, `Generate {config.Type}`, {
		Created = { records[1].Id },
		Placed = #layout.Placements,
	})
end

local OptimizeShape = Schema.Record({
	{ "FindingIds", Schema.Optional(Schema.Array(Schema.String(32), 32)) },
	{ "IncludeDestructive", Schema.Default(Schema.Boolean, false) },
})

local function handleOptimize(player: Player, request: { [string]: any }): Result
	local options, reason = Schema.Decode(OptimizeShape, request)
	if options == nil then
		return fail(reason or "MalformedRequest")
	end
	local r = rt()
	local report = ArchitectOptimizer.Analyze(WorldState.List(r.State))
	local patches, deletes = ArchitectOptimizer.Plan(report, options.FindingIds, options.IncludeDestructive)
	local before: { NodeRecord } = {}
	local after: { NodeRecord } = {}
	local deleting: { [string]: boolean } = {}
	for _, id in deletes do
		deleting[id] = true
	end
	local ids: { string } = {}
	for id in patches do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		local current = WorldState.Get(r.State, id)
		if current and not deleting[id] and not current.Locked then
			table.insert(before, current)
			table.insert(after, ArchitectRecord.Apply(current, patches[id]))
		end
	end
	local removed: { NodeRecord } = {}
	for _, id in deletes do
		local current = WorldState.Get(r.State, id)
		if current and not current.Locked and current.Kind == "Part" then
			table.insert(removed, current)
		end
	end
	if #after == 0 and #removed == 0 then
		return fail("NothingToApply")
	end
	local ops: { Op } = {}
	if #after > 0 then
		table.insert(ops, { Kind = "Update", Before = before, After = after })
	end
	if #removed > 0 then
		table.insert(ops, { Kind = "Delete", Records = removed })
	end
	return edit(player, ops, "Optimize", { Changed = #after, Deleted = #removed })
end

local EDIT_KINDS: { [string]: (Player, { [string]: any }) -> Result } = {
	Create = handleCreate,
	Update = handleUpdate,
	Delete = handleDelete,
	Group = handleGroup,
	Ungroup = handleUngroup,
	PlaceTemplate = handlePlaceTemplate,
	Generate = handleGenerate,
	Optimize = handleOptimize,
}

local function handleEdit(player: Player, request: unknown): Result
	local notReady = ready()
	if notReady then
		return fail(notReady)
	end
	if not Schema.IsTable(request) then
		return fail("MalformedRequest")
	end
	local handler = EDIT_KINDS[Schema.StringOr((request :: any).Kind, "")]
	if handler == nil then
		return fail("UnknownKind")
	end
	return handler(player, request :: { [string]: any })
end

--
-- Terrain
--

local StrokeShape = Schema.Record({
	{ "Mode", Schema.Enum(ArchitectConstants.Terrain.Modes) },
	{ "Center", ArchitectRecord.PositionShape },
	{ "Radius", Schema.Number(ArchitectConstants.Terrain.MinRadius, ArchitectConstants.Terrain.MaxRadius) },
	{ "Strength", Schema.Number(0.05, 1) },
	{ "Material", Schema.Enum(ArchitectConstants.TerrainMaterials) },
	{ "Height", Schema.Optional(Schema.Number(ArchitectConstants.Limits.MinY, ArchitectConstants.Limits.MaxY)) },
})

-- The protected zone a stroke's whole writable region (TerrainBrush.RegionOf -- for Flatten, down to and up from its
-- target height) would touch, or nil.
local function strokeTouchesZone(stroke: Stroke): string?
	local r = rt()
	local region = TerrainBrush.RegionOf(stroke)
	local low = region.CFrame.Position - region.Size / 2
	local high = region.CFrame.Position + region.Size / 2
	for _, zone in r.State.Zones do
		if
			low.X < zone.Max.X
			and high.X > zone.Min.X
			and low.Y < zone.Max.Y
			and high.Y > zone.Min.Y
			and low.Z < zone.Max.Z
			and high.Z > zone.Min.Z
		then
			return zone.Name
		end
	end
	return nil
end

-- Applies (or reverts) one stroke against the live terrain and the log. Returns a refusal reason, or nil.
local function terrainOp(op: Op): string?
	local r = rt()
	local terrain = r.Terrain
	if terrain == nil then
		return "TerrainUnavailable"
	end
	local id = op.StrokeId :: number
	if op.Apply then
		local stroke = r.StrokeArchive[id]
		if stroke == nil then
			return "MissingStroke"
		end
		if #r.Strokes >= ArchitectConstants.Terrain.MaxStrokes then
			return "TerrainLogFull"
		end
		local snapshot = TerrainBrush.Snapshot(terrain :: Terrain, stroke)
		TerrainBrush.Apply(terrain :: Terrain, stroke)
		table.insert(r.Strokes, { Stroke = stroke, Snapshot = snapshot })
		return nil
	end
	local index: number? = nil
	for i, entry in r.Strokes do
		if entry.Stroke.Id == id then
			index = i
		end
	end
	if index == nil then
		return "MissingStroke"
	end
	local entry = r.Strokes[index :: number]
	for later = (index :: number) + 1, #r.Strokes do
		if TerrainBrush.Overlaps(entry.Stroke, r.Strokes[later].Stroke) then
			return "UndoConflict"
		end
	end
	if entry.Snapshot == nil then
		return "NoSnapshot"
	end
	TerrainBrush.Restore(terrain :: Terrain, entry.Snapshot :: TerrainBrush.Snapshot)
	table.remove(r.Strokes, index :: number)
	return nil
end

local function handleTerrain(player: Player, raw: unknown): Result
	local notReady = ready()
	if notReady then
		return fail(notReady)
	end
	local decoded, reason = Schema.Decode(StrokeShape, raw)
	if decoded == nil then
		return fail(reason or "MalformedRequest")
	end
	local r = rt()
	local stroke: Stroke = {
		Id = r.NextStrokeId,
		Mode = decoded.Mode,
		Center = decoded.Center,
		Radius = decoded.Radius,
		Strength = decoded.Strength,
		Material = decoded.Material,
		-- A flatten level within one radius of the stroke: the region it may write stays one brush tall.
		Height = if decoded.Height
			then math.clamp(decoded.Height, decoded.Center.Y - decoded.Radius, decoded.Center.Y + decoded.Radius)
			else nil,
	}
	local zone = strokeTouchesZone(stroke)
	if zone then
		return fail("ProtectedArea")
	end
	r.NextStrokeId += 1
	r.StrokeArchive[stroke.Id] = stroke
	local op: Op = { Kind = "Terrain", StrokeId = stroke.Id, Apply = true }
	local refusal = terrainOp(op)
	if refusal then
		return fail(refusal)
	end
	r.Change += 1
	ArchitectHistory.Record(historyOf(player), { Label = `Terrain {stroke.Mode}`, Ops = { op } })
	broadcastStatus(player.Name, `Terrain {stroke.Mode}`)
	local undo, redo = labels(player)
	return { Success = true, Revision = r.State.Revision, Undo = undo, Redo = redo, Strokes = #r.Strokes }
end

--
-- Undo / redo
--

local function replay(
	player: Player,
	transaction: ArchitectHistory.Transaction,
	label: string
): (ArchitectHistory.Transaction?, string?)
	local inverse = ArchitectHistory.Invert(transaction)
	local first = inverse.Ops[1]
	if first and first.Kind == "Terrain" then
		local refusal = terrainOp(first)
		if refusal then
			return nil, refusal
		end
		rt().Change += 1
		broadcastStatus(player.Name, label)
		return inverse, nil
	end
	local applied, _, reason = commit(player, inverse.Ops, label)
	if applied == nil then
		return nil, reason
	end
	return { Label = transaction.Label, Ops = applied }, nil
end

local function handleUndo(player: Player): Result
	local notReady = ready()
	if notReady then
		return fail(notReady)
	end
	local history = historyOf(player)
	local transaction = ArchitectHistory.TakeUndo(history)
	if transaction == nil then
		return fail("NothingToUndo")
	end
	local applied, reason = replay(player, transaction, `Undo {transaction.Label}`)
	if applied == nil then
		-- The entry is dropped: what it would restore is no longer what the world holds (StaleNode/UndoConflict).
		logger:info("Undo refused", { admin = player.Name, label = transaction.Label, reason = reason })
		local undo, redo = labels(player)
		return {
			Success = false,
			Reason = if reason == "StaleNode" then "UndoConflict" else reason,
			Undo = undo,
			Redo = redo,
		}
	end
	-- The nodes this undo touched carry new revisions; the next entry down must expect those (ArchitectHistory.Rebase).
	ArchitectHistory.Rebase(history.Undo, ArchitectHistory.RevsOf(applied.Ops))
	ArchitectHistory.PushRedo(history, applied)
	local undo, redo = labels(player)
	return { Success = true, Revision = rt().State.Revision, Undo = undo, Redo = redo, Label = transaction.Label }
end

local function handleRedo(player: Player): Result
	local notReady = ready()
	if notReady then
		return fail(notReady)
	end
	local history = historyOf(player)
	local transaction = ArchitectHistory.TakeRedo(history)
	if transaction == nil then
		return fail("NothingToRedo")
	end
	local applied, reason = replay(player, transaction, `Redo {transaction.Label}`)
	if applied == nil then
		local undo, redo = labels(player)
		return {
			Success = false,
			Reason = if reason == "StaleNode" then "RedoConflict" else reason,
			Undo = undo,
			Redo = redo,
		}
	end
	ArchitectHistory.Rebase(history.Redo, ArchitectHistory.RevsOf(applied.Ops))
	ArchitectHistory.PushUndo(history, applied)
	local undo, redo = labels(player)
	return { Success = true, Revision = rt().State.Revision, Undo = undo, Redo = redo, Label = transaction.Label }
end

--
-- Sessions
--

local function templateSummaries(): { ArchitectTemplates.TemplateSummary }
	local out: { ArchitectTemplates.TemplateSummary } = {}
	for _, template in StarterTemplates.All() do
		table.insert(out, ArchitectTemplates.Summarize(template))
	end
	local r = rt()
	if r.Persistence then
		for _, template in (r.Persistence :: WorldPersistence.Persistence).Templates do
			table.insert(out, ArchitectTemplates.Summarize(template))
		end
	end
	return out
end

local function page(index: number): { NodeRecord }
	local list = WorldState.List(rt().State)
	local first = (index - 1) * Limits.PageSize + 1
	return table.move(list, first, math.min(first + Limits.PageSize - 1, #list), 1, {})
end

local function handleOpen(player: Player): Result
	local r = rt()
	WorldState.SetZones(r.State, ProtectedZones.Collect(r.Container))
	subscribers[player] = true
	local zones = {}
	for _, zone in r.State.Zones do
		table.insert(zones, { Name = zone.Name, Min = zone.Min, Max = zone.Max })
	end
	local undo, redo = labels(player)
	logger:info("Editor opened", { admin = player.Name })
	return {
		Success = true,
		Revision = r.State.Revision,
		Pages = math.max(math.ceil(r.State.Count / Limits.PageSize), 1),
		Records = page(1),
		Templates = templateSummaries(),
		Zones = zones,
		Undo = undo,
		Redo = redo,
		Status = status(),
	}
end

local function handlePage(_player: Player, rawIndex: unknown): Result
	local index = Schema.Number(1, 1000)(rawIndex)
	if index == nil then
		return fail("InvalidPage")
	end
	return { Success = true, Revision = rt().State.Revision, Records = page(math.floor(index)) }
end

local function handleClose(player: Player): Result
	subscribers[player] = nil
	return { Success = true }
end

local function handlePreview(_player: Player, rawConfig: unknown): Result
	local notReady = ready()
	if notReady then
		return fail(notReady)
	end
	local config, layout, reason = layoutFor(rawConfig)
	if config == nil or layout == nil then
		return fail(reason or "InvalidConfig")
	end
	local placements = {}
	for _, placement in layout.Placements do
		table.insert(
			placements,
			{ TemplateId = placement.TemplateId, CFrame = placement.CFrame, Radius = placement.Radius }
		)
	end
	local pending = ArchitectGenerator.Expand(layout, config, resolveTemplate)
	return {
		Success = true,
		Placements = placements,
		Requested = layout.Requested,
		Refused = layout.Refused,
		Corners = layout.Corners,
		NodeCount = #pending,
		OverBudget = #pending > Limits.MaxNodesPerTransaction or rt().State.Count + #pending > Limits.MaxNodes,
	}
end

local function handleAnalyze(_player: Player): Result
	local report = ArchitectOptimizer.Analyze(WorldState.List(rt().State))
	return { Success = true, Revision = rt().State.Revision, Report = ArchitectOptimizer.ForWire(report) }
end

--
-- Templates
--

local MetaShape = Schema.Record({
	{ "Name", Schema.NonEmptyString(Limits.MaxNameLength) },
	{ "Category", Schema.Default(Schema.String(Limits.MaxNameLength), "Saved") },
	{ "Description", Schema.Default(Schema.String(Limits.MaxDescriptionLength), "") },
	{ "Tags", Schema.Default(Schema.Array(Schema.String(Limits.MaxTagLength), Limits.MaxTags), {}) },
	{ "Type", Schema.Default(Schema.Enum(ArchitectConstants.TemplateTypes), "Assembly") },
	{ "Faction", Schema.Default(Schema.Enum(ArchitectConstants.Factions), "Any") },
	{ "Region", Schema.Default(Schema.Enum(ArchitectConstants.Regions), "Any") },
	{ "Variant", Schema.Default(Schema.Enum(ArchitectConstants.Variants), "Intact") },
})

local function savedTemplate(id: unknown): ArchitectTemplates.Template?
	local r = rt()
	if r.Persistence == nil or not Schema.IsString(id) then
		return nil
	end
	return (r.Persistence :: WorldPersistence.Persistence).Templates[id :: string]
end

local function newTemplateId(): string
	return "t" .. string.lower(string.sub(string.gsub(HttpService:GenerateGUID(false), "-", ""), 1, 15))
end

local function storeTemplate(player: Player, raw: { [string]: any }, id: string, version: number): Result
	local r = rt()
	local persistence = r.Persistence
	if persistence == nil then
		return fail("StorageUnavailable")
	end
	local template, reason = ArchitectTemplates.Validate(raw, id, false)
	if template == nil then
		return fail(`InvalidTemplate: {reason}`)
	end
	template.Version = version
	template.Author = player.Name
	template.UpdatedAt = os.time()
	local ok, storeReason = WorldPersistence.SaveTemplate(persistence :: WorldPersistence.Persistence, template)
	if not ok then
		return fail(storeReason or "StorageError")
	end
	logger:info("Template saved", { admin = player.Name, id = id, name = template.Name, nodes = #template.Nodes })
	return { Success = true, Template = ArchitectTemplates.Summarize(template), Templates = templateSummaries() }
end

local function handleTemplate(player: Player, request: unknown): Result
	if not Schema.IsTable(request) then
		return fail("MalformedRequest")
	end
	local req = request :: { [string]: any }
	local kind = Schema.StringOr(req.Kind, "")
	local r = rt()
	if kind == "List" then
		return { Success = true, Templates = templateSummaries() }
	elseif kind == "Get" then
		local template = resolveTemplate(req.Id)
		if template == nil then
			return fail("UnknownTemplate")
		end
		return { Success = true, Template = template }
	end
	local persistence = r.Persistence
	if persistence == nil then
		return fail("StorageUnavailable")
	end
	if kind == "Save" then
		local meta, metaReason = Schema.Decode(MetaShape, req)
		if meta == nil then
			return fail(metaReason or "MalformedRequest")
		end
		local targets, reason = resolveTargets(req.Targets)
		if targets == nil then
			return fail(reason or "MalformedRequest")
		end
		local ids: { string } = {}
		for _, target in targets do
			table.insert(ids, target.Id)
		end
		local records = WorldState.Subtrees(r.State, ids)
		if #records > Limits.MaxTemplateNodes then
			return fail("TemplateTooLarge")
		end
		local raw = ArchitectTemplates.Capture(records)
		raw.Name, raw.Category, raw.Description, raw.Tags = meta.Name, meta.Category, meta.Description, meta.Tags
		raw.Type, raw.Faction, raw.Region, raw.Variant = meta.Type, meta.Faction, meta.Region, meta.Variant
		local replace = savedTemplate(req.ReplaceId)
		if req.ReplaceId ~= nil and replace == nil then
			return fail("UnknownTemplate")
		end
		local count = 0
		for _ in (persistence :: WorldPersistence.Persistence).Templates do
			count += 1
		end
		if replace == nil and count >= Limits.MaxSavedTemplates then
			return fail("LibraryFull")
		end
		return storeTemplate(
			player,
			raw,
			if replace then replace.Id else newTemplateId(),
			if replace then replace.Version + 1 else 1
		)
	elseif kind == "Rename" or kind == "Duplicate" then
		local source = if kind == "Rename" then savedTemplate(req.Id) else resolveTemplate(req.Id)
		if source == nil then
			return fail("UnknownTemplate")
		end
		local meta, metaReason = Schema.Decode(MetaShape, req)
		if meta == nil then
			return fail(metaReason or "MalformedRequest")
		end
		local nodes = {}
		for _, node in source.Nodes do
			table.insert(nodes, { Key = node.Key, Parent = node.Parent, Record = node.Record })
		end
		local raw = {
			Name = meta.Name,
			Category = meta.Category,
			Description = meta.Description,
			Tags = meta.Tags,
			Type = meta.Type,
			Faction = meta.Faction,
			Region = meta.Region,
			Variant = meta.Variant,
			Nodes = nodes,
		}
		if kind == "Rename" then
			return storeTemplate(player, raw, source.Id, source.Version + 1)
		end
		return storeTemplate(player, raw, newTemplateId(), 1)
	elseif kind == "Delete" then
		local template = savedTemplate(req.Id)
		if template == nil then
			return fail("UnknownTemplate")
		end
		local ok, reason = WorldPersistence.DeleteTemplate(persistence :: WorldPersistence.Persistence, template.Id)
		if not ok then
			return fail(reason or "StorageError")
		end
		logger:info("Template deleted", { admin = player.Name, id = template.Id })
		return { Success = true, Templates = templateSummaries() }
	end
	return fail("UnknownKind")
end

--
-- World slots
--

local function currentDoc(): ArchitectCodec.WorldDoc
	local r = rt()
	local strokes: { Stroke } = {}
	for _, entry in r.Strokes do
		table.insert(strokes, entry.Stroke)
	end
	return { NextId = r.State.NextId, Records = WorldState.List(r.State), Strokes = strokes }
end

-- Reverts every applied stroke (newest first), then replaces the world and replays `doc`'s strokes.
local function install(doc: ArchitectCodec.WorldDoc): WorldState.Delta
	local r = rt()
	if r.Terrain then
		for index = #r.Strokes, 1, -1 do
			local snapshot = r.Strokes[index].Snapshot
			if snapshot then
				TerrainBrush.Restore(r.Terrain :: Terrain, snapshot)
			end
		end
	end
	table.clear(r.Strokes)
	local delta = WorldState.Replace(r.State, doc.Records, doc.NextId)
	WorldMaterializer.Apply(r.Materializer, delta.Upserts, delta.Removes)
	for _, stroke in doc.Strokes do
		local copy = table.clone(stroke)
		copy.Id = r.NextStrokeId
		r.NextStrokeId += 1
		r.StrokeArchive[copy.Id] = copy
		if r.Terrain and #r.Strokes < ArchitectConstants.Terrain.MaxStrokes then
			local snapshot = TerrainBrush.Snapshot(r.Terrain :: Terrain, copy)
			TerrainBrush.Apply(r.Terrain :: Terrain, copy)
			table.insert(r.Strokes, { Stroke = copy, Snapshot = snapshot })
		end
	end
	for _, history in histories do
		ArchitectHistory.Clear(history)
	end
	return delta
end

local function slotListing(): Result
	local r = rt()
	if r.Persistence == nil then
		return fail("StorageUnavailable")
	end
	local slots, reason = WorldPersistence.ListSlots(r.Persistence :: WorldPersistence.Persistence)
	if slots == nil then
		return fail(reason or "StorageError")
	end
	return { Success = true, Slots = slots, Status = status() }
end

local WorldRequestShape = Schema.Record({
	{ "Kind", Schema.Enum({ "ListSlots", "Save", "Load", "Delete" }) },
	{ "Slot", Schema.Optional(WorldPersistence.SlotNameShape) },
	{ "Gen", Schema.Optional(Schema.Number(1, 1e9)) },
	{ "Note", Schema.Default(Schema.String(80), "") },
})

local function handleWorld(player: Player, raw: unknown): Result
	local notReady = ready()
	if notReady then
		return fail(notReady)
	end
	local request, reason = Schema.Decode(WorldRequestShape, raw)
	if request == nil then
		return fail(reason or "MalformedRequest")
	end
	if request.Kind == "ListSlots" then
		return slotListing()
	end
	local r = rt()
	local persistence = r.Persistence
	if persistence == nil then
		return fail("StorageUnavailable")
	end
	local slot = request.Slot
	if slot == nil then
		return fail("SlotRequired")
	end
	if r.Busy then
		return fail("Busy")
	end
	r.Busy = true
	local ok, result = pcall(function(): Result
		if request.Kind == "Save" then
			local changeAtSave = r.Change
			local generation, saveReason = WorldPersistence.Save(
				persistence :: WorldPersistence.Persistence,
				slot,
				currentDoc(),
				player.Name,
				request.Note
			)
			if generation == nil then
				logger:error("World save failed", { admin = player.Name, slot = slot, reason = saveReason })
				return fail(saveReason or "StorageError")
			end
			if slot == PersistenceConfig.LiveSlot then
				r.LiveChange = changeAtSave
				r.LiveGeneration = generation.Gen
			end
			logger:info(
				"World saved",
				{ admin = player.Name, slot = slot, gen = generation.Gen, nodes = generation.Nodes }
			)
			broadcastStatus(player.Name, `Saved {slot}`)
			return { Success = true, Generation = generation, Status = status() }
		elseif request.Kind == "Load" then
			local report = WorldPersistence.Load(persistence :: WorldPersistence.Persistence, slot, request.Gen)
			if report.Doc == nil then
				return fail(report.Reason or "StorageError")
			end
			local doc = report.Doc :: ArchitectCodec.WorldDoc
			if #doc.Records > Limits.MaxNodes then
				return fail("WorldTooLarge")
			end
			-- Nothing is lost by a load: the working world goes to Autosave first, and a failed autosave stops the load.
			if r.State.Count > 0 or #r.Strokes > 0 then
				local saved, autosaveReason = WorldPersistence.Save(
					persistence :: WorldPersistence.Persistence,
					PersistenceConfig.AutosaveSlot,
					currentDoc(),
					player.Name,
					`Before loading {slot}`
				)
				if saved == nil then
					return fail(`AutosaveFailed: {autosaveReason}`)
				end
			end
			install(doc)
			r.Change += 1
			if slot == PersistenceConfig.LiveSlot and request.Gen == nil then
				r.LiveChange = r.Change
			end
			logger:info(
				"World loaded",
				{ admin = player.Name, slot = slot, nodes = #doc.Records, skipped = report.Skipped }
			)
			broadcastReset(player.Name, `Loaded {slot}`)
			return { Success = true, Skipped = report.Skipped, Status = status() }
		else
			local deleted, deleteReason = WorldPersistence.DeleteSlot(persistence :: WorldPersistence.Persistence, slot)
			if not deleted then
				return fail(deleteReason or "StorageError")
			end
			logger:info("Slot deleted", { admin = player.Name, slot = slot })
			return { Success = true }
		end
	end)
	r.Busy = false
	if not ok then
		logger:error("World request errored", { admin = player.Name, errorMessage = tostring(result) })
		return fail("InternalError")
	end
	return result
end

--
-- Boot
--

local function loadLive(): ()
	local r = rt()
	local persistence = r.Persistence
	if persistence then
		local loaded, refused = WorldPersistence.LoadTemplates(persistence :: WorldPersistence.Persistence)
		logger:info("Templates loaded", { loaded = loaded, refused = refused })
		local report =
			WorldPersistence.Load(persistence :: WorldPersistence.Persistence, PersistenceConfig.LiveSlot, nil)
		if report.Doc then
			local doc = report.Doc :: ArchitectCodec.WorldDoc
			if #doc.Records <= Limits.MaxNodes then
				install(doc)
				local generations = WorldPersistence.Generations(
					persistence :: WorldPersistence.Persistence,
					PersistenceConfig.LiveSlot
				)
				if generations and #generations > 0 then
					r.LiveGeneration = generations[#generations].Gen
				end
				logger:info(
					"Live world loaded",
					{ nodes = #doc.Records, strokes = #doc.Strokes, skipped = report.Skipped }
				)
			else
				logger:error("Live world exceeds the node budget; not loaded", { nodes = #doc.Records })
			end
		elseif report.Reason ~= "EmptySlot" then
			logger:error("Live world failed to load; starting empty", { reason = report.Reason })
		end
	end
	r.Change = 0
	r.LiveChange = 0
	r.Ready = true
end

export type Options = {
	Store: WorldPersistence.Store?,
	Retry: WorldPersistence.Retry?,
	Container: Instance?,
	Terrain: Terrain?,
	Push: ((Player, { [string]: any }) -> ())?,
	-- Load the Live slot synchronously (specs) instead of on its own thread.
	LoadNow: boolean?,
}

-- Builds the runtime. Init calls it with the real DataStore and Workspace; specs call it through ConfigureForTesting.
local function configure(options: Options): ()
	local container = options.Container or Workspace
	local store = options.Store
	local retry = options.Retry or (withRetry :: any)
	runtime = {
		State = WorldState.New(),
		Materializer = WorldMaterializer.New(container),
		Persistence = if store then WorldPersistence.New(store :: WorldPersistence.Store, retry) else nil,
		Terrain = options.Terrain,
		Container = container,
		Strokes = {},
		StrokeArchive = {},
		NextStrokeId = 1,
		Change = 0,
		LiveChange = 0,
		LiveGeneration = nil,
		Busy = false,
		Ready = false,
		Push = options.Push or function(player: Player, payload: { [string]: any })
			if deltaRemote then
				(deltaRemote :: RemoteEvent):FireClient(player, payload)
			end
		end,
		Retry = retry,
	}
	local r = runtime :: Runtime
	WorldState.SetZones(r.State, ProtectedZones.Collect(container))
	if options.LoadNow then
		loadLive()
	else
		task.spawn(loadLive)
	end
end

-- The composed Endpoint handlers by remote key, for specs (the harness cannot InvokeServer).
WorldArchitectSystem.Remotes = {} :: { [string]: Endpoint.Bound }

function WorldArchitectSystem.Init(): ()
	local storeOk, store = pcall(function()
		return DataStoreService:GetDataStore(StorageConfig.WorldArchitectDataStoreName)
	end)
	if not storeOk then
		logger:warn(
			"DataStore unavailable; World Architect runs without persistence",
			{ errorMessage = tostring(store) }
		)
	end
	configure({
		Store = if storeOk then store :: any else nil,
		Container = Workspace,
		Terrain = Workspace:FindFirstChildOfClass("Terrain"),
	})

	local endpoint = Endpoint.Scope("WorldArchitectSystem", logger)
	local errorResult = { Success = false, Reason = "InternalError" }
	local function denied(reason: string): Result
		return { Success = false, Reason = reason }
	end
	local specs: { { Key: string, Limiter: RateLimiter.RateLimiterInstance, Handler: (Player, ...any) -> any } } = {
		{ Key = "Open", Limiter = readLimiter, Handler = handleOpen },
		{ Key = "Page", Limiter = readLimiter, Handler = handlePage },
		{ Key = "Close", Limiter = readLimiter, Handler = handleClose },
		{ Key = "Edit", Limiter = editLimiter, Handler = handleEdit },
		{ Key = "Undo", Limiter = editLimiter, Handler = handleUndo },
		{ Key = "Redo", Limiter = editLimiter, Handler = handleRedo },
		{ Key = "Template", Limiter = editLimiter, Handler = handleTemplate },
		{ Key = "Terrain", Limiter = editLimiter, Handler = handleTerrain },
		{ Key = "Preview", Limiter = heavyLimiter, Handler = handlePreview },
		{ Key = "World", Limiter = heavyLimiter, Handler = handleWorld },
		{ Key = "Analyze", Limiter = heavyLimiter, Handler = handleAnalyze },
	}
	for _, spec in specs do
		WorldArchitectSystem.Remotes[spec.Key] = endpoint.Function({
			Name = (Names :: any)[spec.Key],
			Limiter = spec.Limiter,
			Admin = true,
			ErrorResult = errorResult,
			Denied = denied,
			Handler = spec.Handler,
		})
	end
	deltaRemote = endpoint.Push(Names.Delta)
	logger:info("WorldArchitectSystem.Init() complete")
end

-- Rebuilds the runtime against injected dependencies, keeping the remotes Init declared. Specs only.
function WorldArchitectSystem.ConfigureForTesting(options: Options): ()
	for player in histories do
		histories[player] = nil
	end
	for player in subscribers do
		subscribers[player] = nil
	end
	configure(options)
end

-- Read-only views for specs and diagnostics.
function WorldArchitectSystem.State(): WorldState.State
	return rt().State
end

function WorldArchitectSystem.InstanceOf(id: string): Instance?
	return WorldMaterializer.InstanceOf(rt().Materializer, id)
end

return WorldArchitectSystem
