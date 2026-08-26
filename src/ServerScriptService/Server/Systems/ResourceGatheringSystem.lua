--!strict
--[[
	ResourceGatheringSystem.lua

	Owns: coal mining and water collection, end to end -- discovering CollectionService-tagged
	CoalDeposit/WaterSource parts, putting a ProximityPrompt on each, crediting the gathering player's
	own carried coal/water (Types.PlayerProfile.blimpFuel) on a successful trigger, and (coal only)
	putting a depleted vein on its own respawn timer.

	ONE SYSTEM OVER Shared/Gathering/GatheringConstants.lua's PER-RESOURCE CONFIG TABLE, not two
	near-identical Systems. Mining and collection are the same mechanic shape -- tag a part, hold a
	ProximityPrompt, grant a carried amount, gate re-use -- with exactly two real differences (coal
	deposits deplete and respawn, water sources don't; the yield/hold numbers), both of which the
	config table already carries. A second System would only duplicate this one's tag-discovery and
	prompt-wiring code for no behavioural difference the config table couldn't already express.

	FEEDS THE BLIMP FUEL SYSTEM AND OWNS NOTHING ABOUT A BLIMP. A gathered resource lands in the
	player's own carried total, clamped at Shared/Blimp/BlimpConstants.Carry's own cap -- it is
	Server/Systems/BlimpSystem.depositFuel that later moves it into an actual blimp's tank, at a
	furnace/water-tank prompt this module never touches. This module has no notion of a blimp, a mount,
	or a pilot at all.

	Also owns SpawnDebugNode, a dev/test-only convenience the Dev Menu's "Spawn" tab calls to place a
	tagged Part near the requesting admin -- the same "spawn near me" shape DevMenuSystem already uses
	for DebugDummySystem.Spawn -- for testing before a builder has placed any real world nodes.

	Does not own: the tag names or per-resource tuning (Shared/Gathering/GatheringConstants.lua), the
	carried-resource cap (Shared/Blimp/BlimpConstants.Carry), or what a deposit into a blimp's tank does
	with a carried resource (Server/Systems/BlimpSystem.lua).
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local BlimpConstants = require(ReplicatedStorage.Shared.Blimp.BlimpConstants)
local GatheringConstants = require(ReplicatedStorage.Shared.Gathering.GatheringConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local Trove = require(ReplicatedStorage.Shared.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local PlayerDataSystem = require(script.Parent.PlayerDataSystem)

local logger = Logger.scope("ResourceGatheringSystem")

local ResourceGatheringSystem = {}

local carriedFuelUpdatedRemote: RemoteEvent? = nil

type NodeRecord = {
	Part: BasePart,
	Kind: GatheringConstants.ResourceKind,
	Config: GatheringConstants.ResourceConfig,
	Prompt: ProximityPrompt,
	Trove: Trove.TroveInstance,
}

-- One entry per registered node, keyed by the tagged part itself -- small (a map has a handful of
-- gathering nodes), same shape as BlimpSystem's own `blimps` registry.
local nodes: { [BasePart]: NodeRecord } = {}

-- One shared bucket per resource kind, not per node -- see GatheringConstants.MaxGathersPerSecond's
-- own comment.
local gatherRateLimiters: { [GatheringConstants.ResourceKind]: RateLimiter.RateLimiterInstance } = {
	Coal = RateLimiter.New(GatheringConstants.MaxGathersPerSecond),
	Water = RateLimiter.New(GatheringConstants.MaxGathersPerSecond),
}

local function setPromptEnabled(prompt: ProximityPrompt, enabled: boolean): ()
	if prompt.Parent then
		prompt.Enabled = enabled
	end
end

-- The cap that actually matters is the BLIMP TANK's own capacity -- see BlimpConstants.Carry's own
-- header on why the two are tuned together rather than independently.
local function carryCapFor(kind: GatheringConstants.ResourceKind): number
	return if kind == "Coal" then BlimpConstants.Carry.CoalCap else BlimpConstants.Carry.WaterCap
end

-- Server -> `player` only. Reads the CURRENT profile rather than taking Coal/Water as arguments, so a
-- caller can never push a stale or hand-computed pair -- every caller (handleGather below, Server/
-- Systems/BlimpSystem.depositFuel, and the OnProfileLoaded catch-up in Init) just says "something
-- about this player's carried fuel changed," never what it changed to. Safe to call before the remote
-- exists or before a profile has loaded -- both are silent no-ops, not errors.
function ResourceGatheringSystem.PushCarriedFuelUpdate(player: Player): ()
	local remote = carriedFuelUpdatedRemote
	if not remote then
		return
	end
	local profile = PlayerDataSystem.GetProfile(player)
	if not profile then
		return
	end
	local payload: GatheringConstants.CarriedFuelUpdatePayload = {
		Coal = profile.blimpFuel.Coal,
		Water = profile.blimpFuel.Water,
	}
	remote:FireClient(player, payload)
end

-- A gather that would push a player over their own cap is simply CAPPED here rather than refused
-- outright -- the trip still wasn't wasted, a partial top-up beats an all-or-nothing rejection a
-- player has no way to see coming.
local function handleGather(player: Player, node: NodeRecord): ()
	local limiter = gatherRateLimiters[node.Kind]
	if limiter:IsLimited(player) then
		return
	end

	local profile = PlayerDataSystem.GetProfile(player)
	if not profile then
		return
	end
	local carried = if node.Kind == "Coal" then profile.blimpFuel.Coal else profile.blimpFuel.Water
	local room = math.max(0, carryCapFor(node.Kind) - carried)
	if room <= 0 then
		return
	end
	local granted = math.min(node.Config.Yield, room)

	PlayerDataSystem.Transform(player, function(mutableProfile)
		if node.Kind == "Coal" then
			mutableProfile.blimpFuel.Coal += granted
		else
			mutableProfile.blimpFuel.Water += granted
		end
	end)
	ResourceGatheringSystem.PushCarriedFuelUpdate(player)

	logger:debug("Resource gathered", {
		player = player.Name,
		kind = node.Kind,
		granted = granted,
		node = node.Part:GetFullName(),
	})

	local respawnSeconds = node.Config.RespawnSeconds
	if respawnSeconds then
		setPromptEnabled(node.Prompt, false)
		task.delay(respawnSeconds, function()
			setPromptEnabled(node.Prompt, true)
		end)
	end
end

local function buildPrompt(part: BasePart, config: GatheringConstants.ResourceConfig): ProximityPrompt
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "GatherPrompt"
	prompt.ActionText = config.ActionText
	prompt.ObjectText = config.ObjectText
	prompt.MaxActivationDistance = config.MaxActivationDistance
	prompt.HoldDuration = config.HoldDuration
	prompt.RequiresLineOfSight = false
	prompt.Parent = part
	return prompt
end

local function registerNode(part: BasePart, kind: GatheringConstants.ResourceKind): ()
	if nodes[part] then
		return
	end
	local config = GatheringConstants.Resources[kind]
	local trove = Trove.New()
	local prompt = trove:Add(buildPrompt(part, config))

	local record: NodeRecord = {
		Part = part,
		Kind = kind,
		Config = config,
		Prompt = prompt,
		Trove = trove,
	}
	nodes[part] = record

	trove:Connect(prompt.Triggered, function(player: Player)
		handleGather(player, record)
	end)
end

local function unregisterNode(part: BasePart): ()
	local record = nodes[part]
	if not record then
		return
	end
	nodes[part] = nil
	record.Trove:Clean()
end

-- Present-at-boot nodes and future ones through the same function, and GetTagged read before the
-- Added signal is connected -- the same ordering BlimpSystem.Init uses for its own tag, and for the
-- same reason: a part tagged in the window between the two would otherwise register twice, and
-- registerNode's own guard is what makes the overlap harmless in the other direction.
local function watchTag(tagName: string, kind: GatheringConstants.ResourceKind): ()
	for _, tagged in CollectionService:GetTagged(tagName) do
		if tagged:IsA("BasePart") then
			registerNode(tagged :: BasePart, kind)
		end
	end
	CollectionService:GetInstanceAddedSignal(tagName):Connect(function(instance: Instance)
		if instance:IsA("BasePart") then
			registerNode(instance :: BasePart, kind)
		end
	end)
	CollectionService:GetInstanceRemovedSignal(tagName):Connect(function(instance: Instance)
		if instance:IsA("BasePart") then
			unregisterNode(instance :: BasePart)
		end
	end)
end

-- Dev/test convenience only ("Spawn" tab, Server/Systems/DevMenuSystem.handleFillCarriedFuel) --
-- sets BOTH carried pools to their cap and pushes the update, returning whether the profile was
-- actually written.
--
-- LIVES HERE RATHER THAN IN DevMenuSystem, even though nothing but the Dev Menu calls it, for the
-- same reason BlimpSystem.depositFuel calls PushCarriedFuelUpdate instead of firing the remote
-- itself: this module owns Types.PlayerProfile.blimpFuel, and a second writer reaching around it
-- would be the point at which "who is allowed to change a player's carried total" stops having an
-- answer. The Dev Menu owns the authorization; this owns the field.
function ResourceGatheringSystem.FillCarriedFuel(player: Player): boolean
	local filled = PlayerDataSystem.Transform(player, function(profile)
		profile.blimpFuel.Coal = carryCapFor("Coal")
		profile.blimpFuel.Water = carryCapFor("Water")
	end)
	if not filled then
		return false
	end
	ResourceGatheringSystem.PushCarriedFuelUpdate(player)
	logger:info("Carried fuel filled by dev tool", { player = player.Name })
	return true
end

-- Dev/test convenience only ("Spawn" tab, Server/Systems/DevMenuSystem.lua's handleSpawnCoalDeposit/
-- handleSpawnWaterSource) -- lazily-created holding folder for whatever a tester spawns this way,
-- same shape as DebugDummySystem.lua's own DebugDummies folder.
local debugNodeFolderInstance: Folder? = nil
local function debugNodeFolder(): Folder
	local existing = debugNodeFolderInstance
	if existing and existing.Parent ~= nil then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "DebugResourceNodes"
	folder.Parent = Workspace
	debugNodeFolderInstance = folder
	return folder
end

-- Visual-only, and ONLY for the debug spawn below -- a real world node's look is a builder's own call
-- in Studio on their own placed geometry (GatheringConstants.lua's own header: "nothing else is
-- required" beyond the tag). This exists purely so a tester's "Spawn Coal Deposit"/"Spawn Water
-- Source" button hands them something visibly distinct to walk up to.
local DEBUG_NODE_APPEARANCE: {
	[GatheringConstants.ResourceKind]: { Size: Vector3, Color: Color3, Material: Enum.Material, Transparency: number },
} =
	{
		Coal = {
			Size = Vector3.new(3, 3, 3),
			Color = Color3.fromRGB(30, 28, 26),
			Material = Enum.Material.Slate,
			Transparency = 0,
		},
		Water = {
			Size = Vector3.new(4, 1, 4),
			Color = Color3.fromRGB(70, 140, 200),
			Material = Enum.Material.Glass,
			Transparency = 0.3,
		},
	}

-- Builds one plain, tagged Part at `spawnCFrame` and hands it back -- registration is automatic:
-- CollectionService:AddTag fires the same GetInstanceAddedSignal watchTag above is already listening
-- for, so there is nothing else to wire up here, the identical path a builder's own placed geometry
-- goes through. Called by DevMenuSystem's two "Spawn" tab actions the same way that System already
-- calls DebugDummySystem.Spawn.
function ResourceGatheringSystem.SpawnDebugNode(kind: GatheringConstants.ResourceKind, spawnCFrame: CFrame): BasePart
	local appearance = DEBUG_NODE_APPEARANCE[kind]
	local part = Instance.new("Part")
	part.Name = if kind == "Coal" then "CoalDepositDebug" else "WaterSourceDebug"
	part.Anchored = true
	part.CanCollide = true
	part.Size = appearance.Size
	part.Color = appearance.Color
	part.Material = appearance.Material
	part.Transparency = appearance.Transparency
	part.CFrame = spawnCFrame
	part.Parent = debugNodeFolder()

	CollectionService:AddTag(part, GatheringConstants.Resources[kind].Tag)

	return part
end

function ResourceGatheringSystem.Init(): ()
	carriedFuelUpdatedRemote = NetworkBridge.CreateRemoteEvent(GatheringConstants.RemoteNames.CarriedFuelUpdated)

	watchTag(GatheringConstants.Tags.CoalDeposit, "Coal")
	watchTag(GatheringConstants.Tags.WaterSource, "Water")

	-- Catch-up for a joining/rejoining player -- without this, a player who logged out mid-stockpile
	-- would see nothing on their HUD until their NEXT gather, even though their real carried total
	-- (persisted in Types.PlayerProfile.blimpFuel) is already sitting there. Hooked off
	-- PlayerDataSystem.OnProfileLoaded rather than PlayerLifecycle's own OnPlayer, which fires
	-- present-at-Init-and-future-alike with no guarantee the profile has actually finished loading yet
	-- -- this event is PlayerDataSystem's own "the profile is now safe to read" signal.
	PlayerDataSystem.OnProfileLoaded.Event:Connect(function(player: Player)
		ResourceGatheringSystem.PushCarriedFuelUpdate(player)
	end)

	-- No character binding needed -- gathering has no per-life state, only a per-player rate-limit
	-- bucket to release on leave. Still routed through PlayerLifecycle rather than a raw
	-- Players.PlayerRemoving:Connect, matching every other System in this codebase (QiSystem.lua's own
	-- Init is the closest precedent: PlayerDataSystem-only dependency, no character binding either).
	PlayerLifecycle.BindAllPlayers({
		Scope = "ResourceGatheringSystem",
		OnPlayerRemoving = function(player: Player)
			gatherRateLimiters.Coal:Clear(player)
			gatherRateLimiters.Water:Clear(player)
		end,
	})

	logger:info("ResourceGatheringSystem.Init() complete")
end

return ResourceGatheringSystem :: Types.SystemModule
