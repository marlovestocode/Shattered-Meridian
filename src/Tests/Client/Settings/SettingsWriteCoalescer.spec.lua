--!strict
-- Covers Client/Settings/SettingsWriteCoalescer.lua -- the burst-to-one-write step between SettingsClient's
-- controls and the server's 4/s settings bucket. The clock is injected, so nothing here waits.

local StarterPlayer = game:GetService("StarterPlayer")

local SettingsWriteCoalescer = require(StarterPlayer.StarterPlayerScripts.Client.Settings.SettingsWriteCoalescer)

type Sent = { Remote: string, Field: string, Value: unknown }

-- A scheduler the spec fires by hand: records every timer, runs them all on demand in the order made.
local function makeHarness()
	local sent: { Sent } = {}
	local timers: { () -> () } = {}
	local coalescer = SettingsWriteCoalescer.New(
		function(remote, field, value)
			table.insert(sent, { Remote = remote, Field = field, Value = value })
		end,
		0.3,
		function(_seconds, callback)
			table.insert(timers, callback)
		end
	)
	local function fireTimers()
		local due = timers
		timers = {}
		for _, callback in due do
			callback()
		end
	end
	return coalescer, sent, fireTimers
end

return function()
	describe("SettingsWriteCoalescer", function()
		it("sends nothing until the wait elapses", function()
			local coalescer, sent = makeHarness()
			coalescer:Queue("UpdateUI", "Scale", 1.1)
			expect(#sent).to.equal(0)
			expect(coalescer:HasPending()).to.equal(true)
		end)

		it("turns a burst on one field into a single write of the final value", function()
			local coalescer, sent, fireTimers = makeHarness()
			for step = 1, 5 do
				coalescer:Queue("UpdateUI", "Scale", 1 + step * 0.05)
			end
			fireTimers()

			expect(#sent).to.equal(1)
			expect(sent[1].Remote).to.equal("UpdateUI")
			expect(sent[1].Field).to.equal("Scale")
			expect(sent[1].Value).to.be.near(1.25, 1e-9)
			expect(coalescer:HasPending()).to.equal(false)
		end)

		it("restarts the wait on every change, so only the last timer flushes", function()
			local coalescer, sent, fireTimers = makeHarness()
			coalescer:Queue("UpdateUI", "Scale", 1)
			coalescer:Queue("UpdateUI", "Scale", 1.1)
			-- Both timers fire; only the newest generation acts, so the write is not sent twice.
			fireTimers()
			expect(#sent).to.equal(1)
			expect(sent[1].Value).to.equal(1.1)
		end)

		it("keeps different fields and different remotes apart, oldest first", function()
			local coalescer, sent, fireTimers = makeHarness()
			coalescer:Queue("UpdateParkour", "CoyoteTime", true)
			coalescer:Queue("UpdateComfort", "CoyoteTime", false)
			coalescer:Queue("UpdateParkour", "AutoVault", true)
			coalescer:Queue("UpdateParkour", "CoyoteTime", false)
			fireTimers()

			expect(#sent).to.equal(3)
			expect(sent[1].Remote).to.equal("UpdateParkour")
			expect(sent[1].Field).to.equal("CoyoteTime")
			expect(sent[1].Value).to.equal(false)
			expect(sent[2].Remote).to.equal("UpdateComfort")
			expect(sent[3].Field).to.equal("AutoVault")
		end)

		it("sends a toggled-back value too (the last change wins even if it equals the first)", function()
			local coalescer, sent, fireTimers = makeHarness()
			coalescer:Queue("UpdateParkour", "Enabled", false)
			coalescer:Queue("UpdateParkour", "Enabled", true)
			fireTimers()
			expect(#sent).to.equal(1)
			expect(sent[1].Value).to.equal(true)
		end)

		it("starts a fresh burst after a flush", function()
			local coalescer, sent, fireTimers = makeHarness()
			coalescer:Queue("UpdateUI", "Scale", 1.1)
			fireTimers()
			coalescer:Queue("UpdateUI", "Scale", 1.2)
			fireTimers()
			expect(#sent).to.equal(2)
			expect(sent[2].Value).to.equal(1.2)
		end)

		it("Flush sends what is pending now, and is harmless when nothing is", function()
			local coalescer, sent, fireTimers = makeHarness()
			coalescer:Flush()
			expect(#sent).to.equal(0)

			coalescer:Queue("UpdateUI", "Scale", 1.3)
			coalescer:Flush()
			expect(#sent).to.equal(1)
			-- The timer left behind finds nothing to do.
			fireTimers()
			expect(#sent).to.equal(1)
		end)
	end)
end
