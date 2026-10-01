--!strict
-- Covers Server/Combat/Domain/DomainSystem.lua -- the realm runtime, against real rigs and STUBBED ports
-- (DomainSystem.SetPortsForTesting): which entry point of which combat layer each effect reaches, with
-- what, is exactly what these cases assert. The strike's full trip through the real engine, defence and
-- damage layers is DomainStrike.spec's.
--
-- Clocks: the instance clock is `clock`, the shared server clock is `clock + SERVER_OFFSET`, so every
-- rule lease is read with an explicit server `now`. Init is never called (no remotes, no Heartbeat); time
-- moves only through Step. Every Step is a full membership tick (0.1s), so membership, clashes and the law
-- are re-evaluated on every call.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local DomainConstants = require(ReplicatedStorage.Shared.Domain.DomainConstants)
local DomainRules = require(ReplicatedStorage.Shared.Domain.DomainRules)
local DomainSystem = require(ServerScriptService.Server.Combat.Domain.DomainSystem)
local DomainTypes = require(ReplicatedStorage.Shared.Domain.DomainTypes)
local HitboxTypes = require(ReplicatedStorage.Shared.HitboxEngine.HitboxTypes)

local SERVER_OFFSET = 1000
local TICK = 0.1

type Rig = { Model: Model, Root: BasePart, Humanoid: Humanoid }

local spawned: { Instance } = {}
local clock = 0

local function makeRig(name: string, position: Vector3): Rig
	local model = Instance.new("Model")
	model.Name = name
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Anchored = true
	root.CanCollide = false
	root.CFrame = CFrame.new(position)
	root.Parent = model
	local humanoid = Instance.new("Humanoid")
	humanoid.RequiresNeck = false
	humanoid.Parent = model
	model.PrimaryPart = root
	model.Parent = Workspace
	table.insert(spawned, model)
	DomainSystem.TrackCombatantForTesting(model)
	return { Model = model, Root = root, Humanoid = humanoid }
end

local function spec(overrides: { [string]: any }?): DomainTypes.DomainSpec
	local result = DomainTypes.Defaults() :: any
	result.ActivationSeconds = 1
	result.ActiveSeconds = 5
	result.EndSeconds = 1
	result.Radius = 20
	result.EntryGraceSeconds = 0
	for key, value in overrides or {} do
		result[key] = value
	end
	return result
end

local function effect(overrides: { [string]: any }): DomainTypes.Effect
	local result = DomainTypes.DefaultEffect() :: any
	result.MoveId = "spec-strike"
	result.FirstDelaySeconds = 0
	result.IntervalSeconds = 1
	for key, value in overrides do
		result[key] = value
	end
	return result
end

local function rule(kind: string, value: number?, affects: string?): DomainTypes.Rule
	local result = DomainTypes.DefaultRule() :: any
	result.Kind = kind
	result.Value = value or 1
	result.Affects = affects or "Enemies"
	return result
end

-- Steps the runtime forward `seconds`, one membership tick at a time.
local function run(seconds: number): ()
	for _ = 1, math.max(1, math.round(seconds / TICK)) do
		clock += TICK
		DomainSystem.Step(TICK, clock)
	end
end

local function serverNow(): number
	return clock + SERVER_OFFSET
end

type Calls = { [string]: { { any } } }

local function stubPorts(overrides: { [string]: any }?): Calls
	local calls: Calls = {
		LaunchVolley = {},
		ExtendHitstun = {},
		DrainGuard = {},
		ThrowMove = {},
		Impulse = {},
		SetBarrier = {},
		SpendQi = {},
	}
	local definition = HitboxTypes.SanitizeDefinition({ DebugName = "spec-strike", Shape = "Sphere" })
	local ports: { [string]: any } = {
		CatalogGet = function(moveId: string)
			return { MoveId = moveId, Definition = definition, PowerLevel = 1 }
		end,
		LaunchVolley = function(...)
			table.insert(calls.LaunchVolley, { ... })
			return 1, 1
		end,
		ExtendHitstun = function(...)
			table.insert(calls.ExtendHitstun, { ... })
		end,
		DrainGuard = function(...)
			table.insert(calls.DrainGuard, { ... })
		end,
		ThrowMove = function(...)
			table.insert(calls.ThrowMove, { ... })
			return true, nil
		end,
		Impulse = function(...)
			table.insert(calls.Impulse, { ... })
		end,
		SpendQi = function(...)
			table.insert(calls.SpendQi, { ... })
			return true
		end,
		PlayerOf = function()
			return { Name = "SpecPlayer" } :: any
		end,
		IsHitstunned = function()
			return false
		end,
		InFlightStartedAt = function()
			return nil
		end,
		IsRegistered = function()
			return true
		end,
		SetBarrier = function(callback)
			table.insert(calls.SetBarrier, { callback })
		end,
		GetMove = function()
			return nil
		end,
	}
	for key, value in overrides or {} do
		ports[key] = value
	end
	DomainSystem.SetPortsForTesting(ports)
	return calls
