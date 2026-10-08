--!strict
-- Covers Server/Systems/Support/SuspicionLedger.lua -- the strike-and-flag shape every automated cheat detector
-- shares. Stand-in subjects and an injected reporter: Players cannot be made headless, and a flag must never reach
-- the real moderation store from a spec.

local ServerScriptService = game:GetService("ServerScriptService")

local SuspicionLedger = require(ServerScriptService.Server.Systems.Support.SuspicionLedger)

return function()
	describe("SuspicionLedger", function()
		local reports: { { Subject: any, Code: string, Reason: string } }
		local subject = { UserId = 7, Name = "Spec" }

		local function ledger(strikes: number, window: number)
			reports = {}
			return SuspicionLedger.New({
				Name = "Spec",
				ReasonCode = "SpecCode",
				Summary = "spec strikes",
				Strikes = strikes,
				WindowSeconds = window,
				Report = function(who, code, reason)
					table.insert(reports, { Subject = who, Code = code, Reason = reason })
				end,
			})
		end

		it("flags once, the moment the threshold is reached inside the window", function()
			local book = ledger(3, 10)
			expect(book:Strike(subject, 1)).to.equal(false)
			expect(book:Strike(subject, 2)).to.equal(false)
			expect(book:Strike(subject, 3, "fast")).to.equal(true)
			expect(book:Strike(subject, 4)).to.equal(false)
			expect(#reports).to.equal(1)
			expect(reports[1].Code).to.equal("SpecCode")
			expect(string.find(reports[1].Reason, "(last: fast)", 1, true) ~= nil).to.equal(true)
		end)

		it("forgets strikes that fall out of the window", function()
			local book = ledger(3, 10)
			book:Strike(subject, 1)
			book:Strike(subject, 2)
			expect(book:Strike(subject, 30)).to.equal(false)
			expect(book:Count(subject, 30)).to.equal(1)
		end)

		it("lets one unambiguous strike weigh several", function()
			local book = ledger(3, 10)
			expect(book:Strike(subject, 1, "teleport", 3)).to.equal(true)
		end)

		it("starts a returning player clean", function()
			local book = ledger(2, 10)
			book:Strike(subject, 1)
			book:Strike(subject, 2)
			book:Release(subject)
			expect(book:IsFlagged(subject)).to.equal(false)
			expect(book:Count(subject, 2)).to.equal(0)
		end)
	end)
end
