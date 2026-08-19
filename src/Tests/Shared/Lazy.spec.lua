--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lazy = require(ReplicatedStorage.Shared.Lazy)

return function()
	describe("Lazy", function()
		it("does not build until Get is called", function()
			local builds = 0
			local lazy = Lazy.new("NotYet", function()
				builds += 1
				return "value"
			end)

			expect(builds).to.equal(0)
			expect(lazy.IsResolved()).to.equal(false)
		end)

		it("builds exactly once across repeated Gets and returns the identical value", function()
			local builds = 0
			local lazy = Lazy.new("Once", function()
				builds += 1
				return { marker = builds }
			end)

			local first = lazy.Get()
			local second = lazy.Get()
			local third = lazy.Get()

			expect(builds).to.equal(1)
			expect(first).to.equal(second)
			expect(second).to.equal(third)
		end)

		it("reports resolved only after the first Get", function()
			local lazy = Lazy.new("Reported", function()
				return 1
			end)

			expect(lazy.IsResolved()).to.equal(false)
			lazy.Get()
			expect(lazy.IsResolved()).to.equal(true)
		end)

		it("IsResolved does not itself force the build", function()
			-- The property the Live Console depends on: a log batch arriving for a panel nobody has
			-- opened must be droppable without mounting the panel to find that out.
			local builds = 0
			local lazy = Lazy.new("Peek", function()
				builds += 1
				return true
			end)

			for _ = 1, 5 do
				expect(lazy.IsResolved()).to.equal(false)
			end
			expect(builds).to.equal(0)
		end)

		it("caches a falsy value rather than rebuilding it every call", function()
			-- `resolved` is tracked separately from the value precisely so `false` and `nil` are real
			-- results, not "not built yet".
			local builds = 0
			local lazy = Lazy.new("Falsy", function()
				builds += 1
				return false
			end)

			expect(lazy.Get()).to.equal(false)
			expect(lazy.Get()).to.equal(false)
			expect(builds).to.equal(1)
		end)

		it("refuses a build that forces itself, instead of recursing forever", function()
			local lazy
			lazy = Lazy.new("Recursive", function()
				return lazy.Get()
			end)

			expect(function()
				lazy.Get()
			end).to.throw()
		end)
	end)
end
