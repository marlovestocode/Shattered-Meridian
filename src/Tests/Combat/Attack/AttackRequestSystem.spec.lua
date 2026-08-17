--!strict
-- Covers Server/Combat/Attack/AttackRequestSystem.lua -- the gates, the per-move cooldown and the
-- input buffer, against the real HitboxEngine and the real DefenseSystem.
--
-- Needs a Workspace, like HitboxEngine.spec and DefenseSystem.spec and for the same reason: the point
-- of this module is that it gates a real engine call on real combatant state, and a synthetic stand-in
-- for either would test the wiring rather than the behaviour. Dummies are built with Instance.new
-- exactly as those specs build their own.
--
-- Time is anchored to os.clock() rather than to an arbitrary constant, because HitboxEngine.
-- RequestAttack stamps its own swing start from the wall clock (the one entry point on that module
-- that does) -- so a spec on a purely synthetic clock would step the engine's state machine with
-- times unrelated to when its swing actually began. Anchoring at `base = os.clock()` and stepping
-- with offsets from it is the same accommodation DefenseSystem.spec already makes. Nothing here
-- sleeps.
--
-- Init() is deliberately never called: it would connect a real Heartbeat racing these synthetic Steps
-- and create remotes with nobody to fire them at. Every case drives Throw/Press/Step directly, which
-- is exactly the surface Init() wires the remote to.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AttackCatalog = require(ServerScriptService.Server.Combat.AttackCatalog)
local AttackConstants = require(ReplicatedStorage.Shared.Attack.AttackConstants)
local AttackRequestSystem = require(ServerScriptService.Server.Combat.Attack.AttackRequestSystem)
local DefenseSystem = require(ServerScriptService.Server.Combat.Defense.DefenseSystem)
local HitboxEngine = require(ServerScriptService.Server.Combat.HitboxEngine.HitboxEngine)
local SwingSequencer = require(ServerScriptService.Server.Combat.Attack.SwingSequencer)

local FRAME = 1 / 60
local BUFFER = AttackConstants.Input.BufferSeconds
local CHAIN_DELAY = AttackConstants.Sequence.ChainDelaySeconds

-- A real, catalogued move with a long cooldown relative to its own swing, so a cooldown refusal can be
-- observed without waiting out a swing. Primary Heavy 1 authors Cooldown 1.37 against a ~1.37s swing.
local HOTBAR_MOVE = "default:Primary:Heavy:1"

type Dummy = {
	Model: Model,
	Root: BasePart,
	Humanoid: Humanoid,
	Id: number,
}

local spawned: { Model } = {}

-- Anchored, so nothing here is a race against gravity. Registered with the ENGINE only by default --
-- DefenseSystem.CanAttack permits an unregistered model (its own documented contract), so a case that
-- needs a real defensive state registers for itself.
local function makeDummy(name: string, position: Vector3): Dummy
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

	local id = HitboxEngine.RegisterCombatant(model, root, humanoid)
	return { Model = model, Root = root, Humanoid = humanoid, Id = id }
end

-- A body the engine has never heard of, for the NotRegistered gate.
local function makeUnregistered(name: string): Model
	local model = Instance.new("Model")
	model.Name = name

	local humanoid = Instance.new("Humanoid")
	humanoid.RequiresNeck = false
	humanoid.Parent = model

	model.Parent = Workspace
	table.insert(spawned, model)
	return model
end

-- One frame, in the order Main.server.lua guarantees at runtime: engine first, attack layer last.
local function step(now: number): ()
	HitboxEngine.Step(FRAME, now)
	AttackRequestSystem.Step(FRAME, now)
end

-- How long the currently-authored stage-1 Basic swing occupies the engine for.
local function basicSwingSeconds(): number
	local entry = AttackCatalog.Get("default:Primary:Basic:1")
	assert(entry ~= nil, "the Primary Basic string must be catalogued")
	local definition = (entry :: any).Definition
	return definition.WindupSeconds + definition.ActiveSeconds + definition.RecoverySeconds
