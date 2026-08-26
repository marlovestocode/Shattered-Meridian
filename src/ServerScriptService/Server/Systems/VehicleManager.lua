--!strict
--[[
	VehicleManager.lua

	Owns: vehicles as a CONTENT TYPE -- finding the registry folder, reading it into a catalog,
	cloning a template into the world at a sane place, tracking every live instance, reclaiming one
	whose owner left, and the five admin-gated remotes the Dev Menu's Vehicles tab drives all of that
	through.

	IT OWNS NO VEHICLE'S BEHAVIOUR, AND THAT IS THE WHOLE DESIGN. A blimp's flight, mounting, fuel and
	arm pose belong to BlimpSystem and always will. The integration between the two is one line and no
	require in either direction: CollectionService tags survive :Clone(), so a Blimp template that a
	builder tagged in Studio arrives in the world already tagged, and BlimpSystem's existing
	GetInstanceAddedSignal("Blimp") registers it with no change to that System at all. Despawn is the
	same seam in reverse -- :Destroy() is what BlimpSystem's own untag/unregister path already
	watches for, including getting every mounted player off the hull first.

	That seam is the reason to be suspicious of any future change here that needs to know what KIND of
	vehicle it is holding. VehicleTypes.VehicleDefinition.Kind exists for sorting and display and is
	branched on nowhere; the day this file reads it to decide what to do is the day it has started
	absorbing the behaviour of every vehicle in the game, which is the monolith the tag seam exists to
	avoid. A new vehicle that flies differently is a new Server/<Thing>System that watches its own tag
	-- exactly the shape BlimpSystem already is -- not a branch in here.

	NAMED A MANAGER, LOCATED AS A SYSTEM, which is the same documented exception ProgressionSystem
	carries (software-architecture.md spells that one out): it coordinates content other Systems own
	rather than owning gameplay state of its own, but it holds a network surface, a per-tick sweep and
	a player-lifecycle binding, and every one of those things lives under Server/Systems in this
	codebase. Splitting it across both folders to satisfy the naming would be two files and one extra
	hop for no gain.

	A SPAWN NAMES A BERTH, NEVER A POSITION. The Spawn remote takes (vehicleId, berthName?) and
	nothing else. A CFrame on that remote would let any client that can reach it drop a two-hundred-
	stud hull on any point of the map, including inside another player, and the admin gate is not the
	right last line of defence against that -- the payload simply never carries it. With no berth
	named, the hull is placed in front of the caller by VehiclePlacement, whose own header explains why
	that offset has to be computed from the hull's size rather than being the fixed 6 studs every other
	"spawn near me" dev action in this codebase uses.

	EVICTION RATHER THAN REFUSAL at both caps -- the oldest live vehicle goes when a new spawn would
	exceed VehicleConstants.Limits. Same choice Constants.Debug.TrainingDummy.MaxActive already makes,
	and for the same reason its own comment gives: a dev tool that starts silently refusing reads as
	broken, where one that quietly recycles reads as working.

	THE OWNER-LEAVE RECLAIM CHECKS OCCUPANCY, and that check is load-bearing rather than defensive. An
	admin spawns an airship, four people climb aboard, the admin disconnects -- and two minutes later
	the grace timer fires. Deleting the hull there does not free a resource, it drops four players out
	of the sky. So a vehicle with any player inside its own bounding radius is never reclaimed, and the
	timer simply re-arms. The check is proximity rather than asking BlimpSystem who is mounted,
	deliberately: this file has no business knowing that mounting exists, and proximity is correct for
	every future vehicle including ones nobody mounts at all.

	Does not own: how any vehicle flies, mounts or refuels (Server/Blimp/**, Server/Systems/
	BlimpSystem.lua); the authoring contract (Shared/Vehicle/VehicleConstants.lua); reading the
	registry folder (Shared/Vehicle/VehicleCatalog.lua); berth resolution (Server/Vehicles/
	VehicleBerths.lua); placement arithmetic (Server/Vehicles/VehiclePlacement.lua); or the Vehicles
	tab itself (Client/UI/Screens/DevTools/DevMenu/VehiclesTab.lua).
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local RemoteHandler = require(ReplicatedStorage.Shared.RemoteHandler)
local Trove = require(ReplicatedStorage.Shared.Trove)
local VehicleCatalog = require(ReplicatedStorage.Shared.Vehicle.VehicleCatalog)
local VehicleConstants = require(ReplicatedStorage.Shared.Vehicle.VehicleConstants)
local VehicleTypes = require(ReplicatedStorage.Shared.Vehicle.VehicleTypes)

local AdminGate = require(ServerScriptService.Server.Network.AdminGate)
local GameplayEvents = require(ServerScriptService.Server.Events.GameplayEvents)
local VehicleBerths = require(ServerScriptService.Server.Vehicles.VehicleBerths)
local VehiclePlacement = require(ServerScriptService.Server.Vehicles.VehiclePlacement)

local logger = Logger.scope("VehicleManager")

local VehicleManager = {}

type VehicleDefinition = VehicleTypes.VehicleDefinition
type RegistryRejection = VehicleTypes.RegistryRejection

-- One live spawned vehicle. Never handed to a caller: this System's public surface is functions and
-- the wire-safe snapshots in VehicleTypes, never this record.
type LiveVehicle = {
	InstanceId: string,
	VehicleId: string,
	DisplayName: string,
	Model: Model,
	-- Cached from the definition rather than re-measured, because a hull's bounding box after it has
	-- been welded and flown is not the one the placement math was done against.
	Size: Vector3,
	OwnerUserId: number,
	SpawnedAt: number,
	BerthName: string?,
	-- os.clock() at the moment the owner disconnected, or nil while they are present. The reclaim
	-- sweep's only input -- see this file's header on why it re-arms rather than firing when the hull
	-- is occupied.
	OwnerLeftAt: number?,
	-- Watches for the Model leaving the world by any route this System did not take (a builder
	-- deleting it in Studio, a future System destroying it) so the live table can never hold a
	-- tombstone.
	Trove: Trove.TroveInstance,
}

-- === State ===

local definitions: { VehicleDefinition } = {}
local definitionsById: { [string]: VehicleDefinition } = {}
local rejections: { RegistryRejection } = {}
local registryPath = "<unresolved>"

local live: { [string]: LiveVehicle } = {}
local nextInstanceNumber = 0
local sweepAccumulator = 0

local spawnFolder: Folder? = nil

local rateLimiter = RateLimiter.New(Constants.NetworkBudget.MaxRemoteCallsPerSecondPerPlayer)

-- === Registry ===

-- The registry folder, searched across VehicleConstants.Registry.SearchOrder. Returns the folder and
-- the readable path it was found at, so every log line and the Dev Menu itself can say exactly which
-- one won -- "the registry is empty" and "the registry is somewhere else" are otherwise the same
-- message.
local function resolveRegistryRoot(): (Instance?, string)
	for _, serviceName in VehicleConstants.Registry.SearchOrder do
		local ok, service = pcall(function()
			return game:GetService(serviceName :: any)
		end)
		if not ok or not service then
			continue
		end
		local found = (service :: Instance):FindFirstChild(VehicleConstants.Registry.FolderName)
		if found then
			return found, serviceName .. "." .. VehicleConstants.Registry.FolderName
		end
	end
	return nil, "<not found>"
end

-- Re-reads the registry. Safe to call at any time and deliberately does NOT touch anything already
-- spawned: a live vehicle keeps the definition it was cloned from, so re-scanning while somebody is
-- flying a hull cannot change that hull's cap, name or ownership rule underneath them.
function VehicleManager.LoadRegistry(): (number, { RegistryRejection })
	local root, path = resolveRegistryRoot()
	registryPath = path

	if not root then
		definitions = {}
		definitionsById = {}
		rejections = {}
		logger:warn("No vehicle registry folder found", {
			folderName = VehicleConstants.Registry.FolderName,
			searched = table.concat(VehicleConstants.Registry.SearchOrder, ", "),
		})
		return 0, rejections
	end

	-- See VehicleConstants' own header: the last two search entries are a migration aid, not
	-- supported homes, and Workspace is the one that is actively harmful rather than merely wasteful.
	local rootService = root.Parent
	if rootService and rootService.Name ~= VehicleConstants.Registry.PreferredService then
		if rootService == Workspace then
			logger:warn(
				"Vehicle registry is in Workspace -- templates are live, replicated, physically simulated"
					.. " models, and any gameplay tags on them are already being read as real instances."
					.. " Move the folder to ServerStorage.",
				{ path = path }
			)
		else
			logger:warn(
				"Vehicle registry is not in ServerStorage -- every client downloads every template at"
					.. " join whether or not one is ever spawned.",
				{ path = path }
			)
		end
	end

	definitions, rejections = VehicleCatalog.ReadRegistry(root)
	definitionsById = {}
	for _, definition in definitions do
		definitionsById[definition.Id] = definition
	end

	logger:info("Vehicle registry loaded", {
		path = path,
		count = #definitions,
		rejected = #rejections,
	})
	for _, rejection in rejections do
		logger:warn("Registry entry rejected", { entry = rejection.Path, reason = rejection.Reason })
	end

	return #definitions, rejections
end

-- === Live bookkeeping ===

local function getSpawnFolder(): Folder
	local cached = spawnFolder
	if cached and cached.Parent ~= nil then
		return cached
	end

	local existing = Workspace:FindFirstChild(VehicleConstants.Registry.SpawnFolderName)
	if existing and existing:IsA("Folder") then
		spawnFolder = existing
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = VehicleConstants.Registry.SpawnFolderName
	folder.Parent = Workspace
	spawnFolder = folder
	return folder
end

-- Every route out of the live table ends here, the same "one implementation of release" rule
-- BlimpSystem's own Dismount keeps: an entry dropped from `live` without its Trove cleaned leaves a
-- connection watching a destroyed Model forever, and a Model destroyed without its entry dropped
-- leaves a tombstone the Dev Menu offers to despawn again.
local function retire(record: LiveVehicle, destroyModel: boolean): ()
	live[record.InstanceId] = nil
	record.Trove:Clean()
	if destroyModel and record.Model.Parent ~= nil then
		record.Model:Destroy()
	end
end

local function liveCountOf(vehicleId: string): number
	local count = 0
	for _, record in live do
		if record.VehicleId == vehicleId then
			count += 1
		end
	end
	return count
end

-- The longest-lived entry matching `vehicleId`, or the longest-lived overall when `vehicleId` is nil.
local function oldest(vehicleId: string?): LiveVehicle?
	local best: LiveVehicle? = nil
	for _, record in live do
		if vehicleId ~= nil and record.VehicleId ~= vehicleId then
			continue
		end
		if best == nil or record.SpawnedAt < best.SpawnedAt then
			best = record
		end
	end
	return best
end

-- True while any player's root sits inside this hull's own bounding radius plus a margin -- see this
-- file's header on why the owner-leave reclaim consults this rather than asking BlimpSystem who is
-- mounted.
local function isOccupied(record: LiveVehicle): boolean
	local radius = VehiclePlacement.HorizontalRadius(record.Size) + VehicleConstants.Lifetime.OccupancyMarginStuds
	local origin = record.Model:GetPivot().Position
	for _, player in Players:GetPlayers() do
		local _, _, root = CharacterUtil.LiveRig(player)
		if root and (root.Position - origin).Magnitude <= radius then
			return true
		end
	end
	return false
end

-- === Placement ===

-- The Y of whatever solid ground is under `position`, or nil over open air. Excludes the spawn folder
-- (a hull must never be seated on another hull -- that stacks two spawns into a tower that the
-- physics solver then unstacks violently) and every player's character, so an admin standing on the
-- pad does not become the ground.
local function probeGroundY(position: Vector3): number?
	local ignore: { Instance } = { getSpawnFolder() }
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character then
			table.insert(ignore, character)
		end
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore

	local hit = Workspace:Raycast(
		position + Vector3.new(0, VehicleConstants.Spawn.GroundProbeStuds * 0.5, 0),
		Vector3.new(0, -VehicleConstants.Spawn.GroundProbeStuds, 0),
		params
	)
	if not hit then
		return nil
	end
	return hit.Position.Y
end

-- === Public API ===

export type SpawnOptions = {
	-- Whose spawn this is. nil for a server-initiated one, which is never reclaimed on a leave.
	Owner: Player?,
	-- The berth to place it at. A missing/unknown/wrong-kind/occupied berth is an error rather than a
	-- silent fallback to the caller's own position: somebody who named a dock meant the dock, and
	-- quietly putting a hull somewhere else is how a spawn "works" and nobody can find the result.
	BerthName: string?,
	-- Where to place it when no berth is named. Required in that case -- this System never invents a
	-- position out of nothing.
	Origin: CFrame?,
}

-- Spawns one vehicle. Returns the live Model, or nil plus a Reason string using the same vocabulary
-- every admin-gated Result in this codebase already speaks.
function VehicleManager.Spawn(vehicleId: string, options: SpawnOptions): (Model?, string?)
	local definition = definitionsById[vehicleId]
	if not definition then
		return nil, "UnknownVehicle"
	end

	local pivot: CFrame
	local berthName: string? = nil

	if options.BerthName ~= nil then
		local berths = VehicleBerths.Resolve()
		local berth = VehicleBerths.Find(berths, options.BerthName)
		if not berth then
			return nil, "UnknownBerth"
		end
		if not VehicleBerths.Accepts(berth, vehicleId) then
			return nil, "BerthRejectsVehicle"
		end

		local pivots: { Vector3 } = {}
		for _, record in live do
			table.insert(pivots, record.Model:GetPivot().Position)
		end
		if VehicleBerths.IsOccupied(berth, pivots) then
			return nil, "BerthOccupied"
		end

		pivot = VehiclePlacement.AtBerth(
			berth.Part.CFrame,
			berth.Part.Size,
			definition.Size,
			VehicleConstants.Spawn.GroundClearanceStuds
		)
		berthName = berth.Name
	else
		local origin = options.Origin
		if not origin then
			return nil, "NoSpawnOrigin"
		end
		pivot = VehiclePlacement.InFrontOf(origin, definition.Size, VehicleConstants.Spawn.GapStuds)
		local groundY = probeGroundY(pivot.Position)
		if groundY ~= nil then
			pivot = VehiclePlacement.SeatOnGround(
				pivot,
				definition.Size,
				groundY,
				VehicleConstants.Spawn.GroundClearanceStuds
			)
		end
	end

	-- Caps, checked in this order so a per-vehicle overflow recycles that vehicle rather than
	-- evicting somebody else's unrelated hull -- see this file's header on eviction vs. refusal.
	local perVehicleCap = math.min(definition.MaxLive, VehicleConstants.Limits.MaxLiveTotal)
	if liveCountOf(vehicleId) >= perVehicleCap then
		local evicted = oldest(vehicleId)
		if evicted then
			logger:info("Evicting oldest to stay under the per-vehicle cap", {
				vehicleId = vehicleId,
				cap = perVehicleCap,
				evicted = evicted.InstanceId,
			})
			retire(evicted, true)
		end
	end

	local total = 0
	for _ in live do
		total += 1
	end
	if total >= VehicleConstants.Limits.MaxLiveTotal then
		local evicted = oldest(nil)
		if evicted then
			logger:info("Evicting oldest to stay under the server cap", {
				cap = VehicleConstants.Limits.MaxLiveTotal,
				evicted = evicted.InstanceId,
			})
			retire(evicted, true)
		end
	end

	nextInstanceNumber += 1
	local instanceId = string.format("%s#%d", vehicleId, nextInstanceNumber)

	local model = definition.Template:Clone()
	model.Name = definition.DisplayName

	-- THE TAGS COME OFF BEFORE THE MODEL MOVES, AND GO BACK ON LAST. This is the single most
	-- load-bearing ordering in this file, and getting it wrong does not produce an error anywhere -- it
	-- produces a vehicle that exists, looks right, and flies wrongly.
	--
	-- :Clone() copies CollectionService tags, so the clone is a fully-tagged Blimp from the instant it
	-- is created -- while it is still unparented and still sitting at the TEMPLATE's CFrame. Every
	-- System that discovers content by tag registers it right there, and BlimpSystem.registerBlimp in
	-- particular reads geometry ONCE, at registration, into three values it never recomputes:
	--
	--   * BlimpDrive.NewState(assembly.Root.CFrame) seeds the flight integrator's Target from where the
	--     hull is and which way it points. Seed that from the template's CFrame, then PivotTo the hull
	--     somewhere else, and the integrator spends the rest of the session steering a hull that is not
	--     where it thinks it is -- which is what a pilot experiences as the turning being broken.
	--   * BlimpTagging.ResolveStandOffset drops a Workspace raycast to find which side of the wheel has
	--     deck under it. A model that is not in Workspace is not hit by a Workspace raycast, so BOTH
	--     probes miss, the deck test is skipped entirely, and the bow falls through to the fallback
	--     branch -- the exact "pilot on the wrong side of the wheel AND flying astern" pair that
	--     function's own header documents as one bug wearing two faces.
	--   * MinAltitude is clamped to the hull's altitude at registration, so a template parked at y=0
	--     hands the spawned hull a floor of zero.
	--
	-- So: strip the Model's own tags, put the hull exactly where it is going, parent it, and only then
	-- give the tags back. Every tag-watching System then registers a hull already standing in its final
	-- place in the world, which is the only state any of them were written to be handed.
	--
	-- Only the MODEL's tags are deferred. The tags on its descendants (a Blimp's helm, furnace and
	-- exhaust parts) must still be present at that moment, because resolving them is part of what
	-- registration does.
	--
	-- Correct under either CollectionService behaviour, which is why it is written this way rather than
	-- as a guess about which one is live: if the added-signal fires on the tag write, stripping stops
	-- the early fire; if it fires on entering the DataModel, the model is parented untagged and so
	-- never fires early either. Both paths end in exactly one registration, at the right time.
	local deferredTags = CollectionService:GetTags(model)
	for _, tag in deferredTags do
		CollectionService:RemoveTag(model, tag)
	end

	model:SetAttribute(VehicleConstants.Attributes.InstanceId, instanceId)
	model:SetAttribute(VehicleConstants.Attributes.VehicleId, vehicleId)
	model:SetAttribute(VehicleConstants.Attributes.OwnerUserId, if options.Owner then options.Owner.UserId else 0)

	model:PivotTo(pivot)
	model.Parent = getSpawnFolder()

	-- In place, in the world -- now it is a Blimp.
	for _, tag in deferredTags do
		CollectionService:AddTag(model, tag)
	end
	CollectionService:AddTag(model, VehicleConstants.Tags.Vehicle)

	local trove = Trove.New()
	local record: LiveVehicle = {
		InstanceId = instanceId,
		VehicleId = vehicleId,
		DisplayName = definition.DisplayName,
		Model = model,
		Size = definition.Size,
		OwnerUserId = if options.Owner then options.Owner.UserId else 0,
		SpawnedAt = os.clock(),
		BerthName = berthName,
		OwnerLeftAt = nil,
		Trove = trove,
	}
	live[instanceId] = record

	-- Destroyed by anything other than this System -- a builder in Studio, a future System -- must
	-- still drop the entry. Guarded on `live[instanceId] == record` so retire's own :Destroy() call
	-- re-entering here is a no-op rather than a double clean.
	trove:Connect(model.AncestryChanged, function()
		if model.Parent == nil and live[instanceId] == record then
			logger:debug("Vehicle removed externally", { instanceId = instanceId })
			retire(record, false)
		end
	end)

	logger:info("Vehicle spawned", {
		instanceId = instanceId,
		vehicleId = vehicleId,
		berth = berthName,
		owner = if options.Owner then options.Owner.Name else "<server>",
	})
	return model, nil
end

function VehicleManager.Despawn(instanceId: string): boolean
	local record = live[instanceId]
	if not record then
		return false
	end
	logger:info("Vehicle despawned", { instanceId = instanceId })
	retire(record, true)
	return true
end

-- Clears every live vehicle, or only those owned by `ownerUserId` when one is given. Returns how many
-- went.
function VehicleManager.DespawnAll(ownerUserId: number?): number
	local doomed: { LiveVehicle } = {}
	for _, record in live do
		if ownerUserId ~= nil and record.OwnerUserId ~= ownerUserId then
			continue
		end
		table.insert(doomed, record)
	end
	for _, record in doomed do
		retire(record, true)
	end
	if #doomed > 0 then
		logger:info("Vehicles cleared", { count = #doomed, ownerUserId = ownerUserId })
	end
	return #doomed
end

function VehicleManager.GetModel(instanceId: string): Model?
	local record = live[instanceId]
	return if record then record.Model else nil
end

-- The whole Dev Menu tab's state -- see VehicleConstants.RemoteNames.GetState on why this is one
-- snapshot rather than four independently-fetchable lists.
function VehicleManager.Snapshot(): VehicleTypes.VehicleStateResult
	local now = os.clock()

	local catalog: { VehicleTypes.VehicleCatalogEntry } = {}
	for _, definition in definitions do
		table.insert(catalog, {
			Id = definition.Id,
			DisplayName = definition.DisplayName,
			Kind = definition.Kind,
			MaxLive = definition.MaxLive,
			FootprintStuds = math.floor(math.max(definition.Size.X, definition.Size.Z) + 0.5),
			LiveCount = liveCountOf(definition.Id),
		})
	end

	local liveInfos: { VehicleTypes.LiveVehicleInfo } = {}
	local pivots: { Vector3 } = {}
	for _, record in live do
		local position = record.Model:GetPivot().Position
		table.insert(pivots, position)

		local owner = if record.OwnerUserId ~= 0 then Players:GetPlayerByUserId(record.OwnerUserId) else nil
		local ownerName = if owner
			then owner.Name
			elseif record.OwnerUserId ~= 0 then string.format("(left, id %d)", record.OwnerUserId)
			else "Server"

		table.insert(liveInfos, {
			InstanceId = record.InstanceId,
			VehicleId = record.VehicleId,
			DisplayName = record.DisplayName,
			OwnerUserId = record.OwnerUserId,
			OwnerName = ownerName,
			Position = position,
			AgeSeconds = now - record.SpawnedAt,
			Occupied = isOccupied(record),
			BerthName = record.BerthName,
		})
	end
	table.sort(liveInfos, function(a, b)
		return a.InstanceId < b.InstanceId
	end)

	local berthInfos: { VehicleTypes.VehicleBerthInfo } = {}
	for _, berth in VehicleBerths.Resolve() do
		table.insert(berthInfos, {
			Name = berth.Name,
			Accepts = berth.Accepts,
			Occupied = VehicleBerths.IsOccupied(berth, pivots),
		})
	end

	return {
		Success = true,
		Catalog = catalog,
		Live = liveInfos,
		Berths = berthInfos,
		RegistryPath = registryPath,
		Rejections = rejections,
	}
end

-- === Reclaim sweep ===

local function sweep(): ()
	local grace = VehicleConstants.Lifetime.OwnerLeaveGraceSeconds
	local now = os.clock()

	local doomed: { LiveVehicle } = {}
	for _, record in live do
		local leftAt = record.OwnerLeftAt
		if leftAt == nil or now - leftAt < grace then
			continue
		end
		if isOccupied(record) then
			-- Re-arm rather than fire. See this file's header: the alternative is dropping whoever is
			-- still aboard out of the sky two minutes after somebody unrelated disconnected.
			record.OwnerLeftAt = now
			continue
		end
		table.insert(doomed, record)
	end

	for _, record in doomed do
		logger:info("Reclaiming a vehicle whose owner left", {
			instanceId = record.InstanceId,
			ownerUserId = record.OwnerUserId,
		})
		retire(record, true)
	end
end

local function onHeartbeatTick(deltaTime: number): ()
	sweepAccumulator += deltaTime
	if sweepAccumulator < VehicleConstants.Lifetime.SweepIntervalSeconds then
		return
	end
	sweepAccumulator = 0
	sweep()
end

-- === Remote handlers ===

local INTERNAL_ERROR_RESULT = { Success = false, Reason = "InternalError" }

local function handleGetState(player: Player): VehicleTypes.VehicleStateResult
	local allowed, reason = AdminGate.Check(player, "VehicleGetState", rateLimiter)
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end
	return VehicleManager.Snapshot()
end

local function handleSpawn(
	player: Player,
	rawVehicleId: unknown,
	rawBerthName: unknown
): VehicleTypes.VehicleSpawnResult
	local allowed, reason = AdminGate.Check(player, "VehicleSpawn", rateLimiter)
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end
	if typeof(rawVehicleId) ~= "string" then
		return { Success = false, Reason = "InvalidRequest" }
	end
	if rawBerthName ~= nil and typeof(rawBerthName) ~= "string" then
		return { Success = false, Reason = "InvalidRequest" }
	end

	local berthName = rawBerthName :: string?
	local origin: CFrame? = nil
	if berthName == nil then
		-- Only needed for a free spawn; a berth spawn is legal from a dead or unloaded character,
		-- which is worth keeping since a berth is exactly what you use when you are not standing
		-- somewhere sensible.
		local _, _, root = CharacterUtil.LiveRig(player)
		if not root then
			return { Success = false, Reason = "NoCharacter" }
		end
		origin = root.CFrame
	end

	local model, failure = VehicleManager.Spawn(rawVehicleId :: string, {
		Owner = player,
		BerthName = berthName,
		Origin = origin,
	})
	if not model then
		return { Success = false, Reason = failure or "SpawnFailed" }
	end

	return {
		Success = true,
		InstanceId = model:GetAttribute(VehicleConstants.Attributes.InstanceId) :: string,
	}
end

local function handleDespawn(player: Player, rawInstanceId: unknown): VehicleTypes.VehicleActionResult
	local allowed, reason = AdminGate.Check(player, "VehicleDespawn", rateLimiter)
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end
	if typeof(rawInstanceId) ~= "string" then
		return { Success = false, Reason = "InvalidRequest" }
	end
	if not VehicleManager.Despawn(rawInstanceId :: string) then
		return { Success = false, Reason = "UnknownInstance" }
	end
	return { Success = true }
end

local function handleDespawnAll(player: Player): VehicleTypes.VehicleActionResult
	local allowed, reason = AdminGate.Check(player, "VehicleDespawnAll", rateLimiter)
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end
	VehicleManager.DespawnAll(nil)
	return { Success = true }
end

local function handleReloadRegistry(player: Player): VehicleTypes.VehicleStateResult
	local allowed, reason = AdminGate.Check(player, "VehicleReloadRegistry", rateLimiter)
	if not allowed then
		return { Success = false, Reason = reason :: string }
	end
	VehicleManager.LoadRegistry()
	return VehicleManager.Snapshot()
end

type RemoteHandlerSpec = {
	RemoteKey: string,
	Handler: (Player, ...any) -> any,
}

-- Same data-driven registration DevMenuSystem's own REMOTE_HANDLERS uses, for the same reason: five
-- hand-duplicated create-and-wrap blocks is five places for one of them to be forgotten.
local REMOTE_HANDLERS: { RemoteHandlerSpec } = {
	{ RemoteKey = "GetState", Handler = handleGetState :: any },
	{ RemoteKey = "Spawn", Handler = handleSpawn :: any },
	{ RemoteKey = "Despawn", Handler = handleDespawn :: any },
	{ RemoteKey = "DespawnAll", Handler = handleDespawnAll :: any },
	{ RemoteKey = "ReloadRegistry", Handler = handleReloadRegistry :: any },
}

function VehicleManager.Init(): ()
	VehicleManager.LoadRegistry()

	for _, spec in REMOTE_HANDLERS do
		local remoteName = VehicleConstants.RemoteNames[spec.RemoteKey]
		local remote = NetworkBridge.CreateRemoteFunction(remoteName)
		remote.OnServerInvoke = RemoteHandler.WrapInvoke(logger, spec.RemoteKey, INTERNAL_ERROR_RESULT, spec.Handler)
	end

	PlayerLifecycle.BindAllPlayers({
		Scope = "VehicleManager",
		OnPlayer = function(player: Player)
			-- A rejoin inside the grace window cancels the reclaim outright rather than merely
			-- resetting its clock: the vehicle is theirs again, and there is nothing left to reclaim.
			for _, record in live do
				if record.OwnerUserId == player.UserId then
					record.OwnerLeftAt = nil
				end
			end
		end,
		OnPlayerRemoving = function(player: Player)
			rateLimiter:Clear(player)
			for _, record in live do
				if record.OwnerUserId ~= player.UserId then
					continue
				end
				local definition = definitionsById[record.VehicleId]
				-- A definition that has since been re-scanned away leaves nothing to consult, so the
				-- safe reading is the default: reclaim it. An orphaned hull nobody can identify is
				-- exactly what the sweep is for.
				if definition == nil or definition.DespawnOnOwnerLeave then
					record.OwnerLeftAt = os.clock()
				end
			end
		end,
	})

	GameplayEvents.OnHeartbeatTick(onHeartbeatTick)

	logger:info("VehicleManager.Init() complete")
end

-- Returned plain rather than cast to Types.SystemModule, unlike BlimpSystem next door: this module's
-- Spawn/Despawn/Snapshot surface is meant to be called by other server code (a quest that berths a
-- ferry, a world event that clears the sky), and that cast erases every function but Init.
return VehicleManager
