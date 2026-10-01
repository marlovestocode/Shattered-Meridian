--!strict
-- Covers Shared/Domain/DomainTypes.lua -- the realm schema: defaults, the field-exact copy, and the
-- strict-identity / lenient-number gate every untrusted block goes through.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DomainTypes = require(ReplicatedStorage.Shared.Domain.DomainTypes)

local function withEffect(overrides: { [string]: any }): { [string]: any }
	local spec = DomainTypes.Defaults() :: any
	local effect = DomainTypes.DefaultEffect() :: any
	effect.MoveId = "spec-strike"
	for key, value in overrides do
		effect[key] = value
	end
	spec.Effects = { effect }
	return spec
end

return function()
	describe("DomainTypes.Defaults", function()
		it("validates as-is and names a working realm", function()
			local spec, reason = DomainTypes.Validate(DomainTypes.Defaults())
			expect(reason).to.equal(nil)
			expect(spec).to.be.ok()
			local validated = spec :: DomainTypes.DomainSpec
			expect(validated.ActiveSeconds > 0).to.equal(true)
			expect(validated.Radius >= DomainTypes.Limits.Radius.Min).to.equal(true)
			expect(#validated.Effects).to.equal(0)
		end)

		it("keeps every default inside its own authorable bounds", function()
			for _, field in DomainTypes.Fields do
				local range = DomainTypes.Limits[field.Name]
				if field.Kind == "Number" then
					expect(field.Default >= range.Min and field.Default <= range.Max).to.equal(true)
				end
			end
			for _, field in DomainTypes.EffectFields do
				local range = DomainTypes.Limits[field.Name]
				if field.Kind == "Number" then
					expect(field.Default >= range.Min and field.Default <= range.Max).to.equal(true)
				end
			end
		end)
	end)

	describe("DomainTypes.Copy", function()
		it("copies exactly the schema's fields and nothing riding along", function()
			local spec = withEffect({}) :: any
			spec.Junk = "not a field"
			spec.Effects[1].AlsoJunk = true
			local copy = DomainTypes.Copy(spec) :: any
			expect(copy.Junk).to.equal(nil)
			expect(copy.Effects[1].AlsoJunk).to.equal(nil)
			expect(copy.Effects[1].MoveId).to.equal("spec-strike")
			expect(copy.Effects).never.to.equal(spec.Effects)
		end)
	end)

	describe("DomainTypes.Validate", function()
		it("refuses an option that does not exist", function()
			local spec = DomainTypes.Defaults() :: any
			spec.Shape = "Torus"
			local validated, reason = DomainTypes.Validate(spec)
			expect(validated).to.equal(nil)
			expect(reason).to.equal("InvalidDomain")
		end)

		it("clamps an out-of-range number rather than refusing it", function()
			local spec = DomainTypes.Defaults() :: any
			spec.Radius = 100000
			spec.ActiveSeconds = -4
			local validated = DomainTypes.Validate(spec) :: DomainTypes.DomainSpec
			expect(validated.Radius).to.equal(DomainTypes.Limits.Radius.Max)
			expect(validated.ActiveSeconds).to.equal(DomainTypes.Limits.ActiveSeconds.Min)
		end)

		it("fills an absent field with its default so older records keep loading", function()
			local validated = DomainTypes.Validate({}) :: DomainTypes.DomainSpec
			expect(validated.Shape).to.equal("Sphere")
			expect(validated.ClashBehavior).to.equal("Suppress")
			expect(#validated.Rules).to.equal(0)
		end)

		it("refuses a delivering effect that names no move", function()
			local _, reason = DomainTypes.Validate(withEffect({ MoveId = "" }))
			expect(reason).to.equal("DomainEffectNeedsMove")
		end)

		it("does not require a move for a kind that delivers none", function()
			local validated, reason = DomainTypes.Validate(withEffect({ Kind = "Hitstun", MoveId = "" }))
			expect(reason).to.equal(nil)
			expect((validated :: DomainTypes.DomainSpec).Effects[1].Kind).to.equal("Hitstun")
		end)

		it("refuses an effect that delivers the realm's own move", function()
			local _, reason = DomainTypes.Validate(withEffect({ MoveId = "my-realm-1234" }), "my-realm-1234")
			expect(reason).to.equal("DomainSelfReference")
		end)

		it("refuses a move id with characters no id can have", function()
			local _, reason = DomainTypes.Validate(withEffect({ MoveId = "../../evil" }))
			expect(reason).to.equal("InvalidDomainEffect")
		end)

		it("drops list entries past the cap rather than refusing the block", function()
			local spec = DomainTypes.Defaults() :: any
			for _ = 1, DomainTypes.MaxRules + 3 do
				table.insert(spec.Rules, DomainTypes.DefaultRule())
			end
			local validated = DomainTypes.Validate(spec) :: DomainTypes.DomainSpec
			expect(#validated.Rules).to.equal(DomainTypes.MaxRules)
		end)

		it("refuses a SealMove rule with no move to seal", function()
			local spec = DomainTypes.Defaults() :: any
			local rule = DomainTypes.DefaultRule() :: any
			rule.Kind = "SealMove"
			spec.Rules = { rule }
			local _, reason = DomainTypes.Validate(spec)
			expect(reason).to.equal("DomainRuleNeedsMove")
		end)

		it("rounds an integer field", function()
			local spec = DomainTypes.Defaults() :: any
			spec.MaxTargets = 3.6
			expect((DomainTypes.Validate(spec) :: DomainTypes.DomainSpec).MaxTargets).to.equal(4)
		end)
	end)

	describe("DomainTypes.BehaviorToward", function()
		it("answers the per-opponent override before the default", function()
			local spec = DomainTypes.Defaults()
			spec.ClashBehavior = "Suppress"
			spec.ClashOverrides = { { OpponentMoveId = "rival-realm", Behavior = "Dominate" } }
			expect(DomainTypes.BehaviorToward(spec, "rival-realm")).to.equal("Dominate")
			expect(DomainTypes.BehaviorToward(spec, "anyone-else")).to.equal("Suppress")
		end)
	end)
end
