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
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Logger = require(ReplicatedStorage.Shared.Logger)
local Constants = require(ReplicatedStorage.Shared.Constants)

local NetworkBridge = {}

local logger = Logger.scope("NetworkBridge")

export type RemoteEventName = string
export type RemoteFunctionName = string

local function getRemotesFolder(): Folder
	local existing = ReplicatedStorage:FindFirstChild("Remotes")
	if existing then
		assert(existing:IsA("Folder"), "ReplicatedStorage.Remotes exists but is not a Folder")
		logger:trace("Remotes folder found")
		return existing
	end

	if RunService:IsServer() then
		local folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = ReplicatedStorage
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
	logger:debug("Remotes folder found after waiting")
	return folder :: Folder
end

-- Server-only. Called once per remote during the owning System's Init -- see Main.server.lua.
function NetworkBridge.CreateRemoteEvent(name: RemoteEventName): RemoteEvent
	assert(RunService:IsServer(), `CreateRemoteEvent("{name}") must only be called from the server`)

	local folder = getRemotesFolder()
	local existing = folder:FindFirstChild(name)
	if existing then
		assert(existing:IsA("RemoteEvent"), `Remotes.{name} exists but is not a RemoteEvent`)
		logger:debug("RemoteEvent already existed", { name = name })
		return existing
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = folder
	logger:debug("RemoteEvent created", { name = name })
	return remote
end

-- Safe from either side once the owning System has created the remote on boot.
function NetworkBridge.GetRemoteEvent(name: RemoteEventName): RemoteEvent
	logger:trace("RemoteEvent lookup start", { name = name })
	local folder = getRemotesFolder()
	local remote = folder:WaitForChild(name, Constants.Network.WaitForChildTimeoutSeconds)
	if not remote then
		logger:error(
			"Timed out waiting for RemoteEvent",
			{ name = name, timeoutSeconds = Constants.Network.WaitForChildTimeoutSeconds }
		)
	end
	assert(remote ~= nil and remote:IsA("RemoteEvent"), `Remotes.{name} is not a registered RemoteEvent`)
	logger:debug("RemoteEvent lookup success", { name = name })
	return remote :: RemoteEvent
end

function NetworkBridge.CreateRemoteFunction(name: RemoteFunctionName): RemoteFunction
	assert(RunService:IsServer(), `CreateRemoteFunction("{name}") must only be called from the server`)

	local folder = getRemotesFolder()
	local existing = folder:FindFirstChild(name)
	if existing then
		assert(existing:IsA("RemoteFunction"), `Remotes.{name} exists but is not a RemoteFunction`)
		logger:debug("RemoteFunction already existed", { name = name })
		return existing
	end

	local remote = Instance.new("RemoteFunction")
	remote.Name = name
	remote.Parent = folder
	logger:debug("RemoteFunction created", { name = name })
	return remote
end

function NetworkBridge.GetRemoteFunction(name: RemoteFunctionName): RemoteFunction
	logger:trace("RemoteFunction lookup start", { name = name })
	local folder = getRemotesFolder()
	local remote = folder:WaitForChild(name, Constants.Network.WaitForChildTimeoutSeconds)
	if not remote then
		logger:error(
			"Timed out waiting for RemoteFunction",
			{ name = name, timeoutSeconds = Constants.Network.WaitForChildTimeoutSeconds }
		)
	end
	assert(remote ~= nil and remote:IsA("RemoteFunction"), `Remotes.{name} is not a registered RemoteFunction`)
	logger:debug("RemoteFunction lookup success", { name = name })
	return remote :: RemoteFunction
end

return NetworkBridge