end

local function open(owner: Rig, realmSpec: DomainTypes.DomainSpec, moveId: string?): string
	local id, reason = DomainSystem.Open(owner.Model, moveId or "spec-realm", realmSpec, clock)
	assert(id, `the spec's realm was refused: {reason}`)
	return id :: string
end

local function membersOf(id: string): { [Model]: boolean }
	local snapshot = DomainSystem.Get(id)
	local set: { [Model]: boolean } = {}
	if snapshot then
		for _, body in snapshot.Members do
			set[body] = true
		end
	end
	return set
end

return function()
	beforeEach(function()
		clock = 0
		DomainSystem.SetClocksForTesting(function()
			return clock
		end, function()
			return clock + SERVER_OFFSET
		end)
	end)

	afterEach(function()
		DomainSystem.Reset()
		for _, instance in spawned do
			instance:Destroy()
		end
		table.clear(spawned)
	end)

	describe("DomainSystem lifecycle", function()
		it("opens Activating, establishes on time, folds on time, and is gone after its fold", function()
			stubPorts()
			local owner = makeRig("Owner", Vector3.new(0, 5, 0))
			local seen: { string } = {}
			DomainSystem.OnPhaseChanged(function(_, transition)
				table.insert(seen, transition.To)
			end)
			local id = open(owner, spec())
			expect((DomainSystem.Get(id) :: any).Phase).to.equal("Activating")
			expect(DomainRules.OwnsLiveDomain(owner.Humanoid, serverNow())).to.equal(true)

			run(1.1)
			expect((DomainSystem.Get(id) :: any).Phase).to.equal("Active")
			run(5)
			expect((DomainSystem.Get(id) :: any).Phase).to.equal("Ending")
			run(1)
			expect(DomainSystem.Get(id)).to.equal(nil)
			expect(table.concat(seen, ",")).to.equal("Activating,Active,Ending,Finished")
			expect(DomainRules.OwnsLiveDomain(owner.Humanoid, serverNow())).to.equal(false)
		end)

		it("waits out the move's windup: the realm is the move's extension and opens when the windup ends", function()
			stubPorts({
				GetMove = function()
					return spec()
				end,
				InFlightStartedAt = function()
					return 0
				end,
			})
			DomainSystem.MarkDomainMoveForTesting("spec-realm")
			local owner = makeRig("Owner", Vector3.new(0, 5, 0))
			DomainSystem.NoteSwingAccepted(
				owner.Model,
				{ MoveId = "spec-realm", StartedAt = clock, WindupSeconds = 0.5 }
			)
			-- Accepted, not opened: nothing exists, nothing is unfurling, the owner holds no realm yet.
			expect(DomainSystem.LiveCount()).to.equal(0)
			expect(DomainRules.OwnsLiveDomain(owner.Humanoid, serverNow())).to.equal(false)

			run(0.3)
			expect(DomainSystem.LiveCount()).to.equal(0)

			run(0.3)
			expect(DomainSystem.LiveCount()).to.equal(1)
			local realm = DomainSystem.GetAll()[1]
			-- Its clock starts at the windup's SCHEDULED end (0.5s), not at acceptance (0) or the noticing frame (0.6).
			expect(realm.OpenedAt).to.be.near(0.5, 1e-6)
			expect(realm.Phase).to.equal("Activating")
		end)

		it("never opens when the swing is cut before its windup ends", function()
			local swingStartedAt: number? = 0
			stubPorts({
				GetMove = function()
					return spec()
				end,
				InFlightStartedAt = function()
					return swingStartedAt
				end,
			})
			DomainSystem.MarkDomainMoveForTesting("spec-realm")
			local owner = makeRig("Owner", Vector3.new(0, 5, 0))
			DomainSystem.NoteSwingAccepted(
				owner.Model,
				{ MoveId = "spec-realm", StartedAt = clock, WindupSeconds = 0.5 }
			)
			run(0.2)
			-- A feint, a parry or a stun: the attack layer no longer has that swing in flight.
			swingStartedAt = nil
			run(1)
			expect(DomainSystem.LiveCount()).to.equal(0)
		end)

		it("never opens for an owner who dies in the windup", function()
			stubPorts({
				GetMove = function()
					return spec()
				end,
				InFlightStartedAt = function()
					return 0
				end,
			})
			DomainSystem.MarkDomainMoveForTesting("spec-realm")
			local owner = makeRig("Owner", Vector3.new(0, 5, 0))
			DomainSystem.NoteSwingAccepted(
				owner.Model,
				{ MoveId = "spec-realm", StartedAt = clock, WindupSeconds = 0.5 }
			)
			owner.Humanoid.Health = 0
			run(1)
			expect(DomainSystem.LiveCount()).to.equal(0)
		end)

		it("refuses a second realm for an owner whose first is still up", function()
			stubPorts()
			local owner = makeRig("Owner", Vector3.new(0, 5, 0))
			open(owner, spec())
			local id, reason = DomainSystem.Open(owner.Model, "spec-realm", spec(), clock)
			expect(id).to.equal(nil)
			expect(reason).to.equal("DomainActive")
		end)

		it("never unfurls when the casting swing is cut in its windup", function()
			stubPorts({
				InFlightStartedAt = function()
					return nil
				end,
			})
			local owner = makeRig("Owner", Vector3.new(0, 5, 0))
			local id =
				DomainSystem.Open(owner.Model, "spec-realm", spec(), clock, { StartedAt = clock, WindupSeconds = 0.5 })
			run(TICK)
			local snapshot = DomainSystem.Get(id :: string) :: any
			expect(snapshot.Phase).to.equal("Ending")
			expect(snapshot.CollapseReason).to.equal("Interrupted")
		end)

		it("collapses when the owner is struck while unfurling, if it is authored to", function()
			local struck = false
			stubPorts({
				IsHitstunned = function()
					return struck
				end,
			})
			local owner = makeRig("Owner", Vector3.new(0, 5, 0))
			local id = open(owner, spec({ CancelOnOwnerHit = true }))
			run(0.3)
			expect((DomainSystem.Get(id) :: any).Phase).to.equal("Activating")
			struck = true
			run(TICK)
			expect((DomainSystem.Get(id) :: any).CollapseReason).to.equal("Interrupted")
		end)

		it("collapses when its owner dies", function()
			stubPorts()
			local owner = makeRig("Owner", Vector3.new(0, 5, 0))
			local id = open(owner, spec())
			run(1.2)
			owner.Humanoid.Health = 0
			run(TICK)
			expect((DomainSystem.Get(id) :: any).CollapseReason).to.equal("OwnerDied")
		end)
	end)

	describe("DomainSystem membership and law", function()
		it("admits whoever is inside when it is established, nearest first up to MaxTargets", function()
			stubPorts()
			local owner = makeRig("Owner", Vector3.new(0, 5, 0))
			local near = makeRig("Near", Vector3.new(5, 5, 0))
			local far = makeRig("Far", Vector3.new(15, 5, 0))
			local outside = makeRig("Outside", Vector3.new(60, 5, 0))
			local id = open(owner, spec({ MaxTargets = 2 }))
			run(1.1)
			local members = membersOf(id)
			expect(members[owner.Model]).to.equal(true)
			expect(members[near.Model]).to.equal(true)
			expect(members[far.Model]).to.equal(nil)
			expect(members[outside.Model]).to.equal(nil)
		end)

		it("lays its rules on the bodies they name and lifts them when it folds", function()
			stubPorts()
			local owner = makeRig("Owner", Vector3.new(0, 5, 0))
			local enemy = makeRig("Enemy", Vector3.new(5, 5, 0))
			local realmSpec = spec({
				Rules = {
					rule("DamageTaken", 1.5, "Enemies"),
					rule("DamageDealt", 2, "Owner"),
					rule("NoEvade", 1, "Enemies"),
				},
			})
			open(owner, realmSpec)
			run(1.2)
			expect(DomainRules.Scale(enemy.Humanoid, "DamageTaken", serverNow())).to.be.near(1.5, 1e-6)
			expect(DomainRules.Has(enemy.Humanoid, "NoEvade", serverNow())).to.equal(true)
			expect(DomainRules.Scale(owner.Humanoid, "DamageDealt", serverNow())).to.be.near(2, 1e-6)
			expect(DomainRules.Scale(owner.Humanoid, "DamageTaken", serverNow())).to.equal(1)

			run(5)
			expect(DomainRules.Scale(enemy.Humanoid, "DamageTaken", serverNow())).to.equal(1)
			expect(DomainRules.Has(enemy.Humanoid, "NoEvade", serverNow())).to.equal(false)
		end)

		it(
			"never rewrites a member's lease tick to tick, even when the two clocks jitter against each other",
			function()
				-- The FPS regression (2026-09-30): the lease was re-derived from two clocks every tick, came out a
				-- hair different each time, and replicated a fresh attribute write per member ten times a second.
				local jitter = Random.new(7)
				DomainSystem.SetClocksForTesting(function()
					return clock
				end, function()
					return clock + SERVER_OFFSET + jitter:NextNumber(-1e-4, 1e-4)
				end)
				stubPorts()
				local owner = makeRig("Owner", Vector3.new(0, 5, 0))
				local enemy = makeRig("Enemy", Vector3.new(5, 5, 0))
				open(owner, spec({ Rules = { rule("DamageTaken", 1.5) } }))
				run(1.2)
				local writes = 0
				local connection = enemy.Humanoid.AttributeChanged:Connect(function()
					writes += 1
				end)
				run(2)
				connection:Disconnect()
				expect(writes).to.equal(0)
			end
		)

		it("releases a member who walks out of an open exit, after its linger", function()
			stubPorts()
			local owner = makeRig("Owner", Vector3.new(0, 5, 0))
			local enemy = makeRig("Enemy", Vector3.new(5, 5, 0))
			local id = open(owner, spec({ ExitLingerSeconds = 0.5, Rules = { rule("MoveSpeed", 0.5) } }))
			run(1.2)
			enemy.Root.CFrame = CFrame.new(60, 5, 0)
			run(0.2)
			expect(membersOf(id)[enemy.Model]).to.equal(true)
			expect(DomainRules.Scale(enemy.Humanoid, "MoveSpeed", serverNow())).to.be.near(0.5, 1e-6)
			run(0.5)
			expect(membersOf(id)[enemy.Model]).to.equal(nil)
			expect(DomainRules.Scale(enemy.Humanoid, "MoveSpeed", serverNow())).to.equal(1)
		end)

		it("sets a held member back inside a barred exit", function()
			stubPorts()
			local owner = makeRig("Owner", Vector3.new(0, 5, 0))
			local enemy = makeRig("Enemy", Vector3.new(5, 5, 0))
			local id = open(owner, spec({ ExitRule = "Barred" }))
			run(1.2)
			enemy.Root.CFrame = CFrame.new(40, 5, 0)
			run(TICK)
			expect(enemy.Root.Position.X < 20).to.equal(true)
			expect(membersOf(id)[enemy.Model]).to.equal(true)
		end)

		it("repels a newcomer at a barred entry", function()
			stubPorts()
			local owner = makeRig("Owner", Vector3.new(0, 5, 0))
			local id = open(owner, spec({ EntryRule = "Barred" }))
			run(1.2)
			local newcomer = makeRig("Newcomer", Vector3.new(8, 5, 0))
			run(TICK)
			expect(newcomer.Root.Position.X > 20).to.equal(true)
			expect(membersOf(id)[newcomer.Model]).to.equal(nil)
		end)
	end)

	describe("DomainSystem effects", function()
		it("delivers a Strike to each enemy member on its interval, pinned to that body, as the realm", function()
			local calls = stubPorts()
			local owner = makeRig("Owner", Vector3.new(0, 5, 0))
			local enemy = makeRig("Enemy", Vector3.new(5, 5, 0))
			local id = open(owner, spec({ Effects = { effect({ Kind = "Strike", IntervalSeconds = 1 }) } }))
			run(1.05)
			expect(#calls.LaunchVolley).to.equal(1)
			local call = calls.LaunchVolley[1]
			expect(call[1]).to.equal(owner.Model)
			local options = call[6]
			expect(options.Target).to.equal(enemy.Model)
			expect(options.Exclusive).to.equal(true)
			expect(options.DomainId).to.equal(id)
			-- The synthesised strike is a single homing shot the realm's own barrier never stops.
			expect(call[2].Projectile.Homing).to.equal(true)
			expect(call[2].Projectile.CollisionBehavior).to.equal("Continue")

			run(2.2)
			expect(#calls.LaunchVolley).to.equal(3)
		end)

		it("spends a shot budget, so a realm at the schema's ceilings cannot flood strikes", function()
			local calls = stubPorts()
			local owner = makeRig("Owner", Vector3.new(0, 5, 0))
			for index = 1, 24 do
				local angle = index * 2 * math.pi / 24
				makeRig(`Enemy{index}`, Vector3.new(math.cos(angle) * 10, 5, math.sin(angle) * 10))
			end
			open(
				owner,
				spec({
					MaxTargets = 32,
					Effects = { effect({ Kind = "Strike", IntervalSeconds = 0.25, MaxPerPulse = 32 }) },
				})
			)
			local tuning = DomainConstants.Strike
			-- The first pulse spends the whole burst and stops there, 8 bodies short.
			run(1.05)
			expect(#calls.LaunchVolley).to.equal(tuning.BurstShots)
			-- After that the realm fires at the refill rate, however fast its pulses come.
			run(2)
			local total = #calls.LaunchVolley
			expect(total > tuning.BurstShots).to.equal(true)
			expect(total <= tuning.BurstShots + math.ceil(tuning.MaxShotsPerSecond * 2.1)).to.equal(true)
		end)

		it("books Qi upkeep in whole-second chunks, draining exactly rate x seconds", function()
			local calls = stubPorts()
			local owner = makeRig("Owner", Vector3.new(0, 5, 0))
			open(owner, spec({ UpkeepQiPerSecond = 2, ActiveSeconds = 6 }))
			run(1) -- Activating
			expect(#calls.SpendQi).to.equal(0)
			run(3.05)
			-- Three seconds Active at 2 Qi/s: three spends of 2, not thirty of 0.2.
			local total = 0
			for _, call in calls.SpendQi do
				total += call[2]
			end
			expect(#calls.SpendQi <= 4).to.equal(true)
			expect(total).to.be.near(2 * 3, 0.45)
		end)

		it("hands out a stun through the damage layer's own hitstun, capped", function()
			local calls = stubPorts()
			local owner = makeRig("Owner", Vector3.new(0, 5, 0))
			local enemy = makeRig("Enemy", Vector3.new(5, 5, 0))
			open(owner, spec({ Effects = { effect({ Kind = "Hitstun", MoveId = "", Magnitude = 50 }) } }))
			run(1.05)
			expect(#calls.ExtendHitstun).to.equal(1)
			local call = calls.ExtendHitstun[1]
			expect(call[1]).to.equal(enemy.Model)
			expect(call[2] - call[3]).to.be.near(1.5, 1e-6)
		end)

		it("does not target the owner with an Enemies effect, or anyone during the entry grace", function()
			local calls = stubPorts()
			local owner = makeRig("Owner", Vector3.new(0, 5, 0))
			open(owner, spec({ EntryGraceSeconds = 2, Effects = { effect({ Kind = "GuardDrain", MoveId = "" }) } }))
			run(1.2)
			local newcomer = makeRig("Newcomer", Vector3.new(4, 5, 0))
			run(1)
			expect(#calls.DrainGuard).to.equal(0)
			run(2.5)
			expect(#calls.DrainGuard > 0).to.equal(true)
			expect(calls.DrainGuard[1][1]).to.equal(newcomer.Model)
		end)

		it("has the owner cast through the attack layer on an OwnerCast pulse", function()
			local calls = stubPorts()
			local owner = makeRig("Owner", Vector3.new(0, 5, 0))
			open(owner, spec({ Effects = { effect({ Kind = "OwnerCast", MoveId = "spec-cast" }) } }))
			run(1.05)
			expect(#calls.ThrowMove).to.equal(1)
			expect(calls.ThrowMove[1][1]).to.equal(owner.Model)
			expect(calls.ThrowMove[1][2]).to.equal("spec-cast")
		end)
	end)

	describe("DomainSystem clashes", function()
		it("keeps a suppressed realm's law out of a body both realms hold", function()
			stubPorts()
			local strong = makeRig("Strong", Vector3.new(0, 5, 0))
			local weak = makeRig("Weak", Vector3.new(25, 5, 0))
			local between = makeRig("Between", Vector3.new(12, 5, 0))
			local strongId =
				open(strong, spec({ Priority = 50, Rules = { rule("DamageTaken", 2, "EveryoneButOwner") } }))
			local weakId = open(weak, spec({ Priority = 5, Rules = { rule("MoveSpeed", 0.5, "EveryoneButOwner") } }))
			run(1.2)
			expect(membersOf(strongId)[between.Model]).to.equal(true)
			expect(membersOf(weakId)[between.Model]).to.equal(true)
			expect(DomainRules.GovernorOf(between.Humanoid, serverNow())).to.equal(strongId)
			expect(DomainRules.Scale(between.Humanoid, "DamageTaken", serverNow())).to.be.near(2, 1e-6)
			expect(DomainRules.Scale(between.Humanoid, "MoveSpeed", serverNow())).to.equal(1)
			expect((DomainSystem.Get(weakId) :: any).ClashState).to.equal("Suppressed")
			expect((DomainSystem.Get(strongId) :: any).ClashState).to.equal("Dominant")
		end)

		it("collapses the weaker realm outright under Dominate", function()
			stubPorts()
			local strong = makeRig("Strong", Vector3.new(0, 5, 0))
			local weak = makeRig("Weak", Vector3.new(25, 5, 0))
			open(strong, spec({ Priority = 50, ClashBehavior = "Dominate" }))
			local weakId = open(weak, spec({ Priority = 5 }))
			run(1.2)
			expect((DomainSystem.Get(weakId) :: any).CollapseReason).to.equal("Dominated")
		end)

		it("wears the loser's time away under Erode", function()
			stubPorts()
			local strong = makeRig("Strong", Vector3.new(0, 5, 0))
			local weak = makeRig("Weak", Vector3.new(25, 5, 0))
			open(strong, spec({ Priority = 50, ClashBehavior = "Erode", ErodeRate = 2 }))
			local weakId = open(weak, spec({ Priority = 5 }))
			run(2)
			expect((DomainSystem.Get(weakId) :: any).Eroded > 1).to.equal(true)
			expect((DomainSystem.Get(weakId) :: any).ClashState).to.equal("Eroding")
		end)

		it("leaves realms that do not overlap alone", function()
			stubPorts()
			local a = makeRig("A", Vector3.new(0, 5, 0))
			local b = makeRig("B", Vector3.new(200, 5, 0))
			local aId = open(a, spec({ Priority = 50, ClashBehavior = "Dominate" }))
			local bId = open(b, spec({ Priority = 5 }))
			run(1.2)
			expect((DomainSystem.Get(aId) :: any).ClashState).to.equal("None")
			expect((DomainSystem.Get(bId) :: any).Phase).to.equal("Active")
		end)
	end)

	describe("DomainSystem projectile edge", function()
		it("holds the barrier slot only while a realm with a closed edge is established", function()
			local calls = stubPorts()
			local owner = makeRig("Owner", Vector3.new(0, 5, 0))
			open(owner, spec({ ProjectilesLeave = false }))
			run(1.1)
			expect(#calls.SetBarrier).to.equal(1)
			local barrier = calls.SetBarrier[1][1]
			expect(barrier).to.be.ok()
			-- Leaving from inside is refused; the realm's own strikes are not; entering is allowed.
			expect(barrier(owner.Model, nil, Vector3.new(0, 5, 0), Vector3.new(40, 5, 0))).to.equal(true)
			expect(barrier(owner.Model, "D1", Vector3.new(0, 5, 0), Vector3.new(40, 5, 0))).to.equal(false)
			expect(barrier(owner.Model, nil, Vector3.new(40, 5, 0), Vector3.new(0, 5, 0))).to.equal(false)
			run(5)
			expect(#calls.SetBarrier).to.equal(2)
			expect(calls.SetBarrier[2][1]).to.equal(nil)
		end)
	end)
end
