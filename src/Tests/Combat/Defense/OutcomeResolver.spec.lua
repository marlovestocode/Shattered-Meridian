--!strict
-- Covers Server/Combat/Defense/OutcomeResolver.lua -- what a contact turned out to be.
--
-- Entirely table-driven, with no rig at all: the resolver is pure, and every interesting rule in the
-- defence system (is this a parry, did it come from behind, does the guard hold) is a decision about
-- a handful of numbers. A case here that needed a body would mean the resolver had stopped being
-- pure, which is the property worth protecting.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local DefenseTypes = require(ReplicatedStorage.Shared.Defense.DefenseTypes)
local OutcomeResolver = require(ServerScriptService.Server.Combat.Defense.OutcomeResolver)

type ResolveInput = DefenseTypes.ResolveInput

local GUARD_MAX = DefenseConstants.Guard.Max
local ARC_HALF = DefenseConstants.BlockArcDegrees * 0.5

local function makeInput(overrides: { [string]: any }): ResolveInput
	local base: { [string]: any } = {
		DefenderState = "Neutral",
		BearingDegrees = 0,
		PowerLevel = 1,
		Guard = GUARD_MAX,
		GuardMax = GUARD_MAX,
		BlockHeld = false,
		ParryLive = false,
		ParryConsumed = false,
	}
	for key, value in overrides do
		base[key] = value
	end
	return base :: any
end

