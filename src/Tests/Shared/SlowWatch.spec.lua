--!strict
-- Covers Shared/SlowWatch.lua -- the handler wrapper that labels a call for the MicroProfiler and warns when
-- it runs past its budget. The logger is a recording stand-in, so the spec asserts on exactly what would have
-- been warned.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Logger = require(ReplicatedStorage.Shared.Logger)
local SlowWatch = require(ReplicatedStorage.Shared.SlowWatch)

type Warning = { message: string, fields: { [string]: any }? }

local function recordingLogger(): (Logger.LoggerScope, { Warning })
	local warnings: { Warning } = {}
	local scope: any = {}
	for _, level in { "trace", "debug", "info", "error" } do
		scope[level] = function() end
	end
	scope.warn = function(_self: any, message: string, fields: { [string]: any }?)
		table.insert(warnings, { message = message, fields = fields })
	end
	return scope :: Logger.LoggerScope, warnings
end

-- Spins until `seconds` of wall time have passed.
local function burn(seconds: number): ()
	local until_ = os.clock() + seconds
	local spins = 0
	while os.clock() < until_ do
		spins += 1
	end
end

return function()
	describe("SlowWatch.Handler", function()
		it("passes every argument through to the wrapped handler", function()
			local logger = recordingLogger()
			local seen: { any } = {}
			local wrapped = SlowWatch.Handler(logger, "spec.args", function(a: number, b: string)
				table.insert(seen, a)
				table.insert(seen, b)
			end)
			wrapped(7, "x")
			expect(seen[1]).to.equal(7)
			expect(seen[2]).to.equal("x")
		end)

		it("stays silent for a call inside its budget", function()
			local logger, warnings = recordingLogger()
			SlowWatch.Handler(logger, "spec.fast", function() end, 1)()
			expect(#warnings).to.equal(0)
		end)

		it("warns once, naming the label and the milliseconds, for a call past its budget", function()
			local logger, warnings = recordingLogger()
			SlowWatch.Handler(logger, "spec.slow", function()
				burn(0.02)
			end, 0.005)()
			expect(#warnings).to.equal(1)
			local warning = warnings[1]
			expect(warning.message).to.equal("Slow handler")
			expect((warning.fields :: any).label).to.equal("spec.slow")
			expect((warning.fields :: any).milliseconds >= 20).to.equal(true)
			expect((warning.fields :: any).budgetMilliseconds).to.equal(5)
		end)
	end)
end
