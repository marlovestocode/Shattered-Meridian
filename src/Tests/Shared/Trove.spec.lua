--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Trove = require(ReplicatedStorage.Shared.Trove)

-- Every kind a Trove releases is exercised against a REAL instance of that kind (a live
-- BindableEvent connection, a real Instance, a closure, a nested Trove) rather than a stand-in --
-- the whole value of this module is that `typeof(object)` dispatch is right for the four things the
-- codebase actually hands it, and a mocked connection would not test that at all.

return function()
	describe("Trove -- releasing each kind", function()
		it("disconnects a tracked connection", function()
			local trove = Trove.New()
			local event = Instance.new("BindableEvent")
			local fired = 0
			trove:Connect(event.Event, function()
				fired += 1
			end)

			event:Fire()
			expect(fired).to.equal(1)

			trove:Clean()
			event:Fire()
			expect(fired).to.equal(1)
			event:Destroy()
		end)

		it("destroys a tracked Instance", function()
			local trove = Trove.New()
			local folder = trove:Add(Instance.new("Folder"))
			folder.Parent = workspace

			expect(folder.Parent).to.equal(workspace)
			trove:Clean()
			expect(folder.Parent).to.equal(nil)
		end)

		it("calls a tracked teardown function", function()
			local trove = Trove.New()
			local called = false
			trove:Add(function()
				called = true
			end)

			trove:Clean()
			expect(called).to.equal(true)
		end)

		it("cleans a nested Trove with its parent", function()
			local trove = Trove.New()
			local child = trove:Extend()
			local called = false
			child:Add(function()
				called = true
			end)

			trove:Clean()
			expect(called).to.equal(true)
			expect(child:Count()).to.equal(0)
		end)
	end)

	describe("Trove -- ordering and reuse", function()
		it("releases in reverse order of acquisition", function()
			-- Teardown that runs in acquisition order can hand a later object a dependency that has
			-- already been released -- see this module's header.
			local trove = Trove.New()
			local order: { number } = {}
			trove:Add(function()
				table.insert(order, 1)
			end)
			trove:Add(function()
				table.insert(order, 2)
			end)
			trove:Add(function()
				table.insert(order, 3)
			end)

			trove:Clean()
			expect(order[1]).to.equal(3)
			expect(order[2]).to.equal(2)
			expect(order[3]).to.equal(1)
		end)

		it("is empty and refillable after Clean -- a per-life Trove is reused every respawn", function()
			local trove = Trove.New()
			trove:Add(function() end)
			expect(trove:Count()).to.equal(1)

			trove:Clean()
			expect(trove:Count()).to.equal(0)

			local called = false
			trove:Add(function()
				called = true
			end)
			expect(trove:Count()).to.equal(1)
			trove:Clean()
			expect(called).to.equal(true)
		end)

		it("treats cleaning an empty Trove as a no-op -- every teardown path may call it unguarded", function()
			local trove = Trove.New()
			expect(function()
				trove:Clean()
				trove:Clean()
			end).never.to.throw()
		end)
	end)

	describe("Trove -- Add and Remove", function()
		it("returns the tracked object unchanged, so acquisition and tracking are one expression", function()
			local trove = Trove.New()
			local folder = Instance.new("Folder")
			expect(trove:Add(folder)).to.equal(folder)
			trove:Clean()
		end)

		it("Remove releases one object early and reports that it was tracked", function()
			local trove = Trove.New()
			local called = false
			local teardown = function()
				called = true
			end
			trove:Add(teardown)

			expect(trove:Remove(teardown)).to.equal(true)
			expect(called).to.equal(true)
			expect(trove:Count()).to.equal(0)
		end)

		it("Remove reports false for something it never tracked, rather than assuming", function()
			local trove = Trove.New()
			expect(trove:Remove(function() end)).to.equal(false)
		end)

		it("refuses an Add from inside its own Clean -- that object would never be released", function()
			local trove = Trove.New()
			trove:Add(function()
				trove:Add(function() end)
			end)
			expect(function()
				trove:Clean()
			end).to.throw()
		end)
	end)
end
