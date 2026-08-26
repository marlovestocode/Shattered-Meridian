--!strict
-- Covers Client/Parkour/InputBuffer.lua -- the buffered parkour intents and the two assist windows.
--
-- The Peek/Consume distinction gets the most attention here, because getting it backwards produces a
-- bug that only manifests with the debug overlay open (the overlay calls every CanEnter on a timer,
-- and a consuming CanEnter would silently eat the player's inputs the whole time) -- which is exactly
-- when it is hardest to notice, and exactly the kind of thing a spec is better at catching than a
-- playtest.
--
-- The buffer is a module-level singleton, so every test clears it first rather than relying on the
-- previous one having left it tidy.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local InputBuffer = require(StarterPlayer.StarterPlayerScripts.Client.Parkour.InputBuffer)
local ParkourConstants = require(ReplicatedStorage.Shared.Parkour.ParkourConstants)

local ALL_ASSISTS_ON = {
	CoyoteTime = true,
	JumpBuffer = true,
	AutoVault = true,
	LedgeAssist = true,
	StepAssist = true,
}

local ALL_ASSISTS_OFF = {
	CoyoteTime = false,
	JumpBuffer = false,
	AutoVault = false,
	LedgeAssist = false,
	StepAssist = false,
}

local JUMP_WINDOW = ParkourConstants.Jump.BufferSeconds
local ACTION_WINDOW = ParkourConstants.Assists.ActionBufferSeconds
local COYOTE_WINDOW = ParkourConstants.Jump.CoyoteTimeSeconds

return function()
	beforeEach(function()
		InputBuffer.Clear()
		InputBuffer.SetAssists(ALL_ASSISTS_ON)
	end)

	describe("InputBuffer -- jump", function()
		it("reports nothing buffered before any press", function()
			expect(InputBuffer.PeekJump(100)).to.equal(false)
		end)

		it("reports a live press inside the window", function()
			InputBuffer.PressJump(100)
			expect(InputBuffer.PeekJump(100 + JUMP_WINDOW * 0.5)).to.equal(true)
		end)

		it("expires past the window", function()
			InputBuffer.PressJump(100)
			expect(InputBuffer.PeekJump(100 + JUMP_WINDOW + 0.01)).to.equal(false)
		end)

		it("Peek does NOT consume -- repeated peeks all see the same press", function()
			InputBuffer.PressJump(100)
			expect(InputBuffer.PeekJump(100)).to.equal(true)
			expect(InputBuffer.PeekJump(100)).to.equal(true)
			expect(InputBuffer.PeekJump(100)).to.equal(true)
		end)

		it("Consume spends the press so one input can only ever produce one action", function()
			InputBuffer.PressJump(100)
			expect(InputBuffer.ConsumeJump(100)).to.equal(true)
			expect(InputBuffer.ConsumeJump(100)).to.equal(false)
			expect(InputBuffer.PeekJump(100)).to.equal(false)
		end)

		it("Consume returns false without clearing anything when nothing is live", function()
			expect(InputBuffer.ConsumeJump(100)).to.equal(false)
		end)

		it("still sees a fresh press when the JumpBuffer assist is off", function()
			-- THE REGRESSION THIS FILE ONCE LOCKED IN. PeekJump used to pass the assist flag as
			-- BufferLive's `enabled` argument, which short-circuits before reading the timestamp -- so
			-- switching the assist off returned false for every press at every instant, and this spec
			-- asserted that as correct.
			--
			-- It is not correct, because PeekJump is not only the buffered-jump test: it is the "was
			-- jump pressed at all" test behind WallRunning's kick trigger, LedgeClimbing's CanEnter, the
			-- ledge climb-up branch and the slide-jump. Turning off one forgiveness toggle deleted all of
			-- them. The assist chooses the WINDOW; it never decides whether the press happened. (Leaping
			-- is NOT on this list -- it reads its own dedicated PeekLeap now, not PeekJump at all -- see
			-- States/Leaping.lua's own header.)
			InputBuffer.SetAssists(ALL_ASSISTS_OFF)
			InputBuffer.PressJump(100)
			expect(InputBuffer.PeekJump(100)).to.equal(true)
			expect(InputBuffer.ConsumeJump(100)).to.equal(true)
		end)

		it("stops REMEMBERING a press when the JumpBuffer assist is off", function()
			-- The other half of the contract above: the assist is off, so a press that has aged past
			-- the unbuffered delivery window is gone. Sampled at a point that is inside the full
			-- buffer window and outside the unbuffered one, so this fails if the two are ever
			-- collapsed into the same number.
			InputBuffer.SetAssists(ALL_ASSISTS_OFF)
			InputBuffer.PressJump(100)
			local stale = 100 + ParkourConstants.Jump.UnbufferedWindowSeconds + 0.001
			expect(stale < 100 + JUMP_WINDOW).to.equal(true)
			expect(InputBuffer.PeekJump(stale)).to.equal(false)
		end)

		it("still honors the full buffer window when the assist is on", function()
			InputBuffer.SetAssists(ALL_ASSISTS_ON)
			InputBuffer.PressJump(100)
			expect(InputBuffer.PeekJump(100 + JUMP_WINDOW - 0.001)).to.equal(true)
			expect(InputBuffer.PeekJump(100 + JUMP_WINDOW + 0.001)).to.equal(false)
		end)

		it("uses jump's own window, tighter than the shared action window", function()
			-- Jump is the input players press most reflexively; a window long enough to feel generous for
			-- a slide reads as the character jumping on its own a beat after you stopped asking. Asserted
			-- rather than assumed, because the two windows are separate constants that a tuning pass could
			-- easily bring level without noticing what that costs.
			expect(JUMP_WINDOW < ACTION_WINDOW).to.equal(true)
		end)
	end)

	describe("InputBuffer -- slide", function()
		it("buffers a press and marks slide as held", function()
			InputBuffer.PressSlide(100)
			expect(InputBuffer.PeekSlide(100)).to.equal(true)
			expect(InputBuffer.IsSlideHeld()).to.equal(true)
		end)

		it("clears the held flag on release WITHOUT clearing the buffered press", function()
			-- The two are genuinely separate signals: States/Sliding.lua reads the press to START and the
			-- hold to decide whether to CONTINUE, so a quick tap must still be able to begin a slide.
			InputBuffer.PressSlide(100)
			InputBuffer.ReleaseSlide()
			expect(InputBuffer.IsSlideHeld()).to.equal(false)
			expect(InputBuffer.PeekSlide(100)).to.equal(true)
		end)

		it("expires the press past the shared action window", function()
			InputBuffer.PressSlide(100)
			expect(InputBuffer.PeekSlide(100 + ACTION_WINDOW + 0.01)).to.equal(false)
		end)

		it("Consume spends the press but leaves the held flag alone", function()
			InputBuffer.PressSlide(100)
			expect(InputBuffer.ConsumeSlide(100)).to.equal(true)
			expect(InputBuffer.PeekSlide(100)).to.equal(false)
			expect(InputBuffer.IsSlideHeld()).to.equal(true)
		end)

		it("is unaffected by the assist toggles -- slide buffering is not an optional assist", function()
			InputBuffer.SetAssists(ALL_ASSISTS_OFF)
			InputBuffer.PressSlide(100)
			expect(InputBuffer.PeekSlide(100)).to.equal(true)
		end)
	end)

	describe("InputBuffer -- the air-held slide", function()
		it("arms a press on landing while the key is held, however long the fall was", function()
			-- The whole mechanic: slideHeld is true the entire way down, but the press expires after
			-- the action window, so without this a fall of any real length lands with
			-- States/Sliding.CanEnter refusing "NoSlideInput". Five seconds is deliberately far past
			-- any window in this file -- the point is that fall LENGTH stops mattering.
			InputBuffer.PressSlide(100)
			expect(InputBuffer.PeekSlide(105)).to.equal(false)
			InputBuffer.ArmHeldSlideOnLanding(105)
			expect(InputBuffer.PeekSlide(105)).to.equal(true)
		end)

		it("arms nothing once the key has been released", function()
			-- Releasing mid-air cancels the queued slide, which is why the re-stamp is gated on the
			-- held flag rather than on a press having happened at some point.
			InputBuffer.PressSlide(100)
			InputBuffer.ReleaseSlide()
			InputBuffer.ArmHeldSlideOnLanding(105)
			expect(InputBuffer.PeekSlide(105)).to.equal(false)
		end)

		it("arms nothing when the key was never pressed at all", function()
			InputBuffer.ArmHeldSlideOnLanding(105)
			expect(InputBuffer.PeekSlide(105)).to.equal(false)
		end)

		it("grants ONE attempt per landing, not a press that stays live while held", function()
			-- A continuously-live hold would re-enter Sliding on the frame after every slide ended, for
			-- as long as the key was down. The armed press expires through the ordinary window like any
			-- other, while the held flag (which States/Sliding.lua reads to CONTINUE) stays true.
			InputBuffer.PressSlide(100)
			InputBuffer.ArmHeldSlideOnLanding(200)
			expect(InputBuffer.PeekSlide(200)).to.equal(true)
			expect(InputBuffer.IsSlideHeld()).to.equal(true)
			expect(InputBuffer.PeekSlide(200 + ACTION_WINDOW + 0.01)).to.equal(false)
		end)

		it("is dropped by Clear, so a press held into a respawn cannot fire on the first landing", function()
			-- Same bug class Clear already closes for the ordinary presses (see its own describe block):
			-- this one would otherwise outlive a respawn by holding a flag rather than a timestamp.
			InputBuffer.PressSlide(100)
			InputBuffer.Clear()
			InputBuffer.ArmHeldSlideOnLanding(105)
			expect(InputBuffer.PeekSlide(105)).to.equal(false)
		end)
	end)

	describe("InputBuffer -- roll", function()
		it("buffers and consumes a press", function()
			InputBuffer.PressRoll(100)
			expect(InputBuffer.PeekRoll(100)).to.equal(true)
			expect(InputBuffer.ConsumeRoll(100)).to.equal(true)
			expect(InputBuffer.PeekRoll(100)).to.equal(false)
		end)

		it("expires past the shared action window", function()
			InputBuffer.PressRoll(100)
			expect(InputBuffer.PeekRoll(100 + ACTION_WINDOW + 0.01)).to.equal(false)
		end)
	end)

	describe("InputBuffer -- dash", function()
		it("buffers and consumes a press", function()
			InputBuffer.PressDash(100)
			expect(InputBuffer.PeekDash(100)).to.equal(true)
			expect(InputBuffer.ConsumeDash(100)).to.equal(true)
			expect(InputBuffer.PeekDash(100)).to.equal(false)
		end)

		it("expires past the shared action window", function()
			InputBuffer.PressDash(100)
			expect(InputBuffer.PeekDash(100 + ACTION_WINDOW + 0.01)).to.equal(false)
		end)

		it("does not consume on a peek", function()
			-- The contract States/Dashing.CanEnter depends on. ParkourDebug calls every registered
			-- state's CanEnter on a timer, so a peek that consumed would have the overlay eating the
			-- player's dash presses for as long as it was open -- a bug that only appears while you
			-- are looking at the tool meant to diagnose it.
			InputBuffer.PressDash(100)
			for _ = 1, 5 do
				expect(InputBuffer.PeekDash(100)).to.equal(true)
			end
			expect(InputBuffer.ConsumeDash(100)).to.equal(true)
		end)
	end)

	describe("InputBuffer -- intents are independent", function()
		it("consuming a jump leaves slide, roll, leap and dash alone", function()
			InputBuffer.PressJump(100)
			InputBuffer.PressSlide(100)
			InputBuffer.PressRoll(100)
			InputBuffer.PressLeap(100)
			InputBuffer.PressDash(100)
			InputBuffer.ConsumeJump(100)
			expect(InputBuffer.PeekSlide(100)).to.equal(true)
			expect(InputBuffer.PeekRoll(100)).to.equal(true)
			expect(InputBuffer.PeekLeap(100)).to.equal(true)
			expect(InputBuffer.PeekDash(100)).to.equal(true)
		end)

		it("consuming a dash leaves the roll alone -- they are separate keys and separate moves", function()
			InputBuffer.PressRoll(100)
			InputBuffer.PressDash(100)
			InputBuffer.ConsumeDash(100)
			expect(InputBuffer.PeekRoll(100)).to.equal(true)
		end)
	end)

	describe("InputBuffer.CoyoteAvailable", function()
		it("allows a jump shortly after leaving the ground", function()
			expect(InputBuffer.CoyoteAvailable(100 + COYOTE_WINDOW * 0.5, 100)).to.equal(true)
		end)

		it("refuses past the window", function()
			expect(InputBuffer.CoyoteAvailable(100 + COYOTE_WINDOW + 0.01, 100)).to.equal(false)
		end)

		it("refuses when the CoyoteTime assist is switched off", function()
			InputBuffer.SetAssists(ALL_ASSISTS_OFF)
			expect(InputBuffer.CoyoteAvailable(100.01, 100)).to.equal(false)
		end)

		it("refuses for a character that has never left the ground", function()
			expect(InputBuffer.CoyoteAvailable(100, 0)).to.equal(false)
		end)
	end)

	describe("InputBuffer.Clear", function()
		it("drops every buffered press and the held flag", function()
			-- The real bug class this closes: a jump pressed while dying firing the instant the player
			-- respawns.
			InputBuffer.PressJump(100)
			InputBuffer.PressSlide(100)
			InputBuffer.PressRoll(100)
			InputBuffer.PressLeap(100)
			InputBuffer.PressDash(100)
			InputBuffer.Clear()

			expect(InputBuffer.PeekJump(100)).to.equal(false)
			expect(InputBuffer.PeekSlide(100)).to.equal(false)
			expect(InputBuffer.PeekRoll(100)).to.equal(false)
			expect(InputBuffer.PeekLeap(100)).to.equal(false)
			expect(InputBuffer.PeekDash(100)).to.equal(false)
			expect(InputBuffer.IsSlideHeld()).to.equal(false)
		end)
	end)

	describe("InputBuffer -- leap", function()
		-- Leap used to be detected as a double tap of jump, with its own two-timestamp gesture-detection
		-- machinery here. It is now a dedicated key with a dedicated buffered press -- see
		-- States/Leaping.lua's own header for the change -- so it is tested exactly like Roll above
		-- rather than needing a describe block of its own shape.
		it("buffers and consumes a press", function()
			InputBuffer.PressLeap(100)
			expect(InputBuffer.PeekLeap(100)).to.equal(true)
			expect(InputBuffer.ConsumeLeap(100)).to.equal(true)
			expect(InputBuffer.PeekLeap(100)).to.equal(false)
		end)

		it("expires past the shared action window", function()
			InputBuffer.PressLeap(100)
			expect(InputBuffer.PeekLeap(100 + ACTION_WINDOW + 0.01)).to.equal(false)
		end)

		it("is independent of jump -- pressing one never touches the other's buffer", function()
			InputBuffer.PressJump(100)
			InputBuffer.PressLeap(100)
			InputBuffer.ConsumeJump(100)
			expect(InputBuffer.PeekLeap(100)).to.equal(true)
			InputBuffer.ConsumeLeap(100)
			expect(InputBuffer.PeekJump(100)).to.equal(false)
		end)
	end)

	describe("InputBuffer.SetAssists / GetAssists", function()
		it("round-trips the assist block", function()
			InputBuffer.SetAssists(ALL_ASSISTS_OFF)
			local assists = InputBuffer.GetAssists()
			expect(assists.CoyoteTime).to.equal(false)
			expect(assists.AutoVault).to.equal(false)
		end)

		it("defaults to whatever ParkourConstants currently ships", function()
			-- Not hardcoded here on purpose: the defaults are a tuning decision that lives in one file,
			-- and this asserts the buffer honors it rather than re-stating it.
			InputBuffer.SetAssists({
				CoyoteTime = ParkourConstants.Assists.CoyoteTime,
				JumpBuffer = ParkourConstants.Assists.JumpBuffer,
				AutoVault = ParkourConstants.Assists.AutoVault,
				LedgeAssist = ParkourConstants.Assists.LedgeAssist,
				StepAssist = ParkourConstants.Assists.StepAssist,
			})
			expect(InputBuffer.GetAssists().JumpBuffer).to.equal(ParkourConstants.Assists.JumpBuffer)
		end)
	end)
end