return function()
	describe("OutcomeResolver.Resolve -- evasion (rule 0)", function()
		it("evades a contact inside the evade window, spending nothing", function()
			local result = OutcomeResolver.Resolve(makeInput({ Evading = true, Guard = 40 }))
			expect(result.Kind).to.equal("Evaded")
			expect(result.Guard).to.equal(40)
			expect(result.GuardDelta).to.equal(0)
			expect(result.ConsumesParry).to.equal(false)
		end)

		it("outranks a backstab -- the dodge does not care which way it came from", function()
			local result = OutcomeResolver.Resolve(makeInput({
				Evading = true,
				DefenderState = "Blocking",
				BlockHeld = true,
				BearingDegrees = 180,
			}))
			expect(result.Kind).to.equal("Evaded")
		end)

		it("outranks a live parry, and does not spend it", function()
			local result = OutcomeResolver.Resolve(makeInput({ Evading = true, ParryLive = true }))
			expect(result.Kind).to.equal("Evaded")
			expect(result.ConsumesParry).to.equal(false)
		end)

		it("outranks a block, so the guard is not drained", function()
			local result = OutcomeResolver.Resolve(makeInput({
				Evading = true,
				DefenderState = "Blocking",
				BlockHeld = true,
				PowerLevel = 3,
			}))
			expect(result.Kind).to.equal("Evaded")
			expect(result.GuardDelta).to.equal(0)
		end)

		it("treats an input that predates the field as not evading", function()
			expect(OutcomeResolver.Resolve(makeInput({})).Kind).to.equal("Clean")
			expect(OutcomeResolver.Resolve(makeInput({ Evading = false })).Kind).to.equal("Clean")
		end)
	end)

	describe("OutcomeResolver.BearingDegrees", function()
		local origin = Vector3.new(0, 0, 0)
		-- Roblox convention: -Z is forward.
		local forward = Vector3.new(0, 0, -1)

		it("reads dead ahead as zero", function()
			expect(OutcomeResolver.BearingDegrees(forward, origin, Vector3.new(0, 0, -10))).to.be.near(0, 1e-4)
		end)

		it("reads directly behind as 180", function()
			expect(OutcomeResolver.BearingDegrees(forward, origin, Vector3.new(0, 0, 10))).to.be.near(180, 1e-4)
		end)

		it("reads either flank as 90", function()
			expect(OutcomeResolver.BearingDegrees(forward, origin, Vector3.new(10, 0, 0))).to.be.near(90, 1e-4)
			expect(OutcomeResolver.BearingDegrees(forward, origin, Vector3.new(-10, 0, 0))).to.be.near(90, 1e-4)
		end)

		it("flattens the vertical, so a hit from above is not a hit from behind", function()
			-- Letting Y in would make a block depend on the height difference to the attacker.
			expect(OutcomeResolver.BearingDegrees(forward, origin, Vector3.new(0, 50, -10))).to.be.near(0, 1e-4)
		end)

		it("returns dead ahead for a degenerate input rather than NaN", function()
			-- A NaN here would propagate into every comparison and silently resolve everything Clean.
			expect(OutcomeResolver.BearingDegrees(forward, origin, origin)).to.equal(0)
			expect(OutcomeResolver.BearingDegrees(Vector3.zero, origin, Vector3.new(0, 0, -10))).to.equal(0)
		end)
	end)

	describe("OutcomeResolver.Mitigates", function()
		it("mitigates while Blocking", function()
			expect(OutcomeResolver.Mitigates("Blocking", true)).to.equal(true)
		end)

		it("does NOT mitigate during the raise or the window", function()
			-- The guard is not live until the window closes. That is the raise time, and it is what
			-- stops a player blocking instantly out of a whiffed attack.
			expect(OutcomeResolver.Mitigates("Raising", true)).to.equal(false)
			expect(OutcomeResolver.Mitigates("ParryWindow", true)).to.equal(false)
		end)

		it("mitigates a staggered block, because the brief allows one", function()
			expect(OutcomeResolver.Mitigates("Staggered", true)).to.equal(true)
			expect(OutcomeResolver.Mitigates("Staggered", false)).to.equal(false)
		end)

		it("never mitigates a broken guard", function()
			-- That is the opening.
			expect(OutcomeResolver.Mitigates("GuardBroken", true)).to.equal(false)
		end)
	end)

	describe("OutcomeResolver.Resolve -- clean", function()
		it("resolves an unguarded hit clean and touches no guard", function()
			local result = OutcomeResolver.Resolve(makeInput({}))
			expect(result.Kind).to.equal("Clean")
			expect(result.GuardDelta).to.equal(0)
			expect(result.Guard).to.equal(GUARD_MAX)
		end)

		it("resolves a flank hit clean even while blocking", function()
			-- Outside the arc but not behind: unblocked, but not a backstab. You were not covering
			-- that side.
			local result = OutcomeResolver.Resolve(makeInput({
				DefenderState = "Blocking",
				BlockHeld = true,
				BearingDegrees = ARC_HALF + 5,
			}))
			expect(result.Kind).to.equal("Clean")
		end)

		it("resolves a rear hit on an UNGUARDED defender clean, not as a backstab", function()
			-- A backstab punishes a false sense of security. There is none to punish if they never
			-- raised anything.
			local result = OutcomeResolver.Resolve(makeInput({ BearingDegrees = 180 }))
			expect(result.Kind).to.equal("Clean")
		end)
	end)

	describe("OutcomeResolver.Resolve -- blocking", function()
		it("drains guard scaled by PowerLevel", function()
			local light =
				OutcomeResolver.Resolve(makeInput({ DefenderState = "Blocking", BlockHeld = true, PowerLevel = 1 }))
			expect(light.Kind).to.equal("Blocked")
			expect(light.GuardDelta).to.be.near(-DefenseConstants.Guard.DrainPerPowerLevel, 1e-6)

			local heavy =
				OutcomeResolver.Resolve(makeInput({ DefenderState = "Blocking", BlockHeld = true, PowerLevel = 3 }))
			expect(heavy.GuardDelta).to.be.near(-DefenseConstants.Guard.DrainPerPowerLevel * 3, 1e-6)
		end)

		it("blocks anywhere inside the arc and not one degree outside it", function()
			local inside = OutcomeResolver.Resolve(makeInput({
				DefenderState = "Blocking",
				BlockHeld = true,
				BearingDegrees = ARC_HALF,
			}))
			expect(inside.Kind).to.equal("Blocked")

			local outside = OutcomeResolver.Resolve(makeInput({
				DefenderState = "Blocking",
				BlockHeld = true,
				BearingDegrees = ARC_HALF + 0.001,
			}))
			expect(outside.Kind).to.equal("Clean")
		end)

		it("breaks the guard when the drain meets what is left", function()
			local result = OutcomeResolver.Resolve(makeInput({
				DefenderState = "Blocking",
				BlockHeld = true,
				Guard = DefenseConstants.Guard.DrainPerPowerLevel,
			}))
			-- Met, not merely exceeded -- otherwise the break depends on floating-point luck.
			expect(result.Kind).to.equal("GuardBroken")
			expect(result.Guard).to.equal(0)
		end)

		it("charges a staggered block more, which is what keeps the punish real", function()
			local ordinary = OutcomeResolver.Resolve(makeInput({ DefenderState = "Blocking", BlockHeld = true }))
			local staggered = OutcomeResolver.Resolve(makeInput({ DefenderState = "Staggered", BlockHeld = true }))
			expect(staggered.Kind).to.equal("Blocked")
			expect(staggered.GuardDelta).to.be.near(
				ordinary.GuardDelta * DefenseConstants.Stagger.GuardDrainMultiplier,
				1e-6
			)
		end)

		it("gives a broken guard nothing for holding the key", function()
			local result = OutcomeResolver.Resolve(makeInput({ DefenderState = "GuardBroken", BlockHeld = true }))
			expect(result.Kind).to.equal("Clean")
			expect(result.GuardDelta).to.equal(0)
		end)
	end)

	describe("OutcomeResolver.Resolve -- backstab", function()
		it("beats a block", function()
			local result = OutcomeResolver.Resolve(makeInput({
				DefenderState = "Blocking",
				BlockHeld = true,
				BearingDegrees = 180,
			}))
			expect(result.Kind).to.equal("Backstab")
			expect(result.GuardDelta).to.equal(0)
		end)

		it("beats a parry too", function()
			-- A parry from behind is not a parry.
			local result = OutcomeResolver.Resolve(makeInput({
				DefenderState = "ParryWindow",
				ParryLive = true,
				BearingDegrees = 120,
			}))
			expect(result.Kind).to.equal("Backstab")
			expect(result.ConsumesParry).to.equal(false)
		end)

		it("starts exactly at the rear hemisphere", function()
			local justInside = OutcomeResolver.Resolve(makeInput({
				DefenderState = "Blocking",
				BlockHeld = true,
				BearingDegrees = DefenseConstants.RearHemisphereDegrees,
			}))
			expect(justInside.Kind).to.equal("Backstab")

			local justOutside = OutcomeResolver.Resolve(makeInput({
				DefenderState = "Blocking",
				BlockHeld = true,
				BearingDegrees = DefenseConstants.RearHemisphereDegrees - 0.001,
			}))
			-- Still outside the block arc, so clean rather than blocked -- but not a backstab.
			expect(justOutside.Kind).to.equal("Clean")
		end)
	end)

	describe("OutcomeResolver.Resolve -- parrying", function()
		it("parries inside the window and restores guard", function()
			local result = OutcomeResolver.Resolve(makeInput({
				DefenderState = "ParryWindow",
				ParryLive = true,
				Guard = 40,
			}))
			expect(result.Kind).to.equal("Parried")
			expect(result.ConsumesParry).to.equal(true)
			expect(result.GuardDelta).to.equal(DefenseConstants.Guard.ParryRestore)
		end)

		it("clamps the restore at the ceiling and reports what was actually granted", function()
			local result = OutcomeResolver.Resolve(makeInput({
				DefenderState = "ParryWindow",
				ParryLive = true,
				Guard = GUARD_MAX - 5,
			}))
			expect(result.Guard).to.equal(GUARD_MAX)
			expect(result.GuardDelta).to.equal(5)
		end)

		it("stops exactly one attack -- a second contact in the same batch lands clean", function()
			-- The window consumes on the first contact, which is what makes being surrounded
			-- genuinely dangerous rather than merely inconvenient. And ParryWindow does not
			-- mitigate, so the second hit is Clean rather than Blocked.
			local result = OutcomeResolver.Resolve(makeInput({
				DefenderState = "ParryWindow",
				ParryLive = true,
				ParryConsumed = true,
			}))
			expect(result.Kind).to.equal("Clean")
		end)
	end)

	describe("OutcomeResolver.ArbitrateTrades", function()
		local alpha = Instance.new("Model")
		local beta = Instance.new("Model")
		local gamma = Instance.new("Model")

		local function makeContact(attacker: Model, defender: Model, kind: string, guardDelta: number): any
			return {
				Report = nil :: any,
				Attacker = attacker,
				Defender = defender,
				BearingDegrees = 0,
				DefenderStateAtContact = "ParryWindow",
				Result = {
					Kind = kind,
					Guard = 40 + guardDelta,
					GuardDelta = guardDelta,
					ConsumesParry = kind == "Parried",
				},
				SampleTime = 0,
			}
		end

		it("collapses a mutual parry into a Trade on both sides", function()
			local contacts = {
				makeContact(alpha, beta, "Parried", DefenseConstants.Guard.ParryRestore),
				makeContact(beta, alpha, "Parried", DefenseConstants.Guard.ParryRestore),
			}
			expect(OutcomeResolver.ArbitrateTrades(contacts)).to.equal(2)
			expect(contacts[1].Result.Kind).to.equal("Trade")
			expect(contacts[2].Result.Kind).to.equal("Trade")
		end)

		it("grants no guard to either side of a trade", function()
			local contacts = {
				makeContact(alpha, beta, "Parried", DefenseConstants.Guard.ParryRestore),
				makeContact(beta, alpha, "Parried", DefenseConstants.Guard.ParryRestore),
			}
			OutcomeResolver.ArbitrateTrades(contacts)
			-- Resetting to a "neutral value" instead would let two players with depleted guards farm
			-- each other to refill. A trade must cost a swing each and change no resource.
			expect(contacts[1].Result.GuardDelta).to.equal(0)
			expect(contacts[2].Result.GuardDelta).to.equal(0)
			expect(contacts[1].Result.Guard).to.equal(40)
			expect(contacts[2].Result.Guard).to.equal(40)
		end)

		it("leaves two parries that are not mutual alone", function()
			local contacts = {
				makeContact(alpha, beta, "Parried", 10),
				makeContact(gamma, beta, "Parried", 10),
			}
			expect(OutcomeResolver.ArbitrateTrades(contacts)).to.equal(0)
			expect(contacts[1].Result.Kind).to.equal("Parried")
		end)

		it("leaves a parry paired with a mere block alone", function()
			local contacts = {
				makeContact(alpha, beta, "Parried", 10),
				makeContact(beta, alpha, "Blocked", -18),
			}
			expect(OutcomeResolver.ArbitrateTrades(contacts)).to.equal(0)
			expect(contacts[1].Result.Kind).to.equal("Parried")
			expect(contacts[2].Result.Kind).to.equal("Blocked")
		end)
	end)
end
