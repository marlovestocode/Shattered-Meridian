--!strict
-- Covers Shared/CallbackList.lua -- the synchronous, pcall'd subscriber list every combat extension point
-- uses. The cases that matter are the ones the hand-written copies got wrong: a disconnect during a
-- dispatch must neither skip a neighbour nor still deliver to the one that left.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CallbackList = require(ReplicatedStorage.Shared.CallbackList)
local Logger = require(ReplicatedStorage.Shared.Logger)

local logger = Logger.scope("CallbackListSpec")

return function()
	describe("CallbackList", function()
		it("calls every subscriber in connection order, with the fired arguments", function()
			local list: CallbackList.CallbackList<number, string> = CallbackList.New(logger, "Spec.Order")
			local seen: { string } = {}
			list:Connect(function(n, s)
				table.insert(seen, `a{n}{s}`)
			end)
			list:Connect(function(n, s)
				table.insert(seen, `b{n}{s}`)
			end)
			list:Fire(1, "x")
			expect(table.concat(seen, ",")).to.equal("a1x,b1x")
		end)

		it("stops calling a subscriber once disconnected, and tolerates a second disconnect", function()
			local list: CallbackList.CallbackList<> = CallbackList.New(logger, "Spec.Disconnect")
			local calls = 0
			local disconnect = list:Connect(function()
				calls += 1
			end)
			list:Fire()
			disconnect()
			disconnect()
			list:Fire()
			expect(calls).to.equal(1)
			expect(list:Count()).to.equal(0)
		end)

		it("does not skip the next subscriber when one disconnects itself mid-dispatch", function()
			-- The hand-written copies did: their disconnect was a table.remove from the array being walked.
			local list: CallbackList.CallbackList<> = CallbackList.New(logger, "Spec.SelfDisconnect")
			local seen: { string } = {}
			local disconnectFirst: () -> () = function() end
			disconnectFirst = list:Connect(function()
				table.insert(seen, "first")
				disconnectFirst()
			end)
			list:Connect(function()
				table.insert(seen, "second")
			end)
			list:Fire()
			expect(table.concat(seen, ",")).to.equal("first,second")
			list:Fire()
			expect(table.concat(seen, ",")).to.equal("first,second,second")
		end)

		it("does not deliver to a subscriber another one disconnected earlier in the same dispatch", function()
			local list: CallbackList.CallbackList<> = CallbackList.New(logger, "Spec.CrossDisconnect")
			local seen: { string } = {}
			local disconnectSecond: () -> () = function() end
			list:Connect(function()
				table.insert(seen, "first")
				disconnectSecond()
			end)
			disconnectSecond = list:Connect(function()
				table.insert(seen, "second")
			end)
			list:Fire()
			expect(table.concat(seen, ",")).to.equal("first")
		end)

		it("does not deliver the current dispatch to a subscriber connected during it", function()
			local list: CallbackList.CallbackList<> = CallbackList.New(logger, "Spec.LateConnect")
			local lateCalls = 0
			list:Connect(function()
				if lateCalls == 0 and list:Count() == 1 then
					list:Connect(function()
						lateCalls += 1
					end)
				end
			end)
			list:Fire()
			expect(lateCalls).to.equal(0)
			list:Fire()
			expect(lateCalls).to.equal(1)
		end)

		it("keeps calling the rest when one subscriber errors", function()
			local list: CallbackList.CallbackList<> = CallbackList.New(logger, "Spec.Error")
			local reached = false
			list:Connect(function()
				error("spec: deliberate")
			end)
			list:Connect(function()
				reached = true
			end)
			expect(function()
				list:Fire()
			end).never.to.throw()
			expect(reached).to.equal(true)
		end)

		it("drops every subscriber on Clear", function()
			local list: CallbackList.CallbackList<> = CallbackList.New(logger, "Spec.Clear")
			local calls = 0
			list:Connect(function()
				calls += 1
			end)
			list:Clear()
			list:Fire()
			expect(calls).to.equal(0)
			expect(list:Count()).to.equal(0)
		end)
	end)
end
