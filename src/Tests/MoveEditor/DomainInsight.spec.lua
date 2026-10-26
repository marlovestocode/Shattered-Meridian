--!strict
-- Covers MoveEditor/DomainInsight.lua -- what the Realm tab tells an author: the lifecycle, pulse counts, the
-- composed law, matchups, the checks, the archetypes and the list edits. Each read-out is held to the runtime
-- function it claims to mirror (DomainRules.Apply, DomainClash.Resolve, DomainTypes.Validate).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

local DomainClash = require(ReplicatedStorage.Shared.Domain.DomainClash)
local DomainConstants = require(ReplicatedStorage.Shared.Domain.DomainConstants)
local DomainTypes = require(ReplicatedStorage.Shared.Domain.DomainTypes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local ProjectileTypes = require(ReplicatedStorage.Shared.HitboxEngine.ProjectileTypes)
local MoveRegistryManager = require(ServerScriptService.Server.Combat.MoveRegistryManager)

local DomainInsight = require(StarterPlayer.StarterPlayerScripts.Client.UI.Screens.DevTools.MoveEditor.DomainInsight)

type Move = MoveTypes.MoveDefinition

local function move(overrides: { [string]: any }?): Move
	local candidate: { [string]: any } = {
		MoveId = "spec-realm",
		DisplayName = "Spec Realm",
		Author = "Spec",
		CreatedAt = 1,
		UpdatedAt = 1,
		Shape = "Box",
		Dimensions = { Width = 4, Height = 5, Length = 5 },
		OffsetX = 0,
		OffsetY = 0,
		OffsetZ = -3,
		WindupSeconds = 0.4,
		ActiveSeconds = 0.2,
		RecoverySeconds = 0.3,
		Cooldown = 40,
		Damage = 10,
		PostureDamage = 8,
		Domain = DomainTypes.Defaults(),
	}
	for key, value in pairs(overrides or {}) do
		candidate[key] = value
	end
	-- A nil in an overrides table literal is no key at all, so "not a realm" is asked for by name.
	if candidate.NoDomain then
		candidate.Domain = nil
		candidate.NoDomain = nil
	end
	return MoveRegistryManager.Validate(candidate) :: Move
end

local function texts(found: { DomainInsight.Diagnostic }, severity: string?): { string }
	local out: { string } = {}
	for _, diagnostic in found do
		if severity == nil or diagnostic.Severity == severity then
			table.insert(out, diagnostic.Text)
		end
	end
	return out
end

local function mentions(found: { DomainInsight.Diagnostic }, fragment: string, severity: string?): boolean
	for _, text in texts(found, severity) do
		if string.find(text, fragment, 1, true) then
			return true
		end
	end
	return false
end

return function()
	describe("DomainInsight.Lifecycle", function()
		it("lays the cast end to end from the authored windup", function()
			local subject = move()
			local domain = subject.Domain :: DomainTypes.DomainSpec
			local life = DomainInsight.Lifecycle(subject) :: DomainInsight.Lifecycle
			expect(life.Windup).to.equal(0.4)
			expect(life.Total).to.be.near(0.4 + DomainTypes.TotalSeconds(domain), 1e-6)
			expect(life.CancelAfter).to.be.near(
				DomainConstants.Cancel.WindowFraction * (domain.ActivationSeconds + domain.ActiveSeconds),
				1e-6
			)
			expect(life.Effective).to.equal(false)
		end)

		it("takes the clip's windup and cooldown when the server has them", function()
			local life =
				DomainInsight.Lifecycle(move(), { WindupSeconds = 0.9, Cooldown = 55 }) :: DomainInsight.Lifecycle
			expect(life.Windup).to.equal(0.9)
			expect(life.Cooldown).to.equal(55)
			expect(life.Effective).to.equal(true)
		end)

		it("charges upkeep only over the hold", function()
			local domain = DomainTypes.Defaults()
			domain.UpkeepQiPerSecond = 3
			domain.ActiveSeconds = 10
			local life = DomainInsight.Lifecycle(move({ Domain = domain })) :: DomainInsight.Lifecycle
			expect(life.UpkeepTotal).to.be.near(30, 1e-6)
		end)

		it("has nothing to say about a move with no realm", function()
			expect(DomainInsight.Lifecycle(move({ NoDomain = true }))).to.equal(nil)
		end)
	end)

	describe("DomainInsight.Pulses", function()
		it("counts the first pulse and every interval after it inside the hold", function()
			local domain = DomainTypes.Defaults()
			domain.ActiveSeconds = 12
			local effect = DomainTypes.DefaultEffect()
			effect.FirstDelaySeconds = 0.5
			effect.IntervalSeconds = 2
			expect(DomainInsight.Pulses(effect, domain)).to.equal(6)
		end)

		it("is zero for an effect whose first pulse is after the hold", function()
			local domain = DomainTypes.Defaults()
			domain.ActiveSeconds = 3
			local effect = DomainTypes.DefaultEffect()
			effect.FirstDelaySeconds = 4
			expect(DomainInsight.Pulses(effect, domain)).to.equal(0)
		end)
	end)

	describe("DomainInsight.Law", function()
		it("multiplies stacked scales and ORs flags, as DomainRules.Apply does", function()
			local domain = DomainTypes.Defaults()
			local a = DomainInsight.NewRule("DamageTaken")
			a.Value = 1.5
			local b = DomainInsight.NewRule("DamageTaken")
			b.Value = 2
			local seal = DomainInsight.NewRule("NoParry")
			domain.Rules = { a, b, seal }
			local law = DomainInsight.Law(domain)
			expect(#law).to.equal(1)
			expect(law[1].Name).to.equal("Enemies")
			expect(table.find(law[1].Clauses, "take 3x damage")).to.be.ok()
			expect(table.find(law[1].Clauses, "cannot parry")).to.be.ok()
		end)

		it("splits enemies into players and bots only when a rule's target types differ", function()
			local domain = DomainTypes.Defaults()
			local slow = DomainInsight.NewRule("MoveSpeed")
			slow.Value = 0.5
			slow.TargetTypes = "Players"
			domain.Rules = { slow }
			local law = DomainInsight.Law(domain)
			expect(#law).to.equal(1)
			expect(law[1].Name).to.equal("Enemy players")
		end)

		it("reaches the owner through Everyone and OwnerAndAllies, never through Enemies", function()
			local domain = DomainTypes.Defaults()
			local quick = DomainInsight.NewRule("MoveSpeed")
			quick.Value = 1.2
			quick.Affects = "OwnerAndAllies"
			domain.Rules = { quick }
			local names = {}
			for _, audience in DomainInsight.Law(domain) do
				table.insert(names, audience.Name)
			end
			expect(table.find(names, "The owner")).to.be.ok()
			expect(table.find(names, "Allies")).to.be.ok()
			expect(table.find(names, "Enemies")).to.equal(nil)
		end)

		it("leaves out a rule that multiplies by one", function()
			local domain = DomainTypes.Defaults()
			local idle = DomainInsight.NewRule("DamageDealt")
			idle.Value = 1
			domain.Rules = { idle }
			expect(#DomainInsight.Law(domain)).to.equal(0)
		end)
	end)

	describe("DomainInsight.Matchup", function()
		it("agrees with DomainClash.Resolve in both opening orders", function()
			local mine = DomainTypes.Defaults()
			mine.Priority = 10
			mine.TieBreak = "Newer"
			mine.ClashBehavior = "Dominate"
			local theirs = DomainTypes.Defaults()
			theirs.Priority = 10
			theirs.TieBreak = "Older"
			local matchup = DomainInsight.Matchup("mine-move", mine, "their-move", theirs)
			-- Mine opens later and its tie-break claims: mine wins and dominates.
			expect(matchup.MineOpensLater).to.equal("Theirs collapses")
			-- Theirs opens later and its tie-break yields to the incumbent (mine): mine still wins.
			expect(matchup.TheirsOpensLater).to.equal("Theirs collapses")
		end)

		it("reads a per-opponent override the way the runtime does", function()
			local mine = DomainTypes.Defaults()
			mine.Priority = 50
			local override = DomainTypes.DefaultClashOverride()
			override.OpponentMoveId = "their-move"
			override.Behavior = "Coexist"
			mine.ClashOverrides = { override }
			local theirs = DomainTypes.Defaults()
			local matchup = DomainInsight.Matchup("mine-move", mine, "their-move", theirs)
			expect(string.find(matchup.MineOpensLater, "Coexist", 1, true)).to.be.ok()
			local outcome = DomainClash.Resolve({
				Id = "a",
				MoveId = "mine-move",
				Priority = 50,
				Behavior = "Suppress",
				Overrides = { ["their-move"] = "Coexist" },
				TieBreak = "Contest",
				Interacts = true,
				OpenedAt = 1,
			}, {
				Id = "b",
				MoveId = "their-move",
				Priority = 10,
				Behavior = "Suppress",
				Overrides = {},
				TieBreak = "Contest",
				Interacts = true,
				OpenedAt = 0,
			})
			expect(outcome.Behavior).to.equal("Coexist")
		end)

		it("reports a contest at both realms' contest strengths", function()
			local mine = DomainTypes.Defaults()
			mine.ContestScale = 0.25
			local theirs = DomainTypes.Defaults()
			theirs.ContestScale = 0.75
			local matchup = DomainInsight.Matchup("a", mine, "b", theirs)
			expect(string.find(matchup.MineOpensLater, "yours holds at 25%, theirs at 75%", 1, true)).to.be.ok()
		end)
	end)

	describe("DomainInsight.Diagnostics", function()
		it("finds no error or warning in a realm with an own strike", function()
			local domain = DomainTypes.Defaults()
			domain.Effects = { DomainTypes.DefaultEffect() }
			local found = DomainInsight.Diagnostics(move({ Domain = domain }), {})
			expect(#texts(found, "Error")).to.equal(0)
			expect(#texts(found, "Warning")).to.equal(0)
		end)

		it("warns about a realm that does nothing", function()
			local found = DomainInsight.Diagnostics(move(), {})
			expect(mentions(found, "does nothing", "Warning")).to.equal(true)
		end)

		it("errors on the refusals Save would meet, before Save meets them", function()
			local subject = move()
			local domain = subject.Domain :: DomainTypes.DomainSpec
			local volley = DomainInsight.NewEffect("Volley")
			local seal = DomainInsight.NewRule("SealMove")
			local override = DomainTypes.DefaultClashOverride()
			domain.Effects = { volley }
			domain.Rules = { seal }
			domain.ClashOverrides = { override }
			local found = DomainInsight.Diagnostics(subject, {})
			expect(#texts(found, "Error")).to.equal(3)
			-- And Validate refuses the same draft.
			local _, reason = DomainTypes.Validate(DomainTypes.Copy(domain), subject.MoveId)
			expect(reason).to.be.ok()
			-- Errors are listed first.
			expect(found[1].Severity).to.equal("Error")
		end)

		it("follows references through the move list", function()
			local melee = move({ MoveId = "spec-melee", DisplayName = "Melee", NoDomain = true })
			local other = move({ MoveId = "spec-other", DisplayName = "Other" })
			local subject = move()
			local domain = subject.Domain :: DomainTypes.DomainSpec
			local volley = DomainInsight.NewEffect("Volley")
			volley.MoveId = "spec-melee"
			local missing = DomainInsight.NewEffect("OwnerCast")
			missing.MoveId = "spec-gone"
			local cast = DomainInsight.NewEffect("OwnerCast")
			cast.MoveId = "spec-other"
			domain.Effects = { volley, missing, cast }
			local notRealm = DomainTypes.DefaultClashOverride()
			notRealm.OpponentMoveId = "spec-melee"
			domain.ClashOverrides = { notRealm }
			local moves = DomainInsight.MovesById({ { Move = melee }, { Move = other }, { Move = subject } })
			local found = DomainInsight.Diagnostics(subject, moves)
			expect(mentions(found, "not a projectile move", "Warning")).to.equal(true)
			expect(mentions(found, "no longer exists", "Warning")).to.equal(true)
			expect(mentions(found, "another realm", "Warning")).to.equal(true)
			expect(mentions(found, "not a realm", "Warning")).to.equal(true)
		end)

		it("skips reference checks while the move list is empty", function()
			local subject = move()
			local domain = subject.Domain :: DomainTypes.DomainSpec
			local cast = DomainInsight.NewEffect("OwnerCast")
			cast.MoveId = "anything"
			domain.Effects = { cast }
			expect(mentions(DomainInsight.Diagnostics(subject, {}), "no longer exists")).to.equal(false)
		end)

		it("flags values the runtime caps or ignores", function()
			local subject = move()
			local domain = subject.Domain :: DomainTypes.DomainSpec
			local stun = DomainInsight.NewEffect("Hitstun")
			stun.Magnitude = 5
			local late = DomainInsight.NewEffect("GuardDrain")
			late.FirstDelaySeconds = domain.ActiveSeconds + 1
			local ownStrike = DomainInsight.NewEffect("Strike")
			ownStrike.Affects = "Owner"
			domain.Effects = { stun, late, ownStrike }
			local flat = DomainInsight.NewRule("Cooldown")
			flat.Value = 1
			domain.Rules = { flat }
			domain.Anchor = "FollowOwner"
			domain.BoundaryCollision = true
			local found = DomainInsight.Diagnostics(subject, {})
			expect(mentions(found, "capped", "Warning")).to.equal(true)
			expect(mentions(found, "never fires", "Warning")).to.equal(true)
			expect(mentions(found, "never hit their own owner", "Warning")).to.equal(true)
			expect(mentions(found, "changes nothing", "Warning")).to.equal(true)
			expect(mentions(found, "never walled", "Note")).to.equal(true)
		end)

		it("warns when the owner opens a collapse-on-leave realm from outside it", function()
			local subject = move()
			local domain = subject.Domain :: DomainTypes.DomainSpec
			domain.Effects = { DomainTypes.DefaultEffect() }
			domain.Radius = 10
			domain.CenterForward = 30
			domain.CancelOnOwnerExit = true
			expect(mentions(DomainInsight.Diagnostics(subject, {}), "standing outside it", "Warning")).to.equal(true)
		end)

		it("warns when strikes outrun the realm's shot budget", function()
			local subject = move()
			local domain = subject.Domain :: DomainTypes.DomainSpec
			local barrage = DomainInsight.NewEffect("Strike")
			barrage.IntervalSeconds = 0.25
			barrage.MaxPerPulse = 32
			domain.Effects = { barrage }
			expect(DomainInsight.ShotDemand(domain) > DomainConstants.Strike.MaxShotsPerSecond).to.equal(true)
			expect(mentions(DomainInsight.Diagnostics(subject, {}), "shots/s", "Warning")).to.equal(true)
		end)

		it("counts a volley's shots from the projectile move it names", function()
			local shot = ProjectileTypes.Defaults()
			shot.SpreadPattern = "Fan"
			shot.Count = 5
			local thrower = move({ MoveId = "spec-shot", Projectile = shot, NoDomain = true })
			local domain = DomainTypes.Defaults()
			domain.MaxTargets = 2
			local volley = DomainInsight.NewEffect("Volley")
			volley.MoveId = "spec-shot"
			volley.IntervalSeconds = 1
			domain.Effects = { volley }
			local moves = DomainInsight.MovesById({ { Move = thrower } })
			expect(DomainInsight.ShotDemand(domain, moves)).to.be.near(10, 1e-6)
		end)
	end)

	describe("DomainInsight list edits", function()
		it("shifts an entry and refuses past either end", function()
			local list = { "a", "b", "c" }
			expect(DomainInsight.Shift(list, 1, -1)).to.equal(false)
			expect(DomainInsight.Shift(list, 1, 1)).to.equal(true)
			expect(table.concat(list)).to.equal("bac")
			expect(DomainInsight.Shift(list, 3, 1)).to.equal(false)
		end)

		it("duplicates through the schema's field list, and not past the cap", function()
			local list = { DomainInsight.NewEffect("Pull") }
			(list[1] :: any).Stray = true
			expect(DomainInsight.DuplicateAt(list, 1, 2, DomainTypes.EffectFields)).to.equal(true)
			expect(#list).to.equal(2)
			expect(list[2].Kind).to.equal("Pull")
			expect(list[2]).never.to.equal(list[1])
			expect((list[2] :: any).Stray).to.equal(nil)
			expect(DomainInsight.DuplicateAt(list, 1, 2, DomainTypes.EffectFields)).to.equal(false)
		end)

		it("starts each new effect kind at a magnitude inside its editor range", function()
			for _, kind in DomainTypes.EffectKinds do
				local effect = DomainInsight.NewEffect(kind)
				if kind == "Hitstun" then
					expect(effect.Magnitude <= DomainConstants.MaxHitstunSeconds).to.equal(true)
				elseif kind == "Pull" or kind == "Push" then
					expect(effect.Magnitude <= DomainConstants.ImpulseMaxSpeed).to.equal(true)
				end
			end
		end)
	end)

	describe("DomainInsight.Archetypes", function()
		it("each leaves a realm Validate accepts, with no errors, and keeps the clash overrides", function()
			for _, archetype in DomainInsight.Archetypes do
				local domain = DomainTypes.Defaults()
				local override = DomainTypes.DefaultClashOverride()
				override.OpponentMoveId = "kept-opponent"
				domain.ClashOverrides = { override }
				archetype.Apply(domain)
				local validated, reason = DomainTypes.Validate(DomainTypes.Copy(domain), "spec-realm")
				expect(reason).to.equal(nil)
				expect(validated).to.be.ok()
				expect(#domain.ClashOverrides).to.equal(1)
				expect(domain.ClashOverrides[1].OpponentMoveId).to.equal("kept-opponent")
				local found = DomainInsight.Diagnostics(move({ Domain = domain }), {})
				expect(#texts(found, "Error")).to.equal(0)
				expect(#texts(found, "Warning")).to.equal(0)
			end
		end)

		it("replaces the realm wholesale rather than layering onto it", function()
			local domain = DomainTypes.Defaults()
			domain.Effects = { DomainInsight.NewEffect("Pull"), DomainInsight.NewEffect("Push") }
			domain.Radius = 99
			(DomainInsight.ArchetypeById("Pressure") :: DomainInsight.Archetype).Apply(domain)
			expect(domain.Radius).to.equal(DomainTypes.Defaults().Radius)
			for _, effect in domain.Effects do
				expect(effect.Kind ~= "Pull" and effect.Kind ~= "Push").to.equal(true)
			end
		end)
	end)
end
