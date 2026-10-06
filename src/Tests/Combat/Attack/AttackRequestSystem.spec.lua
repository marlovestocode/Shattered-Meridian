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

local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AttackCatalog = require(ServerScriptService.Server.Combat.AttackCatalog)
local AttackConstants = require(ReplicatedStorage.Shared.Attack.AttackConstants)
local AttackRequestSystem = require(ServerScriptService.Server.Combat.Attack.AttackRequestSystem)
local DamageConstants = require(ReplicatedStorage.Shared.Damage.DamageConstants)
local DamageSystem = require(ServerScriptService.Server.Combat.Damage.DamageSystem)
local DefenseConstants = require(ReplicatedStorage.Shared.Defense.DefenseConstants)
local NetworkLatency = require(ServerScriptService.Server.Combat.NetworkLatency)
local DefenseSystem = require(ServerScriptService.Server.Combat.Defense.DefenseSystem)
local GuardMeter = require(ServerScriptService.Server.Combat.Defense.GuardMeter)
local HitboxEngine = require(ServerScriptService.Server.Combat.HitboxEngine.HitboxEngine)
local SwingSequencer = require(ServerScriptService.Server.Combat.Attack.SwingSequencer)
local WeaponFixture = require(ServerScriptService.Tests.TestHelpers.WeaponFixture)

-- The real roster this file asserts against -- weapons are models in Workspace.Weapons now, so a spec
-- that installs none has an empty roster and every throw resolves to nothing.
local ROSTER = WeaponFixture.Install()
local FIRST_WEAPON = ROSTER[1]
local SECOND_WEAPON = ROSTER[2]

local FRAME = 1 / 60
local BUFFER = AttackConstants.Input.BufferSeconds
local CHAIN_DELAY = AttackConstants.Sequence.ChainDelaySeconds

