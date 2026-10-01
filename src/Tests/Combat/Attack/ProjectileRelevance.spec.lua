--!strict
-- Covers Server/Combat/Attack/ProjectileRelevance.lua -- which client is sent which shot on
-- Attack_Projectile. Players are stand-in tables (Instance.new("Player") errors in the harness); the router
-- only ever uses them as keys. Positions are plain Vector3s; a homing target is a real Model with a
-- PrimaryPart, since that is what the router reads its position from.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AttackTypes = require(ReplicatedStorage.Shared.Attack.AttackTypes)
local ProjectileRelevance = require(ServerScriptService.Server.Combat.Attack.ProjectileRelevance)

type Event = AttackTypes.ProjectileWireEvent
type Viewer = ProjectileRelevance.Viewer

local RADIUS = 100

local spawned: { Instance } = {}

local function fakePlayer(name: string): Player
	return { Name = name } :: any
end

local function viewer(player: Player, position: Vector3?, character: Model?): Viewer
	return { Player = player, Character = character, Position = position }
end

local function body(name: string, position: Vector3): Model
	local model = Instance.new("Model")
	model.Name = name
	local root = Instance.new("Part")
	root.Anchored = true
	root.CFrame = CFrame.new(position)
	root.Parent = model
	model.PrimaryPart = root
	table.insert(spawned, model)
	return model
end

local function launch(id: number, overrides: { [string]: any }?): Event
	local event: any = {
		Kind = "Launch",
		Id = id,
		GroupId = id,
		Position = Vector3.zero,
		-- 50 studs/s for 2s: a 100-stud straight path along +X.
		Velocity = Vector3.new(50, 0, 0),
		Lead = 0,
		LifetimeSeconds = 2,
		Motion = { Gravity = 0, Acceleration = 0, HomingStrength = 0, MaxSpeed = 50 },
	}
	for key, value in overrides or {} do
		event[key] = value
	end
	return event
end

local function follow(kind: string, id: number): Event
	return {
		Kind = kind,
		Id = id,
		GroupId = id,
		Position = Vector3.zero,
		Velocity = Vector3.zero,
		Lead = 0,
	} :: any
end

local function count(routed: { [Player]: { Event } }, player: Player): number
	local list = routed[player]
	return if list then #list else 0
end

return function()
	afterEach(function()
		for _, instance in spawned do
			instance:Destroy()
		end
		table.clear(spawned)
	end)

	describe("ProjectileRelevance", function()
		it("sends a launch to players near its path and not to players far from it", function()
			local router = ProjectileRelevance.New(RADIUS)
			local near = fakePlayer("Near")
			local downrange = fakePlayer("Downrange")
			local far = fakePlayer("Far")
			local routed = router:Route({ launch(1) }, {
				viewer(near, Vector3.new(0, 0, 60)),
				-- Beside the far end of the path, well away from where it launched.
				viewer(downrange, Vector3.new(100, 0, 80)),
				viewer(far, Vector3.new(0, 0, 900)),
			}, 0)
			expect(count(routed, near)).to.equal(1)
			expect(count(routed, downrange)).to.equal(1)
			expect(count(routed, far)).to.equal(0)
		end)

		it("always sends a shot to its thrower, its homing target, and a player with no character", function()
			local router = ProjectileRelevance.New(RADIUS)
			local thrower, targeted, spawning = fakePlayer("Thrower"), fakePlayer("Targeted"), fakePlayer("Spawning")
			local throwerBody = body("ThrowerBody", Vector3.new(0, 0, 5000))
			local targetBody = body("TargetBody", Vector3.new(0, 0, -5000))
			local routed = router:Route({ launch(1, { Owner = throwerBody, Target = targetBody }) }, {
				viewer(thrower, Vector3.new(0, 0, 5000), throwerBody),
				viewer(targeted, Vector3.new(0, 0, -5000), targetBody),
				viewer(spawning, nil),
			}, 0)
			expect(count(routed, thrower)).to.equal(1)
			expect(count(routed, targeted)).to.equal(1)
			expect(count(routed, spawning)).to.equal(1)
		end)

		it("sends a pinned homing shot to players standing near the body it is homing on", function()
			local router = ProjectileRelevance.New(RADIUS)
			local watcher = fakePlayer("Watcher")
			-- The shot launches away from the watcher, but curves onto a body standing beside them.
			local targetBody = body("TargetBody", Vector3.new(0, 0, 400))
			local homing = launch(1, {
				Target = targetBody,
				Motion = { Gravity = 0, Acceleration = 0, HomingStrength = 720, MaxSpeed = 50 },
			})
			local routed = router:Route({ homing }, { viewer(watcher, Vector3.new(30, 0, 400)) }, 0)
			expect(count(routed, watcher)).to.equal(1)
		end)

		it("routes a shot's updates and end to exactly the players that were sent its launch", function()
			local router = ProjectileRelevance.New(RADIUS)
			local near, far = fakePlayer("Near"), fakePlayer("Far")
			local viewers = { viewer(near, Vector3.new(0, 0, 10)), viewer(far, Vector3.new(0, 0, 900)) }
			router:Route({ launch(1) }, viewers, 0)
			local routed = router:Route({ follow("Update", 1), follow("End", 1) }, viewers, 0.1)
			expect(count(routed, near)).to.equal(2)
			expect(count(routed, far)).to.equal(0)
			-- The End forgot the shot: a stray later event for it goes nowhere.
			expect(router:TrackedCount()).to.equal(0)
			expect(next(router:Route({ follow("Update", 1) }, viewers, 0.2))).to.equal(nil)
		end)

		it("keeps a re-launched shot's first recipients and adds any new ones", function()
			local router = ProjectileRelevance.New(RADIUS)
			local first, second = fakePlayer("First"), fakePlayer("Second")
			local viewers = { viewer(first, Vector3.new(0, 0, 10)), viewer(second, Vector3.new(0, 0, -600)) }
			router:Route({ launch(1) }, viewers, 0)
			-- A parry turns the shot round, far from the first recipient, toward the second.
			local turned = launch(1, { Position = Vector3.new(0, 0, -520), Velocity = Vector3.new(0, 0, -50) })
			local routed = router:Route({ turned }, viewers, 0.5)
			expect(count(routed, first)).to.equal(1)
			expect(count(routed, second)).to.equal(1)
		end)

		it("does not send a shot to a player who has left", function()
			local router = ProjectileRelevance.New(RADIUS)
			local stays, leaves = fakePlayer("Stays"), fakePlayer("Leaves")
			router:Route({ launch(1) }, {
				viewer(stays, Vector3.new(0, 0, 10)),
				viewer(leaves, Vector3.new(0, 0, 20)),
			}, 0)
			local routed = router:Route({ follow("End", 1) }, { viewer(stays, Vector3.new(0, 0, 10)) }, 0.1)
			expect(count(routed, stays)).to.equal(1)
			expect(routed[leaves]).to.equal(nil)
		end)

		it("forgets a shot whose end never came, once its lifetime and grace are past", function()
			local router = ProjectileRelevance.New(RADIUS)
			local near = fakePlayer("Near")
			router:Route({ launch(1) }, { viewer(near, Vector3.new(0, 0, 10)) }, 0)
			expect(router:TrackedCount()).to.equal(1)
			router:Route({}, { viewer(near, Vector3.new(0, 0, 10)) }, 10)
			expect(router:TrackedCount()).to.equal(0)
		end)
	end)
end
