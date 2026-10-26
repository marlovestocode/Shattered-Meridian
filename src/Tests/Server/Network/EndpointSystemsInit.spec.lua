--!strict
-- The boot smoke test for every System whose remotes are declared through Endpoint: run its Init in the headless place and check
-- that EVERY remote BootManifest lists for it now exists as a live remote and is declared to the same owner. A broken Endpoint
-- declaration (a typo'd option, a missing limiter, a handler that is nil) otherwise surfaces only when someone boots a server in
-- Studio, because nothing else in this suite ever runs a System's Init.
--
-- Add a System here when it is converted. Only Systems whose Init is safe without a DataStore, a Humanoid or a Workspace map belong.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local BootManifest = require(ServerScriptService.Server.Config.BootManifest)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)

local SYSTEMS: { string } = {
	"SettingsSystem",
	"EmoteSystem",
	"ArtSystem",
	"InventorySystem",
}

local function systemModule(name: string): any
	for _, entry in BootManifest.Entries do
		if entry.Name == name then
			local node: Instance = ServerScriptService.Server
			for _, part in entry.Path do
				node = node:WaitForChild(part)
			end
			return require(node :: ModuleScript)
		end
	end
	error(`{name} is not a BootManifest entry`)
end

return function()
	for _, name in SYSTEMS do
		describe(`{name}.Init`, function()
			it("creates and declares every remote the manifest lists for it", function()
				local system = systemModule(name)
				system.Init()

				local live: { [string]: boolean } = {}
				for _, surface in NetworkBridge.DescribeSurface() do
					if surface.CreateCount > 0 then
						live[surface.Name] = true
					end
				end

				local owners = BootManifest.RemoteOwners()
				local listed = 0
				for _, entry in BootManifest.Entries do
					if entry.Name == name then
						for _, remoteName in entry.Remotes do
							listed += 1
							expect(live[remoteName]).to.equal(true)
							expect(owners[remoteName]).to.equal(name)
						end
					end
				end
				expect(listed > 0).to.equal(true)
			end)
		end)
	end
end