-- A real, catalogued move -- used only to populate AttackRequest.MoveId in the "unauthorised sender"
-- case below. Its VALUE never matters there: MoveId is read but completely ignored for Hotbar now
-- (see AttackTypes.AttackRequest.MoveId's own header). This file used to also cover per-move
-- cooldown, chain-delay independence, and "a hotbar press leaves the string alone" by THROWING a
-- Hotbar move through this same constant -- all three needed the throw to actually SUCCEED, which
-- now requires a real Player with a loaded profile and a real equipped Art
-- (AttackRequestSystem.resolveRequest resolves every Hotbar press through ArtSystem.GetEquipped,
-- admin or not -- see AttackRequestSystem.lua's own header). A bare Instance.new("Player") errors in
-- this headless harness -- the same already-accepted gap Tests/Admin/AdminActionSystem.spec.lua's
-- own header documents for its Player-keyed wrappers -- so that coverage is deferred to
-- Studio/live-server verification; there is no synthetic-dummy substitute for it here.
local HOTBAR_MOVE = `default:{FIRST_WEAPON}:Heavy:1`

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
	-- ARMED, because a fresh SwingSequencer record is now EMPTY-HANDED and an unarmed combatant
	-- resolves no swings at all (see that module's own recordFor). Every case in this file is about
	-- the REQUEST path rather than about being armed, so this is fixture work rather than something
	-- each case restates.
	SwingSequencer.SetWeapon(model, FIRST_WEAPON, os.clock())
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
	local entry = AttackCatalog.Get(`default:{FIRST_WEAPON}:Basic:1`)
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

		it("refuses a hotbar press whose model has no real Player behind it", function()
			-- Every Hotbar press -- admin or not -- resolves through Players:GetPlayerFromCharacter
			-- and then ArtSystem.GetEquipped now (see AttackRequestSystem.lua's own header on why);
			-- there is no longer a second, trusted branch a synthetic dummy (or a spoofed `authorized`)
			-- can reach instead. Asserted for BOTH authorized values on purpose, to prove that flag no
			-- longer changes Hotbar resolution at all -- exactly the class of bug ("an admin's press
			-- takes a different, less-checked path") this module's own header describes fixing.
			local attacker = makeDummy("Civilian", Vector3.new(0, 5, 0))
			for _, authorized in { false, true } do
				local accepted, reason = AttackRequestSystem.Throw(
					attacker.Model,
					{ Kind = "Hotbar", Slot = 1, MoveId = HOTBAR_MOVE },
					authorized,
					os.clock()
				)
				expect(accepted).to.equal(false)
				expect(reason).to.equal("NotAuthorized")
			end
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
	end)

	-- "AttackRequestSystem -- per-move cooldown" and a "leaves the string alone for a hotbar press"
	-- case used to live here, both asserted by THROWING a Hotbar move -- see HOTBAR_MOVE's own header
	-- on why that now needs a real Player and is deferred to Studio/live-server verification instead.

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

		it("drops a buffered press the moment its re-validation refuses for a reason that does not clear", function()
			-- Buffered mid-swing (Busy), then the guard is held. Kept waiting, the press would throw the
			-- instant the guard came back down -- the free swing out of a guard "does not buffer a refusal
			-- the player is choosing to cause" exists to prevent, reached through the flush instead.
			local attacker = makeDummy("GuardedBuffer", Vector3.new(0, 5, 0))
			local base = os.clock()
			local gate = chainGateSeconds()
			DefenseSystem.RegisterCombatant(attacker.Model, attacker.Root, attacker.Humanoid)

			local seen = {}
			local disconnect = AttackRequestSystem.OnPressRefused(function(_model, pressId, reason)
				table.insert(seen, { PressId = pressId, Reason = reason })
			end)
			AttackRequestSystem.Throw(attacker.Model, { Kind = "Basic" }, false, base)
			AttackRequestSystem.Press(attacker.Model, { Kind = "Basic", PressId = 3 }, false, base + 0.01)
			expect(AttackRequestSystem.HasBufferedPress(attacker.Model, base + 0.01)).to.equal(true)
			-- Mid-swing, so the guard is deferred (DefenseSystem.CanAttack answers "Guarding").
			DefenseSystem.SetBlocking(attacker.Model, true, base + 0.02)
			step(base + 0.03)
			disconnect()

			expect(AttackRequestSystem.HasBufferedPress(attacker.Model, base + 0.03)).to.equal(false)
			expect(#seen).to.equal(1)
			expect(seen[1].PressId).to.equal(3)
			expect(seen[1].Reason).to.equal("Guarding")

			-- Releasing the guard inside the old buffer window throws nothing.
			DefenseSystem.SetBlocking(attacker.Model, false, base + 0.04)
			for frame = 3, math.ceil((gate + FRAME) / FRAME) do
				step(base + frame * FRAME)
			end
			expect(SwingSequencer.GetStageIndex(attacker.Model, "Basic", base + gate + FRAME)).to.equal(1)
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

	describe("AttackRequestSystem -- a fresh life", function()
		-- A respawn is a new character Model: none of the previous life's stun, buffered press or string carries.
		it("starts the next body clean after a death mid-string", function()
			local base = os.clock()
			local first = makeDummy("Life1", Vector3.new(0, 5, 0))
			AttackRequestSystem.Throw(first.Model, { Kind = "Basic" }, false, base)
			AttackRequestSystem.Press(first.Model, { Kind = "Basic", PressId = 1 }, false, base + 0.01)
			DamageSystem.ExtendHitstun(first.Model, base + 1, base + 0.01)
			first.Humanoid.Health = 0
			first.Model:Destroy()
			step(base + 0.02)

			local second = makeDummy("Life2", Vector3.new(0, 5, 0))
			expect(DamageSystem.CanAttack(second.Model, base + 0.03)).to.equal(true)
			expect(AttackRequestSystem.HasBufferedPress(second.Model, base + 0.03)).to.equal(false)
			expect(SwingSequencer.GetStageIndex(second.Model, "Basic", base + 0.03)).to.equal(0)
			-- The new life's press ids are its own: a press the client numbers on from the old life still throws.
			expect((AttackRequestSystem.Press(second.Model, { Kind = "Basic", PressId = 2 }, false, base + 0.03))).to.equal(
				true
			)
		end)
	end)

	describe("AttackRequestSystem -- the press verdict", function()
		-- A press carrying an id that will not throw is answered (AttackRequestSystem.OnPressRefused, and a
		-- "Refused" Attack_Cancelled for a player), so the client cuts its prediction instead of timing out.
		local function captureRefusals(): ({ { Model: Model, PressId: number, Reason: string } }, () -> ())
			local seen = {}
			local disconnect = AttackRequestSystem.OnPressRefused(function(model, pressId, reason)
				table.insert(seen, { Model = model, PressId = pressId, Reason = reason })
			end)
			return seen, disconnect
		end

		it("answers a press refused on arrival", function()
			local attacker = makeDummy("Refused", Vector3.new(0, 5, 0))
			local base = os.clock()
			DefenseSystem.RegisterCombatant(attacker.Model, attacker.Root, attacker.Humanoid)
			DefenseSystem.SetBlocking(attacker.Model, true, base)

			local seen, disconnect = captureRefusals()
			AttackRequestSystem.Press(attacker.Model, { Kind = "Basic", PressId = 7 }, false, base + 0.01)
			disconnect()

			expect(#seen).to.equal(1)
			expect(seen[1].PressId).to.equal(7)
			expect(seen[1].Reason).to.equal("Guarding")
		end)

		it("answers a buffered press that expires, and says so", function()
			local attacker = makeDummy("Expired", Vector3.new(0, 5, 0))
			local base = os.clock()

			AttackRequestSystem.Throw(attacker.Model, { Kind = "Basic" }, false, base)
			local seen, disconnect = captureRefusals()
			AttackRequestSystem.Press(attacker.Model, { Kind = "Basic", PressId = 1 }, false, base + 0.01)
			expect(#seen).to.equal(0)
			step(base + 0.01 + BUFFER + FRAME)
			disconnect()

			expect(#seen).to.equal(1)
			expect(seen[1].PressId).to.equal(1)
			expect(seen[1].Reason).to.equal("Expired")
		end)

		it("answers the buffered press a newer one replaces", function()
			local attacker = makeDummy("Superseded", Vector3.new(0, 5, 0))
			local base = os.clock()

			AttackRequestSystem.Throw(attacker.Model, { Kind = "Basic" }, false, base)
			local seen, disconnect = captureRefusals()
			AttackRequestSystem.Press(attacker.Model, { Kind = "Basic", PressId = 1 }, false, base + 0.01)
			AttackRequestSystem.Press(attacker.Model, { Kind = "Basic", PressId = 2 }, false, base + 0.02)
			disconnect()

			expect(#seen).to.equal(1)
			expect(seen[1].PressId).to.equal(1)
			expect(seen[1].Reason).to.equal("Superseded")
			expect(AttackRequestSystem.HasBufferedPress(attacker.Model, base + 0.02)).to.equal(true)
		end)

		it("does not answer a press that throws", function()
			local attacker = makeDummy("Thrown", Vector3.new(0, 5, 0))
			local base = os.clock()

			local seen, disconnect = captureRefusals()
			local accepted = AttackRequestSystem.Press(attacker.Model, { Kind = "Basic", PressId = 1 }, false, base)
			disconnect()

			expect(accepted).to.equal(true)
			expect(#seen).to.equal(0)
		end)

		it("drops a press id it has already seen, without throwing or answering", function()
			local attacker = makeDummy("Duplicate", Vector3.new(0, 5, 0))
			local base = os.clock()

			expect((AttackRequestSystem.Press(attacker.Model, { Kind = "Basic", PressId = 5 }, false, base))).to.equal(
				true
			)
			local seen, disconnect = captureRefusals()
			local accepted, reason =
				AttackRequestSystem.Press(attacker.Model, { Kind = "Basic", PressId = 5 }, false, base + 0.01)
			disconnect()

			expect(accepted).to.equal(false)
			expect(reason).to.equal("Duplicate")
			expect(#seen).to.equal(0)
			expect(AttackRequestSystem.HasBufferedPress(attacker.Model, base + 0.01)).to.equal(false)
		end)
	end)

	describe("AttackRequestSystem -- the guard cut", function()
		-- Where a guard may cut the first Basic stage thrown at `base` (AttackConstants.GuardCut).
		local function guardCutAt(base: number): number
			local definition = (AttackCatalog.Get(`default:{FIRST_WEAPON}:Basic:1`) :: any).Definition
			return AttackConstants.GuardCutAt(
				base,
				definition.WindupSeconds,
				definition.ActiveSeconds,
				definition.RecoverySeconds
			)
		end

		it("cuts the swing's recovery for a guard held against it, at the cut point", function()
			local attacker = makeDummy("GuardCut", Vector3.new(0, 5, 0))
			DefenseSystem.RegisterCombatant(attacker.Model, attacker.Root, attacker.Humanoid)
			local base = os.clock()
			expect((AttackRequestSystem.Throw(attacker.Model, { Kind = "Basic" }, false, base))).to.equal(true)
			-- Pressed mid-swing, so the defence layer holds it until the body is free.
			DefenseSystem.SetBlocking(attacker.Model, true, base + 0.01)
			expect(DefenseSystem.IsGuardDeferred(attacker.Model)).to.equal(true)

			local cutAt = guardCutAt(base) + 1e-3
			step(cutAt)
			expect(HitboxEngine.GetAttackState(attacker.Id)).never.to.equal("Recovery")
		end)

		it("does not cut before the cut point", function()
			local attacker = makeDummy("GuardTooSoon", Vector3.new(0, 5, 0))
			DefenseSystem.RegisterCombatant(attacker.Model, attacker.Root, attacker.Humanoid)
			local base = os.clock()
			AttackRequestSystem.Throw(attacker.Model, { Kind = "Basic" }, false, base)
			DefenseSystem.SetBlocking(attacker.Model, true, base + 0.01)

			local definition = (AttackCatalog.Get(`default:{FIRST_WEAPON}:Basic:1`) :: any).Definition
			local intoRecovery = base + definition.WindupSeconds + definition.ActiveSeconds + 1e-3
			if intoRecovery < guardCutAt(base) then
				step(intoRecovery)
				expect(HitboxEngine.GetAttackState(attacker.Id)).to.equal("Recovery")
			end
		end)

		it("leaves a swing alone when no guard is waiting on it", function()
			local attacker = makeDummy("NoGuard", Vector3.new(0, 5, 0))
			DefenseSystem.RegisterCombatant(attacker.Model, attacker.Root, attacker.Humanoid)
			local base = os.clock()
			AttackRequestSystem.Throw(attacker.Model, { Kind = "Basic" }, false, base)

			local definition = (AttackCatalog.Get(`default:{FIRST_WEAPON}:Basic:1`) :: any).Definition
			if definition.RecoverySeconds > 0.02 then
				step(guardCutAt(base) + 1e-3)
				expect(HitboxEngine.GetAttackState(attacker.Id)).to.equal("Recovery")
			end
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

		-- A "does not make a hotbar move wait on a string's rhythm" case used to live here, asserted by
		-- THROWING a Hotbar move -- see HOTBAR_MOVE's own header on why that now needs a real Player
		-- and is deferred to Studio/live-server verification instead.

		it("keeps the beat shorter than the buffer that forgives it", function()
			-- The relationship, not either number: a chain delay at or past the buffer would mean a
			-- press made the instant a swing ends expires before the beat it is waiting on opens, which
			-- is the one way the pause makes the game feel worse rather than better. Asserted here so
			-- retuning either constant in isolation fails loudly.
			expect(CHAIN_DELAY < BUFFER).to.equal(true)
		end)
	end)

	describe("AttackRequestSystem -- feint", function()
		local FEINT = AttackConstants.Feint

		local function heavyWindup(): number
			local entry = AttackCatalog.Get(`default:{FIRST_WEAPON}:Heavy:1`)
			assert(entry ~= nil, "the first weapon's Heavy string must be catalogued")
			return (entry :: any).Definition.WindupSeconds
		end

		it("cancels a Heavy early in its windup and frees the engine", function()
			local attacker = makeDummy("Feinter", Vector3.new(0, 5, 0))
			local base = os.clock()
			expect(AttackRequestSystem.Throw(attacker.Model, { Kind = "Heavy" }, false, base)).to.equal(true)
			expect(HitboxEngine.GetAttackState(attacker.Id)).to.equal("Windup")

			local accepted, reason = AttackRequestSystem.Feint(attacker.Model, base + 0.01)
			expect(accepted).to.equal(true)
			expect(reason).to.equal(nil)
			expect(HitboxEngine.GetAttackState(attacker.Id)).to.equal("Idle")
		end)

		-- Right-click during an M1 has to feint on every weapon, not only during a Heavy.
		it("feints a Basic too, on every weapon in the roster", function()
			for index, weaponId in ROSTER do
				local attacker = makeDummy(`Jabber{index}`, Vector3.new(index * 20, 5, 0))
				local base = os.clock()
				AttackRequestSystem.SetWeapon(attacker.Model, weaponId, base)
				expect(AttackRequestSystem.Throw(attacker.Model, { Kind = "Basic" }, false, base)).to.equal(true)
				local accepted, reason = AttackRequestSystem.Feint(attacker.Model, base + 0.001)
				expect(reason).to.equal(nil)
				expect(accepted).to.equal(true)
				expect(HitboxEngine.GetAttackState(attacker.Id)).to.equal("Idle")
			end
		end)

		it("refuses with no swing in flight", function()
			local attacker = makeDummy("Idle", Vector3.new(0, 5, 0))
			local accepted, reason = AttackRequestSystem.Feint(attacker.Model, os.clock())
			expect(accepted).to.equal(false)
			expect(reason).to.equal("NotInWindup")
		end)

		it("refuses past the window fraction, so a feint cannot answer a visible parry", function()
			local attacker = makeDummy("Late", Vector3.new(0, 5, 0))
			local base = os.clock()
			AttackRequestSystem.Throw(attacker.Model, { Kind = "Heavy" }, false, base)
			-- Past the fraction but still inside the windup -- the engine is deliberately not stepped, so
			-- it still reports Windup and the fraction is the only thing refusing.
			local lateAt = base + heavyWindup() * (FEINT.WindowFraction + 0.1)
			local accepted, reason = AttackRequestSystem.Feint(attacker.Model, lateAt)
			expect(accepted).to.equal(false)
			expect(reason).to.equal("TooLate")
		end)

		it("rewrites CombatBusyUntil BACKWARDS to the feint's own recovery", function()
			local attacker = makeDummy("Busy", Vector3.new(0, 5, 0))
			local base = os.clock()
			AttackRequestSystem.Throw(attacker.Model, { Kind = "Heavy" }, false, base)
			local swingBusy = attacker.Humanoid:GetAttribute("CombatBusyUntil") :: number

			AttackRequestSystem.Feint(attacker.Model, base + 0.01)
			local feintBusy = attacker.Humanoid:GetAttribute("CombatBusyUntil") :: number
			expect(math.abs(feintBusy - (base + 0.01 + FEINT.RecoverySeconds)) < 1e-6).to.equal(true)
			expect(feintBusy < swingBusy).to.equal(true)
		end)

		it("abandons the string and allows a fresh Heavy once the recovery ends", function()
			local attacker = makeDummy("Reset", Vector3.new(0, 5, 0))
			local base = os.clock()
			AttackRequestSystem.Throw(attacker.Model, { Kind = "Heavy" }, false, base)
			AttackRequestSystem.Feint(attacker.Model, base + 0.01)
			expect(SwingSequencer.GetStageIndex(attacker.Model, "Heavy", base + 0.02)).to.equal(0)

			-- Inside the recovery: held, and for a reason that buffers.
			local early, earlyReason = AttackRequestSystem.Throw(attacker.Model, { Kind = "Heavy" }, false, base + 0.02)
			expect(early).to.equal(false)
			expect(AttackConstants.Input.TransientRefusals[earlyReason :: string]).to.equal(true)

			-- After it: stage 1 again, with the swing-length cooldown shortened along with the swing.
			local afterAt = base + 0.01 + FEINT.RecoverySeconds + 1e-3
			local accepted, reason = AttackRequestSystem.Throw(attacker.Model, { Kind = "Heavy" }, false, afterAt)
			expect(reason).to.equal(nil)
			expect(accepted).to.equal(true)
			expect(SwingSequencer.GetStageIndex(attacker.Model, "Heavy", afterAt)).to.equal(1)
		end)

		it("will not feint again inside the feint cooldown", function()
			local attacker = makeDummy("Twice", Vector3.new(0, 5, 0))
			local base = os.clock()
			AttackRequestSystem.Throw(attacker.Model, { Kind = "Heavy" }, false, base)
			AttackRequestSystem.Feint(attacker.Model, base + 0.01)

			local againAt = base + 0.01 + FEINT.RecoverySeconds + 1e-3
			AttackRequestSystem.Throw(attacker.Model, { Kind = "Heavy" }, false, againAt)
			local accepted, reason = AttackRequestSystem.Feint(attacker.Model, againAt + 0.001)
			expect(accepted).to.equal(false)
			expect(reason).to.equal("Cooldown")
			expect(FEINT.CooldownSeconds > FEINT.RecoverySeconds).to.equal(true)
		end)

		it("drops a press buffered against the swing it cancelled", function()
			local attacker = makeDummy("Buffered", Vector3.new(0, 5, 0))
			local base = os.clock()
			AttackRequestSystem.Throw(attacker.Model, { Kind = "Heavy" }, false, base)
			AttackRequestSystem.Press(attacker.Model, { Kind = "Heavy" }, false, base + 0.005)
			expect(AttackRequestSystem.HasBufferedPress(attacker.Model, base + 0.005)).to.equal(true)

			AttackRequestSystem.Feint(attacker.Model, base + 0.01)
			expect(AttackRequestSystem.HasBufferedPress(attacker.Model, base + 0.01)).to.equal(false)
		end)
	end)

	describe("AttackRequestSystem -- weight class", function()
		it("throws a Heavy at twice a Basic's power level, so it drains twice the guard", function()
			local basic = AttackCatalog.Get(`default:{FIRST_WEAPON}:Basic:1`)
			local heavy = AttackCatalog.Get(`default:{FIRST_WEAPON}:Heavy:1`)
			assert(basic ~= nil and heavy ~= nil, "both strings must be catalogued")
			expect(basic.PowerLevel).to.equal(1)
			expect(heavy.PowerLevel).to.equal(2)
			expect(GuardMeter.DrainFor(heavy.PowerLevel, false)).to.equal(
				2 * GuardMeter.DrainFor(basic.PowerLevel, false)
			)
		end)

		it("hands the engine the move's own power level, not a flat 1", function()
			local attacker = makeDummy("Heavyweight", Vector3.new(0, 5, 0))
			local target = makeDummy("Anvil", Vector3.new(0, 5, -3))
			local reports: { any } = {}
			local disconnect = HitboxEngine.OnHit(function(report)
				if report.Target == target.Model then
					table.insert(reports, report)
				end
			end)

			local base = os.clock()
			AttackRequestSystem.Throw(attacker.Model, { Kind = "Heavy" }, false, base)
			local entry = AttackCatalog.Get(`default:{FIRST_WEAPON}:Heavy:1`) :: any
			local total = entry.Definition.WindupSeconds + entry.Definition.ActiveSeconds + FRAME
			for frame = 0, math.ceil(total / FRAME) do
				step(base + frame * FRAME)
			end
			disconnect()

			expect(#reports > 0).to.equal(true)
			expect(reports[1].PowerLevel).to.equal(2)
		end)
	end)

	describe("AttackRequestSystem -- the string's tempo", function()
		local function entryOf(moveId: string): any
			local entry = AttackCatalog.Get(moveId)
			assert(entry ~= nil, `{moveId} must be catalogued`)
			return entry
		end

		it("plays an M1 at the Basic tempo relative to a Heavy on the same weapon", function()
			local basic = entryOf(`default:{FIRST_WEAPON}:Basic:1`)
			local heavy = entryOf(`default:{FIRST_WEAPON}:Heavy:1`)
			local ratio = basic.PlaybackSpeed / heavy.PlaybackSpeed
			local expected = AttackConstants.Tempo.ByStage.Basic / AttackConstants.Tempo.ByStage.Heavy
			expect(ratio).to.be.near(expected, 1e-6)
		end)

		it("keeps every landed-hit gap in the string inside the combo window, the launcher included", function()
			-- Worst case: contact on the first frame of one swing's active window, then the next swing's
			-- own windup after this one's active + recovery and the chain beat. A gap past the window means
			-- the launcher -- the string's 4th hit, which needs all three before it LANDED -- is unreachable.
			local chain: { any } = {}
			for stage = 1, AttackConstants.Sequence.MaxStageProbe do
				local entry = AttackCatalog.Get(`default:{FIRST_WEAPON}:Basic:{stage}`)
				if not entry then
					break
				end
				table.insert(chain, entry)
			end
			table.insert(chain, entryOf(`default:{FIRST_WEAPON}:Launcher`))
			expect(#chain >= 2).to.equal(true)

			local window = DamageConstants.Combo.WindowSeconds
			for index = 1, #chain - 1 do
				local current = chain[index].Definition
				local following = chain[index + 1].Definition
				local gap = current.ActiveSeconds + current.RecoverySeconds + CHAIN_DELAY + following.WindupSeconds
				expect(gap < window).to.equal(true)
			end
		end)
	end)

	describe("AttackRequestSystem -- M1s link", function()
		-- A landed M1 holds the defender until the next one in its string arrives (2026-10-06,
		-- DamageConstants.Hitstun.LinkBasicString) -- measured on the attacker's best rhythm, contact on the
		-- first active frame and the next press buffered so it throws the instant the chain beat ends. The
		-- defender's answer is a stun parry on the next impact (DefenseConstants.StunParry), not a gap.
		it("stuns every linked M1 until the next one in its string has landed", function()
			for _, weaponId in ROSTER do
				for stage = 1, AttackConstants.Sequence.MaxStageProbe - 1 do
					local current = AttackCatalog.Get(`default:{weaponId}:Basic:{stage}`)
					local following = AttackCatalog.Get(`default:{weaponId}:Basic:{stage + 1}`)
					if not (current and following) then
						break
					end
					local definition = current.Definition
					local impactToImpact = definition.ActiveSeconds
						+ definition.RecoverySeconds
						+ CHAIN_DELAY
						+ following.Definition.WindupSeconds
					local stun = current.Profile.HitstunSeconds or DamageConstants.Hitstun.Seconds
					if stun < impactToImpact + DamageConstants.Hitstun.LinkMarginSeconds - 1e-6 then
						error(
							`{weaponId} Basic {stage} -> {stage + 1}: stun {stun}s ends before the next impact ({impactToImpact}s)`
						)
					end
				end
			end
		end)

		it("keeps the link's margin past the parry rewind's hold", function()
			-- A stunned defender's next hit can wait up to RewindMaxSeconds before it applies (DefenseSystem's
			-- rewind hold) -- and that is the hit that extends the stun. The margin must outlast the wait.
			expect(DamageConstants.Hitstun.LinkMarginSeconds > DefenseConstants.Parry.RewindMaxSeconds).to.equal(true)
		end)

		it("does not hand out a Heavy off a landed M1", function()
			-- The margin is kept short so the link guarantees the next M1, not every follow-up: an attacker who
			-- switches to a Heavy after a landed Basic 1 must still be readable by the time it lands.
			for _, weaponId in ROSTER do
				local basic = AttackCatalog.Get(`default:{weaponId}:Basic:1`)
				local heavy = AttackCatalog.Get(`default:{weaponId}:Heavy:1`)
				if basic and heavy then
					local definition = basic.Definition
					local freeAfterContact = definition.ActiveSeconds + definition.RecoverySeconds
					local stun = basic.Profile.HitstunSeconds or DamageConstants.Hitstun.Seconds
					local heavyLandsAt = freeAfterContact + heavy.Definition.WindupSeconds
					if heavyLandsAt <= stun then
						error(`{weaponId}: a Heavy off Basic 1 lands at {heavyLandsAt}s, inside the {stun}s stun`)
					end
				end
			end
		end)

		it("leaves the last M1 of a string at its authored stun", function()
			for _, weaponId in ROSTER do
				local last = 0
				for stage = 1, AttackConstants.Sequence.MaxStageProbe do
					if AttackCatalog.Get(`default:{weaponId}:Basic:{stage}`) == nil then
						break
					end
					last = stage
				end
				if last > 0 then
					local entry = AttackCatalog.Get(`default:{weaponId}:Basic:{last}`) :: any
					expect(entry.Profile.HitstunSeconds).to.equal(DamageConstants.HitstunFor(weaponId, "Basic"))
				end
			end
		end)

		it("links nothing when the rule is off", function()
			local previous = DamageConstants.Hitstun.LinkBasicString
			DamageConstants.Hitstun.LinkBasicString = false
			local entry = AttackCatalog.Get(`default:{FIRST_WEAPON}:Basic:1`) :: any
			DamageConstants.Hitstun.LinkBasicString = previous
			expect(entry.Profile.HitstunSeconds).to.equal(DamageConstants.HitstunFor(FIRST_WEAPON, "Basic"))
		end)

		it("stuns less on a Fists jab than on a blade's M1 at the end of a string", function()
			local fists = AttackCatalog.Get("default:Fists:Basic:3") :: any
			expect(fists).to.be.ok()
			expect(fists.Profile.HitstunSeconds).to.equal(DamageConstants.HitstunFor("Fists", "Basic"))
			expect(fists.Profile.HitstunSeconds < DamageConstants.Hitstun.Seconds).to.equal(true)
			-- The ceiling that keeps a press buffered at the moment of being hit from firing out of the stun.
			expect(fists.Profile.HitstunSeconds > AttackConstants.Input.BufferSeconds).to.equal(true)
		end)
	end)

	describe("AttackRequestSystem -- weapons", function()
		it("reports the weapon the sequencer is holding", function()
			local attacker = makeDummy("Armed", Vector3.new(0, 5, 0))
			SwingSequencer.SetWeapon(attacker.Model, FIRST_WEAPON, os.clock())
			expect(AttackRequestSystem.GetWeapon(attacker.Model)).to.equal(FIRST_WEAPON)
			SwingSequencer.SwapWeapon(attacker.Model, os.clock())
			expect(AttackRequestSystem.GetWeapon(attacker.Model)).to.equal(SECOND_WEAPON)
		end)
	end)
	describe("AttackRequestSystem -- the hit-confirm cancel", function()
		-- When the first Basic stage's recovery may be cut once it lands, from a throw at `base`.
		local function basicCutAt(base: number): number
			local entry = AttackCatalog.Get(`default:{FIRST_WEAPON}:Basic:1`) :: any
			local definition = entry.Definition
			return AttackConstants.HitConfirmCancelAt(
				base,
				definition.WindupSeconds,
				definition.ActiveSeconds,
				definition.RecoverySeconds
			)
		end

		it("cuts a LANDED Basic's recovery into a Heavy at the cut point", function()
			local attacker = makeDummy("Confirmed", Vector3.new(0, 5, 0))
			local base = os.clock()
			expect((AttackRequestSystem.Throw(attacker.Model, { Kind = "Basic" }, false, base))).to.equal(true)
			AttackRequestSystem.NoteHitConfirmed(attacker.Model, `default:{FIRST_WEAPON}:Basic:1`)

			local cutAt = basicCutAt(base) + 1e-3
			step(cutAt)
			expect(HitboxEngine.GetAttackState(attacker.Id)).to.equal("Recovery")
			local accepted = AttackRequestSystem.Throw(attacker.Model, { Kind = "Heavy" }, false, cutAt)
			expect(accepted).to.equal(true)
		end)

		it("does not cut a swing that did not land", function()
			local attacker = makeDummy("Whiffed", Vector3.new(0, 5, 0))
			local base = os.clock()
			AttackRequestSystem.Throw(attacker.Model, { Kind = "Basic" }, false, base)

			local cutAt = basicCutAt(base) + 1e-3
			step(cutAt)
			local accepted, reason = AttackRequestSystem.Throw(attacker.Model, { Kind = "Heavy" }, false, cutAt)
			expect(accepted).to.equal(false)
			expect(reason).to.equal("Busy")
		end)

		it("does not cut before the cut point", function()
			local attacker = makeDummy("TooSoon", Vector3.new(0, 5, 0))
			local base = os.clock()
			AttackRequestSystem.Throw(attacker.Model, { Kind = "Basic" }, false, base)
			AttackRequestSystem.NoteHitConfirmed(attacker.Model, `default:{FIRST_WEAPON}:Basic:1`)

			local early = basicCutAt(base) - 0.02
			step(early)
			local accepted = AttackRequestSystem.Throw(attacker.Model, { Kind = "Heavy" }, false, early)
			expect(accepted).to.equal(false)
		end)

		it("keeps M1 into M1 at its full rhythm -- Basic does not take the cut", function()
			expect(AttackConstants.HitConfirm.CancelInto.Basic).to.equal(false)
			local attacker = makeDummy("Rhythm", Vector3.new(0, 5, 0))
			local base = os.clock()
			AttackRequestSystem.Throw(attacker.Model, { Kind = "Basic" }, false, base)
			AttackRequestSystem.NoteHitConfirmed(attacker.Model, `default:{FIRST_WEAPON}:Basic:1`)

			local cutAt = basicCutAt(base) + 1e-3
			step(cutAt)
			local accepted = AttackRequestSystem.Throw(attacker.Model, { Kind = "Basic" }, false, cutAt)
			expect(accepted).to.equal(false)
		end)

		it("cuts a landed recovery for an accepted evade, and only then", function()
			local attacker = makeDummy("EvadeOut", Vector3.new(0, 5, 0))
			local base = os.clock()
			AttackRequestSystem.Throw(attacker.Model, { Kind = "Basic" }, false, base)

			local cutAt = basicCutAt(base) + 1e-3
			step(cutAt)
			expect(AttackRequestSystem.CancelRecoveryForEvade(attacker.Model, cutAt)).to.equal(false)

			AttackRequestSystem.NoteHitConfirmed(attacker.Model, `default:{FIRST_WEAPON}:Basic:1`)
			expect(AttackRequestSystem.CancelRecoveryForEvade(attacker.Model, cutAt)).to.equal(true)
			expect(HitboxEngine.GetAttackState(attacker.Id)).to.equal("Idle")
		end)

		it("ignores a landing reported for a swing that is not the one in flight", function()
			local attacker = makeDummy("Stale", Vector3.new(0, 5, 0))
			local base = os.clock()
			AttackRequestSystem.Throw(attacker.Model, { Kind = "Basic" }, false, base)
			AttackRequestSystem.NoteHitConfirmed(attacker.Model, `default:{FIRST_WEAPON}:Basic:2`)

			local cutAt = basicCutAt(base) + 1e-3
			step(cutAt)
			expect((AttackRequestSystem.Throw(attacker.Model, { Kind = "Heavy" }, false, cutAt))).to.equal(false)
		end)
	end)

	describe("AttackRequestSystem -- the heavy tell", function()
		local TELL = AttackConstants.Tell

		it("tags a Heavy's thrower for its windup, with the windup's end stamped", function()
			local attacker = makeDummy("Telegraph", Vector3.new(0, 5, 0))
			local base = os.clock()
			expect((AttackRequestSystem.Throw(attacker.Model, { Kind = "Heavy" }, false, base))).to.equal(true)
			expect(CollectionService:HasTag(attacker.Model, TELL.Tag)).to.equal(true)
			expect(typeof(attacker.Model:GetAttribute(TELL.UntilAttribute))).to.equal("number")

			local entry = AttackCatalog.Get(`default:{FIRST_WEAPON}:Heavy:1`) :: any
			step(base + entry.Definition.WindupSeconds + 0.01)
			expect(CollectionService:HasTag(attacker.Model, TELL.Tag)).to.equal(false)
		end)

		it("does not tag a Basic", function()
			local attacker = makeDummy("Quiet", Vector3.new(0, 5, 0))
			AttackRequestSystem.Throw(attacker.Model, { Kind = "Basic" }, false, os.clock())
			expect(CollectionService:HasTag(attacker.Model, TELL.Tag)).to.equal(false)
		end)

		it("drops the tell the moment the Heavy is feinted", function()
			local attacker = makeDummy("Bluff", Vector3.new(0, 5, 0))
			local base = os.clock()
			AttackRequestSystem.Throw(attacker.Model, { Kind = "Heavy" }, false, base)
			expect((AttackRequestSystem.Feint(attacker.Model, base + 0.01))).to.equal(true)
			expect(CollectionService:HasTag(attacker.Model, TELL.Tag)).to.equal(false)
		end)
	end)

	-- AttackConstants.Latency: a player's swing starts half a round trip before its press arrived, and never
	-- before the body was free to swing.
	describe("AttackRequestSystem -- the attacker's latency refund", function()
		afterEach(function()
			NetworkLatency.SetResolver(nil)
		end)

		it("starts a player's swing half a round trip before the press arrived", function()
			local attacker = makeDummy("Remote", Vector3.new(0, 5, 0))
			NetworkLatency.SetResolver(function()
				return 0.1
			end)
			local base = os.clock()
			expect((AttackRequestSystem.Throw(attacker.Model, { Kind = "Basic" }, false, base))).to.equal(true)
			local swing = AttackRequestSystem.GetInFlight(attacker.Model)
			assert(swing, "an accepted swing is in flight")
			expect(swing.StartedAt).to.be.near(base - 0.05, 1e-6)
		end)

		it("caps the refund", function()
			local attacker = makeDummy("FarAway", Vector3.new(0, 5, 0))
			NetworkLatency.SetResolver(function()
				return 2
			end)
			local base = os.clock()
			AttackRequestSystem.Throw(attacker.Model, { Kind = "Basic" }, false, base)
			local swing = AttackRequestSystem.GetInFlight(attacker.Model)
			assert(swing, "an accepted swing is in flight")
			expect(swing.StartedAt).to.be.near(base - AttackConstants.Latency.MaxLeadSeconds, 1e-6)
		end)

		it("never reaches back into a stun", function()
			local attacker = makeDummy("JustFreed", Vector3.new(0, 5, 0))
			NetworkLatency.SetResolver(function()
				return 0.1
			end)
			local base = os.clock()
			-- Stunned until 10ms before the press arrived: the swing may start no earlier than that.
			DamageSystem.ExtendHitstun(attacker.Model, base - 0.01, base - 0.5)
			expect((AttackRequestSystem.Throw(attacker.Model, { Kind = "Basic" }, false, base))).to.equal(true)
			local swing = AttackRequestSystem.GetInFlight(attacker.Model)
			assert(swing, "an accepted swing is in flight")
			expect(swing.StartedAt).to.be.near(base - 0.01, 1e-6)
		end)

		it("refunds nothing to a body with no connection", function()
			local attacker = makeDummy("Bot", Vector3.new(0, 5, 0))
			local base = os.clock()
			AttackRequestSystem.Throw(attacker.Model, { Kind = "Basic" }, false, base)
			local swing = AttackRequestSystem.GetInFlight(attacker.Model)
			assert(swing, "an accepted swing is in flight")
			expect(swing.StartedAt).to.equal(base)
		end)
	end)

	-- DefenseConstants.Clash: two swings that met cost each side its swing, not its place in the string.
	describe("AttackRequestSystem -- a trade keeps the chain", function()
		it("puts the string back and frees it after the shared recovery", function()
			local attacker = makeDummy("Trader", Vector3.new(0, 5, 0))
			local base = os.clock()
			local gate = chainGateSeconds()

			AttackRequestSystem.Throw(attacker.Model, { Kind = "Basic" }, false, base)
			local frames = math.ceil((gate + FRAME) / FRAME)
			for frame = 0, frames do
				step(base + frame * FRAME)
			end
			local second = base + frames * FRAME
			expect((AttackRequestSystem.Throw(attacker.Model, { Kind = "Basic" }, false, second))).to.equal(true)
			expect(SwingSequencer.GetStageIndex(attacker.Model, "Basic", second)).to.equal(2)
			local swing = AttackRequestSystem.GetInFlight(attacker.Model)
			assert(swing, "the second swing is in flight")

			local cut = second + 0.05
			HitboxEngine.CancelAttack(attacker.Id, "Traded", cut)
			expect(AttackRequestSystem.KeepChainThroughTrade(attacker.Model, swing.MoveId, cut)).to.equal(true)

			-- The traded B2 never landed, so the next press is B2 again ...
			expect(SwingSequencer.GetStageIndex(attacker.Model, "Basic", cut)).to.equal(1)
			-- ... thrown after the one shared beat, not after whatever was left of the swing that got cut.
			expect(SwingSequencer.ChainDelayRemaining(attacker.Model, cut)).to.be.near(
				DefenseConstants.Clash.RecoverySeconds,
				1e-6
			)
		end)
	end)
end
