--!strict
-- Covers Server/Combat/CombatTrace.lua's descriptions -- what a Live Console line says about a contact and a hit.
-- The subscriptions themselves are one line each over the layers' own signals, which their own specs cover.

local ServerScriptService = game:GetService("ServerScriptService")

local CombatTrace = require(ServerScriptService.Server.Combat.CombatTrace)

local function model(name: string): Model
	local m = Instance.new("Model")
	m.Name = name
	return m
end

local function outcome(overrides: { [string]: any }): any
	local base: { [string]: any } = {
		Kind = "Clean",
		Report = { DebugName = "default:Fists:Basic:1", Source = "Melee" },
		Attacker = model("A"),
		Defender = model("D"),
		BearingDegrees = 3.4,
		DefenderStateAtContact = "Neutral",
		Guard = 100,
		GuardDelta = 0,
		SampleTime = 0,
	}
	for key, value in overrides do
		base[key] = value
	end
	return base
end

return function()
	describe("CombatTrace.DescribeContact", function()
		it("names who, what, from where, and what it became", function()
			local fields = CombatTrace.DescribeContact(outcome({}))
			expect(fields.attacker).to.equal("A")
			expect(fields.defender).to.equal("D")
			expect(fields.move).to.equal("default:Fists:Basic:1")
			expect(fields.source).to.equal("Melee")
			expect(fields.kind).to.equal("Clean")
			expect(fields.bearing).to.equal(3)
		end)

		it("explains a missed parry from the resolver's own inputs", function()
			-- The question this module exists for: the key went down, so why was it Clean? A spent window.
			local fields = CombatTrace.DescribeContact(outcome({
				DefenderStateAtContact = "ParryWindow",
				Inputs = {
					DefenderState = "ParryWindow",
					BearingDegrees = 0,
					PowerLevel = 1,
					Guard = 80,
					GuardMax = 100,
					BlockHeld = false,
					ParryLive = true,
					ParryConsumed = true,
				},
			}))
			expect(fields.stateAtContact).to.equal("ParryWindow")
			expect(fields.parryLive).to.equal(true)
			expect(fields.parrySpent).to.equal(true)
			expect(fields.guardBefore).to.equal(80)
		end)

		it("says when the guard was disabled", function()
			local fields = CombatTrace.DescribeContact(outcome({
				Inputs = {
					DefenderState = "Blocking",
					BearingDegrees = 0,
					PowerLevel = 1,
					Guard = 100,
					GuardMax = 100,
					BlockHeld = true,
					ParryLive = false,
					ParryConsumed = false,
					GuardDisabled = true,
				},
			}))
			expect(fields.guardDisabled).to.equal(true)
		end)
	end)

	describe("CombatTrace.DescribeApplied", function()
		it("reports damage, posture and stun, rounded", function()
			local fields = CombatTrace.DescribeApplied(outcome({}), {
				Kind = "Clean",
				Damage = 6.4999,
				GuardDrain = 10,
				HitstunSeconds = 0.5432,
				AdvancesCombo = true,
			})
			expect(fields.damage).to.equal(6.5)
			expect(fields.posture).to.equal(10)
			expect(fields.stun).to.equal(0.54)
		end)

		it("leaves stun out of a hit that stunned nothing", function()
			local fields =
				CombatTrace.DescribeApplied(outcome({ Report = { DebugName = "impact", Source = "Impact" } }), {
					Kind = "Clean",
					Damage = 15,
					GuardDrain = 0,
					HitstunSeconds = 0,
					AdvancesCombo = false,
				})
			expect(fields.stun).to.equal(nil)
			expect(fields.source).to.equal("Impact")
		end)
	end)
end
