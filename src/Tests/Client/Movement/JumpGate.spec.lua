--!strict
-- Covers Client/Movement/JumpGate.lua -- the one writer of the local Humanoid's Jumping switch.
--
-- The case that matters is the one three direct writers got wrong: two owners overlapping, and the
-- first to let go must not hand the jump back while the other still holds it.

local StarterPlayer = game:GetService("StarterPlayer")

local JumpGate = require(StarterPlayer.StarterPlayerScripts.Client.Movement.JumpGate)

local OWNERS = JumpGate.Owners
local JUMPING = Enum.HumanoidStateType.Jumping

return function()
	local humanoid: Humanoid

	beforeEach(function()
		humanoid = Instance.new("Humanoid")
	end)

	afterEach(function()
		humanoid:Destroy()
	end)

	it("stands the jump down while a claim is held and gives it back when it goes", function()
		JumpGate.Set(humanoid, OWNERS.SwingRoot, true)
		expect(humanoid:GetStateEnabled(JUMPING)).to.equal(false)
		expect(JumpGate.IsHeld(humanoid, OWNERS.SwingRoot)).to.equal(true)

		JumpGate.Set(humanoid, OWNERS.SwingRoot, false)
		expect(humanoid:GetStateEnabled(JUMPING)).to.equal(true)
		expect(JumpGate.IsHeld(humanoid)).to.equal(false)
	end)

	it("keeps the jump down until the LAST owner lets go", function()
		-- The launcher window lapsing mid locked swing used to write `true` and free the attacker.
		JumpGate.Set(humanoid, OWNERS.LauncherWindow, true)
		JumpGate.Set(humanoid, OWNERS.SwingRoot, true)
		JumpGate.Set(humanoid, OWNERS.LauncherWindow, false)
		expect(humanoid:GetStateEnabled(JUMPING)).to.equal(false)
		expect(JumpGate.IsHeld(humanoid, OWNERS.LauncherWindow)).to.equal(false)
		expect(JumpGate.IsHeld(humanoid, OWNERS.SwingRoot)).to.equal(true)

		JumpGate.Set(humanoid, OWNERS.SwingRoot, false)
		expect(humanoid:GetStateEnabled(JUMPING)).to.equal(true)
	end)

	it("treats a repeated claim or release as a no-op", function()
		JumpGate.Set(humanoid, OWNERS.GrabThrow, true)
		JumpGate.Set(humanoid, OWNERS.GrabThrow, true)
		JumpGate.Set(humanoid, OWNERS.GrabThrow, false)
		expect(humanoid:GetStateEnabled(JUMPING)).to.equal(true)
		-- Releasing a claim never taken must not take anything else's.
		JumpGate.Set(humanoid, OWNERS.RealmRoot, true)
		JumpGate.Set(humanoid, OWNERS.GrabThrow, false)
		expect(humanoid:GetStateEnabled(JUMPING)).to.equal(false)
		JumpGate.Set(humanoid, OWNERS.RealmRoot, false)
	end)

	it("re-asserts the switch when an owner restates its answer", function()
		JumpGate.Set(humanoid, OWNERS.SwingRoot, true)
		-- Something outside the gate flips it back on.
		humanoid:SetStateEnabled(JUMPING, true)
		JumpGate.Set(humanoid, OWNERS.SwingRoot, true)
		expect(humanoid:GetStateEnabled(JUMPING)).to.equal(false)
		JumpGate.Set(humanoid, OWNERS.SwingRoot, false)
	end)

	it("keeps each Humanoid's claims to itself", function()
		local other = Instance.new("Humanoid")
		JumpGate.Set(humanoid, OWNERS.SwingRoot, true)
		expect(other:GetStateEnabled(JUMPING)).to.equal(true)
		expect(JumpGate.IsHeld(other)).to.equal(false)
		JumpGate.Set(humanoid, OWNERS.SwingRoot, false)
		other:Destroy()
	end)
end
