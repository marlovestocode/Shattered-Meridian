--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RemoteHandler = require(ReplicatedStorage.Shared.RemoteHandler)
local Logger = require(ReplicatedStorage.Shared.Logger)

return function()
	describe("RemoteHandler.WrapInvoke", function()
		it("passes through a successful handler's result unchanged", function()
			local logger = Logger.scope("RemoteHandler.spec")
			local player = { Name = "Tester" } :: any

			local wrapped = RemoteHandler.WrapInvoke(
				logger,
				"TestAction",
				{ Success = false, Reason = "InternalError" },
				function(_p, value: number)
					return { Success = true, Value = value }
				end
			)

			local result = wrapped(player, 7)

			expect(result.Success).to.equal(true)
			expect((result :: any).Value).to.equal(7)
		end)

		it("catches a thrown error and returns the caller's errorResult instead", function()
			local logger = Logger.scope("RemoteHandler.spec")
			local player = { Name = "Tester" } :: any
			local errorResult = { Success = false, Reason = "InternalError" }

			local wrapped = RemoteHandler.WrapInvoke(logger, "TestAction", errorResult, function(_p)
				error("boom")
			end)

			local result = wrapped(player)

			expect(result).to.equal(errorResult)
		end)

		it("forwards every argument after Player to the wrapped handler", function()
			local logger = Logger.scope("RemoteHandler.spec")
			local player = { Name = "Tester" } :: any
			local seenA, seenB = nil, nil

			local wrapped = RemoteHandler.WrapInvoke(
				logger,
				"TestAction",
				{ Success = false },
				function(_p, a: string, b: number)
					seenA, seenB = a, b
					return { Success = true }
				end
			)

			wrapped(player, "hello", 42)

			expect(seenA).to.equal("hello")
			expect(seenB).to.equal(42)
		end)

		it("never lets a handler's error escape the wrapper", function()
			local logger = Logger.scope("RemoteHandler.spec")
			local player = { Name = "Tester" } :: any

			local wrapped = RemoteHandler.WrapInvoke(logger, "TestAction", { Success = false }, function(_p)
				error("boom")
			end)

			expect(function()
				wrapped(player)
			end).never.to.throw()
		end)
	end)
end
