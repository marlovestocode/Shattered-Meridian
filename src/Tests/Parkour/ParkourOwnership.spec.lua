--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ParkourOwnership = require(ReplicatedStorage.Shared.Parkour.ParkourOwnership)
local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)
local AttackConstants = require(ReplicatedStorage.Shared.Attack.AttackConstants)
local DomainRules = require(ReplicatedStorage.Shared.Domain.DomainRules)

return function()
	describe("IsActionState", function()
		it("calls every committed traversal an action", function()
			-- Dashing is here for the same reason Evading is: it owns velocity, it declares a Reports
			-- kind, and swinging out of the middle of one would be the combat layer overwriting a
			-- movement the server has already stood its WalkSpeed resolver down for.
			for _, stateId in
				{ "Sliding", "Vaulting", "Mantling", "WallRunning", "LedgeClimbing", "Evading", "Dashing" }
			do
				expect(ParkourOwnership.IsActionState(stateId :: any)).to.equal(true, stateId)
			end
			expect(ParkourOwnership.IsActionState("Leaping")).to.equal(true)
			expect(ParkourOwnership.IsActionState("LedgeLeaping")).to.equal(true)
			-- The one the server's own Attribute cannot see, and the entire reason the client-side
			-- ParkourActionOwned mirror exists -- States/LedgeHanging.lua declares no Reports kind.
			expect(ParkourOwnership.IsActionState("LedgeHanging")).to.equal(true)
		end)

		it("leaves ordinary locomotion alone", function()
			-- You must be able to fight standing still and while walking. Sprinting is deliberately NOT
			-- an action either: running into a fight is handled by forcing the run DOWN (RunSystem's
			-- CombatBusyUntil tier), never by refusing the attack.
			for _, stateId in { "Idle", "Walking", "Sprinting" } do
				expect(ParkourOwnership.IsActionState(stateId :: any)).to.equal(false, stateId)
			end
		end)

		it("leaves ordinary air time alone", function()
			-- A jump is not a traversal. Refusing an attack for being briefly airborne would delete
			-- jump-cancelling and every aerial exchange in the game.
			for _, stateId in { "Jumping", "WallLaunching", "Falling", "Landing" } do
				expect(ParkourOwnership.IsActionState(stateId :: any)).to.equal(false, stateId)
			end
		end)

		it("does not count CombatHeld, which would make combat refuse itself", function()
			-- That state is where parkour parks WHILE combat owns the body. Counting it would mean the
			-- first swing hands the body over, parkour parks, and every following swing is refused for
			-- being "in a parkour action" -- aerial combat gone entirely.
			expect(ParkourOwnership.IsActionState("CombatHeld")).to.equal(false)
		end)

		it("treats no state at all as not an action", function()
			-- The framework disabled, or between characters. Must not refuse combat.
			expect(ParkourOwnership.IsActionState(nil)).to.equal(false)
		end)
	end)

	describe("OwnsBody", function()
		local function humanoidWith(value: any): Humanoid
			local humanoid = Instance.new("Humanoid")
			if value ~= nil then
				humanoid:SetAttribute(AttributeConstants.ParkourVelocityOwned, value)
			end
			return humanoid
		end

		it("reads the Attribute ParkourSystem publishes", function()
			expect(ParkourOwnership.OwnsBody(humanoidWith(true))).to.equal(true)
			expect(ParkourOwnership.OwnsBody(humanoidWith(false))).to.equal(false)
		end)

		it("reads unset as not owned, so a bot is never gated", function()
			-- A bot has no parkour and therefore no Attribute. This is what keeps the combat gates free
			-- of a "is this a player" special case.
			expect(ParkourOwnership.OwnsBody(humanoidWith(nil))).to.equal(false)
		end)

		it("reads a non-boolean as not owned rather than as truthy", function()
			-- Attribute types are not enforced by anything. Failing OPEN is the right direction here:
			-- the gate refuses combat, so a malformed value must not be able to lock someone out of
			-- fighting for a whole life.
			expect(ParkourOwnership.OwnsBody(humanoidWith("yes"))).to.equal(false)
			expect(ParkourOwnership.OwnsBody(humanoidWith(1))).to.equal(false)
		end)
	end)

	describe("HeldElsewhere", function()
		local NOW = 1000
		local created: { Humanoid } = {}

		local function freeHumanoid(): Humanoid
			local humanoid = Instance.new("Humanoid")
			table.insert(created, humanoid)
			return humanoid
		end

		afterEach(function()
			for _, humanoid in created do
				humanoid:Destroy()
			end
			table.clear(created)
		end)

		it("reads a free body as free", function()
			expect(ParkourOwnership.HeldElsewhere(freeHumanoid(), NOW)).to.equal(false)
		end)

		it("reads every published hold", function()
			for _, attribute in
				{
					AttributeConstants.RootControlLocked,
					AttributeConstants.Flying,
					AttributeConstants.Frozen,
					AttributeConstants.EmoteMovementLocked,
				}
			do
				local humanoid = freeHumanoid()
				humanoid:SetAttribute(attribute, true)
				expect(ParkourOwnership.HeldElsewhere(humanoid, NOW)).to.equal(true, attribute)
			end
		end)

		it("reads a realm's Rooted rule, but only inside the realm's lease", function()
			-- The hold nobody in parkour read before: RunSystem zeroed WalkSpeed, and a dash or a leap
			-- (which never read WalkSpeed) carried the body out anyway.
			local humanoid = freeHumanoid()
			humanoid:SetAttribute(AttributeConstants.DomainFlags, DomainRules.FlagBits.Rooted)
			humanoid:SetAttribute(AttributeConstants.DomainUntil, NOW + 5)
			expect(ParkourOwnership.HeldElsewhere(humanoid, NOW)).to.equal(true)
			expect(ParkourOwnership.HeldElsewhere(humanoid, NOW + 6)).to.equal(false)
		end)

		it("does not read a realm's other flags as a hold", function()
			local humanoid = freeHumanoid()
			humanoid:SetAttribute(AttributeConstants.DomainFlags, DomainRules.FlagBits.NoParkour)
			humanoid:SetAttribute(AttributeConstants.DomainUntil, NOW + 5)
			expect(ParkourOwnership.HeldElsewhere(humanoid, NOW)).to.equal(false)
		end)

		it("reads a dead body as held", function()
			local humanoid = freeHumanoid()
			humanoid.Health = 0
			expect(ParkourOwnership.HeldElsewhere(humanoid, NOW)).to.equal(true)
		end)
	end)

	describe("refusal buffering", function()
		it("does not buffer a press refused for a parkour action", function()
			-- The gate's whole point: a buffered press would fire on the frame the vault ends, which is
			-- the free hit the refusal exists to remove. Expressed by keeping the reason OUT of the
			-- transient table, so this asserts on the absence deliberately.
			expect(AttackConstants.Input.TransientRefusals.ParkourAction).to.never.be.ok()
		end)

		it("still buffers the refusals that genuinely clear on their own", function()
			-- Guards the assertion above against being satisfied by an empty table.
			expect(AttackConstants.Input.TransientRefusals.Busy).to.equal(true)
			expect(AttackConstants.Input.TransientRefusals.Hitstun).to.equal(true)
			expect(AttackConstants.Input.TransientRefusals.ChainDelay).to.equal(true)
		end)
	end)
end
