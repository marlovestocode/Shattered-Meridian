--!strict
-- The W9 equivalence proof: every verb answers exactly as the predicate it replaced, over every combination of the nine flag
-- restraints, plus the leased and derived ones case by case. The OLD predicates are copied here verbatim from the consumers they
-- were removed from (2026-10-27), so a later edit to a verb's row that changes an answer fails here, not in a playtest.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AirComboAttributes = require(ReplicatedStorage.Shared.AirCombo.AirComboAttributes)
local AttributeConstants = require(ReplicatedStorage.Shared.AttributeConstants)
local BodyRestraint = require(ReplicatedStorage.Shared.Combat.BodyRestraint)
local DomainRules = require(ReplicatedStorage.Shared.Domain.DomainRules)
local Rig = require(script.Parent.Parent.TestHelpers.Rig)

local A = AttributeConstants

local FLAGS = {
	A.Frozen,
	A.Grabbed,
	A.Grabbing,
	A.GrabThrowing,
	A.Mounted,
	A.Flying,
	A.RootControlLocked,
	A.SwingRooted,
	A.EmoteMovementLocked,
}

local function on(h: Humanoid, name: string): boolean
	return h:GetAttribute(name) == true
end

-- AttackRequestSystem.bodyGate's Attribute tail.
local function oldSwing(h: Humanoid): string?
	if on(h, A.Mounted) then
		return "Mounted"
	end
	if on(h, A.Frozen) then
		return "Frozen"
	end
	return nil
end

-- DefenseSystem.evadeBodyRefusal after "Committed".
local function oldEvade(h: Humanoid): string?
	if on(h, A.Grabbed) or on(h, A.Grabbing) or on(h, A.Mounted) then
		return "Restrained"
	end
	if on(h, A.Frozen) then
		return "Frozen"
	end
	if AirComboAttributes.IsHeld(h) then
		return "AirHeld"
	end
	if DomainRules.Has(h, "NoEvade") then
		return "DomainSealed"
	end
	return nil
end

-- RunSystem.isMovementLocked's mirrored tiers.
local function oldMove(h: Humanoid): boolean
	return on(h, A.Frozen)
		or on(h, A.Flying)
		or on(h, A.EmoteMovementLocked)
		or on(h, A.Grabbed)
		or on(h, A.GrabThrowing)
		or on(h, A.Mounted)
		or on(h, A.SwingRooted)
end

-- ParkourOwnership.HeldElsewhere.
local function oldParkour(h: Humanoid, now: number?): boolean
	return on(h, A.RootControlLocked)
		or on(h, A.Flying)
		or on(h, A.Frozen)
		or on(h, A.EmoteMovementLocked)
		or AirComboAttributes.IsParticipant(h)
		or DomainRules.Has(h, "Rooted", now)
		or h.Health <= 0
end

-- AttackInputClient's Attribute half (true = allowed).
local function oldLocalSwingAllowed(h: Humanoid): boolean
	return not on(h, A.Mounted) and not on(h, A.Grabbed) and not on(h, A.Grabbing)
end

-- LockOnController.bodyRefusesLock's Humanoid half.
local function oldLockOn(h: Humanoid): boolean
	return h.Health <= 0 or on(h, A.Mounted) or on(h, A.Flying)
end

-- MovementGuard.excuseOf's ServerHeld clause.
local function oldJudge(h: Humanoid): string?
	if on(h, A.RootControlLocked) or on(h, A.Grabbed) or on(h, A.Mounted) or on(h, A.Flying) then
		return "ServerHeld"
	end
	return nil
end

-- AirComboSystem.isRestrained.
local function oldLaunch(h: Humanoid): boolean
	return on(h, A.Grabbed) or on(h, A.Grabbing) or on(h, A.Mounted)
end

local function compareAll(h: Humanoid, label: string): ()
	local function check(verb: string, old: any, new: any)
		if old ~= new then
			error(`{label}: verb {verb} answered {tostring(new)}, the old predicate {tostring(old)}`)
		end
	end
	check("Swing", oldSwing(h), BodyRestraint.Refusal(h, "Swing"))
	check("Guard", on(h, A.Frozen), BodyRestraint.Restrained(h, "Guard"))
	check("GuardRequest", on(h, A.Mounted), BodyRestraint.Restrained(h, "GuardRequest"))
	check("Evade", oldEvade(h), BodyRestraint.Refusal(h, "Evade"))
	check("Move", oldMove(h), BodyRestraint.Restrained(h, "Move"))
	check("Parkour", oldParkour(h), BodyRestraint.Restrained(h, "Parkour"))
	check("LocalSwing", oldLocalSwingAllowed(h), not BodyRestraint.Restrained(h, "LocalSwing"))
	check("Emote", on(h, A.Mounted), BodyRestraint.Restrained(h, "Emote"))
	check("LockOn", oldLockOn(h), BodyRestraint.Restrained(h, "LockOn"))
	check("Judge", oldJudge(h), BodyRestraint.Refusal(h, "Judge"))
	check("Launch", oldLaunch(h), BodyRestraint.Restrained(h, "Launch"))
