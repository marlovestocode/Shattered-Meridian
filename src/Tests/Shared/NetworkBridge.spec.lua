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
end
