--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Constants = require(ReplicatedStorage.Shared.Constants)
local BootManifest = require(ServerScriptService.Server.Config.BootManifest)

-- The HALF of the boot check that can run headless. The other half -- "did Main.server.lua actually
-- call Init on all of these, and did that produce the declared network surface" -- is
-- BootManifest.AssertBootComplete, and it can only run on a real booting server, because this place
-- never executes Main.server.lua at all. Neither half is redundant: this file catches a System that
-- exists but was never added to the boot list (which never runs, so runtime cannot miss it), and the
-- runtime half catches a System that was dropped from the list (which is an absence, so no file
-- shows it). See BootManifest.lua's own header.

local ServerRoot = ServerScriptService.Server

local function resolve(path: { string }): Instance?
	local current: Instance = ServerRoot
	for _, segment in path do
		local child = current:FindFirstChild(segment)
		if not child then
			return nil
		end
		current = child
	end
	return current
end

local function describePath(path: { string }): string
	return table.concat(path, ".")
end

-- Every ModuleScript a developer could add a System to. Managers and Systems are flat folders and are
-- the two places a new System is ever put; Combat's own modules live under nested feature folders and
-- are enumerated by the manifest rather than swept, because that tree is also full of pure helpers
-- that legitimately have no Init.
local function bootableFolders(): { Instance }
	return { ServerRoot.Systems, ServerRoot.Managers }
end

return function()
	describe("BootManifest -- every module on disk is declared", function()
		it("declares every ModuleScript under Server/Systems and Server/Managers", function()
			local declared: { [string]: boolean } = {}
			for _, entry in BootManifest.Entries do
				declared[entry.Name] = true
			end

			local undeclared: { string } = {}
			for _, folder in bootableFolders() do
				for _, child in folder:GetChildren() do
					if child:IsA("ModuleScript") and not declared[child.Name] then
						table.insert(undeclared, `{folder.Name}.{child.Name}`)
					end
				end
			end

			-- A System that exists but is in nobody's boot list is invisible at runtime -- it never
			-- runs, so nothing it owns is ever missed. This assertion is the only place it shows up.
			expect(table.concat(undeclared, ", ")).to.equal("")
		end)

		it("declares each name exactly once", function()
			local seen: { [string]: boolean } = {}
			local duplicates: { string } = {}
			for _, entry in BootManifest.Entries do
				if seen[entry.Name] then
					table.insert(duplicates, entry.Name)
				end
				seen[entry.Name] = true
			end
			expect(table.concat(duplicates, ", ")).to.equal("")
		end)
	end)

	describe("BootManifest -- every declaration resolves to a real System", function()
		it("resolves every entry's path to a ModuleScript", function()
			local missing: { string } = {}
			for _, entry in BootManifest.Entries do
				local instance = resolve(entry.Path)
				if not instance or not instance:IsA("ModuleScript") then
					table.insert(missing, `{entry.Name} at Server.{describePath(entry.Path)}`)
				end
			end
			expect(table.concat(missing, ", ")).to.equal("")
		end)

		it("requires every entry and finds an Init function on it", function()
			-- Doubles as a load-check for the whole server surface: several of these modules are
			-- required by nothing else in this place, so a broken require path in one of them would
			-- otherwise surface only when someone opened Studio.
			local broken: { string } = {}
			for _, entry in BootManifest.Entries do
				local instance = resolve(entry.Path)
				if instance and instance:IsA("ModuleScript") then
					local ok, moduleOrError = pcall(require, instance)
					if not ok then
						table.insert(broken, `{entry.Name} failed to require: {tostring(moduleOrError)}`)
					elseif typeof((moduleOrError :: any).Init) ~= "function" then
						table.insert(broken, `{entry.Name} exposes no Init function`)
					end
				end
			end
			expect(table.concat(broken, ", ")).to.equal("")
		end)
	end)

	describe("BootManifest -- the declared network surface", function()
		it("gives every declared remote exactly one owning System", function()
			-- The static half of the NET-4 two-owners bug: NetworkBridge.claimName can only notice a
			-- second claim once both have happened, on a booting server. Two entries declaring one
			-- name is a fact about this file, and is caught here.
			expect(function()
				BootManifest.RemoteOwners()
			end).never.to.throw()
		end)

		it("never declares a remote it has also retired", function()
			local owners = BootManifest.RemoteOwners()
			local contradictions: { string } = {}
			for _, retired in BootManifest.RetiredRemotes do
				if owners[retired] then
					table.insert(contradictions, `{retired} (claimed by {owners[retired]})`)
				end
			end
			expect(table.concat(contradictions, ", ")).to.equal("")
		end)

		it("accounts for every name in the Dev Menu's remote table, live or retired", function()
			-- The Dev Menu is the one table where the two lists can drift apart silently, because its
			-- remotes are created from a separate REMOTE_HANDLERS array rather than from the table
			-- itself. A name added to one and not the other is exactly what this catches.
			local owners = BootManifest.RemoteOwners()
			local unaccounted: { string } = {}
			for key, name in Constants.Debug.DevMenu.RemoteNames do
				if not owners[name] and not table.find(BootManifest.RetiredRemotes, name) then
					table.insert(unaccounted, key)
				end
			end
			expect(table.concat(unaccounted, ", ")).to.equal("")
		end)

		it("accounts for every name in the Move Editor's remote table, live or retired", function()
			local owners = BootManifest.RemoteOwners()
			local unaccounted: { string } = {}
			for key, name in Constants.MoveEditor.RemoteNames do
				if not owners[name] and not table.find(BootManifest.RetiredRemotes, name) then
					table.insert(unaccounted, key)
				end
			end
			expect(table.concat(unaccounted, ", ")).to.equal("")
		end)

		it("declares a remote surface at all -- a manifest that declares nothing would pass everything else", function()
			local count = 0
			for _ in BootManifest.RemoteOwners() do
				count += 1
			end
			expect(count > 50).to.equal(true)
		end)
	end)

	describe("BootManifest -- drift reporting", function()
		it("reports a server where nothing booted as drifted, not as clean", function()
			-- Main.server.lua never runs in this place, so nothing has called MarkBooted -- which makes
			-- this the one case where the drift report's own logic is directly observable. If it ever
			-- came back clean here, DescribeDrift would be reporting success without looking.
			local drift = BootManifest.DescribeDrift()
			expect(#drift.MissingSystems > 0).to.equal(true)
			expect(BootManifest.IsClean(drift)).to.equal(false)
		end)

		it("counts a System as booted once it reports in", function()
			local first = BootManifest.Entries[1]
			BootManifest.MarkBooted(first.Name)
			local drift = BootManifest.DescribeDrift()
			expect(table.find(drift.MissingSystems, first.Name)).to.equal(nil)
		end)
	end)
end