end

return function()
	describe("BodyRestraint", function()
		afterEach(function()
			Rig.DestroyAll()
		end)

		it("answers every verb exactly as the predicate it replaced, over all 512 flag combinations", function()
			local h = Rig.Dummy("RestraintCombos").Humanoid
			for mask = 0, 2 ^ #FLAGS - 1 do
				local names = {}
				for index, name in FLAGS do
					local set = bit32.band(mask, 2 ^ (index - 1)) ~= 0
					h:SetAttribute(name, if set then true else nil)
					if set then
						table.insert(names, name)
					end
				end
				compareAll(h, `\{{table.concat(names, ",")}\}`)
			end
		end)

		it("agrees on the leased and derived restraints: air hold, realm rules, death", function()
			local h = Rig.Dummy("RestraintLeases").Humanoid
			local now = Workspace:GetServerTimeNow()
			compareAll(h, "nothing")

			h:SetAttribute(A.AirHeldUntil, now + 10)
			compareAll(h, "air held")
			h:SetAttribute(A.AirHeldUntil, now - 10)
			compareAll(h, "air hold lapsed")
			h:SetAttribute(A.AirHeldUntil, nil)

			for flag, bit in DomainRules.FlagBits :: any do
				h:SetAttribute(A.DomainFlags, bit)
				h:SetAttribute(A.DomainUntil, now + 10)
				compareAll(h, `realm {flag}`)
				h:SetAttribute(A.DomainUntil, now - 10)
				compareAll(h, `realm {flag} lapsed`)
			end
			h:SetAttribute(A.DomainFlags, nil)
			h:SetAttribute(A.DomainUntil, nil)

			h.Health = 0
			compareAll(h, "dead")
		end)

		it("restrains the movement camera for each body-holder, in order, and for nothing else", function()
			local h = Rig.Dummy("RestraintCamera").Humanoid
			expect(BodyRestraint.Refusal(h, "CameraMotion")).to.equal(nil)
			for _, name in { A.Mounted, A.Flying, A.RootControlLocked, A.Grabbed, A.Frozen } do
				h:SetAttribute(name, true)
				expect(BodyRestraint.Restrained(h, "CameraMotion")).to.equal(true)
				h:SetAttribute(name, nil)
			end
			-- A swing root, an emote lock and a stun are the body's own business: the camera keeps working.
			for _, name in { A.SwingRooted, A.EmoteMovementLocked, A.HitstunUntil } do
				h:SetAttribute(name, true)
				expect(BodyRestraint.Restrained(h, "CameraMotion")).to.equal(false)
				h:SetAttribute(name, nil)
			end
			h:SetAttribute(A.Mounted, true)
			h:SetAttribute(A.Frozen, true)
			expect(BodyRestraint.Refusal(h, "CameraMotion")).to.equal("Mounted")
		end)

		it("mirrors the movement camera's row by exactly its flag Attributes", function()
			local names = BodyRestraint.AttributesOf("CameraMotion")
			table.sort(names)
			local expected = { A.Mounted, A.Flying, A.RootControlLocked, A.Grabbed, A.Frozen }
			table.sort(expected)
			expect(table.concat(names, ",")).to.equal(table.concat(expected, ","))
		end)

		it("refuses a ragdolled body exactly the verbs the 2026-10-27 decision names, last in each row", function()
			local h = Rig.Dummy("RestraintRagdoll").Humanoid
			h:SetAttribute(A.Ragdolled, true)
			local refused = { "Swing", "Guard", "Evade", "Parkour", "LocalSwing", "Emote", "Judge", "Launch" }
			for _, verb in BodyRestraint.Verbs do
				local expected = table.find(refused, verb) ~= nil
				expect(BodyRestraint.Restrained(h, verb)).to.equal(expected)
			end
			expect(BodyRestraint.Refusal(h, "Judge")).to.equal("ServerHeld")
			-- Last in its row: a body that is also frozen still answers Frozen, as before.
			h:SetAttribute(A.Frozen, true)
			expect(BodyRestraint.Refusal(h, "Swing")).to.equal("Frozen")
		end)

		it("never restrains a missing Humanoid", function()
			for _, verb in BodyRestraint.Verbs do
				expect(BodyRestraint.Refusal(nil, verb)).to.equal(nil)
			end
		end)

		it("hands a mirroring reader exactly the flag Attributes of a row", function()
			local names = BodyRestraint.AttributesOf("Move")
			table.sort(names)
			local expected = {
				A.Frozen,
				A.Flying,
				A.EmoteMovementLocked,
				A.Grabbed,
				A.GrabThrowing,
				A.Mounted,
				A.SwingRooted,
			}
			table.sort(expected)
			expect(table.concat(names, ",")).to.equal(table.concat(expected, ","))
		end)
	end)
end
