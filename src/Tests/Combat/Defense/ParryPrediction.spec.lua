--!strict
-- Covers Client/Defense/ParryPrediction.lua -- the client's key-edge guess at whether a press arms a parry.
--
-- Pure and clock-free, so every case drives it with plain numbers. Each rule here mirrors one in
-- Server/Combat/Defense/DefenseStateMachine.lua (Press, Release, and the whiff branch of Update); a case
-- that fails here is a press whose swing-up would lie about what the server is about to do.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local ParryPrediction = require(StarterPlayer.StarterPlayerScripts.Client.Defense.ParryPrediction)

local WINDOW = { Open = 0, Close = 0.2, RecoveryEnd = 0.65 }
local MIN_UNGUARDED = DefenseConstants.Parry.MinUnguardedSeconds

local function fresh(): ParryPrediction.Predictor
	local predictor = ParryPrediction.New()
	predictor:SetWindow(WINDOW)
	return predictor
end

return function()
	describe("ParryPrediction -- arming", function()
		it("arms a first press on a free body", function()
			local predictor = fresh()
			local id, armed = predictor:Press(10, true)
			expect(id).to.equal(1)
			expect(armed).to.equal(true)
		end)

		it("never arms without a window -- the server fail-closes", function()
			local predictor = ParryPrediction.New()
			local _, armed = predictor:Press(10, true)
			expect(armed).to.equal(false)
		end)

		it("never arms a press made on a committed body", function()
			local _, armed = fresh():Press(10, false)
			expect(armed).to.equal(false)
		end)

		it("never arms while the guard is broken", function()
			local predictor = fresh()
			predictor:NoteServerState("GuardBroken")
			local _, armed = predictor:Press(10, true)
			expect(armed).to.equal(false)
		end)
	end)

	describe("ParryPrediction -- the anti-turtle rule", function()
		it(
			"refuses a parry right after a block came down, and allows it once MinUnguardedSeconds has passed",
			function()
				local predictor = fresh()
				predictor:Press(10, true)
				-- Held past the window's close: the guard became a block.
				predictor:Release(10.5)
				expect(predictor:CanArm(10.5 + MIN_UNGUARDED * 0.5, true)).to.equal(false)
				expect(predictor:CanArm(10.5 + MIN_UNGUARDED + 0.01, true)).to.equal(true)
			end
		)

		it("counts a plain block's release as the guard coming down", function()
			local predictor = fresh()
			predictor:Press(10, false)
			predictor:NoteGuardRaised()
			predictor:Release(10.05)
			expect(predictor:CanArm(10.05 + MIN_UNGUARDED * 0.5, true)).to.equal(false)
		end)

		it("stamps nothing for a deferred press let go before it ever rose", function()
			local predictor = fresh()
			predictor:Press(10, false)
			predictor:Release(10.05)
			expect(predictor:CanArm(10.06, true)).to.equal(true)
		end)
	end)

	describe("ParryPrediction -- the whiff lockout", function()
		it("locks a tap released inside the window until press + RecoveryEnd", function()
			local predictor = fresh()
			predictor:Press(10, true)
			predictor:Release(10.1)
			expect(predictor:CanArm(10 + WINDOW.RecoveryEnd - 0.01, true)).to.equal(false)
			expect(predictor:CanArm(10 + WINDOW.RecoveryEnd + 0.01, true)).to.equal(true)
		end)

		it("charges no lockout for a tap that parried", function()
			local predictor = fresh()
			predictor:Press(10, true)
			predictor:Release(10.05)
			predictor:NoteParryLanded()
			expect(predictor:CanArm(10.1, true)).to.equal(true)
		end)

		it("treats a parry landed with the key held as a guard that later came down", function()
			local predictor = fresh()
			predictor:Press(10, true)
			predictor:NoteParryLanded()
			predictor:Release(10.1)
			expect(predictor:CanArm(10.1 + MIN_UNGUARDED * 0.5, true)).to.equal(false)
			expect(predictor:CanArm(10.1 + MIN_UNGUARDED + 0.01, true)).to.equal(true)
		end)
	end)

	describe("ParryPrediction -- the server's verdict", function()
		it("reports a disagreement for the current press, and re-settles a press already released", function()
			local predictor = fresh()
			local id = predictor:Press(10, true)
			predictor:Release(10.1)
			-- Predicted a parry (so the release looked like a whiff), but the server only blocked it: the
			-- release was a block coming down, not a whiff, so there is no lockout -- only MinUnguarded.
			expect(predictor:Confirm(id, false)).to.equal(true)
			expect(predictor:CanArm(10.1 + MIN_UNGUARDED * 0.5, true)).to.equal(false)
			expect(predictor:CanArm(10.1 + MIN_UNGUARDED + 0.01, true)).to.equal(true)
		end)

		it("adopts the window from the verdict's push for a press made before any window arrived", function()
			local predictor = ParryPrediction.New()
			local id, armed = predictor:Press(10, true)
			expect(armed).to.equal(false)
			-- The verdict's push carries the window; onStateChanged applies it before the verdict.
			predictor:SetWindow(WINDOW)
			expect(predictor:Confirm(id, true)).to.equal(true)
			local held = predictor:GetHeldPress()
			expect(held and held.Window).to.equal(WINDOW)
		end)

		it("reports nothing when the verdict agrees", function()
			local predictor = fresh()
			local id = predictor:Press(10, true)
			expect(predictor:Confirm(id, true)).to.equal(false)
		end)

		it("ignores a verdict for an older press", function()
			local predictor = fresh()
			local first = predictor:Press(10, true)
			predictor:Release(10.5)
			local second = predictor:Press(11, true)
			expect(second).to.equal(first + 1)
			expect(predictor:Confirm(first, false)).to.equal(false)
			local held = predictor:GetHeldPress()
			expect(held and held.Armed).to.equal(true)
		end)
	end)

	describe("ParryPrediction -- a new life", function()
		it("clears every clock but keeps the window", function()
			local predictor = fresh()
			predictor:Press(10, true)
			predictor:Release(10.1)
			predictor:NoteServerState("GuardBroken")
			predictor:Reset()
			expect(predictor:CanArm(10.2, true)).to.equal(true)
			expect(predictor:GetWindow()).to.equal(WINDOW)
		end)
	end)
end