end

-- The earliest moment stage 2 can legally be thrown, relative to a stage-1 throw at t: the swing's own
-- commitment plus the deliberate beat between links. Derived rather than hardcoded, so retuning either
-- half moves every case below with it instead of leaving assertions pinned to a stale rhythm.
local function chainGateSeconds(): number
	return basicSwingSeconds() + CHAIN_DELAY
end

return function()
	afterEach(function()
		AttackRequestSystem.Reset()
		DefenseSystem.Reset()
		HitboxEngine.Reset()
		AttackCatalog.Reset()
		for _, model in spawned do
			model:Destroy()
		end
		table.clear(spawned)
	end)

	describe("AttackRequestSystem -- the gates that are not about timing", function()
		it("refuses a body the engine has never been told about", function()
			local model = makeUnregistered("Stranger")
			local accepted, reason = AttackRequestSystem.Throw(model, { Kind = "Basic" }, false, os.clock())
			expect(accepted).to.equal(false)
			expect(reason).to.equal("NotRegistered")
		end)

		it("refuses a dead combatant", function()
			local attacker = makeDummy("Corpse", Vector3.new(0, 5, 0))
			attacker.Humanoid.Health = 0
			local accepted, reason = AttackRequestSystem.Throw(attacker.Model, { Kind = "Basic" }, false, os.clock())
			expect(accepted).to.equal(false)
			expect(reason).to.equal("NoCharacter")
		end)

		it("refuses a hotbar press from an unauthorised sender", function()
			-- The whole reason a MoveId is allowed on the wire at all -- see AttackTypes.AttackRequest.
			-- MoveId's own header. Without this gate the hotbar is a "throw any authored move" hole.
			local attacker = makeDummy("Civilian", Vector3.new(0, 5, 0))
			local accepted, reason = AttackRequestSystem.Throw(
				attacker.Model,
				{ Kind = "Hotbar", Slot = 1, MoveId = HOTBAR_MOVE },
				false,
				os.clock()
			)
			expect(accepted).to.equal(false)
			expect(reason).to.equal("NotAuthorized")
		end)

		it("refuses a hotbar press naming a move that does not exist", function()
			local attacker = makeDummy("Fabricator", Vector3.new(0, 5, 0))
			local accepted, reason = AttackRequestSystem.Throw(
				attacker.Model,
				{ Kind = "Hotbar", Slot = 1, MoveId = "default:NoSuchWeapon:Basic:99" },
				true,
				os.clock()
			)
			expect(accepted).to.equal(false)
			expect(reason).to.equal("UnknownMove")
		end)
	end)

	describe("AttackRequestSystem -- throwing", function()
		it("accepts a Basic press and puts the engine to work", function()
			local attacker = makeDummy("Swinger", Vector3.new(0, 5, 0))
			local accepted = AttackRequestSystem.Throw(attacker.Model, { Kind = "Basic" }, false, os.clock())
			expect(accepted).to.equal(true)
			expect(HitboxEngine.GetAttackState(attacker.Id)).never.to.equal("Idle")
		end)

		it("advances the string only on an accepted throw", function()
			local attacker = makeDummy("Stringing", Vector3.new(0, 5, 0))
			local base = os.clock()

			AttackRequestSystem.Throw(attacker.Model, { Kind = "Basic" }, false, base)
			expect(SwingSequencer.GetStageIndex(attacker.Model, "Basic", base)).to.equal(1)

			-- Refused for being mid-swing. The string must NOT move, or a player pressing early would
			-- silently skip a stage.
			local accepted, reason = AttackRequestSystem.Throw(attacker.Model, { Kind = "Basic" }, false, base + 0.01)
			expect(accepted).to.equal(false)
			expect(reason).to.equal("Busy")
			expect(SwingSequencer.GetStageIndex(attacker.Model, "Basic", base + 0.01)).to.equal(1)
		end)

		it("leaves the string alone for a hotbar press", function()
			-- A hotbar move is not part of either string and must not disturb the one in progress.
			local attacker = makeDummy("Hotbarrer", Vector3.new(0, 5, 0))
			local base = os.clock()

			AttackRequestSystem.Throw(attacker.Model, { Kind = "Basic" }, false, base)
			HitboxEngine.CancelAttack(attacker.Id, "Spec", base + 0.01)

			local accepted = AttackRequestSystem.Throw(
				attacker.Model,
				{ Kind = "Hotbar", Slot = 1, MoveId = HOTBAR_MOVE },
				true,
				base + 0.02
			)
			expect(accepted).to.equal(true)
			HitboxEngine.CancelAttack(attacker.Id, "Spec", base + 0.03)

			-- Still stage 1 thrown, so the next Basic press is stage 2.
			local resolution = SwingSequencer.Resolve(attacker.Model, "Basic", 1, base + 0.04)
			expect((resolution :: any).StageIndex).to.equal(2)
		end)
	end)

	describe("AttackRequestSystem -- per-move cooldown", function()
		it("refuses the same move again while its authored cooldown is running", function()
			-- Asserted through the hotbar rather than the string, deliberately: a second Basic press
			-- resolves to a DIFFERENT move with its own cooldown, so the string can never exercise this
			-- gate. The swing is cancelled first so "Busy" cannot be the reason instead.
			local attacker = makeDummy("Cooling", Vector3.new(0, 5, 0))
			local base = os.clock()
			local request = { Kind = "Hotbar" :: "Hotbar", Slot = 1, MoveId = HOTBAR_MOVE }

			expect(AttackRequestSystem.Throw(attacker.Model, request, true, base)).to.equal(true)
			HitboxEngine.CancelAttack(attacker.Id, "Spec", base + 0.01)
			expect(HitboxEngine.GetAttackState(attacker.Id)).to.equal("Idle")

			local accepted, reason = AttackRequestSystem.Throw(attacker.Model, request, true, base + 0.02)
			expect(accepted).to.equal(false)
			expect(reason).to.equal("Cooldown")
		end)

		it("reports the remaining cooldown it is enforcing", function()
			local attacker = makeDummy("Reporting", Vector3.new(0, 5, 0))
			local base = os.clock()
			AttackRequestSystem.Throw(attacker.Model, { Kind = "Hotbar", Slot = 1, MoveId = HOTBAR_MOVE }, true, base)

			local entry = AttackCatalog.Get(HOTBAR_MOVE)
			local authored = (entry :: any).Cooldown
			expect(AttackRequestSystem.GetCooldownRemaining(attacker.Model, HOTBAR_MOVE, base)).to.be.near(
				authored,
				1e-3
			)
			-- Past the end, it is zero rather than negative -- a HUD reading this must never be handed
			-- a number it would render as a countdown running backwards.
			expect(AttackRequestSystem.GetCooldownRemaining(attacker.Model, HOTBAR_MOVE, base + authored + 1)).to.equal(
				0
			)
		end)
	end)

	describe("AttackRequestSystem -- the input buffer", function()
		it("remembers a press refused for being mid-swing", function()
			local attacker = makeDummy("Early", Vector3.new(0, 5, 0))
			local base = os.clock()

			AttackRequestSystem.Throw(attacker.Model, { Kind = "Basic" }, false, base)
			local accepted = AttackRequestSystem.Press(attacker.Model, { Kind = "Basic" }, false, base + 0.01)
			expect(accepted).to.equal(false)
			expect(AttackRequestSystem.HasBufferedPress(attacker.Model, base + 0.01)).to.equal(true)
		end)

		it("throws the buffered press the moment the gate opens", function()
			-- The whole point of the buffer: a press made slightly early is simply a press.
			local attacker = makeDummy("Forgiven", Vector3.new(0, 5, 0))
			local base = os.clock()
			local gate = chainGateSeconds()

			AttackRequestSystem.Throw(attacker.Model, { Kind = "Basic" }, false, base)
			-- Pressed inside the buffer window before the GATE opens -- which is the swing's end plus
			-- the chain delay, not the swing's end alone. Asserting from a point the buffer genuinely
			-- covers is the honest test; a press made a full second early SHOULD be dropped, and the
			-- case below covers that.
			local pressedAt = base + gate - (BUFFER / 2)
			AttackRequestSystem.Press(attacker.Model, { Kind = "Basic" }, false, pressedAt)

			for frame = 0, math.ceil((gate + FRAME) / FRAME) do
				step(base + frame * FRAME)
			end

			-- Stage 2 is the proof: the buffered press was thrown, not merely forgotten.
			expect(SwingSequencer.GetStageIndex(attacker.Model, "Basic", base + gate + FRAME)).to.equal(2)
			expect(AttackRequestSystem.HasBufferedPress(attacker.Model, base + gate + FRAME)).to.equal(false)
		end)

		it("drops a buffered press that outlives its own window", function()
			local attacker = makeDummy("Forgotten", Vector3.new(0, 5, 0))
			local base = os.clock()

			AttackRequestSystem.Throw(attacker.Model, { Kind = "Basic" }, false, base)
			AttackRequestSystem.Press(attacker.Model, { Kind = "Basic" }, false, base + 0.01)

			-- Asserted just PAST the boundary rather than merely somewhere after it.
			step(base + 0.01 + BUFFER + FRAME)
			expect(AttackRequestSystem.HasBufferedPress(attacker.Model, base + 0.01 + BUFFER + FRAME)).to.equal(false)
			-- And it did not fire on its way out.
			expect(SwingSequencer.GetStageIndex(attacker.Model, "Basic", base + 0.01 + BUFFER + FRAME)).to.equal(1)
		end)

		it("re-validates at flush time rather than replaying blindly", function()
			-- A press buffered a moment ago may have become illegal since. Firing it anyway is exactly
			-- the bug the re-validation exists to prevent.
			local attacker = makeDummy("Interrupted", Vector3.new(0, 5, 0))
			local base = os.clock()

			AttackRequestSystem.Throw(attacker.Model, { Kind = "Basic" }, false, base)
			AttackRequestSystem.Press(attacker.Model, { Kind = "Basic" }, false, base + 0.01)
			HitboxEngine.CancelAttack(attacker.Id, "Spec", base + 0.02)
			-- Illegal now, for a reason that is not about timing.
			attacker.Humanoid.Health = 0

			step(base + 0.03)
			expect(SwingSequencer.GetStageIndex(attacker.Model, "Basic", base + 0.03)).to.equal(1)
		end)

		it("keeps only the newest press, never a backlog", function()
			-- Mashing must not build a queue that fires as a burst once the gate opens.
			local attacker = makeDummy("Masher", Vector3.new(0, 5, 0))
			local base = os.clock()
			local gate = chainGateSeconds()

			AttackRequestSystem.Throw(attacker.Model, { Kind = "Basic" }, false, base)
			for _press = 1, 8 do
				AttackRequestSystem.Press(attacker.Model, { Kind = "Basic" }, false, base + gate - (BUFFER / 2))
			end

			for frame = 0, math.ceil((gate + FRAME) / FRAME) do
				step(base + frame * FRAME)
			end

			-- Exactly one extra swing came out of eight buffered presses.
			expect(SwingSequencer.GetStageIndex(attacker.Model, "Basic", base + gate + FRAME)).to.equal(2)
		end)

		it("does not buffer a refusal the player is choosing to cause", function()
			-- Holding a guard refuses an attack, and that refusal is NOT transient in the sense the
			-- buffer means: firing a queued swing the instant a player lets go of a block they were
			-- holding on purpose is a worse answer than doing nothing.
			local attacker = makeDummy("Guarding", Vector3.new(0, 5, 0))
			local base = os.clock()
			DefenseSystem.RegisterCombatant(attacker.Model, attacker.Root, attacker.Humanoid)
			DefenseSystem.SetBlocking(attacker.Model, true, base)

			local accepted, reason = AttackRequestSystem.Press(attacker.Model, { Kind = "Basic" }, false, base + 0.01)
			expect(accepted).to.equal(false)
			expect(reason).to.equal("Guarding")
			expect(AttackRequestSystem.HasBufferedPress(attacker.Model, base + 0.01)).to.equal(false)
		end)
	end)

	describe("AttackRequestSystem -- the beat between links", function()
		it("refuses the next stage during the chain delay, even with the engine idle", function()
			-- The engine is explicitly free here (the swing was cancelled), so "Busy" cannot be the
			-- reason -- this is the deliberate pause and nothing else.
			local attacker = makeDummy("Chaining", Vector3.new(0, 5, 0))
			local base = os.clock()

			AttackRequestSystem.Throw(attacker.Model, { Kind = "Basic" }, false, base)
			HitboxEngine.CancelAttack(attacker.Id, "Spec", base + 0.01)
			expect(HitboxEngine.GetAttackState(attacker.Id)).to.equal("Idle")

			local accepted, reason = AttackRequestSystem.Throw(attacker.Model, { Kind = "Basic" }, false, base + 0.02)
			expect(accepted).to.equal(false)
			expect(reason).to.equal("ChainDelay")
		end)

		it("allows the next stage once the beat has passed", function()
			local attacker = makeDummy("Chained", Vector3.new(0, 5, 0))
			local base = os.clock()
			local gate = chainGateSeconds()

			AttackRequestSystem.Throw(attacker.Model, { Kind = "Basic" }, false, base)
			HitboxEngine.CancelAttack(attacker.Id, "Spec", base + 0.01)

			-- Past the gate the string continues, so this is stage 2 rather than a fresh stage 1 --
			-- proof the beat delayed the link rather than breaking the string.
			local accepted = AttackRequestSystem.Throw(attacker.Model, { Kind = "Basic" }, false, base + gate + 1e-3)
			expect(accepted).to.equal(true)
			expect(SwingSequencer.GetStageIndex(attacker.Model, "Basic", base + gate + 1e-3)).to.equal(2)
		end)

		it("does not make a hotbar move wait on a string's rhythm", function()
			-- A hotbar cast is not a link in a chain; it has its own authored Cooldown, and making it
			-- also wait on the beat would be a second, invisible cooldown stacked on the real one.
			local attacker = makeDummy("Casting", Vector3.new(0, 5, 0))
			local base = os.clock()

			AttackRequestSystem.Throw(attacker.Model, { Kind = "Basic" }, false, base)
			HitboxEngine.CancelAttack(attacker.Id, "Spec", base + 0.01)

			local accepted = AttackRequestSystem.Throw(
				attacker.Model,
				{ Kind = "Hotbar", Slot = 1, MoveId = HOTBAR_MOVE },
				true,
				base + 0.02
			)
			expect(accepted).to.equal(true)
		end)

		it("keeps the beat shorter than the buffer that forgives it", function()
			-- The relationship, not either number: a chain delay at or past the buffer would mean a
			-- press made the instant a swing ends expires before the beat it is waiting on opens, which
			-- is the one way the pause makes the game feel worse rather than better. Asserted here so
			-- retuning either constant in isolation fails loudly.
			expect(CHAIN_DELAY < BUFFER).to.equal(true)
		end)
	end)

	describe("AttackRequestSystem -- weapons", function()
		it("reports the weapon the sequencer is holding", function()
			local attacker = makeDummy("Armed", Vector3.new(0, 5, 0))
			expect(AttackRequestSystem.GetWeapon(attacker.Model)).to.equal(AttackConstants.Weapons.Default)
			SwingSequencer.SwapWeapon(attacker.Model, os.clock())
			expect(AttackRequestSystem.GetWeapon(attacker.Model)).to.equal("Secondary")
		end)
	end)
end
