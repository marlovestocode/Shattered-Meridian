--!strict
-- Covers Client/Movement/TurnGate.lua -- the one client writer of the local Humanoid's AutoRotate.
--
-- The cases that matter are the overlaps four snapshot/restore writers got wrong: a swing ending inside a
-- grab throw, a swing ending after shift lock engaged, and parkour letting go of a shift-locked body.

local StarterPlayer = game:GetService("StarterPlayer")

local TurnGate = require(StarterPlayer.StarterPlayerScripts.Client.Movement.TurnGate)

local OWNERS = TurnGate.Owners

return function()
	local humanoid: Humanoid

	beforeEach(function()
		humanoid = Instance.new("Humanoid")
	end)

	afterEach(function()
		humanoid:Destroy()
	end)

	it("turns AutoRotate off while a claim is held and back on when it goes", function()
		expect(humanoid.AutoRotate).to.equal(true)
		TurnGate.Set(humanoid, OWNERS.SwingTrack, true)
		expect(humanoid.AutoRotate).to.equal(false)
		TurnGate.Set(humanoid, OWNERS.SwingTrack, false)
		expect(humanoid.AutoRotate).to.equal(true)
		expect(TurnGate.IsHeld(humanoid)).to.equal(false)
	end)

	it("keeps a grab throw's hold when the throw swing's tracking ends first", function()
		-- The swing captured `true`, the throw captured the swing's `false`, and the swing's end wrote
		-- `true` mid-throw.
		TurnGate.Set(humanoid, OWNERS.SwingTrack, true)
		TurnGate.Set(humanoid, OWNERS.GrabThrow, true)
		TurnGate.Set(humanoid, OWNERS.SwingTrack, false)
		expect(humanoid.AutoRotate).to.equal(false)
		TurnGate.Set(humanoid, OWNERS.GrabThrow, false)
		expect(humanoid.AutoRotate).to.equal(true)
	end)

	it("keeps shift lock's hold when a swing that started before it ends", function()
		TurnGate.Set(humanoid, OWNERS.SwingTrack, true)
		TurnGate.Set(humanoid, OWNERS.ShiftLock, true)
		TurnGate.Set(humanoid, OWNERS.SwingTrack, false)
		expect(humanoid.AutoRotate).to.equal(false)
		TurnGate.Set(humanoid, OWNERS.ShiftLock, false)
	end)

	it("hands turning back when shift lock disengages during a traversal and parkour then lets go", function()
		TurnGate.Set(humanoid, OWNERS.ShiftLock, true)
		TurnGate.Set(humanoid, OWNERS.Parkour, true)
		-- Disengaging mid-traversal must not free a body parkour is steering.
		TurnGate.Set(humanoid, OWNERS.ShiftLock, false)
		expect(humanoid.AutoRotate).to.equal(false)
		-- And parkour's release must not restore the shift-locked `false` it would have captured.
		TurnGate.Set(humanoid, OWNERS.Parkour, false)
		expect(humanoid.AutoRotate).to.equal(true)
	end)

	it("answers 'held by someone else' without counting the asker", function()
		TurnGate.Set(humanoid, OWNERS.Parkour, true)
		expect(TurnGate.IsHeldExcept(humanoid, OWNERS.Parkour)).to.equal(false)
		TurnGate.Set(humanoid, OWNERS.ShiftLock, true)
		expect(TurnGate.IsHeldExcept(humanoid, OWNERS.Parkour)).to.equal(true)
		expect(TurnGate.IsHeldExcept(humanoid, OWNERS.ShiftLock)).to.equal(true)
		TurnGate.Set(humanoid, OWNERS.Parkour, false)
		TurnGate.Set(humanoid, OWNERS.ShiftLock, false)
	end)

	it("re-asserts the value when an owner restates its answer, and ignores a release never taken", function()
		TurnGate.Set(humanoid, OWNERS.ShiftLock, true)
		humanoid.AutoRotate = true
		TurnGate.Set(humanoid, OWNERS.ShiftLock, true)
		expect(humanoid.AutoRotate).to.equal(false)
		TurnGate.Set(humanoid, OWNERS.GrabThrow, false)
		expect(humanoid.AutoRotate).to.equal(false)
		TurnGate.Set(humanoid, OWNERS.ShiftLock, false)
	end)

	it("keeps each Humanoid's claims to itself, so a fresh life starts unheld", function()
		local fresh = Instance.new("Humanoid")
		TurnGate.Set(humanoid, OWNERS.ShiftLock, true)
		expect(fresh.AutoRotate).to.equal(true)
		expect(TurnGate.IsHeld(fresh)).to.equal(false)
		TurnGate.Set(humanoid, OWNERS.ShiftLock, false)
		fresh:Destroy()
	end)
end
