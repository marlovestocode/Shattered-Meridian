--!strict
local StarterPlayer = game:GetService("StarterPlayer")

local RemoteInvoker = require(StarterPlayer.StarterPlayerScripts.Client.Network.RemoteInvoker)

-- A bare table with an InvokeServer method stands in for a RemoteFunction -- these specs run
-- outside a live client/server pair, so there is nothing real to invoke.
local function fakeRemote(onInvoke: (...any) -> ...any): RemoteFunction
	return (
		{
			Name = "FakeRemote",
			InvokeServer = function(_self, ...)
				return onInvoke(...)
			end,
		} :: any
	) :: RemoteFunction
end

return function()
	describe("RemoteInvoker.Invoke", function()
		it("returns (true, result) when InvokeServer succeeds", function()
			local remote = fakeRemote(function(value: number)
				return { Success = true, Value = value }
			end)

			local ok, result = RemoteInvoker.Invoke(remote, 5)

			expect(ok).to.equal(true)
			expect((result :: any).Value).to.equal(5)
		end)

		it("returns (false, errorMessage) when InvokeServer throws", function()
			local remote = fakeRemote(function()
				error("network timeout")
			end)

			local ok, errorMessage = RemoteInvoker.Invoke(remote)

			expect(ok).to.equal(false)
			expect(tostring(errorMessage):find("network timeout") ~= nil).to.equal(true)
		end)

		it("forwards every argument to InvokeServer", function()
			local seenA, seenB = nil, nil
			local remote = fakeRemote(function(a, b)
				seenA, seenB = a, b
				return { Success = true }
			end)

			RemoteInvoker.Invoke(remote, "hello", 42)

			expect(seenA).to.equal("hello")
			expect(seenB).to.equal(42)
		end)
	end)

	describe("RemoteInvoker.InvokeAndReport", function()
		it("reports describe(result) on success", function()
			local remote = fakeRemote(function()
				return { Success = true }
			end)
			local reported = nil

			RemoteInvoker.InvokeAndReport(
				function(message: string)
					reported = message
				end,
				remote,
				{},
				function(result: any)
					return if result.Success then "Done" else "Failed"
				end
			)

			expect(reported).to.equal("Done")
		end)

		it("reports the default error status when InvokeServer throws", function()
			local remote = fakeRemote(function()
				error("boom")
			end)
			local reported = nil

			RemoteInvoker.InvokeAndReport(
				function(message: string)
					reported = message
				end,
				remote,
				{},
				function(_result: any)
					return "Done"
				end
			)

			expect(reported).to.equal("Failed: request error")
		end)

		it("reports a caller-supplied error status when given", function()
			local remote = fakeRemote(function()
				error("boom")
			end)
			local reported = nil

			RemoteInvoker.InvokeAndReport(
				function(message: string)
					reported = message
				end,
				remote,
				{},
				function(_result: any)
					return "Done"
				end,
				"Custom failure message"
			)

			expect(reported).to.equal("Custom failure message")
		end)
	end)
end
