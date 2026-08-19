--!strict
--[[
	NetworkBridge.lua

	Owns: every RemoteEvent/RemoteFunction instance, per software-architecture.md ("networking
	goes through one bridge"). Does not own validation of payload contents -- each System
	validates the requests it receives; this module only owns *instancing and lookup* of the
	remotes themselves, so the network surface stays auditable in one place and the call-budget
	in performance-optimization.md can be enforced centrally.

	Remotes are created here by the owning System during server boot (Create*) -- never instanced
	ad hoc inside a System module. Both sides look them up with Get*.

	LOOKUPS ARE MEMOIZED, and that is a contract, not an optimization detail. Get* used to walk the
	DataModel on every call -- a FindFirstChild for the folder plus a WaitForChild for the remote,
	each preceded by its own logger call -- so calling it was expensive enough that ~99 call sites
	across src/ hand-maintained their own module-scope cache to avoid it. That discipline is invisible
	(nothing enforces it, nothing tests it) and it is one careless call inside a per-frame handler away
	from being a real frame-time cost. Memoizing here retires the whole class: after the first
	resolution a Get* is one table index, so it is now legitimate to call Get* at the point of use
	rather than hoisting it, and an existing hoisted local is simply a micro-optimization rather than a
	requirement.

	The cache is keyed by name and self-heals: a cached instance that has been unparented since is
	discarded and re-resolved, so a spec that destroys a remote (or a Studio session that rebuilds the
	Remotes folder) can never be handed a live-looking handle that silently delivers nothing. In normal
	operation that check never fires -- the server creates each remote exactly once during boot and
	nothing in this codebase reparents or destroys one -- so the steady-state cost stays one table index
	plus one property read.

	LOGGING IS ONCE PER NAME, for the same reason. Every Get* used to emit a trace on entry and a
	debug on success, so a client's boot alone pushed ~100 lines through Shared/Logger.lua's always-on
	capture ring purely to say that networking worked -- evicting a meaningful fraction of the 1000
	entries an admin's Live Console can show. Resolution is logged the first time a name is resolved
	(the only time it can tell anyone anything new) and never again.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Logger = require(ReplicatedStorage.Shared.Logger)
local Constants = require(ReplicatedStorage.Shared.Constants)

local NetworkBridge = {}

local logger = Logger.scope("NetworkBridge")

export type RemoteEventName = string
export type RemoteFunctionName = string

-- Resolved-instance memo, shared by Create* and Get* so a server-side Get* after the owning System's
-- own Create* is also a table hit. Two tables rather than one so a name registered as a RemoteEvent
-- can never be handed back to a GetRemoteFunction caller off the cache -- the class check below runs
-- against the live instance on first resolution, and the cache preserves that separation afterward.
local eventCache: { [string]: RemoteEvent } = {}
local functionCache: { [string]: RemoteFunction } = {}

-- How many times each name has been passed to Create* in this VM. Zero (absent) means this VM only
-- ever resolved the remote, i.e. it is a consumer, not the owner -- which is what every client-side
-- entry is. Exactly 1 is the healthy server-side state. Two or more means two callers are claiming one
-- remote name; see claimName below for why that is reported rather than asserted.
local createCounts: { [string]: number } = {}

local remotesFolder: Folder? = nil

-- A cached instance that has since been unparented (a spec calling :Destroy(), a Studio session
-- rebuilding the folder) must not be handed back -- it would be a live-looking handle that silently
-- delivers nothing. One property read per lookup, versus the full WaitForChild walk the cache exists
-- to avoid, so the cache stays self-healing without giving back what it saves.
local function stillLive(remote: Instance?): boolean
	return remote ~= nil and remote.Parent ~= nil
end

local function getRemotesFolder(): Folder
	local cached = remotesFolder
	if stillLive(cached) then
		return cached :: Folder
	end

	local existing = ReplicatedStorage:FindFirstChild("Remotes")
	if existing then
		assert(existing:IsA("Folder"), "ReplicatedStorage.Remotes exists but is not a Folder")
		remotesFolder = existing
		return existing
	end

	if RunService:IsServer() then
		local folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = ReplicatedStorage
		remotesFolder = folder
		logger:debug("Remotes folder created")
		return folder
	end

	-- Client path: the folder doesn't exist yet, but that's an ordinary, bounded server-boot delay
	-- (Main.server.lua's System.Init() calls can legitimately yield -- DataStore seeding, etc.) not a
	-- guaranteed failure -- mirrors the individual-remote WaitForChild-then-assert pattern below
	-- (GetRemoteEvent/GetRemoteFunction) instead of hard-failing the instant the folder isn't there yet.
	local folder = ReplicatedStorage:WaitForChild("Remotes", Constants.Network.WaitForChildTimeoutSeconds)
	if not folder then
		logger:error(
			"Timed out waiting for Remotes folder",
			{ timeoutSeconds = Constants.Network.WaitForChildTimeoutSeconds }
		)
	end
	assert(
		folder ~= nil and folder:IsA("Folder"),
		"Remotes folder must be created by the server before the client looks it up"
	)
	remotesFolder = folder :: Folder
	logger:debug("Remotes folder found after waiting")
	return folder :: Folder
end

-- Two Systems creating the same remote name is an OWNERSHIP bug, not a benign re-entry: this module's
-- contract is one owning System per remote, and two owners means two OnServerEvent handlers on one
-- instance, each running its own validation and neither aware of the other -- a shape where the
-- rate limiting and payload checks a System believes it enforces are simply bypassed half the time.
--
-- Deliberately NOT an assert, even though this is the bug it exists to catch. Create* is documented
-- and spec'd (Tests/Shared/NetworkBridge.spec.lua) as idempotent -- returning the same instance on a
-- second call -- and an idempotent Init() re-entry is a legitimate reason to see a name twice.
-- Asserting would trade a real, testable class of bug for a boot-time crash on a call pattern the
-- codebase already sanctions. So the count is recorded and surfaced two ways instead: a warn here (a
-- second claim is never intentional in a healthy boot), and CreateCount on DescribeSurface below, so a
-- boot-surface spec can assert exactly-once across the whole server surface at the one place that can
-- actually tell the difference between re-entry and two owners.
local function claimName(name: string, className: string): ()
	local previous = createCounts[name] or 0
	createCounts[name] = previous + 1
	if previous > 0 then
		logger:warn("Remote name claimed more than once -- check for two owning Systems", {
			name = name,
			className = className,
			claimCount = previous + 1,
		})
	end
end

-- Server-only. Called once per remote during the owning System's Init -- see Main.server.lua.
function NetworkBridge.CreateRemoteEvent(name: RemoteEventName): RemoteEvent
	assert(RunService:IsServer(), `CreateRemoteEvent("{name}") must only be called from the server`)
	claimName(name, "RemoteEvent")

	local cached = eventCache[name]
	if stillLive(cached) then
		return cached :: RemoteEvent
	end

	local folder = getRemotesFolder()
	local existing = folder:FindFirstChild(name)
	if existing then
		assert(existing:IsA("RemoteEvent"), `Remotes.{name} exists but is not a RemoteEvent`)
		eventCache[name] = existing
		logger:debug("RemoteEvent already existed -- adopting", { name = name })
		return existing
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = folder
	eventCache[name] = remote
	logger:debug("RemoteEvent created", { name = name })
	return remote
end

-- Safe from either side once the owning System has created the remote on boot. Cheap enough to call
-- at the point of use -- see this module's header on memoization.
function NetworkBridge.GetRemoteEvent(name: RemoteEventName): RemoteEvent
	local cached = eventCache[name]
	if stillLive(cached) then
		return cached :: RemoteEvent
	end

	local folder = getRemotesFolder()
	local remote = folder:WaitForChild(name, Constants.Network.WaitForChildTimeoutSeconds)
	if not remote then
		logger:error(
			"Timed out waiting for RemoteEvent",
			{ name = name, timeoutSeconds = Constants.Network.WaitForChildTimeoutSeconds }
		)
	end
	assert(remote ~= nil and remote:IsA("RemoteEvent"), `Remotes.{name} is not a registered RemoteEvent`)
	eventCache[name] = remote :: RemoteEvent
	logger:debug("RemoteEvent resolved", { name = name })
	return remote :: RemoteEvent
end

function NetworkBridge.CreateRemoteFunction(name: RemoteFunctionName): RemoteFunction
	assert(RunService:IsServer(), `CreateRemoteFunction("{name}") must only be called from the server`)
	claimName(name, "RemoteFunction")

	local cached = functionCache[name]
	if stillLive(cached) then
		return cached :: RemoteFunction
	end

	local folder = getRemotesFolder()
	local existing = folder:FindFirstChild(name)
	if existing then
		assert(existing:IsA("RemoteFunction"), `Remotes.{name} exists but is not a RemoteFunction`)
		functionCache[name] = existing
		logger:debug("RemoteFunction already existed -- adopting", { name = name })
		return existing
	end

	local remote = Instance.new("RemoteFunction")
	remote.Name = name
	remote.Parent = folder
	functionCache[name] = remote
	logger:debug("RemoteFunction created", { name = name })
	return remote
end

function NetworkBridge.GetRemoteFunction(name: RemoteFunctionName): RemoteFunction
	local cached = functionCache[name]
	if stillLive(cached) then
		return cached :: RemoteFunction
	end

	local folder = getRemotesFolder()
	local remote = folder:WaitForChild(name, Constants.Network.WaitForChildTimeoutSeconds)
	if not remote then
		logger:error(
			"Timed out waiting for RemoteFunction",
			{ name = name, timeoutSeconds = Constants.Network.WaitForChildTimeoutSeconds }
		)
	end
	assert(remote ~= nil and remote:IsA("RemoteFunction"), `Remotes.{name} is not a registered RemoteFunction`)
	functionCache[name] = remote :: RemoteFunction
	logger:debug("RemoteFunction resolved", { name = name })
	return remote :: RemoteFunction
end

export type RemoteSurfaceEntry = {
	Name: string,
	Kind: "RemoteEvent" | "RemoteFunction",
	-- How many times Create* was called for this name in this VM. 0 means this VM only resolved the
	-- remote (every client-side entry, and any server-side consumer of another System's remote); 1 is
	-- the healthy state for a remote this VM owns; 2+ is the two-owners bug claimName describes.
	CreateCount: number,
}

-- Every remote this VM has created or resolved, sorted by name. The auditable-in-one-place property
-- this module's header claims was, until now, only true in the sense that every remote passed THROUGH
-- here -- there was no way to ask what the surface actually is, so "is this remote still used", "did
-- this System's Init really run", and "how many remotes does a client boot touch" were all
-- grep-and-hope questions.
--
-- Intended for a spec (assert the expected server surface after Main.server.lua's boot, so a System
-- silently dropped from the boot list fails a test instead of a playtest), for the Dev Menu's own
-- diagnostics, and for a future call-budget audit -- deliberately NOT for gameplay code to enumerate
-- and dispatch on. Returns a fresh array each call; nothing here is per-frame.
function NetworkBridge.DescribeSurface(): { RemoteSurfaceEntry }
	local entries: { RemoteSurfaceEntry } = {}
	for name in eventCache do
		table.insert(
			entries,
			{ Name = name, Kind = "RemoteEvent" :: "RemoteEvent", CreateCount = createCounts[name] or 0 }
		)
	end
	for name in functionCache do
		table.insert(
			entries,
			{ Name = name, Kind = "RemoteFunction" :: "RemoteFunction", CreateCount = createCounts[name] or 0 }
		)
	end
	table.sort(entries, function(left: RemoteSurfaceEntry, right: RemoteSurfaceEntry): boolean
		return left.Name < right.Name
	end)
	return entries
end

-- Spec-only. Drops every cached instance and the folder handle, so a spec that builds its own Remotes
-- folder (or asserts the duplicate-claim guard above) starts from a clean VM without needing a fresh
-- one. Never call this from gameplay code: a live client holding a stale reference past a reset would
-- keep firing at an instance nothing is listening to, silently.
function NetworkBridge.ResetForTesting(): ()
	table.clear(eventCache)
	table.clear(functionCache)
	table.clear(createCounts)
	remotesFolder = nil
end

return NetworkBridge
