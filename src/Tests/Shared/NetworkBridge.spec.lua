--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)

-- Server-path coverage only -- this headless harness runs run-in-roblox's script at server-level
-- security against a place with no live client, so RunService:IsServer() reports true for the
-- entire duration of this spec file. getRemotesFolder()'s new client branch (ReplicatedStorage:
-- WaitForChild("Remotes", timeout) -> log + assert on timeout) added to fix the live-playtest race
-- where a client could observe ReplicatedStorage.Remotes before the server finished creating it is
-- therefore NOT reachable from here -- exercising it needs a real two-actor (server + client)
-- session, i.e. Studio/live-server verification only, the same accepted gap this codebase's other
-- WaitForChild-timeout branches (GetRemoteEvent/GetRemoteFunction's own individual-remote waits)
-- already carry. What IS verified here is that the server path this fix leaves untouched --
-- immediate folder auto-creation, no wait -- still behaves exactly as before.

return function()
	describe("NetworkBridge (server path)", function()
		it("CreateRemoteEvent auto-creates the Remotes folder and the remote", function()
			local remote = NetworkBridge.CreateRemoteEvent("__Test_NetworkBridge_Event")
			expect(remote).to.be.ok()
			expect(remote:IsA("RemoteEvent")).to.equal(true)
			expect(ReplicatedStorage:FindFirstChild("Remotes")).to.be.ok()
			remote:Destroy()
		end)

		it("CreateRemoteEvent returns the same instance on a second call (idempotent)", function()
			local first = NetworkBridge.CreateRemoteEvent("__Test_NetworkBridge_Idempotent")
			local second = NetworkBridge.CreateRemoteEvent("__Test_NetworkBridge_Idempotent")
			expect(first).to.equal(second)
			first:Destroy()
		end)

		it("GetRemoteEvent finds a remote created moments earlier by CreateRemoteEvent", function()
			local created = NetworkBridge.CreateRemoteEvent("__Test_NetworkBridge_GetEvent")
			local fetched = NetworkBridge.GetRemoteEvent("__Test_NetworkBridge_GetEvent")
			expect(fetched).to.equal(created)
			created:Destroy()
		end)

		it("CreateRemoteFunction auto-creates the Remotes folder and the remote", function()
			local remote = NetworkBridge.CreateRemoteFunction("__Test_NetworkBridge_Function")
			expect(remote).to.be.ok()
			expect(remote:IsA("RemoteFunction")).to.equal(true)
			remote:Destroy()
		end)

		it("GetRemoteFunction finds a remote created moments earlier by CreateRemoteFunction", function()
			local created = NetworkBridge.CreateRemoteFunction("__Test_NetworkBridge_GetFunction")
			local fetched = NetworkBridge.GetRemoteFunction("__Test_NetworkBridge_GetFunction")
			expect(fetched).to.equal(created)
			created:Destroy()
		end)
	end)
	-- Memoization is a documented contract of this module, not an internal detail -- ~99 call sites
	-- across src/ used to hoist their own module-scope cache specifically because Get* was expensive,
	-- and this block is what makes it safe to stop doing that. See NetworkBridge.lua's header.
	describe("NetworkBridge lookup memoization", function()
		it("GetRemoteEvent returns the identical instance across repeated calls", function()
			local created = NetworkBridge.CreateRemoteEvent("__Test_NetworkBridge_Memo_Event")
			local first = NetworkBridge.GetRemoteEvent("__Test_NetworkBridge_Memo_Event")
			local second = NetworkBridge.GetRemoteEvent("__Test_NetworkBridge_Memo_Event")
			expect(first).to.equal(created)
			expect(second).to.equal(created)
			created:Destroy()
		end)

		it("GetRemoteFunction returns the identical instance across repeated calls", function()
			local created = NetworkBridge.CreateRemoteFunction("__Test_NetworkBridge_Memo_Function")
			local first = NetworkBridge.GetRemoteFunction("__Test_NetworkBridge_Memo_Function")
			local second = NetworkBridge.GetRemoteFunction("__Test_NetworkBridge_Memo_Function")
			expect(first).to.equal(created)
			expect(second).to.equal(created)
			created:Destroy()
		end)

		-- The failure mode this guards is silent: a cached-but-destroyed remote is a handle that looks
		-- live, accepts FireServer/FireClient calls, and delivers nothing to anyone. A cache with no
		-- liveness check would hand exactly that back forever.
		it("re-resolves rather than returning a cached remote that has since been destroyed", function()
			local first = NetworkBridge.CreateRemoteEvent("__Test_NetworkBridge_Stale")
			first:Destroy()
			local second = NetworkBridge.CreateRemoteEvent("__Test_NetworkBridge_Stale")
			expect(second).never.to.equal(first)
			expect(second.Parent).to.be.ok()
			second:Destroy()
		end)
	end)

	-- DescribeSurface is what makes this module's own "the network surface stays auditable in one
	-- place" claim testable rather than aspirational. The real payoff is a boot-surface assertion (a
	-- System silently dropped from Main.server.lua's boot list stops being a playtest discovery), which
	-- needs a place that actually boots; what is verified here is the reporting itself.
	describe("NetworkBridge.DescribeSurface", function()
		it("reports a created RemoteEvent with its kind and a CreateCount of 1", function()
			local remote = NetworkBridge.CreateRemoteEvent("__Test_NetworkBridge_Surface_Event")
			local found = nil
			for _, entry in NetworkBridge.DescribeSurface() do
				if entry.Name == "__Test_NetworkBridge_Surface_Event" then
					found = entry
				end
			end
			expect(found).to.be.ok()
			expect((found :: any).Kind).to.equal("RemoteEvent")
			expect((found :: any).CreateCount).to.equal(1)
			remote:Destroy()
		end)

		-- Two Systems claiming one remote name means two OnServerEvent handlers on one instance, each
		-- believing its own rate limit and payload validation are the only ones -- so the second claim
		-- has to be countable somewhere. Create* stays idempotent (the instance is shared, as the block
		-- above asserts); the COUNT is what distinguishes a benign Init() re-entry from two owners.
		it("counts repeat claims of the same name rather than hiding them behind idempotency", function()
			local first = NetworkBridge.CreateRemoteFunction("__Test_NetworkBridge_Surface_Claimed")
			local second = NetworkBridge.CreateRemoteFunction("__Test_NetworkBridge_Surface_Claimed")
			expect(second).to.equal(first)

			local found = nil
			for _, entry in NetworkBridge.DescribeSurface() do
				if entry.Name == "__Test_NetworkBridge_Surface_Claimed" then
					found = entry
				end
			end
			expect(found).to.be.ok()
			expect((found :: any).CreateCount).to.equal(2)
			first:Destroy()
		end)

		it("sorts entries by name so two runs of the same surface compare equal", function()
			NetworkBridge.CreateRemoteEvent("__Test_NetworkBridge_SortB")
			NetworkBridge.CreateRemoteEvent("__Test_NetworkBridge_SortA")
			local entries = NetworkBridge.DescribeSurface()
			local sorted = true
			for index = 2, #entries do
				if entries[index - 1].Name > entries[index].Name then
					sorted = false
				end
			end
			expect(sorted).to.equal(true)
		end)
	end)
end
